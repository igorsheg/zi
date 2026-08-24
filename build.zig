const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zi = b.addModule("zi", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zi.link_libc = true;
    zi.linkSystemLibrary("curl", .{ .use_pkg_config = .yes });

    const executable = b.addExecutable(.{
        .name = "zi",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zi", .module = zi }},
        }),
    });
    b.installArtifact(executable);

    const run = b.addRunArtifact(executable);
    run.step.dependOn(b.getInstallStep());
    if (b.args) |arguments| run.addArgs(arguments);
    b.step("run", "Run zi").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = zi });
    const run_tests = b.addRunArtifact(tests);
    b.step("test", "Run unit tests").dependOn(&run_tests.step);
}
