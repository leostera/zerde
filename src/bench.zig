const std = @import("std");
const zerde = @import("zerde");

const Allocator = std.mem.Allocator;
const target_bytes_per_benchmark: usize = 64 * 1024 * 1024;

const Scenario = struct {
    name: []const u8,
    metric_count: usize,
    sample_count: usize,
    string_padding: usize,
};

const scenarios = [_]Scenario{
    .{
        .name = "small",
        .metric_count = 4,
        .sample_count = 32,
        .string_padding = 16,
    },
    .{
        .name = "medium",
        .metric_count = 2_048,
        .sample_count = 180_000,
        .string_padding = 256,
    },
    .{
        .name = "large",
        .metric_count = 16_384,
        .sample_count = 18_000_000,
        .string_padding = 1_024,
    },
};

const Metric = struct {
    id: u64,
    code: u16,
    durationMicros: u32,
    ok: bool,

    pub const serde = .{
        .rename_all = .snake_case,
    };
};

const Metadata = struct {
    ownerId: u64,
    shardCount: u16,
    publicUrl: []const u8,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .publicUrl = .{ .rename = "publicURL" },
        },
    };
};

const Payload = struct {
    serviceName: []const u8,
    version: u32,
    healthy: bool,
    metrics: []const Metric,
    samples: []const u16,
    metadata: Metadata,

    pub const serde = .{
        .rename_all = .snake_case,
        .fields = .{
            .serviceName = .{ .rename = "serviceName" },
        },
    };
};

const StdMetric = struct {
    id: u64,
    code: u16,
    duration_micros: u32,
    ok: bool,
};

const StdMetadata = struct {
    owner_id: u64,
    shard_count: u16,
    publicURL: []const u8,
};

const StdPayload = struct {
    serviceName: []const u8,
    version: u32,
    healthy: bool,
    metrics: []const StdMetric,
    samples: []const u16,
    metadata: StdMetadata,
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
    std.debug.print("scenarios: small, medium, large (~100 MiB)\n\n", .{});

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
    const bytes = bench_case.json().len;
    const parse_iterations = iterationsForBytes(bytes);
    const write_iterations = iterationsForBytes(bytes);

    return .{
        .parse_zerde = .{
            .iterations = parse_iterations,
            .total_ns = try benchZerdeParse(io, bench_case.json(), parse_iterations),
        },
        .parse_std = .{
            .iterations = parse_iterations,
            .total_ns = try benchStdParse(io, bench_case.json(), parse_iterations),
        },
        .write_zerde = .{
            .iterations = write_iterations,
            .total_ns = try benchZerdeSerialize(io, bench_case.zerde_value, write_iterations),
        },
        .write_std = .{
            .iterations = write_iterations,
            .total_ns = try benchStdSerialize(io, bench_case.std_value, write_iterations),
        },
    };
}

fn benchZerdeParse(io: std.Io, input: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    const start = std.Io.Clock.Timestamp.now(io, .awake);
    for (0..iterations) |_| {
        _ = arena.reset(.retain_capacity);
        const value = try zerde.parseSlice(zerde.json, Payload, arena.allocator(), input);
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

fn iterationsForBytes(bytes: usize) usize {
    if (bytes == 0) return 1;
    const raw = target_bytes_per_benchmark / bytes;
    return @max(@as(usize, 1), @min(@as(usize, 100_000), raw));
}

fn bytesToMiB(bytes: usize) f64 {
    return @as(f64, @floatFromInt(bytes)) / (1024.0 * 1024.0);
}

fn makePayload(allocator: Allocator, scenario: Scenario) !Payload {
    const service_name = try makeAsciiBlob(allocator, "edge-api-", scenario.string_padding);
    errdefer allocator.free(service_name);

    const public_url = try makeAsciiBlob(allocator, "https://api.example.com/", scenario.string_padding);
    errdefer allocator.free(public_url);

    const metrics = try allocator.alloc(Metric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .id = i + 1,
            .code = @as(u16, @intCast(200 + (i % 55))),
            .durationMicros = @as(u32, @intCast(500 + (i % 10_000))),
            .ok = (i % 9) != 0,
        };
    }

    const samples = try allocator.alloc(u16, scenario.sample_count);
    errdefer allocator.free(samples);
    for (samples, 0..) |*sample, i| {
        sample.* = @as(u16, @intCast(10_000 + (i % 50_000)));
    }

    return .{
        .serviceName = service_name,
        .version = 7,
        .healthy = true,
        .metrics = metrics,
        .samples = samples,
        .metadata = .{
            .ownerId = 42,
            .shardCount = 16,
            .publicUrl = public_url,
        },
    };
}

fn makeStdPayload(allocator: Allocator, scenario: Scenario) !StdPayload {
    const service_name = try makeAsciiBlob(allocator, "edge-api-", scenario.string_padding);
    errdefer allocator.free(service_name);

    const public_url = try makeAsciiBlob(allocator, "https://api.example.com/", scenario.string_padding);
    errdefer allocator.free(public_url);

    const metrics = try allocator.alloc(StdMetric, scenario.metric_count);
    errdefer allocator.free(metrics);
    for (metrics, 0..) |*metric, i| {
        metric.* = .{
            .id = i + 1,
            .code = @as(u16, @intCast(200 + (i % 55))),
            .duration_micros = @as(u32, @intCast(500 + (i % 10_000))),
            .ok = (i % 9) != 0,
        };
    }

    const samples = try allocator.alloc(u16, scenario.sample_count);
    errdefer allocator.free(samples);
    for (samples, 0..) |*sample, i| {
        sample.* = @as(u16, @intCast(10_000 + (i % 50_000)));
    }

    return .{
        .serviceName = service_name,
        .version = 7,
        .healthy = true,
        .metrics = metrics,
        .samples = samples,
        .metadata = .{
            .owner_id = 42,
            .shard_count = 16,
            .publicURL = public_url,
        },
    };
}

fn makeAsciiBlob(allocator: Allocator, prefix: []const u8, padding: usize) ![]u8 {
    const bytes = try allocator.alloc(u8, prefix.len + padding);
    @memcpy(bytes[0..prefix.len], prefix);
    for (bytes[prefix.len..], 0..) |*byte, i| {
        byte.* = @as(u8, @intCast('a' + @as(u8, @intCast(i % 26))));
    }
    return bytes;
}

fn consumePayload(value: Payload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.samples.len);
}

fn consumeStdPayload(value: StdPayload) void {
    std.mem.doNotOptimizeAway(value.version);
    std.mem.doNotOptimizeAway(value.metrics.len);
    std.mem.doNotOptimizeAway(value.samples.len);
}

fn freePayload(allocator: Allocator, value: Payload) void {
    allocator.free(value.serviceName);
    allocator.free(value.metrics);
    allocator.free(value.samples);
    allocator.free(value.metadata.publicUrl);
}

fn freeStdPayload(allocator: Allocator, value: StdPayload) void {
    allocator.free(value.serviceName);
    allocator.free(value.metrics);
    allocator.free(value.samples);
    allocator.free(value.metadata.publicURL);
}
