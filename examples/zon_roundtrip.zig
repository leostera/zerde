const zerde = @import("zerde");
const common = @import("common.zig");

pub fn main() !void {
    try common.runRoundTrip(zerde.zon, "zon", true);
}
