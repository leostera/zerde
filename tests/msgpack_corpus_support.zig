//! Shared MessagePack corpus registry and exact roundtrip assertions.

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
    if (comptime std.mem.eql(u8, case_name, "null.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, ?bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "true.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "false.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "positive_int.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "big_uint.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, f32, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_empty.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_ascii.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, []const Role, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_int_array.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, [2][2]u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, NameActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, NestedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_array.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "rename_all.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, RenameAllDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "field_rename.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, FieldRenameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum_field.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_null.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, OptionalDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_omitted.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, OptionalDoc, case_name, input, .{ .omit_null_fields = true }, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.msgpack")) return corpus.expectBinaryRoundTrip(zerde.msgpack, MixedDoc, case_name, input, .{}, .{});

    @compileError("unregistered MessagePack corpus case: " ++ case_name);
}
