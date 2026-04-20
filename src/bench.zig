//! Benchmark harness for `zerde` versus Zig's `std.json`.
//!
//! The payload is intentionally mixed and nested so we measure the generic typed
//! walk on realistic data rather than on one dominant scalar pattern.

const std = @import("std");
const zerde = @import("zerde");

const Allocator = std.mem.Allocator;

const Region = enum {
    us_east_1,
    eu_central_1,
    ap_south_1,
};

const HttpMethod = enum {
    GET,
    POST,
    PATCH,
    DELETE,
};

const MetricKind = enum {
    counter,
    gauge,
    histogram,
};

const Severity = enum {
    info,
    warn,
    critical,
};

const Scenario = struct {
    name: []const u8,
    endpoint_count: usize,
    metric_count: usize,
    event_count: usize,
    parse_iterations: usize,
    write_iterations: usize,
};

// Fixed iterations keep successive runs comparable even when implementation speed changes.
const scenarios = [_]Scenario{
    .{
        .name = "small",
        .endpoint_count = 4,
        .metric_count = 6,
        .event_count = 8,
        .parse_iterations = 1_000_000,
        .write_iterations = 1_000_000,
    },
    .{
        .name = "medium",
        .endpoint_count = 24,
        .metric_count = 96,
        .event_count = 4_500,
        .parse_iterations = 1_000,
        .write_iterations = 1_000,
    },
    .{
        .name = "large",
        .endpoint_count = 64,
        .metric_count = 512,
        .event_count = 450_000,
        .parse_iterations = 100,
        .write_iterations = 100,
    },
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
    "slow \"db\" branch",
    "cache miss\nretry",
    "regional failover active",
};

const payload_signature = [16]u8{ 'r', 'e', 'l', 'e', 'a', 's', 'e', '-', '2', '0', '2', '6', '-', '0', '4', 'a' };
const trace_salt = [8]u8{ 's', 'a', 'l', 't', '-', '0', '0', '1' };
const event_signatures = [_][12]u8{
    [12]u8{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '1' },
    [12]u8{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '2' },
    [12]u8{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '3' },
    [12]u8{ 't', 'r', 'a', 'c', 'e', '-', '0', '0', '0', '0', '0', '4' },
};
const weight_templates = [_][4]f32{
    [4]f32{ 0.05, 0.10, 0.25, 0.60 },
    [4]f32{ 0.15, 0.20, 0.30, 0.35 },
    [4]f32{ 0.40, 0.30, 0.20, 0.10 },
};
const flag_templates = [_][4]bool{
    [4]bool{ true, false, true, false },
    [4]bool{ true, true, false, false },
    [4]bool{ false, true, true, true },
};
const sample_templates = [_][4]u16{
    [4]u16{ 120, 135, 142, 155 },
    [4]u16{ 80, 95, 90, 88 },
    [4]u16{ 210, 220, 215, 205 },
};

const Metadata = struct {
    ownerId: u64,
    shardCount: u16,
    publicUrl: []const u8,
    traceSalt: [8]u8,
    releaseName: ?[]const u8,
    hot: bool,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .publicUrl = .{ .rename = "publicURL" },
        },
    };
};

const Endpoint = struct {
    path: []const u8,
    method: HttpMethod,
    timeoutMs: u32,
    retries: ?u8,
    weights: [4]f32,
    enabled: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const Metric = struct {
    name: []const u8,
    kind: MetricKind,
    current: i64,
    peak: u64,
    ratio: f32,
    note: ?[]const u8,
    labels: [3][]const u8,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const Event = struct {
    id: u64,
    code: i32,
    ok: bool,
    severity: Severity,
    route: []const u8,
    region: Region,
    durationMicros: u32,
    cpuLoad: f32,
    signature: [12]u8,
    note: ?[]const u8,
    flags: [4]bool,
    samples: [4]u16,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const Payload = struct {
    serviceName: []const u8,
    version: u32,
    healthy: bool,
    buildNumber: i64,
    primaryRegion: Region,
    description: ?[]const u8,
    signature: [16]u8,
    metadata: Metadata,
    endpoints: []const Endpoint,
    metrics: []const Metric,
    events: []const Event,
    sampleWindows: [3]u32,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .serviceName = .{ .rename = "serviceName" },
        },
    };
};

const StdMetadata = struct {
    owner_id: u64,
    shard_count: u16,
    publicURL: []const u8,
    trace_salt: [8]u8,
    release_name: ?[]const u8,
    hot: bool,
};

const StdEndpoint = struct {
    path: []const u8,
    method: HttpMethod,
    timeout_ms: u32,
    retries: ?u8,
    weights: [4]f32,
    enabled: bool,
};

const StdMetric = struct {
    name: []const u8,
    kind: MetricKind,
    current: i64,
    peak: u64,
    ratio: f32,
    note: ?[]const u8,
    labels: [3][]const u8,
};

const StdEvent = struct {
    id: u64,
    code: i32,
    ok: bool,
    severity: Severity,
    route: []const u8,
    region: Region,
    duration_micros: u32,
    cpu_load: f32,
    signature: [12]u8,
    note: ?[]const u8,
    flags: [4]bool,
    samples: [4]u16,
};

const StdPayload = struct {
    serviceName: []const u8,
    version: u32,
    healthy: bool,
    build_number: i64,
    primary_region: Region,
    description: ?[]const u8,
    signature: [16]u8,
    metadata: StdMetadata,
    endpoints: []const StdEndpoint,
    metrics: []const StdMetric,
    events: []const StdEvent,
    sample_windows: [3]u32,
};

const BenchCase = struct {
    scenario: Scenario,
    zerde_value: Payload,
    std_value: StdPayload,
    json_out: std.Io.Writer.Allocating,

    fn json(self: *BenchCase) []const u8 {
        return self.json_out.written();
    }

    fn deinit(self: *BenchCase, allocator: Allocator) void {
        self.json_out.deinit();
        freePayload(allocator, self.zerde_value);
        freeStdPayload(allocator, self.std_value);
    }
};

const BenchStats = struct {
    iterations: usize,
    total_ns: u64,

    fn nsPerOp(self: BenchStats) f64 {
        return @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(self.iterations));
    }

    fn mibPerSec(self: BenchStats, bytes: usize) f64 {
        const total_bytes = @as(f64, @floatFromInt(bytes)) * @as(f64, @floatFromInt(self.iterations));
        const seconds = @as(f64, @floatFromInt(self.total_ns)) / @as(f64, @floatFromInt(std.time.ns_per_s));
        return (total_bytes / (1024.0 * 1024.0)) / seconds;
    }
};

const ScenarioResult = struct {
    parse_zerde: BenchStats,
    parse_std: BenchStats,
    write_zerde: BenchStats,
    write_std: BenchStats,
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = std.heap.page_allocator;

    std.debug.print("zerde JSON benchmark vs std.json\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n\n", .{});

    for (scenarios) |scenario| {
        var bench_case = try buildCase(allocator, scenario);
        defer bench_case.deinit(allocator);

        const result = try runScenario(io, &bench_case);
        printScenarioResult(bench_case.scenario, bench_case.json().len, result);
    }
}

fn buildCase(allocator: Allocator, scenario: Scenario) !BenchCase {
    const zerde_value = try makePayload(allocator, scenario);
    errdefer freePayload(allocator, zerde_value);

    const std_value = try makeStdPayload(allocator, scenario);
    errdefer freeStdPayload(allocator, std_value);

    var json_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer json_out.deinit();
    try zerde.serialize(zerde.json, &json_out.writer, zerde_value);

    return .{
        .scenario = scenario,
        .zerde_value = zerde_value,
        .std_value = std_value,
        .json_out = json_out,
    };
}

fn runScenario(io: std.Io, bench_case: *BenchCase) !ScenarioResult {
    return .{
        .parse_zerde = .{
            .iterations = bench_case.scenario.parse_iterations,
            .total_ns = try benchZerdeParse(io, bench_case.json(), bench_case.scenario.parse_iterations),
        },
        .parse_std = .{
            .iterations = bench_case.scenario.parse_iterations,
            .total_ns = try benchStdParse(io, bench_case.json(), bench_case.scenario.parse_iterations),
        },
        .write_zerde = .{
            .iterations = bench_case.scenario.write_iterations,
            .total_ns = try benchZerdeSerialize(io, bench_case.zerde_value, bench_case.scenario.write_iterations),
        },
        .write_std = .{
            .iterations = bench_case.scenario.write_iterations,
            .total_ns = try benchStdSerialize(io, bench_case.std_value, bench_case.scenario.write_iterations),
        },
    };
}

fn benchZerdeParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        // The benchmark uses the aliased-slice path because it is the JSON fast path
        // that corresponds to `std.json.parseFromSliceLeaky`.
        const value = try zerde.parseSliceAliased(zerde.json, Payload, arena.allocator(), input);
        consumePayload(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchStdParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const value = try std.json.parseFromSliceLeaky(StdPayload, arena.allocator(), input, .{
            .ignore_unknown_fields = false,
        });
        consumeStdPayload(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZerdeSerialize(io: std.Io, value: Payload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.json, &out.writer, value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchStdSerialize(io: std.Io, value: StdPayload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{}, &out.writer);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printScenarioResult(scenario: Scenario, bytes: usize, result: ScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  bytes: {d} ({d:.2} MiB)\n", .{ bytes, bytesToMiB(bytes) });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  parse  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(bytes),
    });
    std.debug.print("  parse std.json: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_std.nsPerOp(),
        result.parse_std.mibPerSec(bytes),
    });
    std.debug.print("  write  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(bytes),
    });
    std.debug.print("  write std.json: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_std.nsPerOp(),
        result.write_std.mibPerSec(bytes),
    });
    std.debug.print("\n", .{});
}

fn bytesToMiB(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn makePayload(allocator: Allocator, scenario: Scenario) !Payload {
    const endpoints = try allocator.alloc(Endpoint, scenario.endpoint_count);
    errdefer allocator.free(endpoints);
    for (endpoints, 0..) |*endpoint, i| {
        endpoint.* = .{
            .path = endpoint_paths[i % endpoint_paths.len],
            .method = switch (i % 4) {
                0 => .GET,
                1 => .POST,
                2 => .PATCH,
                else => .DELETE,
            },
            .timeoutMs = @as(u32, @intCast(25 + ((i * 7) % 1500))),
            .retries = if (i % 3 == 0) null else @as(u8, @intCast((i % 5) + 1)),
            .weights = weight_templates[i % weight_templates.len],
            .enabled = (i % 5) != 0,
        };
    }

    const metrics = try allocator.alloc(Metric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .name = metric_names[i % metric_names.len],
            .kind = switch (i % 3) {
                0 => .counter,
                1 => .gauge,
                else => .histogram,
            },
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

    const events = try allocator.alloc(Event, scenario.event_count);
    errdefer allocator.free(events);
    for (events, 0..) |*event, i| {
        event.* = .{
            .id = 10_000 + i,
            .code = @as(i32, @intCast((i % 5000))) - 2500,
            .ok = (i % 11) != 0,
            .severity = switch (i % 3) {
                0 => .info,
                1 => .warn,
                else => .critical,
            },
            .route = event_routes[i % event_routes.len],
            .region = switch (i % 3) {
                0 => .us_east_1,
                1 => .eu_central_1,
                else => .ap_south_1,
            },
            .durationMicros = @as(u32, @intCast(120 + (i % 35_000))),
            .cpuLoad = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .signature = event_signatures[i % event_signatures.len],
            .note = optional_notes[(i + 1) % optional_notes.len],
            .flags = flag_templates[i % flag_templates.len],
            .samples = sample_templates[i % sample_templates.len],
        };
    }

    return .{
        .serviceName = "edge-api",
        .version = 7,
        .healthy = true,
        .buildNumber = -42,
        .primaryRegion = .us_east_1,
        .description = "critical path\nrelease candidate",
        .signature = payload_signature,
        .metadata = .{
            .ownerId = 42,
            .shardCount = 16,
            .publicUrl = "https://api.example.com/public",
            .traceSalt = trace_salt,
            .releaseName = "2026.04-hotfix",
            .hot = true,
        },
        .endpoints = endpoints,
        .metrics = metrics,
        .events = events,
        .sampleWindows = .{ 60, 300, 900 },
    };
}

fn makeStdPayload(allocator: Allocator, scenario: Scenario) !StdPayload {
    const endpoints = try allocator.alloc(StdEndpoint, scenario.endpoint_count);
    errdefer allocator.free(endpoints);
    for (endpoints, 0..) |*endpoint, i| {
        endpoint.* = .{
            .path = endpoint_paths[i % endpoint_paths.len],
            .method = switch (i % 4) {
                0 => .GET,
                1 => .POST,
                2 => .PATCH,
                else => .DELETE,
            },
            .timeout_ms = @as(u32, @intCast(25 + ((i * 7) % 1500))),
            .retries = if (i % 3 == 0) null else @as(u8, @intCast((i % 5) + 1)),
            .weights = weight_templates[i % weight_templates.len],
            .enabled = (i % 5) != 0,
        };
    }

    const metrics = try allocator.alloc(StdMetric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .name = metric_names[i % metric_names.len],
            .kind = switch (i % 3) {
                0 => .counter,
                1 => .gauge,
                else => .histogram,
            },
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

    const events = try allocator.alloc(StdEvent, scenario.event_count);
    errdefer allocator.free(events);
    for (events, 0..) |*event, i| {
        event.* = .{
            .id = 10_000 + i,
            .code = @as(i32, @intCast((i % 5000))) - 2500,
            .ok = (i % 11) != 0,
            .severity = switch (i % 3) {
                0 => .info,
                1 => .warn,
                else => .critical,
            },
            .route = event_routes[i % event_routes.len],
            .region = switch (i % 3) {
                0 => .us_east_1,
                1 => .eu_central_1,
                else => .ap_south_1,
            },
            .duration_micros = @as(u32, @intCast(120 + (i % 35_000))),
            .cpu_load = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .signature = event_signatures[i % event_signatures.len],
            .note = optional_notes[(i + 1) % optional_notes.len],
            .flags = flag_templates[i % flag_templates.len],
            .samples = sample_templates[i % sample_templates.len],
        };
    }

    return .{
        .serviceName = "edge-api",
        .version = 7,
        .healthy = true,
        .build_number = -42,
        .primary_region = .us_east_1,
        .description = "critical path\nrelease candidate",
        .signature = payload_signature,
        .metadata = .{
            .owner_id = 42,
            .shard_count = 16,
            .publicURL = "https://api.example.com/public",
            .trace_salt = trace_salt,
            .release_name = "2026.04-hotfix",
            .hot = true,
        },
        .endpoints = endpoints,
        .metrics = metrics,
        .events = events,
        .sample_windows = .{ 60, 300, 900 },
    };
}

fn consumePayload(value: Payload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metadata.shardCount);
    std.mem.doNotOptimizeAway(value.endpoints.len);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.events.len);
}

fn consumeStdPayload(value: StdPayload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metadata.shard_count);
    std.mem.doNotOptimizeAway(value.endpoints.len);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.events.len);
}

fn freePayload(allocator: Allocator, value: Payload) void {
    allocator.free(value.endpoints);
    allocator.free(value.metrics);
    allocator.free(value.events);
}

fn freeStdPayload(allocator: Allocator, value: StdPayload) void {
    allocator.free(value.endpoints);
    allocator.free(value.metrics);
    allocator.free(value.events);
}
