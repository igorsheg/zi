const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const version = b.option([]const u8, "version", "Zi version string") orelse "0.0.1-dev";

    const app_options = b.addOptions();
    app_options.addOption([]const u8, "version", version);

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    zi.addOptions("build_options", app_options);
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    zi.addImport("zio", zio_dep.module("zio"));

    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    zi.addImport("vaxis", vaxis_dep.module("vaxis"));

    const exe_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zio", .module = zio_dep.module("zio") },
            .{ .name = "vaxis", .module = vaxis_dep.module("vaxis") },
        },
    });
    exe_module.addOptions("build_options", app_options);
    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = exe_module,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zi").dependOn(&run_cmd.step);

    const generate_models = b.addExecutable(.{
        .name = "generate-models",
        .root_module = b.createModule(.{
            .root_source_file = b.path("scripts/generate-models.zig"),
            .target = target,
            .optimize = optimize,
            .strip = strip,
        }),
    });
    const generate_models_cmd = b.addRunArtifact(generate_models);
    generate_models_cmd.addArg("src/ai/models.generated.zig");
    b.step("generate-models", "Generate AI model table").dependOn(&generate_models_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = zi });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const zio_import_check = b.addSystemCommand(&.{
        "sh",
        "-c",
        "if grep -R '@import(\"zio\")\\|\\bzio\\.' -n src | grep -v 'src/runtime/zio_backend.zig'; then exit 1; fi",
    });
    const zio_import_check_step = b.step("check-zio-imports", "Ensure zio is only imported by the private runtime backend");
    zio_import_check_step.dependOn(&zio_import_check.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&zio_import_check.step);
    // Serialized: the suites contain wall-clock frame-budget tests that flake
    // when a sibling test binary saturates the machine concurrently.
    const lib_tests_run = b.addRunArtifact(lib_tests);
    const exe_tests_run = b.addRunArtifact(exe_tests);
    exe_tests_run.step.dependOn(&lib_tests_run.step);
    test_step.dependOn(&exe_tests_run.step);

    _ = b.step("pty-test", "PTY harness removed with TUI reset");
}
