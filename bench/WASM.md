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
