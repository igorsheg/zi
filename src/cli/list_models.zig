const std = @import("std");
const ai = @import("../ai/root.zig");
const auth = @import("../auth/root.zig");
const settings_mod = @import("../settings/root.zig");
const common = @import("common.zig");

const stdout: std.fs.File = .{ .handle = std.posix.STDOUT_FILENO };
const stderr: std.fs.File = .{ .handle = std.posix.STDERR_FILENO };

pub fn run(allocator: std.mem.Allocator) !void {
    var auth_storage = auth.storage.AuthStorage.create(allocator, null) catch {
        try stderr.writeAll("warning: could not load auth storage\n");
        unreachable;
    };
    _ = &auth_storage;

    const cwd = std.fs.cwd().realpathAlloc(allocator, ".") catch "/unknown";
    var settings = settings_mod.manager.SettingsManager.create(allocator, cwd, null) catch {
        try stderr.writeAll("warning: could not load settings\n");
        unreachable;
    };
    _ = &settings;

    const custom_models = common.convertCustomModels(allocator, settings.getModels()) catch &.{};
    var registry = ai.model_registry.ModelRegistry.init(
        allocator,
        &auth_storage,
        custom_models,
    ) catch {
        try stderr.writeAll("error: could not build model registry\n");
        std.process.exit(1);
    };

    for (registry.getAll()) |m| {
        stdout.writeAll(ai.provider.apiToString(m.api)) catch {};
        stdout.writeAll("\t") catch {};
        stdout.writeAll(m.id) catch {};
        stdout.writeAll("\t") catch {};
        stdout.writeAll(m.name) catch {};
        stdout.writeAll("\n") catch {};
    }
}
