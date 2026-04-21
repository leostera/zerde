const zerde = @import("zerde");
const common = @import("wasm_common.zig");

const CrewMate = struct {
    name: []const u8,
    bounty: u32,
    role: enum {
        captain,
        navigator,
        shipwright,
    },
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

pub export fn serialize_franky_bin() bool {
    const buffer = zerde.wasm.serializeOwned(common.allocator, CrewMate{
        .name = "Franky",
        .bounty = 394_000_000,
        .role = .shipwright,
    }) catch return false;

    common.replaceOutput(buffer);
    return true;
}

pub export fn is_shipwright_from_bin(input_ptr: usize, input_len: usize) bool {
    if (input_ptr == 0) return false;
    const ptr: [*]const u8 = @ptrFromInt(input_ptr);
    const crew = zerde.wasm.parsePartsAliased(CrewMate, common.allocator, ptr, input_len) catch return false;
    return crew.role == .shipwright;
}
