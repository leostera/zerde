# TOML Benchmark

This file is a running log of TOML benchmark results for `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml).

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-toml -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `cd59eb1`, uses a serialize-only nested columnar payload with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` table
- a nested `endpoints` table with arrays of strings, enums, integers, floats, and bools
- a nested `metrics` table with arrays of strings, enums, signed integers, unsigned integers, floats, and fixed string arrays
- a nested `events` table with arrays of strings, enums, signed integers, unsigned integers, floats, bools, and fixed arrays

Why columnar instead of row-oriented arrays-of-tables:

- `zerde` and `zig-toml` both serialize this shape cleanly and at large sizes
- `zig-toml` does not support slice fields in serialization
- the two libraries do not agree on the representation of pointer-to-array struct fields, so that shape is not a fair apples-to-apples benchmark

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` write iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` write iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` write iterations

The current large case produces TOML outputs of about `68.78 MiB` for `zerde` and `70.50 MiB` for `zig-toml`.

## 2026-04-20 - cd59eb1

Changes since previous run:

- added `zig-toml` as a benchmark dependency
- added a dedicated TOML serializer benchmark and a `bench-toml` build step
- fixed `zerde`'s TOML arrays-of-tables state tracking so nested fields no longer clobber the outer table-array context

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,939 B | 3,037 B | 1000000 | 4073.12 | 688.13 | 6580.97 | 440.10 | `zerde` 1.62x faster |
| medium | 727,571 B | 745,857 B | 1000 | 945424.92 | 733.92 | 830189.38 | 856.80 | `zig-toml` 1.14x faster |
| large | 72,119,881 B | 73,921,079 B | 100 | 92861007.50 | 740.66 | 81907176.67 | 860.69 | `zig-toml` 1.13x faster |

### Notes

- `zerde` wins clearly on the small payload, while `zig-toml` pulls ahead by about `13-14%` on the medium and large payloads.
- Output sizes differ slightly because the serializers make different formatting choices, so throughput is reported against each library's own emitted byte count.
- This benchmark is serialize-only. TOML parse benchmarks will make sense once `zerde` grows a TOML deserializer.
