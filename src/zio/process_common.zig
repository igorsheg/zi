const builtin = @import("builtin");
const std = @import("std");

const log = std.log.scoped(.zio_process);

pub fn supportsProcessGroups() bool {
    return builtin.os.tag != .windows and builtin.os.tag != .wasi;
}

pub fn killChild(child_id: std.process.Child.Id, process_group: bool, sig: std.posix.SIG) void {
    if (process_group and supportsProcessGroups()) {
        const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(child_id));
        killPid(group_pid, sig);
    } else {
        killPid(child_id, sig);
    }
}

fn killPid(pid: std.posix.pid_t, sig: std.posix.SIG) void {
    std.posix.kill(pid, sig) catch |err| switch (err) {
        error.ProcessNotFound => {},
        else => log.warn("failed to signal pid {d}: {s}", .{ pid, @errorName(err) }),
    };
}

pub const shell_argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c" } else &.{ "/bin/sh", "-c" };
