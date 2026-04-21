# BSON Benchmark

This file is a running log of BSON benchmark results for `zerde` against `zig-bson`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-bson -Doptimize=ReleaseFast`

## Workload

Current harness uses the same mixed nested payload family as the JSON benchmark, encoded as BSON:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against one canonical BSON document per scenario

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

This run uses a signed-integer and string-signature payload because that is the shared typed subset both libraries support cleanly.

## 2026-04-21 - 352166c

Changes since previous run:

- flattened BSON serialization into one contiguous output buffer
- switched nested BSON documents and arrays to in-place length backpatching instead of per-frame temporary buffers
- removed the remaining nested-document copy step on the write path

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 1000000 | 2722.57 | 1474.70 | 14822.31 | 270.87 | `zerde` 5.44x faster |
| medium | 1,198,550 B | 1000 | 838012.67 | 1363.97 | 6124481.34 | 186.63 | `zerde` 7.31x faster |
| large | 118,617,999 B | 100 | 81112045.45 | 1394.65 | 803683736.26 | 140.76 | `zerde` 9.91x faster |

### Write

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 6961.70 | 576.72 | 33324.54 | 120.48 | `zerde` 4.79x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 1698452.53 | 672.98 | 5733876.78 | 199.35 | `zerde` 3.38x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 183895481.26 | 615.15 | 598149069.24 | 189.12 | `zerde` 3.25x faster |

### Roundtrip

| Scenario | zerde Size | zig-bson Size | Iterations | zerde ns/op | zerde MiB/s | zig-bson ns/op | zig-bson MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,210 B | 4,210 B | 1000000 | 10794.47 | 743.89 | 50223.86 | 159.88 | `zerde` 4.65x faster |
| medium | 1,198,550 B | 1,198,550 B | 1000 | 2529969.59 | 903.59 | 11894976.17 | 192.19 | `zerde` 4.70x faster |
| large | 118,617,999 B | 118,617,999 B | 100 | 266686571.24 | 848.36 | 1401168325.44 | 161.47 | `zerde` 5.25x faster |

### Notes

- The BSON rewrite turned write from the slowest part of the comparison into a clear win in every scenario.
- BSON now joins CBOR as a binary format where `zerde` is substantially ahead on parse, write, and roundtrip.
