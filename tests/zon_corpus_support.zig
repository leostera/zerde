//! Shared ZON corpus registry and exact roundtrip assertions.

const std = @import("std");
const corpus = @import("corpus_support");
const zerde = @import("zerde");

const Role = enum {
    captain,
    doctor,
    navigator,
    shipwright,
};

const EmptyDoc = struct {};

const NameDoc = struct {
    name: []const u8,
};

const NameActiveDoc = struct {
    name: []const u8,
    active: bool,
};

const MaybeNote = struct {
    note: ?[]const u8,
};

const NamedMaybeNote = struct {
    name: []const u8,
    note: ?[]const u8,
};

const NestedShip = struct {
    ship: struct {
        name: []const u8,
        crew: u8,
    },
};

const Fleet = struct {
    ships: []const NameDoc,
};

const RenameAllDoc = struct {
    captainName: []const u8,
    crewTotal: u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const FieldRenameDoc = struct {
    actingCaptain: []const u8,
    seaDriver: []const u8,

    pub const serde = .{
        .fields = .{
            .actingCaptain = .{ .rename = "acting_captain" },
            .seaDriver = .{ .rename = "sea_driver" },
        },
    };
};

const EnumDoc = struct {
    role: Role,
};

const FixedBytesDoc = struct {
    code: [4]u8,
};

const MixedDoc = struct {
    name: []const u8,
    active: bool,
    count: u8,
    ratio: f64,
    note: ?[]const u8,
};

const DeepMix = struct {
    crew: struct {
        name: []const u8,
        roles: []const Role,
        active: bool,
    },
    log: []const struct {
        island: []const u8,
        days: u8,
    },
    notes: []const u8,
    checkpoints: [3]u16,
};

pub fn expectRoundTripMatches(comptime case_name: []const u8, input: []const u8) !void {
    if (comptime std.mem.eql(u8, case_name, "null.zon")) return corpus.expectTextRoundTrip(zerde.zon, ?bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "true.zon")) return corpus.expectTextRoundTrip(zerde.zon, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "false.zon")) return corpus.expectTextRoundTrip(zerde.zon, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.zon")) return corpus.expectTextRoundTrip(zerde.zon, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "positive_int.zon")) return corpus.expectTextRoundTrip(zerde.zon, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.zon")) return corpus.expectTextRoundTrip(zerde.zon, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fraction.zon")) return corpus.expectTextRoundTrip(zerde.zon, f64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nan.zon")) return corpus.expectTextRoundTrip(zerde.zon, f64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "pos_inf.zon")) return corpus.expectTextRoundTrip(zerde.zon, f64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "neg_inf.zon")) return corpus.expectTextRoundTrip(zerde.zon, f64, case_name, input, .{}, .{});

    if (comptime std.mem.eql(u8, case_name, "string_empty.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_ascii.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_escaped.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const u8, case_name, input, .{}, .{});

    if (comptime std.mem.eql(u8, case_name, "enum.zon")) return corpus.expectTextRoundTrip(zerde.zon, Role, case_name, input, .{}, .{});

    if (comptime std.mem.eql(u8, case_name, "array_bool.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_string.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const Role, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_object.zon")) return corpus.expectTextRoundTrip(zerde.zon, []const NameDoc, case_name, input, .{}, .{});

    if (comptime std.mem.eql(u8, case_name, "empty.zon")) return corpus.expectTextRoundTrip(zerde.zon, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single.zon")) return corpus.expectTextRoundTrip(zerde.zon, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.zon")) return corpus.expectTextRoundTrip(zerde.zon, NameActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_null.zon")) return corpus.expectTextRoundTrip(zerde.zon, MaybeNote, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_omitted.zon")) return corpus.expectTextRoundTrip(zerde.zon, NamedMaybeNote, case_name, input, .{
        .omit_null_fields = true,
    }, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.zon")) return corpus.expectTextRoundTrip(zerde.zon, NestedShip, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested_array.zon")) return corpus.expectTextRoundTrip(zerde.zon, Fleet, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.zon")) return corpus.expectTextRoundTrip(zerde.zon, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.zon")) return corpus.expectTextRoundTrip(zerde.zon, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum_field.zon")) return corpus.expectTextRoundTrip(zerde.zon, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.zon")) return corpus.expectTextRoundTrip(zerde.zon, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.zon")) return corpus.expectTextRoundTrip(zerde.zon, MixedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_deep_mix.zon")) return corpus.expectTextRoundTrip(zerde.zon, DeepMix, case_name, input, .{}, .{});

    @compileError("unregistered ZON corpus case: " ++ case_name);
}
