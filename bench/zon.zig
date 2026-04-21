//! ZON benchmark entrypoint and format-specific wiring.

const std = @import("std");
const common = @import("common.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    try common.runZonBench(io, allocator);
}
