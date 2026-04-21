//! Format-independent typed walk.
//!
//! This layer reflects on `T` with `@typeInfo` and drives a format backend
//! through a small serializer/deserializer protocol. The backend knows how to
//! emit or read one concrete format; this file knows how to walk arbitrary Zig
//! data structures.

const std = @import("std");
const Allocator = std.mem.Allocator;
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
    bytes,
    array,
    object,
};

/// Numeric token returned by format backends before the typed layer casts it to `T`.
pub const Number = union(enum) {
    integer: i128,
    float: f64,
};

/// String token that may either borrow input bytes or own a freshly allocated buffer.
pub const StringToken = struct {
    bytes: []const u8,
    allocated: bool,

    pub fn deinit(self: StringToken, allocator: Allocator) void {
        if (self.allocated) allocator.free(@constCast(self.bytes));
    }
};

/// Frees values produced by the owning parse paths.
/// Aliased slice parses should instead be released by dropping the input and allocator scope together.
pub fn free(allocator: Allocator, value: anytype) void {
    freeTyped(@TypeOf(value), allocator, value);
}

/// Entry point used by `root.zig` once a format module has been selected.
pub fn serialize(comptime Format: type, writer: *std.Io.Writer, value: anytype, comptime serde_cfg: anytype, comptime format_cfg: anytype) !void {
    var serializer = Format.serializer(writer, format_cfg);
    defer if (@hasDecl(@TypeOf(serializer), "deinit")) serializer.deinit();
    try serializeValue(&serializer, value, serde_cfg);
}

/// Entry point used by `root.zig` once a format-specific deserializer has been created.
pub fn deserialize(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    return deserializeValue(T, allocator, deserializer, cfg);
}

fn serializeValue(serializer: anytype, value: anytype, comptime cfg: anytype) !void {
    const T = @TypeOf(value);
    const SerializerType = @TypeOf(serializer.*);
    switch (@typeInfo(T)) {
        .bool => try serializer.emitBool(value),
        .int, .comptime_int => try serializer.emitInteger(value),
        .float, .comptime_float => try serializer.emitFloat(value),
        .optional => {
            if (value) |child| {
                try serializeValue(serializer, child, cfg);
            } else {
                try serializer.emitNull();
            }
        },
        .@"enum" => {
            if (@hasDecl(SerializerType, "emitEnum")) {
                try serializer.emitEnum(T, value);
            } else {
                try serializer.emitString(@tagName(value));
            }
        },
        .array => |info| {
            if (info.child == u8) {
                if (@hasDecl(SerializerType, "emitBytes")) {
                    try serializer.emitBytes(value[0..]);
                } else {
                    try serializer.emitString(value[0..]);
                }
                return;
            }

            if (@hasDecl(SerializerType, "serializeSequence")) {
                if (try serializer.serializeSequence(T, value, cfg)) return;
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

                if (@hasDecl(SerializerType, "serializeSequence")) {
                    if (try serializer.serializeSequence(T, value, cfg)) return;
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

            // TOML uses two passes so scalars appear before nested tables; JSON stays at one pass.
            const pass_count = comptime SerializerType.structPassCount(T);
            if (@hasDecl(SerializerType, "beginStructSized")) {
                var field_count: usize = 0;
                inline for (0..pass_count) |pass| {
                    inline for (info.fields) |field| {
                        if (field.is_comptime) {
                            @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                        }

                        if (SerializerType.includeStructField(T, field.type, pass)) {
                            const field_value = @field(value, field.name);
                            const skip_field = meta.effectiveOmitNullFields(T, cfg) and @typeInfo(field.type) == .optional and field_value == null;
                            if (!skip_field) field_count += 1;
                        }
                    }
                }
                try serializer.beginStructSized(T, field_count);
            } else {
                try serializer.beginStruct(T);
            }
            inline for (0..pass_count) |pass| {
                inline for (info.fields) |field| {
                    if (field.is_comptime) {
                        @compileError("comptime struct fields are not supported: " ++ @typeName(T) ++ "." ++ field.name);
                    }

                    if (SerializerType.includeStructField(T, field.type, pass)) {
                        const field_value = @field(value, field.name);
                        // Null omission is decided by the typed layer so formats do not duplicate that policy.
                        const skip_field = meta.effectiveOmitNullFields(T, cfg) and @typeInfo(field.type) == .optional and field_value == null;
                        if (!skip_field) {
                            const emitted_name = comptime meta.effectiveFieldName(T, field.name, cfg);
                            const emit_value = if (@hasDecl(SerializerType, "beginStructFieldValue"))
                                try serializer.beginStructFieldValue(T, emitted_name, field.type, field_value)
                            else
                                try serializer.beginStructField(T, emitted_name, field.type);
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

fn deserializeValue(comptime T: type, allocator: Allocator, deserializer: anytype, comptime cfg: anytype) anyerror!T {
    return switch (@typeInfo(T)) {
        .bool => try deserializer.readBool(),
        // Formats parse numbers once into a common token; the typed layer is responsible for exact casts.
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

fn decodeFloatNumber(comptime T: type, number: Number) Error!T {
    return switch (number) {
        .integer => |n| @as(T, @floatFromInt(n)),
        .float => |n| @as(T, @floatCast(n)),
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

fn deserializeArray(
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    allocator: Allocator,
    deserializer: anytype,
    comptime cfg: anytype,
) anyerror!T {
    if (info.child == u8) {
        // Byte arrays may come from either a format-native bytes token or a plain string token.
        const token = try readByteToken(allocator, deserializer);
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
                const DeserializerType = @TypeOf(deserializer.*);
                // Aliased slice parses can hand byte and string fields straight back to the caller without copying.
                if (@hasDecl(DeserializerType, "borrowStrings") and deserializer.borrowStrings()) {
                    return token.bytes;
                }
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

fn readByteToken(allocator: Allocator, deserializer: anytype) anyerror!StringToken {
    const DeserializerType = @TypeOf(deserializer.*);
    if (@hasDecl(DeserializerType, "readBytes")) {
        return switch (try deserializer.peekKind()) {
            .bytes => try deserializer.readBytes(allocator),
            .string => try deserializer.readString(allocator),
            else => error.UnexpectedType,
        };
    }
    return try deserializer.readString(allocator);
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

        // This is the generic field matcher: reflect over the struct and compare against
        // the effective wire name after rename rules have been applied.
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
            // Unknown-field policy also lives at the typed layer so every format behaves the same way.
            if (meta.effectiveDenyUnknownFields(T, cfg)) return error.UnknownField;
            try deserializer.skipValue(allocator);
        }
    }

    // Missing-field defaults are resolved after the object is fully consumed.
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
