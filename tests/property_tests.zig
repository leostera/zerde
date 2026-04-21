//! Property-style roundtrip tests built on top of Zig's stdlib fuzz support.

const std = @import("std");
const zerde = @import("zerde");

const Allocator = std.mem.Allocator;
const Smith = std.testing.Smith;
const Weight = Smith.Weight;

const Role = enum {
    captain,
    navigator,
    cook,
    shipwright,
    musician,
    doctor,
};

const PropertyCase = enum {
    scalars,
    optional,
    renamed,
    nested,
};

const ScalarDoc = struct {
    active: bool,
    signed_value: i32,
    unsigned_value: u32,
    ratio: f32,
    role: Role,
};

const OptionalDoc = struct {
    name: []const u8,
    note: ?[]const u8,
    retries: ?u16,

    pub const serde = .{
        .omit_null_fields = true,
    };
};

const RenameDoc = struct {
    firstName: []const u8,
    posterBounty: u32,
    role: Role,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .posterBounty = .{ .rename = "wanted_amount" },
        },
    };
};

const Member = struct {
    name: []const u8,
    role: Role,
    active: bool,
    bounty: u32,
};

const Metadata = struct {
    dock: u16,
    emergency: bool,
    motto: []const u8,
};

const NestedDoc = struct {
    shipName: []const u8,
    checksum: [6]u8,
    flags: [3]bool,
    matrix: [2][3]u8,
    scores: []const i16,
    labels: []const []const u8,
    crew: []const Member,
    metadata: Metadata,
    note: ?[]const u8,

    pub const serde = .{
        .omit_null_fields = true,
    };
};

const string_weights: []const Weight = &.{
    Weight.rangeAtMost(u8, 'a', 'z', 10),
    Weight.rangeAtMost(u8, 'A', 'Z', 4),
    Weight.rangeAtMost(u8, '0', '9', 3),
    Weight.value(u8, ' ', 2),
    Weight.value(u8, '-', 2),
    Weight.value(u8, '_', 2),
    Weight.value(u8, ':', 1),
    Weight.value(u8, '.', 1),
    Weight.value(u8, '/', 1),
    Weight.value(u8, '\n', 1),
    Weight.value(u8, '\t', 1),
    Weight.value(u8, '"', 1),
    Weight.value(u8, '\\', 1),
};

const byte_weights: []const Weight = &.{
    Weight.rangeAtMost(u8, 'a', 'z', 8),
    Weight.rangeAtMost(u8, 'A', 'Z', 2),
    Weight.rangeAtMost(u8, '0', '9', 2),
    Weight.value(u8, '-', 1),
    Weight.value(u8, '_', 1),
};

fn genLen(smith: *Smith, comptime max: u8) usize {
    return @intCast(smith.valueRangeAtMost(u8, 0, max));
}

fn genString(allocator: Allocator, smith: *Smith, comptime max_len: usize) ![]const u8 {
    var buf: [max_len]u8 = undefined;
    const len = smith.sliceWeightedBytes(&buf, string_weights);
    return allocator.dupe(u8, buf[0..@min(len, max_len)]);
}

fn genFixedBytes(comptime N: usize, smith: *Smith) [N]u8 {
    var out: [N]u8 = undefined;
    for (&out) |*byte| byte.* = smith.valueWeighted(u8, byte_weights);
    return out;
}

fn genBoolArray(comptime N: usize, smith: *Smith) [N]bool {
    var out: [N]bool = undefined;
    for (&out) |*value| value.* = smith.value(bool);
    return out;
}

fn genByteMatrix(smith: *Smith) [2][3]u8 {
    var out: [2][3]u8 = undefined;
    for (&out) |*row| row.* = genFixedBytes(3, smith);
    return out;
}

fn genScores(allocator: Allocator, smith: *Smith) ![]const i16 {
    const len = genLen(smith, 8);
    const values = try allocator.alloc(i16, len);
    for (values) |*value| {
        value.* = smith.valueRangeAtMost(i16, -2_048, 2_048);
    }
    return values;
}

fn genLabels(allocator: Allocator, smith: *Smith) ![]const []const u8 {
    const len = genLen(smith, 6);
    const values = try allocator.alloc([]const u8, len);
    for (values) |*value| {
        value.* = try genString(allocator, smith, 24);
    }
    return values;
}

fn genCrew(allocator: Allocator, smith: *Smith) ![]const Member {
    const len = genLen(smith, 5);
    const values = try allocator.alloc(Member, len);
    for (values) |*value| {
        value.* = try genMember(allocator, smith);
    }
    return values;
}

fn genMaybeString(allocator: Allocator, smith: *Smith, comptime max_len: usize) !?[]const u8 {
    if (smith.valueWeighted(bool, &.{
        Weight.value(bool, false, 3),
        Weight.value(bool, true, 1),
    })) {
        return try genString(allocator, smith, max_len);
    }
    return null;
}

fn genMaybeRetries(smith: *Smith) ?u16 {
    if (smith.valueWeighted(bool, &.{
        Weight.value(bool, false, 2),
        Weight.value(bool, true, 1),
    })) {
        return smith.valueRangeAtMost(u16, 0, 128);
    }
    return null;
}

fn genMember(allocator: Allocator, smith: *Smith) !Member {
    return .{
        .name = try genString(allocator, smith, 18),
        .role = smith.value(Role),
        .active = smith.value(bool),
        .bounty = smith.valueRangeAtMost(u32, 0, 1_000_000_000),
    };
}

fn genScalarDoc(smith: *Smith) ScalarDoc {
    return .{
        .active = smith.value(bool),
        .signed_value = smith.valueRangeAtMost(i32, -1_000_000, 1_000_000),
        .unsigned_value = smith.valueRangeAtMost(u32, 0, 1_000_000),
        .ratio = @as(f32, @floatFromInt(smith.valueRangeAtMost(i32, -10_000, 10_000))) / 32.0,
        .role = smith.value(Role),
    };
}

fn genOptionalDoc(allocator: Allocator, smith: *Smith) !OptionalDoc {
    return .{
        .name = try genString(allocator, smith, 24),
        .note = try genMaybeString(allocator, smith, 32),
        .retries = genMaybeRetries(smith),
    };
}

fn genRenameDoc(allocator: Allocator, smith: *Smith) !RenameDoc {
    return .{
        .firstName = try genString(allocator, smith, 20),
        .posterBounty = smith.valueRangeAtMost(u32, 0, 500_000_000),
        .role = smith.value(Role),
    };
}

fn genNestedDoc(allocator: Allocator, smith: *Smith) !NestedDoc {
    return .{
        .shipName = try genString(allocator, smith, 28),
        .checksum = genFixedBytes(6, smith),
        .flags = genBoolArray(3, smith),
        .matrix = genByteMatrix(smith),
        .scores = try genScores(allocator, smith),
        .labels = try genLabels(allocator, smith),
        .crew = try genCrew(allocator, smith),
        .metadata = .{
            .dock = smith.valueRangeAtMost(u16, 0, 1024),
            .emergency = smith.value(bool),
            .motto = try genString(allocator, smith, 24),
        },
        .note = try genMaybeString(allocator, smith, 24),
    };
}

fn expectRoundTrip(comptime Format: type, comptime T: type, expected: T) !void {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try zerde.serialize(Format, &out.writer, expected);

    const decoded = try zerde.parseSlice(Format, T, std.testing.allocator, out.written());
    defer zerde.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

fn makePropertyHarness(comptime Format: type) type {
    return struct {
        fn run(_: void, smith: *Smith) !void {
            var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
            defer arena.deinit();

            const allocator = arena.allocator();

            switch (smith.value(PropertyCase)) {
                .scalars => try expectRoundTrip(Format, ScalarDoc, genScalarDoc(smith)),
                .optional => try expectRoundTrip(Format, OptionalDoc, try genOptionalDoc(allocator, smith)),
                .renamed => try expectRoundTrip(Format, RenameDoc, try genRenameDoc(allocator, smith)),
                .nested => try expectRoundTrip(Format, NestedDoc, try genNestedDoc(allocator, smith)),
            }
        }
    };
}

test "json property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.json).run, .{});
}

test "zon property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.zon).run, .{});
}

test "toml property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.toml).run, .{});
}

test "yaml property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.yaml).run, .{});
}

test "cbor property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.cbor).run, .{});
}

test "bson property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.bson).run, .{});
}

test "msgpack property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.msgpack).run, .{});
}

test "bin property roundtrip" {
    try std.testing.fuzz({}, makePropertyHarness(zerde.bin).run, .{});
}
