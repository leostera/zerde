# Benchmarking

This directory contains the benchmark harness and benchmark history for `zerde`.

The current runner uses [`zBench`](https://github.com/hendriknielaender/zBench) for timing and result collection while keeping `zerde`'s existing scenario workloads, fairness policy, and benchmark-history files.

## Layout

- `bench/bench.zig`: benchmark entrypoint
- `bench/cbor.zig`: CBOR benchmark entrypoint
- `bench/json.zig`: JSON benchmark entrypoint
- `bench/toml.zig`: TOML benchmark entrypoint
- `bench/yaml.zig`: YAML benchmark entrypoint
- `bench/common.zig`: shared scenarios, payload builders, and benchmark loops
- `bench/CBOR.md`: running CBOR benchmark history
- `bench/JSON.md`: running JSON benchmark history
- `bench/TOML.md`: running TOML benchmark history
- `bench/YAML.md`: running YAML benchmark history

## Commands

Run all benchmarks:

```sh
zig build bench -Doptimize=ReleaseFast
```

Run JSON only:

```sh
zig build bench-json -Doptimize=ReleaseFast
```

Run TOML only:

```sh
zig build bench-toml -Doptimize=ReleaseFast
```

Run CBOR only:

```sh
zig build bench-cbor -Doptimize=ReleaseFast
```

Run YAML only:

```sh
zig build bench-yaml -Doptimize=ReleaseFast
```

Run the test suite before recording benchmark results:

```sh
zig build test
```

## Current comparisons

- JSON compares `zerde` against Zig's `std.json`
- TOML compares `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml)
- CBOR compares `zerde` against `zbor`
- YAML compares `zerde` against `zig-yaml`

The benchmark payloads are intentionally non-trivial and live in `bench/common.zig`.
The current harness measures parse, write, and roundtrip (`typed -> bytes -> typed`) cost.
`zBench` is configured with the same fixed per-scenario iteration counts that the repo used before the migration so successive runs stay comparable.

## Benchmark Policy

Benchmarks should measure the full cost of the public API path a user actually pays for.

- if a library can serialize a typed value directly, benchmark that direct typed serialization path
- if a library can parse bytes directly into a typed value, benchmark that direct typed parse path
- if a library requires an intermediate representation such as a DOM, object tree, or generic value before the user can reach their typed data, that conversion cost belongs inside the timed region
- likewise, if a library requires converting a typed value into an intermediate representation before writing, that conversion cost belongs inside the timed region
- do not add extra benchmark-layer conversions that the compared library does not actually require

In other words, benchmark end-to-end usage cost, not just the format engine in isolation.

Current harness behavior follows that rule:

- JSON compares `zerde.parseSliceAliased(..., Payload, ...)` against `std.json.parseFromSliceLeaky(StdPayload, ...)`, so both sides are timed on their typed parse APIs
- JSON write compares `zerde.serialize(...)` against `std.json.Stringify.value(...)`, so both sides are timed on their typed serialization APIs
- JSON roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `std.json.Stringify.value(...) + std.json.parseFromSliceLeaky(...)`
- TOML parse compares `zerde.parseSlice(..., TomlParsePayload, ...)` against `zig_toml.Parser(TomlParsePayload).parseString(...)`
- TOML write compares `zerde.serialize(...)` against `zig_toml.serialize(...)`
- TOML roundtrip compares `zerde.serialize(...) + zerde.parseSlice(...)` against `zig_toml.serialize(...) + zig_toml.Parser(...).parseString(...)`
- CBOR parse compares `zerde.parseSliceAliased(..., Payload, ...)` against `zbor.DataItem.new(...) + zbor.parse(ZborPayload, ...)`
- CBOR write compares `zerde.serialize(...)` against `zbor.stringify(...)`
- CBOR roundtrip compares `zerde.serialize(...) + zerde.parseSliceAliased(...)` against `zbor.stringify(...) + zbor.DataItem.new(...) + zbor.parse(...)`
- YAML parse compares `zerde.parseSliceAliased(..., YamlPayload, ...)` against `Yaml.load(...) + Yaml.parse(..., YamlPayload)`, so the baseline's document-load step stays inside the timed region
- YAML write compares `zerde.serializeWith(..., .{ .omit_null_fields = true }, .{ .indent_width = 4 })` against `zig_yaml.stringify(...)`
- YAML roundtrip compares `zerde.serializeWith(...) + zerde.parseSliceAliased(...)` against `zig_yaml.stringify(...) + Yaml.load(...) + Yaml.parse(...)`

Roundtrip benchmarks also perform one deep equality check per scenario before timing begins.
That keeps correctness in the harness without turning the timed region into a struct-comparison benchmark.

If a future comparison target only offers an intermediate representation, the harness should include the required `IR -> typed` or `typed -> IR` step in the measured time.

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
