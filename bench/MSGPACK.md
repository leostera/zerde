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

## 2026-04-21 - 500513c

Changes since previous run:

- definite-length streaming arrays now consume their known element counts directly and close once, instead of paying an item-boundary call for every element
- MessagePack object reads now resolve map keys straight to typed field indexes on the hot path
- shared typed field matching now buckets candidate names by length before falling back to exact byte comparison

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 2824.97 | 904.06 | 3280.92 | 778.42 | `zerde` 1.16x faster |
| medium | 728,807 B | 1000 | 886409.36 | 784.11 | 866966.33 | 801.70 | `msgpack.zig` 1.02x faster |
| large | 72,267,214 B | 100 | 88089157.45 | 782.38 | 86595374.62 | 795.88 | `msgpack.zig` 1.02x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1381.92 | 1848.12 | 1356.43 | 1882.84 | `msgpack.zig` 1.02x faster |
| medium | 728,679 B | 728,807 B | 1000 | 404100.75 | 1719.68 | 416559.07 | 1668.54 | `zerde` 1.03x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 40200141.61 | 1714.13 | 41283827.11 | 1669.40 | `zerde` 1.03x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 4228.69 | 1207.91 | 4958.97 | 1030.03 | `zerde` 1.17x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1291313.37 | 1076.30 | 1291738.82 | 1076.14 | `zerde` 1.00x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 127788007.04 | 1078.48 | 128469128.33 | 1072.93 | `zerde` 1.01x faster |

### Notes

- This pass closes most of the remaining MessagePack read gap without changing the wire format or narrowing supported semantics.
- Parse is now clearly ahead on the small case and within about `2%` on the medium and large cases; write stays ahead on the medium and large cases.

## 2026-04-21 - 565b6be

Changes since previous run:

- pre-encoded MessagePack field keys at comptime so repeated struct field names no longer rebuild their string headers at runtime
- added direct inline field-value emission for scalar, string, byte, optional, and scalar-sequence fields
- specialized MessagePack scalar-sequence writes for arrays and slices of bools, numbers, enums, strings, and bytes
- tightened enum-tag and field-name handling on the read path without changing the wire format under test

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 1000000 | 3419.00 | 746.98 | 3388.02 | 753.81 | `msgpack.zig` 1.01x faster |
| medium | 728,807 B | 1000 | 1057704.96 | 657.13 | 914704.48 | 759.86 | `msgpack.zig` 1.16x faster |
| large | 72,267,214 B | 100 | 107489919.15 | 641.17 | 91732676.23 | 751.31 | `msgpack.zig` 1.17x faster |

### Write

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 1424.37 | 1793.03 | 1405.30 | 1817.37 | `msgpack.zig` 1.01x faster |
| medium | 728,679 B | 728,807 B | 1000 | 414245.29 | 1677.56 | 420558.14 | 1652.67 | `zerde` 1.02x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 41162997.88 | 1674.04 | 41914015.83 | 1644.30 | `zerde` 1.02x faster |

### Roundtrip

| Scenario | zerde Size | msgpack.zig Size | Iterations | zerde ns/op | zerde MiB/s | msgpack.zig ns/op | msgpack.zig MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,678 B | 2,678 B | 1000000 | 4875.79 | 1047.60 | 5154.56 | 990.94 | `zerde` 1.06x faster |
| medium | 728,679 B | 728,807 B | 1000 | 1467359.60 | 947.17 | 1343465.95 | 1034.70 | `msgpack.zig` 1.09x faster |
| large | 72,255,694 B | 72,267,214 B | 100 | 147602240.87 | 933.70 | 134519315.01 | 1024.68 | `msgpack.zig` 1.10x faster |

### Notes

- This pass nearly eliminated the MessagePack write gap: the baseline's `~22%` write lead on medium and large is now a slight `zerde` win.
- Parse is still the main remaining deficit, so roundtrip improved but does not yet beat the baseline on the medium and large scenarios.

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
