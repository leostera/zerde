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

Run all benchmarks:

```sh
zig build bench -Doptimize=ReleaseFast
```

Run a single benchmark family:

```sh
zig build bench-json -Doptimize=ReleaseFast
zig build bench-toml -Doptimize=ReleaseFast
zig build bench-cbor -Doptimize=ReleaseFast
zig build bench-yaml -Doptimize=ReleaseFast
```

Benchmark workflow and benchmark-log conventions live in [bench/README.md](bench/README.md).
That file also defines benchmark fairness policy: time the full public usage path, including any mandatory intermediate-representation conversion required by a compared library.
The benchmark runner itself is built on `zBench`.

## Corpus Tests

Corpus-based roundtrip tests start in `tests/corpus/json`.
Each fixture is treated as a canonical source file: parse it into a typed value, serialize it back out, and require an exact byte-for-byte match.

When adding fixtures:

- add the source file under `tests/corpus/<format>/`
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
