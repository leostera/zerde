const std = @import("std");
const mem = std.mem;

pub fn NonOptional(comptime T: type) type {
    const type_info = @typeInfo(T);
    if (type_info == .optional) {
        return type_info.optional.child;
    }
    return T;
}

/// A struct or union field, rebuilt from the parallel arrays of `@typeInfo` (Zig 0.17).
pub const Field = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque = null,

    pub inline fn defaultValue(comptime field: Field) ?field.type {
        const dp: *const field.type = @ptrCast(@alignCast(field.default_value_ptr orelse return null));
        return dp.*;
    }
};

pub fn structFields(comptime T: type) []const Field {
    const info = @typeInfo(T).@"struct";
    comptime var fields: [info.field_names.len]Field = undefined;
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, field_type, attrs, i| {
        fields[i] = .{ .name = name, .type = field_type, .default_value_ptr = attrs.default_value_ptr };
    }
    const result = fields;
    return &result;
}

pub fn unionFields(comptime T: type) []const Field {
    const info = @typeInfo(T).@"union";
    comptime var fields: [info.field_names.len]Field = undefined;
    inline for (info.field_names, info.field_types, 0..) |name, field_type, i| {
        fields[i] = .{ .name = name, .type = field_type };
    }
    const result = fields;
    return &result;
}

pub fn Optional(comptime T: type, comptime is_optional: bool) type {
    return if (is_optional) ?T else T;
}

pub inline fn isOptional(comptime T: type) bool {
    return @typeInfo(T) == .optional;
}

test isOptional {
    try std.testing.expect(isOptional(?u32));
    try std.testing.expect(!isOptional(u32));
}

var no_allocator_dummy: u8 = 0;

pub const NoAllocator = struct {
    pub fn noAlloc(ctx: *anyopaque, len: usize, ptr_align: mem.Alignment, ret_addr: usize) ?[*]u8 {
        _ = ctx;
        _ = len;
        _ = ptr_align;
        _ = ret_addr;
        return null;
    }

    pub fn allocator() std.mem.Allocator {
        return .{
            .ptr = &no_allocator_dummy,
            .vtable = &.{
                .alloc = noAlloc,
                .resize = std.mem.Allocator.noResize,
                .free = std.mem.Allocator.noFree,
                .remap = std.mem.Allocator.noRemap,
            },
        };
    }
};
