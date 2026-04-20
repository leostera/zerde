//! YAML backend for the typed walk.
//!
//! The serializer writes a practical block-YAML subset directly from the typed
//! walk. The read path lives in `yaml_read.zig` and feeds the same typed
//! deserializer protocol used by the other backends.

const std = @import("std");
const Allocator = std.mem.Allocator;
const typed = @import("typed.zig");
const read_impl = @import("yaml_read.zig");

pub const ReadConfig = read_impl.ReadConfig;
pub const WriteConfig = struct {
    indent_width: usize = 2,
};

pub const readerDeserializer = read_impl.readerDeserializer;
pub const sliceDeserializer = read_impl.sliceDeserializer;
pub const deserialize = read_impl.deserialize;
pub const deserializeWith = read_impl.deserializeWith;
pub const parseSlice = read_impl.parseSlice;
pub const parseSliceWith = read_impl.parseSliceWith;
pub const parseSliceAliased = read_impl.parseSliceAliased;
pub const parseSliceAliasedWith = read_impl.parseSliceAliasedWith;

const ObjectFrame = struct {
    indent: usize,
    sequence_item_indent: ?usize = null,
    first_field_written: bool = false,
};

const ArrayFrame = struct {
    indent: usize,
};

const PendingField = struct {
    line_indent: usize,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) YamlSerializer(@TypeOf(cfg)) {
    return YamlSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn YamlSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        object_stack: [128]ObjectFrame = undefined,
        object_len: usize = 0,
        array_stack: [128]ArrayFrame = undefined,
        array_len: usize = 0,
        pending_field: ?PendingField = null,
        pending_array_item: ?usize = null,

        const Self = @This();

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            try self.prepareValuePrefix();
            try self.writer.writeAll("null");
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.prepareValuePrefix();
            try self.writer.writeAll(if (value) "true" else "false");
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.prepareValuePrefix();
            try self.writer.print("{}", .{value});
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try self.prepareValuePrefix();
            try self.writer.print("{}", .{value});
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try self.prepareValuePrefix();
            try self.writeScalarString(value);
        }

        pub fn emitEnum(self: *Self, comptime _: type, value: anytype) !void {
            try self.prepareValuePrefix();
            try self.writeScalarString(@tagName(value));
        }

        pub fn serializeSequence(self: *Self, comptime Sequence: type, value: Sequence, comptime cfg: anytype) !bool {
            _ = cfg;
            if (!isInlineSequenceType(Sequence)) return false;

            try self.prepareValuePrefix();
            try self.writeInlineValue(Sequence, value);
            return true;
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;

            if (self.pending_array_item) |item_indent| {
                self.pending_array_item = null;
                try self.pushObject(.{
                    .indent = item_indent + effectiveIndentWidth(self.cfg),
                    .sequence_item_indent = item_indent,
                });
                return;
            }

            if (self.pending_field) |field| {
                self.pending_field = null;
                try self.pushObject(.{
                    .indent = field.line_indent + effectiveIndentWidth(self.cfg),
                });
                return;
            }

            try self.pushObject(.{ .indent = 0 });
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
            const frame = self.currentObjectFrame();
            if (frame.first_field_written) try self.writer.writeByte('\n');
            const line_indent = if (frame.sequence_item_indent != null and !frame.first_field_written)
                frame.sequence_item_indent.?
            else
                frame.indent;

            if (frame.sequence_item_indent != null and !frame.first_field_written) {
                try self.writeIndent(line_indent);
                try self.writer.writeAll("- ");
            } else {
                try self.writeIndent(line_indent);
            }
            frame.first_field_written = true;

            try self.writeKey(name);
            try self.writer.writeByte(':');

            if (isCompoundType(FieldType)) {
                try self.writer.writeByte('\n');
                self.pending_field = .{ .line_indent = line_indent };
            } else {
                try self.writer.writeByte(' ');
            }

            return true;
        }

        pub fn beginStructFieldValue(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type, value: FieldType) !bool {
            _ = Parent;

            const frame = self.currentObjectFrame();
            if (frame.first_field_written) try self.writer.writeByte('\n');
            const line_indent = if (frame.sequence_item_indent != null and !frame.first_field_written)
                frame.sequence_item_indent.?
            else
                frame.indent;

            if (frame.sequence_item_indent != null and !frame.first_field_written) {
                try self.writeIndent(line_indent);
                try self.writer.writeAll("- ");
            } else {
                try self.writeIndent(line_indent);
            }
            frame.first_field_written = true;

            try self.writeKey(name);
            try self.writer.writeByte(':');

            if (isCompoundValue(FieldType, value)) {
                try self.writer.writeByte('\n');
                self.pending_field = .{ .line_indent = line_indent };
            } else {
                try self.writer.writeByte(' ');
            }

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
            _ = self.popObject();
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = len;

            if (self.pending_array_item) |item_indent| {
                try self.writeIndent(item_indent);
                try self.writer.writeAll("-\n");
                self.pending_array_item = null;
                try self.pushArray(.{ .indent = item_indent + effectiveIndentWidth(self.cfg) });
                return;
            }

            if (self.pending_field) |field| {
                self.pending_field = null;
                try self.pushArray(.{ .indent = field.line_indent + effectiveIndentWidth(self.cfg) });
                return;
            }

            if (!isCompoundType(Child)) return error.InvalidYamlState;
            try self.pushArray(.{ .indent = 0 });
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = Child;
            if (index != 0) try self.writer.writeByte('\n');
            self.pending_array_item = self.currentArrayFrame().indent;
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            _ = self.popArray();
        }

        fn prepareValuePrefix(self: *Self) !void {
            if (self.pending_array_item) |item_indent| {
                try self.writeIndent(item_indent);
                try self.writer.writeAll("- ");
                self.pending_array_item = null;
            }
        }

        fn writeInlineValue(self: *Self, comptime T: type, value: T) !void {
            switch (@typeInfo(T)) {
                .bool => try self.writer.writeAll(if (value) "true" else "false"),
                .int, .comptime_int, .float, .comptime_float => try self.writer.print("{}", .{value}),
                .optional => {
                    if (value) |child| {
                        try self.writeInlineValue(@TypeOf(child), child);
                    } else {
                        try self.writer.writeAll("null");
                    }
                },
                .@"enum" => try self.writeScalarString(@tagName(value)),
                .array => |info| {
                    if (info.child == u8) {
                        try self.writeScalarString(value[0..]);
                    } else {
                        try self.writeInlineSequence(T, value);
                    }
                },
                .pointer => |info| switch (info.size) {
                    .slice => {
                        if (info.child == u8) {
                            try self.writeScalarString(value);
                        } else {
                            try self.writeInlineSequence(T, value);
                        }
                    },
                    .one => try self.writeInlineValue(info.child, value.*),
                    else => return error.UnsupportedYamlInlineType,
                },
                else => return error.UnsupportedYamlInlineType,
            }
        }

        fn writeInlineSequence(self: *Self, comptime T: type, value: T) !void {
            try self.writer.writeAll("[ ");
            switch (@typeInfo(T)) {
                .array => {
                    for (value, 0..) |item, index| {
                        if (index != 0) try self.writer.writeAll(", ");
                        try self.writeInlineValue(@TypeOf(item), item);
                    }
                },
                .pointer => {
                    for (value, 0..) |item, index| {
                        if (index != 0) try self.writer.writeAll(", ");
                        try self.writeInlineValue(@TypeOf(item), item);
                    }
                },
                else => return error.UnsupportedYamlInlineType,
            }
            try self.writer.writeAll(" ]");
        }

        fn writeKey(self: *Self, key: []const u8) !void {
            if (isPlainKey(key)) {
                try self.writer.writeAll(key);
            } else {
                try self.writeQuotedString(key);
            }
        }

        fn writeScalarString(self: *Self, value: []const u8) !void {
            if (isPlainScalarString(value)) {
                try self.writer.writeAll(value);
            } else {
                try self.writeQuotedString(value);
            }
        }

        fn writeQuotedString(self: *Self, value: []const u8) !void {
            try self.writer.writeByte('"');
            var start: usize = 0;
            for (value, 0..) |char, i| {
                const escaped = switch (char) {
                    '\\' => "\\\\",
                    '"' => "\\\"",
                    '\n' => "\\n",
                    '\r' => "\\r",
                    '\t' => "\\t",
                    else => null,
                };

                if (escaped) |replacement| {
                    if (i > start) try self.writer.writeAll(value[start..i]);
                    try self.writer.writeAll(replacement);
                    start = i + 1;
                }
            }
            if (start < value.len) try self.writer.writeAll(value[start..]);
            try self.writer.writeByte('"');
        }

        fn writeIndent(self: *Self, indent: usize) !void {
            var remaining = indent;
            while (remaining != 0) {
                const chunk = @min(remaining, spaces.len);
                try self.writer.writeAll(spaces[0..chunk]);
                remaining -= chunk;
            }
        }

        fn pushObject(self: *Self, frame: ObjectFrame) !void {
            if (self.object_len == self.object_stack.len) return error.YamlNestingTooDeep;
            self.object_stack[self.object_len] = frame;
            self.object_len += 1;
        }

        fn popObject(self: *Self) ObjectFrame {
            self.object_len -= 1;
            return self.object_stack[self.object_len];
        }

        fn currentObjectFrame(self: *Self) *ObjectFrame {
            return &self.object_stack[self.object_len - 1];
        }

        fn pushArray(self: *Self, frame: ArrayFrame) !void {
            if (self.array_len == self.array_stack.len) return error.YamlNestingTooDeep;
            self.array_stack[self.array_len] = frame;
            self.array_len += 1;
        }

        fn popArray(self: *Self) ArrayFrame {
            self.array_len -= 1;
            return self.array_stack[self.array_len];
        }

        fn currentArrayFrame(self: *Self) *ArrayFrame {
            return &self.array_stack[self.array_len - 1];
        }
    };
}

const spaces = "                                ";

fn effectiveIndentWidth(comptime cfg: anytype) usize {
    return if (@hasField(@TypeOf(cfg), "indent_width")) @field(cfg, "indent_width") else 2;
}

fn isCompoundValue(comptime T: type, value: T) bool {
    return switch (@typeInfo(T)) {
        .optional => if (value) |child|
            isCompoundValue(@TypeOf(child), child)
        else
            false,
        else => isCompoundType(T),
    };
}

fn isCompoundType(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| !info.is_tuple,
        .array => |info| info.child != u8 and !isInlineSequenceType(T),
        .pointer => |info| switch (info.size) {
            .one => isCompoundType(info.child),
            .slice => info.child != u8 and !isInlineSequenceType(T),
            else => false,
        },
        else => false,
    };
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
        .array, .pointer => isInlineSequenceType(T),
        else => false,
    };
}

fn isPlainKey(key: []const u8) bool {
    if (key.len == 0) return false;
    for (key) |char| {
        if (!(std.ascii.isAlphanumeric(char) or char == '_' or char == '-')) return false;
    }
    return true;
}

fn isPlainScalarString(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "null") or
        std.mem.eql(u8, value, "~") or
        std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "yes") or
        std.ascii.eqlIgnoreCase(value, "no") or
        std.ascii.eqlIgnoreCase(value, "on") or
        std.ascii.eqlIgnoreCase(value, "off"))
    {
        return false;
    }

    if (std.fmt.parseInt(i128, value, 0)) |_| {
        return false;
    } else |_| {}

    if (std.fmt.parseFloat(f64, value)) |_| {
        return false;
    } else |_| {}

    if (value[0] == '-' or value[0] == '?' or value[0] == ':' or value[0] == '#' or value[0] == '[' or value[0] == ']') {
        return false;
    }
    if (value[value.len - 1] == ' ') return false;

    for (value) |char| {
        switch (char) {
            '\n', '\r', '\t', '"', '\\', ',', '[', ']', '{', '}', '#' => return false,
            ':' => return false,
            else => {},
        }
    }

    return true;
}

test "serialize and parse struct to yaml" {
    const Member = struct {
        fullName: []const u8,
        admin: bool,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const Example = struct {
        firstName: []const u8,
        active: bool,
        samples: [3]u16,
        metadata: struct {
            accountId: u64,
        },
        members: []const Member,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Ada",
        .active = true,
        .samples = .{ 3, 5, 8 },
        .metadata = .{
            .accountId = 42,
        },
        .members = &.{
            .{ .fullName = "Grace Hopper", .admin = false },
            .{ .fullName = "Edsger Dijkstra", .admin = true },
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, expected, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        \\first_name: Ada
        \\active: true
        \\samples: [ 3, 5, 8 ]
        \\metadata:
        \\  account_id: 42
        \\members:
        \\  - full_name: Grace Hopper
        \\    admin: false
        \\  - full_name: Edsger Dijkstra
        \\    admin: true
    , out.written());

    const decoded = try parseSliceWith(Example, std.testing.allocator, out.written(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "parseSliceAliased reuses yaml string bytes from input" {
    const Example = struct {
        message: []const u8,
    };

    const input =
        \\message: ok
    ;

    const decoded = try parseSliceAliased(Example, std.testing.allocator, input);
    try std.testing.expectEqualStrings("ok", decoded.message);

    const begin = @intFromPtr(input.ptr);
    const end = begin + input.len;
    const ptr = @intFromPtr(decoded.message.ptr);
    try std.testing.expect(ptr >= begin and ptr < end);
}

test "parse quoted yaml string with document markers" {
    const Example = struct {
        name: []const u8,
        port: u16,
    };

    const input =
        \\---
        \\name: "Ada Lovelace"
        \\port: 8080
        \\...
    ;

    const decoded = try parseSlice(Example, std.testing.allocator, input);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada Lovelace", decoded.name);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
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
