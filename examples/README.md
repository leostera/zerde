# Examples

This folder contains both native Zig examples and browser-oriented wasm
examples.

The native examples show the core typed API across the supported formats.
The wasm examples show how to move typed data across a JS boundary or parse
foreign payloads inside the module.

Build them all with:

```sh
zig build examples
```

That produces native executables and `.wasm` artifacts in `zig-out/bin/`.

Native examples in this folder:

- `json_roundtrip.zig`: serialize a Zig struct to JSON and parse it back
- `toml_roundtrip.zig`: serialize a Zig struct to TOML and parse it back
- `yaml_roundtrip.zig`: serialize a Zig struct to YAML and parse it back
- `cbor_roundtrip.zig`: serialize a Zig struct to CBOR and parse it back
- `bson_roundtrip.zig`: serialize a Zig struct to BSON and parse it back
- `msgpack_roundtrip.zig`: serialize a Zig struct to MessagePack and parse it back
- `bin_roundtrip.zig`: serialize a Zig struct to `zerde`'s compact binary format and parse it back

WASM examples in this folder export the same host-facing helpers:

- `alloc_input(len)` to reserve wasm memory for incoming bytes
- `free_input(ptr, len)` to release that input buffer
- `output_ptr()` and `output_len()` to expose the last successful output buffer
- `release_output()` to free that output buffer

Examples in this folder:

- `wasm_bin_bridge.zig`: serialize a Zig struct for JS and read compact binary back into wasm
- `wasm_json_bridge.zig`: parse JSON inside wasm and reserialize it to canonical JSON
- `wasm_yaml_bridge.zig`: parse YAML inside wasm and reserialize it to JSON
- `wasm_msgpack_bridge.zig`: parse MessagePack inside wasm and reserialize it to JSON
