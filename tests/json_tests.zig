//! JSON corpus entrypoint.
//!
//! `build.zig` scans `tests/corpus/json` and generates one test per fixture.

test {
    _ = @import("json_corpus_generated");
}
