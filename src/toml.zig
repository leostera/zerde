//! TOML backend for the typed walk.
//!
//! TOML cannot emit fields in arbitrary order if nested tables are involved, so
//! this backend asks the typed layer for two struct passes: scalars first, then
//! nested tables and arrays-of-tables.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const read_impl = @import("toml_read.zig");

pub const ReadConfig = read_impl.ReadConfig;
pub const WriteConfig = struct {};

pub const readerDeserializer = read_impl.readerDeserializer;
pub const sliceDeserializer = read_impl.sliceDeserializer;
pub const deserialize = read_impl.deserialize;
pub const deserializeWith = read_impl.deserializeWith;
pub const parseSlice = read_impl.parseSlice;
pub const parseSliceWith = read_impl.parseSliceWith;
pub const parseSliceAliased = read_impl.parseSliceAliased;
pub const parseSliceAliasedWith = read_impl.parseSliceAliasedWith;

/// Streaming TOML writer used by the typed layer.
pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) TomlSerializer(@TypeOf(cfg)) {
    return TomlSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn TomlSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        table_path: [64][]const u8 = undefined,
        table_path_len: usize = 0,
        array_table_field_stack: [64][]const u8 = undefined,
        array_table_field_len: usize = 0,
        inline_array_first: [64]bool = undefined,
        inline_array_len: usize = 0,
        current_field: ?[]const u8 = null,
        wrote_anything: bool = false,
        root_started: bool = false,

        const Self = @This();

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            _ = self;
            return error.TomlNullUnsupported;
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.ensureValueContext();
            try writeBool(self.writer, value);
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.ensureValueContext();
            try writeInteger(self.writer, value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try self.ensureValueContext();
            try writeFloat(self.writer, value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try self.ensureValueContext();
            try writeBasicString(self.writer, value);
        }

        pub fn emitEnum(self: *Self, comptime Enum: type, value: Enum) !void {
            try self.ensureValueContext();
            try writeQuotedEnumTag(self.writer, Enum, value);
        }

        pub fn serializeSequence(self: *Self, comptime Sequence: type, value: Sequence, comptime cfg: anytype) !bool {
            _ = cfg;
            if (!isInlineSequenceType(Sequence)) return false;

            try self.ensureValueContext();
            try self.writeInlineValue(Sequence, value);
            return true;
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;
            _ = self.cfg;
            if (!self.root_started and self.current_field == null and self.table_path_len == 0) {
                self.root_started = true;
            }
        }

        pub fn structPassCount(comptime T: type) usize {
            _ = T;
            return 2;
        }

        // Pass 0 writes plain key/value fields, pass 1 writes nested tables.
        pub fn includeStructField(comptime Parent: type, comptime FieldType: type, comptime pass: usize) bool {
            _ = Parent;
            return switch (pass) {
                0 => !isStructType(FieldType) and !isArrayOfStructs(FieldType),
                1 => isStructType(FieldType) or isArrayOfStructs(FieldType),
                else => false,
            };
        }

        pub fn beginStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !bool {
            _ = Parent;
            self.current_field = name;

            if (isStructType(FieldType)) {
                // Nested structs become TOML tables.
                try self.writeTableHeader(name, false);
                try self.pushTable(name);
                return true;
            }

            if (isArrayOfStructs(FieldType)) {
                // Arrays of structs are emitted one element at a time as array-of-table entries.
                try self.pushArrayTableField(name);
                return true;
            }

            try self.writeKey(name);
            try self.writer.writeAll(" = ");
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = Parent;
            _ = name;

            if (isStructType(FieldType)) {
                self.popTable();
                self.current_field = null;
                self.wrote_anything = true;
                return;
            }

            if (isArrayOfStructs(FieldType)) {
                self.popArrayTableField();
                self.current_field = null;
                self.wrote_anything = true;
                return;
            }

            try self.writer.writeByte('\n');
            self.current_field = null;
            self.wrote_anything = true;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = self;
            _ = T;
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            if (isStructType(Child)) {
                if (len == 0) return error.EmptyTomlArrayOfTables;
                return;
            }

            // Non-struct arrays stay inline in TOML.
            try self.ensureValueContext();
            try self.writer.writeByte('[');
            try self.pushInlineArray();
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = index;
            if (isStructType(Child)) {
                const field_name = if (self.array_table_field_len != 0)
                    self.array_table_field_stack[self.array_table_field_len - 1]
                else
                    self.current_field orelse return error.InvalidTomlState;
                try self.writeTableHeader(field_name, true);
                try self.pushTable(field_name);
                return;
            }

            const first = &self.inline_array_first[self.inline_array_len - 1];
            if (!first.*) {
                try self.writer.writeAll(", ");
            } else {
                first.* = false;
            }
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = index;
            if (isStructType(Child)) {
                self.popTable();
                self.wrote_anything = true;
            }
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = len;
            if (isStructType(Child)) return;

            self.inline_array_len -= 1;
            try self.writer.writeByte(']');
        }

        fn ensureValueContext(self: *Self) !void {
            if (self.current_field == null and self.inline_array_len == 0) {
                return error.TomlInvalidTopLevelType;
            }
        }

        fn writeTableHeader(self: *Self, field_name: []const u8, array_of_tables: bool) !void {
            if (self.wrote_anything) try self.writer.writeByte('\n');

            if (array_of_tables) {
                try self.writer.writeAll("[[");
            } else {
                try self.writer.writeByte('[');
            }

            try self.writeQualifiedKey(field_name);

            if (array_of_tables) {
                try self.writer.writeAll("]]\n");
            } else {
                try self.writer.writeAll("]\n");
            }
        }

        fn writeQualifiedKey(self: *Self, field_name: []const u8) !void {
            for (0..self.table_path_len) |index| {
                if (index != 0) try self.writer.writeByte('.');
                try self.writeKey(self.table_path[index]);
            }
            if (self.table_path_len != 0) try self.writer.writeByte('.');
            try self.writeKey(field_name);
        }

        fn writeKey(self: *Self, key: []const u8) !void {
            if (isBareKey(key)) {
                try self.writer.writeAll(key);
            } else {
                try writeBasicString(self.writer, key);
            }
        }

        fn writeInlineValue(self: *Self, comptime T: type, value: T) !void {
            switch (@typeInfo(T)) {
                .bool => try writeBool(self.writer, value),
                .int, .comptime_int => try writeInteger(self.writer, value),
                .float, .comptime_float => try writeFloat(self.writer, value),
                .@"enum" => try writeQuotedEnumTag(self.writer, T, value),
                .optional => {
                    if (value) |child| {
                        try self.writeInlineValue(@TypeOf(child), child);
                    } else {
                        return error.TomlNullUnsupported;
                    }
                },
                .array => |info| {
                    if (info.child == u8) {
                        try writeBasicString(self.writer, value[0..]);
                        return;
                    }
                    try self.writeInlineSequenceContents(T, value);
                },
                .pointer => |info| switch (info.size) {
                    .slice => {
                        if (info.child == u8) {
                            try writeBasicString(self.writer, value);
                            return;
                        }
                        try self.writeInlineSequenceContents(T, value);
                    },
                    .one => try self.writeInlineValue(info.child, value.*),
                    else => return error.UnsupportedType,
                },
                else => return error.UnsupportedType,
            }
        }

        fn writeInlineSequenceContents(self: *Self, comptime T: type, value: T) !void {
            const Child = sequenceChild(T);

            try self.writer.writeByte('[');
            var first = true;

            switch (@typeInfo(Child)) {
                .bool => for (value) |item| {
                    try writeInlineSeparator(self.writer, &first);
                    try writeBool(self.writer, item);
                },
                .int, .comptime_int => for (value) |item| {
                    try writeInlineSeparator(self.writer, &first);
                    try writeInteger(self.writer, item);
                },
                .float, .comptime_float => for (value) |item| {
                    try writeInlineSeparator(self.writer, &first);
                    try writeFloat(self.writer, item);
                },
                .@"enum" => for (value) |item| {
                    try writeInlineSeparator(self.writer, &first);
                    try writeQuotedEnumTag(self.writer, Child, item);
                },
                .array => |info| {
                    if (info.child == u8) {
                        for (value) |item| {
                            try writeInlineSeparator(self.writer, &first);
                            try writeBasicString(self.writer, item[0..]);
                        }
                    } else {
                        for (value) |item| {
                            try writeInlineSeparator(self.writer, &first);
                            try self.writeInlineValue(Child, item);
                        }
                    }
                },
                .pointer => |info| {
                    if (info.size == .slice and info.child == u8) {
                        for (value) |item| {
                            try writeInlineSeparator(self.writer, &first);
                            try writeBasicString(self.writer, item);
                        }
                    } else {
                        for (value) |item| {
                            try writeInlineSeparator(self.writer, &first);
                            try self.writeInlineValue(Child, item);
                        }
                    }
                },
                else => for (value) |item| {
                    try writeInlineSeparator(self.writer, &first);
                    try self.writeInlineValue(Child, item);
                },
            }
            try self.writer.writeByte(']');
        }

        fn pushTable(self: *Self, field_name: []const u8) !void {
            if (self.table_path_len == self.table_path.len) return error.TomlNestingTooDeep;
            self.table_path[self.table_path_len] = field_name;
            self.table_path_len += 1;
        }

        fn popTable(self: *Self) void {
            self.table_path_len -= 1;
        }

        fn pushInlineArray(self: *Self) !void {
            if (self.inline_array_len == self.inline_array_first.len) return error.TomlNestingTooDeep;
            self.inline_array_first[self.inline_array_len] = true;
            self.inline_array_len += 1;
        }

        fn pushArrayTableField(self: *Self, field_name: []const u8) !void {
            if (self.array_table_field_len == self.array_table_field_stack.len) return error.TomlNestingTooDeep;
            self.array_table_field_stack[self.array_table_field_len] = field_name;
            self.array_table_field_len += 1;
        }

        fn popArrayTableField(self: *Self) void {
            self.array_table_field_len -= 1;
        }
    };
}

pub fn serialize(writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(writer, value, .{}, .{});
}

/// Convenience wrapper around the format-neutral typed serializer.
pub fn serializeWith(
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try typed.serialize(@This(), writer, value, serde_cfg, format_cfg);
}

fn isStructType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple,
        .pointer => |info| info.size == .one and isStructType(info.child),
        .optional => |info| isStructType(info.child),
        else => false,
    };
}

fn isArrayOfStructs(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |info| isStructType(info.child),
        .pointer => |info| switch (info.size) {
            .slice => isStructType(info.child),
            .one => isArrayOfStructs(info.child),
            else => false,
        },
        else => false,
    };
}

fn isInlineSequenceType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .array => |info| info.child != u8 and !isStructType(info.child) and !isArrayOfStructs(info.child),
        .pointer => |info| switch (info.size) {
            .slice => info.child != u8 and !isStructType(info.child) and !isArrayOfStructs(info.child),
            else => false,
        },
        else => false,
    };
}

fn sequenceChild(comptime T: type) type {
    return switch (@typeInfo(T)) {
        .array => |info| info.child,
        .pointer => |info| switch (info.size) {
            .slice => info.child,
            .one => sequenceChild(info.child),
            else => @compileError("unsupported sequence type: " ++ @typeName(T)),
        },
        else => @compileError("unsupported sequence type: " ++ @typeName(T)),
    };
}

fn isBareKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |c| {
        if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) {
            return false;
        }
    }
    return true;
}

fn writeBasicString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try writer.writeByte('"');
    var cursor: usize = 0;
    while (cursor <= bytes.len) {
        const escape_index = std.mem.indexOfAnyPos(u8, bytes, cursor, &toml_escape_bytes) orelse bytes.len;
        if (cursor != escape_index) {
            try writer.writeAll(bytes[cursor..escape_index]);
        }
        if (escape_index == bytes.len) break;
        try writeEscapedTomlByte(writer, bytes[escape_index]);
        cursor = escape_index + 1;
    }
    try writer.writeByte('"');
}

fn writeBool(writer: *std.Io.Writer, value: bool) !void {
    if (value) {
        try writer.writeAll("true");
    } else {
        try writer.writeAll("false");
    }
}

fn writeInteger(writer: *std.Io.Writer, value: anytype) !void {
    try writer.print("{d}", .{value});
}

fn writeFloat(writer: *std.Io.Writer, value: anytype) !void {
    if (std.math.isNan(value)) {
        try writer.writeAll("nan");
        return;
    }
    if (std.math.isInf(value)) {
        if (value < 0) {
            try writer.writeAll("-inf");
        } else {
            try writer.writeAll("inf");
        }
        return;
    }
    try writer.print("{d}", .{value});
}

const toml_escape_bytes = [_]u8{
    '"',  '\\',
    '\n', '\r',
    '\t', 0x08,
    0x0c, 0x00,
    0x01, 0x02,
    0x03, 0x04,
    0x05, 0x06,
    0x07, 0x0b,
    0x0e, 0x0f,
    0x10, 0x11,
    0x12, 0x13,
    0x14, 0x15,
    0x16, 0x17,
    0x18, 0x19,
    0x1a, 0x1b,
    0x1c, 0x1d,
    0x1e, 0x1f,
};

fn writeEscapedTomlByte(writer: *std.Io.Writer, byte: u8) !void {
    switch (byte) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\r' => try writer.writeAll("\\r"),
        '\t' => try writer.writeAll("\\t"),
        0x08 => try writer.writeAll("\\b"),
        0x0c => try writer.writeAll("\\f"),
        0x00...0x07, 0x0b, 0x0e...0x1f => {
            const hex = "0123456789abcdef";
            try writer.writeAll("\\u00");
            try writer.writeByte(hex[byte >> 4]);
            try writer.writeByte(hex[byte & 0x0f]);
        },
        else => unreachable,
    }
}

fn writeQuotedEnumTag(writer: *std.Io.Writer, comptime Enum: type, value: Enum) !void {
    inline for (@typeInfo(Enum).@"enum".fields) |field| {
        if (@intFromEnum(value) == field.value) {
            try writer.writeAll(std.fmt.comptimePrint("\"{s}\"", .{field.name}));
            return;
        }
    }
    unreachable;
}

fn writeInlineSeparator(writer: *std.Io.Writer, first: *bool) !void {
    if (!first.*) {
        try writer.writeAll(", ");
    } else {
        first.* = false;
    }
}

test "serialize nested struct to toml" {
    const Config = struct {
        serviceName: []const u8,
        port: u16,
        metadata: struct {
            owner: []const u8,
            retries: []const u8,
        },
        weights: []const f32,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, Config{
        .serviceName = "api",
        .port = 8080,
        .metadata = .{
            .owner = "platform",
            .retries = "three",
        },
        .weights = &.{ 0.5, 1.25 },
    }, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        \\service_name = "api"
        \\port = 8080
        \\weights = [0.5, 1.25]
        \\
        \\[metadata]
        \\owner = "platform"
        \\retries = "three"
        \\
    , out.written());
}

test "serialize TOML string escapes control bytes" {
    const Example = struct {
        value: []const u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serialize(&out.writer, Example{
        .value = "a\x08b\x0cc\x01",
    });

    try std.testing.expectEqualStrings(
        \\value = "a\bb\fc\u0001"
        \\
    , out.written());
}

test "serialize nested inline arrays to toml" {
    const Example = struct {
        values: [2][3]u16,
        labels: [2][2][]const u8,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serialize(&out.writer, Example{
        .values = .{
            .{ 1, 2, 3 },
            .{ 4, 5, 6 },
        },
        .labels = .{
            .{ "a", "b" },
            .{ "c", "d" },
        },
    });

    try std.testing.expectEqualStrings(
        \\values = [[1, 2, 3], [4, 5, 6]]
        \\labels = [["a", "b"], ["c", "d"]]
        \\
    , out.written());
}
