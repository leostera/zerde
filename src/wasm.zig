//! WebAssembly / WASI interop helpers.
//!
//! This module does not define a new wire format. It packages existing format
//! backends behind pointer+length helpers that are convenient to expose from
//! wasm exports or accept from JS-hosted callers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bin = @import("bin.zig");
const json = @import("json.zig");
const msgpack = @import("msgpack.zig");
const typed = @import("typed.zig");
const yaml = @import("yaml.zig");

/// Pointer+length pair that is friendly to wasm exports.
///
/// On wasm32 targets, both fields are naturally 32-bit `usize` values that JS
/// can feed into `Uint8Array(memory.buffer, ptr, len)`.
pub const Slice = extern struct {
    ptr: usize,
    len: usize,
};

/// Owns a serialized payload until the caller is done exposing it.
pub const OwnedBuffer = struct {
    out: std.Io.Writer.Allocating,

    pub fn deinit(self: *OwnedBuffer) void {
        self.out.deinit();
        self.* = undefined;
    }

    pub fn bytes(self: *OwnedBuffer) []const u8 {
        return self.out.written();
    }

    pub fn descriptor(self: *OwnedBuffer) Slice {
        return sliceDescriptor(self.bytes());
    }
};

/// Converts a byte slice into a pointer+length pair for FFI use.
pub fn sliceDescriptor(bytes: []const u8) Slice {
    return .{
        .ptr = @intFromPtr(bytes.ptr),
        .len = bytes.len,
    };
}

/// Reconstructs a byte slice from raw pointer+length parts.
pub fn bytesFromParts(ptr: [*]const u8, len: usize) []const u8 {
    return ptr[0..len];
}

/// Reconstructs a byte slice from an exported pointer+length descriptor.
pub fn bytesFromDescriptor(value: Slice) []const u8 {
    const ptr: [*]const u8 = @ptrFromInt(value.ptr);
    return ptr[0..value.len];
}

/// Serializes `value` into an owned wasm-friendly buffer using the compact binary backend.
pub fn serializeOwned(allocator: Allocator, value: anytype) !OwnedBuffer {
    return serializeFormatOwned(bin, allocator, value);
}

/// Serializes `value` into an owned wasm-friendly buffer with custom typed and binary config.
pub fn serializeOwnedWith(
    allocator: Allocator,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !OwnedBuffer {
    return serializeFormatOwnedWith(bin, allocator, value, serde_cfg, format_cfg);
}

/// Serializes `value` into an owned wasm-friendly buffer using the selected format.
pub fn serializeFormatOwned(comptime Format: type, allocator: Allocator, value: anytype) !OwnedBuffer {
    return serializeFormatOwnedWith(Format, allocator, value, .{}, .{});
}

/// Serializes `value` into an owned wasm-friendly buffer with custom typed and format config.
pub fn serializeFormatOwnedWith(
    comptime Format: type,
    allocator: Allocator,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !OwnedBuffer {
    if (!@hasDecl(Format, "serializeWith")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement serializeWith()");
    }

    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try Format.serializeWith(&out.writer, value, serde_cfg, format_cfg);
    return .{ .out = out };
}

/// Parses a typed value from a wasm pointer+length descriptor with the compact binary backend.
pub fn parse(comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseFormat(bin, T, allocator, value);
}

/// Parses a typed value from raw pointer+length parts with the compact binary backend.
pub fn parseParts(comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parseFormatParts(bin, T, allocator, ptr, len);
}

/// Parses a typed value from a wasm pointer+length descriptor with custom typed and binary config.
pub fn parseWith(
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatWith(bin, T, allocator, value, serde_cfg, format_cfg);
}

/// Parses a typed value from raw pointer+length parts with custom typed and binary config.
pub fn parsePartsWith(
    comptime T: type,
    allocator: Allocator,
    ptr: [*]const u8,
    len: usize,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatPartsWith(bin, T, allocator, ptr, len, serde_cfg, format_cfg);
}

/// Parses a typed value and may alias borrowed strings directly into the wasm input buffer.
pub fn parseAliased(comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseFormatAliased(bin, T, allocator, value);
}

/// Parses from raw pointer+length parts and may alias borrowed strings directly into the wasm input buffer.
pub fn parsePartsAliased(comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parseFormatPartsAliased(bin, T, allocator, ptr, len);
}

/// Parses a typed value from a wasm pointer+length descriptor and may alias borrowed strings.
pub fn parseAliasedWith(
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatAliasedWith(bin, T, allocator, value, serde_cfg, format_cfg);
}

/// Parses from raw pointer+length parts and may alias borrowed strings with custom config.
pub fn parsePartsAliasedWith(
    comptime T: type,
    allocator: Allocator,
    ptr: [*]const u8,
    len: usize,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatPartsAliasedWith(bin, T, allocator, ptr, len, serde_cfg, format_cfg);
}

/// Parses a typed value from a wasm pointer+length descriptor using the selected format.
pub fn parseFormat(comptime Format: type, comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseFormatWith(Format, T, allocator, value, .{}, .{});
}

/// Parses a typed value from raw pointer+length parts using the selected format.
pub fn parseFormatParts(comptime Format: type, comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parseFormatPartsWith(Format, T, allocator, ptr, len, .{}, .{});
}

/// Parses a typed value from a wasm pointer+length descriptor with custom typed and format config.
pub fn parseFormatWith(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatPartsWith(Format, T, allocator, @ptrFromInt(value.ptr), value.len, serde_cfg, format_cfg);
}

/// Parses a typed value from raw pointer+length parts with custom typed and format config.
pub fn parseFormatPartsWith(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    ptr: [*]const u8,
    len: usize,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (!@hasDecl(Format, "parseSliceWith")) {
        @compileError("format " ++ @typeName(Format) ++ " does not implement parseSliceWith()");
    }

    return Format.parseSliceWith(T, allocator, bytesFromParts(ptr, len), serde_cfg, format_cfg);
}

/// Parses a typed value from a wasm pointer+length descriptor and may alias borrowed strings.
pub fn parseFormatAliased(comptime Format: type, comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseFormatAliasedWith(Format, T, allocator, value, .{}, .{});
}

/// Parses from raw pointer+length parts and may alias borrowed strings.
pub fn parseFormatPartsAliased(comptime Format: type, comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parseFormatPartsAliasedWith(Format, T, allocator, ptr, len, .{}, .{});
}

/// Parses a typed value from a wasm pointer+length descriptor and may alias borrowed strings.
pub fn parseFormatAliasedWith(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return parseFormatPartsAliasedWith(Format, T, allocator, @ptrFromInt(value.ptr), value.len, serde_cfg, format_cfg);
}

/// Parses from raw pointer+length parts and may alias borrowed strings with custom config.
pub fn parseFormatPartsAliasedWith(
    comptime Format: type,
    comptime T: type,
    allocator: Allocator,
    ptr: [*]const u8,
    len: usize,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    if (@hasDecl(Format, "parseSliceAliasedWith")) {
        return Format.parseSliceAliasedWith(T, allocator, bytesFromParts(ptr, len), serde_cfg, format_cfg);
    }

    return parseFormatPartsWith(Format, T, allocator, ptr, len, serde_cfg, format_cfg);
}

test "serializeOwned exposes pointer length descriptor" {
    const CrewMate = struct {
        name: []const u8,
        bounty: u32,
        role: enum(u8) {
            shipwright,
            navigator,
        },
    };

    var encoded = try serializeOwned(std.testing.allocator, CrewMate{
        .name = "Franky",
        .bounty = 394_000_000,
        .role = .shipwright,
    });
    defer encoded.deinit();

    const bytes = encoded.bytes();
    const parts = encoded.descriptor();

    try std.testing.expectEqual(@intFromPtr(bytes.ptr), parts.ptr);
    try std.testing.expectEqual(bytes.len, parts.len);

    const decoded = try parse(CrewMate, std.testing.allocator, parts);
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Franky", decoded.name);
    try std.testing.expectEqual(@as(u32, 394_000_000), decoded.bounty);
    try std.testing.expectEqual(.shipwright, decoded.role);
}

test "parse keeps strings owned by default" {
    const Example = struct {
        name: []const u8,
    };

    var encoded = try serializeOwned(std.testing.allocator, Example{
        .name = "Sunny",
    });
    defer encoded.deinit();

    const parts = encoded.descriptor();
    const decoded = try parse(Example, std.testing.allocator, parts);
    defer typed.free(std.testing.allocator, decoded);

    const begin = @intFromPtr(encoded.bytes().ptr);
    const end = begin + encoded.bytes().len;
    const name_ptr = @intFromPtr(decoded.name.ptr);

    try std.testing.expect(name_ptr < begin or name_ptr >= end);
    try std.testing.expectEqualStrings("Sunny", decoded.name);
}

test "parseAliased may borrow strings from the wasm buffer" {
    const Example = struct {
        name: []const u8,
    };

    var encoded = try serializeOwned(std.testing.allocator, Example{
        .name = "Mille Sunny",
    });
    defer encoded.deinit();

    const parts = encoded.descriptor();
    const decoded = try parseAliased(Example, std.testing.allocator, parts);

    const begin = @intFromPtr(encoded.bytes().ptr);
    const end = begin + encoded.bytes().len;
    const name_ptr = @intFromPtr(decoded.name.ptr);

    try std.testing.expect(name_ptr >= begin and name_ptr < end);
    try std.testing.expectEqualStrings("Mille Sunny", decoded.name);
}

test "parseParts entrypoints mirror descriptor entrypoints" {
    const Example = struct {
        title: []const u8,
        code: u32,
    };

    var encoded = try serializeOwned(std.testing.allocator, Example{
        .title = "Thousand Sunny",
        .code = 1000,
    });
    defer encoded.deinit();

    const bytes = encoded.bytes();

    const owned = try parseParts(Example, std.testing.allocator, bytes.ptr, bytes.len);
    defer typed.free(std.testing.allocator, owned);
    try std.testing.expectEqualStrings("Thousand Sunny", owned.title);
    try std.testing.expectEqual(@as(u32, 1000), owned.code);

    const aliased = try parsePartsAliased(Example, std.testing.allocator, bytes.ptr, bytes.len);
    try std.testing.expectEqualStrings("Thousand Sunny", aliased.title);
    try std.testing.expectEqual(@as(u32, 1000), aliased.code);

    const begin = @intFromPtr(bytes.ptr);
    const end = begin + bytes.len;
    const title_ptr = @intFromPtr(aliased.title.ptr);

    try std.testing.expect(title_ptr >= begin and title_ptr < end);
}

test "format helpers roundtrip JSON through wasm pointers" {
    const Example = struct {
        captainName: []const u8,
        bounty: u32,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    var encoded = try serializeFormatOwnedWith(json, std.testing.allocator, Example{
        .captainName = "Luffy",
        .bounty = 3_000_000_000,
    }, .{
        .rename_all = .snake_case,
    }, .{});
    defer encoded.deinit();

    const decoded = try parseFormatWith(json, Example, std.testing.allocator, encoded.descriptor(), .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(std.testing.allocator, decoded);

    try std.testing.expectEqualStrings("Luffy", decoded.captainName);
    try std.testing.expectEqual(@as(u32, 3_000_000_000), decoded.bounty);
}

test "format helpers parse YAML inside wasm" {
    const Example = struct {
        serviceName: []const u8,
        port: u16,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const yaml_bytes =
        \\service_name: sunny
        \\port: 8080
    ;

    const decoded = try parseFormatAliasedWith(yaml, Example, std.testing.allocator, sliceDescriptor(yaml_bytes), .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings("sunny", decoded.serviceName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
}

test "format helpers parse MessagePack inside wasm" {
    const Example = struct {
        role: enum {
            shipwright,
            cook,
        },
        active: bool,
    };

    var encoded = try serializeFormatOwned(msgpack, std.testing.allocator, Example{
        .role = .shipwright,
        .active = true,
    });
    defer encoded.deinit();

    const decoded = try parseFormat(msgpack, Example, std.testing.allocator, encoded.descriptor());
    try std.testing.expectEqual(.shipwright, decoded.role);
    try std.testing.expect(decoded.active);
}
