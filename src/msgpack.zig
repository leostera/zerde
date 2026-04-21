//! MessagePack backend for the typed walk.
//!
//! This backend targets the common JSON-like subset of MessagePack:
//! nil, booleans, integers, floats, strings, byte strings, arrays, and maps.
//! It keeps the typed walk format-agnostic while still emitting direct,
//! length-prefixed MessagePack containers without a runtime intermediate tree.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const Number = typed.Number;
const ObjectFieldLookup = typed.ObjectFieldLookup;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const FieldCase = meta.FieldCase;
pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    borrow_strings: bool = false,
};
pub const WriteConfig = struct {};
pub const ParseError = anyerror;

const ContainerKind = enum {
    array,
    object,
};

const Container = struct {
    kind: ContainerKind,
    remaining: usize,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) MsgpackSerializer(@TypeOf(cfg)) {
    return MsgpackSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !MsgpackDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return MsgpackDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !MsgpackDeserializer(@TypeOf(cfg)) {
    _ = allocator;
    return MsgpackDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

pub fn MsgpackSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,

        const Self = @This();

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            _ = self.cfg;
            try self.writer.writeByte(0xc0);
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.writer.writeByte(if (value) 0xc3 else 0xc2);
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try writeInt(self.writer, value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try writeFloat(self.writer, value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeStrHeader(self.writer, value.len);
            try self.writer.writeAll(value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            try writeBinHeader(self.writer, value.len);
            try self.writer.writeAll(value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try self.emitInteger(@intFromEnum(value));
        }

        pub fn serializeSequence(self: *Self, comptime Sequence: type, value: Sequence, comptime cfg: anytype) !bool {
            _ = cfg;
            if (!isInlineSequenceType(Sequence)) return false;

            try writeInlineSequence(self, Sequence, value);
            return true;
        }

        pub fn beginStructSized(self: *Self, comptime T: type, field_count: usize) !void {
            _ = T;
            try writeMapHeader(self.writer, field_count);
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
            return error.InvalidMsgpackState;
        }

        pub fn structPassCount(comptime T: type) usize {
            _ = T;
            return 1;
        }

        pub fn includeStructField(comptime Parent: type, comptime FieldType: type, comptime pass: usize) bool {
            _ = Parent;
            _ = FieldType;
            _ = pass;
            return true;
        }

        pub fn beginStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !bool {
            _ = Parent;
            _ = FieldType;
            try self.writeFieldName(name);
            return true;
        }

        pub fn beginStructFieldValue(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type, value: FieldType) !bool {
            _ = Parent;
            try self.writeFieldName(name);

            if (try self.writeInlineValue(FieldType, value)) return false;
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            try writeArrayHeader(self.writer, len);
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = self;
            _ = Child;
            _ = len;
        }

        fn writeFieldName(self: *Self, comptime name: []const u8) !void {
            const encoded = comptime encodeFieldName(name);
            try self.writer.writeAll(&encoded);
        }

        fn writeInlineValue(self: *Self, comptime T: type, value: T) !bool {
            switch (@typeInfo(T)) {
                .bool => {
                    try self.emitBool(value);
                    return true;
                },
                .int, .comptime_int => {
                    try self.emitInteger(value);
                    return true;
                },
                .float, .comptime_float => {
                    try self.emitFloat(value);
                    return true;
                },
                .@"enum" => {
                    try self.emitEnum(T, value);
                    return true;
                },
                .optional => {
                    if (value) |child| return try self.writeInlineValue(@TypeOf(child), child);
                    try self.emitNull();
                    return true;
                },
                .array => |info| {
                    if (info.child == u8) {
                        try self.emitBytes(value[0..]);
                        return true;
                    }
                    if (isInlineSequenceType(T)) {
                        try writeInlineSequence(self, T, value);
                        return true;
                    }
                    return false;
                },
                .pointer => |info| switch (info.size) {
                    .slice => {
                        if (info.child == u8) {
                            try self.emitString(value);
                            return true;
                        }
                        if (isInlineSequenceType(T)) {
                            try writeInlineSequence(self, T, value);
                            return true;
                        }
                        return false;
                    },
                    .one => return try self.writeInlineValue(info.child, value.*),
                    else => return false,
                },
                else => return false,
            }
        }
    };
}

pub fn MsgpackDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        index: usize = 0,
        owns_input: bool,
        can_borrow_strings: bool,
        stack: [128]Container = undefined,
        stack_len: usize = 0,

        const Self = @This();

        fn initBorrowed(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .owns_input = false,
                .can_borrow_strings = effectiveBorrowStrings(cfg),
            };
        }

        fn initOwned(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .owns_input = true,
                .can_borrow_strings = false,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
            if (self.stack_len != 0) return error.InvalidMsgpackState;
            if (self.index != self.input.len) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn errorOffset(self: *Self) usize {
            return self.index;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            const tag = try self.peekByte();
            return switch (classify(tag)) {
                .nil => .null,
                .boolean => .bool,
                .integer, .float => .number,
                .string => .string,
                .binary => .bytes,
                .array => .array,
                .map => .object,
                .extension => error.UnsupportedExtensionType,
                .invalid => error.UnexpectedToken,
            };
        }

        pub fn readNull(self: *Self) !void {
            const tag = try self.readByte();
            if (tag != 0xc0) return error.UnexpectedType;
        }

        pub fn readBool(self: *Self) !bool {
            return switch (try self.readByte()) {
                0xc2 => false,
                0xc3 => true,
                else => error.UnexpectedType,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            const tag = try self.readByte();
            return switch (classify(tag)) {
                .integer => .{ .integer = try self.decodeInteger(tag) },
                .float => .{ .float = try self.decodeFloat(tag) },
                else => error.UnexpectedType,
            };
        }

        pub fn readInt(self: *Self, comptime T: type) !T {
            const tag = try self.readByte();
            return switch (classify(tag)) {
                .integer => castIntValue(T, try self.decodeInteger(tag)),
                .float => castFloatToInt(T, try self.decodeFloat(tag)),
                else => error.UnexpectedType,
            };
        }

        pub fn readFloat(self: *Self, comptime T: type) !T {
            const tag = try self.readByte();
            return switch (classify(tag)) {
                .integer => @as(T, @floatFromInt(try self.decodeInteger(tag))),
                .float => @as(T, @floatCast(try self.decodeFloat(tag))),
                else => error.UnexpectedType,
            };
        }

        pub fn readEnumTag(self: *Self, comptime T: type) !T {
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const tag = try self.readByte();
            return switch (classify(tag)) {
                .integer => blk: {
                    const raw = try castIntValue(tag_type, try self.decodeInteger(tag));
                    break :blk std.enums.fromInt(T, raw) orelse error.InvalidEnumTag;
                },
                .string => blk: {
                    const raw = try self.readBorrowedStringTagged(tag);
                    break :blk std.meta.stringToEnum(T, raw) orelse error.InvalidEnumTag;
                },
                else => error.UnexpectedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            const len = try self.readRawLenFor(.string);
            return try self.readStringLike(allocator, len);
        }

        pub fn readBytes(self: *Self, allocator: Allocator) !StringToken {
            const len = try self.readRawLenFor(.binary);
            return try self.readStringLike(allocator, len);
        }

        pub fn beginArray(self: *Self) !void {
            const len = try self.readContainerLen(.array);
            try self.push(.{
                .kind = .array,
                .remaining = len,
            });
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            const len = try self.readContainerLen(.array);
            try self.push(.{
                .kind = .array,
                .remaining = len,
            });
            return len;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidMsgpackState;
            if (frame.remaining == 0) {
                _ = self.pop();
                return false;
            }
            frame.remaining -= 1;
            return true;
        }

        pub fn finishKnownLenArray(self: *Self) !void {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidMsgpackState;
            _ = self.pop();
        }

        pub fn beginObject(self: *Self) !void {
            const len = try self.readContainerLen(.map);
            try self.push(.{
                .kind = .object,
                .remaining = len,
            });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidMsgpackState;
            if (frame.remaining == 0) {
                _ = self.pop();
                return null;
            }
            frame.remaining -= 1;
            return try self.readString(allocator);
        }

        pub fn nextObjectFieldIndex(self: *Self, comptime T: type, comptime cfg: anytype) !ObjectFieldLookup {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidMsgpackState;
            if (frame.remaining == 0) {
                _ = self.pop();
                return .end;
            }

            frame.remaining -= 1;
            const key = try self.readBorrowedString();
            return if (typed.matchStructFieldIndex(T, cfg, key)) |index|
                .{ .field_index = index }
            else
                .unknown;
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = allocator;
            try self.skipOne();
        }

        fn decodeInteger(self: *Self, tag: u8) !i128 {
            return switch (tag) {
                0x00...0x7f => @as(i128, tag),
                0xe0...0xff => @as(i128, @as(i8, @bitCast(tag))),
                0xcc => @as(i128, try self.readByte()),
                0xcd => @as(i128, try self.readBig(u16)),
                0xce => @as(i128, try self.readBig(u32)),
                0xcf => @as(i128, @intCast(try self.readBig(u64))),
                0xd0 => @as(i128, @as(i8, @bitCast(try self.readByte()))),
                0xd1 => @as(i128, @as(i16, @bitCast(try self.readBig(u16)))),
                0xd2 => @as(i128, @as(i32, @bitCast(try self.readBig(u32)))),
                0xd3 => @as(i128, @as(i64, @bitCast(try self.readBig(u64)))),
                else => error.UnexpectedType,
            };
        }

        fn decodeFloat(self: *Self, tag: u8) !f64 {
            return switch (tag) {
                0xca => @as(f64, @floatCast(@as(f32, @bitCast(try self.readBig(u32))))),
                0xcb => @as(f64, @bitCast(try self.readBig(u64))),
                else => error.UnexpectedType,
            };
        }

        fn readStringLike(self: *Self, allocator: Allocator, len: usize) !StringToken {
            if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
            const raw = self.input[self.index .. self.index + len];
            self.index += len;

            if (self.can_borrow_strings) {
                return .{
                    .bytes = raw,
                    .allocated = false,
                };
            }

            return .{
                .bytes = try allocator.dupe(u8, raw),
                .allocated = true,
            };
        }

        fn readBorrowedString(self: *Self) ![]const u8 {
            const len = try self.readRawLenFor(.string);
            if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
            const raw = self.input[self.index .. self.index + len];
            self.index += len;
            return raw;
        }

        fn readBorrowedStringTagged(self: *Self, tag: u8) ![]const u8 {
            const len = try decodeRawLen(self, tag, .string);
            if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
            const raw = self.input[self.index .. self.index + len];
            self.index += len;
            return raw;
        }

        fn readRawLenFor(self: *Self, expected: HeaderClass) !usize {
            const tag = try self.readByte();
            const actual = classify(tag);
            if (actual != expected) return error.UnexpectedType;
            return try decodeRawLen(self, tag, expected);
        }

        fn readContainerLen(self: *Self, expected: HeaderClass) !usize {
            const tag = try self.readByte();
            const actual = classify(tag);
            if (actual != expected) return error.UnexpectedType;
            return try decodeContainerLen(self, tag, expected);
        }

        fn skipOne(self: *Self) !void {
            const tag = try self.readByte();
            switch (classify(tag)) {
                .nil, .boolean => {},
                .integer => _ = try self.decodeInteger(tag),
                .float => _ = try self.decodeFloat(tag),
                .string => {
                    const len = try decodeRawLen(self, tag, .string);
                    if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
                    self.index += len;
                },
                .binary => {
                    const len = try decodeRawLen(self, tag, .binary);
                    if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
                    self.index += len;
                },
                .array => {
                    const len = try decodeContainerLen(self, tag, .array);
                    for (0..len) |_| try self.skipOne();
                },
                .map => {
                    const len = try decodeContainerLen(self, tag, .map);
                    for (0..len) |_| {
                        try self.skipOne();
                        try self.skipOne();
                    }
                },
                .extension => return error.UnsupportedExtensionType,
                .invalid => return error.UnexpectedToken,
            }
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.MsgpackNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }

        fn peekByte(self: *Self) !u8 {
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            return self.input[self.index];
        }

        fn readByte(self: *Self) !u8 {
            const byte = try self.peekByte();
            self.index += 1;
            return byte;
        }

        fn readBig(self: *Self, comptime T: type) !T {
            var bytes: [@sizeOf(T)]u8 = undefined;
            if (self.input.len - self.index < bytes.len) return error.UnexpectedEndOfInput;
            @memcpy(&bytes, self.input[self.index .. self.index + bytes.len]);
            self.index += bytes.len;
            return std.mem.readInt(T, &bytes, .big);
        }
    };
}

const HeaderClass = enum {
    nil,
    boolean,
    integer,
    float,
    string,
    binary,
    array,
    map,
    extension,
    invalid,
};

fn classify(tag: u8) HeaderClass {
    return switch (tag) {
        0x00...0x7f, 0xcc...0xcf, 0xd0...0xd3, 0xe0...0xff => .integer,
        0xc0 => .nil,
        0xc2, 0xc3 => .boolean,
        0xc4...0xc6 => .binary,
        0xca, 0xcb => .float,
        0xd9...0xdb, 0xa0...0xbf => .string,
        0xdc, 0xdd, 0x90...0x9f => .array,
        0xde, 0xdf, 0x80...0x8f => .map,
        0xc7...0xc9, 0xd4...0xd8, 0xc1 => .extension,
    };
}

fn decodeRawLen(deserializer: anytype, tag: u8, expected: HeaderClass) !usize {
    if (expected == .string) {
        return switch (tag) {
            0xa0...0xbf => tag & 0x1f,
            0xd9 => std.math.cast(usize, try deserializer.readByte()) orelse error.LengthMismatch,
            0xda => std.math.cast(usize, try deserializer.readBig(u16)) orelse error.LengthMismatch,
            0xdb => std.math.cast(usize, try deserializer.readBig(u32)) orelse error.LengthMismatch,
            else => error.UnexpectedType,
        };
    }

    return switch (tag) {
        0xc4 => std.math.cast(usize, try deserializer.readByte()) orelse error.LengthMismatch,
        0xc5 => std.math.cast(usize, try deserializer.readBig(u16)) orelse error.LengthMismatch,
        0xc6 => std.math.cast(usize, try deserializer.readBig(u32)) orelse error.LengthMismatch,
        else => error.UnexpectedType,
    };
}

fn decodeContainerLen(deserializer: anytype, tag: u8, expected: HeaderClass) !usize {
    return switch (expected) {
        .array => switch (tag) {
            0x90...0x9f => tag & 0x0f,
            0xdc => std.math.cast(usize, try deserializer.readBig(u16)) orelse error.LengthMismatch,
            0xdd => std.math.cast(usize, try deserializer.readBig(u32)) orelse error.LengthMismatch,
            else => error.UnexpectedType,
        },
        .map => switch (tag) {
            0x80...0x8f => tag & 0x0f,
            0xde => std.math.cast(usize, try deserializer.readBig(u16)) orelse error.LengthMismatch,
            0xdf => std.math.cast(usize, try deserializer.readBig(u32)) orelse error.LengthMismatch,
            else => error.UnexpectedType,
        },
        else => error.UnexpectedType,
    };
}

pub fn serialize(writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(writer, value, .{}, .{});
}

pub fn serializeWith(
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try typed.serialize(@This(), writer, value, serde_cfg, format_cfg);
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
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSliceAliased(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceAliasedWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceAliasedWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, .{
        .max_input_bytes = effectiveMaxInputBytes(read_cfg),
        .borrow_strings = true,
    });
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

fn writeInt(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value >= 0) {
                const unsigned = std.math.cast(u64, value) orelse return error.IntegerOverflow;
                try writeUnsigned(writer, unsigned);
            } else {
                const signed = std.math.cast(i64, value) orelse return error.IntegerOverflow;
                try writeSigned(writer, signed);
            }
        },
        .int => |info| {
            if (info.signedness == .unsigned) {
                try writeUnsigned(writer, std.math.cast(u64, value) orelse return error.IntegerOverflow);
            } else {
                try writeSigned(writer, std.math.cast(i64, value) orelse return error.IntegerOverflow);
            }
        },
        else => return error.UnsupportedType,
    }
}

fn writeUnsigned(writer: *std.Io.Writer, value: u64) !void {
    switch (value) {
        0...0x7f => try writer.writeByte(@as(u8, @intCast(value))),
        0x80...0xff => {
            try writer.writeByte(0xcc);
            try writer.writeByte(@as(u8, @intCast(value)));
        },
        0x0100...0xffff => {
            try writer.writeByte(0xcd);
            try writeBigEndian(writer, @as(u16, @intCast(value)));
        },
        0x0001_0000...0xffff_ffff => {
            try writer.writeByte(0xce);
            try writeBigEndian(writer, @as(u32, @intCast(value)));
        },
        else => {
            try writer.writeByte(0xcf);
            try writeBigEndian(writer, value);
        },
    }
}

fn writeSigned(writer: *std.Io.Writer, value: i64) !void {
    if (value >= 0) return writeUnsigned(writer, @as(u64, @intCast(value)));
    if (value >= -32) {
        try writer.writeByte(@as(u8, @bitCast(@as(i8, @intCast(value)))));
        return;
    }
    if (value >= std.math.minInt(i8) and value <= std.math.maxInt(i8)) {
        try writer.writeByte(0xd0);
        try writer.writeByte(@as(u8, @bitCast(@as(i8, @intCast(value)))));
        return;
    }
    if (value >= std.math.minInt(i16) and value <= std.math.maxInt(i16)) {
        try writer.writeByte(0xd1);
        try writeBigEndian(writer, @as(u16, @bitCast(@as(i16, @intCast(value)))));
        return;
    }
    if (value >= std.math.minInt(i32) and value <= std.math.maxInt(i32)) {
        try writer.writeByte(0xd2);
        try writeBigEndian(writer, @as(u32, @bitCast(@as(i32, @intCast(value)))));
        return;
    }
    try writer.writeByte(0xd3);
    try writeBigEndian(writer, @as(u64, @bitCast(value)));
}

fn writeFloat(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_float => {
            try writer.writeByte(0xcb);
            try writeBigEndian(writer, @as(u64, @bitCast(@as(f64, value))));
        },
        .float => |info| switch (info.bits) {
            16, 32 => {
                try writer.writeByte(0xca);
                try writeBigEndian(writer, @as(u32, @bitCast(@as(f32, @floatCast(value)))));
            },
            64 => {
                try writer.writeByte(0xcb);
                try writeBigEndian(writer, @as(u64, @bitCast(value)));
            },
            else => return error.UnsupportedType,
        },
        else => return error.UnsupportedType,
    }
}

fn writeStrHeader(writer: *std.Io.Writer, len: usize) !void {
    switch (len) {
        0...31 => try writer.writeByte(0xa0 | @as(u8, @intCast(len))),
        32...0xff => {
            try writer.writeByte(0xd9);
            try writer.writeByte(@as(u8, @intCast(len)));
        },
        0x0100...0xffff => {
            try writer.writeByte(0xda);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        else => {
            try writer.writeByte(0xdb);
            try writeBigEndian(writer, @as(u32, @intCast(std.math.cast(u32, len) orelse return error.LengthMismatch)));
        },
    }
}

fn writeBinHeader(writer: *std.Io.Writer, len: usize) !void {
    switch (len) {
        0...0xff => {
            try writer.writeByte(0xc4);
            try writer.writeByte(@as(u8, @intCast(len)));
        },
        0x0100...0xffff => {
            try writer.writeByte(0xc5);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        else => {
            try writer.writeByte(0xc6);
            try writeBigEndian(writer, @as(u32, @intCast(std.math.cast(u32, len) orelse return error.LengthMismatch)));
        },
    }
}

fn writeArrayHeader(writer: *std.Io.Writer, len: usize) !void {
    switch (len) {
        0...15 => try writer.writeByte(0x90 | @as(u8, @intCast(len))),
        16...0xffff => {
            try writer.writeByte(0xdc);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        else => {
            try writer.writeByte(0xdd);
            try writeBigEndian(writer, @as(u32, @intCast(std.math.cast(u32, len) orelse return error.LengthMismatch)));
        },
    }
}

fn writeMapHeader(writer: *std.Io.Writer, len: usize) !void {
    switch (len) {
        0...15 => try writer.writeByte(0x80 | @as(u8, @intCast(len))),
        16...0xffff => {
            try writer.writeByte(0xde);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        else => {
            try writer.writeByte(0xdf);
            try writeBigEndian(writer, @as(u32, @intCast(std.math.cast(u32, len) orelse return error.LengthMismatch)));
        },
    }
}

fn writeBigEndian(writer: *std.Io.Writer, value: anytype) !void {
    var buffer: [@sizeOf(@TypeOf(value))]u8 = undefined;
    std.mem.writeInt(@TypeOf(value), &buffer, value, .big);
    try writer.writeAll(&buffer);
}

fn castIntValue(comptime T: type, raw: i128) !T {
    return switch (@typeInfo(T)) {
        .comptime_int => @as(T, std.math.cast(i64, raw) orelse return error.IntegerOverflow),
        .int => std.math.cast(T, raw) orelse error.IntegerOverflow,
        else => error.UnsupportedType,
    };
}

fn castFloatToInt(comptime T: type, raw: f64) !T {
    const rounded = @round(raw);
    if (rounded != raw) return error.UnexpectedType;
    return castIntValue(T, @as(i128, @intFromFloat(rounded)));
}

fn encodeFieldName(comptime name: []const u8) [fieldNameEncodedLen(name)]u8 {
    var buffer: [fieldNameEncodedLen(name)]u8 = undefined;
    const header_len = fieldHeaderLen(name.len);

    switch (header_len) {
        1 => buffer[0] = 0xa0 | @as(u8, @intCast(name.len)),
        2 => {
            buffer[0] = 0xd9;
            buffer[1] = @as(u8, @intCast(name.len));
        },
        3 => {
            buffer[0] = 0xda;
            std.mem.writeInt(u16, buffer[1..3], @as(u16, @intCast(name.len)), .big);
        },
        5 => {
            buffer[0] = 0xdb;
            std.mem.writeInt(u32, buffer[1..5], @as(u32, @intCast(name.len)), .big);
        },
        else => unreachable,
    }

    @memcpy(buffer[header_len..], name);
    return buffer;
}

fn fieldHeaderLen(len: usize) comptime_int {
    return switch (len) {
        0...31 => 1,
        32...0xff => 2,
        0x0100...0xffff => 3,
        else => 5,
    };
}

fn fieldNameEncodedLen(comptime name: []const u8) comptime_int {
    return fieldHeaderLen(name.len) + name.len;
}

fn isInlineSequenceType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |info| info.child != u8 and isInlineSequenceElementType(info.child),
        .pointer => |info| switch (info.size) {
            .slice => info.child != u8 and isInlineSequenceElementType(info.child),
            else => false,
        },
        else => false,
    };
}

fn isInlineSequenceElementType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => true,
        .optional => |info| isInlineSequenceElementType(info.child),
        .array => |info| info.child == u8 or isInlineSequenceType(T),
        .pointer => |info| switch (info.size) {
            .slice => info.child == u8 or isInlineSequenceType(T),
            .one => isInlineSequenceElementType(info.child),
            else => false,
        },
        else => false,
    };
}

fn writeInlineSequence(ser: anytype, comptime Sequence: type, value: Sequence) !void {
    const len = switch (@typeInfo(Sequence)) {
        .array => value.len,
        .pointer => value.len,
        else => @compileError("unsupported MessagePack sequence type: " ++ @typeName(Sequence)),
    };

    try writeArrayHeader(ser.writer, len);
    for (value) |item| {
        const written = try ser.writeInlineValue(@TypeOf(item), item);
        if (!written) return error.UnsupportedType;
    }
}

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return (ReadConfig{}).max_input_bytes;
}

fn effectiveBorrowStrings(comptime cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "borrow_strings")) return @field(cfg, "borrow_strings");
    return false;
}

test "serialize and parse struct to msgpack" {
    const Example = struct {
        firstName: []const u8,
        active: bool,
        kind: enum {
            admin,
            member,
        },
        note: ?[]const u8,
        samples: [3]u16,
        metadata: struct {
            accountId: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Ada",
        .active = true,
        .kind = .admin,
        .note = null,
        .samples = .{ 3, 5, 8 },
        .metadata = .{
            .accountId = 42,
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, expected, .{
        .rename_all = .snake_case,
    }, .{});

    const decoded = try parseSliceWith(Example, std.testing.allocator, out.written(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "parseSliceAliased reuses msgpack string bytes from input" {
    const Example = struct {
        message: []const u8,
    };

    const input = [_]u8{
        0x81,
        0xa7,
        'm',
        'e',
        's',
        's',
        'a',
        'g',
        'e',
        0xa2,
        'o',
        'k',
    };

    const decoded = try parseSliceAliased(Example, std.testing.allocator, &input);
    try std.testing.expectEqualStrings("ok", decoded.message);

    const begin = @intFromPtr(input[0..].ptr);
    const end = begin + input.len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr >= begin and ptr < end);
}

test "parse msgpack bin into fixed byte array" {
    const Example = struct {
        payload: [3]u8,
    };

    const input = [_]u8{
        0x81,
        0xa7,
        'p',
        'a',
        'y',
        'l',
        'o',
        'a',
        'd',
        0xc4,
        0x03,
        0x01,
        0x02,
        0x03,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    try std.testing.expectEqualDeep([_]u8{ 0x01, 0x02, 0x03 }, decoded.payload);
}

test "reader deserialize reads from fixed msgpack input" {
    const Example = struct {
        name: []const u8,
        count: u16,
    };

    const input = [_]u8{
        0x82,
        0xa4,
        'n',
        'a',
        'm',
        'e',
        0xa3,
        'A',
        'd',
        'a',
        0xa5,
        'c',
        'o',
        'u',
        'n',
        't',
        0x2a,
    };

    var reader = std.Io.Reader.fixed(&input);
    const decoded = try deserialize(Example, std.testing.allocator, &reader);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqual(@as(u16, 42), decoded.count);
}
