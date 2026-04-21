//! Compact schema-driven binary backend.
//!
//! Unlike the self-describing text and document formats, `zerde.bin` relies on
//! the caller's `T` as the schema. Struct fields are encoded in declaration
//! order, optionals use a one-byte presence marker, integers use varint
//! encoding, and strings/byte slices are length-prefixed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const StringToken = typed.StringToken;

pub const FieldCase = meta.FieldCase;
pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
    borrow_strings: bool = false,
};
pub const WriteConfig = struct {};
pub const ParseError = anyerror;

const ArrayFrame = struct {
    remaining: usize,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) BinSerializer(@TypeOf(cfg)) {
    return BinSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !BinDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return BinDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !BinDeserializer(@TypeOf(cfg)) {
    _ = allocator;
    return BinDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

pub fn BinSerializer(comptime Config: type) type {
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
            try self.writer.writeByte(0x00);
        }

        pub fn beginOptional(self: *Self, present: bool) !void {
            try self.writer.writeByte(if (present) 0x01 else 0x00);
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.writer.writeByte(if (value) 0x01 else 0x00);
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try writeInteger(self.writer, value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try writeFloat(self.writer, value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeVarUInt(self.writer, value.len);
            try self.writer.writeAll(value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            try self.emitString(value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try self.emitInteger(@intFromEnum(value));
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
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
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
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
            try writeVarUInt(self.writer, len);
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

pub fn BinDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        index: usize = 0,
        owns_input: bool,
        can_borrow_strings: bool,
        array_stack: [128]ArrayFrame = undefined,
        array_stack_len: usize = 0,

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
            if (self.array_stack_len != 0) return error.InvalidBinaryState;
            if (self.index != self.input.len) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn errorOffset(self: *Self) usize {
            return self.index;
        }

        pub fn readOptionalPresent(self: *Self) !bool {
            return switch (try self.readByte()) {
                0x00 => false,
                0x01 => true,
                else => error.InvalidOptionalTag,
            };
        }

        pub fn readBool(self: *Self) !bool {
            return switch (try self.readByte()) {
                0x00 => false,
                0x01 => true,
                else => error.UnexpectedType,
            };
        }

        pub fn readInt(self: *Self, comptime T: type) !T {
            return switch (@typeInfo(T)) {
                .comptime_int => blk: {
                    const value = try self.readInt(i64);
                    break :blk value;
                },
                .int => |info| blk: {
                    if (info.signedness == .unsigned) {
                        const value = try self.readVarUInt();
                        break :blk std.math.cast(T, value) orelse error.IntegerOverflow;
                    }

                    const value = try self.readVarInt();
                    break :blk std.math.cast(T, value) orelse error.IntegerOverflow;
                },
                else => error.UnsupportedType,
            };
        }

        pub fn readFloat(self: *Self, comptime T: type) !T {
            return switch (@typeInfo(T)) {
                .comptime_float => @as(T, @floatCast(try self.readFloat(f64))),
                .float => |info| switch (info.bits) {
                    16 => @as(T, @bitCast(try self.readLittle(u16))),
                    32 => @as(T, @bitCast(try self.readLittle(u32))),
                    64 => @as(T, @bitCast(try self.readLittle(u64))),
                    else => error.UnsupportedType,
                },
                else => error.UnsupportedType,
            };
        }

        pub fn readEnumTag(self: *Self, comptime T: type) !T {
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const raw = try self.readInt(tag_type);
            return std.enums.fromInt(T, raw) orelse error.InvalidEnumTag;
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            return try self.readLengthPrefixedBytes(allocator);
        }

        pub fn readByteToken(self: *Self, allocator: Allocator) !StringToken {
            return try self.readLengthPrefixedBytes(allocator);
        }

        pub fn beginArray(self: *Self) !void {
            if (self.array_stack_len == self.array_stack.len) return error.BinaryNestingTooDeep;
            self.array_stack[self.array_stack_len] = .{ .remaining = try self.readVarUInt() };
            self.array_stack_len += 1;
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            const len = try self.readVarUInt();
            if (self.array_stack_len == self.array_stack.len) return error.BinaryNestingTooDeep;
            self.array_stack[self.array_stack_len] = .{ .remaining = len };
            self.array_stack_len += 1;
            return len;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.currentArray();
            if (frame.remaining == 0) {
                self.array_stack_len -= 1;
                return false;
            }
            frame.remaining -= 1;
            return true;
        }

        pub fn finishKnownLenArray(self: *Self) !void {
            if (self.array_stack_len == 0) return error.InvalidBinaryState;
            self.array_stack_len -= 1;
        }

        pub fn beginStructOrdered(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
        }

        pub fn endStructOrdered(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
        }

        fn readLengthPrefixedBytes(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            const len = try self.readVarUInt();
            if (self.input.len - self.index < len) return error.UnexpectedEndOfInput;
            const bytes = self.input[self.index .. self.index + len];
            self.index += len;

            return .{
                .bytes = bytes,
                .allocated = false,
            };
        }

        fn readVarUInt(self: *Self) !usize {
            var shift: u6 = 0;
            var value: u64 = 0;

            while (true) {
                const byte = try self.readByte();
                value |= @as(u64, byte & 0x7f) << shift;
                if ((byte & 0x80) == 0) break;
                if (shift >= 63) return error.IntegerOverflow;
                shift += 7;
            }

            return std.math.cast(usize, value) orelse error.IntegerOverflow;
        }

        fn readVarInt(self: *Self) !i64 {
            const zigzag = try self.readVarUInt();
            if ((zigzag & 1) == 0) {
                return std.math.cast(i64, zigzag >> 1) orelse error.IntegerOverflow;
            }

            const magnitude = (zigzag >> 1) + 1;
            const positive = std.math.cast(i64, magnitude) orelse return error.IntegerOverflow;
            return -positive;
        }

        fn readByte(self: *Self) !u8 {
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            const byte = self.input[self.index];
            self.index += 1;
            return byte;
        }

        fn readLittle(self: *Self, comptime T: type) !T {
            var buffer: [@sizeOf(T)]u8 = undefined;
            if (self.input.len - self.index < buffer.len) return error.UnexpectedEndOfInput;
            @memcpy(&buffer, self.input[self.index .. self.index + buffer.len]);
            self.index += buffer.len;
            return std.mem.readInt(T, &buffer, .little);
        }

        fn currentArray(self: *Self) *ArrayFrame {
            return &self.array_stack[self.array_stack_len - 1];
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

fn writeInteger(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (value >= 0) {
                try writeVarUInt(writer, std.math.cast(usize, value) orelse return error.IntegerOverflow);
            } else {
                try writeVarInt(writer, std.math.cast(i64, value) orelse return error.IntegerOverflow);
            }
        },
        .int => |info| {
            if (info.signedness == .unsigned) {
                try writeVarUInt(writer, std.math.cast(usize, value) orelse return error.IntegerOverflow);
            } else {
                try writeVarInt(writer, std.math.cast(i64, value) orelse return error.IntegerOverflow);
            }
        },
        else => return error.UnsupportedType,
    }
}

fn writeFloat(writer: *std.Io.Writer, value: anytype) !void {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_float => try writeLittle(writer, @as(u64, @bitCast(@as(f64, value)))),
        .float => |info| switch (info.bits) {
            16 => try writeLittle(writer, @as(u16, @bitCast(value))),
            32 => try writeLittle(writer, @as(u32, @bitCast(value))),
            64 => try writeLittle(writer, @as(u64, @bitCast(value))),
            else => return error.UnsupportedType,
        },
        else => return error.UnsupportedType,
    }
}

fn writeVarUInt(writer: *std.Io.Writer, value: usize) !void {
    var current: u64 = @intCast(value);
    while (true) {
        var byte: u8 = @truncate(current & 0x7f);
        current >>= 7;
        if (current != 0) byte |= 0x80;
        try writer.writeByte(byte);
        if (current == 0) break;
    }
}

fn writeVarInt(writer: *std.Io.Writer, value: i64) !void {
    const zigzag: u64 = @bitCast((value << 1) ^ (value >> 63));
    try writeVarUInt(writer, std.math.cast(usize, zigzag) orelse return error.IntegerOverflow);
}

fn writeLittle(writer: *std.Io.Writer, value: anytype) !void {
    const Int = @TypeOf(value);
    var buffer: [@sizeOf(Int)]u8 = undefined;
    inline for (0..buffer.len) |index| {
        buffer[index] = @as(u8, @truncate(value >> @as(std.math.Log2Int(Int), @intCast(index * 8))));
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

test "serialize and parse struct to binary" {
    const Example = struct {
        first_name: []const u8,
        active: bool,
        kind: enum(u8) {
            admin,
            member,
        },
        note: ?[]const u8,
        samples: [3]u16,
        metadata: struct {
            account_id: u64,
        },
    };

    const expected = Example{
        .first_name = "Ada",
        .active = true,
        .kind = .admin,
        .note = null,
        .samples = .{ 3, 5, 8 },
        .metadata = .{
            .account_id = 42,
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(&out.writer, expected);

    const decoded = try parseSlice(Example, std.testing.allocator, out.written());
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "parseSliceAliased reuses binary string bytes from input" {
    const Example = struct {
        message: []const u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(&out.writer, Example{ .message = "Nami" });

    const decoded = try parseSliceAliased(Example, std.testing.allocator, out.written());
    try std.testing.expectEqualStrings("Nami", decoded.message);

    const begin = @intFromPtr(out.written().ptr);
    const end = begin + out.written().len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr >= begin and ptr < end);
}

test "parseSlice keeps binary strings owned at the typed edge" {
    const Example = struct {
        message: []const u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(&out.writer, Example{ .message = "Nami" });

    const decoded = try parseSlice(Example, std.testing.allocator, out.written());
    defer typed.free(std.testing.allocator, decoded);
    try std.testing.expectEqualStrings("Nami", decoded.message);

    const begin = @intFromPtr(out.written().ptr);
    const end = begin + out.written().len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr < begin or ptr >= end);
}
