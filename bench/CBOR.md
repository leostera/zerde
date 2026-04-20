# CBOR Benchmark

This file is a running log of CBOR benchmark results for `zerde` against `zbor`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-cbor -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as CBOR:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against one canonical CBOR document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a canonical CBOR document of about `76.22 MiB`, with write outputs of about `76.22 MiB` for `zerde` and `75.28 MiB` for `zbor`.

## 2026-04-20 - 49d8ca8

Changes since previous run:

- added the first CBOR benchmark harness and `bench-cbor` build step
- parse measures `zerde` against `zbor` on the same canonical CBOR document per scenario
- the `zbor` parse timing includes `DataItem.new(...)` because that validation wrapper is part of its public typed parse path
- write and roundtrip use each library's own CBOR output size because the two serializers do not emit the exact same document

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 1000000 | 2963.69 | 944.76 | 24204.02 | 115.68 | `zerde` 8.17x faster |
| medium | 806,470 B | 1000 | 934998.21 | 822.58 | 8219954.67 | 93.57 | `zerde` 8.79x faster |
| large | 79,925,027 B | 100 | 91059739.59 | 837.06 | 796041867.08 | 95.75 | `zerde` 8.74x faster |

### Write

| Scenario | zerde Size | zbor Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 2,880 B | 1000000 | 1700.21 | 1646.85 | 2925.42 | 938.87 | `zerde` 1.72x faster |
| medium | 806,470 B | 796,256 B | 1000 | 491605.00 | 1564.49 | 941530.54 | 806.53 | `zerde` 1.91x faster |
| large | 79,925,027 B | 78,933,633 B | 100 | 50543477.08 | 1508.06 | 91421371.67 | 823.41 | `zerde` 1.81x faster |

### Roundtrip

| Scenario | zerde Size | zbor Size | Iterations | zerde ns/op | zerde MiB/s | zbor ns/op | zbor MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,936 B | 2,880 B | 1000000 | 4737.94 | 1181.94 | 30631.48 | 179.33 | `zerde` 6.46x faster |
| medium | 806,470 B | 796,256 B | 1000 | 1403336.92 | 1096.12 | 10050243.33 | 151.11 | `zerde` 7.16x faster |
| large | 79,925,027 B | 78,933,633 B | 100 | 139319860.41 | 1094.21 | 999369348.75 | 150.65 | `zerde` 7.17x faster |

### Notes

- `zbor` emits a slightly smaller document on this workload, but `zerde` still wins write throughput in all three scenarios.
- The biggest CBOR gap is parse and roundtrip, where the baseline's required `DataItem` validation step shows up clearly in the end-to-end numbers.
