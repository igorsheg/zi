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
const pty_options = @import("pty_options");
const vscreen = @import("vscreen.zig");

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

const smcup = "\x1b[?1049h";
const rmcup = "\x1b[?1049l";
const test_timeout_ns = std.time.ns_per_s;

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

    try writeAll(child.master, "ZAG\n");

    // A pty may split bytes across reads, so accumulate and search the whole
    // received slice rather than each chunk independently.
    var received: [1024]u8 = undefined;
    var received_len: usize = 0;
    try readUntilContains(child.master, &received, &received_len, "ZAG", test_timeout_ns);
}

test "real zi binary starts tui and exits alternate screen on quit" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        "HOME=/tmp",
        "ZI_CODING_AGENT_DIR=/tmp/zi-pty-agent",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, 80, 24);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readUntilContains(child.master, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(80, 24);
    screen.feed(received[0..received_len]);
    try readScreenUntilContains(child.master, &screen, "zi", test_timeout_ns);
    try readScreenUntilContains(child.master, &screen, "idle", test_timeout_ns);
    try readScreenUntilContains(child.master, &screen, ">", test_timeout_ns);

    try writeUntilContains(child.master, &received, &received_len, "q\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child.pid, &child_exited, test_timeout_ns);
}

fn readScreenUntilContains(
    fd: posix.fd_t,
    screen: *vscreen.Screen,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        if (screen.contains(needle)) return;
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        screen.feed(buf[0..n]);
    }
    return error.TimeoutWaitingForScreen;
}

fn writeAll(fd: posix.fd_t, bytes: []const u8) !void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = c.write(fd, bytes[written..].ptr, bytes.len - written);
        if (n <= 0) return error.WriteFailed;
        written += @intCast(n);
    }
}

fn readUntilContains(
    fd: posix.fd_t,
    received: []u8,
    received_len: *usize,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        if (received_len.* + n > received.len) return error.ReadBufferFull;
        @memcpy(received[received_len.*..][0..n], buf[0..n]);
        received_len.* += n;
        if (std.mem.indexOf(u8, received[0..received_len.*], needle) != null) return;
    }
    return error.TimeoutWaitingForOutput;
}

fn writeUntilContains(
    fd: posix.fd_t,
    received: []u8,
    received_len: *usize,
    bytes: []const u8,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var next_write_ns = start_ns;
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        const now_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        if (now_ns >= next_write_ns) {
            try writeAll(fd, bytes);
            next_write_ns = now_ns + (100 * std.time.ns_per_ms);
        }

        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 25);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(fd, &buf);
        if (n == 0) break;
        if (received_len.* + n > received.len) return error.ReadBufferFull;
        @memcpy(received[received_len.*..][0..n], buf[0..n]);
        received_len.* += n;
        if (std.mem.indexOf(u8, received[0..received_len.*], needle) != null) return;
    }
    return error.TimeoutWaitingForOutput;
}

fn waitForCleanExit(pid: posix.pid_t, child_exited: *bool, timeout_ns: i128) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        var status: c_int = undefined;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited < 0) return error.WaitFailed;
        if (waited == 0) {
            _ = c.usleep(10_000);
            continue;
        }
        child_exited.* = true;
        if (status != 0) return error.ChildExitedUncleanly;
        return;
    }
    return error.TimeoutWaitingForExit;
}

fn cleanupChild(child: Child, child_exited: *bool) void {
    if (!child_exited.*) {
        posix.kill(child.pid, posix.SIG.KILL) catch |err| {
            std.log.warn("pty: failed to kill child {d}: {t}", .{ child.pid, err });
        };
        var status: c_int = undefined;
        _ = c.waitpid(child.pid, &status, 0);
    }
    _ = c.close(child.master);
}
