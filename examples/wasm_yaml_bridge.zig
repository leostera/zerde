const zerde = @import("zerde");
const common = @import("wasm_common.zig");

const ServiceConfig = struct {
    serviceName: []const u8,
    port: u16,
    debug: bool,

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

pub export fn yaml_to_json(input_ptr: usize, input_len: usize) bool {
    if (input_ptr == 0) return false;
    const config = zerde.wasm.parseFormatWith(zerde.yaml, ServiceConfig, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{
        .rename_all = .snake_case,
    }, .{}) catch return false;
    defer zerde.free(common.allocator, config);

    const buffer = zerde.wasm.serializeFormatOwnedWith(zerde.json, common.allocator, config, .{
        .rename_all = .snake_case,
    }, .{}) catch return false;
    common.replaceOutput(buffer);
    return true;
}

pub export fn service_port_from_yaml(input_ptr: usize, input_len: usize) u16 {
    if (input_ptr == 0) return 0;
    const config = zerde.wasm.parseFormatWith(zerde.yaml, ServiceConfig, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{
        .rename_all = .snake_case,
    }, .{}) catch return 0;
    defer zerde.free(common.allocator, config);
    return config.port;
}
