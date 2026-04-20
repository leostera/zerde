const std = @import("std");
const Allocator = std.mem.Allocator;
const Value = @import("value.zig").Value;
const ObjectField = @import("value.zig").ObjectField;
const typed = @import("typed.zig");
const meta = @import("meta.zig");
const Number = typed.Number;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const FieldCase = meta.FieldCase;
pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
};
pub const WriteConfig = struct {};
pub const ParseError = anyerror;

const ContainerKind = enum {
    object,
    array,
};

const Container = struct {
    kind: ContainerKind,
    first: bool,
};

pub fn serializer(writer: *std.Io.Writer, comptime cfg: anytype) JsonSerializer(@TypeOf(cfg)) {
    return JsonSerializer(@TypeOf(cfg)).init(writer, cfg);
}

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !JsonDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return JsonDeserializer(@TypeOf(cfg)).initOwned(input, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !JsonDeserializer(@TypeOf(cfg)) {
    _ = allocator;
    return JsonDeserializer(@TypeOf(cfg)).initBorrowed(input, cfg);
}

pub fn JsonSerializer(comptime Config: type) type {
    return struct {
        writer: *std.Io.Writer,
        cfg: Config,
        stack: [128]Container = undefined,
        stack_len: usize = 0,

        const Self = @This();

        fn init(writer: *std.Io.Writer, cfg: Config) Self {
            return .{
                .writer = writer,
                .cfg = cfg,
            };
        }

        pub fn emitNull(self: *Self) !void {
            _ = self.cfg;
            try self.writer.writeAll("null");
        }

        pub fn emitBool(self: *Self, value: bool) !void {
            if (value) {
                try self.writer.writeAll("true");
            } else {
                try self.writer.writeAll("false");
            }
        }

        pub fn emitInteger(self: *Self, value: anytype) !void {
            try self.writer.print("{}", .{value});
        }

        pub fn emitFloat(self: *Self, value: anytype) !void {
            try self.writer.print("{}", .{value});
        }

        pub fn emitString(self: *Self, value: []const u8) !void {
            try writeEscapedString(self.writer, value);
        }

        pub fn beginStruct(self: *Self, comptime T: type) !void {
            _ = T;
            try self.writer.writeByte('{');
            try self.push(.{ .kind = .object, .first = true });
        }

        pub fn structPassCount(comptime T: type) usize {
            _ = T;
            return 1;
        }

        pub fn includeStructField(comptime Parent: type, comptime FieldType: type, comptime pass: usize) bool {
            _ = Parent;
            _ = FieldType;
            _ = pass;
            return true;
        }

        pub fn beginStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !bool {
            _ = Parent;
            _ = FieldType;
            const container = self.current();
            if (container.kind != .object) return error.InvalidJsonState;
            if (!container.first) {
                try self.writer.writeByte(',');
            } else {
                container.first = false;
            }
            try writeEscapedString(self.writer, name);
            try self.writer.writeByte(':');
            return true;
        }

        pub fn endStructField(self: *Self, comptime Parent: type, comptime name: []const u8, comptime FieldType: type) !void {
            _ = self;
            _ = Parent;
            _ = name;
            _ = FieldType;
        }

        pub fn endStruct(self: *Self, comptime T: type) !void {
            _ = T;
            _ = self.pop();
            try self.writer.writeByte('}');
        }

        pub fn beginArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            try self.writer.writeByte('[');
            try self.push(.{ .kind = .array, .first = true });
        }

        pub fn beginArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = Child;
            _ = index;
            const container = self.current();
            if (container.kind != .array) return error.InvalidJsonState;
            if (!container.first) {
                try self.writer.writeByte(',');
            } else {
                container.first = false;
            }
        }

        pub fn endArrayItem(self: *Self, comptime Child: type, index: usize) !void {
            _ = self;
            _ = Child;
            _ = index;
        }

        pub fn endArray(self: *Self, comptime Child: type, len: usize) !void {
            _ = Child;
            _ = len;
            _ = self.pop();
            try self.writer.writeByte(']');
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.JsonNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }
    };
}

pub fn JsonDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        parser: Parser,
        owns_input: bool,
        stack: [128]Container = undefined,
        stack_len: usize = 0,

        const Self = @This();

        fn initBorrowed(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .parser = .{ .input = input },
                .owns_input = false,
            };
        }

        fn initOwned(input: []const u8, cfg: Config) Self {
            return .{
                .input = input,
                .cfg = cfg,
                .parser = .{ .input = input },
                .owns_input = true,
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
            self.parser.skipWhitespace();
            if (!self.parser.eof()) return error.TrailingCharacters;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            self.parser.skipWhitespace();
            return switch (self.parser.peek() orelse return error.UnexpectedEndOfInput) {
                'n' => .null,
                't', 'f' => .bool,
                '-', '0'...'9' => .number,
                '"' => .string,
                '[' => .array,
                '{' => .object,
                else => error.UnexpectedToken,
            };
        }

        pub fn readNull(self: *Self) !void {
            self.parser.skipWhitespace();
            try self.parser.consumeLiteral("null");
        }

        pub fn readBool(self: *Self) !bool {
            self.parser.skipWhitespace();
            return switch (self.parser.peek() orelse return error.UnexpectedEndOfInput) {
                't' => blk: {
                    try self.parser.consumeLiteral("true");
                    break :blk true;
                },
                'f' => blk: {
                    try self.parser.consumeLiteral("false");
                    break :blk false;
                },
                else => error.UnexpectedToken,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            self.parser.skipWhitespace();
            return self.parser.parseNumberToken();
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            self.parser.skipWhitespace();
            return self.parser.parseStringToken(allocator);
        }

        pub fn beginArray(self: *Self) !void {
            self.parser.skipWhitespace();
            if (self.parser.consume() != '[') return error.UnexpectedToken;
            try self.push(.{ .kind = .array, .first = true });
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = self.current();
            if (frame.kind != .array) return error.InvalidJsonState;

            self.parser.skipWhitespace();
            if (frame.first) {
                if (self.parser.peek() == ']') {
                    _ = self.parser.consume();
                    _ = self.pop();
                    return false;
                }
                frame.first = false;
                return true;
            }

            const next = self.parser.consume() orelse return error.UnexpectedEndOfInput;
            switch (next) {
                ',' => {
                    self.parser.skipWhitespace();
                    return true;
                },
                ']' => {
                    _ = self.pop();
                    return false;
                },
                else => return error.UnexpectedToken,
            }
        }

        pub fn beginObject(self: *Self) !void {
            self.parser.skipWhitespace();
            if (self.parser.consume() != '{') return error.UnexpectedToken;
            try self.push(.{ .kind = .object, .first = true });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            const frame = self.current();
            if (frame.kind != .object) return error.InvalidJsonState;

            self.parser.skipWhitespace();
            if (frame.first) {
                if (self.parser.peek() == '}') {
                    _ = self.parser.consume();
                    _ = self.pop();
                    return null;
                }
                frame.first = false;
            } else {
                const next = self.parser.consume() orelse return error.UnexpectedEndOfInput;
                switch (next) {
                    ',' => self.parser.skipWhitespace(),
                    '}' => {
                        _ = self.pop();
                        return null;
                    },
                    else => return error.UnexpectedToken,
                }
            }

            if (self.parser.peek() != '"') return error.UnexpectedToken;
            const key = try self.parser.parseStringToken(allocator);
            errdefer key.deinit(allocator);

            self.parser.skipWhitespace();
            if (self.parser.consume() != ':') return error.UnexpectedToken;
            return key;
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            switch (try self.peekKind()) {
                .null => try self.readNull(),
                .bool => _ = try self.readBool(),
                .number => _ = try self.readNumber(),
                .string => {
                    const token = try self.readString(allocator);
                    token.deinit(allocator);
                },
                .array => {
                    try self.beginArray();
                    while (try self.nextArrayItem()) {
                        try self.skipValue(allocator);
                    }
                },
                .object => {
                    try self.beginObject();
                    while (try self.nextObjectField(allocator)) |field_name| {
                        field_name.deinit(allocator);
                        try self.skipValue(allocator);
                    }
                },
            }
        }

        fn push(self: *Self, container: Container) !void {
            if (self.stack_len == self.stack.len) return error.JsonNestingTooDeep;
            self.stack[self.stack_len] = container;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Container {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn current(self: *Self) *Container {
            return &self.stack[self.stack_len - 1];
        }
    };
}

pub fn serialize(writer: *std.Io.Writer, value: anytype) !void {
    try serializeWith(writer, value, .{}, .{});
}

pub fn serializeWith(
    writer: *std.Io.Writer,
    value: anytype,
    comptime serde_cfg: anytype,
    comptime format_cfg: anytype,
) !void {
    try typed.serialize(@This(), writer, value, serde_cfg, format_cfg);
}

pub fn deserialize(comptime T: type, allocator: Allocator, reader: *std.Io.Reader) ParseError!T {
    return deserializeWith(T, allocator, reader, .{}, .{});
}

pub fn deserializeWith(
    comptime T: type,
    allocator: Allocator,
    reader: *std.Io.Reader,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try readerDeserializer(allocator, reader, read_cfg);
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn parseSlice(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, read_cfg);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn readValue(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !Value {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    defer allocator.free(input);
    return parseValue(allocator, input, cfg);
}

pub fn parseValue(allocator: Allocator, input: []const u8, comptime cfg: anytype) Parser.Error!Value {
    _ = cfg;
    var parser = Parser{ .input = input };
    return parser.parse(allocator);
}

pub fn writeValue(writer: *std.Io.Writer, value: Value, comptime cfg: anytype) !void {
    _ = cfg;
    switch (value) {
        .null => try writer.writeAll("null"),
        .bool => |b| if (b) {
            try writer.writeAll("true");
        } else {
            try writer.writeAll("false");
        },
        .integer => |n| try writer.print("{d}", .{n}),
        .float => |n| try writer.print("{d}", .{n}),
        .string => |bytes| try writeEscapedString(writer, bytes),
        .array => |items| {
            try writer.writeByte('[');
            for (items, 0..) |item, index| {
                if (index != 0) try writer.writeByte(',');
                try writeValue(writer, item, .{});
            }
            try writer.writeByte(']');
        },
        .object => |fields| {
            try writer.writeByte('{');
            for (fields, 0..) |field, index| {
                if (index != 0) try writer.writeByte(',');
                try writeEscapedString(writer, field.key);
                try writer.writeByte(':');
                try writeValue(writer, field.value, .{});
            }
            try writer.writeByte('}');
        },
    }
}

pub fn writeEscapedString(writer: *std.Io.Writer, bytes: []const u8) !void {
    try std.json.Stringify.encodeJsonString(bytes, .{}, writer);
}

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return 16 * 1024 * 1024;
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    pub const Error = Allocator.Error || error{
        UnexpectedEndOfInput,
        UnexpectedToken,
        TrailingCharacters,
        InvalidNumber,
        InvalidStringEscape,
        InvalidUnicodeEscape,
        InvalidUnicodeSurrogate,
        InvalidStringCharacter,
    };

    fn parse(self: *Parser, allocator: Allocator) Error!Value {
        const value = try self.parseValueInner(allocator);
        self.skipWhitespace();
        if (!self.eof()) return error.TrailingCharacters;
        return value;
    }

    fn parseValueInner(self: *Parser, allocator: Allocator) Error!Value {
        self.skipWhitespace();
        const c = self.peek() orelse return error.UnexpectedEndOfInput;
        return switch (c) {
            'n' => blk: {
                try self.consumeLiteral("null");
                break :blk .null;
            },
            't' => blk: {
                try self.consumeLiteral("true");
                break :blk .{ .bool = true };
            },
            'f' => blk: {
                try self.consumeLiteral("false");
                break :blk .{ .bool = false };
            },
            '"' => .{ .string = try self.parseString(allocator) },
            '[' => try self.parseArray(allocator),
            '{' => try self.parseObject(allocator),
            '-', '0'...'9' => blk: {
                break :blk switch (try self.parseNumberToken()) {
                    .integer => |n| .{ .integer = n },
                    .float => |n| .{ .float = n },
                };
            },
            else => error.UnexpectedToken,
        };
    }

    fn parseArray(self: *Parser, allocator: Allocator) Error!Value {
        _ = self.consume();
        self.skipWhitespace();

        var items: std.ArrayList(Value) = .empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }

        if (self.peek() == ']') {
            _ = self.consume();
            return .{ .array = try items.toOwnedSlice(allocator) };
        }

        while (true) {
            const value = try self.parseValueInner(allocator);
            try items.append(allocator, value);
            self.skipWhitespace();

            const next = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (next) {
                ',' => self.skipWhitespace(),
                ']' => break,
                else => return error.UnexpectedToken,
            }
        }

        return .{ .array = try items.toOwnedSlice(allocator) };
    }

    fn parseObject(self: *Parser, allocator: Allocator) Error!Value {
        _ = self.consume();
        self.skipWhitespace();

        var fields: std.ArrayList(ObjectField) = .empty;
        errdefer {
            for (fields.items) |*field| {
                allocator.free(field.key);
                field.value.deinit(allocator);
            }
            fields.deinit(allocator);
        }

        if (self.peek() == '}') {
            _ = self.consume();
            return .{ .object = try fields.toOwnedSlice(allocator) };
        }

        while (true) {
            if (self.peek() != '"') return error.UnexpectedToken;
            const key = try self.parseString(allocator);
            errdefer allocator.free(key);

            self.skipWhitespace();
            if (self.consume() != ':') return error.UnexpectedToken;

            const value = try self.parseValueInner(allocator);
            try fields.append(allocator, .{ .key = key, .value = value });
            self.skipWhitespace();

            const next = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (next) {
                ',' => self.skipWhitespace(),
                '}' => break,
                else => return error.UnexpectedToken,
            }
        }

        return .{ .object = try fields.toOwnedSlice(allocator) };
    }

    fn parseNumberToken(self: *Parser) Error!Number {
        const start = self.index;
        var is_float = false;

        if (self.peek() == '-') _ = self.consume();

        const first_digit = self.peek() orelse return error.UnexpectedEndOfInput;
        switch (first_digit) {
            '0' => _ = self.consume(),
            '1'...'9' => {
                _ = self.consume();
                while (self.peek()) |c| {
                    if (!std.ascii.isDigit(c)) break;
                    _ = self.consume();
                }
            },
            else => return error.InvalidNumber,
        }

        if (self.peek() == '.') {
            is_float = true;
            _ = self.consume();
            const first_fraction = self.peek() orelse return error.InvalidNumber;
            if (!std.ascii.isDigit(first_fraction)) return error.InvalidNumber;
            while (self.peek()) |c| {
                if (!std.ascii.isDigit(c)) break;
                _ = self.consume();
            }
        }

        if (self.peek()) |c| {
            if (c == 'e' or c == 'E') {
                is_float = true;
                _ = self.consume();
                if (self.peek()) |sign| {
                    if (sign == '+' or sign == '-') _ = self.consume();
                } else return error.InvalidNumber;

                const first_exp = self.peek() orelse return error.InvalidNumber;
                if (!std.ascii.isDigit(first_exp)) return error.InvalidNumber;
                while (self.peek()) |digit| {
                    if (!std.ascii.isDigit(digit)) break;
                    _ = self.consume();
                }
            }
        }

        const slice = self.input[start..self.index];
        if (is_float) {
            return .{ .float = std.fmt.parseFloat(f64, slice) catch return error.InvalidNumber };
        }
        return .{ .integer = std.fmt.parseInt(i128, slice, 10) catch return error.InvalidNumber };
    }

    fn parseString(self: *Parser, allocator: Allocator) Error![]u8 {
        const token = try self.parseStringToken(allocator);
        if (token.allocated) return @constCast(token.bytes);
        return allocator.dupe(u8, token.bytes);
    }

    fn parseStringToken(self: *Parser, allocator: Allocator) Error!StringToken {
        if (self.consume() != '"') return error.UnexpectedToken;

        const start = self.index;
        var builder: std.ArrayList(u8) = .empty;
        errdefer builder.deinit(allocator);

        while (true) {
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"' => {
                    if (builder.items.len == 0) {
                        return .{
                            .bytes = self.input[start .. self.index - 1],
                            .allocated = false,
                        };
                    }

                    try builder.appendSlice(allocator, self.input[start .. self.index - 1]);
                    return .{
                        .bytes = try builder.toOwnedSlice(allocator),
                        .allocated = true,
                    };
                },
                '\\' => {
                    try builder.appendSlice(allocator, self.input[start .. self.index - 1]);
                    try self.appendEscape(allocator, &builder);
                    return self.finishEscapedString(allocator, builder);
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    fn finishEscapedString(self: *Parser, allocator: Allocator, initial_builder: std.ArrayList(u8)) Error!StringToken {
        var builder = initial_builder;
        errdefer builder.deinit(allocator);

        var chunk_start = self.index;
        while (true) {
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (c) {
                '"' => {
                    try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);
                    return .{
                        .bytes = try builder.toOwnedSlice(allocator),
                        .allocated = true,
                    };
                },
                '\\' => {
                    try builder.appendSlice(allocator, self.input[chunk_start .. self.index - 1]);
                    try self.appendEscape(allocator, &builder);
                    chunk_start = self.index;
                },
                0...31 => return error.InvalidStringCharacter,
                else => {},
            }
        }
    }

    fn appendEscape(self: *Parser, allocator: Allocator, builder: *std.ArrayList(u8)) Error!void {
        const escape = self.consume() orelse return error.UnexpectedEndOfInput;
        switch (escape) {
            '"', '\\', '/' => try builder.append(allocator, escape),
            'b' => try builder.append(allocator, '\x08'),
            'f' => try builder.append(allocator, '\x0c'),
            'n' => try builder.append(allocator, '\n'),
            'r' => try builder.append(allocator, '\r'),
            't' => try builder.append(allocator, '\t'),
            'u' => try self.appendUnicodeEscape(allocator, builder),
            else => return error.InvalidStringEscape,
        }
    }

    fn appendUnicodeEscape(self: *Parser, allocator: Allocator, builder: *std.ArrayList(u8)) Error!void {
        const first = try self.parseHex4();
        var codepoint: u21 = first;

        if (std.unicode.utf16IsHighSurrogate(first)) {
            if (self.consume() != '\\' or self.consume() != 'u') return error.InvalidUnicodeSurrogate;
            const second = try self.parseHex4();
            if (!std.unicode.utf16IsLowSurrogate(second)) return error.InvalidUnicodeSurrogate;
            codepoint = std.unicode.utf16DecodeSurrogatePair(&[_]u16{ first, second }) catch {
                return error.InvalidUnicodeSurrogate;
            };
        } else if (std.unicode.utf16IsLowSurrogate(first)) {
            return error.InvalidUnicodeSurrogate;
        }

        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch unreachable;
        try builder.appendSlice(allocator, utf8[0..len]);
    }

    fn parseHex4(self: *Parser) Error!u16 {
        var value: u16 = 0;
        var count: usize = 0;
        while (count < 4) : (count += 1) {
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            value <<= 4;
            value |= switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => 10 + (c - 'a'),
                'A'...'F' => 10 + (c - 'A'),
                else => return error.InvalidUnicodeEscape,
            };
        }
        return value;
    }

    fn consumeLiteral(self: *Parser, comptime expected: []const u8) Error!void {
        inline for (expected) |c| {
            if (self.consume() != c) return error.UnexpectedToken;
        }
    }

    fn skipWhitespace(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\n', '\r', '\t' => _ = self.consume(),
                else => return,
            }
        }
    }

    fn peek(self: *Parser) ?u8 {
        if (self.index >= self.input.len) return null;
        return self.input[self.index];
    }

    fn consume(self: *Parser) ?u8 {
        const c = self.peek() orelse return null;
        self.index += 1;
        return c;
    }

    fn eof(self: *Parser) bool {
        return self.index >= self.input.len;
    }
};

test "value parse and write roundtrip" {
    const allocator = std.testing.allocator;
    var value = try parseValue(allocator, "{\"name\":\"Ada\",\"numbers\":[1,2,3],\"ok\":true}", .{});
    defer value.deinit(allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try writeValue(&out.writer, value, .{});

    try std.testing.expectEqualStrings(
        "{\"name\":\"Ada\",\"numbers\":[1,2,3],\"ok\":true}",
        out.written(),
    );
}

test "typed serialize supports rename_all and omit_null_fields" {
    const Example = struct {
        firstName: []const u8,
        internal_id: u32,
        nickname: ?[]const u8,
    };

    const value = Example{
        .firstName = "Ada",
        .internal_id = 42,
        .nickname = null,
    };

    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try serializeWith(&out.writer, value, .{
        .rename_all = .snake_case,
        .omit_null_fields = true,
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"first_name\":\"Ada\",\"internal_id\":42}",
        out.written(),
    );
}

test "typed deserialize supports config rename_all" {
    const Example = struct {
        firstName: []const u8,
        accountId: u64,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator, "{\"first_name\":\"Ada\",\"account_id\":99}", .{
        .rename_all = .snake_case,
    }, .{});
    defer allocator.free(decoded.firstName);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(u64, 99), decoded.accountId);
}

test "typed deserialize handles escaped strings on direct path" {
    const Example = struct {
        message: []const u8,
        nickname: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator, "{\"message\":\"Ada\\nLovelace\",\"nickname\":null}", .{}, .{});
    defer allocator.free(decoded.message);

    try std.testing.expectEqualStrings("Ada\nLovelace", decoded.message);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.nickname);
}

test "typed deserialize detects duplicate and unknown fields on direct path" {
    const Example = struct {
        port: u16,
    };

    try std.testing.expectError(
        error.DuplicateField,
        parseSliceWith(Example, std.testing.allocator, "{\"port\":8080,\"port\":9090}", .{}, .{}),
    );

    try std.testing.expectError(
        error.UnknownField,
        parseSliceWith(Example, std.testing.allocator, "{\"port\":8080,\"extra\":1}", .{
            .deny_unknown_fields = true,
        }, .{}),
    );
}

test "reader and writer entrypoints work" {
    const allocator = std.testing.allocator;

    var reader = std.Io.Reader.fixed("{\"service_name\":\"api\",\"port\":8080}");
    const Example = struct {
        serviceName: []const u8,
        port: u16,
    };

    const decoded = try deserializeWith(Example, allocator, &reader, .{
        .rename_all = .snake_case,
    }, .{});
    defer allocator.free(decoded.serviceName);

    try std.testing.expectEqualStrings("api", decoded.serviceName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    try serializeWith(&out.writer, decoded, .{
        .rename_all = .snake_case,
    }, .{});

    try std.testing.expectEqualStrings(
        "{\"service_name\":\"api\",\"port\":8080}",
        out.written(),
    );
}
