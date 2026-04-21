# Allocation Benchmark

This file is a running log of allocation benchmark results for `zerde`.

Unlike the timing logs, this benchmark is `zerde`-only: it measures allocation
count, total allocated bytes, and peak live bytes for parse, write, and
roundtrip paths across the supported formats.

## Environment

- Machine: `Apple M1 Ultra`
- OS: `Darwin 25.3.0 arm64`
- Zig: `0.16.0`
- Command: `zig build bench-memory -Doptimize=ReleaseFast`

## Workload

The allocation benchmark reuses the same mixed nested small/medium/large
payloads as the timing harness in `bench/common.zig`.

For each format it records:

- owned typed parse
- aliased parse when the format supports it
- write
- roundtrip (`typed -> bytes -> typed`)

The large scenario sizes differ by format because each writer emits its own
canonical representation.

## 2026-04-22 - ac2fe7e

Changes since previous run:

- added `bench-memory` as a dedicated allocation benchmark
- added allocator tracking for allocation calls, remaps, total allocated bytes, and peak live bytes
- measured owned parse, aliased parse when supported, write, and roundtrip across all benchmarked formats

### Highlights

- Binary and CBOR have the cheapest aliased parse path: `3` allocations even on the large scenario, with peak live bytes dropping to about `34.4 MiB`.
- JSON's aliased parse meaningfully reduces large-parse overhead: allocation calls fall from `812,550` to `180,229`, and peak live bytes drop from `81,100,368 B` to `74,392,128 B`.
- BSON benefits heavily from aliasing on large parses: `1,262,552` allocation calls drop to `25`, with peak live bytes falling from `92,621,316 B` to `79,283,200 B`.
- MessagePack also benefits heavily from aliasing on large parses: `2,163,107` allocation calls drop to `900,580`, and peak live bytes fall from `69,595,851 B` to `52,265,036 B`.
- ZON currently has no aliased parse mode, and its large text parse is the most allocation-heavy in the set at `1,884,817,336 B` total allocated and `959,034,162 B` peak live bytes.
- TOML and YAML still pay substantial parse-time memory costs on the large scenario even with aliased string fields, which suggests their parser/document-index layers dominate more than final string ownership.

### Large Parse

| Format | Parse Size | Owned Allocs | Owned Allocated | Owned Peak | Aliased Allocs | Aliased Allocated | Aliased Peak |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| binary | 30,448,108 B | 812,528 | 47,312,693 B | 47,312,693 B | 3 | 36,055,808 B | 36,055,808 B |
| JSON | 112,803,589 B | 812,550 | 163,154,529 B | 81,100,368 B | 180,229 | 154,780,908 B | 74,392,128 B |
| ZON | 107,850,184 B | 1,713,126 | 1,884,817,336 B | 959,034,162 B | n/a | n/a | n/a |
| CBOR | 79,925,027 B | 812,528 | 47,312,693 B | 47,312,693 B | 3 | 36,055,808 B | 36,055,808 B |
| BSON | 118,617,999 B | 1,262,552 | 159,344,365 B | 92,621,316 B | 25 | 142,687,456 B | 79,283,200 B |
| MessagePack | 72,255,694 B | 2,163,107 | 69,595,851 B | 69,595,851 B | 900,580 | 52,265,036 B | 52,265,036 B |
| TOML | 72,232,635 B | 3,154,124 | 912,222,532 B | 452,627,968 B | 1,801,494 | 892,908,355 B | 433,313,791 B |
| YAML | 132,592,435 B | 3,514,886 | 1,092,162,548 B | 755,567,552 B | 2,702,360 | 1,081,399,312 B | 755,567,552 B |

### Large Write And Roundtrip

| Format | Write Allocated | Write Peak | Roundtrip Allocated | Roundtrip Peak |
| --- | ---: | ---: | ---: | ---: |
| binary | 111,697,746 B | 62,078,867 B | 159,010,439 B | 84,560,077 B |
| JSON | 382,815,355 B | 212,700,473 B | 545,969,884 B | 212,700,473 B |
| ZON | 347,627,699 B | 193,146,640 B | 2,232,445,035 B | 1,074,922,199 B |
| CBOR | 240,226,269 B | 133,479,880 B | 287,538,962 B | 133,479,880 B |
| BSON | 355,854,126 B | 355,854,126 B | 515,198,491 B | 448,475,442 B |
| MessagePack | 249,341,676 B | 138,544,671 B | 318,937,527 B | 152,722,713 B |
| TOML | 279,941,127 B | 155,550,047 B | 1,192,163,659 B | 545,958,052 B |
| YAML | 576,422,788 B | 320,260,337 B | 1,668,585,336 B | 947,723,813 B |

### Notes

- Aliased parse helps most when the format exposes raw byte or string spans directly from the input buffer.
- For large text formats, write and roundtrip are dominated by output-buffer growth and format-specific parse indexing rather than by final typed-value ownership alone.
- This benchmark is meant to track memory behavior over time. It complements the timing logs but does not replace them.
