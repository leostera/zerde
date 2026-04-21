# WASM Examples

This folder contains small browser-oriented wasm examples that use `zerde.wasm`
to move typed data across a JS boundary or parse foreign payloads inside the
module.

Build them all with:

```sh
zig build examples
```

That produces `.wasm` artifacts in `zig-out/bin/`.

Each example exports the same host-facing helpers:

- `alloc_input(len)` to reserve wasm memory for incoming bytes
- `free_input(ptr, len)` to release that input buffer
- `output_ptr()` and `output_len()` to expose the last successful output buffer
- `release_output()` to free that output buffer

Examples in this folder:

- `wasm_bin_bridge.zig`: serialize a Zig struct for JS and read compact binary back into wasm
- `wasm_json_bridge.zig`: parse JSON inside wasm and reserialize it to canonical JSON
- `wasm_yaml_bridge.zig`: parse YAML inside wasm and reserialize it to JSON
- `wasm_msgpack_bridge.zig`: parse MessagePack inside wasm and reserialize it to JSON
