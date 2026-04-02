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

    // ── L3: auth — credential storage (depends on ai for env key lookup) ─
    const auth = b.addModule("auth", .{
        .root_source_file = b.path("packages/auth/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    auth.addImport("ai", ai);

    // ── L3: settings — user preferences (depends on ai for Transport) ──
    const settings = b.addModule("settings", .{
        .root_source_file = b.path("packages/settings/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    settings.addImport("ai", ai);

    // ── L4: agent — stateful agent (depends on ai) ─────────────────────
    const agent = b.addModule("agent", .{
        .root_source_file = b.path("packages/agent/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    agent.addImport("ai", ai);

    // ── L5: session — session persistence (depends on ai, agent) ─────
    const session = b.addModule("session", .{
        .root_source_file = b.path("packages/session/src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    session.addImport("ai", ai);
    session.addImport("agent", agent);

    // ── executable ──────────────────────────────────────────────────────
    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    exe_mod.addImport("ai", ai);
    exe_mod.addImport("auth", auth);
    exe_mod.addImport("settings", settings);
    exe_mod.addImport("agent", agent);
    exe_mod.addImport("session", session);

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

    const auth_tests = b.addTest(.{ .root_module = auth });
    test_step.dependOn(&b.addRunArtifact(auth_tests).step);
    b.step("test-auth", "Test auth package").dependOn(&b.addRunArtifact(auth_tests).step);

    const settings_tests = b.addTest(.{ .root_module = settings });
    test_step.dependOn(&b.addRunArtifact(settings_tests).step);
    b.step("test-settings", "Test settings package").dependOn(&b.addRunArtifact(settings_tests).step);

    const agent_tests = b.addTest(.{ .root_module = agent });
    test_step.dependOn(&b.addRunArtifact(agent_tests).step);
    b.step("test-agent", "Test agent package").dependOn(&b.addRunArtifact(agent_tests).step);

    const session_tests = b.addTest(.{ .root_module = session });
    test_step.dependOn(&b.addRunArtifact(session_tests).step);
    b.step("test-session", "Test session package").dependOn(&b.addRunArtifact(session_tests).step);
}
