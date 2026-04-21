# ZON Benchmark

This file is a running log of ZON benchmark results for `zerde` against Zig's `std.zon`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-zon -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `3b08153`, uses the repo's mixed nested payload with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against each library's own canonical ZON output because the compared payload types do not share the same field-renaming metadata

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a canonical parse input of about `102.85 MiB` for `zerde`, with write outputs of about `102.85 MiB` for `zerde` and `114.44 MiB` for `std.zon`.

## 2026-04-21 - 3b08153

Changes since previous run:

- added a first-class typed ZON backend built around Zig's own object notation
- added ZON corpus fixtures, typed tests, examples, wasm bridges, and transcoder support
- added ZON benchmarks against `std.zon`

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | std.zon ns/op | std.zon MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,732 B | 1000000 | 38200.90 | 93.17 | 45721.92 | 77.84 | `zerde` 1.20x faster |
| medium | 1,089,288 B | 1000 | 10792225.96 | 96.26 | 13921324.89 | 74.62 | `zerde` 1.29x faster |
| large | 107,850,184 B | 100 | 1071416287.07 | 96.00 | 1402286404.58 | 73.35 | `zerde` 1.31x faster |

### Write

| Scenario | zerde Size | std.zon Size | Iterations | zerde ns/op | zerde MiB/s | std.zon ns/op | std.zon MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,732 B | 4,005 B | 1000000 | 7647.03 | 465.42 | 8162.45 | 467.93 | `zerde` 1.07x faster |
| medium | 1,089,288 B | 1,210,845 B | 1000 | 2026715.85 | 512.57 | 2281109.62 | 506.22 | `zerde` 1.13x faster |
| large | 107,850,184 B | 120,000,241 B | 100 | 200320260.02 | 513.45 | 229143250.31 | 499.43 | `zerde` 1.14x faster |

### Roundtrip

| Scenario | zerde Size | std.zon Size | Iterations | zerde ns/op | zerde MiB/s | std.zon ns/op | std.zon MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,732 B | 4,005 B | 1000000 | 46703.18 | 152.41 | 53852.75 | 141.85 | `zerde` 1.15x faster |
| medium | 1,089,288 B | 1,210,845 B | 1000 | 12793225.58 | 162.40 | 16272721.43 | 141.92 | `zerde` 1.27x faster |
| large | 107,850,184 B | 120,000,241 B | 100 | 1267397702.17 | 162.31 | 1599566435.80 | 143.09 | `zerde` 1.26x faster |

### Notes

- The baseline parse path goes through `std.zon.parse.fromSliceAlloc(...)`, which requires a sentinel-terminated copy of the input, so that allocation is part of the measured public cost.
- `std.zon` emits a larger canonical document on this workload, so write and roundtrip throughput use each library's own output byte count.
