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

The current large case produces a canonical CBOR document a bit over `100 MiB`.
