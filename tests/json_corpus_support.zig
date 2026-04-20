//! Shared JSON corpus registry and exact roundtrip assertions.
//!
//! The corpus is feature-first: each fixture picks the smallest Zig type that
//! expresses the JSON shape under test instead of routing every file through one
//! large schema.

const std = @import("std");
const zerde = @import("zerde");

const Role = enum {
    captain,
    cook,
    doctor,
    navigator,
    helmsman,
};

const EmptyObject = struct {};

const NameOnly = struct {
    name: []const u8,
};

const NameActive = struct {
    name: []const u8,
    active: bool,
};

const NumericFields = struct {
    count: u8,
    price: f64,
    delta: i8,
};

const EmptyMembers = struct {
    members: []const bool,
};

const EmptyMetadata = struct {
    metadata: EmptyObject,
};

const Ship = struct {
    name: []const u8,
    crew: u8,
};

const NestedShip = struct {
    ship: Ship,
};

const Fleet = struct {
    ships: []const NameOnly,
};

const MaybeNote = struct {
    note: ?[]const u8,
};

const NamedMaybeNote = struct {
    name: []const u8,
    note: ?[]const u8,
};

const SnakeCaseSummary = struct {
    captainName: []const u8,
    crewTotal: u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const FieldRenameSummary = struct {
    captain: []const u8,
    helmsman: []const u8,

    pub const serde = .{
        .fields = .{
            .captain = .{ .rename = "acting_captain" },
            .helmsman = .{ .rename = "sea_driver" },
        },
    };
};

const RoleField = struct {
    role: Role,
};

const FixedBytes = struct {
    code: [4]u8,
};

const FixedSamples = struct {
    samples: [3]u16,
};

const MixedScalars = struct {
    name: []const u8,
    active: bool,
    count: u8,
    ratio: f64,
    note: ?[]const u8,
};

const EscapedFields = struct {
    message: []const u8,
    quote: []const u8,
};

const UnicodeFields = struct {
    name: []const u8,
    role: []const u8,
};

const LogEntry = struct {
    island: []const u8,
    days: u8,
};

const DeepCrew = struct {
    name: []const u8,
    roles: []const Role,
    active: bool,
};

const DeepMix = struct {
    crew: DeepCrew,
    log: []const LogEntry,
    notes: ?[]const u8,
    checkpoints: [3]u16,
};

pub fn expectRoundTripMatches(comptime case_name: []const u8, input: []const u8) !void {
    if (comptime std.mem.eql(u8, case_name, "null.json")) return expectCase(?bool, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "true.json")) return expectCase(bool, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "false.json")) return expectCase(bool, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.json")) return expectCase(i64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "positive_int.json")) return expectCase(u64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.json")) return expectCase(i64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "big_uint.json")) return expectCase(u64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "fraction.json")) return expectCase(f64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_fraction.json")) return expectCase(f64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "precise_fraction.json")) return expectCase(f64, case_name, input, .{});

    if (comptime std.mem.eql(u8, case_name, "string_empty.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_ascii.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_quote.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_backslash.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_newline.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_tab.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_carriage_return.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_backspace.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped_formfeed.json")) return expectCase([]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "string_unicode_utf8.json")) return expectCase([]const u8, case_name, input, .{});

    if (comptime std.mem.eql(u8, case_name, "array_empty.json")) return expectCase([]const bool, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.json")) return expectCase([]const bool, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.json")) return expectCase([]const i64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_negative_int.json")) return expectCase([]const i64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_float.json")) return expectCase([]const f64, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_string.json")) return expectCase([]const []const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.json")) return expectCase([]const Role, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_nested_int.json")) return expectCase([3][2]u16, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_nested_string.json")) return expectCase([2][2][]const u8, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "array_object.json")) return expectCase([]const NameOnly, case_name, input, .{});

    if (comptime std.mem.eql(u8, case_name, "object_empty.json")) return expectCase(EmptyObject, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single_field.json")) return expectCase(NameOnly, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.json")) return expectCase(NameActive, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_numeric_fields.json")) return expectCase(NumericFields, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty_array.json")) return expectCase(EmptyMembers, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty_object.json")) return expectCase(EmptyMetadata, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.json")) return expectCase(NestedShip, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested_array.json")) return expectCase(Fleet, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_null.json")) return expectCase(MaybeNote, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_value.json")) return expectCase(MaybeNote, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_omitted.json")) return expectCase(NamedMaybeNote, case_name, input, .{
        .omit_null_fields = true,
    });
    if (comptime std.mem.eql(u8, case_name, "object_rename_all_snake_case.json")) return expectCase(SnakeCaseSummary, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_field_rename.json")) return expectCase(FieldRenameSummary, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_enum_field.json")) return expectCase(RoleField, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_fixed_bytes.json")) return expectCase(FixedBytes, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_fixed_int_array.json")) return expectCase(FixedSamples, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_mixed_scalars.json")) return expectCase(MixedScalars, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_escaped_fields.json")) return expectCase(EscapedFields, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_unicode_fields.json")) return expectCase(UnicodeFields, case_name, input, .{});
    if (comptime std.mem.eql(u8, case_name, "object_deep_mix.json")) return expectCase(DeepMix, case_name, input, .{});

    @compileError("unregistered JSON corpus case: " ++ case_name);
}

fn expectCase(comptime T: type, comptime case_name: []const u8, input: []const u8, comptime serde_cfg: anytype) !void {
    const allocator = std.testing.allocator;

    const decoded = try zerde.parseSliceWith(zerde.json, T, allocator, input, serde_cfg, .{});
    defer zerde.free(allocator, decoded);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serializeWith(zerde.json, &out.writer, decoded, serde_cfg, .{});

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
