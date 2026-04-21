//! CBOR backend for the typed walk.
//!
//! This backend writes arrays with definite lengths and structs as indefinite
//! maps so field omission stays cheap. Text fields default to CBOR text strings;
//! the read path also accepts byte strings for `[]const u8` to stay interoperable
//! with common CBOR producers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const Number = typed.Number;
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
    indefinite: bool,
    remaining: usize,
};

const Header = struct {
    major: u8,
    ai: u8,
    value: u64,
    indefinite: bool,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) CborSerializer(@TypeOf(cfg)) {
    return CborSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !CborDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return CborDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !CborDeserializer(@TypeOf(cfg)) {
    _ = allocator;
    return CborDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

pub fn CborSerializer(comptime Config: type) type {
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
            try self.writer.writeByte(0xf6);
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.writer.writeByte(if (value) 0xf5 else 0xf4);
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try writeInt(self.writer, value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try writeFloat(self.writer, value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeTextString(self.writer, value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try writeTextString(self.writer, @tagName(value));
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;
            try self.writer.writeByte(0xbf);
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
            try writeTextString(self.writer, name);
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = T;
            try self.writer.writeByte(0xff);
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            try writeMajorValue(self.writer, 4, len);
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
    };
}

pub fn CborDeserializer(comptime Config: type) type {
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
            if (self.index != self.input.len) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            const header = try self.peekResolvedHeader();
            return switch (header.major) {
                0, 1 => .number,
                2, 3 => .string,
                4 => .array,
                5 => .object,
                7 => switch (header.ai) {
                    20, 21 => .bool,
                    22 => .null,
                    25, 26, 27 => .number,
                    else => error.UnexpectedToken,
                },
                else => error.UnexpectedToken,
            };
        }

        pub fn readNull(self: *Self) !void {
            const header = try self.readResolvedHeader();
            if (header.major != 7) return error.UnexpectedType;
            if (header.ai != 22) return error.UnexpectedType;
        }

        pub fn readBool(self: *Self) !bool {
            const header = try self.readResolvedHeader();
            if (header.major != 7) return error.UnexpectedType;
            return switch (header.ai) {
                20 => false,
                21 => true,
                else => error.UnexpectedType,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            const header = try self.readResolvedHeader();
            return switch (header.major) {
                0 => .{ .integer = @as(i128, @intCast(header.value)) },
                1 => .{ .integer = -@as(i128, @intCast(header.value)) - 1 },
                7 => switch (header.ai) {
                    25 => .{ .float = @as(f64, @floatCast(@as(f16, @bitCast(@as(u16, @intCast(header.value)))))) },
                    26 => .{ .float = @as(f64, @floatCast(@as(f32, @bitCast(@as(u32, @intCast(header.value)))))) },
                    27 => .{ .float = @as(f64, @bitCast(header.value)) },
                    else => error.UnexpectedType,
                },
                else => error.UnexpectedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            const header = try self.readResolvedHeader();
            if (header.major != 2 and header.major != 3) return error.UnexpectedType;
            if (header.indefinite) return error.UnsupportedIndefiniteString;

            const len = std.math.cast(usize, header.value) orelse return error.LengthMismatch;
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

        pub fn beginArray(self: *Self) !void {
            const header = try self.readResolvedHeader();
            if (header.major != 4) return error.UnexpectedType;
            try self.push(.{
                .kind = .array,
                .indefinite = header.indefinite,
                .remaining = if (header.indefinite) 0 else std.math.cast(usize, header.value) orelse return error.LengthMismatch,
            });
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            const header = try self.readResolvedHeader();
            if (header.major != 4) return error.UnexpectedType;
            const len = if (header.indefinite) null else std.math.cast(usize, header.value) orelse return error.LengthMismatch;
            try self.push(.{
                .kind = .array,
                .indefinite = header.indefinite,
                .remaining = len orelse 0,
            });
            return len;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidCborState;

            if (frame.indefinite) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    _ = self.pop();
                    return false;
                }
                return true;
            }

            if (frame.remaining == 0) {
                _ = self.pop();
                return false;
            }

            frame.remaining -= 1;
            return true;
        }

        pub fn beginObject(self: *Self) !void {
            const header = try self.readResolvedHeader();
            if (header.major != 5) return error.UnexpectedType;
            try self.push(.{
                .kind = .object,
                .indefinite = header.indefinite,
                .remaining = if (header.indefinite) 0 else std.math.cast(usize, header.value) orelse return error.LengthMismatch,
            });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidCborState;

            if (frame.indefinite) {
                if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.index] == 0xff) {
                    self.index += 1;
                    _ = self.pop();
                    return null;
                }
            } else {
                if (frame.remaining == 0) {
                    _ = self.pop();
                    return null;
                }
                frame.remaining -= 1;
            }

            return try self.readString(allocator);
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = allocator;
            try self.skipOne();
        }

        fn peekResolvedHeader(self: *Self) !Header {
            var cursor = self.index;
            return self.readResolvedHeaderAt(&cursor);
        }

        fn readResolvedHeader(self: *Self) !Header {
            return self.readResolvedHeaderAt(&self.index);
        }

        fn readResolvedHeaderAt(self: *Self, cursor: *usize) !Header {
            while (true) {
                const header = try parseHeader(self.input, cursor);
                if (header.major != 6) return header;
            }
        }

        fn skipOne(self: *Self) !void {
            const header = try parseHeader(self.input, &self.index);
            switch (header.major) {
                0, 1 => {},
                2, 3 => {
                    if (header.indefinite) return error.UnsupportedIndefiniteString;
                    const len = std.math.cast(usize, header.value) orelse return error.LengthMismatch;
                    if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
                    self.index += len;
                },
                4 => {
                    if (header.indefinite) {
                        while (true) {
                            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                            if (self.input[self.index] == 0xff) {
                                self.index += 1;
                                break;
                            }
                            try self.skipOne();
                        }
                    } else {
                        const len = std.math.cast(usize, header.value) orelse return error.LengthMismatch;
                        for (0..len) |_| {
                            try self.skipOne();
                        }
                    }
                },
                5 => {
                    if (header.indefinite) {
                        while (true) {
                            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
                            if (self.input[self.index] == 0xff) {
                                self.index += 1;
                                break;
                            }
                            try self.skipOne();
                            try self.skipOne();
                        }
                    } else {
                        const len = std.math.cast(usize, header.value) orelse return error.LengthMismatch;
                        for (0..len) |_| {
                            try self.skipOne();
                            try self.skipOne();
                        }
                    }
                },
                6 => try self.skipOne(),
                7 => {
                    if (header.ai == 31) return error.StandAloneBreakCode;
                },
                else => return error.UnexpectedToken,
            }
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.CborNestingTooDeep;
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

fn parseHeader(input: []const u8, cursor: *usize) !Header {
    if (cursor.* >= input.len) return error.UnexpectedEndOfInput;

    const initial = input[cursor.*];
    cursor.* += 1;

    const major = initial >> 5;
    const ai = initial & 0x1f;

    return switch (ai) {
        0...23 => .{
            .major = major,
            .ai = ai,
            .value = ai,
            .indefinite = false,
        },
        24 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 1),
            .indefinite = false,
        },
        25 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 2),
            .indefinite = false,
        },
        26 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 4),
            .indefinite = false,
        },
        27 => .{
            .major = major,
            .ai = ai,
            .value = try readSizedUnsigned(input, cursor, 8),
            .indefinite = false,
        },
        28, 29, 30 => error.InvalidAdditionalInfo,
        31 => switch (major) {
            2, 3, 4, 5 => .{
                .major = major,
                .ai = ai,
                .value = 0,
                .indefinite = true,
            },
            else => error.InvalidAdditionalInfo,
        },
        else => unreachable,
    };
}

fn readSizedUnsigned(input: []const u8, cursor: *usize, byte_count: usize) !u64 {
    if (input.len - cursor.* < byte_count) return error.UnexpectedEndOfInput;

    var value: u64 = 0;
    for (input[cursor.* .. cursor.* + byte_count]) |byte| {
        value = (value << 8) | byte;
    }
    cursor.* += byte_count;
    return value;
}

fn writeInt(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value >= 0) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else {
                const adjusted = std.math.cast(u64, -value - 1) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 1, adjusted);
            }
        },
        .int => |info| {
            if (info.signedness == .unsigned) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else if (value >= 0) {
                const unsigned = std.math.cast(u64, value) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 0, unsigned);
            } else {
                const adjusted = std.math.cast(u64, -@as(i128, @intCast(value)) - 1) orelse return error.CborIntegerOutOfRange;
                try writeMajorValue(writer, 1, adjusted);
            }
        },
        else => return error.UnsupportedType,
    }
}

fn writeFloat(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_float => try writeFloat(writer, @as(f64, value)),
        .float => |info| switch (info.bits) {
            16 => {
                try writer.writeByte(0xf9);
                try writeBigEndian(writer, @as(u16, @bitCast(value)));
            },
            32 => {
                try writer.writeByte(0xfa);
                try writeBigEndian(writer, @as(u32, @bitCast(value)));
            },
            64 => {
                try writer.writeByte(0xfb);
                try writeBigEndian(writer, @as(u64, @bitCast(value)));
            },
            else => return error.UnsupportedType,
        },
        else => return error.UnsupportedType,
    }
}

fn writeTextString(writer: *std.Io.Writer, value: []const u8) !void {
    try writeMajorValue(writer, 3, value.len);
    try writer.writeAll(value);
}

fn writeMajorValue(writer: *std.Io.Writer, major: u8, value: anytype) !void {
    const len = std.math.cast(u64, value) orelse return error.LengthMismatch;
    const head = major << 5;
    switch (len) {
        0...23 => try writer.writeByte(head | @as(u8, @intCast(len))),
        24...0xff => {
            try writer.writeByte(head | 24);
            try writer.writeByte(@as(u8, @intCast(len)));
        },
        0x0100...0xffff => {
            try writer.writeByte(head | 25);
            try writeBigEndian(writer, @as(u16, @intCast(len)));
        },
        0x0001_0000...0xffff_ffff => {
            try writer.writeByte(head | 26);
            try writeBigEndian(writer, @as(u32, @intCast(len)));
        },
        else => {
            try writer.writeByte(head | 27);
            try writeBigEndian(writer, len);
        },
    }
}

fn writeBigEndian(writer: *std.Io.Writer, value: anytype) !void {
    var buffer: [@sizeOf(@TypeOf(value))]u8 = undefined;
    inline for (0..buffer.len) |index| {
        const shift = (buffer.len - 1 - index) * 8;
        buffer[index] = @as(u8, @truncate(value >> shift));
    }
    try writer.writeAll(&buffer);
}

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return (ReadConfig{}).max_input_bytes;
}

fn effectiveBorrowStrings(comptime cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "borrow_strings")) return @field(cfg, "borrow_strings");
    return false;
}

test "serialize and parse struct to cbor" {
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

test "parseSliceAliased reuses cbor string bytes from input" {
    const Example = struct {
        message: []const u8,
    };

    const input = [_]u8{
        0xa1,
        0x67,
        'm',
        'e',
        's',
        's',
        'a',
        'g',
        'e',
        0x62,
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

test "parse definite cbor map with snake_case fields" {
    const Example = struct {
        firstName: []const u8,
        port: u16,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const input = [_]u8{
        0xa2,
        0x6a,
        'f',
        'i',
        'r',
        's',
        't',
        '_',
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x64,
        'p',
        'o',
        'r',
        't',
        0x19,
        0x1f,
        0x90,
    };

    const decoded = try parseSliceWith(Example, std.testing.allocator, &input, .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
}

test "parse cbor byte string into fixed byte array" {
    const Example = struct {
        payload: [3]u8,
    };

    const input = [_]u8{
        0xa1,
        0x67,
        'p',
        'a',
        'y',
        'l',
        'o',
        'a',
        'd',
        0x43,
        0x01,
        0x02,
        0x03,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    try std.testing.expectEqualDeep([_]u8{ 0x01, 0x02, 0x03 }, decoded.payload);
}

test "parse indefinite cbor map and array" {
    const Example = struct {
        name: []const u8,
        samples: []const u16,
    };

    const input = [_]u8{
        0xbf,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x67,
        's',
        'a',
        'm',
        'p',
        'l',
        'e',
        's',
        0x9f,
        0x01,
        0x02,
        0x03,
        0xff,
        0xff,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqualSlices(u16, &.{ 1, 2, 3 }, decoded.samples);
}

test "reader deserialize reads from a fixed CBOR input" {
    const Example = struct {
        name: []const u8,
        count: u16,
    };

    const input = [_]u8{
        0xa2,
        0x64,
        'n',
        'a',
        'm',
        'e',
        0x63,
        'A',
        'd',
        'a',
        0x65,
        'c',
        'o',
        'u',
        'n',
        't',
        0x18,
        0x2a,
    };

    var reader = std.Io.Reader.fixed(&input);
    const decoded = try deserialize(Example, std.testing.allocator, &reader);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqual(@as(u16, 42), decoded.count);
}

test "simple value 23 is not treated as cbor null" {
    var deserializer = try sliceDeserializer(std.testing.allocator, &.{0xf7}, .{});
    try std.testing.expectError(error.UnexpectedToken, deserializer.peekKind());
}

test "indefinite length is rejected for invalid major types" {
    try std.testing.expectError(
        error.InvalidAdditionalInfo,
        parseSlice(u8, std.testing.allocator, &.{0x1f}),
    );
}
