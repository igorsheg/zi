const std = @import("std");
const cancel = @import("cancel.zig");

pub const EnvPair = struct {
    key: []const u8,
    value: []const u8,
};

pub const StreamKind = enum { stdout, stderr };

pub const Event = union(enum) {
    ready,
    stdout: []const u8,
    stderr: []const u8,
    exit: ?std.process.Child.Term,
    spawn_failed,
};

pub const EventSink = struct {
    ptr: *anyopaque,
    submit: *const fn (ptr: *anyopaque, event: Event) bool,
};

pub const StartRequest = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    env: []const EnvPair = &.{},
    clear_env: bool = false,
    process_group: bool = true,
    stdin: bool = true,
    close_stdin_before_wait: bool = false,
    stdout: bool = true,
    stderr: bool = true,
    timeout_ms: ?u64 = null,
    signal: cancel.Token = cancel.Token.none,
};
