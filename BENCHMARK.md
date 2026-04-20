# JSON Benchmark

This file is a running log of JSON benchmark results for `zerde` against Zig's `std.json`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `8a3a0a9`, uses a mixed nested payload with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations

The current large case produces a JSON document of about `107.58 MiB`.

Runs before `8a3a0a9` used the older simpler payload, so they are not directly comparable to the newer mixed-payload runs.

## 2026-04-20 - 8a3a0a9

Changes since previous run:

- replaced the benchmark payload with a more realistic nested document that exercises strings, bools, signed and unsigned integers, floats, optionals, enums, fixed arrays, slices, and nested structs
- switched benchmark iteration counts to fixed values: `1_000_000` for small, `1_000` for medium, and `100` for large

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5687.70 | 652.25 | 12836.01 | 289.01 | `zerde` 2.26x faster |
| medium | 1,139,498 B | 1000 | 1737680.04 | 625.38 | 3804823.33 | 285.61 | `zerde` 2.19x faster |
| large | 112,803,590 B | 100 | 173746168.75 | 619.17 | 380069327.50 | 283.05 | `zerde` 2.19x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4649.56 | 797.88 | 5479.65 | 677.01 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1264018.00 | 859.73 | 1514801.38 | 717.39 | `zerde` 1.20x faster |
| large | 112,803,590 B | 100 | 124516359.16 | 863.97 | 149503560.42 | 719.57 | `zerde` 1.20x faster |

### Notes

- This is the first run using the richer mixed payload, so compare it against future entries with the same workload rather than the older simpler runs below.
- The large workload is now truly mixed data rather than a tiny wrapper around one dominant numeric array.

## 2026-04-20 - 5187fab

Changes since previous run:

- kept original integer and float types through the serializer instead of widening everything to `i128` and `f64`
- switched JSON string escaping to `std.json.Stringify.encodeJsonString`, which writes contiguous runs instead of emitting normal bytes one at a time

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 1061.25 | 533.79 | 2344.17 | 241.66 | `zerde` 2.21x faster |
| medium | 1,193,982 B | 56 | 3026555.80 | 376.23 | 6045828.86 | 188.34 | `zerde` 2.00x faster |
| large | 108,926,312 B | 1 | 302906792.00 | 342.94 | 575346375.00 | 180.55 | `zerde` 1.90x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 543.63 | 1042.05 | 672.06 | 842.90 | `zerde` 1.24x faster |
| medium | 1,193,982 B | 56 | 1058150.29 | 1076.09 | 1213110.13 | 938.64 | `zerde` 1.15x faster |
| large | 108,926,312 B | 1 | 139605667.00 | 744.10 | 154164167.00 | 673.83 | `zerde` 1.10x faster |

### Notes

- Parse stayed in the same range as the previous run.
- Write throughput flipped from slower-than-`std.json` to faster-than-`std.json` in all three scenarios.

## 2026-04-20 - 0407065

Changes since previous run:

- initial scenario-based benchmark harness with `small`, `medium`, and `large` payloads

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 1117.14 | 507.08 | 2338.16 | 242.28 | `zerde` 2.09x faster |
| medium | 1,193,982 B | 56 | 3038775.30 | 374.71 | 5983440.48 | 190.30 | `zerde` 1.97x faster |
| large | 108,926,312 B | 1 | 300554833.00 | 345.63 | 575630916.00 | 180.46 | `zerde` 1.91x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 752.66 | 752.64 | 667.38 | 848.81 | `zerde` 12.8% slower |
| medium | 1,193,982 B | 56 | 1365147.32 | 834.10 | 1203385.41 | 946.22 | `zerde` 13.4% slower |
| large | 108,926,312 B | 1 | 169926625.00 | 611.32 | 161201958.00 | 644.41 | `zerde` 5.4% slower |
