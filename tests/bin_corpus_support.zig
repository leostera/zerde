//! Shared binary corpus registry and exact roundtrip assertions.

const std = @import("std");
const corpus = @import("corpus_support");
const zerde = @import("zerde");

pub const Role = enum(u8) {
    captain,
    doctor,
    navigator,
};

pub const EmptyDoc = struct {};

pub const NameDoc = struct {
    name: []const u8,
};

pub const NameActiveDoc = struct {
    name: []const u8,
    active: bool,
};

pub const NestedDoc = struct {
    ship: struct {
        name: []const u8,
        crew: u8,
    },
};

pub const MembersDoc = struct {
    members: []const []const u8,
};

pub const EnumDoc = struct {
    role: Role,
};

pub const FixedBytesDoc = struct {
    code: [4]u8,
};

pub const OptionalDoc = struct {
    name: []const u8,
    note: ?[]const u8,
};

pub const MixedDoc = struct {
    name: []const u8,
    active: bool,
    count: u8,
    ratio: f32,
    role: Role,
};

pub fn expectRoundTripMatches(comptime case_name: []const u8, input: []const u8) !void {
    if (comptime std.mem.eql(u8, case_name, "null.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, ?bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "true.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "false.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "zero.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "positive_int.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "negative_int.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, i64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "big_uint.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, u64, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "float.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, f32, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_empty.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "string_ascii.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const u8, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_empty.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_bool.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const bool, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_int.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "array_enum.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, []const Role, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "nested_int_array.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, [2][2]u16, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_empty.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, EmptyDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_single.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, NameDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_two_fields.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, NameActiveDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_nested.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, NestedDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "object_array.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, MembersDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "enum_field.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, EnumDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "fixed_bytes.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, FixedBytesDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_null.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, OptionalDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "optional_value.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, OptionalDoc, case_name, input, .{}, .{});
    if (comptime std.mem.eql(u8, case_name, "mixed_scalars.bin")) return corpus.expectBinaryRoundTrip(zerde.bin, MixedDoc, case_name, input, .{}, .{});

    @compileError("unregistered binary corpus case: " ++ case_name);
}
