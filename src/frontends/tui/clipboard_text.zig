//! Narrow text clipboard backend for the concrete TUI frontend.
//!
//! OSC 52 only proves bytes reached the terminal. Local macOS sessions need a
//! backend that owns the platform clipboard directly. Remote sessions keep using
//! terminal-mediated copy so the text reaches the user's local terminal emulator.
const std = @import("std");
const builtin = @import("builtin");

pub const CopyError = error{
    Unsupported,
    MissingStdinPipe,
    WriteFailed,
    ProcessSpawnFailed,
    ProcessWaitFailed,
    ProcessExitedNonZero,
};

pub const Backend = enum { native };

pub const Runner = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.Io, []const []const u8, []const u8) CopyError!void,

    fn call(self: Runner, io: std.Io, argv: []const []const u8, text: []const u8) CopyError!void {
        try self.call_fn(self.context, io, argv, text);
    }
};

const process_runner: Runner = .{ .call_fn = copyWithStdin };

pub fn copyNative(io: std.Io, environ: ?*const std.process.Environ.Map, text: []const u8) CopyError!Backend {
    return copyNativeWith(io, environ, text, process_runner);
}

pub fn copyNativeWith(
    io: std.Io,
    environ: ?*const std.process.Environ.Map,
    text: []const u8,
    runner: Runner,
) CopyError!Backend {
    if (text.len == 0) return error.Unsupported;
    if (isSshSession(environ)) return error.Unsupported;

    switch (builtin.os.tag) {
        .macos => try runner.call(io, &.{"/usr/bin/pbcopy"}, text),
        else => return error.Unsupported,
    }
    return .native;
}

fn copyWithStdin(_: ?*anyopaque, io: std.Io, argv: []const []const u8, text: []const u8) CopyError!void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .pipe,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = if (builtin.os.tag == .windows) null else 0,
    }) catch return error.ProcessSpawnFailed;
    var waited = false;
    defer if (!waited) child.kill(io);

    const stdin = child.stdin orelse return error.MissingStdinPipe;
    child.stdin = null;
    stdin.writeStreamingAll(io, text) catch return error.WriteFailed;
    stdin.close(io);

    const term = child.wait(io) catch return error.ProcessWaitFailed;
    waited = true;
    switch (term) {
        .exited => |code| if (code == 0) return else return error.ProcessExitedNonZero,
        else => return error.ProcessExitedNonZero,
    }
}

fn isSshSession(environ: ?*const std.process.Environ.Map) bool {
    return hasEnv(environ, "SSH_TTY") or hasEnv(environ, "SSH_CONNECTION");
}

fn hasEnv(environ: ?*const std.process.Environ.Map, name: []const u8) bool {
    const env = environ orelse return false;
    return env.get(name) != null;
}

test "native copy is disabled over ssh" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();
    try env.put("SSH_CONNECTION", "host");
    try std.testing.expectError(error.Unsupported, copyNativeWith(std.testing.io, &env, "hello", .{
        .call_fn = struct {
            fn call(_: ?*anyopaque, _: std.Io, _: []const []const u8, _: []const u8) CopyError!void {
                return error.ProcessSpawnFailed;
            }
        }.call,
    }));
}

test "macos native copy uses pbcopy runner" {
    if (builtin.os.tag != .macos) return;
    const State = struct {
        called: bool = false,

        fn call(context: ?*anyopaque, _: std.Io, argv: []const []const u8, text: []const u8) CopyError!void {
            const state: *@This() = @ptrCast(@alignCast(context.?));
            state.called = true;
            try std.testing.expectEqualStrings("/usr/bin/pbcopy", argv[0]);
            try std.testing.expectEqualStrings("hello", text);
        }
    };
    var state: State = .{};
    try std.testing.expectEqual(Backend.native, try copyNativeWith(std.testing.io, null, "hello", .{
        .context = &state,
        .call_fn = State.call,
    }));
    try std.testing.expect(state.called);
}
