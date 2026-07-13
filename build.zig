const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Omit debug information") orelse false;
    const version = b.option([]const u8, "version", "Zi version string") orelse "0.0.1-dev";

    const app_options = b.addOptions();
    app_options.addOption([]const u8, "version", version);
    app_options.addOption([]const u8, "node_executable", b.findProgram(&.{"node"}, &.{}) catch "node");

    const host_sources = [_][]const u8{
        "extensions/api/index.d.ts",
        "extensions/api/package.json",
        "extensions/host/package.json",
        "extensions/host/package-lock.json",
        "extensions/host/tsconfig.json",
        "extensions/host/scripts/build.mjs",
        "extensions/host/scripts/typecheck.mjs",
        "extensions/host/src/api.ts",
        "extensions/host/src/framing.ts",
        "extensions/host/src/loader.ts",
        "extensions/host/src/main.ts",
        "extensions/host/src/protocol.ts",
        "extensions/host/src/transport.ts",
    };
    const host_typecheck = b.addSystemCommand(&.{ "node", "extensions/host/scripts/typecheck.mjs" });
    const host_bundle = b.addSystemCommand(&.{ "node", "extensions/host/scripts/build.mjs" });
    for (host_sources) |source| {
        host_typecheck.addFileInput(b.path(source));
        host_bundle.addFileInput(b.path(source));
    }
    host_bundle.step.dependOn(&host_typecheck.step);
    const host_bundle_path = host_bundle.addOutputFileArg("extension-host.mjs");
    const host_digest_path = host_bundle.addOutputFileArg("extension-host-digest.zig");

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    zi.addOptions("build_options", app_options);
    zi.addAnonymousImport("extension_host_bundle", .{ .root_source_file = host_bundle_path });
    zi.addAnonymousImport("extension_host_digest", .{ .root_source_file = host_digest_path });
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
    exe_module.addAnonymousImport("extension_host_bundle", .{ .root_source_file = host_bundle_path });
    exe_module.addAnonymousImport("extension_host_digest", .{ .root_source_file = host_digest_path });
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
    const zio_import_check_step = b.step(
        "check-zio-imports",
        "Ensure zio is only imported by the private runtime backend",
    );
    zio_import_check_step.dependOn(&zio_import_check.step);

    const host_tests = b.addSystemCommand(&.{ "npm", "--prefix", "extensions/host", "test" });
    host_tests.addFileInput(b.path("extensions/api/index.d.ts"));
    host_tests.addFileInput(b.path("extensions/api/package.json"));
    host_tests.addFileInput(b.path("extensions/host/package.json"));
    host_tests.addFileInput(b.path("extensions/host/package-lock.json"));
    host_tests.addFileInput(b.path("extensions/host/tsconfig.json"));
    host_tests.addFileInput(b.path("extensions/host/src/api.ts"));
    host_tests.addFileInput(b.path("extensions/host/src/framing.ts"));
    host_tests.addFileInput(b.path("extensions/host/src/loader.ts"));
    host_tests.addFileInput(b.path("extensions/host/src/main.ts"));
    host_tests.addFileInput(b.path("extensions/host/src/protocol.ts"));
    host_tests.addFileInput(b.path("extensions/host/src/transport.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/api.test.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/framing.test.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/loader.test.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/protocol.test.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/transport.test.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/fixtures/extension.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/fixtures/fixture-package/index.d.ts"));
    host_tests.addFileInput(b.path("extensions/host/test/fixtures/fixture-package/index.js"));
    host_tests.addFileInput(b.path("extensions/host/test/fixtures/fixture-package/package.json"));
    b.step("host-test", "Run extension host tests").dependOn(&host_tests.step);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&zio_import_check.step);
    test_step.dependOn(&host_tests.step);
    // Serialized: the suites contain wall-clock frame-budget tests that flake
    // when a sibling test binary saturates the machine concurrently.
    const lib_tests_run = b.addRunArtifact(lib_tests);
    const exe_tests_run = b.addRunArtifact(exe_tests);
    exe_tests_run.step.dependOn(&lib_tests_run.step);
    test_step.dependOn(&exe_tests_run.step);

    const pty_tests = b.addTest(.{
        .name = "pty-e2e-test",
        .root_module = zi,
        .filters = &.{"pty e2e"},
    });
    const pty_tests_run = b.addRunArtifact(pty_tests);
    pty_tests_run.step.dependOn(&zio_import_check.step);
    pty_tests_run.step.dependOn(b.getInstallStep());
    pty_tests_run.setEnvironmentVariable("ZI_PTY_E2E_BIN", b.getInstallPath(.bin, "zi"));
    b.step("pty-test", "Run TUI pty end-to-end tests").dependOn(&pty_tests_run.step);
}
