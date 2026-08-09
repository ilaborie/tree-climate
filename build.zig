const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});

    // ReleaseSafe rather than ReleaseFast, so `zig build --release` keeps bounds
    // checks and the safety panics. They cost nothing measurable here: the
    // pipeline spends its time in pdftotext, curl, magick and Typst, not in
    // this code.
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const app = b.addModule("tree_climate", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "tree-climate",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tree_climate", .module = app }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run the pipeline binary").dependOn(&run.step);

    // Unit tests: pure modules only, no filesystem, no subprocess. Fast enough
    // to be the inner development loop.
    //
    // `std.testing.fuzz` targets belong here too. Note that coverage-guided
    // fuzzing (`zig build test --fuzz`) does not work on this toolchain:
    // Zig 0.16.0 ships a test runner that fails to compile in fuzz mode
    // (`compiler/test_runner.zig:566`, a StackTrace type mismatch), reproducible
    // on a stock `zig init`. Fuzz targets still run as ordinary one-shot
    // property tests under `zig build test`, and will become coverage-guided
    // with no code change once upstream fixes the runner.
    const unit_tests = b.addTest(.{ .root_module = app });
    b.step("test", "Run unit tests").dependOn(&b.addRunArtifact(unit_tests).step);

    // Golden tests: everything that reads the repository or shells out. Kept in
    // a separate step so the inner loop stays fast.
    const golden_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/golden.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "tree_climate", .module = app }},
        }),
    });
    const run_golden = b.addRunArtifact(golden_tests);
    run_golden.setCwd(b.path("."));
    b.step("test-golden", "Run tests that read the repository").dependOn(&run_golden.step);

    const fmt = b.addFmt(.{
        .paths = &.{ "build.zig", "build.zig.zon", "src", "tests" },
        .check = true,
    });
    b.step("fmt", "Check formatting").dependOn(&fmt.step);
}
