# WASM Benchmark

This file is a running log of wasm helper benchmark results for `zerde.wasm` against the equivalent direct `zerde.bin` path.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-wasm -Doptimize=ReleaseFast`

## Workload

The wasm helper uses the same compact binary transport as `zerde.bin`.

These benchmarks intentionally measure:

- `zerde.wasm.serializeOwned(...)` against the equivalent direct binary write path
- `zerde.wasm.parse(...)` against the equivalent direct binary owning parse path
- `typed -> wasm buffer -> typed` against `typed -> binary buffer -> typed`

So the point of the comparison is not wire-format speed. The point is measuring the extra cost, if any, of the wasm pointer+length helper layer used for JS / WASI interop.

The workload reuses the same mixed nested binary payload as `bench/BIN.md`:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

## 2026-04-21 - 73bb719

Changes since previous run:

- expanded `zerde.wasm` from binary-only helpers into format-aware helpers that can parse and serialize JSON, YAML, MessagePack, and any other backend that exposes the normal typed slice APIs
- added browser-oriented freestanding wasm examples for binary, JSON, YAML, and MessagePack payloads
- kept the same benchmark workload so this run isolates the overhead of the broader wasm helper surface itself

### Parse

| Scenario | Parse Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 821.00 | 1513.57 | 816.00 | 1522.84 | `bin` 1.01x faster |
| medium | 304,775 B | 1000 | 194349.00 | 1495.54 | 193578.00 | 1501.49 | effectively tied |
| large | 30,267,904 B | 100 | 20586007.00 | 1402.20 | 20781071.00 | 1389.04 | `wasm` 1.01x faster |

### Write

| Scenario | Write Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 3575.00 | 347.59 | 3421.00 | 363.24 | `bin` 1.05x faster |
| medium | 304,775 B | 1000 | 280991.00 | 1034.40 | 280591.00 | 1035.87 | effectively tied |
| large | 30,267,904 B | 100 | 30937982.00 | 933.02 | 30191607.00 | 956.08 | `bin` 1.02x faster |

### Roundtrip

| Scenario | Write Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 4265.00 | 582.71 | 4267.00 | 582.44 | effectively tied |
| medium | 304,775 B | 1000 | 487019.00 | 1193.61 | 478640.00 | 1214.51 | `bin` 1.02x faster |
| large | 30,267,904 B | 100 | 53445461.00 | 1080.19 | 51520704.00 | 1120.55 | `bin` 1.04x faster |

### Notes

- The broader format-aware helper layer is still essentially free on parse; it remains within noise of the direct binary path.
- Write and roundtrip stay close as well, with the direct path still slightly ahead because `zerde.wasm` keeps the owned buffer lifecycle that real wasm exports need.

## 2026-04-21 - 7ecaaef

Changes since previous run:

- added the first dedicated wasm helper benchmark harness
- compared `zerde.wasm` against the equivalent direct `zerde.bin` API path instead of treating wasm support like a separate format
- kept the same mixed binary payload family and fixed iteration counts used by the binary benchmark

### Parse

| Scenario | Parse Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 830.00 | 1497.15 | 824.00 | 1508.06 | `bin` 1.01x faster |
| medium | 304,775 B | 1000 | 193630.00 | 1501.09 | 193557.00 | 1501.66 | effectively tied |
| large | 30,267,904 B | 100 | 20555984.00 | 1404.25 | 20591526.00 | 1401.83 | effectively tied |

### Write

| Scenario | Write Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 3526.00 | 352.42 | 3697.00 | 336.12 | `wasm` 1.05x faster |
| medium | 304,775 B | 1000 | 286485.00 | 1014.56 | 283997.00 | 1023.45 | effectively tied |
| large | 30,267,904 B | 100 | 29686616.00 | 972.35 | 30370354.00 | 950.46 | `wasm` 1.02x faster |

### Roundtrip

| Scenario | Write Size | Iterations | wasm ns/op | wasm MiB/s | bin ns/op | bin MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 1,303 B | 1000000 | 4491.00 | 553.39 | 4171.00 | 595.85 | `bin` 1.08x faster |
| medium | 304,775 B | 1000 | 491250.00 | 1183.33 | 480533.00 | 1209.72 | `bin` 1.02x faster |
| large | 30,267,904 B | 100 | 53160605.00 | 1085.98 | 50750969.00 | 1137.54 | `bin` 1.05x faster |

### Notes

- The helper layer is effectively free on parse and write; the numbers stay within noise of the direct binary path.
- Roundtrip is slightly slower through `zerde.wasm` because `serializeOwned(...)` always materializes a fresh owned buffer, which is exactly the cost a wasm export would pay.
