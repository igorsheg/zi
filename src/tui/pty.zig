//! PTY harness primitives: open a pseudo-terminal pair and fork+exec a child
//! wired to the slave. Test-only infrastructure for driving the real `zi`
//! binary under a pseudo-terminal, the way pz and zag drive their TUIs.
//!
//! The mechanism is libc `openpty` + `fork`/`dup2`/`TIOCSCTTY`/`execve`. Zig
//! 0.16's `std.posix` does not expose `fork`/`dup2`/`execve`/`close`/`write`/
//! `waitpid`, so those go through libc; `read`/`poll`/`kill` use `std.posix`.
//! This module links libc, so it is built under the dedicated `pty-test` step
//! rather than the main unit-test suite.
const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;

const c = @cImport({
    if (builtin.os.tag == .macos) {
        @cInclude("util.h");
    } else {
        @cInclude("pty.h");
    }
    @cInclude("sys/ioctl.h");
    @cInclude("sys/wait.h");
    @cInclude("unistd.h");
});

pub const Pty = struct {
    master: posix.fd_t,
    slave: posix.fd_t,

    pub fn open(cols: u16, rows: u16) !Pty {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        var master: c_int = undefined;
        var slave: c_int = undefined;
        if (c.openpty(&master, &slave, null, null, &ws) != 0) return error.OpenptyFailed;
        // The child explicitly closes master after fork, so master cannot leak
        // into it; the slave stays inheritable so the child can dup2 it onto stdio.
        return .{ .master = master, .slave = slave };
    }
};

/// A child process running under a pty. The parent owns `master`; the slave is
/// already closed in the parent after the fork.
pub const Child = struct {
    pid: posix.pid_t,
    master: posix.fd_t,
};

/// Fork+exec `path` under a fresh pty, wiring the child's stdin/stdout/stderr to
/// the slave with the slave as its controlling terminal. `argv`/`envp` are
/// null-terminated C string arrays.
pub fn spawn(
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cols: u16,
    rows: u16,
) !Child {
    const pty = try Pty.open(cols, rows);
    errdefer {
        _ = c.close(pty.master);
        _ = c.close(pty.slave);
    }

    const pid = c.fork();
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        childExec(pty, path, argv, envp);
        unreachable;
    }

    // Parent: the slave belongs to the child now.
    _ = c.close(pty.slave);
    return .{ .pid = pid, .master = pty.master };
}

/// Child half of `spawn`. Runs only post-fork, pre-exec, so it stays on raw
/// syscalls. Returns only if exec fails, in which case it `_exit`s.
fn childExec(
    pty: Pty,
    path: [*:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
) void {
    _ = c.close(pty.master);
    // These are the calls that make the child a controlling-TTY process; if any
    // fails, execing anyway would put the child in the wrong test environment,
    // so fail fast. close() stays best-effort.
    if (c.setsid() < 0) c._exit(127);
    if (c.ioctl(pty.slave, c.TIOCSCTTY, @as(c_ulong, 0)) < 0) c._exit(127);
    if (c.dup2(pty.slave, 0) < 0) c._exit(127);
    if (c.dup2(pty.slave, 1) < 0) c._exit(127);
    if (c.dup2(pty.slave, 2) < 0) c._exit(127);
    if (pty.slave > 2) _ = c.close(pty.slave);
    _ = c.execve(path, @ptrCast(argv), @ptrCast(envp));
    c._exit(127);
}

test "pty round-trip: child stdout reaches the master fd" {
    const argv = [_:null]?[*:0]const u8{ "/bin/cat", "-u" };
    const envp: [0:null]?[*:0]const u8 = .{};
    const child = try spawn("/bin/cat", &argv, &envp, 80, 24);
    defer {
        posix.kill(child.pid, posix.SIG.KILL) catch {};
        var status: c_int = undefined;
        _ = c.waitpid(child.pid, &status, 0);
        _ = c.close(child.master);
    }

    const message = "ZAG\n";
    var written: usize = 0;
    while (written < message.len) {
        const w = c.write(child.master, message[written..].ptr, message.len - written);
        if (w <= 0) return error.WriteFailed;
        written += @intCast(w);
    }

    // A pty may split bytes across reads, so accumulate and search the whole
    // received slice rather than each chunk independently.
    const io = std.testing.io;
    const start_ns = std.Io.Clock.awake.now(io).nanoseconds;
    var received: [1024]u8 = undefined;
    var received_len: usize = 0;
    var buf: [256]u8 = undefined;
    while (std.Io.Clock.awake.now(io).nanoseconds - start_ns < std.time.ns_per_s) {
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        const take = @min(n, received.len - received_len);
        @memcpy(received[received_len..][0..take], buf[0..take]);
        received_len += take;
        if (std.mem.indexOf(u8, received[0..received_len], "ZAG") != null) return;
    }
    return error.TimeoutWaitingForEcho;
}
