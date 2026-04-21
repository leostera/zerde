# MessagePack Benchmark

This file is a running log of MessagePack benchmark results for `zerde` against `msgpack.zig`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-msgpack -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as MessagePack:

- top-level scalars, enums, optionals, and slices
- a nested `metadata` struct with booleans, integers, and strings
- an `endpoints` array of structs with bools, enums, optionals, and float slices
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and string-slice labels
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and scalar slices
- parse measured against one canonical MessagePack document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

This run uses the baseline library's MessagePack output as the shared parse input so both libraries consume the same enum representation.

## 2026-04-21 - 42e7ed3

Changes since previous run:

- added the first MessagePack benchmark harness and `bench-msgpack` build step
- vendored and patched `msgpack.zig` for Zig `0.16`
- switched `zerde`'s MessagePack enum encoding to compact numeric tags
- parse measures both libraries against the same baseline-encoded MessagePack payload per scenario

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 3345.77 | 763.33 | 3325.23 | 768.05 | `msgpack.zig` 0.6% faster |
| medium | 728,807 B | 1000 | 1031567.20 | 673.78 | 910726.20 | 763.18 | `msgpack.zig` 1.13x faster |
| large | 72,267,214 B | 100 | 103025607.49 | 668.95 | 90392317.13 | 762.45 | `msgpack.zig` 1.14x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1691.64 | 1509.74 | 1334.71 | 1913.48 | `msgpack.zig` 1.27x faster |
| medium | 728,679 B | 728,807 B | 1000 | 498382.62 | 1394.36 | 408262.15 | 1702.45 | `msgpack.zig` 1.22x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 49482804.21 | 1392.57 | 40453282.10 | 1703.68 | `msgpack.zig` 1.22x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 5096.78 | 1002.18 | 4890.09 | 1044.54 | `msgpack.zig` 1.04x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1540764.22 | 902.05 | 1322876.74 | 1050.81 | `msgpack.zig` 1.16x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 153151492.98 | 899.87 | 130947336.23 | 1052.63 | `msgpack.zig` 1.17x faster |

### Notes

- Numeric enum tags closed the output-size gap, but the baseline still wins raw parse and write throughput.
- `zerde` now emits a slightly smaller document than `msgpack.zig` on the medium and large scenarios, so the remaining gap is execution cost rather than inflated output size.
