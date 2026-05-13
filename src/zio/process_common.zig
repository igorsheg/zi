const builtin = @import("builtin");
const std = @import("std");

pub fn supportsProcessGroups() bool {
    return builtin.os.tag != .windows and builtin.os.tag != .wasi;
}

pub fn killChild(child_id: std.process.Child.Id, process_group: bool, sig: std.posix.SIG) void {
    if (process_group and supportsProcessGroups()) {
        const group_pid: std.posix.pid_t = -@as(std.posix.pid_t, @intCast(child_id));
        std.posix.kill(group_pid, sig) catch {};
    } else {
        std.posix.kill(child_id, sig) catch {};
    }
}

pub const shell_argv: []const []const u8 = if (builtin.os.tag == .windows) &.{ "cmd.exe", "/c" } else &.{ "/bin/sh", "-c" };
