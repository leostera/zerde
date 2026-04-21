# zerde

`zerde` is a serialization framework for Zig using comptime-specialization to
emit optimal de/serialization code for any Zig datatype, with support for many
common formats: JSON, BSON, CBOR, TOML, YAML, MessagePack, etc.

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

## Current status

| Format | Serialize | Reader deserialize | Slice deserialize | Aliased slice parse | Notes |
| --- | --- | --- | --- | --- | --- |
| Binary | yes | yes | yes | yes | Schema-driven compact binary format |
| BSON | yes | yes | yes | yes | Typed BSON path |
| MessagePack | yes | yes | yes | yes | Typed MessagePack path |
| JSON | yes | yes | yes | yes | Fully typed fast path, benchmarked against `std.json` |
| TOML | yes | yes | yes | yes | Practical TOML subset centered on scalars, arrays, tables, and arrays-of-tables |
| CBOR | yes | yes | yes | yes | Definite-length writer; read accepts definite and indefinite arrays/maps |
| YAML | yes | yes | yes | yes | Practical block-YAML subset with block mappings, block sequences, and flow scalar arrays |

## Getting Started

Add `zerde` as a Zig dependency:

```sh
zig fetch --save git+https://github.com/leostera/zerde
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

## Configuration

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

## Ownership

Use `parseSlice` or `deserialize` when you want `zerde` to allocate owned typed
results.

Use `parseSliceAliased` when the input buffer is stable and your type contains
reference fields such as `[]const u8`; in that mode `zerde` may hand those
fields back as slices into the original input.

## Errors

`zerde` can attach field-path and byte-location context to parse failures with
`parseSliceWithDiagnostics` and `deserializeWithDiagnostics`.

Use this when you need errors like `InvalidNumber at root.crew[0].bounty (offset
19, line 1, column 20)` instead of a bare format error.

`Diagnostic` records:

- the structured field path
- byte offset for all formats
- line and column for text formats that can report them directly
