# YAML Benchmark

This file is a running log of YAML benchmark results for `zerde` against `zig-yaml`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-yaml -Doptimize=ReleaseFast`

## Workload

Current harness uses a mixed nested YAML payload with One Piece-themed data:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct
- a `routes` array of structs with strings, enums, integers, optionals, fixed float arrays, and bools
- a `ledgers` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- a `logs` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays
- parse measured against one canonical YAML document per scenario

Current scenarios:

- `small`: `4` routes, `6` ledgers, `8` logs, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` routes, `96` ledgers, `4,500` logs, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` routes, `512` ledgers, `450,000` logs, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a canonical YAML parse input of about `118.01 MiB`, with write outputs of about `126.45 MiB` for `zerde` and `118.01 MiB` for `zig-yaml`.

## 2026-04-21 - ced89d0

Changes since previous run:

- reran the YAML benchmark on current `HEAD` after the parse-path intermediate string copy removal work landed in other backends
- no YAML-specific serializer, deserializer, or workload changes landed in this commit
- this entry refreshes the YAML baseline for the current tree

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,196 B | 1000000 | 15721.25 | 254.54 | 31142.40 | 128.49 | `zerde` 1.98x faster |
| medium | 1,250,463 B | 1000 | 4823705.46 | 247.22 | 9409578.22 | 126.74 | `zerde` 1.95x faster |
| large | 123,747,473 B | 100 | 493036764.21 | 239.36 | 979227316.26 | 120.52 | `zerde` 1.99x faster |

### Write

| Scenario | zerde Size | zig-yaml Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,670 B | 4,196 B | 1000000 | 6000.50 | 742.21 | 17373.40 | 230.33 | `zerde` 2.90x faster |
| medium | 1,343,451 B | 1,250,463 B | 1000 | 1500090.58 | 854.09 | 3757412.70 | 317.38 | `zerde` 2.50x faster |
| large | 132,592,435 B | 123,747,473 B | 100 | 147209265.01 | 858.98 | 374259243.73 | 315.33 | `zerde` 2.54x faster |

### Roundtrip

| Scenario | zerde Size | zig-yaml Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,670 B | 4,196 B | 1000000 | 21961.66 | 405.58 | 49136.01 | 162.88 | `zerde` 2.24x faster |
| medium | 1,343,451 B | 1,250,463 B | 1000 | 6416305.18 | 399.36 | 13381528.82 | 178.24 | `zerde` 2.09x faster |
| large | 132,592,435 B | 123,747,473 B | 100 | 628870915.84 | 402.15 | 1379585104.58 | 171.09 | `zerde` 2.19x faster |

### Notes

- YAML stays in the same performance band as the previous recorded run, with `zerde` ahead on parse, write, and roundtrip throughout.
- `zerde` still emits a larger YAML document than the baseline on this workload and still wins comfortably on write throughput.

## 2026-04-20 - 2fa5c8e

Changes since previous run:

- added the first YAML benchmark harness and `bench-yaml` build step
- added a YAML-specific mixed payload that both libraries accept cleanly
- parse measures `zerde` against `zig-yaml` on the same canonical YAML document per scenario
- the `zig-yaml` parse timing includes `Yaml.load(...)` because that document-load step is part of its public typed parse path
- write and roundtrip use each library's own emitted byte count because the two serializers do not produce the exact same YAML text

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,196 B | 1000000 | 15459.57 | 258.84 | 30094.87 | 132.97 | `zerde` 1.95x faster |
| medium | 1,250,463 B | 1000 | 4729527.50 | 252.15 | 9393257.96 | 126.96 | `zerde` 1.99x faster |
| large | 123,747,473 B | 100 | 472460584.59 | 249.79 | 974604162.50 | 121.09 | `zerde` 2.06x faster |

### Write

| Scenario | zerde Size | zig-yaml Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,670 B | 4,196 B | 1000000 | 5908.06 | 753.83 | 17363.47 | 230.46 | `zerde` 2.94x faster |
| medium | 1,343,451 B | 1,250,463 B | 1000 | 1496411.29 | 856.19 | 3642810.92 | 327.37 | `zerde` 2.43x faster |
| large | 132,592,435 B | 123,747,473 B | 100 | 147383087.92 | 857.97 | 368890573.33 | 319.92 | `zerde` 2.50x faster |

### Roundtrip

| Scenario | zerde Size | zig-yaml Size | Iterations | zerde ns/op | zerde MiB/s | zig-yaml ns/op | zig-yaml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 4,670 B | 4,196 B | 1000000 | 21712.98 | 410.23 | 48248.86 | 165.87 | `zerde` 2.22x faster |
| medium | 1,343,451 B | 1,250,463 B | 1000 | 6309396.54 | 406.13 | 13186909.79 | 180.87 | `zerde` 2.09x faster |
| large | 132,592,435 B | 123,747,473 B | 100 | 621515895.42 | 406.91 | 1367030772.08 | 172.66 | `zerde` 2.20x faster |

### Notes

- `zerde` wins YAML parse, write, and roundtrip in all three scenarios in the first recorded run.
- `zerde` emits a larger YAML document on this workload, but still stays well ahead on write throughput.
- The biggest baseline cost is on parse and roundtrip, where document loading plus typed mapping remains significantly slower than `zerde`'s direct typed path.
