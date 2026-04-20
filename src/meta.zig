const std = @import("std");

pub const FieldCase = enum {
    unchanged,
    snake_case,
    camelCase,
    PascalCase,
    kebab_case,
};

pub const SerdeConfig = struct {
    rename_all: FieldCase = .unchanged,
    omit_null_fields: bool = false,
    deny_unknown_fields: bool = false,
};

pub const JsonConfig = SerdeConfig;

pub fn hasField(comptime T: type, comptime name: []const u8) bool {
    return switch (@typeInfo(T)) {
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (std.mem.eql(u8, field.name, name)) break :blk true;
            }
            break :blk false;
        },
        else => false,
    };
}

fn cfgHasField(comptime cfg: anytype, comptime name: []const u8) bool {
    return hasField(@TypeOf(cfg), name);
}

fn serdeHasField(comptime T: type, comptime name: []const u8) bool {
    return @hasDecl(T, "serde") and hasField(@TypeOf(T.serde), name);
}

fn fieldOverrideHasRenameFrom(comptime container: anytype, comptime field_name: []const u8) bool {
    if (!comptime cfgHasField(container, "fields")) return false;
    const fields = @field(container, "fields");
    if (!comptime hasField(@TypeOf(fields), field_name)) return false;
    const field_cfg = @field(fields, field_name);
    return comptime hasField(@TypeOf(field_cfg), "rename");
}

fn fieldOverrideRenameFrom(comptime container: anytype, comptime field_name: []const u8) []const u8 {
    const fields = @field(container, "fields");
    const field_cfg = @field(fields, field_name);
    return @field(field_cfg, "rename");
}

pub fn effectiveRenameAll(comptime T: type, comptime cfg: anytype) FieldCase {
    if (comptime serdeHasField(T, "rename_all")) return @field(T.serde, "rename_all");
    if (comptime cfgHasField(cfg, "rename_all")) return @field(cfg, "rename_all");
    return .unchanged;
}

pub fn effectiveOmitNullFields(comptime T: type, comptime cfg: anytype) bool {
    if (comptime cfgHasField(cfg, "omit_null_fields")) return @field(cfg, "omit_null_fields");
    if (comptime serdeHasField(T, "omit_null_fields")) return @field(T.serde, "omit_null_fields");
    return false;
}

pub fn effectiveDenyUnknownFields(comptime T: type, comptime cfg: anytype) bool {
    if (comptime cfgHasField(cfg, "deny_unknown_fields")) return @field(cfg, "deny_unknown_fields");
    if (comptime serdeHasField(T, "deny_unknown_fields")) return @field(T.serde, "deny_unknown_fields");
    return false;
}

pub fn effectiveFieldName(comptime T: type, comptime field_name: []const u8, comptime cfg: anytype) []const u8 {
    if (comptime fieldOverrideHasRenameFrom(cfg, field_name)) {
        return fieldOverrideRenameFrom(cfg, field_name);
    }

    if (comptime @hasDecl(T, "serde") and fieldOverrideHasRenameFrom(T.serde, field_name)) {
        return fieldOverrideRenameFrom(T.serde, field_name);
    }

    return applyCase(field_name, effectiveRenameAll(T, cfg));
}

pub fn applyCase(comptime name: []const u8, comptime style: FieldCase) []const u8 {
    if (style == .unchanged) return name;

    return comptime blk: {
        var buffer: [name.len * 2 + 1]u8 = undefined;
        var out_len: usize = 0;
        var word_index: usize = 0;
        var in_word = false;
        var i: usize = 0;

        while (i < name.len) : (i += 1) {
            const c = name[i];
            if (isSeparator(c)) {
                in_word = false;
                continue;
            }

            const boundary = isBoundary(name, i);
            if (boundary) {
                switch (style) {
                    .snake_case => {
                        buffer[out_len] = '_';
                        out_len += 1;
                    },
                    .kebab_case => {
                        buffer[out_len] = '-';
                        out_len += 1;
                    },
                    else => {},
                }
                in_word = false;
            }

            const normalized = switch (style) {
                .snake_case, .kebab_case => std.ascii.toLower(c),
                .camelCase => if (word_index == 0)
                    std.ascii.toLower(c)
                else if (!in_word)
                    std.ascii.toUpper(c)
                else
                    std.ascii.toLower(c),
                .PascalCase => if (!in_word)
                    std.ascii.toUpper(c)
                else
                    std.ascii.toLower(c),
                .unchanged => c,
            };

            buffer[out_len] = normalized;
            out_len += 1;

            if (!in_word) word_index += 1;
            in_word = true;
        }

        break :blk std.fmt.comptimePrint("{s}", .{buffer[0..out_len]});
    };
}

fn isSeparator(c: u8) bool {
    return c == '_' or c == '-' or c == ' ';
}

fn isBoundary(comptime name: []const u8, comptime i: usize) bool {
    if (i == 0) return false;

    const c = name[i];
    const prev = name[i - 1];

    if (isSeparator(prev)) return true;
    if (isSeparator(c)) return false;

    if (std.ascii.isUpper(c) and (std.ascii.isLower(prev) or std.ascii.isDigit(prev))) return true;

    if (std.ascii.isUpper(c) and std.ascii.isUpper(prev) and i + 1 < name.len and std.ascii.isLower(name[i + 1])) {
        return true;
    }

    return false;
}

test "case conversion" {
    try std.testing.expectEqualStrings("first_name", applyCase("firstName", .snake_case));
    try std.testing.expectEqualStrings("firstName", applyCase("first_name", .camelCase));
    try std.testing.expectEqualStrings("FirstName", applyCase("first_name", .PascalCase));
    try std.testing.expectEqualStrings("http_server", applyCase("HTTPServer", .snake_case));
    try std.testing.expectEqualStrings("http-server", applyCase("HTTPServer", .kebab_case));
}
