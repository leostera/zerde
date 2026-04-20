const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const meta = @import("meta.zig");

pub const Error = Allocator.Error || error{
    UnsupportedType,
    UnexpectedType,
    UnknownField,
    MissingField,
    DuplicateField,
    IntegerOverflow,
    InvalidEnumTag,
    LengthMismatch,
};

pub const ValueKind = enum {
    null,
    bool,
    number,
    string,
    array,
    object,
};

pub const Number = union(enum) {
    integer: i128,
    float: f64,
};

pub const StringToken = struct {
    bytes: []const u8,
    allocated: bool,

    pub fn deinit(self: StringToken, allocator: Allocator) void {
        if (self.allocated) allocator.free(@constCast(self.bytes));
    }
};

pub fn free(allocator: Allocator, value: anytype) void {
    freeTyped(@TypeOf(value), allocator, value);
}

pub fn fromValue(comptime T: type, allocator: Allocator, value: Value, comptime cfg: anytype) Error!T {
    return switch (@typeInfo(T)) {
        .bool => switch (value) {
            .bool => |b| b,
            else => error.UnexpectedType,
        },
        .int, .comptime_int => decodeInt(T, value),
        .float, .comptime_float => decodeFloat(T, value),
        .optional => |info| switch (value) {
            .null => null,
            else => try fromValue(info.child, allocator, value, cfg),
        },
        .@"enum" => decodeEnum(T, value),
        .array => |info| decodeArray(T, info, allocator, value, cfg),
        .pointer => |info| decodePointer(T, info, allocator, value, cfg),
        .@"struct" => |info| decodeStruct(T, info, allocator, value, cfg),
        else => error.UnsupportedType,
    };
}

pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var serializer = Format.serializer(writer, format_cfg);
    try serializeValue(&serializer, value, serde_cfg);
}

pub fn deserialize(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    return deserializeValue(T, allocator, deserializer, cfg);
}

fn serializeValue(serializer: anytype, value: anytype, comptime cfg: anytype) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => try serializer.emitBool(value),
        .int, .comptime_int => try serializer.emitInteger(try intToI128(T, value)),
        .float, .comptime_float => try serializer.emitFloat(asF64(T, value)),
        .optional => {
            if (value) |child| {
                try serializeValue(serializer, child, cfg);
            } else {
                try serializer.emitNull();
            }
        },
        .@"enum" => try serializer.emitString(@tagName(value)),
        .array => |info| {
            if (info.child == u8) {
                try serializer.emitString(value[0..]);
                return;
            }

            try serializer.beginArray(info.child, value.len);
            for (value, 0..) |item, index| {
                try serializer.beginArrayItem(info.child, index);
                try serializeValue(serializer, item, cfg);
                try serializer.endArrayItem(info.child, index);
            }
            try serializer.endArray(info.child, value.len);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    try serializer.emitString(value);
                    return;
                }

                try serializer.beginArray(info.child, value.len);
                for (value, 0..) |item, index| {
                    try serializer.beginArrayItem(info.child, index);
                    try serializeValue(serializer, item, cfg);
                    try serializer.endArrayItem(info.child, index);
                }
                try serializer.endArray(info.child, value.len);
            },
            .one => try serializeValue(serializer, value.*, cfg),
            else => @compileError("zerde cannot serialize pointer type " ++ @typeName(T)),
        },
        .@"struct" => |info| {
            if (info.is_tuple) @compileError("tuple structs are not supported: " ++ @typeName(T));

            const SerializerType = @TypeOf(serializer.*);
            const pass_count = comptime SerializerType.structPassCount(T);
            try serializer.beginStruct(T);
            inline for (0..pass_count) |pass| {
                inline for (info.fields) |field| {
                    if (field.is_comptime) {
                        @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                    }

                    if (SerializerType.includeStructField(T, field.type, pass)) {
                        const field_value = @field(value, field.name);
                        const skip_field = meta.effectiveOmitNullFields(T, cfg) and @typeInfo(field.type) == .optional and field_value == null;
                        if (!skip_field) {
                            const emitted_name = comptime meta.effectiveFieldName(T, field.name, cfg);
                            const emit_value = try serializer.beginStructField(T, emitted_name, field.type);
                            if (emit_value) {
                                try serializeValue(serializer, field_value, cfg);
                            }
                            try serializer.endStructField(T, emitted_name, field.type);
                        }
                    }
                }
            }
            try serializer.endStruct(T);
        },
        else => @compileError("zerde cannot serialize " ++ @typeName(T)),
    }
}

fn intToI128(comptime T: type, value: T) Error!i128 {
    return std.math.cast(i128, value) orelse error.IntegerOverflow;
}

fn asF64(comptime T: type, value: T) f64 {
    return switch (@typeInfo(T)) {
        .float => @as(f64, @floatCast(value)),
        .comptime_float => value,
        else => unreachable,
    };
}

fn deserializeValue(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    return switch (@typeInfo(T)) {
        .bool => try deserializer.readBool(),
        .int, .comptime_int => decodeIntNumber(T, try deserializer.readNumber()),
        .float, .comptime_float => decodeFloatNumber(T, try deserializer.readNumber()),
        .optional => |info| blk: {
            if (try deserializer.peekKind() == .null) {
                try deserializer.readNull();
                break :blk null;
            }
            break :blk try deserializeValue(info.child, allocator, deserializer, cfg);
        },
        .@"enum" => try decodeEnumValue(T, allocator, deserializer),
        .array => |info| try deserializeArray(T, info, allocator, deserializer, cfg),
        .pointer => |info| try deserializePointer(T, info, allocator, deserializer, cfg),
        .@"struct" => |info| try deserializeStruct(T, info, allocator, deserializer, cfg),
        else => error.UnsupportedType,
    };
}

fn decodeInt(comptime T: type, value: Value) Error!T {
    return switch (value) {
        .integer => |n| std.math.cast(T, n) orelse error.IntegerOverflow,
        .float => |n| blk: {
            const rounded = @round(n);
            if (rounded != n) break :blk error.UnexpectedType;
            break :blk std.math.cast(T, @as(i128, @intFromFloat(rounded))) orelse error.IntegerOverflow;
        },
        else => error.UnexpectedType,
    };
}

fn decodeIntNumber(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |n| std.math.cast(T, n) orelse error.IntegerOverflow,
        .float => |n| blk: {
            const rounded = @round(n);
            if (rounded != n) break :blk error.UnexpectedType;
            break :blk std.math.cast(T, @as(i128, @intFromFloat(rounded))) orelse error.IntegerOverflow;
        },
    };
}

fn decodeFloat(comptime T: type, value: Value) Error!T {
    return switch (value) {
        .integer => |n| @as(T, @floatFromInt(n)),
        .float => |n| @as(T, @floatCast(n)),
        else => error.UnexpectedType,
    };
}

fn decodeFloatNumber(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |n| @as(T, @floatFromInt(n)),
        .float => |n| @as(T, @floatCast(n)),
    };
}

fn decodeEnum(comptime T: type, value: Value) Error!T {
    return switch (value) {
        .string => |bytes| std.meta.stringToEnum(T, bytes) orelse error.InvalidEnumTag,
        .integer => |raw_tag| blk: {
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const cast_tag = std.math.cast(tag_type, raw_tag) orelse break :blk error.InvalidEnumTag;
            break :blk std.enums.fromInt(T, cast_tag) orelse error.InvalidEnumTag;
        },
        else => error.UnexpectedType,
    };
}

fn decodeEnumValue(comptime T: type, allocator: Allocator, deserializer: anytype) anyerror!T {
    return switch (try deserializer.peekKind()) {
        .string => blk: {
            const token = try deserializer.readString(allocator);
            defer token.deinit(allocator);
            break :blk std.meta.stringToEnum(T, token.bytes) orelse error.InvalidEnumTag;
        },
        .number => blk: {
            const raw_tag = switch (try deserializer.readNumber()) {
                .integer => |n| n,
                .float => return error.UnexpectedType,
            };
            const tag_type = @typeInfo(T).@"enum".tag_type;
            const cast_tag = std.math.cast(tag_type, raw_tag) orelse return error.InvalidEnumTag;
            break :blk std.enums.fromInt(T, cast_tag) orelse error.InvalidEnumTag;
        },
        else => error.UnexpectedType,
    };
}

fn decodeArray(
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    allocator: Allocator,
    value: Value,
    comptime cfg: anytype,
) Error!T {
    if (info.child == u8) {
        return switch (value) {
            .string => |bytes| blk: {
                if (bytes.len != info.len) break :blk error.LengthMismatch;
                var result: T = undefined;
                @memcpy(result[0..], bytes);
                break :blk result;
            },
            else => error.UnexpectedType,
        };
    }

    return switch (value) {
        .array => |items| blk: {
            if (items.len != info.len) break :blk error.LengthMismatch;
            var result: T = undefined;
            for (items, 0..) |item, i| {
                result[i] = try fromValue(info.child, allocator, item, cfg);
            }
            break :blk result;
        },
        else => error.UnexpectedType,
    };
}

fn deserializeArray(
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
) anyerror!T {
    if (info.child == u8) {
        const token = try deserializer.readString(allocator);
        defer token.deinit(allocator);

        if (token.bytes.len != info.len) return error.LengthMismatch;
        var result: T = undefined;
        @memcpy(result[0..], token.bytes);
        return result;
    }

    try deserializer.beginArray();
    var result: T = undefined;
    var index: usize = 0;

    while (try deserializer.nextArrayItem()) {
        if (index >= info.len) return error.LengthMismatch;
        result[index] = try deserializeValue(info.child, allocator, deserializer, cfg);
        index += 1;
    }

    if (index != info.len) return error.LengthMismatch;
    return result;
}

fn decodePointer(
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    allocator: Allocator,
    value: Value,
    comptime cfg: anytype,
) Error!T {
    switch (info.size) {
        .slice => {
            if (info.child == u8) {
                return switch (value) {
                    .string => |bytes| allocator.dupe(info.child, bytes),
                    else => error.UnexpectedType,
                };
            }

            return switch (value) {
                .array => |items| blk: {
                    const result = try allocator.alloc(info.child, items.len);
                    errdefer allocator.free(result);
                    for (items, 0..) |item, i| {
                        result[i] = try fromValue(info.child, allocator, item, cfg);
                    }
                    break :blk result;
                },
                else => error.UnexpectedType,
            };
        },
        .one => {
            const ptr = try allocator.create(info.child);
            errdefer allocator.destroy(ptr);
            ptr.* = try fromValue(info.child, allocator, value, cfg);
            return ptr;
        },
        else => return error.UnsupportedType,
    }
}

fn deserializePointer(
    comptime T: type,
    comptime info: std.builtin.Type.Pointer,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
) anyerror!T {
    switch (info.size) {
        .slice => {
            if (info.child == u8) {
                const token = try deserializer.readString(allocator);
                defer token.deinit(allocator);
                return allocator.dupe(info.child, token.bytes);
            }

            try deserializer.beginArray();
            var items: std.ArrayList(info.child) = .empty;
            errdefer {
                for (items.items) |item| freeTyped(info.child, allocator, item);
                items.deinit(allocator);
            }

            while (try deserializer.nextArrayItem()) {
                const item = try deserializeValue(info.child, allocator, deserializer, cfg);
                try items.append(allocator, item);
            }

            return items.toOwnedSlice(allocator);
        },
        .one => {
            const ptr = try allocator.create(info.child);
            errdefer allocator.destroy(ptr);
            ptr.* = try deserializeValue(info.child, allocator, deserializer, cfg);
            return ptr;
        },
        else => return error.UnsupportedType,
    }
}

fn decodeStruct(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    value: Value,
    comptime cfg: anytype,
) Error!T {
    if (info.is_tuple) return error.UnsupportedType;

    return switch (value) {
        .object => |fields| blk: {
            var result: T = undefined;
            var seen: [info.fields.len]bool = [_]bool{false} ** info.fields.len;
            errdefer freePartialStruct(T, allocator, &result, &seen);

            for (fields) |field| {
                var matched = false;

                inline for (info.fields, 0..) |struct_field, i| {
                    if (struct_field.is_comptime) {
                        @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ struct_field.name);
                    }

                    const expected_name = meta.effectiveFieldName(T, struct_field.name, cfg);
                    if (std.mem.eql(u8, field.key, expected_name)) {
                        if (seen[i]) return error.DuplicateField;
                        @field(result, struct_field.name) = try fromValue(struct_field.type, allocator, field.value, cfg);
                        seen[i] = true;
                        matched = true;
                        break;
                    }
                }

                if (!matched and meta.effectiveDenyUnknownFields(T, cfg)) {
                    return error.UnknownField;
                }
            }

            inline for (info.fields, 0..) |struct_field, i| {
                if (!seen[i]) {
                    if (struct_field.defaultValue()) |default_value| {
                        @field(result, struct_field.name) = default_value;
                    } else if (@typeInfo(struct_field.type) == .optional) {
                        @field(result, struct_field.name) = null;
                    } else {
                        return error.MissingField;
                    }
                }
            }

            break :blk result;
        },
        else => error.UnexpectedType,
    };
}

fn deserializeStruct(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
) anyerror!T {
    if (info.is_tuple) return error.UnsupportedType;

    try deserializer.beginObject();

    var result: T = undefined;
    var seen: [info.fields.len]bool = [_]bool{false} ** info.fields.len;
    errdefer freePartialStruct(T, allocator, &result, &seen);

    while (try deserializer.nextObjectField(allocator)) |field_name| {
        defer field_name.deinit(allocator);

        var matched = false;

        inline for (info.fields, 0..) |struct_field, i| {
            if (struct_field.is_comptime) {
                @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ struct_field.name);
            }

            const expected_name = meta.effectiveFieldName(T, struct_field.name, cfg);
            if (std.mem.eql(u8, field_name.bytes, expected_name)) {
                if (seen[i]) return error.DuplicateField;
                @field(result, struct_field.name) = try deserializeValue(struct_field.type, allocator, deserializer, cfg);
                seen[i] = true;
                matched = true;
                break;
            }
        }

        if (!matched) {
            if (meta.effectiveDenyUnknownFields(T, cfg)) return error.UnknownField;
            try deserializer.skipValue(allocator);
        }
    }

    inline for (info.fields, 0..) |struct_field, i| {
        if (!seen[i]) {
            if (struct_field.defaultValue()) |default_value| {
                @field(result, struct_field.name) = default_value;
            } else if (@typeInfo(struct_field.type) == .optional) {
                @field(result, struct_field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }

    return result;
}

fn freeTyped(comptime T: type, allocator: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => {},
        .optional => {
            if (value) |child| freeTyped(@TypeOf(child), allocator, child);
        },
        .array => |info| {
            if (info.child == u8) return;
            for (value) |item| freeTyped(info.child, allocator, item);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    allocator.free(value);
                } else {
                    for (value) |item| freeTyped(info.child, allocator, item);
                    allocator.free(value);
                }
            },
            .one => {
                freeTyped(info.child, allocator, value.*);
                allocator.destroy(value);
            },
            else => {},
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                if (!field.is_comptime) {
                    freeTyped(field.type, allocator, @field(value, field.name));
                }
            }
        },
        else => {},
    }
}

fn freePartialStruct(
    comptime T: type,
    allocator: Allocator,
    result: *T,
    seen: *[@typeInfo(T).@"struct".fields.len]bool,
) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (seen[i]) freeTyped(field.type, allocator, @field(result.*, field.name));
    }
}
