# Agents

Project conventions for automated changes:

- use conventional commits
- run `zig build test` after code changes
- when touching benchmarked code, run the relevant `zig build bench-* -Doptimize=ReleaseFast` command
- benchmark workflow lives in `bench/README.md`
- benchmark history lives in `bench/JSON.md`, `bench/TOML.md`, and `bench/CBOR.md`
- add benchmark log entries only for real benchmark-affecting changes, newest first, with sections named `## YYYY-MM-DD - <hash>`
- keep `README.md`, `bench/README.md`, and `CONTRIBUTING.md` aligned with the current workflow
- keep this file updated when repo conventions change
