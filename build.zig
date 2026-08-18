const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zi", .module = zi }},
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run zi").dependOn(&run.step);

    const model_catalog_module = b.createModule(.{
        .root_source_file = b.path("src/ai/model_catalog.zig"),
        .target = b.graph.host,
        .optimize = optimize,
    });
    const model_catalog_tool_module = b.createModule(.{
        .root_source_file = b.path("tools/model_catalog.zig"),
        .target = b.graph.host,
        .optimize = optimize,
        .imports = &.{.{ .name = "catalog", .module = model_catalog_module }},
    });
    const model_catalog_tool = b.addExecutable(.{
        .name = "zi-model-catalog",
        .root_module = model_catalog_tool_module,
    });
    const model_catalog_tool_tests = b.addTest(.{
        .root_module = model_catalog_tool_module,
    });
    const run_model_catalog_tool_tests = b.addRunArtifact(model_catalog_tool_tests);
    const run_model_catalog_check = b.addRunArtifact(model_catalog_tool);
    run_model_catalog_check.addArgs(&.{
        "check",
        "data/model_catalog.json",
        "src/ai/model_catalog_snapshot.zig",
    });
    const model_catalog_check = b.step("check-model-catalog", "Verify the generated model catalog snapshot");
    model_catalog_check.dependOn(&run_model_catalog_check.step);
    const run_model_catalog_update = b.addRunArtifact(model_catalog_tool);
    run_model_catalog_update.addArgs(&.{
        "update",
        "data/model_catalog.json",
        "src/ai/model_catalog_snapshot.zig",
    });
    const model_catalog_update = b.step("update-model-catalog", "Regenerate the model catalog snapshot");
    model_catalog_update.dependOn(&run_model_catalog_update.step);

    const tests = b.addTest(.{ .root_module = zi });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run library tests");
    test_step.dependOn(&run_tests.step);
    test_step.dependOn(&run_model_catalog_tool_tests.step);
    test_step.dependOn(&run_model_catalog_check.step);
}
