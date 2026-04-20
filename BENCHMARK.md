# JSON Benchmark

This file is a running log of JSON benchmark results for `zerde` against Zig's `std.json`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench -Doptimize=ReleaseFast`

## Workload

The benchmark uses a typed payload with:

- a renamed top-level `serviceName` field
- a nested `metadata` struct with a renamed `publicURL` field
- a `metrics` array of structs
- a `samples` array of integers

Scenarios:

- `small`: `4` metrics, `32` samples, `16` bytes of extra string padding
- `medium`: `2,048` metrics, `180,000` samples, `256` bytes of extra string padding
- `large`: `16,384` metrics, `18,000,000` samples, `1,024` bytes of extra string padding

The large case produces a JSON document of about `103.88 MiB`.

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
