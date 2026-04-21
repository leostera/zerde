//! ZON backend for the typed walk.
//!
//! ZON is Zig's textual object notation. The typed layer still decides which
//! Zig schema is being traversed; this backend only handles ZON syntax,
//! containers, and literal spelling.

const std = @import("std");
const meta = @import("meta.zig");
const read_impl = @import("zon_read.zig");

const LowSerializer = std.zon.Serializer;

pub const FieldCase = meta.FieldCase;
pub const ReadConfig = read_impl.ReadConfig;
pub const WriteConfig = struct {
    whitespace: bool = false,
};
pub const ParseError = anyerror;

pub const readerDeserializer = read_impl.readerDeserializer;
pub const sliceDeserializer = read_impl.sliceDeserializer;
pub const deserialize = read_impl.deserialize;
pub const deserializeWith = read_impl.deserializeWith;
pub const parseSlice = read_impl.parseSlice;
pub const parseSliceWith = read_impl.parseSliceWith;

const Container = union(enum) {
    object: LowSerializer.Struct,
    array: LowSerializer.Tuple,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) ZonSerializer(@TypeOf(cfg)) {
    return ZonSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn ZonSerializer(comptime Config: type) type {
    return struct {
        low: LowSerializer,
        cfg: Config,
        stack: [128]Container = undefined,
        stack_len: usize = 0,

        const Self = @This();

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .low = .{
                    .writer = writer,
                    .options = .{ .whitespace = effectiveWhitespace(cfg) },
                },
                .cfg = cfg,
            };
        }

        pub fn deinit(self: *Self) void {
            _ = self;
        }

        pub fn emitNull(self: *Self) !void {
            _ = self.cfg;
            try self.low.writer.writeAll("null");
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            try self.low.writer.print("{}", .{value});
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.low.int(value);
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try self.low.float(value);
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try self.low.string(value);
        }

        pub fn emitBytes(self: *Self, value: []const u8) !void {
            // ZON has no dedicated byte-string syntax, so byte arrays normalize to strings.
            try self.emitString(value);
        }

        pub fn emitEnum(self: *Self, comptime Enum: type, value: Enum) !void {
            try self.low.ident(@tagName(value));
        }

        pub fn beginStructSized(self: *Self, comptime T: type, field_count: usize) !void {
            _ = T;
            try self.push(.{
                .object = try self.low.beginStruct(.{
                    .whitespace_style = .{ .fields = field_count },
                }),
            });
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            try self.beginStructSized(T, 0);
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
            switch (self.current().*) {
                .object => |*container| try container.fieldPrefix(name),
                else => return error.InvalidZonState,
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
            var container = self.pop();
            switch (container) {
                .object => |*object| try object.end(),
                else => return error.InvalidZonState,
            }
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            try self.push(.{
                .array = try self.low.beginTuple(.{
                    .whitespace_style = .{ .fields = len },
                }),
            });
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = Child;
            _ = index;
            switch (self.current().*) {
                .array => |*container| try container.fieldPrefix(),
                else => return error.InvalidZonState,
            }
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            var container = self.pop();
            switch (container) {
                .array => |*array| try array.end(),
                else => return error.InvalidZonState,
            }
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.ZonNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
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
    comptime write_cfg: anytype,
) !void {
    const typed = @import("typed.zig");
    try typed.serialize(@This(), writer, value, serde_cfg, write_cfg);
}

fn effectiveWhitespace(cfg: anytype) bool {
    if (@hasField(@TypeOf(cfg), "whitespace")) return cfg.whitespace;
    return false;
}

test "ZON roundtrip keeps typed path working" {
    const root = @import("root.zig");
    const typed = @import("typed.zig");
    const Example = struct {
        name: []const u8,
        bounty: u32,
        role: enum { shipwright, sniper },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const allocator = std.testing.allocator;
    const expected = Example{
        .name = "Franky",
        .bounty = 394_000_000,
        .role = .shipwright,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try root.serialize(root.zon, &out.writer, expected);
    const decoded = try parseSlice(Example, allocator, out.written());
    defer typed.free(allocator, decoded);

    try std.testing.expectEqualStrings(".{.name=\"Franky\",.bounty=394000000,.role=.shipwright}", out.written());
    try std.testing.expectEqualDeep(expected, decoded);
}
