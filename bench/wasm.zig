//! wasm helper benchmark against the direct binary path.

const std = @import("std");
const zerde = @import("zerde");
const bin_bench = @import("bin.zig");

const Allocator = std.mem.Allocator;
const Scenario = bin_bench.Scenario;
const scenarios = bin_bench.scenarios;
const BenchStats = bin_bench.BenchStats;
const BinPayload = bin_bench.BinPayload;

const WasmScenarioResult = struct {
    parse_bytes: usize,
    write_bytes: usize,
    parse_wasm: BenchStats,
    parse_bin: BenchStats,
    write_wasm: BenchStats,
    write_bin: BenchStats,
    roundtrip_wasm: BenchStats,
    roundtrip_bin: BenchStats,
};

pub fn run(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde wasm benchmark vs direct zerde.bin\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> wasm buffer -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: wasm uses the compact binary format under the hood; this benchmark isolates pointer+length helper overhead against the equivalent direct binary API path\n\n", .{});

    for (scenarios) |scenario| {
        const result = try runScenario(io, allocator, scenario);
        printScenarioResult(scenario, result);
    }

    std.debug.print("\n", .{});
}

fn runScenario(io: std.Io, allocator: Allocator, scenario: Scenario) !WasmScenarioResult {
    const WasmParse = struct {
        input: []const u8,
        arena: std.heap.ArenaAllocator,

        fn init(input: []const u8) @This() {
            return .{
                .input = input,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            const parsed = zerde.wasm.parse(BinPayload, self.arena.allocator(), zerde.wasm.sliceDescriptor(self.input)) catch @panic("zerde wasm parse failed");
            bin_bench.consumePayload(parsed);
        }
    };

    const BinParse = struct {
        input: []const u8,
        arena: std.heap.ArenaAllocator,

        fn init(input: []const u8) @This() {
            return .{
                .input = input,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            const parsed = zerde.parseSlice(zerde.bin, BinPayload, self.arena.allocator(), self.input) catch @panic("zerde bin parse failed");
            bin_bench.consumePayload(parsed);
        }
    };

    const WasmSerialize = struct {
        value: BinPayload,

        fn init(value: BinPayload) @This() {
            return .{ .value = value };
        }

        pub fn run(self: *@This(), _: Allocator) void {
            var out = zerde.wasm.serializeOwned(std.heap.page_allocator, self.value) catch @panic("zerde wasm serialize failed");
            defer out.deinit();
            std.mem.doNotOptimizeAway(out.bytes().len);
        }
    };

    const BinSerialize = struct {
        value: BinPayload,

        fn init(value: BinPayload) @This() {
            return .{ .value = value };
        }

        pub fn run(self: *@This(), _: Allocator) void {
            var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer out.deinit();
            zerde.serialize(zerde.bin, &out.writer, self.value) catch @panic("zerde bin serialize failed");
            std.mem.doNotOptimizeAway(out.written().len);
        }
    };

    const WasmRoundTrip = struct {
        value: BinPayload,
        arena: std.heap.ArenaAllocator,

        fn init(value: BinPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            var check_out = try zerde.wasm.serializeOwned(std.heap.page_allocator, value);
            defer check_out.deinit();
            const check = try zerde.wasm.parse(BinPayload, self.arena.allocator(), check_out.descriptor());
            try std.testing.expectEqualDeep(value, check);
            _ = self.arena.reset(.retain_capacity);
            return self;
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            var out = zerde.wasm.serializeOwned(std.heap.page_allocator, self.value) catch @panic("zerde wasm roundtrip serialize failed");
            defer out.deinit();
            const parsed = zerde.wasm.parse(BinPayload, self.arena.allocator(), out.descriptor()) catch @panic("zerde wasm roundtrip parse failed");
            bin_bench.consumePayload(parsed);
        }
    };

    const BinRoundTrip = struct {
        value: BinPayload,
        arena: std.heap.ArenaAllocator,

        fn init(value: BinPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer out.deinit();
            try zerde.serialize(zerde.bin, &out.writer, value);
            const check = try zerde.parseSlice(zerde.bin, BinPayload, self.arena.allocator(), out.written());
            try std.testing.expectEqualDeep(value, check);
            _ = self.arena.reset(.retain_capacity);
            return self;
        }

        fn deinit(self: *@This()) void {
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
            defer out.deinit();
            zerde.serialize(zerde.bin, &out.writer, self.value) catch @panic("zerde bin roundtrip serialize failed");
            const parsed = zerde.parseSlice(zerde.bin, BinPayload, self.arena.allocator(), out.written()) catch @panic("zerde bin roundtrip parse failed");
            bin_bench.consumePayload(parsed);
        }
    };

    const value = try bin_bench.makePayload(allocator, scenario);
    defer bin_bench.freePayload(allocator, value);

    var parse_out: std.Io.Writer.Allocating = .init(allocator);
    defer parse_out.deinit();
    try zerde.serialize(zerde.bin, &parse_out.writer, value);
    const parse_input = parse_out.written();

    var write_out = try zerde.wasm.serializeOwned(allocator, value);
    defer write_out.deinit();

    var parse_wasm = WasmParse.init(parse_input);
    defer parse_wasm.deinit();
    var parse_bin = BinParse.init(parse_input);
    defer parse_bin.deinit();
    var write_wasm = WasmSerialize.init(value);
    var write_bin = BinSerialize.init(value);
    var roundtrip_wasm = try WasmRoundTrip.init(value);
    defer roundtrip_wasm.deinit();
    var roundtrip_bin = try BinRoundTrip.init(value);
    defer roundtrip_bin.deinit();

    return .{
        .parse_bytes = parse_input.len,
        .write_bytes = write_out.bytes().len,
        .parse_wasm = try bin_bench.runZbenchParam(io, allocator, "wasm parse zerde", &parse_wasm, scenario.parse_iterations),
        .parse_bin = try bin_bench.runZbenchParam(io, allocator, "wasm parse bin", &parse_bin, scenario.parse_iterations),
        .write_wasm = try bin_bench.runZbenchParam(io, allocator, "wasm write zerde", &write_wasm, scenario.write_iterations),
        .write_bin = try bin_bench.runZbenchParam(io, allocator, "wasm write bin", &write_bin, scenario.write_iterations),
        .roundtrip_wasm = try bin_bench.runZbenchParam(io, allocator, "wasm roundtrip zerde", &roundtrip_wasm, scenario.roundtrip_iterations),
        .roundtrip_bin = try bin_bench.runZbenchParam(io, allocator, "wasm roundtrip bin", &roundtrip_bin, scenario.roundtrip_iterations),
    };
}

fn printScenarioResult(scenario: Scenario, result: WasmScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{ result.parse_bytes, bin_bench.bytesToMiB(result.parse_bytes) });
    std.debug.print("  write bytes: {d} ({d:.2} MiB)\n", .{ result.write_bytes, bin_bench.bytesToMiB(result.write_bytes) });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{ scenario.endpoint_count, scenario.metric_count, scenario.event_count });
    std.debug.print("  parse iters: {d}\n", .{result.parse_wasm.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_wasm.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_wasm.iterations});
    std.debug.print("  parse  wasm: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.parse_wasm.nsPerOp(), result.parse_wasm.mibPerSec(result.parse_bytes) });
    std.debug.print("  parse   bin: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.parse_bin.nsPerOp(), result.parse_bin.mibPerSec(result.parse_bytes) });
    std.debug.print("  write  wasm: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.write_wasm.nsPerOp(), result.write_wasm.mibPerSec(result.write_bytes) });
    std.debug.print("  write   bin: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.write_bin.nsPerOp(), result.write_bin.mibPerSec(result.write_bytes) });
    std.debug.print("  roundtrip  wasm: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.roundtrip_wasm.nsPerOp(), result.roundtrip_wasm.mibPerSec(result.write_bytes * 2) });
    std.debug.print("  roundtrip   bin: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.roundtrip_bin.nsPerOp(), result.roundtrip_bin.mibPerSec(result.write_bytes * 2) });
    std.debug.print("\n", .{});
}
