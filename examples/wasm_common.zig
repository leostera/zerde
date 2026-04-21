const std = @import("std");
const zerde = @import("zerde");

pub const allocator = std.heap.wasm_allocator;

var output: ?zerde.wasm.OwnedBuffer = null;

pub fn allocInput(len: usize) usize {
    const bytes = allocator.alloc(u8, len) catch return 0;
    return @intFromPtr(bytes.ptr);
}

pub fn freeInput(ptr: usize, len: usize) void {
    if (ptr == 0) return;
    const raw: [*]u8 = @ptrFromInt(ptr);
    allocator.free(raw[0..len]);
}

pub fn replaceOutput(buffer: zerde.wasm.OwnedBuffer) void {
    clearOutput();
    output = buffer;
}

pub fn clearOutput() void {
    if (output) |*buffer| {
        buffer.deinit();
    }
    output = null;
}

pub fn outputPtr() usize {
    if (output) |*buffer| return @intFromPtr(buffer.bytes().ptr);
    return 0;
}

pub fn outputLen() usize {
    if (output) |*buffer| return buffer.bytes().len;
    return 0;
}
