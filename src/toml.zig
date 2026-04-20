//! TOML backend for the typed walk.
//!
//! TOML cannot emit fields in arbitrary order if nested tables are involved, so
//! this backend asks the typed layer for two struct passes: scalars first, then
//! nested tables and arrays-of-tables.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");

pub const WriteConfig = struct {};

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
            if (value) {
                try self.writer.writeAll("true");
            } else {
                try self.writer.writeAll("false");
            }
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.ensureValueContext();
            try self.writer.print("{}", .{value});
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try self.ensureValueContext();
            try self.writer.print("{}", .{value});
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try self.ensureValueContext();
            try writeBasicString(self.writer, value);
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
                const field_name = self.current_field orelse return error.InvalidTomlState;
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
        .pointer => |info| info.size == .slice and isStructType(info.child),
        else => false,
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
    for (bytes) |c| {
        switch (c) {
            '"' => try writer.writeAll("\\\""),
            '\\' => try writer.writeAll("\\\\"),
            '\n' => try writer.writeAll("\\n"),
            '\r' => try writer.writeAll("\\r"),
            '\t' => try writer.writeAll("\\t"),
            else => try writer.writeByte(c),
        }
    }
    try writer.writeByte('"');
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
