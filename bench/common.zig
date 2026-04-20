//! Shared benchmark helpers and workloads for `zerde` format benchmarks.
//!
//! The payloads are intentionally mixed and nested so we measure the generic
//! typed walk on realistic data rather than on one dominant scalar pattern.

const std = @import("std");
const zerde = @import("zerde");
const zig_toml = @import("zig_toml");

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

const toml_notes = [_][]const u8{
    "steady state",
    "slow \"db\" branch",
    "cache miss\nretry",
    "regional failover active",
};

const TomlMetadata = struct {
    owner_id: u64,
    shard_count: u16,
    public_url: []const u8,
    trace_salt: []const u8,
    release_name: ?[]const u8,
    hot: bool,
};

fn TomlEndpointColumns(comptime endpoint_count: usize) type {
    return struct {
        paths: *const [endpoint_count][]const u8,
        methods: *const [endpoint_count]HttpMethod,
        timeout_ms: *const [endpoint_count]u32,
        retries: *const [endpoint_count]u8,
        weights: *const [endpoint_count][4]f32,
        enabled: *const [endpoint_count]bool,
    };
}

fn TomlMetricColumns(comptime metric_count: usize) type {
    return struct {
        names: *const [metric_count][]const u8,
        kinds: *const [metric_count]MetricKind,
        current: *const [metric_count]i64,
        peak: *const [metric_count]u64,
        ratio: *const [metric_count]f32,
        notes: *const [metric_count][]const u8,
        labels: *const [metric_count][3][]const u8,
    };
}

fn TomlEventColumns(comptime event_count: usize) type {
    return struct {
        ids: *const [event_count]u64,
        codes: *const [event_count]i32,
        ok: *const [event_count]bool,
        severity: *const [event_count]Severity,
        routes: *const [event_count][]const u8,
        region: *const [event_count]Region,
        duration_micros: *const [event_count]u32,
        cpu_load: *const [event_count]f32,
        signatures: *const [event_count][]const u8,
        notes: *const [event_count][]const u8,
        flags: *const [event_count][4]bool,
        samples: *const [event_count][4]u16,
    };
}

fn TomlPayload(comptime endpoint_count: usize, comptime metric_count: usize, comptime event_count: usize) type {
    return struct {
        service_name: []const u8,
        version: u32,
        healthy: bool,
        build_number: i64,
        primary_region: Region,
        description: ?[]const u8,
        signature: []const u8,
        metadata: TomlMetadata,
        endpoints: TomlEndpointColumns(endpoint_count),
        metrics: TomlMetricColumns(metric_count),
        events: TomlEventColumns(event_count),
        sample_windows: [3]u32,
    };
}

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

const TomlScenarioResult = struct {
    zerde_bytes: usize,
    zig_toml_bytes: usize,
    write_zerde: BenchStats,
    write_zig_toml: BenchStats,
};

pub fn runAll(io: std.Io, allocator: Allocator) !void {
    try runJsonBench(io, allocator);
    try runTomlBench(io, allocator);
}

pub fn runJsonBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde JSON benchmark vs std.json\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n\n", .{});

    for (scenarios) |scenario| {
        var bench_case = try buildCase(allocator, scenario);
        defer bench_case.deinit(allocator);

        const result = try runScenario(io, &bench_case);
        printScenarioResult(bench_case.scenario, bench_case.json().len, result);
    }

    std.debug.print("\n", .{});
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

pub fn runTomlBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde TOML benchmark vs zig-toml\n", .{});
    std.debug.print("scenarios: small, medium, large\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("note: serialize-only for now; zerde does not implement TOML deserialize yet\n\n", .{});

    inline for (scenarios) |scenario| {
        const result = try runTomlScenario(
            scenario.endpoint_count,
            scenario.metric_count,
            scenario.event_count,
            scenario.write_iterations,
            io,
            allocator,
        );
        printTomlScenarioResult(scenario, result);
    }
}

fn runTomlScenario(
    comptime endpoint_count: usize,
    comptime metric_count: usize,
    comptime event_count: usize,
    write_iterations: usize,
    io: std.Io,
    allocator: Allocator,
) !TomlScenarioResult {
    const value = try makeTomlPayload(endpoint_count, metric_count, event_count, allocator);
    defer freeTomlPayload(allocator, value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serialize(zerde.toml, &zerde_out.writer, value);

    var zig_toml_out: std.Io.Writer.Allocating = .init(allocator);
    defer zig_toml_out.deinit();
    try zig_toml.serialize(allocator, value, &zig_toml_out.writer);

    return .{
        .zerde_bytes = zerde_out.written().len,
        .zig_toml_bytes = zig_toml_out.written().len,
        .write_zerde = .{
            .iterations = write_iterations,
            .total_ns = try benchTomlZerdeSerialize(io, value, write_iterations),
        },
        .write_zig_toml = .{
            .iterations = write_iterations,
            .total_ns = try benchZigTomlSerialize(io, allocator, value, write_iterations),
        },
    };
}

fn benchTomlZerdeSerialize(io: std.Io, value: anytype, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.toml, &out.writer, value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigTomlSerialize(io: std.Io, allocator: Allocator, value: anytype, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zig_toml.serialize(allocator, value, &out.writer);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printTomlScenarioResult(comptime scenario: Scenario, result: TomlScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  zerde bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_bytes,
        bytesToMiB(result.zerde_bytes),
    });
    std.debug.print("  zig-toml bytes: {d} ({d:.2} MiB)\n", .{
        result.zig_toml_bytes,
        bytesToMiB(result.zig_toml_bytes),
    });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  write    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_bytes),
    });
    std.debug.print("  write zig-toml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zig_toml.nsPerOp(),
        result.write_zig_toml.mibPerSec(result.zig_toml_bytes),
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

fn makeTomlPayload(
    comptime endpoint_count: usize,
    comptime metric_count: usize,
    comptime event_count: usize,
    allocator: Allocator,
) !*TomlPayload(endpoint_count, metric_count, event_count) {
    const PayloadType = TomlPayload(endpoint_count, metric_count, event_count);
    const value = try allocator.create(PayloadType);
    errdefer allocator.destroy(value);

    const endpoint_paths_array = try allocator.create([endpoint_count][]const u8);
    errdefer allocator.destroy(endpoint_paths_array);
    const endpoint_methods = try allocator.create([endpoint_count]HttpMethod);
    errdefer allocator.destroy(endpoint_methods);
    const endpoint_timeout_ms = try allocator.create([endpoint_count]u32);
    errdefer allocator.destroy(endpoint_timeout_ms);
    const endpoint_retries = try allocator.create([endpoint_count]u8);
    errdefer allocator.destroy(endpoint_retries);
    const endpoint_weights = try allocator.create([endpoint_count][4]f32);
    errdefer allocator.destroy(endpoint_weights);
    const endpoint_enabled = try allocator.create([endpoint_count]bool);
    errdefer allocator.destroy(endpoint_enabled);

    const metric_names_array = try allocator.create([metric_count][]const u8);
    errdefer allocator.destroy(metric_names_array);
    const metric_kinds = try allocator.create([metric_count]MetricKind);
    errdefer allocator.destroy(metric_kinds);
    const metric_current = try allocator.create([metric_count]i64);
    errdefer allocator.destroy(metric_current);
    const metric_peak = try allocator.create([metric_count]u64);
    errdefer allocator.destroy(metric_peak);
    const metric_ratio = try allocator.create([metric_count]f32);
    errdefer allocator.destroy(metric_ratio);
    const metric_notes = try allocator.create([metric_count][]const u8);
    errdefer allocator.destroy(metric_notes);
    const metric_labels = try allocator.create([metric_count][3][]const u8);
    errdefer allocator.destroy(metric_labels);

    const event_ids = try allocator.create([event_count]u64);
    errdefer allocator.destroy(event_ids);
    const event_codes = try allocator.create([event_count]i32);
    errdefer allocator.destroy(event_codes);
    const event_ok = try allocator.create([event_count]bool);
    errdefer allocator.destroy(event_ok);
    const event_severity = try allocator.create([event_count]Severity);
    errdefer allocator.destroy(event_severity);
    const event_routes_array = try allocator.create([event_count][]const u8);
    errdefer allocator.destroy(event_routes_array);
    const event_region = try allocator.create([event_count]Region);
    errdefer allocator.destroy(event_region);
    const event_duration_micros = try allocator.create([event_count]u32);
    errdefer allocator.destroy(event_duration_micros);
    const event_cpu_load = try allocator.create([event_count]f32);
    errdefer allocator.destroy(event_cpu_load);
    const event_signatures_array = try allocator.create([event_count][]const u8);
    errdefer allocator.destroy(event_signatures_array);
    const event_notes = try allocator.create([event_count][]const u8);
    errdefer allocator.destroy(event_notes);
    const event_flags = try allocator.create([event_count][4]bool);
    errdefer allocator.destroy(event_flags);
    const event_samples = try allocator.create([event_count][4]u16);
    errdefer allocator.destroy(event_samples);

    for (endpoint_paths_array, 0..) |*path, i| {
        path.* = endpoint_paths[i % endpoint_paths.len];
        endpoint_methods[i] = switch (i % 4) {
            0 => .GET,
            1 => .POST,
            2 => .PATCH,
            else => .DELETE,
        };
        endpoint_timeout_ms[i] = @as(u32, @intCast(25 + ((i * 7) % 1500)));
        endpoint_retries[i] = @as(u8, @intCast((i % 5) + 1));
        endpoint_weights[i] = weight_templates[i % weight_templates.len];
        endpoint_enabled[i] = (i % 5) != 0;
    }

    for (metric_names_array, 0..) |*name, i| {
        name.* = metric_names[i % metric_names.len];
        metric_kinds[i] = switch (i % 3) {
            0 => .counter,
            1 => .gauge,
            else => .histogram,
        };
        metric_current[i] = @as(i64, @intCast((i % 40_000))) - 20_000;
        metric_peak[i] = @as(u64, @intCast(100_000 + (i % 4_000_000)));
        metric_ratio[i] = @as(f32, @floatFromInt(i % 1000)) / 1000.0;
        metric_notes[i] = toml_notes[i % toml_notes.len];
        metric_labels[i] = .{
            label_pool[i % label_pool.len],
            label_pool[(i + 1) % label_pool.len],
            label_pool[(i + 2) % label_pool.len],
        };
    }

    for (event_ids, 0..) |*id, i| {
        id.* = 10_000 + i;
        event_codes[i] = @as(i32, @intCast((i % 5000))) - 2500;
        event_ok[i] = (i % 11) != 0;
        event_severity[i] = switch (i % 3) {
            0 => .info,
            1 => .warn,
            else => .critical,
        };
        event_routes_array[i] = event_routes[i % event_routes.len];
        event_region[i] = switch (i % 3) {
            0 => .us_east_1,
            1 => .eu_central_1,
            else => .ap_south_1,
        };
        event_duration_micros[i] = @as(u32, @intCast(120 + (i % 35_000)));
        event_cpu_load[i] = @as(f32, @floatFromInt(i % 1000)) / 1000.0;
        event_signatures_array[i] = metric_names[i % metric_names.len];
        event_notes[i] = toml_notes[(i + 1) % toml_notes.len];
        event_flags[i] = flag_templates[i % flag_templates.len];
        event_samples[i] = sample_templates[i % sample_templates.len];
    }

    value.* = .{
        .service_name = "edge-api",
        .version = 7,
        .healthy = true,
        .build_number = -42,
        .primary_region = .us_east_1,
        .description = "critical path\nrelease candidate",
        .signature = "release-2026-04a",
        .metadata = .{
            .owner_id = 42,
            .shard_count = 16,
            .public_url = "https://api.example.com/public",
            .trace_salt = "salt-001",
            .release_name = "2026.04-hotfix",
            .hot = true,
        },
        .endpoints = .{
            .paths = endpoint_paths_array,
            .methods = endpoint_methods,
            .timeout_ms = endpoint_timeout_ms,
            .retries = endpoint_retries,
            .weights = endpoint_weights,
            .enabled = endpoint_enabled,
        },
        .metrics = .{
            .names = metric_names_array,
            .kinds = metric_kinds,
            .current = metric_current,
            .peak = metric_peak,
            .ratio = metric_ratio,
            .notes = metric_notes,
            .labels = metric_labels,
        },
        .events = .{
            .ids = event_ids,
            .codes = event_codes,
            .ok = event_ok,
            .severity = event_severity,
            .routes = event_routes_array,
            .region = event_region,
            .duration_micros = event_duration_micros,
            .cpu_load = event_cpu_load,
            .signatures = event_signatures_array,
            .notes = event_notes,
            .flags = event_flags,
            .samples = event_samples,
        },
        .sample_windows = .{ 60, 300, 900 },
    };

    return value;
}

fn freeTomlPayload(allocator: Allocator, value: anytype) void {
    allocator.destroy(value.events.samples);
    allocator.destroy(value.events.flags);
    allocator.destroy(value.events.notes);
    allocator.destroy(value.events.signatures);
    allocator.destroy(value.events.cpu_load);
    allocator.destroy(value.events.duration_micros);
    allocator.destroy(value.events.region);
    allocator.destroy(value.events.routes);
    allocator.destroy(value.events.severity);
    allocator.destroy(value.events.ok);
    allocator.destroy(value.events.codes);
    allocator.destroy(value.events.ids);

    allocator.destroy(value.metrics.labels);
    allocator.destroy(value.metrics.notes);
    allocator.destroy(value.metrics.ratio);
    allocator.destroy(value.metrics.peak);
    allocator.destroy(value.metrics.current);
    allocator.destroy(value.metrics.kinds);
    allocator.destroy(value.metrics.names);

    allocator.destroy(value.endpoints.enabled);
    allocator.destroy(value.endpoints.weights);
    allocator.destroy(value.endpoints.retries);
    allocator.destroy(value.endpoints.timeout_ms);
    allocator.destroy(value.endpoints.methods);
    allocator.destroy(value.endpoints.paths);

    allocator.destroy(value);
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
