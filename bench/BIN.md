# Binary Benchmark

This file is a running log of binary benchmark results for `zerde` against `bufzilla`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-bin -Doptimize=ReleaseFast`

## Workload

Current harness uses a mixed nested schema-driven payload with:

- top-level scalars, fixed arrays, and optionals
- a nested `metadata` struct with booleans, integers, and strings
- an `endpoints` array of structs with bools, integers, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against each library's own binary encoding because the two formats are not wire-compatible

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces about `28.87 MiB` for `zerde.bin` and about `77.79 MiB` for `bufzilla`.

## 2026-04-21 - 151b50b

Changes since previous run:

- added the first binary benchmark harness and `bench-bin` build step
- introduced a schema-driven binary comparison against `bufzilla`
- benchmarked parse against each library's own encoded bytes because the wire formats differ

### Parse

| Scenario | zerde Parse Size | bufzilla Parse Size | Iterations | zerde ns/op | zerde MiB/s | bufzilla ns/op | bufzilla MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 2,991 B | 1000000 | 855.00 | 1453.38 | 3694.00 | 772.18 | `zerde` 4.32x faster |
| medium | 304,775 B | 826,634 B | 1000 | 237976.00 | 1221.37 | 1153115.00 | 683.66 | `zerde` 4.85x faster |
| large | 30,267,904 B | 81,572,128 B | 100 | 24108370.00 | 1197.33 | 114227142.00 | 681.04 | `zerde` 4.74x faster |

### Write

| Scenario | zerde Size | bufzilla Size | Iterations | zerde ns/op | zerde MiB/s | bufzilla ns/op | bufzilla MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 2,991 B | 1000000 | 616.00 | 2017.27 | 2145.00 | 1329.81 | `zerde` 3.48x faster |
| medium | 304,775 B | 826,634 B | 1000 | 155967.00 | 1863.57 | 642087.00 | 1227.78 | `zerde` 4.12x faster |
| large | 30,267,904 B | 81,572,128 B | 100 | 15765120.00 | 1830.99 | 63728572.00 | 1220.70 | `zerde` 4.04x faster |

### Roundtrip

| Scenario | zerde Size | bufzilla Size | Iterations | zerde ns/op | zerde MiB/s | bufzilla ns/op | bufzilla MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 2,991 B | 1000000 | 1480.00 | 1679.24 | 5514.00 | 1034.62 | `zerde` 3.73x faster |
| medium | 304,775 B | 826,634 B | 1000 | 393455.00 | 1477.46 | 1761410.00 | 895.12 | `zerde` 4.48x faster |
| large | 30,267,904 B | 81,572,128 B | 100 | 39622652.00 | 1457.03 | 174934465.00 | 889.40 | `zerde` 4.42x faster |

### Notes

- `zerde.bin` is materially more compact on this workload, so the throughput gap is paired with a wire-size advantage rather than inflated output.
- Because the formats differ, parse is intentionally measured as end-to-end typed decode on each library's own bytes instead of forcing one shared binary document.
