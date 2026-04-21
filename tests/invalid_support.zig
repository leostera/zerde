//! Shared helpers for invalid corpus tests.

const std = @import("std");
const zerde = @import("zerde");

pub fn expectTextParseFails(
    comptime Format: type,
    comptime T: type,
    comptime case_name: []const u8,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try expectParseFails(Format, T, case_name, input, serde_cfg, format_cfg, true);
}

pub fn expectBinaryParseFails(
    comptime Format: type,
    comptime T: type,
    comptime case_name: []const u8,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try expectParseFails(Format, T, case_name, input, serde_cfg, format_cfg, false);
}

fn expectParseFails(
    comptime Format: type,
    comptime T: type,
    comptime case_name: []const u8,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
    comptime expect_location: bool,
) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    var diagnostic: zerde.Diagnostic = .{};
    if (zerde.parseSliceWithDiagnostics(Format, T, gpa.allocator(), input, &diagnostic, serde_cfg, format_cfg)) |parsed| {
        defer zerde.free(gpa.allocator(), parsed);
        std.debug.print("invalid corpus unexpectedly parsed: {s}\n", .{case_name});
        return error.InvalidCorpusAccepted;
    } else |_| {
        if (expect_location) {
            try std.testing.expect(diagnostic.location.offset != null or diagnostic.path_len != 0);
        }
    }
}
