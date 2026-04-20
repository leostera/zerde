# Benchmarking

This directory contains the benchmark harness and benchmark history for `zerde`.

## Layout

- `bench/bench.zig`: benchmark entrypoint
- `bench/json.zig`: JSON benchmark entrypoint
- `bench/toml.zig`: TOML benchmark entrypoint
- `bench/common.zig`: shared scenarios, payload builders, and benchmark loops
- `bench/JSON.md`: running JSON benchmark history
- `bench/TOML.md`: running TOML benchmark history

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

Run the test suite before recording benchmark results:

```sh
zig build test
```

## Current comparisons

- JSON compares `zerde` against Zig's `std.json`
- TOML compares `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml)

The benchmark payloads are intentionally non-trivial and live in `bench/common.zig`.

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
