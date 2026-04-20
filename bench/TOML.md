# TOML Benchmark

This file is a running log of TOML benchmark results for `zerde` against [`sam701/zig-toml`](https://github.com/sam701/zig-toml).

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-toml -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `8ba2955`, uses a nested columnar payload on a shared TOML subset with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` table
- a nested `endpoints` table with arrays of strings, enums, integers, floats, and bools
- a nested `metrics` table with arrays of strings, enums, signed integers, unsigned integers, floats, and fixed string arrays
- a nested `events` table with arrays of strings, enums, signed integers, unsigned integers, floats, bools, and fixed arrays
- parse and write both measured against one canonical TOML document per scenario

Why columnar instead of row-oriented arrays-of-tables:

- `zerde` and `zig-toml` both serialize this shape cleanly and at large sizes
- `zig-toml` does not support slice fields in serialization
- the two libraries do not agree on the representation of pointer-to-array struct fields, so that shape is not a fair apples-to-apples benchmark
- the payload avoids byte-slice columns because both serializers map `[]u8` as strings, which is not a good shared benchmark shape for numeric arrays

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a canonical parse input of about `68.89 MiB`, with write outputs of about `68.89 MiB` for `zerde` and `70.60 MiB` for `zig-toml`.

Runs before `8ba2955` used the older write-only harness, so the new parse numbers are not comparable to those entries.

## 2026-04-20 - 102c8eb

Changes since previous run:

- preserved enum type information into the TOML backend so enum values no longer go through the generic string path
- specialized quoted enum emission for both scalar fields and inline arrays
- reduced per-element overhead again in the large columnar arrays dominated by enums and scalar values

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 1000000 | 8194.18 | 343.33 | 18507.01 | 152.01 | `zerde` 2.26x faster |
| medium | 728,766 B | 1000 | 1937601.13 | 358.69 | 3453429.42 | 201.25 | `zerde` 1.78x faster |
| large | 72,232,635 B | 100 | 190880997.91 | 360.89 | 340876375.83 | 202.09 | `zerde` 1.79x faster |

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 3326.43 | 845.75 | 6327.49 | 459.69 | `zerde` 1.90x faster |
| medium | 728,766 B | 747,054 B | 1000 | 793043.75 | 876.38 | 881136.00 | 808.55 | `zerde` 1.11x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 78872590.42 | 873.39 | 87011245.42 | 811.44 | `zerde` 1.10x faster |

### Roundtrip

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 11621.15 | 484.18 | 27073.73 | 214.87 | `zerde` 2.33x faster |
| medium | 728,766 B | 747,054 B | 1000 | 2674676.63 | 519.69 | 4380012.67 | 325.32 | `zerde` 1.64x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 267133226.25 | 515.75 | 426886360.83 | 330.79 | `zerde` 1.60x faster |

### Notes

- This run turns the TOML write lead from a near tie into a clearer win on medium and large payloads.
- The biggest remaining throughput cost is now plain scalar formatting and raw string emission rather than dispatch overhead inside inline arrays.

## 2026-04-20 - 48da477

Changes since previous run:

- switched TOML basic-string emission to chunked escape scanning instead of byte-at-a-time writes
- added a format-level inline sequence fast path so TOML can serialize scalar-heavy arrays without bouncing through the generic per-item typed callback path
- specialized inline sequence emission for bools, integers, floats, enums, strings, and nested inline arrays
- expanded TOML basic-string escaping to cover control bytes while keeping the streaming writer architecture

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 1000000 | 8515.16 | 330.39 | 20271.41 | 138.78 | `zerde` 2.38x faster |
| medium | 728,766 B | 1000 | 1916525.88 | 362.64 | 3360138.42 | 206.84 | `zerde` 1.75x faster |
| large | 72,232,635 B | 100 | 181566105.84 | 379.40 | 327786710.00 | 210.16 | `zerde` 1.81x faster |

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 3575.03 | 786.94 | 6712.09 | 433.35 | `zerde` 1.88x faster |
| medium | 728,766 B | 747,054 B | 1000 | 838778.58 | 828.59 | 844664.63 | 843.47 | `zerde` 0.7% faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 82111884.17 | 838.93 | 82259511.25 | 858.31 | `zerde` 0.2% faster |

### Roundtrip

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 12277.72 | 458.28 | 27295.52 | 213.13 | `zerde` 2.22x faster |
| medium | 728,766 B | 747,054 B | 1000 | 2696033.00 | 515.58 | 4241899.21 | 335.91 | `zerde` 1.57x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 262820705.42 | 524.21 | 409655304.58 | 344.70 | `zerde` 1.56x faster |

### Notes

- This is the first recorded run where `zerde` wins TOML write on all three scenarios, though the medium and large wins are still narrow.
- The main win came from faster string scanning and lower overhead in inline sequence emission, not from changing the benchmark shape or adding format-specific shortcuts for this workload.

## 2026-04-20 - b9b03f2

Changes since previous run:

- added end-to-end TOML roundtrip benchmarks
- roundtrip now validates `typed -> bytes -> typed` correctness once per scenario before entering the timed loop
- parse, write, and roundtrip all continue to run on the shared TOML subset accepted by both libraries

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 1000000 | 8213.13 | 342.54 | 18978.32 | 148.24 | `zerde` 2.31x faster |
| medium | 728,766 B | 1000 | 1854068.58 | 374.85 | 3351989.29 | 207.34 | `zerde` 1.81x faster |
| large | 72,232,635 B | 100 | 182912285.42 | 376.61 | 327952118.33 | 210.05 | `zerde` 1.79x faster |

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 3994.45 | 704.31 | 6355.43 | 457.67 | `zerde` 1.59x faster |
| medium | 728,766 B | 747,054 B | 1000 | 949205.17 | 732.20 | 830005.38 | 858.36 | `zig-toml` 1.14x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 92975430.41 | 740.91 | 80711253.75 | 874.77 | `zig-toml` 1.15x faster |

### Roundtrip

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 12376.90 | 454.61 | 25941.57 | 224.25 | `zerde` 2.10x faster |
| medium | 728,766 B | 747,054 B | 1000 | 2803547.71 | 495.80 | 4255314.88 | 334.85 | `zerde` 1.52x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 274027020.83 | 502.77 | 404140020.83 | 349.40 | `zerde` 1.47x faster |

### Notes

- `zerde` still loses TOML write throughput on the medium and large scenarios, but the read advantage is large enough that full roundtrip stays ahead in all three cases.
- Roundtrip correctness is checked once before timing for each scenario so the measured numbers stay focused on serialization and deserialization work.

## 2026-04-20 - 8ba2955

Changes since previous run:

- added TOML parse benchmarks against `zig-toml`
- switched the TOML benchmark to a shared parse+write workload
- changed the `retries` column from a byte slice to integer counts so the canonical TOML stays valid for both libraries

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 1000000 | 8196.32 | 343.24 | 19225.35 | 146.33 | `zerde` 2.35x faster |
| medium | 728,766 B | 1000 | 1807772.17 | 384.45 | 3276471.04 | 212.12 | `zerde` 1.81x faster |
| large | 72,232,635 B | 100 | 174376910.83 | 395.04 | 322422231.67 | 213.65 | `zerde` 1.85x faster |

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,950 B | 3,050 B | 1000000 | 4025.18 | 698.93 | 6722.98 | 432.65 | `zerde` 1.67x faster |
| medium | 728,766 B | 747,054 B | 1000 | 937816.13 | 741.09 | 840051.33 | 848.10 | `zig-toml` 1.12x faster |
| large | 72,232,635 B | 74,033,835 B | 100 | 91210099.17 | 755.25 | 79092874.58 | 892.67 | `zig-toml` 1.15x faster |

### Notes

- `zerde` is ahead on TOML parse in all three scenarios on the shared subset benchmark.
- `zerde` still wins TOML write on the small payload, while `zig-toml` keeps a medium and large write advantage.
- Parse throughput is measured against one canonical TOML input per scenario so both libraries consume the same bytes.

## 2026-04-20 - cd59eb1

Changes since previous run:

- added `zig-toml` as a benchmark dependency
- added a dedicated TOML serializer benchmark and a `bench-toml` build step
- fixed `zerde`'s TOML arrays-of-tables state tracking so nested fields no longer clobber the outer table-array context

### Write

| Scenario | zerde Size | zig-toml Size | Iterations | zerde ns/op | zerde MiB/s | zig-toml ns/op | zig-toml MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 2,939 B | 3,037 B | 1000000 | 4073.12 | 688.13 | 6580.97 | 440.10 | `zerde` 1.62x faster |
| medium | 727,571 B | 745,857 B | 1000 | 945424.92 | 733.92 | 830189.38 | 856.80 | `zig-toml` 1.14x faster |
| large | 72,119,881 B | 73,921,079 B | 100 | 92861007.50 | 740.66 | 81907176.67 | 860.69 | `zig-toml` 1.13x faster |

### Notes

- `zerde` wins clearly on the small payload, while `zig-toml` pulls ahead by about `13-14%` on the medium and large payloads.
- Output sizes differ slightly because the serializers make different formatting choices, so throughput is reported against each library's own emitted byte count.
- This benchmark is still serialize-only. TOML parse benchmarks are the next step now that `zerde` has a TOML deserializer.
