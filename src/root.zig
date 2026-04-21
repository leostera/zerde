//! Public package entrypoints.
//!
//! `zerde` keeps the typed walk separate from the format backend:
//! callers pick a Zig type plus a format module, and the typed layer
//! specializes the read or write path for that exact combination.

const std = @import("std");
const bin_impl = @import("bin.zig");
const bson_impl = @import("bson.zig");
const cbor_impl = @import("cbor.zig");
const json_impl = @import("json.zig");
const msgpack_impl = @import("msgpack.zig");
const toml_impl = @import("toml.zig");
const yaml_impl = @import("yaml.zig");
const meta = @import("meta.zig");
const typed = @import("typed.zig");

pub const FieldCase = meta.FieldCase;
pub const SerdeConfig = meta.SerdeConfig;

pub const bin = bin_impl;
pub const bson = bson_impl;
pub const cbor = cbor_impl;
pub const json = json_impl;
pub const msgpack = msgpack_impl;
pub const toml = toml_impl;
pub const yaml = yaml_impl;

/// Recursively frees values produced by the owning parse paths.
pub fn free(allocator: std.mem.Allocator, value: anytype) void {
    typed.free(allocator, value);
}

/// Serializes `value` with the default serde and format configuration.
pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(Format, writer, value, .{}, .{});
}

/// Serializes `value` with separate typed-layer and format-layer configuration.
pub fn serializeWith(
    comptime Format: type,
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    if (!@hasDecl(Format, "serializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement serializer()");
    }
    try typed.serialize(Format, writer, value, serde_cfg, format_cfg);
}

/// Deserializes `T` from a streaming reader using the format's typed backend.
pub fn deserialize(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !T {
    return deserializeWith(Format, T, allocator, reader, .{}, .{});
}

/// Deserializes `T` from a reader with separate typed-layer and format-layer configuration.
pub fn deserializeWith(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (!@hasDecl(Format, "readerDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement readerDeserializer()");
    }

    var deserializer = try Format.readerDeserializer(allocator, reader, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
    return value;
}

/// Parses `T` from an in-memory slice using the owning slice path.
pub fn parseSlice(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return parseSliceWith(Format, T, allocator, input, .{}, .{});
}

/// Parses from a stable input slice and may alias unescaped strings directly into that slice.
pub fn parseSliceAliased(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return parseSliceAliasedWith(Format, T, allocator, input, .{}, .{});
}

/// Parses `T` from a slice with separate typed-layer and format-layer configuration.
pub fn parseSliceWith(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (!@hasDecl(Format, "sliceDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement sliceDeserializer()");
    }

    var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
    return value;
}

/// Uses a format-specific aliased-slice fast path when the format provides one.
pub fn parseSliceAliasedWith(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (@hasDecl(Format, "parseSliceAliasedWith")) {
        return Format.parseSliceAliasedWith(T, allocator, input, serde_cfg, format_cfg);
    }

    return parseSliceWith(Format, T, allocator, input, serde_cfg, format_cfg);
}

test "generic json entrypoints work" {
    const Example = struct {
        serviceName: []const u8,
        port: u16,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(json, Example, allocator, "{\"service_name\":\"api\",\"port\":8080}", .{
        .rename_all = .snake_case,
    }, .{});
    defer allocator.free(decoded.serviceName);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try serializeWith(json, &out.writer, decoded, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"service_name\":\"api\",\"port\":8080}",
        out.written(),
    );
}

test "generic binary entrypoint works" {
    const Example = struct {
        first_name: []const u8,
        active: bool,
        samples: []const u16,
    };

    const expected = Example{
        .first_name = "Luffy",
        .active = true,
        .samples = &.{ 3, 5, 8 },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(bin, &out.writer, expected);

    const decoded = try parseSliceWith(bin, Example, std.testing.allocator, out.written(), .{}, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "generic toml entrypoint works" {
    const Example = struct {
        firstName: []const u8,
        metadata: struct {
            accountId: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(toml, Example, allocator,
        \\first_name = "Ada"
        \\
        \\[metadata]
        \\account_id = 42
        \\
    , .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(allocator, decoded);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(toml, &out.writer, decoded, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        \\first_name = "Ada"
        \\
        \\[metadata]
        \\account_id = 42
        \\
    , out.written());
}

test "generic cbor entrypoint works" {
    const Example = struct {
        firstName: []const u8,
        metadata: struct {
            accountId: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Ada",
        .metadata = .{
            .accountId = 42,
        },
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(cbor, &out.writer, expected, .{
        .rename_all = .snake_case,
    }, .{});

    const decoded = try parseSliceWith(cbor, Example, std.testing.allocator, out.written(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test "generic yaml entrypoint works" {
    const Example = struct {
        firstName: []const u8,
        members: []const struct {
            accountId: u64,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const input =
        \\first_name: Ada
        \\members:
        \\  - account_id: 42
        \\  - account_id: 99
    ;

    const decoded = try parseSliceWith(yaml, Example, std.testing.allocator, input, .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(usize, 2), decoded.members.len);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(yaml, &out.writer, decoded, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(input, out.written());
}

test "generic msgpack entrypoint works" {
    const Example = struct {
        firstName: []const u8,
        active: bool,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const expected = Example{
        .firstName = "Ada",
        .active = true,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(msgpack, &out.writer, expected, .{
        .rename_all = .snake_case,
    }, .{});

    const decoded = try parseSliceWith(msgpack, Example, std.testing.allocator, out.written(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualDeep(expected, decoded);
}

test {
    _ = @import("bin.zig");
    _ = @import("bin_tests");
    _ = @import("bson.zig");
    _ = @import("bson_tests");
    _ = @import("cbor_tests");
    _ = @import("meta.zig");
    _ = @import("typed.zig");
    _ = @import("cbor.zig");
    _ = @import("json.zig");
    _ = @import("json_tests");
    _ = @import("msgpack.zig");
    _ = @import("msgpack_tests");
    _ = @import("toml.zig");
    _ = @import("toml_tests");
    _ = @import("yaml.zig");
    _ = @import("yaml_tests");
}
