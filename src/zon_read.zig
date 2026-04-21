//! ZON read-side parser and typed deserializer bridge.
//!
//! This backend leans on Zig's own ZON front-end to parse text into `Zoir`,
//! then exposes the same pull-deserializer protocol the typed layer already
//! understands. Unlike the binary backends, this path cannot alias final string
//! fields directly back into the caller's input slice because Zig's parser needs
//! a sentinel-terminated buffer and string literal decoding may allocate.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;
const Zoir = std.zig.Zoir;
const ZonGen = std.zig.ZonGen;
const diagnostic_mod = @import("diagnostic.zig");
const typed = @import("typed.zig");

const Number = typed.Number;
const ObjectFieldLookup = typed.ObjectFieldLookup;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const ParseError = anyerror;

pub const ReadConfig = struct {
    max_input_bytes: usize = 128 * 1024 * 1024,
};

const Frame = union(enum) {
    array: struct {
        range: Zoir.Node.Index.Range,
        index: usize,
    },
    object: struct {
        names: []const Zoir.NullTerminatedString,
        vals: Zoir.Node.Index.Range,
        index: usize,
    },
};

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !ZonDeserializer(@TypeOf(cfg)) {
    const raw_input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    defer allocator.free(raw_input);

    const input = try allocator.dupeZ(u8, raw_input);
    return ZonDeserializer(@TypeOf(cfg)).init(allocator, input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !ZonDeserializer(@TypeOf(cfg)) {
    if (input.len > effectiveMaxInputBytes(cfg)) return error.InputTooLarge;
    return ZonDeserializer(@TypeOf(cfg)).init(allocator, try allocator.dupeZ(u8, input), cfg);
}

pub fn deserialize(comptime T: type, allocator: Allocator, reader: *std.Io.Reader) ParseError!T {
    return deserializeWith(T, allocator, reader, .{}, .{});
}

pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try readerDeserializer(allocator, reader, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSlice(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn ZonDeserializer(comptime Config: type) type {
    return struct {
        allocator: Allocator,
        input: [:0]const u8,
        cfg: Config,
        ast: ?Ast = null,
        zoir: ?Zoir = null,
        current: ?Zoir.Node.Index = null,
        stack: [128]Frame = undefined,
        stack_len: usize = 0,
        last_error_location: ?diagnostic_mod.Location = null,

        const Self = @This();

        fn init(allocator: Allocator, input: [:0]const u8, cfg: Config) Self {
            return .{
                .allocator = allocator,
                .input = input,
                .cfg = cfg,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            _ = allocator;
            if (self.zoir) |zoir| zoir.deinit(self.allocator);
            if (self.ast) |*ast| ast.deinit(self.allocator);
            self.allocator.free(self.input);
        }

        pub fn finish(self: *Self) !void {
            try self.ensureParsed();
        }

        pub fn borrowStrings(self: *Self) bool {
            _ = self;
            return false;
        }

        pub fn errorLocation(self: *Self) diagnostic_mod.Location {
            if (self.last_error_location) |location| return location;

            if (self.ast) |ast| {
                const node = self.currentNodeIndex();
                const token = ast.nodeMainToken(node.getAstNode(self.zoir.?));
                return locationFromAstToken(ast, token, 0);
            }

            return .{};
        }

        pub fn peekKind(self: *Self) !ValueKind {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .null => .null,
                .true, .false => .bool,
                .int_literal, .float_literal, .char_literal, .pos_inf, .neg_inf, .nan => .number,
                .string_literal, .enum_literal => .string,
                .array_literal => .array,
                .struct_literal, .empty_literal => .object,
            };
        }

        pub fn readNull(self: *Self) !void {
            try self.ensureParsed();
            switch (self.currentNode()) {
                .null => {},
                else => return self.failCurrent(error.UnexpectedType),
            }
        }

        pub fn readBool(self: *Self) !bool {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .true => true,
                .false => false,
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn readNumber(self: *Self) !Number {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .int_literal => |value| switch (value) {
                    .small => |small| .{ .integer = small },
                    .big => |big| blk: {
                        if (!big.fits(i128)) return self.failCurrent(error.IntegerOverflow);
                        break :blk .{ .integer = try big.toInt(i128) };
                    },
                },
                .float_literal => |value| .{ .float = @as(f64, @floatCast(value)) },
                .pos_inf => .{ .float = std.math.inf(f64) },
                .neg_inf => .{ .float = -std.math.inf(f64) },
                .nan => .{ .float = std.math.nan(f64) },
                .char_literal => |value| .{ .integer = value },
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn readInt(self: *Self, comptime T: type) !T {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .int_literal => |value| switch (value) {
                    .small => |small| std.math.cast(T, small) orelse return self.failCurrent(error.IntegerOverflow),
                    .big => |big| big.toInt(T) catch return self.failCurrent(error.IntegerOverflow),
                },
                .float_literal => |value| blk: {
                    const rounded = @round(value);
                    if (rounded != value) return self.failCurrent(error.UnexpectedType);
                    break :blk switch (@typeInfo(T)) {
                        .comptime_int => @as(T, @intFromFloat(rounded)),
                        .int => std.math.cast(T, @as(i128, @intFromFloat(rounded))) orelse return self.failCurrent(error.IntegerOverflow),
                        else => return self.failCurrent(error.UnsupportedType),
                    };
                },
                .char_literal => |value| std.math.cast(T, value) orelse return self.failCurrent(error.IntegerOverflow),
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn readFloat(self: *Self, comptime T: type) !T {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .int_literal => |value| switch (value) {
                    .small => |small| @as(T, @floatFromInt(small)),
                    .big => |big| big.toFloat(T, .nearest_even)[0],
                },
                .float_literal => |value| @as(T, @floatCast(value)),
                .pos_inf => std.math.inf(T),
                .neg_inf => -std.math.inf(T),
                .nan => std.math.nan(T),
                .char_literal => |value| @as(T, @floatFromInt(value)),
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn readEnumTag(self: *Self, comptime T: type) !T {
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .enum_literal => |field_name| std.meta.stringToEnum(T, field_name.get(self.zoir.?)) orelse return self.failCurrent(error.InvalidEnumTag),
                .string_literal => blk: {
                    const token = try self.readString(self.allocator);
                    defer token.deinit(self.allocator);
                    break :blk std.meta.stringToEnum(T, token.bytes) orelse return self.failCurrent(error.InvalidEnumTag);
                },
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            try self.ensureParsed();
            return switch (self.currentNode()) {
                .string_literal => try self.parseStringToken(self.currentNodeIndex()),
                .enum_literal => |field_name| .{
                    .bytes = field_name.get(self.zoir.?),
                    .allocated = false,
                },
                else => return self.failCurrent(error.UnexpectedType),
            };
        }

        pub fn beginArray(self: *Self) !void {
            try self.ensureParsed();
            switch (self.currentNode()) {
                .array_literal => |range| try self.push(.{
                    .array = .{
                        .range = range,
                        .index = 0,
                    },
                }),
                .empty_literal => try self.push(.{
                    .array = .{
                        .range = .{ .start = self.currentNodeIndex(), .len = 0 },
                        .index = 0,
                    },
                }),
                else => return self.failCurrent(error.UnexpectedType),
            }
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            try self.beginArray();
            return switch (self.currentFrame().*) {
                .array => |array_frame| array_frame.range.len,
                else => return error.InvalidZonState,
            };
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = switch (self.currentFrame().*) {
                .array => |*array_frame| array_frame,
                else => return error.InvalidZonState,
            };

            if (frame.index >= frame.range.len) {
                _ = self.pop();
                return false;
            }

            self.current = frame.range.at(@intCast(frame.index));
            frame.index += 1;
            return true;
        }

        pub fn beginObject(self: *Self) !void {
            try self.ensureParsed();
            switch (self.currentNode()) {
                .struct_literal => |fields| try self.push(.{
                    .object = .{
                        .names = fields.names,
                        .vals = fields.vals,
                        .index = 0,
                    },
                }),
                .empty_literal => try self.push(.{
                    .object = .{
                        .names = &.{},
                        .vals = .{ .start = self.currentNodeIndex(), .len = 0 },
                        .index = 0,
                    },
                }),
                else => return self.failCurrent(error.UnexpectedType),
            }
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            _ = allocator;
            const frame = switch (self.currentFrame().*) {
                .object => |*object_frame| object_frame,
                else => return error.InvalidZonState,
            };

            if (frame.index >= frame.vals.len) {
                _ = self.pop();
                return null;
            }

            const field_index = frame.index;
            frame.index += 1;
            self.current = frame.vals.at(@intCast(field_index));
            return .{
                .bytes = frame.names[field_index].get(self.zoir.?),
                .allocated = false,
            };
        }

        pub fn nextObjectFieldIndex(self: *Self, comptime T: type, comptime cfg: anytype) !ObjectFieldLookup {
            const frame = switch (self.currentFrame().*) {
                .object => |*object_frame| object_frame,
                else => return error.InvalidZonState,
            };

            if (frame.index >= frame.vals.len) {
                _ = self.pop();
                return .end;
            }

            const field_index = frame.index;
            frame.index += 1;
            self.current = frame.vals.at(@intCast(field_index));
            const field_name = frame.names[field_index].get(self.zoir.?);

            return if (typed.matchStructFieldIndex(T, cfg, field_name)) |index|
                .{ .field_index = index }
            else
                .unknown;
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = self;
            _ = allocator;
        }

        fn ensureParsed(self: *Self) !void {
            if (self.zoir != null) {
                if (self.zoir.?.hasCompileErrors()) return error.ParseZon;
                return;
            }

            var ast = try std.zig.Ast.parse(self.allocator, self.input, .zon);
            errdefer ast.deinit(self.allocator);

            var zoir = try ZonGen.generate(self.allocator, ast, .{ .parse_str_lits = false });
            errdefer zoir.deinit(self.allocator);

            self.ast = ast;
            self.zoir = zoir;

            if (zoir.hasCompileErrors()) {
                self.last_error_location = firstCompileErrorLocation(ast, zoir);
                return error.ParseZon;
            }
        }

        fn parseStringToken(self: *Self, node: Zoir.Node.Index) !StringToken {
            const ast = self.ast.?;
            const ast_node = node.getAstNode(self.zoir.?);
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            errdefer out.deinit();

            try out.ensureUnusedCapacity(ZonGen.strLitSizeHint(ast, ast_node));
            const result = ZonGen.parseStrLit(ast, ast_node, &out.writer) catch return error.OutOfMemory;
            switch (result) {
                .success => {},
                .failure => |err| {
                    const token = ast.nodeMainToken(ast_node);
                    const location = locationFromAstToken(ast, token, @intCast(err.offset()));
                    self.last_error_location = location;
                    return error.InvalidStringLiteral;
                },
            }

            return .{
                .bytes = try out.toOwnedSlice(),
                .allocated = true,
            };
        }

        fn currentNodeIndex(self: *Self) Zoir.Node.Index {
            return self.current orelse .root;
        }

        fn currentNode(self: *Self) Zoir.Node {
            return self.currentNodeIndex().get(self.zoir.?);
        }

        fn currentFrame(self: *Self) *Frame {
            return &self.stack[self.stack_len - 1];
        }

        fn push(self: *Self, frame: Frame) !void {
            if (self.stack_len == self.stack.len) return error.ZonNestingTooDeep;
            self.stack[self.stack_len] = frame;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Frame {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn failCurrent(self: *Self, err: anyerror) anyerror {
            self.last_error_location = self.errorLocation();
            return err;
        }
    };
}

fn effectiveMaxInputBytes(cfg: anytype) usize {
    if (@hasField(@TypeOf(cfg), "max_input_bytes")) return cfg.max_input_bytes;
    return 128 * 1024 * 1024;
}

fn firstCompileErrorLocation(ast: Ast, zoir: Zoir) diagnostic_mod.Location {
    if (zoir.compile_errors.len == 0) return .{};
    const compile_err = zoir.compile_errors[0];

    if (compile_err.token.unwrap()) |token| {
        return locationFromAstToken(ast, token, @intCast(compile_err.node_or_offset));
    }

    const node: Ast.Node.Index = @enumFromInt(compile_err.node_or_offset);
    return locationFromAstToken(ast, ast.nodeMainToken(node), 0);
}

fn locationFromAstToken(ast: Ast, token: Ast.TokenIndex, extra_column_offset: usize) diagnostic_mod.Location {
    const raw = ast.tokenLocation(0, token);
    return .{
        .offset = ast.tokenStart(token) + extra_column_offset,
        .line = raw.line + 1,
        .column = raw.column + extra_column_offset + 1,
    };
}
