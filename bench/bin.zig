//! Binary benchmark against bufzilla.

const std = @import("std");
const bufzilla = @import("bufzilla");
const zbench = @import("zbench");
const zerde = @import("zerde");

const Allocator = std.mem.Allocator;

const Scenario = struct {
    name: []const u8,
    endpoint_count: usize,
    metric_count: usize,
    event_count: usize,
    parse_iterations: usize,
    write_iterations: usize,
    roundtrip_iterations: usize,
};

const scenarios = [_]Scenario{
    .{ .name = "small", .endpoint_count = 4, .metric_count = 6, .event_count = 8, .parse_iterations = 1_000_000, .write_iterations = 1_000_000, .roundtrip_iterations = 1_000_000 },
    .{ .name = "medium", .endpoint_count = 24, .metric_count = 96, .event_count = 4_500, .parse_iterations = 1_000, .write_iterations = 1_000, .roundtrip_iterations = 1_000 },
    .{ .name = "large", .endpoint_count = 64, .metric_count = 512, .event_count = 450_000, .parse_iterations = 100, .write_iterations = 100, .roundtrip_iterations = 100 },
};

const endpoint_paths = [_][]const u8{
    "/v1/users",
    "/v1/users/:id",
    "/v1/teams",
    "/v1/teams/:id",
    "/internal/cache/flush",
    "/internal/reindex",
};

const metric_names = [_][]const u8{
    "requests_total",
    "latency_p99",
    "db_pool_in_use",
    "queue_depth",
    "cache_hit_ratio",
    "bytes_sent_total",
};

const label_pool = [_][]const u8{
    "env:prod",
    "region:us-east-1",
    "region:eu-central-1",
    "region:ap-south-1",
    "tier:frontend",
    "tier:backend",
    "team:core-platform",
    "rollout:blue",
};

const event_routes = [_][]const u8{
    "/v1/users",
    "/v1/teams",
    "/internal/reindex",
    "/v1/checkout",
    "/v1/reports",
    "/v1/search",
};

const optional_notes = [_]?[]const u8{
    null,
    "steady state",
    "slow db branch",
    "cache miss retry",
    "regional failover active",
};

const payload_signature = [16]u8{ 'r', 'e', 'l', 'e', 'a', 's', 'e', '-', '2', '0', '2', '6', '-', '0', '4', 'a' };
const trace_salt = [8]u8{ 's', 'a', 'l', 't', '-', '0', '0', '1' };
const event_signatures = [_][12]u8{
    .{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '1' },
    .{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '2' },
    .{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '3' },
    .{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '4' },
};
const weight_templates = [_][4]f32{
    .{ 0.05, 0.10, 0.25, 0.60 },
    .{ 0.15, 0.20, 0.30, 0.35 },
    .{ 0.40, 0.30, 0.20, 0.10 },
};
const flag_templates = [_][4]bool{
    .{ true, false, true, false },
    .{ true, true, false, false },
    .{ false, true, true, true },
};
const sample_templates = [_][4]u16{
    .{ 120, 135, 142, 155 },
    .{ 80, 95, 90, 88 },
    .{ 210, 220, 215, 205 },
};
const sample_windows = [3]u32{ 60, 300, 900 };

const BinMetadata = struct {
    owner_id: u64,
    shard_count: u16,
    public_url: []const u8,
    trace_salt: [8]u8,
    release_name: ?[]const u8,
    hot: bool,
};

const BinEndpoint = struct {
    path: []const u8,
    method: u8,
    timeout_ms: u32,
    retries: ?u8,
    weights: [4]f32,
    enabled: bool,
};

const BinMetric = struct {
    name: []const u8,
    kind: u8,
    current: i64,
    peak: u64,
    ratio: f32,
    note: ?[]const u8,
    labels: [3][]const u8,
};

const BinEvent = struct {
    id: u64,
    code: i32,
    ok: bool,
    severity: u8,
    route: []const u8,
    region: u8,
    duration_micros: u32,
    cpu_load: f32,
    signature: [12]u8,
    note: ?[]const u8,
    flags: [4]bool,
    samples: [4]u16,
};

const BinPayload = struct {
    service_name: []const u8,
    version: u32,
    healthy: bool,
    build_number: i64,
    primary_region: u8,
    description: ?[]const u8,
    signature: [16]u8,
    metadata: BinMetadata,
    endpoints: []const BinEndpoint,
    metrics: []const BinMetric,
    events: []const BinEvent,
    sample_windows: [3]u32,
};

const BenchStats = struct {
    iterations: usize,
    mean_ns: f64,

    fn nsPerOp(self: BenchStats) f64 {
        return self.mean_ns;
    }

    fn mibPerSec(self: BenchStats, bytes: usize) f64 {
        const seconds = self.mean_ns / std.time.ns_per_s;
        return if (seconds == 0) 0 else bytesToMiB(bytes) / seconds;
    }
};

const BinScenarioResult = struct {
    zerde_parse_bytes: usize,
    bufzilla_parse_bytes: usize,
    zerde_write_bytes: usize,
    bufzilla_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_bufzilla: BenchStats,
    write_zerde: BenchStats,
    write_bufzilla: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_bufzilla: BenchStats,
};

pub fn run(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde binary benchmark vs bufzilla\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: parse measures each library against its own binary encoding because the formats are different\n\n", .{});

    for (scenarios) |scenario| {
        const result = try runScenario(io, allocator, scenario);
        printScenarioResult(scenario, result);
    }

    std.debug.print("\n", .{});
}

fn runScenario(io: std.Io, allocator: Allocator, scenario: Scenario) !BinScenarioResult {
    const ZerdeParse = struct {
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
            const value = zerde.parseSliceAliased(zerde.bin, BinPayload, self.arena.allocator(), self.input) catch @panic("zerde binary parse failed");
            consumePayload(value);
        }
    };

    const BufzillaParse = struct {
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
            const value = decodeBufzilla(BinPayload, self.arena.allocator(), self.input) catch @panic("bufzilla parse failed");
            consumePayload(value);
        }
    };

    const ZerdeSerialize = struct {
        value: BinPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: BinPayload) @This() {
            return .{
                .value = value,
                .out = .init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            self.out.clearRetainingCapacity();
            zerde.serialize(zerde.bin, &self.out.writer, self.value) catch @panic("zerde binary serialize failed");
        }
    };

    const BufzillaSerialize = struct {
        value: BinPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: BinPayload) @This() {
            return .{
                .value = value,
                .out = .init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            self.out.clearRetainingCapacity();
            var writer = bufzilla.Writer.init(&self.out.writer);
            writer.writeAny(self.value) catch @panic("bufzilla serialize failed");
        }
    };

    const ZerdeRoundTrip = struct {
        value: BinPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: BinPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serialize(zerde.bin, &self.out.writer, self.value);
            const check = try zerde.parseSliceAliased(zerde.bin, BinPayload, self.arena.allocator(), self.out.written());
            try std.testing.expectEqualDeep(self.value, check);
            _ = self.arena.reset(.retain_capacity);
            self.out.clearRetainingCapacity();
            return self;
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            self.out.clearRetainingCapacity();
            zerde.serialize(zerde.bin, &self.out.writer, self.value) catch @panic("zerde binary roundtrip serialize failed");
            const parsed = zerde.parseSliceAliased(zerde.bin, BinPayload, self.arena.allocator(), self.out.written()) catch @panic("zerde binary roundtrip parse failed");
            consumePayload(parsed);
        }
    };

    const BufzillaRoundTrip = struct {
        value: BinPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: BinPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            var writer = bufzilla.Writer.init(&self.out.writer);
            try writer.writeAny(self.value);
            const check = try decodeBufzilla(BinPayload, self.arena.allocator(), self.out.written());
            try std.testing.expectEqualDeep(self.value, check);
            _ = self.arena.reset(.retain_capacity);
            self.out.clearRetainingCapacity();
            return self;
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
            self.arena.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            _ = self.arena.reset(.retain_capacity);
            self.out.clearRetainingCapacity();
            var writer = bufzilla.Writer.init(&self.out.writer);
            writer.writeAny(self.value) catch @panic("bufzilla roundtrip serialize failed");
            const parsed = decodeBufzilla(BinPayload, self.arena.allocator(), self.out.written()) catch @panic("bufzilla roundtrip parse failed");
            consumePayload(parsed);
        }
    };

    const value = try makePayload(allocator, scenario);
    defer freePayload(allocator, value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serialize(zerde.bin, &zerde_out.writer, value);

    var bufzilla_out: std.Io.Writer.Allocating = .init(allocator);
    defer bufzilla_out.deinit();
    var bufzilla_writer = bufzilla.Writer.init(&bufzilla_out.writer);
    try bufzilla_writer.writeAny(value);

    var parse_zerde = ZerdeParse.init(zerde_out.written());
    defer parse_zerde.deinit();
    var parse_bufzilla = BufzillaParse.init(bufzilla_out.written());
    defer parse_bufzilla.deinit();
    var write_zerde = ZerdeSerialize.init(value);
    defer write_zerde.deinit();
    var write_bufzilla = BufzillaSerialize.init(value);
    defer write_bufzilla.deinit();
    var roundtrip_zerde = try ZerdeRoundTrip.init(value);
    defer roundtrip_zerde.deinit();
    var roundtrip_bufzilla = try BufzillaRoundTrip.init(value);
    defer roundtrip_bufzilla.deinit();

    return .{
        .zerde_parse_bytes = zerde_out.written().len,
        .bufzilla_parse_bytes = bufzilla_out.written().len,
        .zerde_write_bytes = zerde_out.written().len,
        .bufzilla_write_bytes = bufzilla_out.written().len,
        .parse_zerde = try runZbenchParam(io, allocator, "bin parse zerde", &parse_zerde, scenario.parse_iterations),
        .parse_bufzilla = try runZbenchParam(io, allocator, "bin parse bufzilla", &parse_bufzilla, scenario.parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "bin write zerde", &write_zerde, scenario.write_iterations),
        .write_bufzilla = try runZbenchParam(io, allocator, "bin write bufzilla", &write_bufzilla, scenario.write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "bin roundtrip zerde", &roundtrip_zerde, scenario.roundtrip_iterations),
        .roundtrip_bufzilla = try runZbenchParam(io, allocator, "bin roundtrip bufzilla", &roundtrip_bufzilla, scenario.roundtrip_iterations),
    };
}

fn printScenarioResult(scenario: Scenario, result: BinScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  zerde parse bytes: {d} ({d:.2} MiB)\n", .{ result.zerde_parse_bytes, bytesToMiB(result.zerde_parse_bytes) });
    std.debug.print("  bufzilla parse bytes: {d} ({d:.2} MiB)\n", .{ result.bufzilla_parse_bytes, bytesToMiB(result.bufzilla_parse_bytes) });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{ result.zerde_write_bytes, bytesToMiB(result.zerde_write_bytes) });
    std.debug.print("  bufzilla write bytes: {d} ({d:.2} MiB)\n", .{ result.bufzilla_write_bytes, bytesToMiB(result.bufzilla_write_bytes) });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{ scenario.endpoint_count, scenario.metric_count, scenario.event_count });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.parse_zerde.nsPerOp(), result.parse_zerde.mibPerSec(result.zerde_parse_bytes) });
    std.debug.print("  parse bufzilla: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.parse_bufzilla.nsPerOp(), result.parse_bufzilla.mibPerSec(result.bufzilla_parse_bytes) });
    std.debug.print("  write  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.write_zerde.nsPerOp(), result.write_zerde.mibPerSec(result.zerde_write_bytes) });
    std.debug.print("  write bufzilla: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.write_bufzilla.nsPerOp(), result.write_bufzilla.mibPerSec(result.bufzilla_write_bytes) });
    std.debug.print("  roundtrip  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.roundtrip_zerde.nsPerOp(), result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2) });
    std.debug.print("  roundtrip bufzilla: {d:.2} ns/op, {d:.2} MiB/s\n", .{ result.roundtrip_bufzilla.nsPerOp(), result.roundtrip_bufzilla.mibPerSec(result.bufzilla_write_bytes * 2) });
    std.debug.print("\n", .{});
}

fn benchStatsFromResult(result: zbench.Result) !BenchStats {
    const timing_stats = try zbench.statistics.Statistics(u64).init(result.readings.timings_ns);
    return .{
        .iterations = result.readings.iterations,
        .mean_ns = @as(f64, @floatFromInt(timing_stats.mean)),
    };
}

fn runZbenchParam(io: std.Io, allocator: Allocator, name: []const u8, benchmark: anytype, iterations: usize) !BenchStats {
    const BenchmarkPtr = @TypeOf(benchmark);
    const pointer_info = @typeInfo(BenchmarkPtr);
    if (pointer_info != .pointer) @compileError("benchmark context must be a pointer");
    const BenchmarkType = pointer_info.pointer.child;
    const const_benchmark: *const BenchmarkType = benchmark;

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try bench.addParam(name, const_benchmark, .{ .iterations = std.math.cast(u32, iterations) orelse return error.IntegerOverflow });
    var iter = try bench.iterator();
    while (try iter.next(io)) |step| switch (step) {
        .progress => {},
        .result => |result| {
            defer result.deinit();
            return try benchStatsFromResult(result);
        },
    };
    return error.MissingBenchmarkResult;
}

fn makePayload(allocator: Allocator, scenario: Scenario) !BinPayload {
    const endpoints = try allocator.alloc(BinEndpoint, scenario.endpoint_count);
    errdefer allocator.free(endpoints);
    for (endpoints, 0..) |*endpoint, i| {
        endpoint.* = .{
            .path = endpoint_paths[i % endpoint_paths.len],
            .method = @as(u8, @intCast(i % 4)),
            .timeout_ms = @as(u32, @intCast(25 + ((i * 7) % 1500))),
            .retries = if (i % 3 == 0) null else @as(u8, @intCast((i % 5) + 1)),
            .weights = weight_templates[i % weight_templates.len],
            .enabled = (i % 5) != 0,
        };
    }

    const metrics = try allocator.alloc(BinMetric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .name = metric_names[i % metric_names.len],
            .kind = @as(u8, @intCast(i % 3)),
            .current = @as(i64, @intCast((i % 40_000))) - 20_000,
            .peak = @as(u64, @intCast(100_000 + (i % 4_000_000))),
            .ratio = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .note = optional_notes[i % optional_notes.len],
            .labels = .{
                label_pool[i % label_pool.len],
                label_pool[(i + 1) % label_pool.len],
                label_pool[(i + 2) % label_pool.len],
            },
        };
    }

    const events = try allocator.alloc(BinEvent, scenario.event_count);
    errdefer allocator.free(events);
    for (events, 0..) |*event, i| {
        event.* = .{
            .id = 10_000 + i,
            .code = @as(i32, @intCast((i % 5000))) - 2500,
            .ok = (i % 11) != 0,
            .severity = @as(u8, @intCast(i % 3)),
            .route = event_routes[i % event_routes.len],
            .region = @as(u8, @intCast(i % 3)),
            .duration_micros = @as(u32, @intCast(120 + (i % 35_000))),
            .cpu_load = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .signature = event_signatures[i % event_signatures.len],
            .note = optional_notes[(i + 1) % optional_notes.len],
            .flags = flag_templates[i % flag_templates.len],
            .samples = sample_templates[i % sample_templates.len],
        };
    }

    return .{
        .service_name = "edge-api",
        .version = 7,
        .healthy = true,
        .build_number = -42,
        .primary_region = 0,
        .description = "critical path release candidate",
        .signature = payload_signature,
        .metadata = .{
            .owner_id = 42,
            .shard_count = 16,
            .public_url = "https://api.example.com/public",
            .trace_salt = trace_salt,
            .release_name = "2026.04-hotfix",
            .hot = true,
        },
        .endpoints = endpoints,
        .metrics = metrics,
        .events = events,
        .sample_windows = sample_windows,
    };
}

fn freePayload(allocator: Allocator, value: BinPayload) void {
    allocator.free(value.endpoints);
    allocator.free(value.metrics);
    allocator.free(value.events);
}

fn consumePayload(value: BinPayload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metadata.shard_count);
    std.mem.doNotOptimizeAway(value.endpoints.len);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.events.len);
}

fn decodeBufzilla(comptime T: type, allocator: Allocator, input: []const u8) !T {
    var reader = bufzilla.Reader(.{}).init(input);
    const value = try decodeBufzillaFromValue(T, allocator, &reader, try reader.read());
    if (reader.pos != input.len) return error.TrailingCharacters;
    return value;
}

fn decodeBufzillaFromValue(comptime T: type, allocator: Allocator, reader: anytype, current: bufzilla.Value) !T {
    return switch (@typeInfo(T)) {
        .bool => try expectBufBool(current),
        .int, .comptime_int => try castBufInt(T, current),
        .float, .comptime_float => try castBufFloat(T, current),
        .optional => |info| if (tagOf(current) == .null) null else try decodeBufzillaFromValue(info.child, allocator, reader, current),
        .pointer => |info| switch (info.size) {
            .slice => if (info.child == u8)
                try expectBufBytes(current)
            else
                try decodeBufzillaSlice(T, info.child, allocator, reader, current),
            else => error.UnsupportedType,
        },
        .array => |info| try decodeBufzillaArray(T, info, allocator, reader, current),
        .@"struct" => |info| try decodeBufzillaStruct(T, info, allocator, reader, current),
        else => error.UnsupportedType,
    };
}

fn decodeBufzillaSlice(comptime T: type, comptime Child: type, allocator: Allocator, reader: anytype, current: bufzilla.Value) !T {
    if (tagOf(current) != .array) return error.UnexpectedType;

    var items: std.ArrayList(Child) = .empty;
    errdefer {
        for (items.items) |item| freeDecodedValue(Child, allocator, item);
        items.deinit(allocator);
    }

    while (true) {
        const next = try reader.read();
        if (tagOf(next) == .containerEnd) break;
        try items.append(allocator, try decodeBufzillaFromValue(Child, allocator, reader, next));
    }

    return items.toOwnedSlice(allocator);
}

fn decodeBufzillaArray(
    comptime T: type,
    comptime info: std.builtin.Type.Array,
    allocator: Allocator,
    reader: anytype,
    current: bufzilla.Value,
) !T {
    if (info.child == u8 and tagOf(current) == .bytes) {
        const bytes = try expectBufBytes(current);
        if (bytes.len != info.len) return error.LengthMismatch;
        var result: T = undefined;
        @memcpy(result[0..], bytes);
        return result;
    }

    if (tagOf(current) != .array) return error.UnexpectedType;

    var result: T = undefined;
    var index: usize = 0;
    while (true) {
        const next = try reader.read();
        if (tagOf(next) == .containerEnd) break;
        if (index >= info.len) return error.LengthMismatch;
        result[index] = try decodeBufzillaFromValue(info.child, allocator, reader, next);
        index += 1;
    }

    if (index != info.len) return error.LengthMismatch;
    return result;
}

fn decodeBufzillaStruct(
    comptime T: type,
    comptime info: std.builtin.Type.Struct,
    allocator: Allocator,
    reader: anytype,
    current: bufzilla.Value,
) !T {
    if (tagOf(current) != .object) return error.UnexpectedType;

    var result: T = undefined;
    var seen: [info.fields.len]bool = [_]bool{false} ** info.fields.len;
    errdefer freePartialDecodedStruct(T, allocator, &result, &seen);

    while (true) {
        const key_value = try reader.read();
        if (tagOf(key_value) == .containerEnd) break;
        const key = try expectBufBytes(key_value);
        const value = try reader.read();

        var matched = false;
        inline for (info.fields, 0..) |field, i| {
            if (std.mem.eql(u8, key, field.name)) {
                @field(result, field.name) = try decodeBufzillaFromValue(field.type, allocator, reader, value);
                seen[i] = true;
                matched = true;
                break;
            }
        }

        if (!matched) try skipBufzillaCurrent(reader, value);
    }

    inline for (info.fields, 0..) |_, i| {
        if (!seen[i]) return error.MissingField;
    }
    return result;
}

fn skipBufzillaCurrent(reader: anytype, current: bufzilla.Value) !void {
    switch (tagOf(current)) {
        .object => {
            while (true) {
                const key = try reader.read();
                if (tagOf(key) == .containerEnd) break;
                const value = try reader.read();
                try skipBufzillaCurrent(reader, value);
            }
        },
        .array => {
            while (true) {
                const item = try reader.read();
                if (tagOf(item) == .containerEnd) break;
                try skipBufzillaCurrent(reader, item);
            }
        },
        else => {},
    }
}

fn expectBufBool(value: bufzilla.Value) !bool {
    return switch (value) {
        .bool => |v| v,
        else => error.UnexpectedType,
    };
}

fn expectBufBytes(value: bufzilla.Value) ![]const u8 {
    return switch (value) {
        .bytes => |bytes| bytes,
        else => error.UnexpectedType,
    };
}

fn castBufInt(comptime T: type, value: bufzilla.Value) !T {
    return switch (value) {
        .u64 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .u32 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .u16 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .u8 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .i64 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .i32 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .i16 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        .i8 => |v| std.math.cast(T, v) orelse error.IntegerOverflow,
        else => error.UnexpectedType,
    };
}

fn castBufFloat(comptime T: type, value: bufzilla.Value) !T {
    return switch (value) {
        .f64 => |v| @as(T, @floatCast(v)),
        .f32 => |v| @as(T, @floatCast(v)),
        .f16 => |v| @as(T, @floatCast(v)),
        .u64 => |v| @as(T, @floatFromInt(v)),
        .i64 => |v| @as(T, @floatFromInt(v)),
        else => error.UnexpectedType,
    };
}

fn freeDecodedValue(comptime T: type, allocator: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float => {},
        .optional => if (value) |child| freeDecodedValue(@TypeOf(child), allocator, child),
        .array => |info| {
            if (info.child == u8) return;
            for (value) |item| freeDecodedValue(info.child, allocator, item);
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child != u8) {
                    for (value) |item| freeDecodedValue(info.child, allocator, item);
                }
                allocator.free(value);
            },
            else => {},
        },
        .@"struct" => |info| inline for (info.fields) |field| freeDecodedValue(field.type, allocator, @field(value, field.name)),
        else => {},
    }
}

fn freePartialDecodedStruct(comptime T: type, allocator: Allocator, result: *T, seen: *[@typeInfo(T).@"struct".fields.len]bool) void {
    inline for (@typeInfo(T).@"struct".fields, 0..) |field, i| {
        if (seen[i]) freeDecodedValue(field.type, allocator, @field(result.*, field.name));
    }
}

fn tagOf(value: bufzilla.Value) std.meta.Tag(bufzilla.Value) {
    return std.meta.activeTag(value);
}

fn bytesToMiB(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}
