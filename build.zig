const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const zig_toml_dep = b.dependency("toml", .{
        .target = target,
        .optimize = optimize,
    });
    const zbor_dep = b.dependency("zbor", .{
        .target = target,
        .optimize = optimize,
    });

    // The package itself is just `src/root.zig`; tests and benchmarks import it.
    const zerde_mod = b.addModule("zerde", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // `zig build test` exercises the library as a package module.
    const tests = b.addTest(.{
        .root_module = zerde_mod,
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run zerde tests");
    test_step.dependOn(&run_tests.step);

    // Benchmarks live in a separate executable so they can use a different root file.
    const bench_exe = b.addExecutable(.{
        .name = "zerde-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("bench/bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zerde", .module = zerde_mod },
                .{ .name = "zig_toml", .module = zig_toml_dep.module("toml") },
                .{ .name = "zbor", .module = zbor_dep.module("zbor") },
            },
        }),
    });
    b.installArtifact(bench_exe);

    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);

    const run_bench_json = b.addRunArtifact(bench_exe);
    run_bench_json.addArg("json");

    const run_bench_toml = b.addRunArtifact(bench_exe);
    run_bench_toml.addArg("toml");

    const run_bench_cbor = b.addRunArtifact(bench_exe);
    run_bench_cbor.addArg("cbor");

    const bench_step = b.step("bench", "Run JSON, TOML, and CBOR benchmarks");
    bench_step.dependOn(&run_bench.step);

    const bench_json_step = b.step("bench-json", "Run JSON benchmark against std.json");
    bench_json_step.dependOn(&run_bench_json.step);

    const bench_toml_step = b.step("bench-toml", "Run TOML benchmark against zig-toml");
    bench_toml_step.dependOn(&run_bench_toml.step);

    const bench_cbor_step = b.step("bench-cbor", "Run CBOR benchmark against zbor");
    bench_cbor_step.dependOn(&run_bench_cbor.step);
}
