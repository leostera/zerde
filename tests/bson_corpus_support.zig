//! Shared BSON corpus registry and exact roundtrip assertions.

const std = @import("std");
const corpus = @import("corpus_support");
const zerde = @import("zerde");

const Role = enum {
    captain,
    cook,
    doctor,
    navigator,
};

const EmptyDoc = struct {};

const NameDoc = struct {
    name: []const u8,
};

const ActiveDoc = struct {
    active: bool,
};

const CountDoc = struct {
    count: i32,
};

const DeltaDoc = struct {
    delta: i32,
};

const BountyDoc = struct {
    bounty: i64,
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

const MembersDoc = struct {
    members: []const []const u8,
};

const RolesDoc = struct {
    roles: []const Role,
};

const GridDoc = struct {
    values: [2][2]u16,
};

const ShipDoc = struct {
    ship: struct {
        name: []const u8,
        crew: u8,
    },
};

const FleetDoc = struct {
    ships: []const struct {
        name: []const u8,
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

const MixedDoc = struct {
    name: []const u8,
    active: bool,
    count: u8,
    ratio: f32,
    role: Role,
};

pub fn expectRoundTripMatches(comptime case_name: []const u8, input: []const u8) !void {
    if (comptime std.mem.eql(u8, case_name, "empty.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "bool_true.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, ActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "bool_false.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, ActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, CountDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, DeltaDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "int64.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, BountyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, RatioDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, EmptyMembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, FlagsDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, SamplesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_string.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, RolesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_array.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, GridDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_document.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, ShipDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_of_documents.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, FleetDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum_field.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_null.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, OptionalDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_omitted.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, OptionalDoc, case_name, input, .{ .omit_null_fields = true }, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.bson")) return corpus.expectBinaryRoundTrip(zerde.bson, MixedDoc, case_name, input, .{}, .{});

    @compileError("unregistered BSON corpus case: " ++ case_name);
}
