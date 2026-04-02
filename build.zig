const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── L2: ai — LLM substrate (no internal deps) ──────────────────────
    const ai = b.addModule("ai", .{
        .root_source_file = b.path("packages/ai/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ── L4: agent — stateful agent (depends on ai) ─────────────────────
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("packages/agent/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent.addImport("ai", ai);

    // ── executable ──────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ai", ai);
    exe_mod.addImport("agent", agent);

    const exe = b.addExecutable(.{
        .name = "zi",
        .root_module = exe_mod,
    });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run zi").dependOn(&run_cmd.step);

    // ── tests ───────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run all tests");

    const ai_tests = b.addTest(.{ .root_module = ai });
    test_step.dependOn(&b.addRunArtifact(ai_tests).step);
    b.step("test-ai", "Test ai package").dependOn(&b.addRunArtifact(ai_tests).step);

    const agent_tests = b.addTest(.{ .root_module = agent });
    test_step.dependOn(&b.addRunArtifact(agent_tests).step);
    b.step("test-agent", "Test agent package").dependOn(&b.addRunArtifact(agent_tests).step);
}
