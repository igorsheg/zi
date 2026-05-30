const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vaxis_dep = b.dependency("vaxis", .{
        .target = target,
        .optimize = optimize,
    });
    zi.addImport("vaxis", vaxis_dep.module("vaxis"));

    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zi", .module = zi },
            },
        }),
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
        }),
    });
    const generate_models_cmd = b.addRunArtifact(generate_models);
    generate_models_cmd.addArg("src/ai/models.generated.zig");
    b.step("generate-models", "Generate AI model table").dependOn(&generate_models_cmd.step);

    const lib_tests = b.addTest(.{ .root_module = zi });
    const exe_tests = b.addTest(.{ .root_module = exe.root_module });

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(exe_tests).step);

    // PTY harness drives the real binary under a pseudo-terminal and needs
    // libc (openpty). Kept on its own step so the unit suite stays libc-free
    // and hermetic.
    const pty_options = b.addOptions();
    pty_options.addOptionPath("zi_bin_path", exe.getEmittedBin());

    const pty_test_module = b.createModule(.{
        .root_source_file = b.path("src/tui/substrate/pty.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    pty_test_module.addOptions("pty_options", pty_options);
    const pty_tests = b.addTest(.{ .root_module = pty_test_module });
    const pty_test_step = b.step("pty-test", "Run PTY harness tests (links libc)");
    pty_test_step.dependOn(&b.addRunArtifact(pty_tests).step);
}
