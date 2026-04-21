# Agents

Project conventions for automated changes:

- use conventional commits
- run `zig build test` after code changes
- when touching benchmarked code, run the relevant `zig build bench-* -Doptimize=ReleaseFast` command
- benchmark workflow lives in `bench/README.md`
- benchmark history lives in `bench/BIN.md`, `bench/BSON.md`, `bench/CBOR.md`, `bench/JSON.md`, `bench/MSGPACK.md`, `bench/TOML.md`, and `bench/YAML.md`
- benchmark timing is implemented with `zBench`; keep the scenario workloads and fairness policy stable unless you are intentionally changing benchmark behavior
- add benchmark log entries only for real benchmark-affecting changes, newest first, with sections named `## YYYY-MM-DD - <hash>`
- corpus roundtrip fixtures live in `tests/corpus/<format>` and should stay in canonical output form
- prefer feature-first corpus names such as `null.json`, `empty.toml`, `array_float.yaml`, `object_single.cbor`, `object_nested.bson`, `enum_field.msgpack`, and `object_single.bin`
- corpus tests are generated from `tests/corpus/bin`, `tests/corpus/bson`, `tests/corpus/cbor`, `tests/corpus/json`, `tests/corpus/msgpack`, `tests/corpus/toml`, and `tests/corpus/yaml`
- keep `README.md`, `bench/README.md`, and `CONTRIBUTING.md` aligned with the current workflow
- keep this file updated when repo conventions change
