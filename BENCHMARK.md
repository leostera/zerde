# JSON Benchmark

This file captures the current JSON benchmark results for `zerde` against Zig's `std.json`.

## Environment

- Date: 2026-04-20
- Zig: `0.16.0`
- CPU: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
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

## Results

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

## Notes

- These numbers are from a single machine and a single benchmark run.
- The large scenario uses one iteration because the payload is already about `103.88 MiB`.
- On the current direct typed JSON path, `zerde` is consistently faster than `std.json` for parsing.
- `std.json` is still slightly ahead on writing in these scenarios, though the gap narrows on the large payload.
