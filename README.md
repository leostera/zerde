# zerde

`zerde` is a comptime-specialized serialization framework for Zig.

Point it at a Zig type and a format, and it generates a typed serializer or
deserializer for that exact combination.

What you get:

- one typed API across JSON, ZON, TOML, YAML, CBOR, BSON, MessagePack, and binary
- fast read and write paths without a required runtime value tree
- an optional `zerde.Value` tree for transcoding and schema-less tooling
- per-type and per-call customization for field renames and wire-shape policy
- owned, arena-backed, and aliased slice parse entrypoints
- wasm/WASI pointer+length helpers for moving typed values across JS boundaries and parsing JSON, ZON, YAML, MessagePack, and other format payloads inside the module

Current benchmark snapshot on the repo's mixed nested workload:

- about `2.1x` faster than `std.json` on reads and `1.2x` faster on writes
- about `1.3x` faster than `std.zon` on reads and `1.1x` faster on writes
- about `1.7x` faster than `zig-toml` on reads and `1.1x` faster on writes
- about `8x` faster than `zbor` on reads and `1.8x` faster on writes
- about `2x` faster than `zig-yaml` on reads and `2.5x` faster on writes
- about `9x` faster than `zig-bson` on reads and `3x` to `4x` faster on writes
- about `4x` to `5x` faster than `bufzilla` on reads and `3x` to `4x` faster on writes

```zig
const std = @import("std");
const zerde = @import("zerde");

const StrawHat = struct {
    name: []const u8,
    bounty: u32,
    role: enum { captain, navigator, cook, shipwright },

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub fn main() !void {
    const allocator = std.heap.page_allocator;

    const crew_mate = StrawHat{
        .name = "Franky",
        .bounty = 394_000_000,
        .role = .shipwright,
    };

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serialize(zerde.json, &out.writer, crew_mate);

    var decoded = try zerde.parseSliceOwned(zerde.json, StrawHat, allocator, out.written());
    defer decoded.deinit();

    std.debug.print("{s}\n", .{out.written()});
}
```

## Formats

| Format | Serialize | Reader deserialize | Slice deserialize | Aliased slice parse | Notes |
| --- | --- | --- | --- | --- | --- |
| Binary | yes | yes | yes | yes | Schema-driven compact binary format |
| BSON | yes | yes | yes | yes | Typed BSON path |
| MessagePack | yes | yes | yes | yes | Typed MessagePack path |
| JSON | yes | yes | yes | yes | Fully typed fast path, benchmarked against `std.json` |
| ZON | yes | yes | yes | no | Typed ZON path, benchmarked against `std.zon`; slice parse currently owns decoded strings |
| TOML | yes | yes | yes | yes | Practical TOML subset centered on scalars, arrays, tables, and arrays-of-tables |
| CBOR | yes | yes | yes | yes | Definite-length writer; read accepts definite and indefinite arrays/maps |
| YAML | yes | yes | yes | yes | Practical block-YAML subset with block mappings, block sequences, and flow scalar arrays |

## WebAssembly / WASI

`zerde` is not limited to its compact binary transport in wasm.

The `zerde.wasm` helpers can:

- serialize typed Zig values into wasm-friendly pointer+length buffers
- parse JSON, ZON, YAML, MessagePack, and other supported payloads inside the module
- reserialize those typed values back into JSON, binary, or another format before handing bytes back to JS

```zig
const std = @import("std");
const zerde = @import("zerde");

const CrewManifest = struct {
    captainName: []const u8,
    bounty: u32,
    shipwright: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub fn normalizeJson(allocator: std.mem.Allocator, input: []const u8) !zerde.wasm.OwnedBuffer {
    const manifest = try zerde.wasm.parseFormatWith(zerde.json, CrewManifest, allocator, zerde.wasm.sliceDescriptor(input), .{
        .rename_all = .snake_case,
    }, .{});
    defer zerde.free(allocator, manifest);

    return zerde.wasm.serializeFormatOwnedWith(zerde.json, allocator, manifest, .{
        .rename_all = .snake_case,
    }, .{});
}
```

Native format examples and browser-oriented wasm examples live in [`examples/`](examples), and you can build them with `zig build examples`.

## Install

Add `zerde` as a Zig dependency:

```sh
zig fetch --save git+https://github.com/leostera/zerde#0.1.0
```

Then import it from your `build.zig`:

```zig
const zerde_dep = b.dependency("zerde", .{
    .target = target,
    .optimize = optimize,
});

exe.root_module.addImport("zerde", zerde_dep.module("zerde"));
```

And from your Zig code:

```zig
const zerde = @import("zerde");
```

Benchmark history and per-format runs live in [`bench/`](bench).

## CLI

`zerde` also ships with a small transcoder for self-describing formats.

Build it with:

```sh
zig build transcode
```

Then use it like:

```sh
./zig-out/bin/zerde-transcode --from json --to yaml crew.json
```

It currently supports `json`, `zon`, `toml`, `yaml`, `cbor`, `bson`, and `msgpack`.

## Customization

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
        .firstName = "Franky",
        .createdAt = 42,
        .nickname = null,
    }, .{
        .omit_null_fields = true,
    }, .{});
}
```
