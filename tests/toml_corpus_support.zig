//! Shared TOML corpus registry and exact roundtrip assertions.

const std = @import("std");
const corpus = @import("corpus_support");
const zerde = @import("zerde");

const Role = enum {
    captain,
    doctor,
    navigator,
};

const EmptyDoc = struct {};

const NameDoc = struct {
    name: []const u8,
};

const BoolDoc = struct {
    active: bool,
};

const CountDoc = struct {
    count: i64,
};

const DeltaDoc = struct {
    delta: i64,
};

const RatioDoc = struct {
    ratio: f64,
};

const EmptyMembersDoc = struct {
    members: []const bool,
};

const FlagsDoc = struct {
    flags: []const bool,
};

const SamplesDoc = struct {
    samples: []const u16,
};

const RatiosDoc = struct {
    ratios: []const f64,
};

const MembersDoc = struct {
    members: []const []const u8,
};

const RolesDoc = struct {
    roles: []const Role,
};

const InlineArraysDoc = struct {
    values: [2][3]u16,
    labels: [2][2][]const u8,
};

const ServiceDoc = struct {
    serviceName: []const u8,
    port: u16,
    weights: []const f32,
    metadata: struct {
        owner: []const u8,
        retries: []const u8,
    },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const EmptyMetadataDoc = struct {
    metadata: struct {},
};

const EndpointsDoc = struct {
    serviceName: []const u8,
    endpoints: []const struct {
        path: []const u8,
        secure: bool,
    },

    pub const serde = .{
        .rename_all = .snake_case,
    };
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

const MixedScalarsDoc = struct {
    name: []const u8,
    active: bool,
    count: u8,
    ratio: f64,
    code: [4]u8,
};

const EscapedStringDoc = struct {
    value: []const u8,
};

const CrewDoc = struct {
    shipName: []const u8,
    checkpoints: []const u16,
    crew: struct {
        captain: []const u8,
        doctor: []const u8,
    },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub fn expectRoundTripMatches(comptime case_name: []const u8, input: []const u8) !void {
    if (comptime std.mem.eql(u8, case_name, "empty.toml")) return corpus.expectTextRoundTrip(zerde.toml, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string.toml")) return corpus.expectTextRoundTrip(zerde.toml, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "bool_true.toml")) return corpus.expectTextRoundTrip(zerde.toml, BoolDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "bool_false.toml")) return corpus.expectTextRoundTrip(zerde.toml, BoolDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.toml")) return corpus.expectTextRoundTrip(zerde.toml, CountDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.toml")) return corpus.expectTextRoundTrip(zerde.toml, DeltaDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.toml")) return corpus.expectTextRoundTrip(zerde.toml, RatioDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.toml")) return corpus.expectTextRoundTrip(zerde.toml, EmptyMembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.toml")) return corpus.expectTextRoundTrip(zerde.toml, FlagsDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.toml")) return corpus.expectTextRoundTrip(zerde.toml, SamplesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_float.toml")) return corpus.expectTextRoundTrip(zerde.toml, RatiosDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_string.toml")) return corpus.expectTextRoundTrip(zerde.toml, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.toml")) return corpus.expectTextRoundTrip(zerde.toml, RolesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_inline_arrays.toml")) return corpus.expectTextRoundTrip(zerde.toml, InlineArraysDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_table.toml")) return corpus.expectTextRoundTrip(zerde.toml, ServiceDoc, case_name, input, .{ .rename_all = .snake_case }, .{});
    if (comptime std.mem.eql(u8, case_name, "empty_nested_table.toml")) return corpus.expectTextRoundTrip(zerde.toml, EmptyMetadataDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_of_tables.toml")) return corpus.expectTextRoundTrip(zerde.toml, EndpointsDoc, case_name, input, .{ .rename_all = .snake_case }, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.toml")) return corpus.expectTextRoundTrip(zerde.toml, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.toml")) return corpus.expectTextRoundTrip(zerde.toml, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum.toml")) return corpus.expectTextRoundTrip(zerde.toml, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.toml")) return corpus.expectTextRoundTrip(zerde.toml, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_omitted.toml")) return corpus.expectTextRoundTrip(zerde.toml, OptionalDoc, case_name, input, .{ .omit_null_fields = true }, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.toml")) return corpus.expectTextRoundTrip(zerde.toml, MixedScalarsDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "escaped_string.toml")) return corpus.expectTextRoundTrip(zerde.toml, EscapedStringDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_combo.toml")) return corpus.expectTextRoundTrip(zerde.toml, CrewDoc, case_name, input, .{ .rename_all = .snake_case }, .{});

    @compileError("unregistered TOML corpus case: " ++ case_name);
}
