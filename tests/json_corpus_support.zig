//! Shared JSON corpus schema and exact roundtrip assertions.

const std = @import("std");
const zerde = @import("zerde");

pub const DispatchReport = struct {
    convoyId: u64,
    arcName: []const u8,
    sea: Sea,
    active: bool,
    morale: f32,
    alertness: f64,
    intelDelta: i32,
    notes: ?[]const u8,
    callSign: [4]u8,
    checkpoints: [3]u16,
    flagship: Ship,
    alliedCrews: []const Ship,
    islands: []const IslandStop,
    weatherWindows: []const WeatherWindow,
};

const Sea = enum {
    east_blue,
    paradise,
    new_world,
};

const Role = enum {
    captain,
    navigator,
    swordsman,
    cook,
    doctor,
    archaeologist,
    shipwright,
    musician,
    helmsman,
    sniper,
};

const Ship = struct {
    name: []const u8,
    captain: []const u8,
    crewCount: u16,
    colaBarrels: ?u16,
    officers: []const Officer,
};

const Officer = struct {
    name: []const u8,
    role: Role,
    bounty: u32,
    dream: ?[]const u8,
    haki: bool,
};

const IslandStop = struct {
    island: []const u8,
    daysStayed: u8,
    logPoseCharge: f32,
    supplies: []const []const u8,
};

const WeatherWindow = struct {
    label: []const u8,
    waveHeightMeters: f64,
    currentKnots: f32,
    stormsExpected: bool,
};

pub fn expectRoundTripMatches(case_name: []const u8, input: []const u8) !void {
    const allocator = std.testing.allocator;

    const decoded = try zerde.parseSliceWith(zerde.json, DispatchReport, allocator, input, .{
        .rename_all = .snake_case,
        .deny_unknown_fields = true,
    }, .{});
    defer zerde.free(allocator, decoded);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serializeWith(zerde.json, &out.writer, decoded, .{
        .rename_all = .snake_case,
        .deny_unknown_fields = true,
    }, .{});

    if (!std.mem.eql(u8, input, out.written())) {
        printDiff(case_name, input, out.written());
        try std.testing.expectEqualStrings(input, out.written());
    }
}

fn printDiff(case_name: []const u8, expected: []const u8, actual: []const u8) void {
    const mismatch_index = firstMismatch(expected, actual) orelse @min(expected.len, actual.len);

    std.debug.print(
        "\\njson corpus mismatch in {s}: expected {d} bytes, got {d} bytes\\n",
        .{ case_name, expected.len, actual.len },
    );
    std.debug.print("first mismatch at byte {d}\\n", .{mismatch_index});
    std.debug.print("expected context: {s}\\n", .{contextWindow(expected, mismatch_index)});
    std.debug.print("actual context:   {s}\\n", .{contextWindow(actual, mismatch_index)});
}

fn firstMismatch(expected: []const u8, actual: []const u8) ?usize {
    const len = @min(expected.len, actual.len);
    for (0..len) |index| {
        if (expected[index] != actual[index]) return index;
    }
    if (expected.len != actual.len) return len;
    return null;
}

fn contextWindow(bytes: []const u8, index: usize) []const u8 {
    const start = index -| 32;
    const end = @min(bytes.len, index + 32);
    return bytes[start..end];
}
