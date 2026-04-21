//! Benchmark entrypoint. Dispatches to the format-specific benchmark modules.

const std = @import("std");
const bson = @import("bson.zig");
const cbor = @import("cbor.zig");
const json = @import("json.zig");
const toml = @import("toml.zig");
const yaml = @import("yaml.zig");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const io = init.io;
    const allocator = std.heap.page_allocator;

    const mode = if (args.len >= 2) args[1] else "all";
    if (std.mem.eql(u8, mode, "json")) {
        try json.run(io, allocator);
        return;
    }
    if (std.mem.eql(u8, mode, "toml")) {
        try toml.run(io, allocator);
        return;
    }
    if (std.mem.eql(u8, mode, "cbor")) {
        try cbor.run(io, allocator);
        return;
    }
    if (std.mem.eql(u8, mode, "bson")) {
        try bson.run(io, allocator);
        return;
    }
    if (std.mem.eql(u8, mode, "yaml")) {
        try yaml.run(io, allocator);
        return;
    }

    try json.run(io, allocator);
    try toml.run(io, allocator);
    try cbor.run(io, allocator);
    try bson.run(io, allocator);
    try yaml.run(io, allocator);
}
