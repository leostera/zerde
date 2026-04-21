# Benchmarking

This directory contains the benchmark harness and benchmark history for `zerde`.

The timing runner uses [`zBench`](https://github.com/hendriknielaender/zBench) for result collection while keeping `zerde`'s existing scenario workloads, fairness policy, and benchmark-history files.
There is also a separate allocation benchmark that tracks allocation calls,
allocated bytes, and peak live bytes for `zerde`'s own parse/write/roundtrip
paths.

## Layout

- `bench/bench.zig`: benchmark entrypoint
- `bench/bin.zig`: binary benchmark entrypoint
- `bench/bson.zig`: BSON benchmark entrypoint
- `bench/cbor.zig`: CBOR benchmark entrypoint
- `bench/json.zig`: JSON benchmark entrypoint
- `bench/memory.zig`: allocation benchmark entrypoint
- `bench/msgpack.zig`: MessagePack benchmark entrypoint
- `bench/toml.zig`: TOML benchmark entrypoint
- `bench/wasm.zig`: WASM helper benchmark entrypoint
- `bench/yaml.zig`: YAML benchmark entrypoint
- `bench/zon.zig`: ZON benchmark entrypoint
- `bench/common.zig`: shared scenarios, payload builders, and benchmark loops
- `bench/BIN.md`: running binary benchmark history
- `bench/BSON.md`: running BSON benchmark history
- `bench/CBOR.md`: running CBOR benchmark history
- `bench/JSON.md`: running JSON benchmark history
- `bench/MSGPACK.md`: running MessagePack benchmark history
- `bench/MEMORY.md`: running allocation benchmark history
- `bench/TOML.md`: running TOML benchmark history
- `bench/WASM.md`: running WASM benchmark history
- `bench/YAML.md`: running YAML benchmark history
- `bench/ZON.md`: running ZON benchmark history

## Commands

Run all benchmarks:

```sh
zig build bench -Doptimize=ReleaseFast
```

Run binary only:

```sh
zig build bench-bin -Doptimize=ReleaseFast
```

Run JSON only:

```sh
zig build bench-json -Doptimize=ReleaseFast
```

Run the allocation benchmark:

```sh
zig build bench-memory -Doptimize=ReleaseFast
```

Run TOML only:

```sh
zig build bench-toml -Doptimize=ReleaseFast
```

Run ZON only:

```sh
zig build bench-zon -Doptimize=ReleaseFast
```

Run CBOR only:

```sh
zig build bench-cbor -Doptimize=ReleaseFast
```

Run BSON only:

```sh
zig build bench-bson -Doptimize=ReleaseFast
```

Run MessagePack only:

```sh
zig build bench-msgpack -Doptimize=ReleaseFast
```

Run YAML only:

```sh
zig build bench-yaml -Doptimize=ReleaseFast
```

Run WASM helper benchmark only:

```sh
zig build bench-wasm -Doptimize=ReleaseFast
```

Run the test suite before recording benchmark results:

```sh
zig build test
```

## Current comparisons

- binary compares `zerde` against `bufzilla`
- JSON compares `zerde` against Zig's `std.json`
- ZON compares `zerde` against Zig's `std.zon`
- TOML compares `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml)
- CBOR compares `zerde` against `zbor`
- BSON compares `zerde` against `zig-bson`
- MessagePack compares `zerde` against `msgpack.zig`
- YAML compares `zerde` against `zig-yaml`
- WASM compares `zerde.wasm` against the equivalent direct `zerde.bin` path to measure helper overhead rather than wire-format speed
- the allocation benchmark is `zerde`-only and measures allocator behavior rather than external relative speed

The benchmark payloads are intentionally non-trivial and live in `bench/common.zig`.
The current harness measures parse, write, and roundtrip (`typed -> bytes -> typed`) cost.
`zBench` is configured with the same fixed per-scenario iteration counts that the repo used before the migration so successive runs stay comparable.

The allocation benchmark reuses the same scenarios, but records allocation
counts, remaps, total allocated bytes, and peak live bytes instead of timing.

## Benchmark Policy

Benchmarks should measure the full cost of the public API path a user actually pays for.

- if a library can serialize a typed value directly, benchmark that direct typed serialization path
- if a library can parse bytes directly into a typed value, benchmark that direct typed parse path
- if a library requires an intermediate representation such as a DOM, object tree, or generic value before the user can reach their typed data, that conversion cost belongs inside the timed region
- likewise, if a library requires converting a typed value into an intermediate representation before writing, that conversion cost belongs inside the timed region
- do not add extra benchmark-layer conversions that the compared library does not actually require

In other words, benchmark end-to-end usage cost, not just the format engine in isolation.

The allocation benchmark follows the same rule for `zerde`'s own APIs:

- parse measures the full owning typed parse path
- parse aliased measures the public aliased parse path when a format supports it
- write measures the public serializer path
- roundtrip measures `typed -> bytes -> typed`

Current harness behavior follows that rule:

- binary parse compares `zerde.parseSliceAliased(..., BinPayload, ...)` against `decodeBufzilla(BinPayload, ...)`
- binary write compares `zerde.serialize(...)` against `bufzilla.Writer.writeAny(...)`
- binary roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `bufzilla.Writer.writeAny(...) + decodeBufzilla(...)`
- JSON compares `zerde.parseSliceAliased(..., Payload, ...)` against `std.json.parseFromSliceLeaky(StdPayload, ...)`, so both sides are timed on their typed parse APIs
- JSON write compares `zerde.serialize(...)` against `std.json.Stringify.value(...)`, so both sides are timed on their typed serialization APIs
- JSON roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `std.json.Stringify.value(...) + std.json.parseFromSliceLeaky(...)`
- ZON parse compares `zerde.parseSlice(zerde.zon, Payload, ...)` against `std.zon.parse.fromSliceAlloc(StdPayload, ...)`
- ZON write compares `zerde.serialize(zerde.zon, ...)` against `std.zon.stringify.serialize(...)`
- ZON roundtrip compares `zerde.serialize(zerde.zon, ...) + zerde.parseSlice(zerde.zon, ...)` against `std.zon.stringify.serialize(...) + std.zon.parse.fromSliceAlloc(...)`
- TOML parse compares `zerde.parseSlice(..., TomlParsePayload, ...)` against `zig_toml.Parser(TomlParsePayload).parseString(...)`
- TOML write compares `zerde.serialize(...)` against `zig_toml.serialize(...)`
- TOML roundtrip compares `zerde.serialize(...) + zerde.parseSlice(...)` against `zig_toml.serialize(...) + zig_toml.Parser(...).parseString(...)`
- CBOR parse compares `zerde.parseSliceAliased(..., Payload, ...)` against `zbor.DataItem.new(...) + zbor.parse(ZborPayload, ...)`
- CBOR write compares `zerde.serialize(...)` against `zbor.stringify(...)`
- CBOR roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `zbor.stringify(...) + zbor.DataItem.new(...) + zbor.parse(...)`
- BSON parse compares `zerde.parseSliceAliased(..., BsonPayload, ...)` against `zig_bson.reader(...).into(BsonPayload)`
- BSON write compares `zerde.serialize(...)` against `zig_bson.write(...)`
- BSON roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `zig_bson.write(...) + zig_bson.reader(...).into(...)`
- MessagePack parse compares `zerde.parseSliceAliased(..., MsgpackPayload, ...)` against `zig_msgpack.decodeFromSliceLeaky(...)`
- MessagePack write compares `zerde.serialize(...)` against `zig_msgpack.encode(...)`
- MessagePack roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `zig_msgpack.encode(...) + zig_msgpack.decodeFromSliceLeaky(...)`
- YAML parse compares `zerde.parseSliceAliased(..., YamlPayload, ...)` against `Yaml.load(...) + Yaml.parse(..., YamlPayload)`, so the baseline's document-load step stays inside the timed region
- YAML write compares `zerde.serializeWith(..., .{ .omit_null_fields = true }, .{ .indent_width = 4 })` against `zig_yaml.stringify(...)`
- YAML roundtrip compares `zerde.serializeWith(...) + zerde.parseSliceAliased(...)` against `zig_yaml.stringify(...) + Yaml.load(...) + Yaml.parse(...)`
- WASM parse compares `zerde.wasm.parse(...)` against `zerde.parseSlice(zerde.bin, ...)`, so both sides own the typed result and operate on the same compact binary bytes
- WASM write compares `zerde.wasm.serializeOwned(...)` against the equivalent direct `zerde.serialize(zerde.bin, ...)` path with a fresh owned output buffer
- WASM roundtrip compares `zerde.wasm.serializeOwned(...) + zerde.wasm.parse(...)` against the equivalent direct binary roundtrip path

Roundtrip benchmarks also perform one deep equality check per scenario before timing begins.
That keeps correctness in the harness without turning the timed region into a struct-comparison benchmark.

If a future comparison target only offers an intermediate representation, the harness should include the required `IR -> typed` or `typed -> IR` step in the measured time.
When two libraries do not share a wire format, benchmark parse against each library's own emitted bytes and call that out explicitly in the benchmark log.

## Recording Results

Benchmark logs are append-only history files with newest runs first.

Use this section format:

```md
## 2026-04-20 - abc1234
```

When adding a run:

- put the new section at the top of the relevant log
- describe what changed since the previous recorded run
- record only runs that reflect actual benchmark, workload, parser, or serializer changes
- do not record layout-only, documentation-only, or other non-performance repo changes
- prefer running on a clean commit and use that commit hash in the section title
