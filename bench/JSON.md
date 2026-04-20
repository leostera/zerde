# JSON Benchmark

This file is a running log of JSON benchmark results for `zerde` against Zig's `std.json`.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-json -Doptimize=ReleaseFast`

## Workload

Current harness, starting at `8a3a0a9`, uses a mixed nested payload with:

- top-level scalars, enums, optionals, and fixed arrays
- a nested `metadata` struct with a renamed `publicURL` field
- an `endpoints` array of structs with bools, enums, optionals, and fixed float arrays
- a `metrics` array of structs with signed and unsigned integers, floats, optionals, and fixed string arrays
- an `events` array of structs with enums, bools, signed and unsigned integers, floats, optionals, and fixed arrays

Current scenarios:

- `small`: `4` endpoints, `6` metrics, `8` events, `1_000_000` parse iterations, `1_000_000` write iterations, `1_000_000` roundtrip iterations
- `medium`: `24` endpoints, `96` metrics, `4,500` events, `1_000` parse iterations, `1_000` write iterations, `1_000` roundtrip iterations
- `large`: `64` endpoints, `512` metrics, `450,000` events, `100` parse iterations, `100` write iterations, `100` roundtrip iterations

The current large case produces a JSON document of about `107.58 MiB`.

Runs before `8a3a0a9` used the older simpler payload, so they are not directly comparable to the newer mixed-payload runs.

## 2026-04-20 - b9b03f2

Changes since previous run:

- added end-to-end JSON roundtrip benchmarks
- roundtrip now validates `typed -> bytes -> typed` correctness once per scenario before entering the timed loop
- the harness records separate `std.json` write sizes because `std.json` emits a larger document than `zerde` on the shared mixed payload

### Parse

| Scenario | Parse Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 1000000 | 5610.85 | 661.01 | 12880.34 | 287.95 | `zerde` 2.30x faster |
| medium | 1,139,497 B | 1000 | 1742032.13 | 623.82 | 3815532.38 | 284.81 | `zerde` 2.19x faster |
| large | 112,803,589 B | 100 | 173975188.75 | 618.35 | 376462378.75 | 285.76 | `zerde` 2.16x faster |

### Write

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 4784.75 | 775.14 | 5506.06 | 742.87 | `zerde` 1.15x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 1292649.25 | 840.68 | 1533028.00 | 747.88 | `zerde` 1.19x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 127489172.09 | 843.82 | 149742352.09 | 756.57 | `zerde` 1.17x faster |

### Roundtrip

| Scenario | zerde Size | std.json Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,889 B | 4,289 B | 1000000 | 10421.09 | 711.80 | 18902.82 | 432.77 | `zerde` 1.81x faster |
| medium | 1,139,497 B | 1,202,217 B | 1000 | 3054196.46 | 711.62 | 5414850.13 | 423.47 | `zerde` 1.77x faster |
| large | 112,803,589 B | 118,794,235 B | 100 | 299403212.50 | 718.62 | 531540714.17 | 426.27 | `zerde` 1.78x faster |

### Notes

- `std.json` still parses the same canonical `zerde` input in the parse benchmark, but its own serializer produces a larger output on this workload, so write and roundtrip throughput now use per-library byte counts.
- Roundtrip correctness is checked once before timing for each scenario so the measured numbers stay focused on serialization and deserialization work.

## 2026-04-20 - 8ae56d3

Changes since previous run:

- removed the old runtime `Value` fallback path, so the package now relies on typed format backends only
- renamed the aliased JSON slice parse API to `parseSliceAliased`
- added README and source-level documentation across the package

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5498.19 | 674.73 | 12760.10 | 290.73 | `zerde` 2.32x faster |
| medium | 1,139,498 B | 1000 | 1693899.29 | 641.54 | 3816176.96 | 284.76 | `zerde` 2.25x faster |
| large | 112,803,590 B | 100 | 168851010.00 | 637.12 | 377039325.00 | 285.32 | `zerde` 2.23x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4676.09 | 793.35 | 5518.36 | 672.26 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1266087.50 | 858.32 | 1528167.92 | 711.12 | `zerde` 1.21x faster |
| large | 112,803,590 B | 100 | 125885706.25 | 854.57 | 150331443.33 | 715.60 | `zerde` 1.19x faster |

### Notes

- Performance stayed within noise of the previous aliased-slice run, which is what we want from a cleanup and documentation pass.
- This run was taken on a clean commit after removing the runtime tree fallback, not on a dirty working tree.

## 2026-04-20 - 1804f43

Changes since previous run:

- added an explicit slice-parse path that can alias unescaped JSON strings directly from the input buffer when the caller keeps the input alive
- switched the benchmark to compare `zerde`'s aliased parse path against `std.json.parseFromSliceLeaky`, so both parsers are allowed to reuse the input slice

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5457.33 | 679.78 | 12809.68 | 289.61 | `zerde` 2.35x faster |
| medium | 1,139,498 B | 1000 | 1686185.67 | 644.48 | 3800610.25 | 285.93 | `zerde` 2.25x faster |
| large | 112,803,590 B | 100 | 168133617.50 | 639.84 | 376343222.09 | 285.85 | `zerde` 2.24x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4671.43 | 794.14 | 5510.73 | 673.19 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1262402.46 | 860.83 | 1521429.42 | 714.27 | `zerde` 1.21x faster |
| large | 112,803,590 B | 100 | 125214744.17 | 859.15 | 150374654.17 | 715.40 | `zerde` 1.20x faster |

### Notes

- Parse improved by about `4.2%` on small, `3.1%` on medium, and `3.3%` on large compared with the previous mixed-payload run.
- Write stayed in the same range as the previous run because this change only affects the typed JSON read path.

## 2026-04-20 - 8a3a0a9

Changes since previous run:

- replaced the benchmark payload with a more realistic nested document that exercises strings, bools, signed and unsigned integers, floats, optionals, enums, fixed arrays, slices, and nested structs
- switched benchmark iteration counts to fixed values: `1_000_000` for small, `1_000` for medium, and `100` for large

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 5687.70 | 652.25 | 12836.01 | 289.01 | `zerde` 2.26x faster |
| medium | 1,139,498 B | 1000 | 1737680.04 | 625.38 | 3804823.33 | 285.61 | `zerde` 2.19x faster |
| large | 112,803,590 B | 100 | 173746168.75 | 619.17 | 380069327.50 | 283.05 | `zerde` 2.19x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 3,890 B | 1000000 | 4649.56 | 797.88 | 5479.65 | 677.01 | `zerde` 1.18x faster |
| medium | 1,139,498 B | 1000 | 1264018.00 | 859.73 | 1514801.38 | 717.39 | `zerde` 1.20x faster |
| large | 112,803,590 B | 100 | 124516359.16 | 863.97 | 149503560.42 | 719.57 | `zerde` 1.20x faster |

### Notes

- This is the first run using the richer mixed payload, so compare it against future entries with the same workload rather than the older simpler runs below.
- The large workload is now truly mixed data rather than a tiny wrapper around one dominant numeric array.

## 2026-04-20 - 5187fab

Changes since previous run:

- kept original integer and float types through the serializer instead of widening everything to `i128` and `f64`
- switched JSON string escaping to `std.json.Stringify.encodeJsonString`, which writes contiguous runs instead of emitting normal bytes one at a time

### Parse

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 1061.25 | 533.79 | 2344.17 | 241.66 | `zerde` 2.21x faster |
| medium | 1,193,982 B | 56 | 3026555.80 | 376.23 | 6045828.86 | 188.34 | `zerde` 2.00x faster |
| large | 108,926,312 B | 1 | 302906792.00 | 342.94 | 575346375.00 | 180.55 | `zerde` 1.90x faster |

### Write

| Scenario | JSON Size | Iterations | zerde ns/op | zerde MiB/s | std.json ns/op | std.json MiB/s | Relative |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | --- |
| small | 594 B | 100000 | 543.63 | 1042.05 | 672.06 | 842.90 | `zerde` 1.24x faster |
| medium | 1,193,982 B | 56 | 1058150.29 | 1076.09 | 1213110.13 | 938.64 | `zerde` 1.15x faster |
| large | 108,926,312 B | 1 | 139605667.00 | 744.10 | 154164167.00 | 673.83 | `zerde` 1.10x faster |

### Notes

- Parse stayed in the same range as the previous run.
- Write throughput flipped from slower-than-`std.json` to faster-than-`std.json` in all three scenarios.

## 2026-04-20 - 0407065

Changes since previous run:

- initial scenario-based benchmark harness with `small`, `medium`, and `large` payloads

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
