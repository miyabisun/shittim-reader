const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Core library module ──
    const lib_mod = b.addModule("shittim_reader", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // ── CLI executable (developer tool) ──
    const exe = b.addExecutable(.{
        .name = "shittim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "shittim_reader", .module = lib_mod },
            },
        }),
    });
    b.installArtifact(exe);

    // ── Run step ──
    const run_step = b.step("run", "Run the CLI tool");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // ── Tests ──
    const test_step = b.step("test", "Run all unit tests");

    // Library unit tests (src/ only — no test fixture data)
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);

    // CLI tests
    const exe_tests = b.addTest(.{
        .root_module = exe.root_module,
    });
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // OCR integration tests (test fixtures embedded from test_fixtures/)
    const ocr_fixture_mod = b.createModule(.{
        .root_source_file = b.path("test_fixtures/ocr_fixtures.zig"),
        .target = target,
    });
    const ocr_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/ocr_test.zig"),
            .target = target,
            .imports = &.{
                .{ .name = "shittim_reader", .module = lib_mod },
                .{ .name = "ocr_fixtures", .module = ocr_fixture_mod },
            },
        }),
    });
    test_step.dependOn(&b.addRunArtifact(ocr_tests).step);
}
