const std = @import("std");
const zerde = @import("zerde");

pub const CrewRecord = struct {
    name: []const u8,
    bounty: u32,
    role: enum { shipwright, sniper, doctor },
    colaFuel: bool,
    dockNumber: u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

pub const franky = CrewRecord{
    .name = "Franky",
    .bounty = 394_000_000,
    .role = .shipwright,
    .colaFuel = true,
    .dockNumber = 1,
};

pub fn runRoundTrip(comptime Format: type, comptime label: []const u8, comptime show_text: bool) !void {
    const allocator = std.heap.page_allocator;

    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    try zerde.serialize(Format, &out.writer, franky);

    var decoded = try zerde.parseSliceOwned(Format, CrewRecord, allocator, out.written());
    defer decoded.deinit();

    if (show_text) {
        std.debug.print("{s} payload:\n{s}\n", .{ label, out.written() });
    } else {
        std.debug.print("{s} payload size: {d} bytes\n", .{ label, out.written().len });
    }

    std.debug.print("decoded: {s}, bounty {d}, dock {d}\n", .{
        decoded.value.name,
        decoded.value.bounty,
        decoded.value.dockNumber,
    });
}
