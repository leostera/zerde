# Changelog

## Unreleased

- ported the library, tests, examples, transcoder CLI, and benchmark harness to Zig 0.17.0; `minimum_zig_version` is now `0.17.0`
- adapted the typed reflection layer to the 0.17 `@typeInfo` shape (`field_names`, `field_types`, `field_attrs`, `attrs.@"const"`)
- adapted the ZON backend to the 0.17 `std.zig.Ast`, `Zoir`, and `std.zon.Serializer` signatures
- CI installs Zig 0.17.0
- updated the `toml` (`zig-toml`), `zbor`, and `zbench` dependencies to 0.17-compatible commits
- patched the vendored `bufzilla`, `msgpack-zig`, `zig-bson`, and `zig-yaml` benchmark baselines for 0.17

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
