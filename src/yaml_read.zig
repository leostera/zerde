//! YAML read-side parser and typed deserializer bridge.
//!
//! This parser intentionally targets a practical YAML subset that matches the
//! writer in `yaml.zig`: block mappings, block sequences of compound values,
//! flow sequences of scalar values, plain scalars, and quoted scalars.

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
    borrow_strings: bool = false,
};

const Node = union(enum) {
    null,
    bool: bool,
    integer: i128,
    float: f64,
    string: StringToken,
    array: *ArrayNode,
    table: *Table,

    fn kind(self: Node) ValueKind {
        return switch (self) {
            .null => .null,
            .bool => .bool,
            .integer, .float => .number,
            .string => .string,
            .array => .array,
            .table => .object,
        };
    }

    fn deinit(self: Node, allocator: Allocator) void {
        switch (self) {
            .null, .bool, .integer, .float => {},
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

    fn deinit(self: *ArrayNode, allocator: Allocator) void {
        for (self.items.items) |item| item.deinit(allocator);
        self.items.deinit(allocator);
        allocator.destroy(self);
    }
};

const Entry = struct {
    key: StringToken,
    value: Node,
};

const Table = struct {
    entries: std.ArrayList(Entry) = .empty,

    fn create(allocator: Allocator) !*Table {
        const table = try allocator.create(Table);
        table.* = .{};
        return table;
    }

    fn findEntry(self: *Table, key: []const u8) ?*Entry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key.bytes, key)) return entry;
        }
        return null;
    }

    fn addEntry(self: *Table, allocator: Allocator, key: StringToken, value: Node) !void {
        if (self.findEntry(key.bytes) != null) {
            key.deinit(allocator);
            return error.DuplicateField;
        }
        try self.entries.append(allocator, .{
            .key = key,
            .value = value,
        });
    }

    fn deinit(self: *Table, allocator: Allocator) void {
        for (self.entries.items) |entry| {
            entry.key.deinit(allocator);
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

const Line = struct {
    indent: usize,
    content: []const u8,
};

pub fn readerDeserializer(allocator: Allocator, reader: *std.Io.Reader, comptime cfg: anytype) !YamlDeserializer(@TypeOf(cfg)) {
    const input = try reader.allocRemaining(allocator, .limited(effectiveMaxInputBytes(cfg)));
    return YamlDeserializer(@TypeOf(cfg)).init(allocator, input, true, cfg);
}

pub fn sliceDeserializer(allocator: Allocator, input: []const u8, comptime cfg: anytype) !YamlDeserializer(@TypeOf(cfg)) {
    return YamlDeserializer(@TypeOf(cfg)).init(allocator, input, false, cfg);
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

pub fn parseSliceAliased(comptime T: type, allocator: Allocator, input: []const u8) ParseError!T {
    return parseSliceAliasedWith(T, allocator, input, .{}, .{});
}

pub fn parseSliceAliasedWith(
    comptime T: type,
    allocator: Allocator,
    input: []const u8,
    comptime serde_cfg: anytype,
    comptime read_cfg: anytype,
) ParseError!T {
    var deserializer = try sliceDeserializer(allocator, input, .{
        .max_input_bytes = effectiveMaxInputBytes(read_cfg),
        .borrow_strings = true,
    });
    defer deserializer.deinit(allocator);
    const value = try typed.deserialize(T, allocator, &deserializer, serde_cfg);
    try deserializer.finish();
    return value;
}

pub fn YamlDeserializer(comptime Config: type) type {
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
            var parser = try Parser.init(allocator, input, effectiveBorrowStrings(cfg));
            defer parser.deinit(allocator);

            return .{
                .input = input,
                .cfg = cfg,
                .owns_input = owns_input,
                .root = try parser.parseDocument(allocator),
            };
        }

        pub fn deinit(self: *Self, allocator: Allocator) void {
            self.root.deinit(allocator);
            if (self.owns_input) allocator.free(@constCast(self.input));
        }

        pub fn finish(self: *Self) !void {
            _ = self.cfg;
        }

        pub fn borrowStrings(self: *Self) bool {
            return effectiveBorrowStrings(self.cfg);
        }

        pub fn peekKind(self: *Self) !ValueKind {
            return self.currentNode().kind();
        }

        pub fn readNull(self: *Self) !void {
            switch (self.currentNode().*) {
                .null => {},
                else => return error.UnexpectedType,
            }
        }

        pub fn readBool(self: *Self) !bool {
            return switch (self.currentNode().*) {
                .bool => |value| value,
                else => error.UnexpectedType,
            };
        }

        pub fn readNumber(self: *Self) !Number {
            return switch (self.currentNode().*) {
                .integer => |value| .{ .integer = value },
                .float => |value| .{ .float = value },
                else => error.UnexpectedType,
            };
        }

        pub fn readString(self: *Self, allocator: Allocator) !StringToken {
            _ = allocator;
            return switch (self.currentNode().*) {
                .string => |token| .{
                    .bytes = token.bytes,
                    .allocated = false,
                },
                else => error.UnexpectedType,
            };
        }

        pub fn beginArray(self: *Self) !void {
            const array = switch (self.currentNode().*) {
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

        pub fn nextArrayItem(self: *Self) !bool {
            const frame = switch (self.currentFrame().*) {
                .array => |*array_frame| array_frame,
                else => return error.InvalidYamlState,
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
            const table = switch (self.currentNode().*) {
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
                else => return error.InvalidYamlState,
            };

            if (frame.index >= frame.table.entries.items.len) {
                _ = self.pop();
                return null;
            }

            const entry = &frame.table.entries.items[frame.index];
            frame.index += 1;
            self.current = &entry.value;
            return .{
                .bytes = entry.key.bytes,
                .allocated = false,
            };
        }

        pub fn skipValue(self: *Self, allocator: Allocator) !void {
            _ = self;
            _ = allocator;
        }

        fn currentNode(self: *Self) *const Node {
            return self.current orelse &self.root;
        }

        fn push(self: *Self, frame: Frame) !void {
            if (self.stack_len == self.stack.len) return error.YamlNestingTooDeep;
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
    borrow_strings: bool,
    lines: std.ArrayList(Line) = .empty,
    line_index: usize = 0,

    fn init(allocator: Allocator, input: []const u8, borrow_strings: bool) !Parser {
        var parser = Parser{
            .input = input,
            .borrow_strings = borrow_strings,
        };
        try parser.loadLines(allocator);
        return parser;
    }

    fn deinit(self: *Parser, allocator: Allocator) void {
        self.lines.deinit(allocator);
    }

    fn parseDocument(self: *Parser, allocator: Allocator) ParseError!Node {
        if (self.lines.items.len == 0) return .null;
        return self.parseNode(allocator, self.lines.items[0].indent);
    }

    fn parseNode(self: *Parser, allocator: Allocator, indent: usize) ParseError!Node {
        if (self.line_index >= self.lines.items.len) return .null;

        const line = self.lines.items[self.line_index];
        if (line.indent != indent) return error.InvalidYamlIndentation;

        if (isSequenceLine(line.content)) {
            return .{ .array = try self.parseSequence(allocator, indent) };
        }

        if (findMapSeparator(line.content) != null) {
            return .{ .table = try self.parseMap(allocator, indent) };
        }

        const value = try self.parseInlineValue(allocator, line.content);
        self.line_index += 1;
        return value;
    }

    fn parseMap(self: *Parser, allocator: Allocator, indent: usize) ParseError!*Table {
        const table = try Table.create(allocator);
        errdefer table.deinit(allocator);

        while (self.line_index < self.lines.items.len) {
            const line = self.lines.items[self.line_index];
            if (line.indent != indent or isSequenceLine(line.content)) break;
            if (findMapSeparator(line.content) == null) break;
            try self.parseMapEntryContent(allocator, table, indent, line.content);
        }

        return table;
    }

    fn parseSequence(self: *Parser, allocator: Allocator, indent: usize) ParseError!*ArrayNode {
        const array = try ArrayNode.create(allocator);
        errdefer array.deinit(allocator);

        while (self.line_index < self.lines.items.len) {
            const line = self.lines.items[self.line_index];
            if (line.indent != indent or !isSequenceLine(line.content)) break;

            const rest = trimLeftSpaces(line.content[1..]);
            if (rest.len == 0) {
                self.line_index += 1;
                var value: Node = .null;
                if (self.line_index < self.lines.items.len and self.lines.items[self.line_index].indent > indent) {
                    value = try self.parseNode(allocator, self.lines.items[self.line_index].indent);
                }
                try array.append(allocator, value);
                continue;
            }

            if (findMapSeparator(rest) != null) {
                const table = try self.parseSequenceItemMap(allocator, indent, rest);
                try array.append(allocator, .{ .table = table });
                continue;
            }

            const value = try self.parseInlineValue(allocator, rest);
            self.line_index += 1;
            try array.append(allocator, value);
        }

        return array;
    }

    fn parseSequenceItemMap(self: *Parser, allocator: Allocator, item_indent: usize, first_content: []const u8) ParseError!*Table {
        const table = try Table.create(allocator);
        errdefer table.deinit(allocator);

        try self.parseMapEntryContent(allocator, table, item_indent, first_content);

        if (self.line_index >= self.lines.items.len or self.lines.items[self.line_index].indent <= item_indent) {
            return table;
        }

        const continuation_indent = self.lines.items[self.line_index].indent;
        while (self.line_index < self.lines.items.len) {
            const line = self.lines.items[self.line_index];
            if (line.indent != continuation_indent or isSequenceLine(line.content)) break;
            if (findMapSeparator(line.content) == null) break;
            try self.parseMapEntryContent(allocator, table, continuation_indent, line.content);
        }

        return table;
    }

    fn parseMapEntryContent(self: *Parser, allocator: Allocator, table: *Table, indent: usize, content: []const u8) ParseError!void {
        const separator = findMapSeparator(content) orelse return error.ExpectedMappingSeparator;
        const raw_key = trimRightSpaces(content[0..separator]);
        if (raw_key.len == 0) return error.ExpectedMappingKey;

        const key = try self.parseKeyToken(allocator, raw_key);
        errdefer key.deinit(allocator);

        const rest = trimLeftSpaces(content[separator + 1 ..]);
        self.line_index += 1;

        var value: Node = .null;
        errdefer value.deinit(allocator);

        if (rest.len == 0) {
            if (self.line_index < self.lines.items.len and self.lines.items[self.line_index].indent > indent) {
                value = try self.parseNode(allocator, self.lines.items[self.line_index].indent);
            }
        } else {
            value = try self.parseInlineValue(allocator, rest);
        }

        try table.addEntry(allocator, key, value);
    }

    fn parseInlineValue(self: *Parser, allocator: Allocator, raw: []const u8) ParseError!Node {
        const text = std.mem.trim(u8, raw, " ");
        if (text.len == 0) return .null;

        if (text[0] == '[') {
            return .{ .array = try self.parseFlowList(allocator, text) };
        }

        if (isQuoted(text)) {
            return .{ .string = try self.parseQuotedToken(allocator, text) };
        }

        if (parseNull(text)) {
            return .null;
        }

        if (parseBool(text)) |value| {
            return .{ .bool = value };
        }

        if (looksLikeFloat(text)) {
            if (std.fmt.parseFloat(f64, text)) |value| {
                return .{ .float = value };
            } else |_| {}
        } else {
            if (std.fmt.parseInt(i128, text, 0)) |value| {
                return .{ .integer = value };
            } else |_| {}
        }

        return .{ .string = self.borrowedToken(text) };
    }

    fn parseFlowList(self: *Parser, allocator: Allocator, text: []const u8) ParseError!*ArrayNode {
        if (text.len < 2 or text[text.len - 1] != ']') return error.InvalidYamlFlowSequence;

        const array = try ArrayNode.create(allocator);
        errdefer array.deinit(allocator);

        const inner = std.mem.trim(u8, text[1 .. text.len - 1], " ");
        if (inner.len == 0) return array;

        var start: usize = 0;
        var depth: usize = 0;
        var quote: ?u8 = null;
        var escaped = false;

        for (inner, 0..) |char, i| {
            if (quote) |q| {
                if (q == '"' and escaped) {
                    escaped = false;
                    continue;
                }
                if (q == '"' and char == '\\') {
                    escaped = true;
                    continue;
                }
                if (char == q) quote = null;
                continue;
            }

            switch (char) {
                '\'', '"' => quote = char,
                '[' => depth += 1,
                ']' => {
                    if (depth == 0) return error.InvalidYamlFlowSequence;
                    depth -= 1;
                },
                ',' => if (depth == 0) {
                    try array.append(allocator, try self.parseInlineValue(allocator, inner[start..i]));
                    start = i + 1;
                },
                else => {},
            }
        }

        try array.append(allocator, try self.parseInlineValue(allocator, inner[start..]));
        return array;
    }

    fn parseKeyToken(self: *Parser, allocator: Allocator, raw_key: []const u8) ParseError!StringToken {
        if (isQuoted(raw_key)) return self.parseQuotedToken(allocator, raw_key);
        return self.borrowedToken(raw_key);
    }

    fn parseQuotedToken(self: *Parser, allocator: Allocator, text: []const u8) ParseError!StringToken {
        if (text.len < 2 or text[text.len - 1] != text[0]) return error.InvalidYamlString;

        const quote = text[0];
        const inner = text[1 .. text.len - 1];

        if (quote == '\'' and std.mem.indexOfScalar(u8, inner, '\'') == null) {
            return self.borrowedToken(inner);
        }

        if (quote == '"' and std.mem.indexOfScalar(u8, inner, '\\') == null) {
            return self.borrowedToken(inner);
        }

        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);

        if (quote == '\'') {
            var i: usize = 0;
            while (i < inner.len) : (i += 1) {
                if (inner[i] == '\'' and i + 1 < inner.len and inner[i + 1] == '\'') {
                    try out.append(allocator, '\'');
                    i += 1;
                    continue;
                }
                try out.append(allocator, inner[i]);
            }
        } else {
            var i: usize = 0;
            while (i < inner.len) : (i += 1) {
                if (inner[i] != '\\') {
                    try out.append(allocator, inner[i]);
                    continue;
                }

                i += 1;
                if (i >= inner.len) return error.InvalidYamlEscape;
                const escaped: u8 = switch (inner[i]) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => return error.InvalidYamlEscape,
                };
                try out.append(allocator, escaped);
            }
        }

        return .{
            .bytes = try out.toOwnedSlice(allocator),
            .allocated = true,
        };
    }

    fn borrowedToken(self: *Parser, bytes: []const u8) StringToken {
        _ = self.borrow_strings;
        return .{
            .bytes = bytes,
            .allocated = false,
        };
    }

    fn loadLines(self: *Parser, allocator: Allocator) ParseError!void {
        var start: usize = 0;
        while (start <= self.input.len) {
            const end = std.mem.indexOfScalarPos(u8, self.input, start, '\n') orelse self.input.len;
            var line = self.input[start..end];
            if (line.len != 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            try self.appendLine(allocator, line);
            if (end == self.input.len) break;
            start = end + 1;
        }
    }

    fn appendLine(self: *Parser, allocator: Allocator, raw_line: []const u8) ParseError!void {
        const trimmed_right = trimRightSpaces(raw_line);
        if (trimmed_right.len == 0) return;

        var indent: usize = 0;
        while (indent < trimmed_right.len and trimmed_right[indent] == ' ') : (indent += 1) {}
        if (indent < trimmed_right.len and trimmed_right[indent] == '\t') return error.InvalidYamlIndentation;

        const content = trimmed_right[indent..];
        if (content.len == 0) return;
        if (content[0] == '#') return;
        if (std.mem.eql(u8, content, "---") or std.mem.eql(u8, content, "...")) return;

        try self.lines.append(allocator, .{
            .indent = indent,
            .content = content,
        });
    }
};

fn effectiveMaxInputBytes(comptime cfg: anytype) usize {
    if (comptime meta.hasField(@TypeOf(cfg), "max_input_bytes")) return @field(cfg, "max_input_bytes");
    return (ReadConfig{}).max_input_bytes;
}

fn effectiveBorrowStrings(comptime cfg: anytype) bool {
    if (comptime meta.hasField(@TypeOf(cfg), "borrow_strings")) return @field(cfg, "borrow_strings");
    return false;
}

fn isSequenceLine(content: []const u8) bool {
    return content.len != 0 and content[0] == '-' and (content.len == 1 or content[1] == ' ');
}

fn findMapSeparator(text: []const u8) ?usize {
    var bracket_depth: usize = 0;
    var quote: ?u8 = null;
    var escaped = false;

    for (text, 0..) |char, i| {
        if (quote) |q| {
            if (q == '"' and escaped) {
                escaped = false;
                continue;
            }
            if (q == '"' and char == '\\') {
                escaped = true;
                continue;
            }
            if (char == q) quote = null;
            continue;
        }

        switch (char) {
            '\'', '"' => quote = char,
            '[' => bracket_depth += 1,
            ']' => {
                if (bracket_depth != 0) bracket_depth -= 1;
            },
            ':' => {
                if (bracket_depth != 0) continue;
                if (i + 1 == text.len or text[i + 1] == ' ') return i;
            },
            else => {},
        }
    }

    return null;
}

fn parseNull(text: []const u8) bool {
    return std.mem.eql(u8, text, "null") or std.mem.eql(u8, text, "~");
}

fn parseBool(text: []const u8) ?bool {
    if (std.ascii.eqlIgnoreCase(text, "true") or
        std.ascii.eqlIgnoreCase(text, "yes") or
        std.ascii.eqlIgnoreCase(text, "on") or
        std.ascii.eqlIgnoreCase(text, "y"))
    {
        return true;
    }

    if (std.ascii.eqlIgnoreCase(text, "false") or
        std.ascii.eqlIgnoreCase(text, "no") or
        std.ascii.eqlIgnoreCase(text, "off") or
        std.ascii.eqlIgnoreCase(text, "n"))
    {
        return false;
    }

    return null;
}

fn looksLikeFloat(text: []const u8) bool {
    return std.mem.indexOfScalar(u8, text, '.') != null or
        std.mem.indexOfScalar(u8, text, 'e') != null or
        std.mem.indexOfScalar(u8, text, 'E') != null;
}

fn isQuoted(text: []const u8) bool {
    return text.len >= 2 and ((text[0] == '"' and text[text.len - 1] == '"') or (text[0] == '\'' and text[text.len - 1] == '\''));
}

fn trimLeftSpaces(text: []const u8) []const u8 {
    var start: usize = 0;
    while (start < text.len and text[start] == ' ') : (start += 1) {}
    return text[start..];
}

fn trimRightSpaces(text: []const u8) []const u8 {
    var end = text.len;
    while (end != 0 and text[end - 1] == ' ') : (end -= 1) {}
    return text[0..end];
}
