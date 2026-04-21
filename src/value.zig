//! Optional runtime value tree for self-describing formats.
//!
//! The typed path remains the default fast path for `zerde`. This module is an
//! explicit escape hatch for cases such as transcoding, inspection, tooling,
//! and format-to-format conversion when no Zig schema is available up front.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const bson_format = @import("bson.zig");
const cbor_format = @import("cbor.zig");
const json_format = @import("json.zig");
const msgpack_format = @import("msgpack.zig");
const toml_format = @import("toml.zig");
const yaml_format = @import("yaml.zig");

const Number = typed.Number;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const Bytes = struct {
    bytes: []const u8,
    allocated: bool,

    fn fromTokenOwned(allocator: Allocator, token: StringToken) !Bytes {
        if (token.allocated) {
            return .{
                .bytes = token.bytes,
                .allocated = true,
            };
        }

        return .{
            .bytes = try allocator.dupe(u8, token.bytes),
            .allocated = true,
        };
    }

    pub fn deinit(self: Bytes, allocator: Allocator) void {
        if (self.allocated) allocator.free(@constCast(self.bytes));
    }

    pub fn eql(self: Bytes, other: Bytes) bool {
        return std.mem.eql(u8, self.bytes, other.bytes);
    }
};

pub const Entry = struct {
    key: Bytes,
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i128,
    float: f64,
    string: Bytes,
    bytes: Bytes,
    array: []Value,
    object: []Entry,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .null, .bool, .integer, .float => {},
            .string => |token| token.deinit(allocator),
            .bytes => |token| token.deinit(allocator),
            .array => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .object => |entries| {
                for (entries) |*entry| {
                    entry.key.deinit(allocator);
                    entry.value.deinit(allocator);
                }
                allocator.free(entries);
            },
        }
        self.* = undefined;
    }

    pub fn eql(self: Value, other: Value) bool {
        switch (self) {
            .null => return other == .null,
            .bool => |lhs| return switch (other) {
                .bool => |rhs| lhs == rhs,
                else => false,
            },
            .integer => |lhs| return switch (other) {
                .integer => |rhs| lhs == rhs,
                else => false,
            },
            .float => |lhs| return switch (other) {
                .float => |rhs| lhs == rhs,
                else => false,
            },
            .string => |lhs| return switch (other) {
                .string => |rhs| lhs.eql(rhs),
                else => false,
            },
            .bytes => |lhs| return switch (other) {
                .bytes => |rhs| lhs.eql(rhs),
                else => false,
            },
            .array => |lhs| return switch (other) {
                .array => |rhs| blk: {
                    if (lhs.len != rhs.len) break :blk false;
                    for (lhs, rhs) |lhs_item, rhs_item| {
                        if (!lhs_item.eql(rhs_item)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .object => |lhs| return switch (other) {
                .object => |rhs| blk: {
                    if (lhs.len != rhs.len) break :blk false;
                    for (lhs, rhs) |lhs_entry, rhs_entry| {
                        if (!lhs_entry.key.eql(rhs_entry.key)) break :blk false;
                        if (!lhs_entry.value.eql(rhs_entry.value)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
        }
    }
};

pub fn deserialize(comptime Format: type, allocator: Allocator, reader: *std.Io.Reader) !Value {
    return deserializeWith(Format, allocator, reader, .{});
}

pub fn deserializeWith(
    comptime Format: type,
    allocator: Allocator,
    reader: *std.Io.Reader,
    comptime format_cfg: anytype,
) !Value {
    if (!@hasDecl(Format, "readerDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement readerDeserializer()");
    }

    var deserializer = try Format.readerDeserializer(allocator, reader, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);

    const value = try parseFromDeserializer(allocator, &deserializer);
    if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
    return value;
}

pub fn parseSlice(comptime Format: type, allocator: Allocator, input: []const u8) !Value {
    return parseSliceWith(Format, allocator, input, .{});
}

pub fn parseSliceWith(
    comptime Format: type,
    allocator: Allocator,
    input: []const u8,
    comptime format_cfg: anytype,
) !Value {
    if (!@hasDecl(Format, "sliceDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement sliceDeserializer()");
    }

    var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);

    const value = try parseFromDeserializer(allocator, &deserializer);
    if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
    return value;
}

pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: Value) !void {
    if (Format == json_format) return writeJson(writer, value);
    if (Format == toml_format) return writeToml(writer, value);
    if (Format == yaml_format) return writeYaml(writer, value);
    if (Format == cbor_format) return writeCbor(writer, value);
    if (Format == bson_format) return writeBson(writer, value);
    if (Format == msgpack_format) return writeMsgpack(writer, value);
    @compileError("zerde.Value serialization is only supported for JSON, TOML, YAML, CBOR, BSON, and MessagePack");
}

fn parseFromDeserializer(allocator: Allocator, deserializer: anytype) anyerror!Value {
    const DeserializerType = @TypeOf(deserializer.*);
    return switch (try deserializer.peekKind()) {
        .null => blk: {
            try deserializer.readNull();
            break :blk .null;
        },
        .bool => .{ .bool = try deserializer.readBool() },
        .number => switch (try deserializer.readNumber()) {
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
        },
        .string => blk: {
            const token = try deserializer.readString(allocator);
            break :blk .{ .string = try Bytes.fromTokenOwned(allocator, token) };
        },
        .bytes => blk: {
            if (@hasDecl(DeserializerType, "readBytes")) {
                const token = try deserializer.readBytes(allocator);
                break :blk .{ .bytes = try Bytes.fromTokenOwned(allocator, token) };
            }

            const token = try deserializer.readString(allocator);
            break :blk .{ .string = try Bytes.fromTokenOwned(allocator, token) };
        },
        .array => try parseArrayValue(allocator, deserializer),
        .object => try parseObjectValue(allocator, deserializer),
    };
}

fn parseArrayValue(allocator: Allocator, deserializer: anytype) anyerror!Value {
    var items: std.ArrayList(Value) = .empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }

    if (@hasDecl(@TypeOf(deserializer.*), "beginArrayLen")) {
        _ = try deserializer.beginArrayLen();
    } else {
        try deserializer.beginArray();
    }

    while (try deserializer.nextArrayItem()) {
        try items.append(allocator, try parseFromDeserializer(allocator, deserializer));
    }

    return .{ .array = try items.toOwnedSlice(allocator) };
}

fn parseObjectValue(allocator: Allocator, deserializer: anytype) anyerror!Value {
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| {
            entry.key.deinit(allocator);
            entry.value.deinit(allocator);
        }
        entries.deinit(allocator);
    }

    try deserializer.beginObject();
    while (try deserializer.nextObjectField(allocator)) |field_token| {
        const key = try Bytes.fromTokenOwned(allocator, field_token);
        errdefer key.deinit(allocator);

        const value = try parseFromDeserializer(allocator, deserializer);
        errdefer {
            var tmp = value;
            tmp.deinit(allocator);
        }

        try entries.append(allocator, .{
            .key = key,
            .value = value,
        });
    }

    return .{ .object = try entries.toOwnedSlice(allocator) };
}

fn writeJson(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{}", .{n}),
        .float => |n| try writer.print("{}", .{n}),
        .string => |s| try writeDoubleQuotedString(writer, s.bytes),
        .bytes => |bytes| try writeJsonByteArray(writer, bytes.bytes),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeJson(writer, item);
            }
            try writer.writeByte(']');
        },
        .object => |entries| {
            try writer.writeByte('{');
            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeByte(',');
                try writeDoubleQuotedString(writer, entry.key.bytes);
                try writer.writeByte(':');
                try writeJson(writer, entry.value);
            }
            try writer.writeByte('}');
        },
    }
}

fn writeYaml(writer: *std.Io.Writer, value: Value) !void {
    try writeYamlValue(writer, value, 0);
}

fn writeYamlValue(writer: *std.Io.Writer, value: Value, indent: usize) !void {
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{}", .{n}),
        .float => |n| try writer.print("{}", .{n}),
        .string => |s| try writeDoubleQuotedString(writer, s.bytes),
        .bytes => |bytes| try writeYamlByteArray(writer, bytes.bytes, indent),
        .array => |items| {
            if (items.len == 0) {
                try writer.writeAll("[]");
                return;
            }

            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte('\n');
                try writeIndent(writer, indent);
                try writer.writeAll("- ");
                if (isYamlInline(item)) {
                    try writeYamlValue(writer, item, indent + 2);
                } else {
                    try writer.writeByte('\n');
                    try writeYamlValue(writer, item, indent + 2);
                }
            }
        },
        .object => |entries| {
            if (entries.len == 0) {
                try writer.writeAll("{}");
                return;
            }

            for (entries, 0..) |entry, index| {
                if (index != 0) try writer.writeByte('\n');
                try writeIndent(writer, indent);
                try writeDoubleQuotedString(writer, entry.key.bytes);
                try writer.writeByte(':');
                if (isYamlInline(entry.value)) {
                    try writer.writeByte(' ');
                    try writeYamlValue(writer, entry.value, indent + 2);
                } else {
                    try writer.writeByte('\n');
                    try writeYamlValue(writer, entry.value, indent + 2);
                }
            }
        },
    }
}

fn writeToml(writer: *std.Io.Writer, value: Value) !void {
    if (value != .object) return error.TomlInvalidTopLevelType;

    var state = TomlWriterState{
        .writer = writer,
    };
    try state.writeTableBody(value.object);
}

const TomlWriterState = struct {
    writer: *std.Io.Writer,
    path: [64][]const u8 = undefined,
    path_len: usize = 0,
    wrote_anything: bool = false,

    fn writeTableHeader(self: *TomlWriterState, array_of_tables: bool) !void {
        if (self.wrote_anything) try self.writer.writeByte('\n');
        try self.writer.writeAll(if (array_of_tables) "[[" else "[");
        for (self.path[0..self.path_len], 0..) |segment, index| {
            if (index != 0) try self.writer.writeByte('.');
            try writeTomlKey(writerOr(self), segment);
        }
        try self.writer.writeAll(if (array_of_tables) "]]\n" else "]\n");
        self.wrote_anything = true;
    }

    fn writeTableBody(self: *TomlWriterState, entries: []const Entry) !void {
        for (entries) |entry| {
            if (isTomlScalarLike(entry.value)) {
                try writeTomlKey(self.writer, entry.key.bytes);
                try self.writer.writeAll(" = ");
                try writeTomlScalarLike(self.writer, entry.value);
                try self.writer.writeByte('\n');
                self.wrote_anything = true;
            }
        }

        for (entries) |entry| {
            switch (entry.value) {
                .object => |nested| {
                    try self.pushPath(entry.key.bytes);
                    try self.writeTableHeader(false);
                    try self.writeTableBody(nested);
                    self.popPath();
                },
                .array => |items| {
                    if (!isTomlArrayOfTables(items)) continue;
                    try self.pushPath(entry.key.bytes);
                    for (items) |item| {
                        const nested = switch (item) {
                            .object => |object_entries| object_entries,
                            else => unreachable,
                        };
                        try self.writeTableHeader(true);
                        try self.writeTableBody(nested);
                    }
                    self.popPath();
                },
                else => {},
            }
        }
    }

    fn pushPath(self: *TomlWriterState, segment: []const u8) !void {
        if (self.path_len == self.path.len) return error.TomlNestingTooDeep;
        self.path[self.path_len] = segment;
        self.path_len += 1;
    }

    fn popPath(self: *TomlWriterState) void {
        self.path_len -= 1;
    }
};

fn writerOr(state: *TomlWriterState) *std.Io.Writer {
    return state.writer;
}

fn writeCbor(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try writer.writeByte(0xf6),
        .bool => |b| try writer.writeByte(if (b) 0xf5 else 0xf4),
        .integer => |n| try writeCborInteger(writer, n),
        .float => |n| try writeCborFloat(writer, n),
        .string => |s| try writeCborStringLike(writer, 3, s.bytes),
        .bytes => |bytes| try writeCborStringLike(writer, 2, bytes.bytes),
        .array => |items| {
            try writeCborMajor(writer, 4, items.len);
            for (items) |item| try writeCbor(writer, item);
        },
        .object => |entries| {
            try writeCborMajor(writer, 5, entries.len);
            for (entries) |entry| {
                try writeCborStringLike(writer, 3, entry.key.bytes);
                try writeCbor(writer, entry.value);
            }
        },
    }
}

fn writeMsgpack(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .null => try writer.writeByte(0xc0),
        .bool => |b| try writer.writeByte(if (b) 0xc3 else 0xc2),
        .integer => |n| try writeMsgpackInteger(writer, n),
        .float => |n| try writeMsgpackFloat(writer, n),
        .string => |s| try writeMsgpackStringLike(writer, .string, s.bytes),
        .bytes => |bytes| try writeMsgpackStringLike(writer, .binary, bytes.bytes),
        .array => |items| {
            try writeMsgpackArrayHeader(writer, items.len);
            for (items) |item| try writeMsgpack(writer, item);
        },
        .object => |entries| {
            try writeMsgpackMapHeader(writer, entries.len);
            for (entries) |entry| {
                try writeMsgpackStringLike(writer, .string, entry.key.bytes);
                try writeMsgpack(writer, entry.value);
            }
        },
    }
}

fn writeBson(writer: *std.Io.Writer, value: Value) !void {
    if (value != .object) return error.BsonRootMustBeDocument;

    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    defer buffer.deinit(std.heap.smp_allocator);

    try encodeBsonDocument(&buffer, value.object, false);
    try writer.writeAll(buffer.items);
}

fn encodeBsonDocument(buffer: *std.ArrayListUnmanaged(u8), entries: []const Entry, as_array: bool) anyerror!void {
    const allocator = std.heap.smp_allocator;
    const length_offset = buffer.items.len;
    try buffer.appendNTimes(allocator, 0, 4);

    for (entries, 0..) |entry, index| {
        const key = if (as_array)
            try std.fmt.allocPrint(allocator, "{}", .{index})
        else
            entry.key.bytes;
        defer if (as_array) allocator.free(key);
        try encodeBsonElement(buffer, key, entry.value);
    }

    try buffer.append(allocator, 0x00);

    const total_len = buffer.items.len - length_offset;
    std.mem.writeInt(i32, buffer.items[length_offset .. length_offset + 4][0..4], @intCast(total_len), .little);
}

fn encodeBsonElement(buffer: *std.ArrayListUnmanaged(u8), key: []const u8, value: Value) anyerror!void {
    const allocator = std.heap.smp_allocator;

    try buffer.append(allocator, bsonTypeTag(value));
    try buffer.appendSlice(allocator, key);
    try buffer.append(allocator, 0x00);

    switch (value) {
        .null => {},
        .bool => |b| try buffer.append(allocator, if (b) 0x01 else 0x00),
        .integer => |n| {
            if (std.math.cast(i32, n)) |small| {
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(i32, &bytes, small, .little);
                try buffer.appendSlice(allocator, &bytes);
            } else {
                var bytes: [8]u8 = undefined;
                std.mem.writeInt(i64, &bytes, std.math.cast(i64, n) orelse return error.IntegerOverflow, .little);
                try buffer.appendSlice(allocator, &bytes);
            }
        },
        .float => |n| {
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, @bitCast(n), .little);
            try buffer.appendSlice(allocator, &bytes);
        },
        .string => |s| try appendBsonString(buffer, s.bytes),
        .bytes => |bytes_value| {
            var len_bytes: [4]u8 = undefined;
            std.mem.writeInt(i32, &len_bytes, @intCast(bytes_value.bytes.len), .little);
            try buffer.appendSlice(allocator, &len_bytes);
            try buffer.append(allocator, 0x00);
            try buffer.appendSlice(allocator, bytes_value.bytes);
        },
        .array => |items| {
            var entries = try allocator.alloc(Entry, items.len);
            defer allocator.free(entries);
            for (items, 0..) |item, index| {
                entries[index] = .{
                    .key = .{
                        .bytes = "",
                        .allocated = false,
                    },
                    .value = item,
                };
            }
            try encodeBsonDocument(buffer, entries, true);
        },
        .object => |entries| try encodeBsonDocument(buffer, entries, false),
    }
}

fn bsonTypeTag(value: Value) u8 {
    return switch (value) {
        .float => 0x01,
        .string => 0x02,
        .object => 0x03,
        .array => 0x04,
        .bytes => 0x05,
        .bool => 0x08,
        .null => 0x0a,
        .integer => |n| if (std.math.cast(i32, n) != null) 0x10 else 0x12,
    };
}

fn appendBsonString(buffer: *std.ArrayListUnmanaged(u8), value: []const u8) anyerror!void {
    const allocator = std.heap.smp_allocator;
    var len_bytes: [4]u8 = undefined;
    std.mem.writeInt(i32, &len_bytes, @intCast(value.len + 1), .little);
    try buffer.appendSlice(allocator, &len_bytes);
    try buffer.appendSlice(allocator, value);
    try buffer.append(allocator, 0x00);
}

fn writeJsonByteArray(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('[');
    for (bytes, 0..) |byte, index| {
        if (index != 0) try writer.writeByte(',');
        try writer.print("{}", .{byte});
    }
    try writer.writeByte(']');
}

fn writeYamlByteArray(writer: *std.Io.Writer, bytes: []const u8, _: usize) !void {
    try writer.writeByte('[');
    for (bytes, 0..) |byte, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.print("{}", .{byte});
    }
    try writer.writeByte(']');
}

fn writeTomlScalarLike(writer: *std.Io.Writer, value: Value) !void {
    switch (value) {
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .integer => |n| try writer.print("{}", .{n}),
        .float => |n| try writer.print("{}", .{n}),
        .string => |s| try writeDoubleQuotedString(writer, s.bytes),
        .bytes => |bytes| {
            try writer.writeByte('[');
            for (bytes.bytes, 0..) |byte, index| {
                if (index != 0) try writer.writeAll(", ");
                try writer.print("{}", .{byte});
            }
            try writer.writeByte(']');
        },
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeAll(", ");
                try writeTomlScalarLike(writer, item);
            }
            try writer.writeByte(']');
        },
        .null => return error.TomlNullUnsupported,
        .object => return error.TomlInlineTableUnsupported,
    }
}

fn isTomlScalarLike(value: Value) bool {
    return switch (value) {
        .bool, .integer, .float, .string, .bytes => true,
        .array => |items| blk: {
            for (items) |item| {
                if (!isTomlScalarLike(item)) break :blk false;
            }
            break :blk true;
        },
        else => false,
    };
}

fn isTomlArrayOfTables(items: []const Value) bool {
    if (items.len == 0) return false;
    for (items) |item| {
        if (item != .object) return false;
    }
    return true;
}

fn isYamlInline(value: Value) bool {
    return switch (value) {
        .null, .bool, .integer, .float, .string, .bytes => true,
        .array => |items| items.len == 0,
        .object => |entries| entries.len == 0,
    };
}

fn writeIndent(writer: *std.Io.Writer, indent: usize) !void {
    for (0..indent) |_| try writer.writeByte(' ');
}

fn writeDoubleQuotedString(writer: *std.Io.Writer, value: []const u8) !void {
    try writer.writeByte('"');
    for (value) |byte| {
        switch (byte) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\x08' => try writer.writeAll("\\b"),
            '\x0c' => try writer.writeAll("\\f"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            0...7, 0x0b, 0x0e...31 => try writer.print("\\u{X:0>4}", .{byte}),
            else => try writer.writeByte(byte),
        }
    }
    try writer.writeByte('"');
}

fn writeTomlKey(writer: *std.Io.Writer, key: []const u8) !void {
    try writeDoubleQuotedString(writer, key);
}

fn writeCborInteger(writer: *std.Io.Writer, value: i128) !void {
    if (value >= 0) {
        try writeCborMajor(writer, 0, std.math.cast(u64, value) orelse return error.IntegerOverflow);
    } else {
        const encoded = std.math.cast(u64, -value - 1) orelse return error.IntegerOverflow;
        try writeCborMajor(writer, 1, encoded);
    }
}

fn writeCborFloat(writer: *std.Io.Writer, value: f64) !void {
    try writer.writeByte(0xfb);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .big);
    try writer.writeAll(&bytes);
}

fn writeCborStringLike(writer: *std.Io.Writer, major: u8, value: []const u8) !void {
    try writeCborMajor(writer, major, value.len);
    try writer.writeAll(value);
}

fn writeCborMajor(writer: *std.Io.Writer, major: u8, value: usize) !void {
    if (value < 24) {
        try writer.writeByte((major << 5) | @as(u8, @intCast(value)));
        return;
    }

    if (value <= std.math.maxInt(u8)) {
        try writer.writeByte((major << 5) | 24);
        try writer.writeByte(@intCast(value));
        return;
    }

    if (value <= std.math.maxInt(u16)) {
        try writer.writeByte((major << 5) | 25);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, @intCast(value), .big);
        try writer.writeAll(&bytes);
        return;
    }

    if (value <= std.math.maxInt(u32)) {
        try writer.writeByte((major << 5) | 26);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(value), .big);
        try writer.writeAll(&bytes);
        return;
    }

    try writer.writeByte((major << 5) | 27);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @intCast(value), .big);
    try writer.writeAll(&bytes);
}

const MsgpackStringKind = enum {
    string,
    binary,
};

fn writeMsgpackInteger(writer: *std.Io.Writer, value: i128) !void {
    if (value >= 0) {
        const unsigned = std.math.cast(u64, value) orelse return error.IntegerOverflow;
        if (unsigned <= 0x7f) {
            try writer.writeByte(@intCast(unsigned));
        } else if (unsigned <= std.math.maxInt(u8)) {
            try writer.writeByte(0xcc);
            try writer.writeByte(@intCast(unsigned));
        } else if (unsigned <= std.math.maxInt(u16)) {
            try writer.writeByte(0xcd);
            var bytes: [2]u8 = undefined;
            std.mem.writeInt(u16, &bytes, @intCast(unsigned), .big);
            try writer.writeAll(&bytes);
        } else if (unsigned <= std.math.maxInt(u32)) {
            try writer.writeByte(0xce);
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @intCast(unsigned), .big);
            try writer.writeAll(&bytes);
        } else {
            try writer.writeByte(0xcf);
            var bytes: [8]u8 = undefined;
            std.mem.writeInt(u64, &bytes, unsigned, .big);
            try writer.writeAll(&bytes);
        }
        return;
    }

    if (value >= -32) {
        try writer.writeByte(@bitCast(@as(i8, @intCast(value))));
    } else if (value >= std.math.minInt(i8)) {
        try writer.writeByte(0xd0);
        try writer.writeByte(@bitCast(@as(i8, @intCast(value))));
    } else if (value >= std.math.minInt(i16)) {
        try writer.writeByte(0xd1);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(i16, &bytes, @intCast(value), .big);
        try writer.writeAll(&bytes);
    } else if (value >= std.math.minInt(i32)) {
        try writer.writeByte(0xd2);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(i32, &bytes, @intCast(value), .big);
        try writer.writeAll(&bytes);
    } else {
        try writer.writeByte(0xd3);
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(i64, &bytes, std.math.cast(i64, value) orelse return error.IntegerOverflow, .big);
        try writer.writeAll(&bytes);
    }
}

fn writeMsgpackFloat(writer: *std.Io.Writer, value: f64) !void {
    try writer.writeByte(0xcb);
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, @bitCast(value), .big);
    try writer.writeAll(&bytes);
}

fn writeMsgpackStringLike(writer: *std.Io.Writer, kind: MsgpackStringKind, value: []const u8) !void {
    switch (kind) {
        .string => {
            if (value.len <= 31) {
                try writer.writeByte(0xa0 | @as(u8, @intCast(value.len)));
            } else if (value.len <= std.math.maxInt(u8)) {
                try writer.writeByte(0xd9);
                try writer.writeByte(@intCast(value.len));
            } else if (value.len <= std.math.maxInt(u16)) {
                try writer.writeByte(0xda);
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &bytes, @intCast(value.len), .big);
                try writer.writeAll(&bytes);
            } else {
                try writer.writeByte(0xdb);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, @intCast(value.len), .big);
                try writer.writeAll(&bytes);
            }
        },
        .binary => {
            if (value.len <= std.math.maxInt(u8)) {
                try writer.writeByte(0xc4);
                try writer.writeByte(@intCast(value.len));
            } else if (value.len <= std.math.maxInt(u16)) {
                try writer.writeByte(0xc5);
                var bytes: [2]u8 = undefined;
                std.mem.writeInt(u16, &bytes, @intCast(value.len), .big);
                try writer.writeAll(&bytes);
            } else {
                try writer.writeByte(0xc6);
                var bytes: [4]u8 = undefined;
                std.mem.writeInt(u32, &bytes, @intCast(value.len), .big);
                try writer.writeAll(&bytes);
            }
        },
    }

    try writer.writeAll(value);
}

fn writeMsgpackArrayHeader(writer: *std.Io.Writer, len: usize) !void {
    if (len <= 15) {
        try writer.writeByte(0x90 | @as(u8, @intCast(len)));
    } else if (len <= std.math.maxInt(u16)) {
        try writer.writeByte(0xdc);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, @intCast(len), .big);
        try writer.writeAll(&bytes);
    } else {
        try writer.writeByte(0xdd);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(len), .big);
        try writer.writeAll(&bytes);
    }
}

fn writeMsgpackMapHeader(writer: *std.Io.Writer, len: usize) !void {
    if (len <= 15) {
        try writer.writeByte(0x80 | @as(u8, @intCast(len)));
    } else if (len <= std.math.maxInt(u16)) {
        try writer.writeByte(0xde);
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, @intCast(len), .big);
        try writer.writeAll(&bytes);
    } else {
        try writer.writeByte(0xdf);
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, @intCast(len), .big);
        try writer.writeAll(&bytes);
    }
}

test "Value roundtrips across self-describing formats" {
    const allocator = std.testing.allocator;
    const input =
        \\{"name":"Franky","bounty":394000000,"shipwright":true,"ratio":1.5,"weapons":["beam","cola"],"dock":{"mode":7},"ports":[{"name":"left"},{"name":"right"}]}
    ;

    const source = try parseSlice(json_format, allocator, input);
    defer {
        var tmp = source;
        tmp.deinit(allocator);
    }

    inline for (.{
        json_format,
        toml_format,
        yaml_format,
        cbor_format,
        bson_format,
        msgpack_format,
    }) |Format| {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try serialize(Format, &out.writer, source);

        const reparsed = try parseSlice(Format, allocator, out.written());
        defer {
            var tmp = reparsed;
            tmp.deinit(allocator);
        }

        try std.testing.expect(source.eql(reparsed));
    }
}
