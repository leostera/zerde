//! Shared CBOR corpus registry and exact roundtrip assertions.

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

const NameActiveDoc = struct {
    name: []const u8,
    active: bool,
};

const NestedDoc = struct {
    ship: struct {
        name: []const u8,
        crew: u8,
    },
};

const MembersDoc = struct {
    members: []const []const u8,
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
    doctor: []const u8,

    pub const serde = .{
        .fields = .{
            .captain = .{ .rename = "acting_captain" },
            .doctor = .{ .rename = "chief_doctor" },
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
    if (comptime std.mem.eql(u8, case_name, "null.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, ?bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "true.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "false.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "positive_int.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "big_uint.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, f32, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_empty.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_ascii.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, []const Role, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_int_array.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, [2][2]u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, NameActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, NestedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_array.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum_field.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_null.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, OptionalDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_omitted.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, OptionalDoc, case_name, input, .{ .omit_null_fields = true }, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.cbor")) return corpus.expectBinaryRoundTrip(zerde.cbor, MixedDoc, case_name, input, .{}, .{});

    @compileError("unregistered CBOR corpus case: " ++ case_name);
}
