# Changelog

## 0.1.0

First public release of `zerde`.

- added a comptime-specialized typed serialization layer for Zig structs, enums, arrays, slices, optionals, and scalar values
- added format backends for binary, BSON, CBOR, JSON, MessagePack, TOML, and YAML behind one shared typed API
- added owned, arena-backed, and aliased slice parse entrypoints, plus recursive cleanup helpers for owned decode paths
- added wasm/WASI helpers for pointer+length interop and format-aware parsing and serialization inside wasm modules
- added structured parse diagnostics with field-path and input-location reporting
- added corpus-driven roundtrip tests across all supported formats
- added per-format benchmark suites and benchmark history, including comparisons against standard-library or ecosystem baselines where available
- added CI, benchmark, and tag-based release workflows for GitHub Actions
