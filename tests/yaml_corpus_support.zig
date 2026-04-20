//! Shared YAML corpus registry and exact roundtrip assertions.

const std = @import("std");
const corpus = @import("corpus_support");
const zerde = @import("zerde");

const Role = enum {
    captain,
    doctor,
    helmsman,
    navigator,
};

const EmptyDoc = struct {};

const NameDoc = struct {
    name: []const u8,
};

const NameActiveDoc = struct {
    name: []const u8,
    active: bool,
};

const NoteDoc = struct {
    note: ?[]const u8,
};

const MixedDoc = struct {
    name: []const u8,
    active: bool,
    samples: [3]u16,
    note: ?[]const u8,
};

const MembersDoc = struct {
    members: []const []const u8,
};

const OfficersDoc = struct {
    officers: []const struct {
        name: []const u8,
        admin: bool,
    },
};

const NestedDoc = struct {
    ship: struct {
        name: []const u8,
        crew: u8,
    },
};

const RenameAllDoc = struct {
    captainName: []const u8,
    crewTotal: u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const FieldRenameDoc = struct {
    captain: []const u8,
    helmsman: []const u8,

    pub const serde = .{
        .fields = .{
            .captain = .{ .rename = "acting_captain" },
            .helmsman = .{ .rename = "sea_driver" },
        },
    };
};

const EnumDoc = struct {
    role: Role,
};

const FixedBytesDoc = struct {
    code: [4]u8,
};

const OptionalDoc = struct {
    name: []const u8,
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
    if (comptime std.mem.eql(u8, case_name, "empty.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "null.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, ?bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "true.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "false.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, f64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_plain.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_quoted.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_unicode.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_float.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const f64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const Role, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_inline_arrays.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, [2][2]u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_object.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, []const NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, NameActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_null.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, NoteDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_optional_omitted.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, OptionalDoc, case_name, input, .{ .omit_null_fields = true }, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty_array.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_sequence_scalars.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_sequence_objects.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, OfficersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, NestedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, MixedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_deep_mix.yaml")) return corpus.expectTextRoundTrip(zerde.yaml, DeepMix, case_name, input, .{}, .{});

    @compileError("unregistered YAML corpus case: " ++ case_name);
}
