//! Shared helpers for canonical corpus roundtrip tests.

const std = @import("std");
const zerde = @import("zerde");

pub fn expectTextRoundTrip(
    comptime Format: type,
    comptime T: type,
    comptime case_name: []const u8,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    const allocator = std.testing.allocator;

    const decoded = try zerde.parseSliceWith(Format, T, allocator, input, serde_cfg, format_cfg);
    defer zerde.free(allocator, decoded);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serializeWith(Format, &out.writer, decoded, serde_cfg, format_cfg);

    if (!std.mem.eql(u8, input, out.written())) {
        printTextDiff(case_name, input, out.written());
        try std.testing.expectEqualStrings(input, out.written());
    }
}

pub fn expectBinaryRoundTrip(
    comptime Format: type,
    comptime T: type,
    comptime case_name: []const u8,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    const allocator = std.testing.allocator;

    const decoded = try zerde.parseSliceWith(Format, T, allocator, input, serde_cfg, format_cfg);
    defer zerde.free(allocator, decoded);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serializeWith(Format, &out.writer, decoded, serde_cfg, format_cfg);

    if (!std.mem.eql(u8, input, out.written())) {
        printBinaryDiff(case_name, input, out.written());
        return error.CorpusMismatch;
    }
}

pub fn printTextDiff(case_name: []const u8, expected: []const u8, actual: []const u8) void {
    const mismatch_index = firstMismatch(expected, actual) orelse @min(expected.len, actual.len);

    std.debug.print(
        "\\ncorpus mismatch in {s}: expected {d} bytes, got {d} bytes\\n",
        .{ case_name, expected.len, actual.len },
    );
    std.debug.print("first mismatch at byte {d}\\n", .{mismatch_index});
    std.debug.print("expected context: {s}\\n", .{contextWindow(expected, mismatch_index)});
    std.debug.print("actual context:   {s}\\n", .{contextWindow(actual, mismatch_index)});
}

pub fn printBinaryDiff(case_name: []const u8, expected: []const u8, actual: []const u8) void {
    const mismatch_index = firstMismatch(expected, actual) orelse @min(expected.len, actual.len);
    const expected_window = contextWindow(expected, mismatch_index);
    const actual_window = contextWindow(actual, mismatch_index);

    std.debug.print(
        "\\ncorpus mismatch in {s}: expected {d} bytes, got {d} bytes\\n",
        .{ case_name, expected.len, actual.len },
    );
    std.debug.print("first mismatch at byte {d}\\n", .{mismatch_index});
    std.debug.print("expected hex: {f}\n", .{std.fmt.fmtSliceHexLower(expected_window)});
    std.debug.print("actual hex:   {f}\n", .{std.fmt.fmtSliceHexLower(actual_window)});
}

fn firstMismatch(expected: []const u8, actual: []const u8) ?usize {
    const len = @min(expected.len, actual.len);
    for (0..len) |index| {
        if (expected[index] != actual[index]) return index;
    }
    if (expected.len != actual.len) return len;
    return null;
}

fn contextWindow(bytes: []const u8, index: usize) []const u8 {
    const start = index -| 32;
    const end = @min(bytes.len, index + 32);
    return bytes[start..end];
}
