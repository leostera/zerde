//! Structured diagnostics for parse and deserialize failures.
//!
//! The normal `!T` APIs stay lightweight. Callers that want richer failures can
//! pass a `Diagnostic` to the `...WithDiagnostics` entrypoints and get the
//! failing field path plus best-effort location data.

const std = @import("std");

pub const Location = struct {
    offset: ?usize = null,
    line: ?usize = null,
    column: ?usize = null,
};

pub const PathSegment = union(enum) {
    field: []const u8,
    index: usize,
};

pub const Diagnostic = struct {
    path: [64]PathSegment = undefined,
    path_len: usize = 0,
    path_truncated: bool = false,
    location: Location = .{},

    pub fn clear(self: *Diagnostic) void {
        self.path_len = 0;
        self.path_truncated = false;
        self.location = .{};
    }

    pub fn pushField(self: *Diagnostic, comptime name: []const u8) void {
        self.push(.{ .field = name });
    }

    pub fn pushIndex(self: *Diagnostic, index: usize) void {
        self.push(.{ .index = index });
    }

    pub fn pop(self: *Diagnostic) void {
        if (self.path_len != 0) self.path_len -= 1;
    }

    pub fn captureFromDeserializer(self: *Diagnostic, deserializer: anytype) void {
        const DeserializerType = @TypeOf(deserializer.*);
        if (@hasDecl(DeserializerType, "errorLocation")) {
            self.mergeLocation(deserializer.errorLocation());
        } else if (@hasDecl(DeserializerType, "errorOffset")) {
            self.mergeLocation(.{ .offset = deserializer.errorOffset() });
        }
    }

    pub fn format(self: *const Diagnostic, writer: *std.Io.Writer, err: anytype) !void {
        try writer.print("{s}", .{@errorName(err)});

        if (self.path_len != 0) {
            try writer.writeAll(" at root");
            for (self.path[0..self.path_len]) |segment| {
                switch (segment) {
                    .field => |name| try writer.print(".{s}", .{name}),
                    .index => |index| try writer.print("[{d}]", .{index}),
                }
            }
            if (self.path_truncated) try writer.writeAll("[...]");
        }

        if (self.location.offset != null or self.location.line != null) {
            try writer.writeAll(" (");
            var wrote = false;

            if (self.location.offset) |offset| {
                try writer.print("offset {d}", .{offset});
                wrote = true;
            }
            if (self.location.line) |line| {
                if (wrote) try writer.writeAll(", ");
                if (self.location.column) |column| {
                    try writer.print("line {d}, column {d}", .{ line, column });
                } else {
                    try writer.print("line {d}", .{line});
                }
            }

            try writer.writeAll(")");
        }
    }

    fn push(self: *Diagnostic, segment: PathSegment) void {
        if (self.path_len == self.path.len) {
            self.path_truncated = true;
            return;
        }

        self.path[self.path_len] = segment;
        self.path_len += 1;
    }

    fn mergeLocation(self: *Diagnostic, location: Location) void {
        if (location.offset != null) self.location.offset = location.offset;
        if (location.line != null) self.location.line = location.line;
        if (location.column != null) self.location.column = location.column;
    }
};

pub fn locationFromOffset(input: []const u8, offset: usize) Location {
    const clamped = @min(offset, input.len);

    var line: usize = 1;
    var column: usize = 1;
    for (input[0..clamped]) |byte| {
        if (byte == '\n') {
            line += 1;
            column = 1;
        } else {
            column += 1;
        }
    }

    return .{
        .offset = clamped,
        .line = line,
        .column = column,
    };
}
