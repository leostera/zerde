//! MessagePack benchmark entrypoint.

const std = @import("std");
const common = @import("common.zig");

pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    try common.runMsgpackBench(io, allocator);
}
