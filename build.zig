const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const zio_dep = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    zi.addImport("zio", zio_dep.module("zio"));

    const uucode_dep = b.dependency("uucode", .{
        .target = target,
        .optimize = optimize,
        .fields = @as([]const []const u8, &.{
            "grapheme_break",
            "is_emoji_modifier_base",
            "is_emoji_vs_base",
            "wcwidth_standalone",
            "wcwidth_zero_in_grapheme",
        }),
    });
    zi.addImport("uucode", uucode_dep.module("uucode"));

    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zio", .module = zio_dep.module("zio") },
                .{ .name = "uucode", .module = uucode_dep.module("uucode") },
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

    _ = b.step("pty-test", "PTY harness removed with ADR 0006 TUI reset");
}
