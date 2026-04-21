//! WebAssembly / WASI interop helpers.
//!
//! This module does not define a new wire format. It packages the existing
//! compact binary backend behind pointer+length helpers that are convenient to
//! return from wasm exports or accept from JS-hosted callers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bin = @import("bin.zig");
const typed = @import("typed.zig");

/// Pointer+length pair that is friendly to wasm exports.
///
/// On wasm32 targets, both fields are naturally 32-bit `usize` values that JS
/// can feed into `Uint8Array(memory.buffer, ptr, len)`.
pub const Slice = extern struct {
    ptr: usize,
    len: usize,
};

/// Owns a serialized binary payload until the caller is done exposing it.
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
    return serializeOwnedWith(allocator, value, .{}, .{});
}

/// Serializes `value` into an owned wasm-friendly buffer with custom typed and binary config.
pub fn serializeOwnedWith(
    allocator: Allocator,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !OwnedBuffer {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try bin.serializeWith(&out.writer, value, serde_cfg, format_cfg);
    return .{ .out = out };
}

/// Parses a typed value from a wasm pointer+length descriptor, owning strings and slices by default.
pub fn parse(comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseWith(T, allocator, value, .{}, .{});
}

/// Parses a typed value from raw pointer+length parts, owning strings and slices by default.
pub fn parseParts(comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parsePartsWith(T, allocator, ptr, len, .{}, .{});
}

/// Parses a typed value from a wasm pointer+length descriptor with custom typed and binary config.
pub fn parseWith(
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return bin.parseSliceWith(T, allocator, bytesFromDescriptor(value), serde_cfg, format_cfg);
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
    return bin.parseSliceWith(T, allocator, bytesFromParts(ptr, len), serde_cfg, format_cfg);
}

/// Parses a typed value and may alias borrowed strings directly into the wasm input buffer.
pub fn parseAliased(comptime T: type, allocator: Allocator, value: Slice) !T {
    return parseAliasedWith(T, allocator, value, .{}, .{});
}

/// Parses from raw pointer+length parts and may alias borrowed strings directly into the wasm input buffer.
pub fn parsePartsAliased(comptime T: type, allocator: Allocator, ptr: [*]const u8, len: usize) !T {
    return parsePartsAliasedWith(T, allocator, ptr, len, .{}, .{});
}

/// Parses a typed value from a wasm pointer+length descriptor and may alias borrowed strings.
pub fn parseAliasedWith(
    comptime T: type,
    allocator: Allocator,
    value: Slice,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !T {
    return bin.parseSliceAliasedWith(T, allocator, bytesFromDescriptor(value), serde_cfg, format_cfg);
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
    return bin.parseSliceAliasedWith(T, allocator, bytesFromParts(ptr, len), serde_cfg, format_cfg);
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
