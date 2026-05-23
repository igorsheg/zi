const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");
const runtime_env = @import("env.zig");
const runtime_storage = @import("storage.zig");
const log = @import("log.zig");
const cli = @import("../coding_agent/cli/root.zig");
const provider_runtime = @import("../coding_agent/provider_runtime.zig");
const settings_mod = @import("../settings/root.zig");

pub const name = "zi";
pub const version = build_options.version;
pub const tagline = "AI coding agent";

pub fn writeVersionLine(writer: anytype) !void {
    try writer.print("{s} {s}\n", .{ name, version });
}

pub const use_debug_allocator = builtin.mode == .Debug;

pub const MainHeap = struct {
    debug_allocator: if (use_debug_allocator) std.heap.DebugAllocator(.{}) else void = if (use_debug_allocator) .init else {},

    pub fn allocator(self: *MainHeap) std.mem.Allocator {
        return if (use_debug_allocator) self.debug_allocator.allocator() else std.heap.smp_allocator;
    }

    pub fn deinit(self: *MainHeap) void {
        if (use_debug_allocator) {
            switch (self.debug_allocator.deinit()) {
                .ok => {},
                .leak => @panic("memory leak detected"),
            }
        }
    }
};

pub const Caps = struct {
    io: std.Io,
    env: runtime_env.Env,
    allocator: std.mem.Allocator,
};

pub fn main(init: std.process.Init) !void {
    log.setThreadLabel(.main);
    const env = runtime_env.Env.from(init.environ_map);

    var heap: MainHeap = .{};
    defer heap.deinit();

    const allocator = heap.allocator();

    var log_session = try log.init(allocator, .{
        .io = init.io,
        .sink = .stderr,
        .min_level = .info,
    });
    defer log_session.deinit();

    const caps: Caps = .{
        .io = init.io,
        .env = env,
        .allocator = allocator,
    };

    var storage = try runtime_storage.Storage.initForProcess(allocator, init.io, env);
    defer storage.deinit();

    var settings = try settings_mod.load(allocator, init.io, storage);
    defer settings.deinit();

    var cli_runtime = try provider_runtime.ProviderRuntime.initWithOptions(allocator, init.io, env, .{
        .settings_models = settings.models,
    });
    defer cli_runtime.deinit();

    const exit_code = try runCli(caps, init.minimal.args, &cli_runtime, settings);
    if (exit_code != 0) std.process.exit(exit_code);
}

fn runCli(caps: Caps, process_args: std.process.Args, cli_runtime: *provider_runtime.ProviderRuntime, settings: settings_mod.Settings) !u8 {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(caps.allocator);
    var it = std.process.Args.Iterator.init(process_args);
    _ = it.next();
    while (it.next()) |arg| try args.append(caps.allocator, arg);

    var raw = switch (try cli.parse.parse(caps.allocator, args.items)) {
        .ok => |command| command,
        .err => |diag| {
            try writeParseDiagnostic(caps.io, diag);
            return 1;
        },
    };
    defer raw.deinit(caps.allocator);

    var planned = switch (try cli.plan.build(caps.allocator, raw, settings)) {
        .ok => |plan| cli.plan.Result{ .ok = plan },
        .err => |diag| {
            try writePlanDiagnostic(caps.io, diag);
            return 1;
        },
    };
    defer planned.deinit(caps.allocator);

    const result = try cli.dispatch.run(.{ .allocator = caps.allocator, .io = caps.io, .provider_runtime = cli_runtime }, planned.ok);
    switch (result) {
        .ok => return 0,
        .err => |diag| {
            try writeResultDiagnostic(caps.io, diag);
            return 1;
        },
    }
}

fn writeParseDiagnostic(io: std.Io, diag: cli.parse.Diagnostic) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    try cli.diagnostics.writeParse(&writer.interface, diag);
    try writer.interface.flush();
}

fn writePlanDiagnostic(io: std.Io, diag: cli.plan.Diagnostic) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    try cli.diagnostics.writePlan(&writer.interface, diag);
    try writer.interface.flush();
}

fn writeResultDiagnostic(io: std.Io, diag: cli.result.Diagnostic) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    try cli.diagnostics.writeResult(&writer.interface, diag);
    try writer.interface.flush();
}
