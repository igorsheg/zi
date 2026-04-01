const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // --- packages/ai ---
    const ai_mod = b.addModule("zi-ai", .{
        .root_source_file = b.path("packages/ai/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ai unit tests
    const ai_tests = b.addTest(.{
        .root_module = ai_mod,
    });
    const run_ai_tests = b.addRunArtifact(ai_tests);

    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&run_ai_tests.step);

    const ai_test_step = b.step("test-ai", "Run ai package tests");
    ai_test_step.dependOn(&run_ai_tests.step);
}
