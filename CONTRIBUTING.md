# Contributing

## Prerequisites

- Zig `0.16.0`
- Git

## Initial Setup

Clone the repository and enable the repo-local hooks path:

```sh
git config core.hooksPath .githooks
```

The pre-commit hook runs `zig fmt` on staged `.zig` files and re-stages them before the commit is created.

## Development Workflow

Run the test suite:

```sh
zig build test
```

Compile the wasm examples:

```sh
zig build examples
```

Build the transcoder CLI:

```sh
zig build transcode
```

The examples in `examples/` cover both the native typed API across formats and
the `zerde.wasm` browser-style pointer+length interop path.

Run all benchmarks:

```sh
zig build bench -Doptimize=ReleaseFast
```

Run a single benchmark family:

```sh
zig build bench-bin -Doptimize=ReleaseFast
zig build bench-bson -Doptimize=ReleaseFast
zig build bench-msgpack -Doptimize=ReleaseFast
zig build bench-json -Doptimize=ReleaseFast
zig build bench-zon -Doptimize=ReleaseFast
zig build bench-toml -Doptimize=ReleaseFast
zig build bench-cbor -Doptimize=ReleaseFast
zig build bench-yaml -Doptimize=ReleaseFast
zig build bench-wasm -Doptimize=ReleaseFast
```

Benchmark workflow and benchmark-log conventions live in [bench/README.md](bench/README.md).
That file also defines benchmark fairness policy: time the full public usage path, including any mandatory intermediate-representation conversion required by a compared library.
The benchmark runner itself is built on `zBench`.
GitHub Actions mirrors this setup with `.github/workflows/ci.yml` for `zig build test`
plus native library, wasm library, transcoder, example, and benchmark-harness builds, and
`.github/workflows/bench.yml` for full per-format benchmark runs on `main` and
manual dispatches.
Tagged commits on `main` are published through `.github/workflows/release.yml`.

## Parse Diagnostics

Use `zerde.parseSliceWithDiagnostics(...)` or
`zerde.deserializeWithDiagnostics(...)` when you need error context that points
at a specific field path and input location.

## Corpus Tests

Corpus-based roundtrip tests live in `tests/corpus/bin`, `tests/corpus/bson`, `tests/corpus/cbor`, `tests/corpus/json`, `tests/corpus/msgpack`, `tests/corpus/toml`, `tests/corpus/yaml`, and `tests/corpus/zon`.
Each fixture is treated as a canonical source file: parse it into a typed value, serialize it back out, and require an exact byte-for-byte match.
The corpora are feature-first, so fixture names should describe the wire shape being exercised rather than one shared app schema.

When adding fixtures:

- add the source file under `tests/corpus/<format>/`
- prefer feature names like `null.json`, `empty.toml`, `array_float.yaml`, `object_single.cbor`, `object_nested.bson`, `enum_field.msgpack`, `object_single.zon`, or `object_single.bin`
- keep the file in `zerde`'s canonical output form for that format and config
- use descriptive names so a failing generated test is easy to identify
- run `zig build test` after adding or changing corpus fixtures

## Commit Style

Use conventional commits.

Examples:

- `feat(toml): add typed TOML deserializer`
- `fix(json): avoid widening integers in the writer`
- `docs(bench): record JSON benchmark run`

## Before Opening a Change

- make sure `zig build test` passes
- run the relevant benchmark if you changed benchmarked code
- update the relevant docs when workflow or capabilities change
- keep corpus fixtures and corpus support code aligned when adding new roundtrip suites
- keep `AGENTS.md` current when repo conventions or contributor workflow change

## Releases

Cut releases from `main` with an annotated tag:

```sh
git tag -a 0.1.0 -m "0.1.0"
git push origin main --follow-tags
```

The release workflow only publishes tags whose commit is reachable from `main`.
