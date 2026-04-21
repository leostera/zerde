//! Shared benchmark helpers and workloads for `zerde` format benchmarks.
//!
//! The payloads are intentionally mixed and nested so we measure the generic
//! typed walk on realistic data rather than on one dominant scalar pattern.

const std = @import("std");
const zerde = @import("zerde");
const zig_bson = @import("zig_bson");
const zig_toml = @import("zig_toml");
const zig_yaml = @import("zig_yaml");
const zbench = @import("zbench");
const zbor = @import("zbor");

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
    roundtrip_iterations: usize,
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
        .roundtrip_iterations = 1_000_000,
    },
    .{
        .name = "medium",
        .endpoint_count = 24,
        .metric_count = 96,
        .event_count = 4_500,
        .parse_iterations = 1_000,
        .write_iterations = 1_000,
        .roundtrip_iterations = 1_000,
    },
    .{
        .name = "large",
        .endpoint_count = 64,
        .metric_count = 512,
        .event_count = 450_000,
        .parse_iterations = 100,
        .write_iterations = 100,
        .roundtrip_iterations = 100,
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

const ZborPayload = StdPayload;

const BsonMetadata = struct {
    owner_id: i32,
    shard_count: i32,
    publicURL: []const u8,
    trace_salt: []const u8,
    release_name: ?[]const u8,
    hot: bool,
};

const BsonEndpoint = struct {
    path: []const u8,
    method: HttpMethod,
    timeout_ms: i32,
    retries: ?i32,
    weights: [4]f32,
    enabled: bool,
};

const BsonMetric = struct {
    name: []const u8,
    kind: MetricKind,
    current: i32,
    peak: i32,
    ratio: f32,
    note: ?[]const u8,
    labels: [3][]const u8,
};

const BsonEvent = struct {
    id: i32,
    code: i32,
    ok: bool,
    severity: Severity,
    route: []const u8,
    region: Region,
    duration_micros: i32,
    cpu_load: f32,
    signature: []const u8,
    note: ?[]const u8,
    flags: [4]bool,
    samples: [4]i32,
};

const BsonPayload = struct {
    serviceName: []const u8,
    version: i32,
    healthy: bool,
    build_number: i32,
    primary_region: Region,
    description: ?[]const u8,
    signature: []const u8,
    metadata: BsonMetadata,
    endpoints: []const BsonEndpoint,
    metrics: []const BsonMetric,
    events: []const BsonEvent,
    sample_windows: [3]i32,
};

const toml_notes = [_][]const u8{
    "steady state",
    "slow database branch",
    "cache miss retry",
    "regional failover active",
};

const island_pool = [_][]const u8{
    "foosha-village",
    "orange-town",
    "loguetown",
    "alabasta",
    "water-seven",
    "sabaody",
    "wano",
    "egghead",
    "elbaf",
};

const yaml_notes = [_]?[]const u8{
    null,
    "luffy-on-watch",
    "zoro-took-wrong-turn",
    "nami-updated-log-pose",
    "sanji-restocked-galley",
};

const crew_tags = [_][]const u8{
    "crew-straw-hat",
    "ally-heart",
    "ally-mink",
    "sea-grand-line",
    "sea-new-world",
    "ship-sunny",
    "mission-scout",
    "mission-supply",
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
        retries: *const [endpoint_count]u16,
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

const TomlParseEndpointColumns = struct {
    paths: []const []const u8,
    methods: []const HttpMethod,
    timeout_ms: []const u32,
    retries: []const u16,
    weights: []const [4]f32,
    enabled: []const bool,
};

const TomlParseMetricColumns = struct {
    names: []const []const u8,
    kinds: []const MetricKind,
    current: []const i64,
    peak: []const u64,
    ratio: []const f32,
    notes: []const []const u8,
    labels: []const [3][]const u8,
};

const TomlParseEventColumns = struct {
    ids: []const u64,
    codes: []const i32,
    ok: []const bool,
    severity: []const Severity,
    routes: []const []const u8,
    region: []const Region,
    duration_micros: []const u32,
    cpu_load: []const f32,
    signatures: []const []const u8,
    notes: []const []const u8,
    flags: []const [4]bool,
    samples: []const [4]u16,
};

const TomlParsePayload = struct {
    service_name: []const u8,
    version: u32,
    healthy: bool,
    build_number: i64,
    primary_region: Region,
    description: ?[]const u8,
    signature: []const u8,
    metadata: TomlMetadata,
    endpoints: TomlParseEndpointColumns,
    metrics: TomlParseMetricColumns,
    events: TomlParseEventColumns,
    sample_windows: [3]u32,
};

const Sea = enum {
    east_blue,
    grand_line,
    new_world,
};

const VoyageRole = enum {
    scout,
    supply,
    escort,
    rescue,
};

const Threat = enum {
    calm,
    storm,
    emperor,
};

const LedgerKind = enum {
    bounty,
    cola,
    supplies,
};

const YamlMetadata = struct {
    captain_id: u64,
    deck_count: u16,
    flagship_name: []const u8,
    eternal_pose: []const u8,
    alliance_name: ?[]const u8,
    coup_de_burst_ready: bool,
};

const YamlRoute = struct {
    island_name: []const u8,
    mission: VoyageRole,
    eta_hours: u32,
    reroutes: ?u8,
    wind_bias: [4]f32,
    secured: bool,
};

const YamlLedger = struct {
    name: []const u8,
    kind: LedgerKind,
    current: i64,
    peak: u64,
    ratio: f32,
    note: ?[]const u8,
    tags: [3][]const u8,
};

const YamlLog = struct {
    id: u64,
    code: i32,
    cleared: bool,
    threat: Threat,
    route: []const u8,
    sea: Sea,
    duration_minutes: u32,
    wind_load: f32,
    note: ?[]const u8,
    flags: [4]bool,
    samples: [4]u16,
};

const YamlPayload = struct {
    ship_name: []const u8,
    voyage_no: u32,
    ready_for_new_world: bool,
    bounty_delta: i64,
    home_sea: Sea,
    crew_note: ?[]const u8,
    metadata: YamlMetadata,
    routes: []const YamlRoute,
    ledgers: []const YamlLedger,
    logs: []const YamlLog,
    checkpoint_hours: [3]u32,
};

const BenchCase = struct {
    scenario: Scenario,
    zerde_value: Payload,
    std_value: StdPayload,
    json_out: std.Io.Writer.Allocating,
    std_json_out: std.Io.Writer.Allocating,

    fn json(self: *BenchCase) []const u8 {
        return self.json_out.written();
    }

    fn stdJson(self: *BenchCase) []const u8 {
        return self.std_json_out.written();
    }

    fn deinit(self: *BenchCase, allocator: Allocator) void {
        self.std_json_out.deinit();
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

fn benchStatsFromResult(result: zbench.Result) !BenchStats {
    const timing_stats = try zbench.statistics.Statistics(u64).init(result.readings.timings_ns);
    return .{
        .iterations = result.readings.iterations,
        .total_ns = timing_stats.total,
    };
}

fn runZbenchParam(
    io: std.Io,
    allocator: Allocator,
    name: []const u8,
    benchmark: anytype,
    iterations: usize,
) !BenchStats {
    const BenchmarkPtr = @TypeOf(benchmark);
    const pointer_info = @typeInfo(BenchmarkPtr);
    if (pointer_info != .pointer) @compileError("benchmark context must be a pointer");
    const BenchmarkType = pointer_info.pointer.child;
    const const_benchmark: *const BenchmarkType = benchmark;

    var bench = zbench.Benchmark.init(allocator, .{});
    defer bench.deinit();

    try bench.addParam(name, const_benchmark, .{
        .iterations = @intCast(iterations),
    });

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

const ScenarioResult = struct {
    parse_bytes: usize,
    zerde_write_bytes: usize,
    std_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_std: BenchStats,
    write_zerde: BenchStats,
    write_std: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_std: BenchStats,
};

const TomlScenarioResult = struct {
    parse_bytes: usize,
    zerde_write_bytes: usize,
    zig_toml_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_zig_toml: BenchStats,
    write_zerde: BenchStats,
    write_zig_toml: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_zig_toml: BenchStats,
};

const CborScenarioResult = struct {
    parse_bytes: usize,
    zerde_write_bytes: usize,
    zbor_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_zbor: BenchStats,
    write_zerde: BenchStats,
    write_zbor: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_zbor: BenchStats,
};

const BsonScenarioResult = struct {
    parse_bytes: usize,
    zerde_write_bytes: usize,
    zig_bson_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_zig_bson: BenchStats,
    write_zerde: BenchStats,
    write_zig_bson: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_zig_bson: BenchStats,
};

const YamlScenarioResult = struct {
    parse_bytes: usize,
    zerde_write_bytes: usize,
    zig_yaml_write_bytes: usize,
    parse_zerde: BenchStats,
    parse_zig_yaml: BenchStats,
    write_zerde: BenchStats,
    write_zig_yaml: BenchStats,
    roundtrip_zerde: BenchStats,
    roundtrip_zig_yaml: BenchStats,
};

pub fn runAll(io: std.Io, allocator: Allocator) !void {
    try runJsonBench(io, allocator);
    try runTomlBench(io, allocator);
    try runCborBench(io, allocator);
    try runBsonBench(io, allocator);
    try runYamlBench(io, allocator);
}

pub fn runJsonBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde JSON benchmark vs std.json\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n\n", .{});

    for (scenarios) |scenario| {
        var bench_case = try buildCase(allocator, scenario);
        defer bench_case.deinit(allocator);

        const result = try runScenario(io, allocator, &bench_case);
        printScenarioResult(bench_case.scenario, result);
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

    var std_json_out: std.Io.Writer.Allocating = .init(allocator);
    errdefer std_json_out.deinit();
    try std.json.Stringify.value(std_value, .{}, &std_json_out.writer);

    return .{
        .scenario = scenario,
        .zerde_value = zerde_value,
        .std_value = std_value,
        .json_out = json_out,
        .std_json_out = std_json_out,
    };
}

fn runScenario(io: std.Io, allocator: Allocator, bench_case: *BenchCase) !ScenarioResult {
    const JsonZerdeParse = struct {
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
            const value = zerde.parseSliceAliased(zerde.json, Payload, self.arena.allocator(), self.input) catch @panic("zerde JSON parse failed");
            consumePayload(value);
        }
    };

    const JsonStdParse = struct {
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
            const value = std.json.parseFromSliceLeaky(StdPayload, self.arena.allocator(), self.input, .{
                .ignore_unknown_fields = false,
            }) catch @panic("std.json parse failed");
            consumeStdPayload(value);
        }
    };

    const JsonZerdeSerialize = struct {
        value: Payload,
        out: std.Io.Writer.Allocating,

        fn init(value: Payload) @This() {
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
            zerde.serialize(zerde.json, &self.out.writer, self.value) catch @panic("zerde JSON serialize failed");
        }
    };

    const JsonStdSerialize = struct {
        value: StdPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: StdPayload) @This() {
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
            std.json.Stringify.value(self.value, .{}, &self.out.writer) catch @panic("std.json serialize failed");
        }
    };

    const JsonZerdeRoundTrip = struct {
        value: Payload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: Payload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serialize(zerde.json, &self.out.writer, self.value);
            const check = try zerde.parseSliceAliased(zerde.json, Payload, self.arena.allocator(), self.out.written());
            try assertRoundTripEqual(Payload, self.value, check);
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
            zerde.serialize(zerde.json, &self.out.writer, self.value) catch @panic("zerde JSON roundtrip serialize failed");
            const parsed = zerde.parseSliceAliased(zerde.json, Payload, self.arena.allocator(), self.out.written()) catch @panic("zerde JSON roundtrip parse failed");
            consumePayload(parsed);
        }
    };

    const JsonStdRoundTrip = struct {
        value: StdPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: StdPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try std.json.Stringify.value(self.value, .{}, &self.out.writer);
            const check = try std.json.parseFromSliceLeaky(StdPayload, self.arena.allocator(), self.out.written(), .{
                .ignore_unknown_fields = false,
            });
            try assertRoundTripEqual(StdPayload, self.value, check);
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
            std.json.Stringify.value(self.value, .{}, &self.out.writer) catch @panic("std.json roundtrip serialize failed");
            const parsed = std.json.parseFromSliceLeaky(StdPayload, self.arena.allocator(), self.out.written(), .{
                .ignore_unknown_fields = false,
            }) catch @panic("std.json roundtrip parse failed");
            consumeStdPayload(parsed);
        }
    };

    var parse_zerde = JsonZerdeParse.init(bench_case.json());
    defer parse_zerde.deinit();
    var parse_std = JsonStdParse.init(bench_case.json());
    defer parse_std.deinit();
    var write_zerde = JsonZerdeSerialize.init(bench_case.zerde_value);
    defer write_zerde.deinit();
    var write_std = JsonStdSerialize.init(bench_case.std_value);
    defer write_std.deinit();
    var roundtrip_zerde = try JsonZerdeRoundTrip.init(bench_case.zerde_value);
    defer roundtrip_zerde.deinit();
    var roundtrip_std = try JsonStdRoundTrip.init(bench_case.std_value);
    defer roundtrip_std.deinit();

    return .{
        .parse_bytes = bench_case.json().len,
        .zerde_write_bytes = bench_case.json().len,
        .std_write_bytes = bench_case.stdJson().len,
        .parse_zerde = try runZbenchParam(io, allocator, "json parse zerde", &parse_zerde, bench_case.scenario.parse_iterations),
        .parse_std = try runZbenchParam(io, allocator, "json parse std", &parse_std, bench_case.scenario.parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "json write zerde", &write_zerde, bench_case.scenario.write_iterations),
        .write_std = try runZbenchParam(io, allocator, "json write std", &write_std, bench_case.scenario.write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "json roundtrip zerde", &roundtrip_zerde, bench_case.scenario.roundtrip_iterations),
        .roundtrip_std = try runZbenchParam(io, allocator, "json roundtrip std", &roundtrip_std, bench_case.scenario.roundtrip_iterations),
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

fn benchZerdeRoundTrip(io: std.Io, value: Payload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zerde.serialize(zerde.json, &out.writer, value);
    const check = try zerde.parseSliceAliased(zerde.json, Payload, arena.allocator(), out.written());
    try assertRoundTripEqual(Payload, value, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.json, &out.writer, value);
        const parsed = try zerde.parseSliceAliased(zerde.json, Payload, arena.allocator(), out.written());
        consumePayload(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchStdRoundTrip(io: std.Io, value: StdPayload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try std.json.Stringify.value(value, .{}, &out.writer);
    const check = try std.json.parseFromSliceLeaky(StdPayload, arena.allocator(), out.written(), .{
        .ignore_unknown_fields = false,
    });
    try assertRoundTripEqual(StdPayload, value, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try std.json.Stringify.value(value, .{}, &out.writer);
        const parsed = try std.json.parseFromSliceLeaky(StdPayload, arena.allocator(), out.written(), .{
            .ignore_unknown_fields = false,
        });
        consumeStdPayload(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printScenarioResult(scenario: Scenario, result: ScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{
        result.parse_bytes,
        bytesToMiB(result.parse_bytes),
    });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_write_bytes,
        bytesToMiB(result.zerde_write_bytes),
    });
    std.debug.print("  std.json write bytes: {d} ({d:.2} MiB)\n", .{
        result.std_write_bytes,
        bytesToMiB(result.std_write_bytes),
    });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  parse std.json: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_std.nsPerOp(),
        result.parse_std.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  write  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_write_bytes),
    });
    std.debug.print("  write std.json: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_std.nsPerOp(),
        result.write_std.mibPerSec(result.std_write_bytes),
    });
    std.debug.print("  roundtrip  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zerde.nsPerOp(),
        result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2),
    });
    std.debug.print("  roundtrip std.json: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_std.nsPerOp(),
        result.roundtrip_std.mibPerSec(result.std_write_bytes * 2),
    });
    std.debug.print("\n", .{});
}

pub fn runTomlBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde TOML benchmark vs zig-toml\n", .{});
    std.debug.print("scenarios: small, medium, large\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: parse and write are both measured against the same canonical TOML input per scenario\n\n", .{});

    inline for (scenarios) |scenario| {
        const result = try runTomlScenario(
            scenario.endpoint_count,
            scenario.metric_count,
            scenario.event_count,
            scenario.parse_iterations,
            scenario.write_iterations,
            scenario.roundtrip_iterations,
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
    parse_iterations: usize,
    write_iterations: usize,
    roundtrip_iterations: usize,
    io: std.Io,
    allocator: Allocator,
) !TomlScenarioResult {
    const WriteType = TomlPayload(endpoint_count, metric_count, event_count);

    const TomlZerdeParse = struct {
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
            const value = zerde.parseSlice(zerde.toml, TomlParsePayload, self.arena.allocator(), self.input) catch @panic("zerde TOML parse failed");
            consumeTomlParsed(value);
        }
    };

    const ZigTomlParse = struct {
        input: []const u8,
        parser: zig_toml.Parser(TomlParsePayload),

        fn init(parse_allocator: Allocator, input: []const u8) @This() {
            return .{
                .input = input,
                .parser = zig_toml.Parser(TomlParsePayload).init(parse_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.parser.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            var result = self.parser.parseString(self.input) catch @panic("zig-toml parse failed");
            consumeTomlParsed(result.value);
            result.deinit();
        }
    };

    const TomlZerdeSerialize = struct {
        value: *const WriteType,
        out: std.Io.Writer.Allocating,

        fn init(value: *const WriteType) @This() {
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
            zerde.serialize(zerde.toml, &self.out.writer, self.value.*) catch @panic("zerde TOML serialize failed");
        }
    };

    const ZigTomlSerialize = struct {
        allocator: Allocator,
        value: *const WriteType,
        out: std.Io.Writer.Allocating,

        fn init(write_allocator: Allocator, value: *const WriteType) @This() {
            return .{
                .allocator = write_allocator,
                .value = value,
                .out = .init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            self.out.clearRetainingCapacity();
            zig_toml.serialize(self.allocator, self.value.*, &self.out.writer) catch @panic("zig-toml serialize failed");
        }
    };

    const TomlZerdeRoundTrip = struct {
        value: *const WriteType,
        expected: TomlParsePayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: *const WriteType) !@This() {
            var self = @This(){
                .value = value,
                .expected = makeTomlParseView(value.*),
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serialize(zerde.toml, &self.out.writer, self.value.*);
            const check = try zerde.parseSlice(zerde.toml, TomlParsePayload, self.arena.allocator(), self.out.written());
            try assertRoundTripEqual(TomlParsePayload, self.expected, check);
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
            zerde.serialize(zerde.toml, &self.out.writer, self.value.*) catch @panic("zerde TOML roundtrip serialize failed");
            const parsed = zerde.parseSlice(zerde.toml, TomlParsePayload, self.arena.allocator(), self.out.written()) catch @panic("zerde TOML roundtrip parse failed");
            consumeTomlParsed(parsed);
        }
    };

    const ZigTomlRoundTrip = struct {
        allocator: Allocator,
        value: *const WriteType,
        expected: TomlParsePayload,
        parser: zig_toml.Parser(TomlParsePayload),
        out: std.Io.Writer.Allocating,

        fn init(roundtrip_allocator: Allocator, value: *const WriteType) !@This() {
            var self = @This(){
                .allocator = roundtrip_allocator,
                .value = value,
                .expected = makeTomlParseView(value.*),
                .parser = zig_toml.Parser(TomlParsePayload).init(roundtrip_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zig_toml.serialize(self.allocator, self.value.*, &self.out.writer);
            var check = try self.parser.parseString(self.out.written());
            defer check.deinit();
            try assertRoundTripEqual(TomlParsePayload, self.expected, check.value);
            self.out.clearRetainingCapacity();
            return self;
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
            self.parser.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            self.out.clearRetainingCapacity();
            zig_toml.serialize(self.allocator, self.value.*, &self.out.writer) catch @panic("zig-toml roundtrip serialize failed");
            var parsed = self.parser.parseString(self.out.written()) catch @panic("zig-toml roundtrip parse failed");
            consumeTomlParsed(parsed.value);
            parsed.deinit();
        }
    };

    const value = try makeTomlPayload(endpoint_count, metric_count, event_count, allocator);
    defer freeTomlPayload(allocator, value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serialize(zerde.toml, &zerde_out.writer, value);
    const parse_input = zerde_out.written();

    var zig_toml_out: std.Io.Writer.Allocating = .init(allocator);
    defer zig_toml_out.deinit();
    try zig_toml.serialize(allocator, value, &zig_toml_out.writer);

    var parse_zerde = TomlZerdeParse.init(parse_input);
    defer parse_zerde.deinit();
    var parse_zig_toml = ZigTomlParse.init(allocator, parse_input);
    defer parse_zig_toml.deinit();
    var write_zerde = TomlZerdeSerialize.init(value);
    defer write_zerde.deinit();
    var write_zig_toml = ZigTomlSerialize.init(allocator, value);
    defer write_zig_toml.deinit();
    var roundtrip_zerde = try TomlZerdeRoundTrip.init(value);
    defer roundtrip_zerde.deinit();
    var roundtrip_zig_toml = try ZigTomlRoundTrip.init(allocator, value);
    defer roundtrip_zig_toml.deinit();

    return .{
        .parse_bytes = parse_input.len,
        .zerde_write_bytes = zerde_out.written().len,
        .zig_toml_write_bytes = zig_toml_out.written().len,
        .parse_zerde = try runZbenchParam(io, allocator, "toml parse zerde", &parse_zerde, parse_iterations),
        .parse_zig_toml = try runZbenchParam(io, allocator, "toml parse zig-toml", &parse_zig_toml, parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "toml write zerde", &write_zerde, write_iterations),
        .write_zig_toml = try runZbenchParam(io, allocator, "toml write zig-toml", &write_zig_toml, write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "toml roundtrip zerde", &roundtrip_zerde, roundtrip_iterations),
        .roundtrip_zig_toml = try runZbenchParam(io, allocator, "toml roundtrip zig-toml", &roundtrip_zig_toml, roundtrip_iterations),
    };
}

fn benchTomlZerdeParse(comptime T: type, io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const value = try zerde.parseSlice(zerde.toml, T, arena.allocator(), input);
        consumeTomlParsed(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigTomlParse(comptime T: type, io: std.Io, allocator: Allocator, input: []const u8, iterations: usize) !u64 {
    var parser = zig_toml.Parser(T).init(allocator);
    defer parser.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        var result = try parser.parseString(input);
        consumeTomlParsed(result.value);
        result.deinit();
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
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

fn benchTomlZerdeRoundTrip(io: std.Io, value: anytype, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const expected = makeTomlParseView(value);
    try zerde.serialize(zerde.toml, &out.writer, value);
    const check = try zerde.parseSlice(zerde.toml, TomlParsePayload, arena.allocator(), out.written());
    try assertRoundTripEqual(TomlParsePayload, expected, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.toml, &out.writer, value);
        const parsed = try zerde.parseSlice(zerde.toml, TomlParsePayload, arena.allocator(), out.written());
        consumeTomlParsed(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigTomlRoundTrip(io: std.Io, allocator: Allocator, value: anytype, iterations: usize) !u64 {
    var parser = zig_toml.Parser(TomlParsePayload).init(allocator);
    defer parser.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const expected = makeTomlParseView(value);
    try zig_toml.serialize(allocator, value, &out.writer);
    var check = try parser.parseString(out.written());
    defer check.deinit();
    try assertRoundTripEqual(TomlParsePayload, expected, check.value);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zig_toml.serialize(allocator, value, &out.writer);
        var parsed = try parser.parseString(out.written());
        consumeTomlParsed(parsed.value);
        parsed.deinit();
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printTomlScenarioResult(comptime scenario: Scenario, result: TomlScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{
        result.parse_bytes,
        bytesToMiB(result.parse_bytes),
    });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_write_bytes,
        bytesToMiB(result.zerde_write_bytes),
    });
    std.debug.print("  zig-toml write bytes: {d} ({d:.2} MiB)\n", .{
        result.zig_toml_write_bytes,
        bytesToMiB(result.zig_toml_write_bytes),
    });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  parse zig-toml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zig_toml.nsPerOp(),
        result.parse_zig_toml.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  write    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_write_bytes),
    });
    std.debug.print("  write zig-toml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zig_toml.nsPerOp(),
        result.write_zig_toml.mibPerSec(result.zig_toml_write_bytes),
    });
    std.debug.print("  roundtrip    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zerde.nsPerOp(),
        result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2),
    });
    std.debug.print("  roundtrip zig-toml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zig_toml.nsPerOp(),
        result.roundtrip_zig_toml.mibPerSec(result.zig_toml_write_bytes * 2),
    });
    std.debug.print("\n", .{});
}

pub fn runCborBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde CBOR benchmark vs zbor\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: parse is measured on one canonical CBOR document per scenario; zbor parse includes DataItem construction because it is part of the public typed path\n\n", .{});

    for (scenarios) |scenario| {
        const result = try runCborScenario(io, allocator, scenario);
        printCborScenarioResult(scenario, result);
    }

    std.debug.print("\n", .{});
}

fn runCborScenario(io: std.Io, allocator: Allocator, scenario: Scenario) !CborScenarioResult {
    const CborZerdeParse = struct {
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
            const value = zerde.parseSliceAliased(zerde.cbor, Payload, self.arena.allocator(), self.input) catch @panic("zerde CBOR parse failed");
            consumePayload(value);
        }
    };

    const ZborParse = struct {
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
            const item = zbor.DataItem.new(self.input) catch @panic("zbor item parse failed");
            const value = zbor.parse(ZborPayload, item, zborParseOptions(self.arena.allocator())) catch @panic("zbor typed parse failed");
            consumeStdPayload(value);
        }
    };

    const CborZerdeSerialize = struct {
        value: Payload,
        out: std.Io.Writer.Allocating,

        fn init(value: Payload) @This() {
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
            zerde.serialize(zerde.cbor, &self.out.writer, self.value) catch @panic("zerde CBOR serialize failed");
        }
    };

    const ZborSerialize = struct {
        value: ZborPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: ZborPayload) @This() {
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
            zbor.stringify(self.value, zborStringifyOptions(), &self.out.writer) catch @panic("zbor serialize failed");
        }
    };

    const CborZerdeRoundTrip = struct {
        value: Payload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: Payload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serialize(zerde.cbor, &self.out.writer, self.value);
            const check = try zerde.parseSliceAliased(zerde.cbor, Payload, self.arena.allocator(), self.out.written());
            try assertRoundTripEqual(Payload, self.value, check);
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
            zerde.serialize(zerde.cbor, &self.out.writer, self.value) catch @panic("zerde CBOR roundtrip serialize failed");
            const parsed = zerde.parseSliceAliased(zerde.cbor, Payload, self.arena.allocator(), self.out.written()) catch @panic("zerde CBOR roundtrip parse failed");
            consumePayload(parsed);
        }
    };

    const ZborRoundTrip = struct {
        value: ZborPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: ZborPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zbor.stringify(self.value, zborStringifyOptions(), &self.out.writer);
            const check_item = try zbor.DataItem.new(self.out.written());
            const check = try zbor.parse(ZborPayload, check_item, zborParseOptions(self.arena.allocator()));
            try assertRoundTripEqual(ZborPayload, self.value, check);
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
            zbor.stringify(self.value, zborStringifyOptions(), &self.out.writer) catch @panic("zbor roundtrip serialize failed");
            const item = zbor.DataItem.new(self.out.written()) catch @panic("zbor roundtrip item failed");
            const parsed = zbor.parse(ZborPayload, item, zborParseOptions(self.arena.allocator())) catch @panic("zbor roundtrip parse failed");
            consumeStdPayload(parsed);
        }
    };

    const zerde_value = try makePayload(allocator, scenario);
    defer freePayload(allocator, zerde_value);

    const zbor_value = try makeStdPayload(allocator, scenario);
    defer freeStdPayload(allocator, zbor_value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serialize(zerde.cbor, &zerde_out.writer, zerde_value);
    const parse_input = zerde_out.written();

    var zbor_out: std.Io.Writer.Allocating = .init(allocator);
    defer zbor_out.deinit();
    try zbor.stringify(zbor_value, zborStringifyOptions(), &zbor_out.writer);

    var parse_zerde = CborZerdeParse.init(parse_input);
    defer parse_zerde.deinit();
    var parse_zbor = ZborParse.init(parse_input);
    defer parse_zbor.deinit();
    var write_zerde = CborZerdeSerialize.init(zerde_value);
    defer write_zerde.deinit();
    var write_zbor = ZborSerialize.init(zbor_value);
    defer write_zbor.deinit();
    var roundtrip_zerde = try CborZerdeRoundTrip.init(zerde_value);
    defer roundtrip_zerde.deinit();
    var roundtrip_zbor = try ZborRoundTrip.init(zbor_value);
    defer roundtrip_zbor.deinit();

    return .{
        .parse_bytes = parse_input.len,
        .zerde_write_bytes = zerde_out.written().len,
        .zbor_write_bytes = zbor_out.written().len,
        .parse_zerde = try runZbenchParam(io, allocator, "cbor parse zerde", &parse_zerde, scenario.parse_iterations),
        .parse_zbor = try runZbenchParam(io, allocator, "cbor parse zbor", &parse_zbor, scenario.parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "cbor write zerde", &write_zerde, scenario.write_iterations),
        .write_zbor = try runZbenchParam(io, allocator, "cbor write zbor", &write_zbor, scenario.write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "cbor roundtrip zerde", &roundtrip_zerde, scenario.roundtrip_iterations),
        .roundtrip_zbor = try runZbenchParam(io, allocator, "cbor roundtrip zbor", &roundtrip_zbor, scenario.roundtrip_iterations),
    };
}

fn benchCborZerdeParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const value = try zerde.parseSliceAliased(zerde.cbor, Payload, arena.allocator(), input);
        consumePayload(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZborParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const item = try zbor.DataItem.new(input);
        const value = try zbor.parse(ZborPayload, item, zborParseOptions(arena.allocator()));
        consumeStdPayload(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchCborZerdeSerialize(io: std.Io, value: Payload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.cbor, &out.writer, value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZborSerialize(io: std.Io, value: ZborPayload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zbor.stringify(value, zborStringifyOptions(), &out.writer);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchCborZerdeRoundTrip(io: std.Io, value: Payload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zerde.serialize(zerde.cbor, &out.writer, value);
    const check = try zerde.parseSliceAliased(zerde.cbor, Payload, arena.allocator(), out.written());
    try assertRoundTripEqual(Payload, value, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zerde.serialize(zerde.cbor, &out.writer, value);
        const parsed = try zerde.parseSliceAliased(zerde.cbor, Payload, arena.allocator(), out.written());
        consumePayload(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZborRoundTrip(io: std.Io, value: ZborPayload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zbor.stringify(value, zborStringifyOptions(), &out.writer);
    const check_item = try zbor.DataItem.new(out.written());
    const check = try zbor.parse(ZborPayload, check_item, zborParseOptions(arena.allocator()));
    try assertRoundTripEqual(ZborPayload, value, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zbor.stringify(value, zborStringifyOptions(), &out.writer);
        const item = try zbor.DataItem.new(out.written());
        const parsed = try zbor.parse(ZborPayload, item, zborParseOptions(arena.allocator()));
        consumeStdPayload(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printCborScenarioResult(scenario: Scenario, result: CborScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{
        result.parse_bytes,
        bytesToMiB(result.parse_bytes),
    });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_write_bytes,
        bytesToMiB(result.zerde_write_bytes),
    });
    std.debug.print("  zbor write bytes: {d} ({d:.2} MiB)\n", .{
        result.zbor_write_bytes,
        bytesToMiB(result.zbor_write_bytes),
    });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  parse   zbor: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zbor.nsPerOp(),
        result.parse_zbor.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  write  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_write_bytes),
    });
    std.debug.print("  write   zbor: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zbor.nsPerOp(),
        result.write_zbor.mibPerSec(result.zbor_write_bytes),
    });
    std.debug.print("  roundtrip  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zerde.nsPerOp(),
        result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2),
    });
    std.debug.print("  roundtrip   zbor: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zbor.nsPerOp(),
        result.roundtrip_zbor.mibPerSec(result.zbor_write_bytes * 2),
    });
    std.debug.print("\n", .{});
}

pub fn runBsonBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde BSON benchmark vs zig-bson\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: parse and roundtrip use a signed-integer/string-signature BSON payload because that is the shared typed subset both libraries support\n\n", .{});

    for (scenarios) |scenario| {
        const result = try runBsonScenario(io, allocator, scenario);
        printBsonScenarioResult(scenario, result);
    }

    std.debug.print("\n", .{});
}

fn runBsonScenario(io: std.Io, allocator: Allocator, scenario: Scenario) !BsonScenarioResult {
    const BsonZerdeParse = struct {
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
            const value = zerde.parseSliceAliased(zerde.bson, BsonPayload, self.arena.allocator(), self.input) catch @panic("zerde BSON parse failed");
            consumeBsonPayload(value);
        }
    };

    const ZigBsonParse = struct {
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
            var bson_reader = zig_bson.reader(self.arena.allocator(), self.input);
            var owned = bson_reader.readInto(BsonPayload) catch @panic("zig-bson parse failed");
            defer owned.deinit();
            consumeBsonPayload(owned.value);
        }
    };

    const BsonZerdeSerialize = struct {
        value: BsonPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: BsonPayload) @This() {
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
            zerde.serialize(zerde.bson, &self.out.writer, self.value) catch @panic("zerde BSON serialize failed");
        }
    };

    const ZigBsonSerialize = struct {
        value: BsonPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: BsonPayload) @This() {
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
            var bson_writer = zig_bson.writer(std.heap.page_allocator, &self.out.writer);
            defer bson_writer.deinit();
            bson_writer.writeFrom(self.value) catch @panic("zig-bson serialize failed");
        }
    };

    const BsonZerdeRoundTrip = struct {
        value: BsonPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: BsonPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serialize(zerde.bson, &self.out.writer, self.value);
            const check = try zerde.parseSliceAliased(zerde.bson, BsonPayload, self.arena.allocator(), self.out.written());
            try assertRoundTripEqual(BsonPayload, self.value, check);
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
            zerde.serialize(zerde.bson, &self.out.writer, self.value) catch @panic("zerde BSON roundtrip serialize failed");
            const parsed = zerde.parseSliceAliased(zerde.bson, BsonPayload, self.arena.allocator(), self.out.written()) catch @panic("zerde BSON roundtrip parse failed");
            consumeBsonPayload(parsed);
        }
    };

    const ZigBsonRoundTrip = struct {
        value: BsonPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: BsonPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            var bson_writer = zig_bson.writer(std.heap.page_allocator, &self.out.writer);
            defer bson_writer.deinit();
            try bson_writer.writeFrom(self.value);

            var bson_reader = zig_bson.reader(self.arena.allocator(), self.out.written());
            var check = try bson_reader.readInto(BsonPayload);
            try assertRoundTripEqual(BsonPayload, self.value, check.value);
            check.deinit();
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
            var bson_writer = zig_bson.writer(std.heap.page_allocator, &self.out.writer);
            defer bson_writer.deinit();
            bson_writer.writeFrom(self.value) catch @panic("zig-bson roundtrip serialize failed");

            var bson_reader = zig_bson.reader(self.arena.allocator(), self.out.written());
            var parsed = bson_reader.readInto(BsonPayload) catch @panic("zig-bson roundtrip parse failed");
            defer parsed.deinit();
            consumeBsonPayload(parsed.value);
        }
    };

    const value = try makeBsonPayload(allocator, scenario);
    defer freeBsonPayload(allocator, value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serialize(zerde.bson, &zerde_out.writer, value);
    const parse_input = zerde_out.written();

    var zig_bson_out: std.Io.Writer.Allocating = .init(allocator);
    defer zig_bson_out.deinit();
    {
        var bson_writer = zig_bson.writer(allocator, &zig_bson_out.writer);
        defer bson_writer.deinit();
        try bson_writer.writeFrom(value);
    }

    var parse_zerde = BsonZerdeParse.init(parse_input);
    defer parse_zerde.deinit();
    var parse_zig_bson = ZigBsonParse.init(parse_input);
    defer parse_zig_bson.deinit();
    var write_zerde = BsonZerdeSerialize.init(value);
    defer write_zerde.deinit();
    var write_zig_bson = ZigBsonSerialize.init(value);
    defer write_zig_bson.deinit();
    var roundtrip_zerde = try BsonZerdeRoundTrip.init(value);
    defer roundtrip_zerde.deinit();
    var roundtrip_zig_bson = try ZigBsonRoundTrip.init(value);
    defer roundtrip_zig_bson.deinit();

    return .{
        .parse_bytes = parse_input.len,
        .zerde_write_bytes = zerde_out.written().len,
        .zig_bson_write_bytes = zig_bson_out.written().len,
        .parse_zerde = try runZbenchParam(io, allocator, "bson parse zerde", &parse_zerde, scenario.parse_iterations),
        .parse_zig_bson = try runZbenchParam(io, allocator, "bson parse zig-bson", &parse_zig_bson, scenario.parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "bson write zerde", &write_zerde, scenario.write_iterations),
        .write_zig_bson = try runZbenchParam(io, allocator, "bson write zig-bson", &write_zig_bson, scenario.write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "bson roundtrip zerde", &roundtrip_zerde, scenario.roundtrip_iterations),
        .roundtrip_zig_bson = try runZbenchParam(io, allocator, "bson roundtrip zig-bson", &roundtrip_zig_bson, scenario.roundtrip_iterations),
    };
}

fn printBsonScenarioResult(scenario: Scenario, result: BsonScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{
        result.parse_bytes,
        bytesToMiB(result.parse_bytes),
    });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_write_bytes,
        bytesToMiB(result.zerde_write_bytes),
    });
    std.debug.print("  zig-bson write bytes: {d} ({d:.2} MiB)\n", .{
        result.zig_bson_write_bytes,
        bytesToMiB(result.zig_bson_write_bytes),
    });
    std.debug.print("  endpoints / metrics / events: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  parse zig-bson: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zig_bson.nsPerOp(),
        result.parse_zig_bson.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  write  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_write_bytes),
    });
    std.debug.print("  write zig-bson: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zig_bson.nsPerOp(),
        result.write_zig_bson.mibPerSec(result.zig_bson_write_bytes),
    });
    std.debug.print("  roundtrip  zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zerde.nsPerOp(),
        result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2),
    });
    std.debug.print("  roundtrip zig-bson: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zig_bson.nsPerOp(),
        result.roundtrip_zig_bson.mibPerSec(result.zig_bson_write_bytes * 2),
    });
    std.debug.print("\n", .{});
}

pub fn runYamlBench(io: std.Io, allocator: Allocator) !void {
    std.debug.print("zerde YAML benchmark vs zig-yaml\n", .{});
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n", .{});
    std.debug.print("iterations: 1_000_000 / 1_000 / 100\n", .{});
    std.debug.print("roundtrip: typed value -> bytes -> typed value, with one correctness check before timing\n", .{});
    std.debug.print("note: parse is measured on one canonical YAML document per scenario; zig-yaml parse includes document load because it is part of the public typed path\n\n", .{});

    for (scenarios) |scenario| {
        const result = try runYamlScenario(io, allocator, scenario);
        printYamlScenarioResult(scenario, result);
    }

    std.debug.print("\n", .{});
}

fn runYamlScenario(io: std.Io, allocator: Allocator, scenario: Scenario) !YamlScenarioResult {
    const YamlZerdeParse = struct {
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
            const value = zerde.parseSliceAliased(zerde.yaml, YamlPayload, self.arena.allocator(), self.input) catch @panic("zerde YAML parse failed");
            consumeYamlPayload(value);
        }
    };

    const ZigYamlParse = struct {
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
            const loop_allocator = self.arena.allocator();
            var yaml_doc: zig_yaml.Yaml = .{ .source = self.input };
            yaml_doc.load(loop_allocator) catch @panic("zig-yaml load failed");
            const value = yaml_doc.parse(loop_allocator, YamlPayload) catch @panic("zig-yaml parse failed");
            consumeYamlPayload(value);
            yaml_doc.deinit(loop_allocator);
        }
    };

    const YamlZerdeSerialize = struct {
        value: YamlPayload,
        out: std.Io.Writer.Allocating,

        fn init(value: YamlPayload) @This() {
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
            zerde.serializeWith(zerde.yaml, &self.out.writer, self.value, .{
                .omit_null_fields = true,
            }, .{
                .indent_width = 4,
            }) catch @panic("zerde YAML serialize failed");
        }
    };

    const ZigYamlSerialize = struct {
        allocator: Allocator,
        value: YamlPayload,
        out: std.Io.Writer.Allocating,

        fn init(write_allocator: Allocator, value: YamlPayload) @This() {
            return .{
                .allocator = write_allocator,
                .value = value,
                .out = .init(std.heap.page_allocator),
            };
        }

        fn deinit(self: *@This()) void {
            self.out.deinit();
        }

        pub fn run(self: *@This(), _: Allocator) void {
            self.out.clearRetainingCapacity();
            zig_yaml.stringify(self.allocator, self.value, &self.out.writer) catch @panic("zig-yaml serialize failed");
        }
    };

    const YamlZerdeRoundTrip = struct {
        value: YamlPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(value: YamlPayload) !@This() {
            var self = @This(){
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zerde.serializeWith(zerde.yaml, &self.out.writer, self.value, .{
                .omit_null_fields = true,
            }, .{
                .indent_width = 4,
            });
            const check = try zerde.parseSliceAliased(zerde.yaml, YamlPayload, self.arena.allocator(), self.out.written());
            try assertRoundTripEqual(YamlPayload, self.value, check);
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
            zerde.serializeWith(zerde.yaml, &self.out.writer, self.value, .{
                .omit_null_fields = true,
            }, .{
                .indent_width = 4,
            }) catch @panic("zerde YAML roundtrip serialize failed");
            const parsed = zerde.parseSliceAliased(zerde.yaml, YamlPayload, self.arena.allocator(), self.out.written()) catch @panic("zerde YAML roundtrip parse failed");
            consumeYamlPayload(parsed);
        }
    };

    const ZigYamlRoundTrip = struct {
        allocator: Allocator,
        value: YamlPayload,
        arena: std.heap.ArenaAllocator,
        out: std.Io.Writer.Allocating,

        fn init(roundtrip_allocator: Allocator, value: YamlPayload) !@This() {
            var self = @This(){
                .allocator = roundtrip_allocator,
                .value = value,
                .arena = std.heap.ArenaAllocator.init(std.heap.page_allocator),
                .out = .init(std.heap.page_allocator),
            };
            errdefer self.deinit();

            try zig_yaml.stringify(self.allocator, self.value, &self.out.writer);
            var check_doc: zig_yaml.Yaml = .{ .source = self.out.written() };
            try check_doc.load(self.arena.allocator());
            const check = try check_doc.parse(self.arena.allocator(), YamlPayload);
            try assertRoundTripEqual(YamlPayload, self.value, check);
            check_doc.deinit(self.arena.allocator());
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
            zig_yaml.stringify(self.allocator, self.value, &self.out.writer) catch @panic("zig-yaml roundtrip serialize failed");
            var yaml_doc: zig_yaml.Yaml = .{ .source = self.out.written() };
            yaml_doc.load(self.arena.allocator()) catch @panic("zig-yaml roundtrip load failed");
            const parsed = yaml_doc.parse(self.arena.allocator(), YamlPayload) catch @panic("zig-yaml roundtrip parse failed");
            consumeYamlPayload(parsed);
            yaml_doc.deinit(self.arena.allocator());
        }
    };

    const value = try makeYamlPayload(allocator, scenario);
    defer freeYamlPayload(allocator, value);

    var zerde_out: std.Io.Writer.Allocating = .init(allocator);
    defer zerde_out.deinit();
    try zerde.serializeWith(zerde.yaml, &zerde_out.writer, value, .{
        .omit_null_fields = true,
    }, .{
        .indent_width = 4,
    });

    var zig_yaml_out: std.Io.Writer.Allocating = .init(allocator);
    defer zig_yaml_out.deinit();
    try zig_yaml.stringify(allocator, value, &zig_yaml_out.writer);
    const parse_input = zig_yaml_out.written();

    var parse_zerde = YamlZerdeParse.init(parse_input);
    defer parse_zerde.deinit();
    var parse_zig_yaml = ZigYamlParse.init(parse_input);
    defer parse_zig_yaml.deinit();
    var write_zerde = YamlZerdeSerialize.init(value);
    defer write_zerde.deinit();
    var write_zig_yaml = ZigYamlSerialize.init(allocator, value);
    defer write_zig_yaml.deinit();
    var roundtrip_zerde = try YamlZerdeRoundTrip.init(value);
    defer roundtrip_zerde.deinit();
    var roundtrip_zig_yaml = try ZigYamlRoundTrip.init(allocator, value);
    defer roundtrip_zig_yaml.deinit();

    return .{
        .parse_bytes = parse_input.len,
        .zerde_write_bytes = zerde_out.written().len,
        .zig_yaml_write_bytes = zig_yaml_out.written().len,
        .parse_zerde = try runZbenchParam(io, allocator, "yaml parse zerde", &parse_zerde, scenario.parse_iterations),
        .parse_zig_yaml = try runZbenchParam(io, allocator, "yaml parse zig-yaml", &parse_zig_yaml, scenario.parse_iterations),
        .write_zerde = try runZbenchParam(io, allocator, "yaml write zerde", &write_zerde, scenario.write_iterations),
        .write_zig_yaml = try runZbenchParam(io, allocator, "yaml write zig-yaml", &write_zig_yaml, scenario.write_iterations),
        .roundtrip_zerde = try runZbenchParam(io, allocator, "yaml roundtrip zerde", &roundtrip_zerde, scenario.roundtrip_iterations),
        .roundtrip_zig_yaml = try runZbenchParam(io, allocator, "yaml roundtrip zig-yaml", &roundtrip_zig_yaml, scenario.roundtrip_iterations),
    };
}

fn benchYamlZerdeParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const value = try zerde.parseSliceAliased(zerde.yaml, YamlPayload, arena.allocator(), input);
        consumeYamlPayload(value);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigYamlParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const loop_allocator = arena.allocator();
        var yaml_doc: zig_yaml.Yaml = .{ .source = input };
        try yaml_doc.load(loop_allocator);
        const value = try yaml_doc.parse(loop_allocator, YamlPayload);
        consumeYamlPayload(value);
        yaml_doc.deinit(loop_allocator);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchYamlZerdeSerialize(io: std.Io, value: YamlPayload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zerde.serializeWith(zerde.yaml, &out.writer, value, .{
            .omit_null_fields = true,
        }, .{
            .indent_width = 4,
        });
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigYamlSerialize(io: std.Io, allocator: Allocator, value: YamlPayload, iterations: usize) !u64 {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        out.clearRetainingCapacity();
        try zig_yaml.stringify(allocator, value, &out.writer);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchYamlZerdeRoundTrip(io: std.Io, value: YamlPayload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zerde.serializeWith(zerde.yaml, &out.writer, value, .{
        .omit_null_fields = true,
    }, .{
        .indent_width = 4,
    });
    const check = try zerde.parseSliceAliased(zerde.yaml, YamlPayload, arena.allocator(), out.written());
    try assertRoundTripEqual(YamlPayload, value, check);
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zerde.serializeWith(zerde.yaml, &out.writer, value, .{
            .omit_null_fields = true,
        }, .{
            .indent_width = 4,
        });
        const parsed = try zerde.parseSliceAliased(zerde.yaml, YamlPayload, arena.allocator(), out.written());
        consumeYamlPayload(parsed);
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn benchZigYamlRoundTrip(io: std.Io, allocator: Allocator, value: YamlPayload, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    try zig_yaml.stringify(allocator, value, &out.writer);
    var check_doc: zig_yaml.Yaml = .{ .source = out.written() };
    try check_doc.load(arena.allocator());
    const check = try check_doc.parse(arena.allocator(), YamlPayload);
    try assertRoundTripEqual(YamlPayload, value, check);
    check_doc.deinit(arena.allocator());
    _ = arena.reset(.retain_capacity);

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        out.clearRetainingCapacity();
        try zig_yaml.stringify(allocator, value, &out.writer);
        var yaml_doc: zig_yaml.Yaml = .{ .source = out.written() };
        try yaml_doc.load(arena.allocator());
        const parsed = try yaml_doc.parse(arena.allocator(), YamlPayload);
        consumeYamlPayload(parsed);
        yaml_doc.deinit(arena.allocator());
    }
    return @intCast(start.untilNow(io).raw.nanoseconds);
}

fn printYamlScenarioResult(scenario: Scenario, result: YamlScenarioResult) void {
    std.debug.print("{s}\n", .{scenario.name});
    std.debug.print("  parse bytes: {d} ({d:.2} MiB)\n", .{
        result.parse_bytes,
        bytesToMiB(result.parse_bytes),
    });
    std.debug.print("  zerde write bytes: {d} ({d:.2} MiB)\n", .{
        result.zerde_write_bytes,
        bytesToMiB(result.zerde_write_bytes),
    });
    std.debug.print("  zig-yaml write bytes: {d} ({d:.2} MiB)\n", .{
        result.zig_yaml_write_bytes,
        bytesToMiB(result.zig_yaml_write_bytes),
    });
    std.debug.print("  routes / ledgers / logs: {d} / {d} / {d}\n", .{
        scenario.endpoint_count,
        scenario.metric_count,
        scenario.event_count,
    });
    std.debug.print("  parse iters: {d}\n", .{result.parse_zerde.iterations});
    std.debug.print("  write iters: {d}\n", .{result.write_zerde.iterations});
    std.debug.print("  roundtrip iters: {d}\n", .{result.roundtrip_zerde.iterations});
    std.debug.print("  parse    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zerde.nsPerOp(),
        result.parse_zerde.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  parse zig-yaml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.parse_zig_yaml.nsPerOp(),
        result.parse_zig_yaml.mibPerSec(result.parse_bytes),
    });
    std.debug.print("  write    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zerde.nsPerOp(),
        result.write_zerde.mibPerSec(result.zerde_write_bytes),
    });
    std.debug.print("  write zig-yaml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.write_zig_yaml.nsPerOp(),
        result.write_zig_yaml.mibPerSec(result.zig_yaml_write_bytes),
    });
    std.debug.print("  roundtrip    zerde: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zerde.nsPerOp(),
        result.roundtrip_zerde.mibPerSec(result.zerde_write_bytes * 2),
    });
    std.debug.print("  roundtrip zig-yaml: {d:.2} ns/op, {d:.2} MiB/s\n", .{
        result.roundtrip_zig_yaml.nsPerOp(),
        result.roundtrip_zig_yaml.mibPerSec(result.zig_yaml_write_bytes * 2),
    });
    std.debug.print("\n", .{});
}

fn zborParseOptions(allocator: Allocator) zbor.Options {
    return .{
        .allocator = allocator,
        .slice_serialization_type = .TextString,
        .ignore_unknown_fields = false,
    };
}

fn zborStringifyOptions() zbor.Options {
    return .{
        .slice_serialization_type = .TextString,
    };
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
        .description = "critical path release candidate",
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
        .description = "critical path release candidate",
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

fn makeBsonPayload(allocator: Allocator, scenario: Scenario) !BsonPayload {
    const endpoints = try allocator.alloc(BsonEndpoint, scenario.endpoint_count);
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
            .timeout_ms = @as(i32, @intCast(25 + ((i * 7) % 1500))),
            .retries = if (i % 3 == 0) null else @as(i32, @intCast((i % 5) + 1)),
            .weights = weight_templates[i % weight_templates.len],
            .enabled = (i % 5) != 0,
        };
    }

    const metrics = try allocator.alloc(BsonMetric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .name = metric_names[i % metric_names.len],
            .kind = switch (i % 3) {
                0 => .counter,
                1 => .gauge,
                else => .histogram,
            },
            .current = @as(i32, @intCast((i % 40_000))) - 20_000,
            .peak = @as(i32, @intCast(100_000 + (i % 4_000_000))),
            .ratio = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .note = optional_notes[i % optional_notes.len],
            .labels = .{
                label_pool[i % label_pool.len],
                label_pool[(i + 1) % label_pool.len],
                label_pool[(i + 2) % label_pool.len],
            },
        };
    }

    const events = try allocator.alloc(BsonEvent, scenario.event_count);
    errdefer allocator.free(events);
    for (events, 0..) |*event, i| {
        event.* = .{
            .id = @as(i32, @intCast(10_000 + i)),
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
            .duration_micros = @as(i32, @intCast(120 + (i % 35_000))),
            .cpu_load = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .signature = event_signatures[i % event_signatures.len][0..],
            .note = optional_notes[(i + 1) % optional_notes.len],
            .flags = flag_templates[i % flag_templates.len],
            .samples = .{
                @as(i32, sample_templates[i % sample_templates.len][0]),
                @as(i32, sample_templates[i % sample_templates.len][1]),
                @as(i32, sample_templates[i % sample_templates.len][2]),
                @as(i32, sample_templates[i % sample_templates.len][3]),
            },
        };
    }

    return .{
        .serviceName = "edge-api",
        .version = 7,
        .healthy = true,
        .build_number = -42,
        .primary_region = .us_east_1,
        .description = "critical path release candidate",
        .signature = payload_signature[0..],
        .metadata = .{
            .owner_id = 42,
            .shard_count = 16,
            .publicURL = "https://api.example.com/public",
            .trace_salt = trace_salt[0..],
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
    const endpoint_retries = try allocator.create([endpoint_count]u16);
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
        endpoint_retries[i] = @as(u16, @intCast((i % 5) + 1));
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

fn makeTomlParseView(value: anytype) TomlParsePayload {
    return .{
        .service_name = value.service_name,
        .version = value.version,
        .healthy = value.healthy,
        .build_number = value.build_number,
        .primary_region = value.primary_region,
        .description = value.description,
        .signature = value.signature,
        .metadata = value.metadata,
        .endpoints = .{
            .paths = value.endpoints.paths[0..],
            .methods = value.endpoints.methods[0..],
            .timeout_ms = value.endpoints.timeout_ms[0..],
            .retries = value.endpoints.retries[0..],
            .weights = value.endpoints.weights[0..],
            .enabled = value.endpoints.enabled[0..],
        },
        .metrics = .{
            .names = value.metrics.names[0..],
            .kinds = value.metrics.kinds[0..],
            .current = value.metrics.current[0..],
            .peak = value.metrics.peak[0..],
            .ratio = value.metrics.ratio[0..],
            .notes = value.metrics.notes[0..],
            .labels = value.metrics.labels[0..],
        },
        .events = .{
            .ids = value.events.ids[0..],
            .codes = value.events.codes[0..],
            .ok = value.events.ok[0..],
            .severity = value.events.severity[0..],
            .routes = value.events.routes[0..],
            .region = value.events.region[0..],
            .duration_micros = value.events.duration_micros[0..],
            .cpu_load = value.events.cpu_load[0..],
            .signatures = value.events.signatures[0..],
            .notes = value.events.notes[0..],
            .flags = value.events.flags[0..],
            .samples = value.events.samples[0..],
        },
        .sample_windows = value.sample_windows,
    };
}

fn makeYamlPayload(allocator: Allocator, scenario: Scenario) !YamlPayload {
    const routes = try allocator.alloc(YamlRoute, scenario.endpoint_count);
    errdefer allocator.free(routes);
    for (routes, 0..) |*route, i| {
        route.* = .{
            .island_name = island_pool[i % island_pool.len],
            .mission = switch (i % 4) {
                0 => .scout,
                1 => .supply,
                2 => .escort,
                else => .rescue,
            },
            .eta_hours = @as(u32, @intCast(6 + ((i * 11) % 240))),
            .reroutes = if (i % 3 == 0) null else @as(u8, @intCast((i % 5) + 1)),
            .wind_bias = weight_templates[i % weight_templates.len],
            .secured = (i % 5) != 0,
        };
    }

    const ledgers = try allocator.alloc(YamlLedger, scenario.metric_count);
    errdefer allocator.free(ledgers);
    for (ledgers, 0..) |*ledger, i| {
        ledger.* = .{
            .name = switch (i % 6) {
                0 => "berry-cache",
                1 => "cola-reserve",
                2 => "meat-locker",
                3 => "mini-merry-kit",
                4 => "viva-card-box",
                else => "snail-relay",
            },
            .kind = switch (i % 3) {
                0 => .bounty,
                1 => .cola,
                else => .supplies,
            },
            .current = @as(i64, @intCast((i % 40_000))) - 20_000,
            .peak = @as(u64, @intCast(100_000 + (i % 4_000_000))),
            .ratio = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .note = yaml_notes[i % yaml_notes.len],
            .tags = .{
                crew_tags[i % crew_tags.len],
                crew_tags[(i + 1) % crew_tags.len],
                crew_tags[(i + 2) % crew_tags.len],
            },
        };
    }

    const logs = try allocator.alloc(YamlLog, scenario.event_count);
    errdefer allocator.free(logs);
    for (logs, 0..) |*log, i| {
        log.* = .{
            .id = 10_000 + i,
            .code = @as(i32, @intCast((i % 5000))) - 2500,
            .cleared = (i % 11) != 0,
            .threat = switch (i % 3) {
                0 => .calm,
                1 => .storm,
                else => .emperor,
            },
            .route = island_pool[(i + 2) % island_pool.len],
            .sea = switch (i % 3) {
                0 => .east_blue,
                1 => .grand_line,
                else => .new_world,
            },
            .duration_minutes = @as(u32, @intCast(12 + (i % 35_000))),
            .wind_load = @as(f32, @floatFromInt(i % 1000)) / 1000.0,
            .note = yaml_notes[(i + 1) % yaml_notes.len],
            .flags = flag_templates[i % flag_templates.len],
            .samples = sample_templates[i % sample_templates.len],
        };
    }

    return .{
        .ship_name = "thousand-sunny",
        .voyage_no = 7,
        .ready_for_new_world = true,
        .bounty_delta = -42,
        .home_sea = .new_world,
        .crew_note = "gear-five-drill",
        .metadata = .{
            .captain_id = 56,
            .deck_count = 4,
            .flagship_name = "sunny",
            .eternal_pose = "laugh-tale",
            .alliance_name = "grand-fleet",
            .coup_de_burst_ready = true,
        },
        .routes = routes,
        .ledgers = ledgers,
        .logs = logs,
        .checkpoint_hours = .{ 12, 48, 96 },
    };
}

fn freeYamlPayload(allocator: Allocator, value: YamlPayload) void {
    allocator.free(value.routes);
    allocator.free(value.ledgers);
    allocator.free(value.logs);
}

fn assertRoundTripEqual(comptime T: type, expected: T, actual: T) !void {
    if (!deepEqual(T, expected, actual)) {
        std.debug.print("roundtrip mismatch for {s}\n", .{@typeName(T)});
        reportFirstMismatch(T, expected, actual, @typeName(T));
        return error.RoundTripMismatch;
    }
}

fn deepEqual(comptime T: type, expected: T, actual: T) bool {
    return switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => expected == actual,
        .optional => if (expected) |expected_child|
            if (actual) |actual_child|
                deepEqual(@TypeOf(expected_child), expected_child, actual_child)
            else
                false
        else
            actual == null,
        .array => |info| blk: {
            if (info.child == u8) break :blk std.mem.eql(u8, expected[0..], actual[0..]);
            for (expected, actual) |expected_item, actual_item| {
                if (!deepEqual(info.child, expected_item, actual_item)) break :blk false;
            }
            break :blk true;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                if (info.child == u8) break :blk std.mem.eql(u8, expected, actual);
                if (expected.len != actual.len) break :blk false;
                for (expected, actual) |expected_item, actual_item| {
                    if (!deepEqual(info.child, expected_item, actual_item)) break :blk false;
                }
                break :blk true;
            },
            .one => deepEqual(info.child, expected.*, actual.*),
            else => false,
        },
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!deepEqual(field.type, @field(expected, field.name), @field(actual, field.name))) {
                    break :blk false;
                }
            }
            break :blk true;
        },
        else => std.meta.eql(expected, actual),
    };
}

fn reportFirstMismatch(comptime T: type, expected: T, actual: T, comptime path: []const u8) void {
    switch (@typeInfo(T)) {
        .bool, .int, .comptime_int, .float, .comptime_float, .@"enum" => {
            std.debug.print("  {s}: expected {}, got {}\n", .{ path, expected, actual });
        },
        .optional => |info| {
            if ((expected == null) != (actual == null)) {
                std.debug.print("  {s}: expected {any}, got {any}\n", .{ path, expected, actual });
                return;
            }
            if (expected) |expected_child| {
                reportFirstMismatch(info.child, expected_child, actual.?, path);
            }
        },
        .array => |info| {
            if (info.child == u8) {
                if (!std.mem.eql(u8, expected[0..], actual[0..])) {
                    std.debug.print("  {s}: expected \"{s}\", got \"{s}\"\n", .{ path, expected[0..], actual[0..] });
                }
                return;
            }
            for (expected, actual, 0..) |expected_item, actual_item, i| {
                if (!deepEqual(info.child, expected_item, actual_item)) {
                    std.debug.print("  mismatch at {s}[{d}]\n", .{ path, i });
                    reportFirstMismatch(info.child, expected_item, actual_item, std.fmt.comptimePrint("{s}[]", .{path}));
                    return;
                }
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                if (info.child == u8) {
                    if (!std.mem.eql(u8, expected, actual)) {
                        std.debug.print("  {s}: expected \"{s}\", got \"{s}\"\n", .{ path, expected, actual });
                    }
                    return;
                }
                if (expected.len != actual.len) {
                    std.debug.print("  {s}: expected len {d}, got {d}\n", .{ path, expected.len, actual.len });
                    return;
                }
                for (expected, actual, 0..) |expected_item, actual_item, i| {
                    if (!deepEqual(info.child, expected_item, actual_item)) {
                        std.debug.print("  mismatch at {s}[{d}]\n", .{ path, i });
                        reportFirstMismatch(info.child, expected_item, actual_item, std.fmt.comptimePrint("{s}[]", .{path}));
                        return;
                    }
                }
            },
            .one => reportFirstMismatch(info.child, expected.*, actual.*, path),
            else => std.debug.print("  {s}: pointer mismatch in unsupported pointer shape\n", .{path}),
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const expected_field = @field(expected, field.name);
                const actual_field = @field(actual, field.name);
                if (!deepEqual(field.type, expected_field, actual_field)) {
                    reportFirstMismatch(
                        field.type,
                        expected_field,
                        actual_field,
                        std.fmt.comptimePrint("{s}.{s}", .{ path, field.name }),
                    );
                    return;
                }
            }
            std.debug.print("  {s}: values differ\n", .{path});
        },
        else => std.debug.print("  {s}: mismatch in unsupported type {s}\n", .{ path, @typeName(T) }),
    }
}

fn consumeTomlParsed(value: anytype) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metadata.shard_count);
    std.mem.doNotOptimizeAway(value.endpoints.paths.len);
    std.mem.doNotOptimizeAway(value.metrics.names.len);
    std.mem.doNotOptimizeAway(value.events.ids.len);
    std.mem.doNotOptimizeAway(@intFromPtr(value.endpoints.paths.ptr));
    std.mem.doNotOptimizeAway(@intFromPtr(value.metrics.names.ptr));
    std.mem.doNotOptimizeAway(@intFromPtr(value.events.ids.ptr));
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

fn consumeBsonPayload(value: BsonPayload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metadata.shard_count);
    std.mem.doNotOptimizeAway(value.endpoints.len);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.events.len);
}

fn consumeYamlPayload(value: YamlPayload) void {
    std.mem.doNotOptimizeAway(value.voyage_no);
    std.mem.doNotOptimizeAway(value.metadata.deck_count);
    std.mem.doNotOptimizeAway(value.routes.len);
    std.mem.doNotOptimizeAway(value.ledgers.len);
    std.mem.doNotOptimizeAway(value.logs.len);
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

fn freeBsonPayload(allocator: Allocator, value: BsonPayload) void {
    allocator.free(value.endpoints);
    allocator.free(value.metrics);
    allocator.free(value.events);
}
