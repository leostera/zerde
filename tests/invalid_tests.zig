//! Invalid-input corpus coverage.

const zerde = @import("zerde");
const invalid = @import("invalid_support.zig");

const CountDoc = struct {
    count: u32,
};

const NameDoc = struct {
    name: []const u8,
};

test "invalid json corpus: wrong_type.json" {
    try invalid.expectTextParseFails(zerde.json, CountDoc, "wrong_type.json", @embedFile("corpus_invalid/json/wrong_type.json"), .{}, .{});
}

test "invalid json corpus: truncated_object.json" {
    try invalid.expectTextParseFails(zerde.json, CountDoc, "truncated_object.json", @embedFile("corpus_invalid/json/truncated_object.json"), .{}, .{});
}

test "invalid zon corpus: wrong_type.zon" {
    try invalid.expectTextParseFails(zerde.zon, CountDoc, "wrong_type.zon", @embedFile("corpus_invalid/zon/wrong_type.zon"), .{}, .{});
}

test "invalid zon corpus: truncated_object.zon" {
    try invalid.expectTextParseFails(zerde.zon, CountDoc, "truncated_object.zon", @embedFile("corpus_invalid/zon/truncated_object.zon"), .{}, .{});
}

test "invalid toml corpus: wrong_type.toml" {
    try invalid.expectTextParseFails(zerde.toml, CountDoc, "wrong_type.toml", @embedFile("corpus_invalid/toml/wrong_type.toml"), .{}, .{});
}

test "invalid toml corpus: truncated_array.toml" {
    try invalid.expectTextParseFails(zerde.toml, CountDoc, "truncated_array.toml", @embedFile("corpus_invalid/toml/truncated_array.toml"), .{}, .{});
}

test "invalid yaml corpus: wrong_type.yaml" {
    try invalid.expectTextParseFails(zerde.yaml, CountDoc, "wrong_type.yaml", @embedFile("corpus_invalid/yaml/wrong_type.yaml"), .{}, .{});
}

test "invalid yaml corpus: truncated_flow_array.yaml" {
    try invalid.expectTextParseFails(zerde.yaml, CountDoc, "truncated_flow_array.yaml", @embedFile("corpus_invalid/yaml/truncated_flow_array.yaml"), .{}, .{});
}

test "invalid cbor corpus: wrong_type.cbor" {
    try invalid.expectBinaryParseFails(zerde.cbor, u32, "wrong_type.cbor", @embedFile("corpus_invalid/cbor/wrong_type.cbor"), .{}, .{});
}

test "invalid cbor corpus: truncated_string.cbor" {
    try invalid.expectBinaryParseFails(zerde.cbor, []const u8, "truncated_string.cbor", @embedFile("corpus_invalid/cbor/truncated_string.cbor"), .{}, .{});
}

test "invalid msgpack corpus: wrong_type.msgpack" {
    try invalid.expectBinaryParseFails(zerde.msgpack, u32, "wrong_type.msgpack", @embedFile("corpus_invalid/msgpack/wrong_type.msgpack"), .{}, .{});
}

test "invalid msgpack corpus: truncated_string.msgpack" {
    try invalid.expectBinaryParseFails(zerde.msgpack, []const u8, "truncated_string.msgpack", @embedFile("corpus_invalid/msgpack/truncated_string.msgpack"), .{}, .{});
}

test "invalid bson corpus: wrong_type.bson" {
    try invalid.expectBinaryParseFails(zerde.bson, CountDoc, "wrong_type.bson", @embedFile("corpus_invalid/bson/wrong_type.bson"), .{}, .{});
}

test "invalid bson corpus: truncated_document.bson" {
    try invalid.expectBinaryParseFails(zerde.bson, CountDoc, "truncated_document.bson", @embedFile("corpus_invalid/bson/truncated_document.bson"), .{}, .{});
}

test "invalid bin corpus: invalid_bool_tag.bin" {
    try invalid.expectBinaryParseFails(zerde.bin, bool, "invalid_bool_tag.bin", @embedFile("corpus_invalid/bin/invalid_bool_tag.bin"), .{}, .{});
}

test "invalid bin corpus: truncated_string.bin" {
    try invalid.expectBinaryParseFails(zerde.bin, []const u8, "truncated_string.bin", @embedFile("corpus_invalid/bin/truncated_string.bin"), .{}, .{});
}
