const zerde = @import("zerde");
const common = @import("wasm_common.zig");

const EventEnvelope = struct {
    route: []const u8,
    ok: bool,
    code: i32,
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

pub export fn msgpack_to_json(input_ptr: usize, input_len: usize) bool {
    if (input_ptr == 0) return false;
    const event = zerde.wasm.parseFormatWith(zerde.msgpack, EventEnvelope, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{}, .{}) catch return false;
    defer zerde.free(common.allocator, event);

    const buffer = zerde.wasm.serializeFormatOwned(zerde.json, common.allocator, event) catch return false;
    common.replaceOutput(buffer);
    return true;
}

pub export fn event_ok_from_msgpack(input_ptr: usize, input_len: usize) bool {
    if (input_ptr == 0) return false;
    const event = zerde.wasm.parseFormatWith(zerde.msgpack, EventEnvelope, common.allocator, .{
        .ptr = input_ptr,
        .len = input_len,
    }, .{}, .{}) catch return false;
    defer zerde.free(common.allocator, event);
    return event.ok;
}
