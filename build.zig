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

    // ── Dev tools ──

    // fetch-icons: HTTP only, no library dependencies
    addStandaloneDevTool(b, "fetch-icons", "Download icons from SchaleDB", "tools/fetch_icons.zig");

    // Tools requiring zigimg (lazy dependency, fetched only when step is invoked)
    if (b.lazyDependency("zigimg", .{})) |dep| {
        const zigimg = dep.module("zigimg");
        // split-cells: extract individual cell PNGs from a cropped grid image
        addDevTool(b, lib_mod, zigimg, "split-cells", "Split grid image into cell PNGs", "tools/split_cells.zig");
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

fn addStandaloneDevTool(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    source: []const u8,
) void {
    const tool_exe = b.addExecutable(.{
        .name = step_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
        }),
    });
    const step = b.step(step_name, description);
    const run = b.addRunArtifact(tool_exe);
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}

fn addDevTool(
    b: *std.Build,
    lib_mod: *std.Build.Module,
    zigimg: *std.Build.Module,
    step_name: []const u8,
    description: []const u8,
    source: []const u8,
) void {
    const tool_exe = b.addExecutable(.{
        .name = step_name,
        .root_module = b.createModule(.{
            .root_source_file = b.path(source),
            .target = b.graph.host,
            .imports = &.{
                .{ .name = "shittim_reader", .module = lib_mod },
                .{ .name = "zigimg", .module = zigimg },
            },
        }),
    });
    const step = b.step(step_name, description);
    const run = b.addRunArtifact(tool_exe);
    if (b.args) |args| run.addArgs(args);
    step.dependOn(&run.step);
}
