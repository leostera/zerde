//! Allocation benchmark entrypoint and format-agnostic wiring.

const std = @import("std");
const common = @import("common.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    try common.runMemoryBench(io, allocator);
}
