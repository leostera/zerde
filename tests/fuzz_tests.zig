//! Parser hardening fuzz tests for owned typed parse paths.

const std = @import("std");
const zerde = @import("zerde");

const Smith = std.testing.Smith;
const Weight = Smith.Weight;

const Role = enum {
    captain,
    navigator,
    cook,
    shipwright,
};

const Meta = struct {
    retries: u8,
    tag: []const u8,
};

const FuzzDoc = struct {
    name: []const u8,
    count: u32,
    active: bool,
    note: ?[]const u8,
    role: Role,
    samples: [3]u16,
    meta: Meta,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const text_weights: []const Weight = &.{
    Weight.rangeAtMost(u8, 'a', 'z', 8),
    Weight.rangeAtMost(u8, 'A', 'Z', 2),
    Weight.rangeAtMost(u8, '0', '9', 3),
    Weight.value(u8, '{', 2),
    Weight.value(u8, '}', 2),
    Weight.value(u8, '[', 2),
    Weight.value(u8, ']', 2),
    Weight.value(u8, ':', 2),
    Weight.value(u8, ',', 2),
    Weight.value(u8, '=', 2),
    Weight.value(u8, '.', 2),
    Weight.value(u8, '"', 3),
    Weight.value(u8, '\n', 2),
    Weight.value(u8, '\r', 1),
    Weight.value(u8, '\t', 1),
    Weight.value(u8, ' ', 6),
    Weight.value(u8, '-', 2),
    Weight.value(u8, '_', 2),
    Weight.value(u8, '\\', 1),
};

fn fuzzTextSlice(smith: *Smith, buf: []u8) []const u8 {
    const len = smith.sliceWeightedBytes(buf, text_weights);
    return buf[0..len];
}

fn fuzzBinarySlice(smith: *Smith, buf: []u8) []const u8 {
    const len = smith.slice(buf);
    return buf[0..len];
}

fn exerciseParse(comptime Format: type, input: []const u8) !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer std.testing.expect(gpa.deinit() == .ok) catch @panic("leak");

    const allocator = gpa.allocator();
    var diagnostic: zerde.Diagnostic = .{};

    if (zerde.parseSliceWithDiagnostics(Format, FuzzDoc, allocator, input, &diagnostic, .{}, .{})) |parsed| {
        defer zerde.free(allocator, parsed);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();

        try zerde.serialize(Format, &out.writer, parsed);

        const reparsed = try zerde.parseSlice(Format, FuzzDoc, allocator, out.written());
        defer zerde.free(allocator, reparsed);

        try std.testing.expectEqualDeep(parsed, reparsed);
    } else |_| {}
}

fn makeTextHarness(comptime Format: type) type {
    return struct {
        fn run(_: void, smith: *Smith) !void {
            var buf: [512]u8 = undefined;
            try exerciseParse(Format, fuzzTextSlice(smith, &buf));
        }
    };
}

fn makeBinaryHarness(comptime Format: type) type {
    return struct {
        fn run(_: void, smith: *Smith) !void {
            var buf: [512]u8 = undefined;
            try exerciseParse(Format, fuzzBinarySlice(smith, &buf));
        }
    };
}

const json_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/json/wrong_type.json"),
    @embedFile("corpus_invalid/json/truncated_object.json"),
};

const zon_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/zon/wrong_type.zon"),
    @embedFile("corpus_invalid/zon/truncated_object.zon"),
};

const toml_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/toml/wrong_type.toml"),
    @embedFile("corpus_invalid/toml/truncated_array.toml"),
};

const yaml_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/yaml/wrong_type.yaml"),
    @embedFile("corpus_invalid/yaml/truncated_flow_array.yaml"),
};

const cbor_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/cbor/wrong_type.cbor"),
    @embedFile("corpus_invalid/cbor/truncated_string.cbor"),
};

const msgpack_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/msgpack/wrong_type.msgpack"),
    @embedFile("corpus_invalid/msgpack/truncated_string.msgpack"),
};

const bson_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/bson/wrong_type.bson"),
    @embedFile("corpus_invalid/bson/truncated_document.bson"),
};

const bin_invalid_corpus: []const []const u8 = &.{
    @embedFile("corpus_invalid/bin/invalid_bool_tag.bin"),
    @embedFile("corpus_invalid/bin/truncated_string.bin"),
};

test "json parser fuzz" {
    try std.testing.fuzz({}, makeTextHarness(zerde.json).run, .{ .corpus = json_invalid_corpus });
}

test "zon parser fuzz" {
    try std.testing.fuzz({}, makeTextHarness(zerde.zon).run, .{ .corpus = zon_invalid_corpus });
}

test "toml parser fuzz" {
    try std.testing.fuzz({}, makeTextHarness(zerde.toml).run, .{ .corpus = toml_invalid_corpus });
}

test "yaml parser fuzz" {
    try std.testing.fuzz({}, makeTextHarness(zerde.yaml).run, .{ .corpus = yaml_invalid_corpus });
}

test "cbor parser fuzz" {
    try std.testing.fuzz({}, makeBinaryHarness(zerde.cbor).run, .{ .corpus = cbor_invalid_corpus });
}

test "msgpack parser fuzz" {
    try std.testing.fuzz({}, makeBinaryHarness(zerde.msgpack).run, .{ .corpus = msgpack_invalid_corpus });
}

test "bson parser fuzz" {
    try std.testing.fuzz({}, makeBinaryHarness(zerde.bson).run, .{ .corpus = bson_invalid_corpus });
}

test "bin parser fuzz" {
    try std.testing.fuzz({}, makeBinaryHarness(zerde.bin).run, .{ .corpus = bin_invalid_corpus });
}
