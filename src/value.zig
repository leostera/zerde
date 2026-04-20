const std = @import("std");
const Allocator = std.mem.Allocator;

pub const ObjectField = struct {
    key: []u8,
    value: Value,
};

pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i128,
    float: f64,
    string: []u8,
    array: []Value,
    object: []ObjectField,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .string => |bytes| allocator.free(bytes),
            .array => |items| {
                for (items) |*item| item.deinit(allocator);
                allocator.free(items);
            },
            .object => |fields| {
                for (fields) |*field| {
                    allocator.free(field.key);
                    field.value.deinit(allocator);
                }
                allocator.free(fields);
            },
            else => {},
        }

        self.* = .null;
    }
};
