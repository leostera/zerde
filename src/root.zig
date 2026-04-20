const std = @import("std");
const json_impl = @import("json.zig");
const toml_impl = @import("toml.zig");
const meta = @import("meta.zig");
const typed = @import("typed.zig");
const value_mod = @import("value.zig");

pub const FieldCase = meta.FieldCase;
pub const SerdeConfig = meta.SerdeConfig;
pub const Value = value_mod.Value;
pub const ObjectField = value_mod.ObjectField;

pub const json = json_impl;
pub const toml = toml_impl;

pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(Format, writer, value, .{}, .{});
}

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

pub fn deserialize(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, reader: *std.Io.Reader) !T {
    return deserializeWith(Format, T, allocator, reader, .{}, .{});
}

pub fn deserializeWith(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (@hasDecl(Format, "readerDeserializer")) {
        var deserializer = try Format.readerDeserializer(allocator, reader, format_cfg);
        defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);
        const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
        if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
        return value;
    }

    if (!@hasDecl(Format, "readValue")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement readValue()");
    }

    var value = try Format.readValue(allocator, reader, format_cfg);
    defer value.deinit(allocator);
    return typed.fromValue(T, allocator, value, serde_cfg);
}

pub fn parseSlice(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return parseSliceWith(Format, T, allocator, input, .{}, .{});
}

pub fn parseSliceWith(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (@hasDecl(Format, "sliceDeserializer")) {
        var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
        defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);
        const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
        if (@hasDecl(@TypeOf(deserializer), "finish")) try deserializer.finish();
        return value;
    }

    if (!@hasDecl(Format, "parseValue")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement parseValue()");
    }

    var value = try Format.parseValue(allocator, input, format_cfg);
    defer value.deinit(allocator);
    return typed.fromValue(T, allocator, value, serde_cfg);
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

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serializeWith(toml, &out.writer, Example{
        .firstName = "Ada",
        .metadata = .{ .accountId = 42 },
    }, .{
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

test {
    _ = @import("meta.zig");
    _ = @import("typed.zig");
    _ = @import("json.zig");
    _ = @import("toml.zig");
}
