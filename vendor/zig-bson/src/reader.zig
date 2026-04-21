const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;
const Owned = @import("root.zig").Owned;

/// A Reader deserializes BSON bytes from an in-memory slice into a RawBson value.
pub const Reader = struct {
    input: []const u8,
    index: usize = 0,
    bytes_read: usize = 0,
    allocator: std.mem.Allocator,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, input: []const u8) Self {
        return .{
            .input = input,
            .allocator = allocator,
        };
    }

    /// create a new Reader starting where this reader left off, sharing allocation states so that it only needs
    /// freed once
    fn fork(self: *Self, allocator: std.mem.Allocator) Self {
        return init(allocator, self.input[self.index..]);
    }

    pub fn readInto(self: *Self, comptime Into: type) !Owned(Into) {
        const raw = try self.read();
        var into = try raw.value.into(raw.arena.allocator(), Into);
        into.arena = raw.arena;
        return into;
    }

    /// reads data into an Owned RawBson value. callers are responsible for freeing memory by calling .deinit()
    pub fn read(self: *Self) !Owned(RawBson) {
        var owned = Owned(RawBson){
            .arena = try self.allocator.create(std.heap.ArenaAllocator),
            .value = undefined,
        };
        owned.arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer {
            owned.arena.deinit();
            self.allocator.destroy(owned.arena);
        }

        const len = try self.readI32();
        var elements = std.array_list.Managed(types.Document.Element).init(owned.arena.allocator());
        defer elements.deinit();

        while (self.bytes_read < len - 1) {
            const tpe = types.Type.fromInt(try self.readI8());
            const name = try self.readCStr(owned.arena.allocator());
            const element = switch (tpe) {
                .double => RawBson.makeDouble(try self.readF64()),
                .string => RawBson.makeString(try self.readStr(owned.arena.allocator())),
                .document => blk: {
                    var child = self.fork(owned.arena.allocator());
                    const raw = (try child.read()).value;
                    self.advanceChild(&child);
                    break :blk raw;
                },
                .array => blk: {
                    var child = self.fork(owned.arena.allocator());
                    const raw = (try child.read()).value;
                    self.advanceChild(&child);
                    switch (raw) {
                        .document => |doc| {
                            var elems = try owned.arena.allocator().alloc(RawBson, doc.elements.len);
                            for (doc.elements, 0..) |elem, i| elems[i] = elem.@"1";
                            break :blk RawBson.makeArray(elems);
                        },
                        else => unreachable,
                    }
                },
                .binary => blk: {
                    const bin_len = try self.readI32();
                    const st = types.SubType.fromInt(try self.readU8());
                    const bytes = try owned.arena.allocator().alloc(u8, @intCast(bin_len));
                    try self.readExact(bytes);
                    break :blk switch (st) {
                        .binary_old => old: {
                            if (bytes.len < 4) return error.InvalidBinaryLength;
                            const inner_len = std.mem.readInt(i32, bytes[0..4], .little);
                            if (inner_len < 0 or bytes.len - 4 < @as(usize, @intCast(inner_len))) return error.InvalidBinaryLength;
                            const inner_bytes = try owned.arena.allocator().alloc(u8, @intCast(inner_len));
                            @memcpy(inner_bytes, bytes[4 .. 4 + @as(usize, @intCast(inner_len))]);
                            break :old RawBson.makeBinary(inner_bytes, st);
                        },
                        else => RawBson{ .binary = types.Binary.init(bytes, st) },
                    };
                },
                .undefined => RawBson.makeUndefined(),
                .object_id => blk: {
                    var bytes: [12]u8 = undefined;
                    try self.readExact(&bytes);
                    break :blk RawBson.objectId(bytes);
                },
                .boolean => RawBson.makeBoolean(try self.readI8() == 1),
                .datetime => RawBson.makeDatetime(try self.readI64()),
                .null => RawBson.makeNull(),
                .regex => RawBson.makeRegex(try self.readCStr(owned.arena.allocator()), try self.readCStr(owned.arena.allocator())),
                .dbpointer => blk: {
                    const ref = try self.readStr(owned.arena.allocator());

                    var id_bytes: [12]u8 = undefined;
                    try self.readExact(&id_bytes);

                    break :blk RawBson{
                        .dbpointer = types.DBPointer.init(ref, types.ObjectId.fromBytes(id_bytes)),
                    };
                },
                .javascript => RawBson.javaScript(try self.readStr(owned.arena.allocator())),
                .javascript_with_scope => blk: {
                    _ = try self.readI32();
                    const code = try self.readStr(owned.arena.allocator());
                    var child = self.fork(owned.arena.allocator());
                    const raw = (try child.read()).value;
                    self.advanceChild(&child);
                    switch (raw) {
                        .document => |doc| break :blk RawBson.javaScriptWithScope(code, doc),
                        else => unreachable,
                    }
                },
                .symbol => RawBson.makeSymbol(try self.readStr(owned.arena.allocator())),
                .int32 => RawBson.makeInt32(try self.readI32()),
                .timestamp => RawBson.makeTimestamp(try self.readU32(), try self.readU32()),
                .int64 => RawBson.makeInt64(try self.readI64()),
                .decimal128 => blk: {
                    var bytes: [16]u8 = undefined;
                    try self.readExact(&bytes);
                    break :blk RawBson.makeDecimal128(bytes);
                },
                .min_key => RawBson.minKey(),
                .max_key => RawBson.maxKey(),
            };
            try elements.append(.{ name, element });
        }

        const last_byte = try self.readByte();
        if (last_byte != 0) return error.InvalidEndOfStream;

        owned.value = RawBson.makeDocument(try elements.toOwnedSlice());
        return owned;
    }

    fn advanceChild(self: *Self, child: *Self) void {
        self.index += child.bytes_read;
        self.bytes_read += child.bytes_read;
    }

    inline fn readI32(self: *Self) !i32 {
        return @bitCast(try self.readLittle(u32));
    }

    inline fn readI8(self: *Self) !i8 {
        return @bitCast(try self.readByte());
    }

    inline fn readU8(self: *Self) !u8 {
        return try self.readByte();
    }

    inline fn readCStr(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const start = self.index;
        while (self.index < self.input.len and self.input[self.index] != 0) : (self.index += 1) {}
        if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
        const bytes = self.input[start..self.index];
        self.index += 1;
        self.bytes_read += bytes.len + 1;
        return allocator.dupe(u8, bytes);
    }

    inline fn readStr(self: *Self, allocator: std.mem.Allocator) ![]u8 {
        const str_len = try self.readI32();
        if (str_len <= 0) return error.InvalidStringLength;
        const bytes = try allocator.alloc(u8, @intCast(str_len - 1));
        try self.readExact(bytes);
        if (try self.readByte() != 0) return error.NullTerminatorNotFound;
        if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
        return bytes;
    }

    inline fn readI64(self: *Self) !i64 {
        return @bitCast(try self.readLittle(u64));
    }

    inline fn readF64(self: *Self) !f64 {
        return @bitCast(try self.readLittle(u64));
    }

    inline fn readU32(self: *Self) !u32 {
        return try self.readLittle(u32);
    }

    fn readByte(self: *Self) !u8 {
        if (self.index >= self.input.len) return error.UnexpectedEndOfInput;
        const byte = self.input[self.index];
        self.index += 1;
        self.bytes_read += 1;
        return byte;
    }

    fn readExact(self: *Self, buffer: []u8) !void {
        if (self.input.len - self.index < buffer.len) return error.UnexpectedEndOfInput;
        @memcpy(buffer, self.input[self.index .. self.index + buffer.len]);
        self.index += buffer.len;
        self.bytes_read += buffer.len;
    }

    fn readLittle(self: *Self, comptime T: type) !T {
        var bytes: [@sizeOf(T)]u8 = undefined;
        try self.readExact(&bytes);
        return std.mem.readInt(T, &bytes, .little);
    }
};

/// Creates a new BSON reader to deserialize documents from an input slice.
pub fn reader(allocator: std.mem.Allocator, input: []const u8) Reader {
    return Reader.init(allocator, input);
}
