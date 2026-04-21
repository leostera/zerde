const std = @import("std");
const types = @import("types.zig");
const RawBson = types.RawBson;

/// A Writer serializes BSON to a provided writer-like sink following the BSON spec.
pub fn Writer(comptime T: type) type {
    return struct {
        writer: T,
        arena: std.heap.ArenaAllocator,

        const Self = @This();

        pub fn init(allocator: std.mem.Allocator, wtr: T) Self {
            return .{
                .writer = wtr,
                .arena = std.heap.ArenaAllocator.init(allocator),
            };
        }

        /// callers should ensure this is called to free allocated memory
        pub fn deinit(self: *Self) void {
            self.arena.deinit();
        }

        pub fn writeFrom(self: *Self, data: anytype) !void {
            const raw = try RawBson.from(self.arena.allocator(), data);
            try self.write(raw.value);
        }

        pub fn write(self: *Self, bson: RawBson) !void {
            switch (bson) {
                .double => |v| {
                    const bytes: [8]u8 = @bitCast(v.value);
                    _ = try self.writeAll(&bytes);
                },
                .string => |v| try self.writeString(v),
                .document => |v| {
                    var buf: std.Io.Writer.Allocating = .init(self.arena.allocator());
                    defer buf.deinit();

                    var doc_writer = Writer(@TypeOf(&buf.writer)).init(self.arena.allocator(), &buf.writer);
                    defer doc_writer.deinit();

                    for (v.elements) |elem| {
                        try doc_writer.writeInt(i8, elem.@"1".toType().toInt());
                        _ = try doc_writer.writeAll(elem.@"0");
                        try doc_writer.writeSentinelByte();
                        try doc_writer.write(elem.@"1");
                    }

                    try self.writeInt(i32, @intCast(buf.written().len + 5));
                    _ = try self.writeAll(buf.written());
                    try self.writeSentinelByte();
                },
                .array => |v| {
                    var buf: std.Io.Writer.Allocating = .init(self.arena.allocator());
                    defer buf.deinit();

                    var doc_writer = Writer(@TypeOf(&buf.writer)).init(self.arena.allocator(), &buf.writer);
                    defer doc_writer.deinit();

                    for (v, 0..) |elem, i| {
                        try doc_writer.writeInt(i8, elem.toType().toInt());
                        var scratch: [32]u8 = undefined;
                        const key = try std.fmt.bufPrint(&scratch, "{d}", .{i});
                        _ = try doc_writer.writeAll(key);
                        try doc_writer.writeSentinelByte();
                        try doc_writer.write(elem);
                    }

                    try self.writeInt(i32, @intCast(buf.written().len + 5));
                    _ = try self.writeAll(buf.written());
                    try self.writeSentinelByte();
                },
                .boolean => |v| try self.writeInt(i8, if (v) 1 else 0),
                .regex => |v| {
                    try self.writeCStr(v.pattern);
                    try self.writeCStr(v.options);
                },
                .dbpointer => |v| {
                    try self.writeString(v.ref);
                    try self.write(.{ .object_id = v.id });
                },
                .javascript => |v| try self.writeString(v.value),
                .javascript_with_scope => |v| {
                    try self.writeInt(i32, @intCast(v.value.len));
                    try self.writeString(v.value);
                    try self.write(.{ .document = v.scope });
                },
                .int32 => |v| try self.writeInt(i32, v.value),
                .int64 => |v| try self.writeInt(i64, v.value),
                .decimal128 => {},
                .timestamp => |v| {
                    try self.writeInt(u32, v.increment);
                    try self.writeInt(u32, v.timestamp);
                },
                .binary => |v| {
                    try self.writeInt(i32, @intCast(v.value.len));
                    try self.writeInt(u8, v.subtype.toInt());
                    _ = try self.writeAll(v.value);
                },
                .object_id => |v| _ = try self.writeAll(&v.bytes),
                .datetime => |v| try self.writeInt(i64, v.millis),
                .symbol => |v| try self.writeString(v.value),
                .max_key, .min_key, .null, .undefined => {},
            }
        }

        fn writeInt(self: *Self, comptime Int: type, value: Int) !void {
            var bytes: [@sizeOf(Int)]u8 = undefined;
            std.mem.writeInt(Int, &bytes, value, .little);
            _ = try self.writeAll(&bytes);
        }

        fn writeAll(self: *Self, bytes: []const u8) !usize {
            try self.writer.writeAll(bytes);
            return bytes.len;
        }

        fn writeString(self: *Self, value: []const u8) !void {
            try self.writeInt(i32, @intCast(value.len + 1));
            _ = try self.writeAll(value);
            try self.writeSentinelByte();
        }

        fn writeCStr(self: *Self, value: []const u8) !void {
            _ = try self.writeAll(value);
            try self.writeSentinelByte();
        }

        fn writeSentinelByte(self: *Self) !void {
            try self.writer.writeByte(0);
        }
    };
}

/// Creates a new BSON writer to serialize documents to an underlying writer.
/// Callers should call `deinit()` after using the writer.
pub fn writer(allocator: std.mem.Allocator, underlying: anytype) Writer(@TypeOf(underlying)) {
    return Writer(@TypeOf(underlying)).init(allocator, underlying);
}
