# zerde

`zerde` is a comptime-specialized serialization library for Zig.

The core idea is the same one that makes Serde useful:

- keep the typed walk separate from the wire format
- specialize that typed walk with `comptime T`
- let each format backend only worry about its own syntax and container rules

In practice that means you can use the same public API with different formats:

- `zerde.serialize(zerde.json, writer, value)`
- `zerde.serialize(zerde.toml, writer, value)`
- `zerde.parseSlice(zerde.json, Config, allocator, input)`

The hot paths do not go through a runtime `Value` tree. For supported formats, `zerde` walks your Zig type directly and drives the target format backend in one typed pass.

## Current status

- JSON
  - serialize: supported
  - deserialize from reader: supported
  - deserialize from slice: supported
  - aliased slice parse: supported through `parseSliceAliased`
- TOML
  - serialize: supported
  - deserialize: not implemented yet

## Design

`zerde` is split into three layers:

1. `src/root.zig`
   The public package API. This is where callers choose the format module and pass optional serde config.
2. `src/typed.zig`
   The format-independent typed walk. It uses `@typeInfo`, `@field`, and `inline for` to reflect over `T` and serialize or deserialize it.
3. Format backends like `src/json.zig` and `src/toml.zig`
   These implement the serializer or deserializer protocol expected by the typed layer.

This split matters because it keeps format rules and data-shape rules independent:

- field renaming, null omission, and unknown-field policy live in the typed layer
- JSON escaping, object delimiters, and TOML table ordering live in the format layer

## Serde Configuration

`zerde` accepts configuration at two levels:

- call-site config passed to `serializeWith`, `deserializeWith`, `parseSliceWith`, or `parseSliceAliasedWith`
- per-type config through `pub const serde = .{ ... }`

Supported typed-layer options today:

- `rename_all`
- `omit_null_fields`
- `deny_unknown_fields`
- per-field `rename`

Example:

```zig
const std = @import("std");
const zerde = @import("zerde");

const User = struct {
    firstName: []const u8,
    createdAt: i64,
    nickname: ?[]const u8,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .createdAt = .{ .rename = "created_at_unix" },
        },
    };
};

pub fn main() !void {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zerde.serializeWith(zerde.json, &out.writer, User{
        .firstName = "Ada",
        .createdAt = 42,
        .nickname = null,
    }, .{
        .omit_null_fields = true,
    }, .{});
}
```

## JSON Usage

Owned parse path:

```zig
const decoded = try zerde.parseSlice(zerde.json, User, allocator, input);
defer zerde.free(allocator, decoded);
```

Aliased parse path:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const decoded = try zerde.parseSliceAliased(zerde.json, User, arena.allocator(), input);
```

`parseSliceAliased` may return string fields that point directly into `input` when the JSON string is unescaped. Use it when:

- the input slice outlives the parsed value
- you are releasing the whole allocation scope together, usually with an arena

Do not treat `parseSliceAliased` results like fully-owned data that can always be recursively freed field-by-field.

## TOML Usage

```zig
const Config = struct {
    firstName: []const u8,
    metadata: struct {
        accountId: u64,
    },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

try zerde.serialize(zerde.toml, writer, Config{
    .firstName = "Ada",
    .metadata = .{ .accountId = 42 },
});
```

The TOML backend uses two struct passes so simple key/value pairs are emitted before nested tables and arrays-of-tables.

## Benchmarks

JSON benchmark history lives in [bench/JSON.md](bench/JSON.md).
TOML benchmark history lives in [bench/TOML.md](bench/TOML.md).

The JSON benchmark harness:

- compares `zerde` against Zig's `std.json`
- uses small, medium, and large scenarios
- exercises a mixed nested payload instead of a synthetic single-type document
- uses `parseSliceAliased` on the `zerde` side and `parseFromSliceLeaky` on the `std.json` side for a fair slice-parse comparison

The TOML benchmark harness:

- compares `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml)
- is currently write-only; TOML parse benchmarks have not been added yet
- uses a nested columnar payload so both serializers stay on a valid shared TOML shape

Run everything with:

```sh
zig build bench -Doptimize=ReleaseFast
```

Run JSON only with:

```sh
zig build bench-json -Doptimize=ReleaseFast
```

Run TOML only with:

```sh
zig build bench-toml -Doptimize=ReleaseFast
```

Run tests with:

```sh
zig build test
```

## Git Hooks

This repository ships a pre-commit hook in [`.githooks/pre-commit`](.githooks/pre-commit) that runs `zig fmt` on staged `.zig` files and re-stages them before the commit is created.

Enable the repo-local hooks path in a checkout with:

```sh
git config core.hooksPath .githooks
```
