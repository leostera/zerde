const std = @import("std");
const zerde = @import("zerde");

const max_input_bytes = 128 * 1024 * 1024;

const WireFormat = enum {
    json,
    toml,
    yaml,
    cbor,
    bson,
    msgpack,

    fn parse(raw: []const u8) ?WireFormat {
        if (std.mem.eql(u8, raw, "json")) return .json;
        if (std.mem.eql(u8, raw, "toml")) return .toml;
        if (std.mem.eql(u8, raw, "yaml") or std.mem.eql(u8, raw, "yml")) return .yaml;
        if (std.mem.eql(u8, raw, "cbor")) return .cbor;
        if (std.mem.eql(u8, raw, "bson")) return .bson;
        if (std.mem.eql(u8, raw, "msgpack") or std.mem.eql(u8, raw, "mpk")) return .msgpack;
        return null;
    }
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr = &stderr_writer.interface;

    var from: ?WireFormat = null;
    var to: ?WireFormat = null;
    var input_path: ?[]const u8 = null;

    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const arg = args[index];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            try usage(stdout);
            try stdout.flush();
            return;
        }

        if (std.mem.eql(u8, arg, "--from")) {
            index += 1;
            if (index >= args.len) {
                try usage(stderr);
                try stderr.flush();
                std.process.exit(1);
            }
            from = WireFormat.parse(args[index]) orelse {
                try stderr.print("unknown input format: {s}\n\n", .{args[index]});
                try usage(stderr);
                try stderr.flush();
                std.process.exit(1);
            };
            continue;
        }

        if (std.mem.eql(u8, arg, "--to")) {
            index += 1;
            if (index >= args.len) {
                try usage(stderr);
                try stderr.flush();
                std.process.exit(1);
            }
            to = WireFormat.parse(args[index]) orelse {
                try stderr.print("unknown output format: {s}\n\n", .{args[index]});
                try usage(stderr);
                try stderr.flush();
                std.process.exit(1);
            };
            continue;
        }

        if (std.mem.startsWith(u8, arg, "-")) {
            try stderr.print("unknown flag: {s}\n\n", .{arg});
            try usage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }

        if (input_path != null) {
            try stderr.writeAll("expected at most one input file path\n\n");
            try usage(stderr);
            try stderr.flush();
            std.process.exit(1);
        }
        input_path = arg;
    }

    if (from == null or to == null) {
        try usage(stderr);
        try stderr.flush();
        std.process.exit(1);
    }

    const input = if (input_path) |path|
        try std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited(max_input_bytes))
    else blk: {
        var stdin_buffer: [4096]u8 = undefined;
        var stdin_reader = std.Io.File.stdin().reader(io, &stdin_buffer);
        break :blk try stdin_reader.interface.allocRemaining(arena, .limited(max_input_bytes));
    };

    const value = try parseValue(arena, from.?, input);
    try writeValue(stdout, to.?, value);
    try stdout.flush();
}

fn parseValue(allocator: std.mem.Allocator, format: WireFormat, input: []const u8) !zerde.Value {
    return switch (format) {
        .json => try zerde.value.parseSlice(zerde.json, allocator, input),
        .toml => try zerde.value.parseSlice(zerde.toml, allocator, input),
        .yaml => try zerde.value.parseSlice(zerde.yaml, allocator, input),
        .cbor => try zerde.value.parseSlice(zerde.cbor, allocator, input),
        .bson => try zerde.value.parseSlice(zerde.bson, allocator, input),
        .msgpack => try zerde.value.parseSlice(zerde.msgpack, allocator, input),
    };
}

fn writeValue(writer: *std.Io.Writer, format: WireFormat, value: zerde.Value) !void {
    switch (format) {
        .json => try zerde.value.serialize(zerde.json, writer, value),
        .toml => try zerde.value.serialize(zerde.toml, writer, value),
        .yaml => try zerde.value.serialize(zerde.yaml, writer, value),
        .cbor => try zerde.value.serialize(zerde.cbor, writer, value),
        .bson => try zerde.value.serialize(zerde.bson, writer, value),
        .msgpack => try zerde.value.serialize(zerde.msgpack, writer, value),
    }
}

fn usage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage: zerde-transcode --from <format> --to <format> [path]
        \\
        \\Self-describing formats:
        \\  json
        \\  toml
        \\  yaml
        \\  cbor
        \\  bson
        \\  msgpack
        \\
        \\If [path] is omitted, input is read from stdin and written to stdout.
        \\Binary blobs from BSON or MessagePack become integer arrays when you
        \\transcode them into text formats.
        \\
    );
}
