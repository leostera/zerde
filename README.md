# zerde

<a href="https://x.com/Shreyassanthu77/status/2046350304288100528"
   style="
    margin: 10px;
    min-width: 100%;
    display: flex;
    /* flex-wrap: nowrap; */
    align-content: center;
    justify-content: center;
    flex-direction: row;
">
  <img src="./public/shreyas_quote.png" />
</a>

`zerde` is a comptime-specialized serialization library for Zig.

The core idea is the same one that makes Serde useful:

- keep the typed walk separate from the wire format
- specialize that typed walk with `comptime T`
- let each format backend only worry about its own syntax and container rules

In practice that means you can use the same public API with different formats:

- `zerde.serialize(zerde.bin, writer, value)`
- `zerde.serialize(zerde.bson, writer, value)`
- `zerde.serialize(zerde.json, writer, value)`
- `zerde.serialize(zerde.msgpack, writer, value)`
- `zerde.serialize(zerde.toml, writer, value)`
- `zerde.serialize(zerde.cbor, writer, value)`
- `zerde.serialize(zerde.yaml, writer, value)`
- `zerde.parseSlice(zerde.json, Config, allocator, input)`

The hot paths do not go through a runtime `Value` tree. For supported formats, `zerde` walks your Zig type directly and drives the target format backend in one typed pass.

## Current status

| Format | Serialize | Reader deserialize | Slice deserialize | Aliased slice parse | Notes |
| --- | --- | --- | --- | --- | --- |
| Binary | yes | yes | yes | yes | Schema-driven compact binary format, benchmarked against `bufzilla` |
| BSON | yes | yes | yes | yes | Typed BSON path, benchmarked against `zig-bson` |
| MessagePack | yes | yes | yes | yes | Typed MessagePack path, benchmarked against `msgpack.zig` |
| JSON | yes | yes | yes | yes | Fully typed fast path, benchmarked against `std.json` |
| TOML | yes | yes | yes | no | Practical TOML subset centered on scalars, arrays, tables, and arrays-of-tables |
| CBOR | yes | yes | yes | yes | Definite-length writer; read accepts definite and indefinite arrays/maps |
| YAML | yes | yes | yes | yes | Practical block-YAML subset with block mappings, block sequences, and flow scalar arrays |

Format-specific notes:

- Binary is compact and schema-driven rather than self-describing, so both sides need the same `T`.
- BSON writes typed BSON documents and arrays directly without an intermediate runtime tree.
- MessagePack currently uses compact numeric enum tags.
- JSON is the most complete text backend today, including `parseSliceAliased`.
- TOML read and write are both typed, but the supported surface is intentionally smaller than the full TOML spec.
- CBOR accepts both text strings and byte strings for `[]const u8` and `[N]u8`.
- YAML is intentionally scoped to the subset `zerde` writes today plus the read-side shapes needed for roundtrip tests.

## Design

`zerde` is split into three layers:

1. `src/root.zig`
   The public package API. This is where callers choose the format module and pass optional serde config.
2. `src/typed.zig`
   The format-independent typed walk. It uses `@typeInfo`, `@field`, and `inline for` to reflect over `T` and serialize or deserialize it.
3. Format backends like `src/json.zig`, `src/toml.zig`, and `src/cbor.zig`
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
        .firstName = "Nami",
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
var owned = try zerde.parseSliceOwned(zerde.json, User, allocator, input);
defer owned.deinit();
```

Aliased parse path:

```zig
var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
defer arena.deinit();

const decoded = try zerde.parseSliceAliased(zerde.json, User, arena.allocator(), input);
```

Manual ownership path:

```zig
const decoded = try zerde.parseSlice(zerde.json, User, allocator, input);
defer zerde.free(allocator, decoded);
```

`parseSliceAliased` may return string fields that point directly into `input` when the JSON string is unescaped. Use it when:

- the input slice outlives the parsed value
- you are releasing the whole allocation scope together, usually with an arena

Do not treat `parseSliceAliased` results like fully-owned data that can always be recursively freed field-by-field.

## TOML Usage

```zig
const Config = struct {
    shipName: []const u8,
    metadata: struct {
        accountId: u64,
    },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

try zerde.serialize(zerde.toml, writer, Config{
    .shipName = "Thousand Sunny",
    .metadata = .{ .accountId = 42 },
});
```

The TOML backend uses two struct passes so simple key/value pairs are emitted before nested tables and arrays-of-tables.

Owned TOML parse path:

```zig
var owned = try zerde.parseSliceOwned(zerde.toml, Config, allocator, input);
defer owned.deinit();
```

## CBOR Usage

```zig
const Event = struct {
    name: []const u8,
    count: u32,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
defer out.deinit();

try zerde.serializeWith(zerde.cbor, &out.writer, Event{
    .name = "buster_call_alert",
    .count = 3,
}, .{
    .rename_all = .snake_case,
}, .{});

var owned = try zerde.parseSliceOwned(zerde.cbor, Event, allocator, out.written());
defer owned.deinit();
```

The CBOR backend writes structs as maps and arrays with their exact lengths. String fields are emitted as CBOR text strings; on read, `[]const u8` and `[N]u8` accept either CBOR text or byte strings.

## Binary Usage

```zig
const LogEntry = struct {
    captain: []const u8,
    crew_size: u16,
    active: bool,
};

var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
defer out.deinit();

try zerde.serialize(zerde.bin, &out.writer, LogEntry{
    .captain = "Luffy",
    .crew_size = 10,
    .active = true,
});

var owned = try zerde.parseSliceOwned(zerde.bin, LogEntry, allocator, out.written());
defer owned.deinit();
```

The binary backend is compact and schema-driven. It does not carry field names on the wire, so both ends must agree on `T`.

## BSON Usage

```zig
const Report = struct {
    island_name: []const u8,
    alerts: []const []const u8,
};

try zerde.serialize(zerde.bson, writer, Report{
    .island_name = "Egghead",
    .alerts = &.{ "buster-call-risk", "marine-fleet-nearby" },
});
```

## MessagePack Usage

```zig
const Chest = struct {
    owner: []const u8,
    berries: u64,
};

try zerde.serialize(zerde.msgpack, writer, Chest{
    .owner = "Nami",
    .berries = 9000000,
});
```

## YAML Usage

```zig
const Manifest = struct {
    captainName: []const u8,
    ships: []const []const u8,
};

try zerde.serializeWith(zerde.yaml, writer, Manifest{
    .captainName = "Nami",
    .ships = &.{ "Going Merry", "Thousand Sunny" },
}, .{
    .rename_all = .snake_case,
}, .{
    .indent_width = 4,
});
```

The YAML backend writes a practical block-style subset and can parse that same subset back into typed values. `parseSliceAliased` is also available for YAML when borrowed strings are acceptable.

## Corpus Tests

Corpus-driven roundtrip tests now cover binary, BSON, CBOR, JSON, MessagePack, TOML, and YAML under [`tests/corpus`](tests/corpus).
`build.zig` scans each format directory, generates one test per fixture, parses each file into a typed value, serializes it back out, and requires an exact byte-for-byte match.

Each corpus is feature-first: files like `null.json`, `empty.toml`, `object_nested.yaml`, `object_single.cbor`, `object_nested.bson`, `enum_field.msgpack`, and `object_single.bin` exercise the wire format directly, and the support module maps each fixture to the smallest matching Zig type.
That exact match requirement is intentional: fixture files should already be in `zerde`'s canonical output form for the chosen serde and format config.
When a roundtrip differs, the support code prints the first mismatching byte and a small context window before failing the test.

## Benchmarks

Benchmark workflow and commands live in [bench/README.md](bench/README.md).
Binary benchmark history lives in [bench/BIN.md](bench/BIN.md).
BSON benchmark history lives in [bench/BSON.md](bench/BSON.md).
MessagePack benchmark history lives in [bench/MSGPACK.md](bench/MSGPACK.md).
JSON benchmark history lives in [bench/JSON.md](bench/JSON.md).
TOML benchmark history lives in [bench/TOML.md](bench/TOML.md).
CBOR benchmark history lives in [bench/CBOR.md](bench/CBOR.md).
YAML benchmark history lives in [bench/YAML.md](bench/YAML.md).

## Git Hooks

This repository ships a pre-commit hook in [`.githooks/pre-commit`](.githooks/pre-commit) that runs `zig fmt` on staged `.zig` files and re-stages them before the commit is created.

Enable the repo-local hooks path in a checkout with:

```sh
git config core.hooksPath .githooks
```
