const zerde = @import("zerde");
const common = @import("wasm_common.zig");

const CrewManifest = struct {
    captainName: []const u8,
    bounty: u32,
    shipwright: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub export fn alloc_input(len: usize) usize {
    return common.allocInput(len);
}

pub export fn free_input(ptr: usize, len: usize) void {
    common.freeInput(ptr, len);
}

pub export fn release_output() void {
    common.clearOutput();
}

pub export fn output_ptr() usize {
    return common.outputPtr();
}

pub export fn output_len() usize {
    return common.outputLen();
}

pub export fn normalize_crew_json(input_ptr: usize, input_len: usize) bool {
    if (input_ptr == 0) return false;
    const ptr: [*]const u8 = @ptrFromInt(input_ptr);
    const manifest = zerde.wasm.parseFormatWith(zerde.json, CrewManifest, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{
        .rename_all = .snake_case,
    }, .{}) catch return false;
    defer zerde.free(common.allocator, manifest);

    const buffer = zerde.wasm.serializeFormatOwnedWith(zerde.json, common.allocator, manifest, .{
        .rename_all = .snake_case,
    }, .{}) catch return false;
    _ = ptr;
    common.replaceOutput(buffer);
    return true;
}

pub export fn crew_bounty_from_json(input_ptr: usize, input_len: usize) u32 {
    if (input_ptr == 0) return 0;
    const manifest = zerde.wasm.parseFormatWith(zerde.json, CrewManifest, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{
        .rename_all = .snake_case,
    }, .{}) catch return 0;
    defer zerde.free(common.allocator, manifest);
    return manifest.bounty;
}
