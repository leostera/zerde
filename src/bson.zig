//! BSON backend for the typed walk.
//!
//! BSON is a document format, so `zerde.bson` is optimized around typed root
//! structs and nested arrays/documents. Scalar roots are intentionally rejected;
//! nested scalar values still flow directly through the generic typed walker.

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
    object,
    array,
};

const ElementSlot = union(enum) {
    root,
    field: []const u8,
    array_index: usize,
};

const Frame = struct {
    kind: ContainerKind,
    start: usize,
    is_root: bool,
};

const ReaderFrame = struct {
    kind: ContainerKind,
    end: usize,
};

const BsonType = enum(u8) {
    double = 0x01,
    string = 0x02,
    document = 0x03,
    array = 0x04,
    binary = 0x05,
    bool = 0x08,
    null = 0x0A,
    int32 = 0x10,
    int64 = 0x12,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) BsonSerializer(@TypeOf(cfg)) {
    return BsonSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !BsonDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return BsonDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !BsonDeserializer(@TypeOf(cfg)) {
    _ = allocator;
    return BsonDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

pub fn BsonSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        pending_slot: ?ElementSlot = null,
        buffer: std.ArrayListUnmanaged(u8) = .empty,
        stack: [128]Frame = undefined,
        stack_len: usize = 0,

        const Self = @This();
        const allocator = std.heap.page_allocator;

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self.cfg;
            self.buffer.deinit(allocator);
        }

        pub fn emitNull(self: *Self) !void {
            try self.appendScalar(.null, &.{});
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.appendScalar(.bool, &.{if (value) 0x01 else 0x00});
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            var payload: [8]u8 = undefined;
            const encoded = try encodeInteger(&payload, value);
            try self.appendScalar(encoded.tag, encoded.bytes);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            var payload: [8]u8 = undefined;
            appendLittleEndian(&payload, @as(u64, @bitCast(@as(f64, switch (@typeInfo(@TypeOf(value))) {
                .comptime_float => value,
                .float => @as(f64, @floatCast(value)),
                else => return error.UnsupportedType,
            }))));
            try self.appendScalar(.double, &payload);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            if (self.stack_len == 0) return error.BsonRootMustBeDocument;
            const slot = self.takePendingSlot() orelse return error.InvalidBsonState;
            try appendElementHeader(&self.buffer, .string, slot);
            try appendBsonString(&self.buffer, value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            if (self.stack_len == 0) return error.BsonRootMustBeDocument;
            const slot = self.takePendingSlot() orelse return error.InvalidBsonState;
            try appendElementHeader(&self.buffer, .binary, slot);
            try appendInt32Payload(&self.buffer, value.len);
            try self.buffer.append(allocator, 0x00);
            try self.buffer.appendSlice(allocator, value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try self.emitString(@tagName(value));
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;
            const start = if (self.stack_len == 0) blk: {
                try self.buffer.appendNTimes(allocator, 0x00, 4);
                break :blk @as(usize, 0);
            } else blk: {
                const slot = self.takePendingSlot() orelse return error.InvalidBsonState;
                try appendElementHeader(&self.buffer, .document, slot);
                const child_start = self.buffer.items.len;
                try self.buffer.appendNTimes(allocator, 0x00, 4);
                break :blk child_start;
            };
            try self.push(.{
                .kind = .object,
                .start = start,
                .is_root = self.stack_len == 0,
            });
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
            self.pending_slot = .{ .field = name };
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
            const frame = self.pop();
            if (frame.kind != .object) return error.InvalidBsonState;
            try self.finishFrame(frame);
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            if (self.stack_len == 0) return error.BsonRootMustBeDocument;
            const slot = self.takePendingSlot() orelse return error.InvalidBsonState;
            try appendElementHeader(&self.buffer, .array, slot);
            const start = self.buffer.items.len;
            try self.buffer.appendNTimes(allocator, 0x00, 4);
            try self.push(.{
                .kind = .array,
                .start = start,
                .is_root = false,
            });
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = Child;
            if (self.stack_len == 0 or self.current().kind != .array) return error.InvalidBsonState;
            self.pending_slot = .{ .array_index = index };
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            const frame = self.pop();
            if (frame.kind != .array) return error.InvalidBsonState;
            try self.finishFrame(frame);
        }

        fn appendScalar(self: *Self, tag: BsonType, payload: []const u8) !void {
            if (self.stack_len == 0) return error.BsonRootMustBeDocument;
            const slot = self.takePendingSlot() orelse return error.InvalidBsonState;
            try appendElementToBuffer(&self.buffer, tag, slot, payload);
        }

        fn finishFrame(self: *Self, frame: Frame) !void {
            try self.buffer.append(allocator, 0x00);
            writeInt32Prefix(self.buffer.items[frame.start .. frame.start + 4], self.buffer.items.len - frame.start);

            if (frame.is_root) {
                try self.writer.writeAll(self.buffer.items);
                self.buffer.clearRetainingCapacity();
            }
        }

        fn takePendingSlot(self: *Self) ?ElementSlot {
            const slot = self.pending_slot;
            self.pending_slot = null;
            return slot;
        }

        fn push(self: *Self, frame: Frame) !void {
            if (self.stack_len == self.stack.len) return error.BsonNestingTooDeep;
            self.stack[self.stack_len] = frame;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Frame {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Frame {
            return &self.stack[self.stack_len - 1];
        }
    };
}

pub fn BsonDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        index: usize = 0,
        owns_input: bool,
        can_borrow_strings: bool,
        pending_type: ?BsonType = null,
        stack: [128]ReaderFrame = undefined,
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
            if (self.pending_type != null) return error.InvalidBsonState;
            if (self.stack_len != 0) return error.InvalidBsonState;
            if (self.index != self.input.len) return error.TrailingCharacters;
        }

        pub fn borrowStrings(self: *Self) bool {
            return self.can_borrow_strings;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            const tag = self.pending_type orelse return error.UnexpectedType;
            return switch (tag) {
                .null => .null,
                .bool => .bool,
                .int32, .int64, .double => .number,
                .string => .string,
                .binary => .bytes,
                .document => .object,
                .array => .array,
            };
        }

        pub fn readNull(self: *Self) !void {
            const tag = self.takePendingType() orelse return error.UnexpectedType;
            if (tag != .null) return error.UnexpectedType;
        }

        pub fn readBool(self: *Self) !bool {
            const tag = self.takePendingType() orelse return error.UnexpectedType;
            if (tag != .bool) return error.UnexpectedType;
            return switch (try self.readByte()) {
                0x00 => false,
                0x01 => true,
                else => error.InvalidBooleanValue,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            const tag = self.takePendingType() orelse return error.UnexpectedType;
            return switch (tag) {
                .int32 => .{ .integer = try self.readInt32() },
                .int64 => .{ .integer = try self.readInt64() },
                .double => .{ .float = try self.readF64() },
                else => error.UnexpectedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            const tag = self.takePendingType() orelse return error.UnexpectedType;
            if (tag != .string) return error.UnexpectedType;
            return .{
                .bytes = try self.readStringBytes(),
                .allocated = false,
            };
        }

        pub fn readBytes(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            const tag = self.takePendingType() orelse return error.UnexpectedType;
            return switch (tag) {
                .binary => .{
                    .bytes = try self.readBinaryBytes(),
                    .allocated = false,
                },
                .string => .{
                    .bytes = try self.readStringBytes(),
                    .allocated = false,
                },
                else => error.UnexpectedType,
            };
        }

        pub fn beginArray(self: *Self) !void {
            if (self.pending_type) |tag| {
                if (tag != .array) return error.UnexpectedType;
                self.pending_type = null;
            } else if (self.stack_len == 0) {
                return error.BsonRootMustBeDocument;
            } else {
                return error.UnexpectedType;
            }

            try self.push(.{
                .kind = .array,
                .end = try self.readDocumentEnd(),
            });
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            try self.beginArray();
            return null;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidBsonState;

            if (self.index == frame.end - 1) {
                if (self.input[self.index] != 0x00) return error.InvalidDocumentTerminator;
                self.index += 1;
                _ = self.pop();
                return false;
            }

            const tag = try self.readTag();
            _ = try self.readCString();
            self.pending_type = tag;
            return true;
        }

        pub fn beginObject(self: *Self) !void {
            if (self.pending_type) |tag| {
                if (tag != .document) return error.UnexpectedType;
                self.pending_type = null;
            }

            try self.push(.{
                .kind = .object,
                .end = try self.readDocumentEnd(),
            });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            _ = allocator;
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidBsonState;

            if (self.index == frame.end - 1) {
                if (self.input[self.index] != 0x00) return error.InvalidDocumentTerminator;
                self.index += 1;
                _ = self.pop();
                return null;
            }

            const tag = try self.readTag();
            const key = try self.readCString();
            self.pending_type = tag;
            return .{
                .bytes = key,
                .allocated = false,
            };
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = allocator;
            const tag = self.takePendingType() orelse return error.InvalidBsonState;
            try self.skipPayload(tag);
        }

        fn takePendingType(self: *Self) ?BsonType {
            const tag = self.pending_type;
            self.pending_type = null;
            return tag;
        }

        fn readDocumentEnd(self: *Self) !usize {
            const start = self.index;
            const len = try self.readInt32();
            if (len < 5) return error.InvalidDocumentLength;
            const end = start + @as(usize, @intCast(len));
            if (end > self.input.len) return error.UnexpectedEndOfInput;
            return end;
        }

        fn readTag(self: *Self) !BsonType {
            return switch (try self.readByte()) {
                @intFromEnum(BsonType.double) => .double,
                @intFromEnum(BsonType.string) => .string,
                @intFromEnum(BsonType.document) => .document,
                @intFromEnum(BsonType.array) => .array,
                @intFromEnum(BsonType.binary) => .binary,
                @intFromEnum(BsonType.bool) => .bool,
                @intFromEnum(BsonType.null) => .null,
                @intFromEnum(BsonType.int32) => .int32,
                @intFromEnum(BsonType.int64) => .int64,
                else => error.UnsupportedBsonType,
            };
        }

        fn readStringBytes(self: *Self) ![]const u8 {
            const len = try self.readInt32();
            if (len <= 0) return error.InvalidStringLength;
            const usize_len = @as(usize, @intCast(len));
            if (self.input.len - self.index < usize_len) return error.UnexpectedEndOfInput;
            const end = self.index + usize_len;
            if (self.input[end - 1] != 0x00) return error.InvalidStringTerminator;
            const bytes = self.input[self.index .. end - 1];
            self.index = end;
            return bytes;
        }

        fn readBinaryBytes(self: *Self) ![]const u8 {
            const len = try self.readInt32();
            if (len < 0) return error.InvalidBinaryLength;
            const usize_len = @as(usize, @intCast(len));
            const subtype = try self.readByte();
            _ = subtype;
            if (self.input.len - self.index < usize_len) return error.UnexpectedEndOfInput;
            const bytes = self.input[self.index .. self.index + usize_len];
            self.index += usize_len;
            return bytes;
        }

        fn readCString(self: *Self) ![]const u8 {
            const start = self.index;
            while (self.index < self.input.len and self.input[self.index] != 0x00) : (self.index += 1) {}
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            const bytes = self.input[start..self.index];
            self.index += 1;
            return bytes;
        }

        fn readByte(self: *Self) !u8 {
            if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
            const value = self.input[self.index];
            self.index += 1;
            return value;
        }

        fn readInt32(self: *Self) !i32 {
            const raw = try self.readLittle(u32);
            return @bitCast(raw);
        }

        fn readInt64(self: *Self) !i64 {
            const raw = try self.readLittle(u64);
            return @bitCast(raw);
        }

        fn readF64(self: *Self) !f64 {
            return @bitCast(try self.readLittle(u64));
        }

        fn readLittle(self: *Self, comptime T: type) !T {
            if (self.input.len - self.index < @sizeOf(T)) return error.UnexpectedEndOfInput;
            var value: T = 0;
            inline for (0..@sizeOf(T)) |offset| {
                value |= @as(T, self.input[self.index + offset]) << @as(std.math.Log2Int(T), @intCast(offset * 8));
            }
            self.index += @sizeOf(T);
            return value;
        }

        fn skipPayload(self: *Self, tag: BsonType) !void {
            switch (tag) {
                .null => {},
                .bool => _ = try self.readByte(),
                .int32 => _ = try self.readLittle(u32),
                .int64, .double => _ = try self.readLittle(u64),
                .string => _ = try self.readStringBytes(),
                .binary => _ = try self.readBinaryBytes(),
                .document, .array => {
                    const start = self.index;
                    const end = try self.readDocumentEnd();
                    self.index = end;
                    _ = start;
                },
            }
        }

        fn push(self: *Self, frame: ReaderFrame) !void {
            if (self.stack_len == self.stack.len) return error.BsonNestingTooDeep;
            self.stack[self.stack_len] = frame;
            self.stack_len += 1;
        }

        fn pop(self: *Self) ReaderFrame {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *ReaderFrame {
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

fn appendElementToBuffer(buffer: *std.ArrayListUnmanaged(u8), tag: BsonType, slot: ElementSlot, payload: []const u8) !void {
    try appendElementHeader(buffer, tag, slot);
    try buffer.appendSlice(BsonSerializer(WriteConfig).allocator, payload);
}

fn appendElementHeader(buffer: *std.ArrayListUnmanaged(u8), tag: BsonType, slot: ElementSlot) !void {
    try buffer.append(BsonSerializer(WriteConfig).allocator, @intFromEnum(tag));
    try appendSlotName(buffer, slot);
}

fn appendSlotName(buffer: *std.ArrayListUnmanaged(u8), slot: ElementSlot) !void {
    switch (slot) {
        .root => return error.InvalidBsonState,
        .field => |name| {
            try buffer.appendSlice(BsonSerializer(WriteConfig).allocator, name);
            try buffer.append(BsonSerializer(WriteConfig).allocator, 0x00);
        },
        .array_index => |index| {
            var scratch: [32]u8 = undefined;
            const key = try std.fmt.bufPrint(&scratch, "{d}", .{index});
            try buffer.appendSlice(BsonSerializer(WriteConfig).allocator, key);
            try buffer.append(BsonSerializer(WriteConfig).allocator, 0x00);
        },
    }
}

fn appendBsonString(buffer: *std.ArrayListUnmanaged(u8), value: []const u8) !void {
    try appendInt32Payload(buffer, value.len + 1);
    try buffer.appendSlice(BsonSerializer(WriteConfig).allocator, value);
    try buffer.append(BsonSerializer(WriteConfig).allocator, 0x00);
}

fn appendInt32Payload(buffer: *std.ArrayListUnmanaged(u8), value: usize) !void {
    const len = std.math.cast(i32, value) orelse return error.LengthMismatch;
    var bytes: [4]u8 = undefined;
    writeInt32Prefix(&bytes, @as(usize, @intCast(len)));
    try buffer.appendSlice(BsonSerializer(WriteConfig).allocator, &bytes);
}

fn writeInt32Prefix(dst: []u8, value: usize) void {
    const len = std.math.cast(i32, value) orelse @panic("bson document length overflow");
    appendLittleEndian(dst, @as(u32, @bitCast(len)));
}

fn encodeInteger(buffer: *[8]u8, value: anytype) !struct { tag: BsonType, bytes: []const u8 } {
    switch (@typeInfo(@TypeOf(value))) {
        .comptime_int => {
            if (std.math.cast(i32, value)) |narrow| {
                appendLittleEndian(buffer[0..4], @as(u32, @bitCast(narrow)));
                return .{ .tag = .int32, .bytes = buffer[0..4] };
            }
            if (std.math.cast(i64, value)) |wide| {
                appendLittleEndian(buffer, @as(u64, @bitCast(wide)));
                return .{ .tag = .int64, .bytes = buffer[0..8] };
            }
            return error.BsonIntegerOutOfRange;
        },
        .int => |info| {
            if (info.signedness == .unsigned) {
                const unsigned = std.math.cast(u64, value) orelse return error.BsonIntegerOutOfRange;
                if (unsigned <= std.math.maxInt(i32)) {
                    appendLittleEndian(buffer[0..4], @as(u32, @bitCast(@as(i32, @intCast(unsigned)))));
                    return .{ .tag = .int32, .bytes = buffer[0..4] };
                }
                if (unsigned <= std.math.maxInt(i64)) {
                    appendLittleEndian(buffer, @as(u64, @bitCast(@as(i64, @intCast(unsigned)))));
                    return .{ .tag = .int64, .bytes = buffer[0..8] };
                }
                return error.BsonIntegerOutOfRange;
            }

            const signed = std.math.cast(i64, value) orelse return error.BsonIntegerOutOfRange;
            if (std.math.cast(i32, signed)) |narrow| {
                appendLittleEndian(buffer[0..4], @as(u32, @bitCast(narrow)));
                return .{ .tag = .int32, .bytes = buffer[0..4] };
            }
            appendLittleEndian(buffer, @as(u64, @bitCast(signed)));
            return .{ .tag = .int64, .bytes = buffer[0..8] };
        },
        else => return error.UnsupportedType,
    }
}

fn appendLittleEndian(bytes: []u8, value: anytype) void {
    const Int = @TypeOf(value);
    for (0..bytes.len) |offset| {
        bytes[offset] = @as(u8, @truncate(value >> @as(std.math.Log2Int(Int), @intCast(offset * 8))));
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

test "serialize and parse struct to bson" {
    const Example = struct {
        firstName: []const u8,
        active: bool,
        kind: enum {
            captain,
            doctor,
        },
        note: ?[]const u8,
        samples: [3]u16,
        payload: [4]u8,
        metadata: struct {
            bounty: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Chopper",
        .active = true,
        .kind = .doctor,
        .note = null,
        .samples = .{ 3, 5, 8 },
        .payload = .{ 0xaa, 0xbb, 0xcc, 0xdd },
        .metadata = .{
            .bounty = 1_000,
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

test "parseSliceAliased reuses bson string bytes from input" {
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

test "parse bson binary into fixed byte array" {
    const Example = struct {
        payload: [3]u8,
    };

    const input = [_]u8{
        0x16, 0x00, 0x00, 0x00,
        0x05, 'p',  'a',  'y',
        'l',  'o',  'a',  'd',
        0x00, 0x03, 0x00, 0x00,
        0x00, 0x00, 0x01, 0x02,
        0x03, 0x00,
    };

    const decoded = try parseSlice(Example, std.testing.allocator, &input);
    try std.testing.expectEqualDeep([_]u8{ 0x01, 0x02, 0x03 }, decoded.payload);
}

test "reader deserialize reads from a fixed BSON input" {
    const Example = struct {
        name: []const u8,
        count: u16,
    };

    const input = [_]u8{
        0x1e, 0x00, 0x00, 0x00,
        0x02, 'n',  'a',  'm',
        'e',  0x00, 0x04, 0x00,
        0x00, 0x00, 'A',  'd',
        'a',  0x00, 0x10, 'c',
        'o',  'u',  'n',  't',
        0x00, 0x2a, 0x00, 0x00,
        0x00, 0x00,
    };

    var reader = std.Io.Reader.fixed(&input);
    const decoded = try deserialize(Example, std.testing.allocator, &reader);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.name);
    try std.testing.expectEqual(@as(u16, 42), decoded.count);
}
