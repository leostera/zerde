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
const wasm_impl = @import("wasm.zig");
const yaml_impl = @import("yaml.zig");
const diagnostic_impl = @import("diagnostic.zig");
const meta = @import("meta.zig");
const typed = @import("typed.zig");

pub const FieldCase = meta.FieldCase;
pub const SerdeConfig = meta.SerdeConfig;
pub const Diagnostic = diagnostic_impl.Diagnostic;
pub const DiagnosticLocation = diagnostic_impl.Location;
pub const DiagnosticPathSegment = diagnostic_impl.PathSegment;

pub const bin = bin_impl;
pub const bson = bson_impl;
pub const cbor = cbor_impl;
pub const json = json_impl;
pub const msgpack = msgpack_impl;
pub const toml = toml_impl;
pub const wasm = wasm_impl;
pub const yaml = yaml_impl;

/// Arena-backed parsed value that can be released in one call.
pub fn Owned(comptime T: type) type {
    return struct {
        arena: std.heap.ArenaAllocator,
        value: T,

        pub fn deinit(self: *@This()) void {
            self.arena.deinit();
            self.* = undefined;
        }
    };
}

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

/// Deserializes `T` into an internal arena so callers can release the full result in one call.
pub fn deserializeOwned(comptime Format: type, comptime T: type, backing_allocator: std.mem.Allocator, reader: *std.Io.Reader) !Owned(T) {
    return deserializeOwnedWith(Format, T, backing_allocator, reader, .{}, .{});
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

/// Deserializes `T` while populating `diagnostic` with field-path and location context on failure.
pub fn deserializeWithDiagnostics(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    diagnostic: *Diagnostic,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    diagnostic.clear();

    if (!@hasDecl(Format, "readerDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement readerDeserializer()");
    }

    var deserializer = try Format.readerDeserializer(allocator, reader, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);

    const value = typed.deserializeWithDiagnostics(T, allocator, &deserializer, serde_cfg, diagnostic) catch |err| {
        diagnostic.captureFromDeserializer(&deserializer);
        return err;
    };

    if (@hasDecl(@TypeOf(deserializer), "finish")) {
        deserializer.finish() catch |err| {
            diagnostic.captureFromDeserializer(&deserializer);
            return err;
        };
    }

    return value;
}

/// Deserializes `T` with separate typed-layer and format-layer configuration into an internal arena.
pub fn deserializeOwnedWith(
    comptime Format: type,
    comptime T: type,
    backing_allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Owned(T) {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const value = try deserializeWith(Format, T, arena.allocator(), reader, serde_cfg, format_cfg);
    return .{
        .arena = arena,
        .value = value,
    };
}

/// Parses `T` from an in-memory slice using the owning slice path.
pub fn parseSlice(comptime Format: type, comptime T: type, allocator: std.mem.Allocator, input: []const u8) !T {
    return parseSliceWith(Format, T, allocator, input, .{}, .{});
}

/// Parses `T` into an internal arena so callers can release the full result in one call.
pub fn parseSliceOwned(comptime Format: type, comptime T: type, backing_allocator: std.mem.Allocator, input: []const u8) !Owned(T) {
    return parseSliceOwnedWith(Format, T, backing_allocator, input, .{}, .{});
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

/// Parses `T` from a slice while populating `diagnostic` with field-path and location context on failure.
pub fn parseSliceWithDiagnostics(
    comptime Format: type,
    comptime T: type,
    allocator: std.mem.Allocator,
    input: []const u8,
    diagnostic: *Diagnostic,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    diagnostic.clear();

    if (!@hasDecl(Format, "sliceDeserializer")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement sliceDeserializer()");
    }

    var deserializer = try Format.sliceDeserializer(allocator, input, format_cfg);
    defer if (@hasDecl(@TypeOf(deserializer), "deinit")) deserializer.deinit(allocator);

    const value = typed.deserializeWithDiagnostics(T, allocator, &deserializer, serde_cfg, diagnostic) catch |err| {
        diagnostic.captureFromDeserializer(&deserializer);
        return err;
    };

    if (@hasDecl(@TypeOf(deserializer), "finish")) {
        deserializer.finish() catch |err| {
            diagnostic.captureFromDeserializer(&deserializer);
            return err;
        };
    }

    return value;
}

/// Parses `T` with separate typed-layer and format-layer configuration into an internal arena.
pub fn parseSliceOwnedWith(
    comptime Format: type,
    comptime T: type,
    backing_allocator: std.mem.Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !Owned(T) {
    var arena = std.heap.ArenaAllocator.init(backing_allocator);
    errdefer arena.deinit();
    const value = try parseSliceWith(Format, T, arena.allocator(), input, serde_cfg, format_cfg);
    return .{
        .arena = arena,
        .value = value,
    };
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

const AllocationMetadata = struct {
    shipwrightTitle: []const u8,
    colaPowered: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const AllocationExample = struct {
    name: []const u8,
    bounty: u32,
    notes: []const u16,
    metadata: AllocationMetadata,
    extra: ?[]const u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const allocation_example_json =
    \\{"name":"Franky","bounty":394000000,"notes":[3,5,8,13],"metadata":{"shipwright_title":"Iron\nPirate","cola_powered":true},"extra":"BF-37"}
;

const allocation_example_invalid_json =
    \\{"name":"Franky","bounty":394000000,"notes":[3,5,8,13],"metadata":{"shipwright_title":"Iron\nPirate","cola_powered":true},"extra":99}
;

fn expectAllocationExample(value: AllocationExample) !void {
    try std.testing.expectEqualStrings("Franky", value.name);
    try std.testing.expectEqual(@as(u32, 394000000), value.bounty);
    try std.testing.expectEqualSlices(u16, &.{ 3, 5, 8, 13 }, value.notes);
    try std.testing.expectEqualStrings("Iron\nPirate", value.metadata.shipwrightTitle);
    try std.testing.expect(value.metadata.colaPowered);
    try std.testing.expect(value.extra != null);
    try std.testing.expectEqualStrings("BF-37", value.extra.?);
}

fn parseSliceAllocationTest(allocator: std.mem.Allocator) !void {
    const decoded = try parseSlice(json, AllocationExample, allocator, allocation_example_json);
    defer free(allocator, decoded);
    try expectAllocationExample(decoded);
}

fn parseSliceAliasedAllocationTest(allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    const decoded = try parseSliceAliased(json, AllocationExample, arena.allocator(), allocation_example_json);
    try expectAllocationExample(decoded);
}

fn parseSliceOwnedAllocationTest(allocator: std.mem.Allocator) !void {
    var owned = try parseSliceOwned(json, AllocationExample, allocator, allocation_example_json);
    defer owned.deinit();
    try expectAllocationExample(owned.value);
}

fn deserializeAllocationTest(allocator: std.mem.Allocator) !void {
    var reader: std.Io.Reader = .fixed(allocation_example_json);
    const decoded = try deserialize(json, AllocationExample, allocator, &reader);
    defer free(allocator, decoded);
    try expectAllocationExample(decoded);
}

fn deserializeOwnedAllocationTest(allocator: std.mem.Allocator) !void {
    var reader: std.Io.Reader = .fixed(allocation_example_json);
    var owned = try deserializeOwned(json, AllocationExample, allocator, &reader);
    defer owned.deinit();
    try expectAllocationExample(owned.value);
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

test "parseSliceOwned frees with one arena deinit" {
    const CrewMate = struct {
        name: []const u8,
        bounty: u32,
    };

    var owned = try parseSliceOwned(json, CrewMate, std.testing.allocator, "{\"name\":\"Sanji\",\"bounty\":330000000}");
    defer owned.deinit();

    try std.testing.expectEqualStrings("Sanji", owned.value.name);
    try std.testing.expectEqual(@as(u32, 330000000), owned.value.bounty);
}

test "deserializeOwned frees with one arena deinit" {
    const CrewMate = struct {
        name: []const u8,
        active: bool,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try serialize(bin, &out.writer, CrewMate{
        .name = "Robin",
        .active = true,
    });

    var reader: std.Io.Reader = .fixed(out.written());
    var owned = try deserializeOwned(bin, CrewMate, std.testing.allocator, &reader);
    defer owned.deinit();

    try std.testing.expectEqualStrings("Robin", owned.value.name);
    try std.testing.expect(owned.value.active);
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

test "parseSliceWithDiagnostics captures json path and location" {
    const Example = struct {
        crew: []const struct {
            bounty: u32,
        },
    };

    var diagnostic: Diagnostic = .{};
    var captured_err: anyerror = undefined;
    if (parseSliceWithDiagnostics(
        json,
        Example,
        std.testing.allocator,
        "{\"crew\":[{\"bounty\":\"oops\"}]}",
        &diagnostic,
        .{},
        .{},
    )) |_| {
        return error.TestUnexpectedSuccess;
    } else |decode_err| {
        captured_err = decode_err;
    }

    try std.testing.expectEqual(error.InvalidNumber, captured_err);

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try diagnostic.format(&out.writer, captured_err);

    try std.testing.expectEqualStrings(
        "InvalidNumber at root.crew[0].bounty (offset 19, line 1, column 20)",
        out.written(),
    );
}

test "public parse APIs unwind cleanly on allocation failure" {
    const allocator = std.testing.allocator;

    try std.testing.checkAllAllocationFailures(allocator, parseSliceAllocationTest, .{});
    try std.testing.checkAllAllocationFailures(allocator, parseSliceAliasedAllocationTest, .{});
    try std.testing.checkAllAllocationFailures(allocator, parseSliceOwnedAllocationTest, .{});
    try std.testing.checkAllAllocationFailures(allocator, deserializeAllocationTest, .{});
    try std.testing.checkAllAllocationFailures(allocator, deserializeOwnedAllocationTest, .{});
}

test "parseSlice does not leak after invalid input fails late" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    if (parseSlice(json, AllocationExample, gpa.allocator(), allocation_example_invalid_json)) |_| {
        return error.TestUnexpectedSuccess;
    } else |_| {}
}

test "parseSliceAliased does not leak after invalid input fails late" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var arena = std.heap.ArenaAllocator.init(gpa.allocator());
    defer arena.deinit();

    if (parseSliceAliased(json, AllocationExample, arena.allocator(), allocation_example_invalid_json)) |_| {
        return error.TestUnexpectedSuccess;
    } else |_| {}
}

test "parseSliceOwned does not leak after invalid input fails late" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    if (parseSliceOwned(json, AllocationExample, gpa.allocator(), allocation_example_invalid_json)) |_| {
        return error.TestUnexpectedSuccess;
    } else |_| {}
}

test "deserialize does not leak after invalid input fails late" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var reader: std.Io.Reader = .fixed(allocation_example_invalid_json);
    if (deserialize(json, AllocationExample, gpa.allocator(), &reader)) |_| {
        return error.TestUnexpectedSuccess;
    } else |_| {}
}

test "deserializeOwned does not leak after invalid input fails late" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var reader: std.Io.Reader = .fixed(allocation_example_invalid_json);
    if (deserializeOwned(json, AllocationExample, gpa.allocator(), &reader)) |_| {
        return error.TestUnexpectedSuccess;
    } else |_| {}
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
    _ = @import("wasm.zig");
    _ = @import("yaml.zig");
    _ = @import("yaml_tests");
}
