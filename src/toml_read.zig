//! TOML read-side parser and typed deserializer bridge.
//!
//! TOML is not laid out as a single stream of nested objects the way JSON is,
//! because tables and arrays-of-tables can be declared out of line. This module
//! therefore builds a TOML-specific document index and then exposes the same
//! pull-deserializer protocol that the typed layer already knows how to walk.

const std = @import("std");
const Allocator = std.mem.Allocator;
const meta = @import("meta.zig");
const typed = @import("typed.zig");

const Number = typed.Number;
const StringToken = typed.StringToken;
const ValueKind = typed.ValueKind;

pub const ParseError = anyerror;

pub const ReadConfig = struct {
    max_input_bytes: usize = 16 * 1024 * 1024,
};

const Node = union(enum) {
    bool: bool,
    integer: i128,
    float: f64,
    string: StringToken,
    array: *ArrayNode,
    table: *Table,

    fn kind(self: Node) ValueKind {
        return switch (self) {
            .bool => .bool,
            .integer, .float => .number,
            .string => .string,
            .array => .array,
            .table => .object,
        };
    }

    fn deinit(self: Node, allocator: Allocator) void {
        switch (self) {
            .bool, .integer, .float => {},
            .string => |token| token.deinit(allocator),
            .array => |array| array.deinit(allocator),
            .table => |table| table.deinit(allocator),
        }
    }
};

const ArrayNode = struct {
    items: std.ArrayList(Node) = .empty,

    fn create(allocator: Allocator) !*ArrayNode {
        const array = try allocator.create(ArrayNode);
        array.* = .{};
        return array;
    }

    fn append(self: *ArrayNode, allocator: Allocator, item: Node) !void {
        try self.items.append(allocator, item);
    }

    fn lastTable(self: *ArrayNode) !*Table {
        if (self.items.items.len == 0) return error.InvalidTomlState;
        return switch (self.items.items[self.items.items.len - 1]) {
            .table => |table| table,
            else => error.UnexpectedType,
        };
    }

    fn deinit(self: *ArrayNode, allocator: Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
        allocator.destroy(self);
    }
};

const Entry = struct {
    key: []const u8,
    value: Node,
};

const Table = struct {
    entries: std.ArrayList(Entry) = .empty,
    declared: bool = false,

    fn create(allocator: Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{};
        return table;
    }

    fn findEntry(self: *Table, key: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry;
        }
        return null;
    }

    fn addEntry(self: *Table, allocator: Allocator, key: []const u8, value: Node) !*Entry {
        if (self.findEntry(key) != null) return error.DuplicateField;
        const owned_key = try allocator.dupe(u8, key);
        errdefer allocator.free(owned_key);
        try self.entries.append(allocator, .{
            .key = owned_key,
            .value = value,
        });
        return &self.entries.items[self.entries.items.len - 1];
    }

    fn deinit(self: *Table, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            allocator.free(entry.key);
            entry.value.deinit(allocator);
        }
        self.entries.deinit(allocator);
        allocator.destroy(self);
    }
};

const Frame = union(enum) {
    array: struct {
        array: *ArrayNode,
        index: usize,
    },
    object: struct {
        table: *Table,
        index: usize,
    },
};

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !TomlDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return TomlDeserializer(@TypeOf(cfg)).init(allocator, input, true, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !TomlDeserializer(@TypeOf(cfg)) {
    return TomlDeserializer(@TypeOf(cfg)).init(allocator, input, false, cfg);
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
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn TomlDeserializer(comptime Config: type) type {
    return struct {
        input: []const u8,
        cfg: Config,
        owns_input: bool,
        root: Node,
        current: ?*const Node = null,
        stack: [128]Frame = undefined,
        stack_len: usize = 0,

        const Self = @This();

        fn init(allocator: Allocator, input: []const u8, owns_input: bool, cfg: Config) !Self {
            var parser = Parser{ .input = input };
            const root_table = try parser.parseDocument(allocator);
            return .{
                .input = input,
                .cfg = cfg,
                .owns_input = owns_input,
                .root = .{ .table = root_table },
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.root.deinit(allocator);
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
        }

        pub fn peekKind(self: *Self) !ValueKind {
            return self.currentNode().kind();
        }

        pub fn readNull(self: *Self) !void {
            _ = self;
            return error.UnexpectedType;
        }

        pub fn readBool(self: *Self) !bool {
            return switch (self.currentNode()) {
                .bool => |value| value,
                else => error.UnexpectedType,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            return switch (self.currentNode()) {
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
                else => error.UnexpectedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            return switch (self.currentNode()) {
                .string => |token| .{
                    .bytes = token.bytes,
                    .allocated = false,
                },
                else => error.UnexpectedType,
            };
        }

        pub fn beginArray(self: *Self) !void {
            const array = switch (self.currentNode()) {
                .array => |value| value,
                else => return error.UnexpectedType,
            };
            try self.push(.{
                .array = .{
                    .array = array,
                    .index = 0,
                },
            });
        }

        pub fn beginArrayLen(self: *Self) !?usize {
            const array = switch (self.currentNode()) {
                .array => |value| value,
                else => return error.UnexpectedType,
            };
            try self.push(.{
                .array = .{
                    .array = array,
                    .index = 0,
                },
            });
            return array.items.items.len;
        }

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = switch (self.currentFrame().*) {
                .array => |*array_frame| array_frame,
                else => return error.InvalidTomlState,
            };

            if (frame.index >= frame.array.items.items.len) {
                _ = self.pop();
                return false;
            }

            self.current = &frame.array.items.items[frame.index];
            frame.index += 1;
            return true;
        }

        pub fn beginObject(self: *Self) !void {
            const table = switch (self.currentNode()) {
                .table => |value| value,
                else => return error.UnexpectedType,
            };
            try self.push(.{
                .object = .{
                    .table = table,
                    .index = 0,
                },
            });
        }

        pub fn nextObjectField(self: *Self, allocator: Allocator) !?StringToken {
            _ = allocator;
            const frame = switch (self.currentFrame().*) {
                .object => |*object_frame| object_frame,
                else => return error.InvalidTomlState,
            };

            if (frame.index >= frame.table.entries.items.len) {
                _ = self.pop();
                return null;
            }

            const entry = &frame.table.entries.items[frame.index];
            frame.index += 1;
            self.current = &entry.value;
            return .{
                .bytes = entry.key,
                .allocated = false,
            };
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = self;
            _ = allocator;
        }

        fn currentNode(self: *Self) Node {
            if (self.current) |node| return node.*;
            return self.root;
        }

        fn push(self: *Self, frame: Frame) !void {
            if (self.stack_len == self.stack.len) return error.TomlNestingTooDeep;
            self.stack[self.stack_len] = frame;
            self.stack_len += 1;
        }

        fn pop(self: *Self) Frame {
            self.stack_len -= 1;
            return self.stack[self.stack_len];
        }

        fn currentFrame(self: *Self) *Frame {
            return &self.stack[self.stack_len - 1];
        }
    };
}

const Parser = struct {
    input: []const u8,
    index: usize = 0,

    const Error = Allocator.Error || error{
        DuplicateField,
        UnexpectedEndOfInput,
        UnexpectedToken,
        UnexpectedType,
        TrailingCharacters,
        InvalidNumber,
        InvalidStringEscape,
        InvalidUnicodeEscape,
        InvalidUnicodeSurrogate,
        InvalidStringCharacter,
        InvalidBareKey,
        InvalidTomlState,
        UnsupportedTomlFeature,
    };

    fn parseDocument(self: *Parser, allocator: Allocator) Error!*Table {
        const root = try Table.create(allocator);
        errdefer root.deinit(allocator);
        root.declared = true;

        var current_table = root;

        while (true) {
            self.skipDocumentTrivia();
            if (self.eof()) break;

            if (self.peek() == '[') {
                current_table = try self.parseHeader(allocator, root);
            } else {
                try self.parseKeyValue(allocator, current_table);
            }

            try self.finishLine();
        }

        return root;
    }

    fn parseHeader(self: *Parser, allocator: Allocator, root: *Table) Error!*Table {
        if (self.consume() != '[') return error.UnexpectedToken;
        const array_of_tables = self.peek() == '[';
        if (array_of_tables) _ = self.consume();

        var path = try self.parseKeyPath(allocator);
        defer {
            for (path.items) |token| token.deinit(allocator);
            path.deinit(allocator);
        }

        self.skipInlineSpace();
        if (array_of_tables) {
            if (self.consume() != ']' or self.consume() != ']') return error.UnexpectedToken;
            return try appendArrayTablePath(allocator, root, path.items);
        }

        if (self.consume() != ']') return error.UnexpectedToken;
        return try resolveExplicitTablePath(allocator, root, path.items);
    }

    fn parseKeyValue(self: *Parser, allocator: Allocator, current_table: *Table) Error!void {
        var path = try self.parseKeyPath(allocator);
        defer {
            for (path.items) |token| token.deinit(allocator);
            path.deinit(allocator);
        }

        self.skipInlineSpace();
        if (self.consume() != '=') return error.UnexpectedToken;
        self.skipInlineSpace();

        const value = try self.parseValue(allocator);
        errdefer value.deinit(allocator);

        try insertValuePath(allocator, current_table, path.items, value);
    }

    fn parseKeyPath(self: *Parser, allocator: Allocator) Error!std.ArrayList(StringToken) {
        var path: std.ArrayList(StringToken) = .empty;
        errdefer {
            for (path.items) |token| token.deinit(allocator);
            path.deinit(allocator);
        }

        try path.append(allocator, try self.parseKeyToken(allocator));
        while (true) {
            self.skipInlineSpace();
            if (self.peek() != '.') break;
            _ = self.consume();
            self.skipInlineSpace();
            try path.append(allocator, try self.parseKeyToken(allocator));
        }

        return path;
    }

    fn parseKeyToken(self: *Parser, allocator: Allocator) Error!StringToken {
        return switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            '"' => try self.parseStringToken(allocator),
            else => try self.parseBareKey(),
        };
    }

    fn parseBareKey(self: *Parser) Error!StringToken {
        const start = self.index;
        while (self.peek()) |c| {
            if (!(std.ascii.isAlphabetic(c) or std.ascii.isDigit(c) or c == '_' or c == '-')) break;
            _ = self.consume();
        }

        if (self.index == start) return error.InvalidBareKey;
        return .{
            .bytes = self.input[start..self.index],
            .allocated = false,
        };
    }

    fn parseValue(self: *Parser, allocator: Allocator) Error!Node {
        return switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            '"' => .{ .string = try self.parseStringToken(allocator) },
            '[' => try self.parseArray(allocator),
            't', 'f' => .{ .bool = try self.parseBool() },
            '-', '+', '0'...'9' => try self.parseNumber(),
            '{', '\'' => error.UnsupportedTomlFeature,
            else => error.UnexpectedToken,
        };
    }

    fn parseBool(self: *Parser) Error!bool {
        return switch (self.peek() orelse return error.UnexpectedEndOfInput) {
            't' => blk: {
                try self.consumeLiteral("true");
                break :blk true;
            },
            'f' => blk: {
                try self.consumeLiteral("false");
                break :blk false;
            },
            else => error.UnexpectedToken,
        };
    }

    fn parseNumber(self: *Parser) Error!Node {
        return switch (try self.parseNumberToken()) {
            .integer => |value| .{ .integer = value },
            .float => |value| .{ .float = value },
        };
    }

    fn parseArray(self: *Parser, allocator: Allocator) Error!Node {
        if (self.consume() != '[') return error.UnexpectedToken;

        const array = try ArrayNode.create(allocator);
        errdefer array.deinit(allocator);

        self.skipArrayTrivia();
        if (self.peek() == ']') {
            _ = self.consume();
            return .{ .array = array };
        }

        while (true) {
            const item = try self.parseValue(allocator);
            errdefer item.deinit(allocator);
            try array.append(allocator, item);

            self.skipArrayTrivia();
            const next = self.consume() orelse return error.UnexpectedEndOfInput;
            switch (next) {
                ',' => {
                    self.skipArrayTrivia();
                    if (self.peek() == ']') {
                        _ = self.consume();
                        return .{ .array = array };
                    }
                },
                ']' => return .{ .array = array },
                else => return error.UnexpectedToken,
            }
        }
    }

    fn parseNumberToken(self: *Parser) Error!Number {
        const start = self.index;
        var is_float = false;

        if (self.peek()) |sign| {
            if (sign == '-' or sign == '+') _ = self.consume();
        }

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
            '"', '\\' => try builder.append(allocator, escape),
            'b' => try builder.append(allocator, '\x08'),
            'f' => try builder.append(allocator, '\x0c'),
            'n' => try builder.append(allocator, '\n'),
            'r' => try builder.append(allocator, '\r'),
            't' => try builder.append(allocator, '\t'),
            'u' => try self.appendUnicodeEscape(allocator, builder, 4),
            'U' => try self.appendUnicodeEscape(allocator, builder, 8),
            else => return error.InvalidStringEscape,
        }
    }

    fn appendUnicodeEscape(self: *Parser, allocator: Allocator, builder: *std.ArrayList(u8), comptime digits: usize) Error!void {
        const codepoint = try self.parseHexCodepoint(digits);
        var utf8: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(codepoint, &utf8) catch return error.InvalidUnicodeEscape;
        try builder.appendSlice(allocator, utf8[0..len]);
    }

    fn parseHexCodepoint(self: *Parser, comptime digits: usize) Error!u21 {
        var value: u32 = 0;
        var count: usize = 0;
        while (count < digits) : (count += 1) {
            const c = self.consume() orelse return error.UnexpectedEndOfInput;
            value <<= 4;
            value |= switch (c) {
                '0'...'9' => c - '0',
                'a'...'f' => 10 + (c - 'a'),
                'A'...'F' => 10 + (c - 'A'),
                else => return error.InvalidUnicodeEscape,
            };
        }

        if (value > std.math.maxInt(u21)) return error.InvalidUnicodeEscape;
        if (value >= 0xD800 and value <= 0xDFFF) return error.InvalidUnicodeSurrogate;
        return @as(u21, @intCast(value));
    }

    fn finishLine(self: *Parser) Error!void {
        self.skipInlineSpace();
        if (self.peek() == '#') self.skipComment();
        if (self.eof()) return;
        if (self.peek() == '\n' or self.peek() == '\r') {
            self.consumeLineEnding();
            return;
        }
        return error.TrailingCharacters;
    }

    fn skipDocumentTrivia(self: *Parser) void {
        while (true) {
            self.skipInlineSpace();
            if (self.peek() == '#') {
                self.skipComment();
            }

            if (self.peek()) |c| {
                if (c == '\n' or c == '\r') {
                    self.consumeLineEnding();
                    continue;
                }
            }
            break;
        }
    }

    fn skipArrayTrivia(self: *Parser) void {
        while (true) {
            self.skipInlineSpace();
            if (self.peek() == '#') {
                self.skipComment();
                continue;
            }
            if (self.peek()) |c| {
                if (c == '\n' or c == '\r') {
                    self.consumeLineEnding();
                    continue;
                }
            }
            break;
        }
    }

    fn consumeLiteral(self: *Parser, comptime expected: []const u8) Error!void {
        inline for (expected) |c| {
            if (self.consume() != c) return error.UnexpectedToken;
        }
    }

    fn skipInlineSpace(self: *Parser) void {
        while (self.peek()) |c| {
            switch (c) {
                ' ', '\t' => _ = self.consume(),
                else => return,
            }
        }
    }

    fn skipComment(self: *Parser) void {
        if (self.peek() == '#') _ = self.consume();
        while (self.peek()) |c| {
            if (c == '\n' or c == '\r') return;
            _ = self.consume();
        }
    }

    fn consumeLineEnding(self: *Parser) void {
        if (self.peek() == '\r') {
            _ = self.consume();
            if (self.peek() == '\n') _ = self.consume();
            return;
        }
        if (self.peek() == '\n') _ = self.consume();
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

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return 16 * 1024 * 1024;
}

fn resolveExplicitTablePath(allocator: Allocator, root: *Table, path: []const StringToken) !*Table {
    if (path.len == 0) return error.InvalidTomlState;

    var table = root;
    for (path, 0..) |segment, index| {
        const is_last = index + 1 == path.len;
        if (table.findEntry(segment.bytes)) |entry| {
            switch (entry.value) {
                .table => |child| {
                    if (is_last) {
                        if (child.declared) return error.DuplicateField;
                        child.declared = true;
                    }
                    table = child;
                },
                .array => |array| {
                    if (is_last) return error.UnexpectedType;
                    table = try array.lastTable();
                },
                else => return error.UnexpectedType,
            }
        } else {
            const child = try Table.create(allocator);
            child.declared = is_last;
            _ = try table.addEntry(allocator, segment.bytes, .{ .table = child });
            table = child;
        }
    }

    return table;
}

fn appendArrayTablePath(allocator: Allocator, root: *Table, path: []const StringToken) !*Table {
    if (path.len == 0) return error.InvalidTomlState;

    var table = root;
    for (path[0 .. path.len - 1]) |segment| {
        table = try resolveDescendantTable(allocator, table, segment.bytes);
    }

    const leaf = path[path.len - 1].bytes;
    if (table.findEntry(leaf)) |entry| {
        switch (entry.value) {
            .array => |array| {
                _ = try array.lastTable();
                const child = try Table.create(allocator);
                child.declared = true;
                try array.append(allocator, .{ .table = child });
                return child;
            },
            else => return error.UnexpectedType,
        }
    }

    const array = try ArrayNode.create(allocator);
    errdefer array.deinit(allocator);
    const child = try Table.create(allocator);
    errdefer child.deinit(allocator);
    child.declared = true;
    try array.append(allocator, .{ .table = child });
    _ = try table.addEntry(allocator, leaf, .{ .array = array });
    return child;
}

fn insertValuePath(allocator: Allocator, current_table: *Table, path: []const StringToken, value: Node) !void {
    if (path.len == 0) return error.InvalidTomlState;

    var table = current_table;
    for (path[0 .. path.len - 1]) |segment| {
        table = try resolveDescendantTable(allocator, table, segment.bytes);
    }

    _ = try table.addEntry(allocator, path[path.len - 1].bytes, value);
}

fn resolveDescendantTable(allocator: Allocator, table: *Table, key: []const u8) !*Table {
    if (table.findEntry(key)) |entry| {
        return switch (entry.value) {
            .table => |child| child,
            .array => |array| try array.lastTable(),
            else => error.UnexpectedType,
        };
    }

    const child = try Table.create(allocator);
    _ = try table.addEntry(allocator, key, .{ .table = child });
    return child;
}

test "typed deserialize nested struct from toml" {
    const Example = struct {
        serviceName: []const u8,
        port: u16,
        metadata: struct {
            owner: []const u8,
            retries: []const u8,
        },
        weights: []const f32,

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator,
        \\service_name = "api"
        \\port = 8080
        \\weights = [0.5, 1.25]
        \\
        \\[metadata]
        \\owner = "platform"
        \\retries = "three"
        \\
    , .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(allocator, decoded);

    try std.testing.expectEqualStrings("api", decoded.serviceName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
    try std.testing.expectEqual(@as(usize, 2), decoded.weights.len);
    try std.testing.expectEqualStrings("platform", decoded.metadata.owner);
    try std.testing.expectEqualStrings("three", decoded.metadata.retries);
}

test "typed deserialize arrays of tables from toml" {
    const Example = struct {
        serviceName: []const u8,
        endpoints: []const struct {
            path: []const u8,
            enabled: bool,
        },

        pub const serde = .{
            .rename_all = .snake_case,
        };
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator,
        \\service_name = "api"
        \\
        \\[[endpoints]]
        \\path = "/health"
        \\enabled = true
        \\
        \\[[endpoints]]
        \\path = "/ready"
        \\enabled = false
        \\
    , .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(allocator, decoded);

    try std.testing.expectEqualStrings("api", decoded.serviceName);
    try std.testing.expectEqual(@as(usize, 2), decoded.endpoints.len);
    try std.testing.expectEqualStrings("/health", decoded.endpoints[0].path);
    try std.testing.expectEqual(true, decoded.endpoints[0].enabled);
    try std.testing.expectEqualStrings("/ready", decoded.endpoints[1].path);
    try std.testing.expectEqual(false, decoded.endpoints[1].enabled);
}

test "typed deserialize supports rename defaults and optional fields" {
    const Example = struct {
        firstName: []const u8,
        accountId: u64,
        nickname: ?[]const u8,
    };

    const allocator = std.testing.allocator;
    const decoded = try parseSliceWith(Example, allocator,
        \\first_name = "Ada"
        \\account_id = 99
        \\
    , .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(allocator, decoded);

    try std.testing.expectEqualStrings("Ada", decoded.firstName);
    try std.testing.expectEqual(@as(u64, 99), decoded.accountId);
    try std.testing.expectEqual(@as(?[]const u8, null), decoded.nickname);
}

test "typed deserialize detects duplicate and unknown toml fields" {
    const Example = struct {
        port: u16,
    };

    try std.testing.expectError(
        error.DuplicateField,
        parseSliceWith(Example, std.testing.allocator,
            \\port = 8080
            \\port = 9090
            \\
        , .{}, .{}),
    );

    try std.testing.expectError(
        error.UnknownField,
        parseSliceWith(Example, std.testing.allocator,
            \\port = 8080
            \\extra = 1
            \\
        , .{
            .deny_unknown_fields = true,
        }, .{}),
    );
}

test "toml reader entrypoint works" {
    const Example = struct {
        serviceName: []const u8,
        port: u16,
    };

    var reader = std.Io.Reader.fixed(
        \\service_name = "api"
        \\port = 8080
        \\
    );

    const allocator = std.testing.allocator;
    const decoded = try deserializeWith(Example, allocator, &reader, .{
        .rename_all = .snake_case,
    }, .{});
    defer typed.free(allocator, decoded);

    try std.testing.expectEqualStrings("api", decoded.serviceName);
    try std.testing.expectEqual(@as(u16, 8080), decoded.port);
}
