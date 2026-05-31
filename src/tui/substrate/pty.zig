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
const device_status_report = "\x1b[5n";
const device_status_ok = "\x1b[0n";
const test_timeout_ns = 3 * std.time.ns_per_s;
const cleanup_timeout_ns = 500 * std.time.ns_per_ms;
const test_cols: u16 = 80;
const test_rows: u16 = 24;
const screen_snapshot_size_max = vscreen.Screen.cell_count_max * 4 + vscreen.Screen.height_max;
const long_response =
    "line-001\n" ++
    "line-002\n" ++
    "line-003\n" ++
    "line-004\n" ++
    "line-005\n" ++
    "line-006\n" ++
    "line-007\n" ++
    "line-008\n" ++
    "line-009\n" ++
    "line-010\n" ++
    "line-011\n" ++
    "line-012\n" ++
    "line-013\n" ++
    "line-014\n" ++
    "line-015\n" ++
    "line-016\n" ++
    "line-017\n" ++
    "line-018\n" ++
    "line-019\n" ++
    "line-020\n" ++
    "line-021\n" ++
    "line-022\n" ++
    "line-023\n" ++
    "line-024\n" ++
    "line-025\n" ++
    "line-026\n" ++
    "line-027\n" ++
    "line-028\n" ++
    "line-029\n" ++
    "line-030";

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

    pub fn resize(self: Child, cols: u16, rows: u16) !void {
        var ws: c.struct_winsize = .{
            .ws_col = cols,
            .ws_row = rows,
            .ws_xpixel = 0,
            .ws_ypixel = 0,
        };
        if (c.ioctl(self.master, c.TIOCSWINSZ, &ws) != 0) return error.ResizePtyFailed;
        try posix.kill(self.pid, posix.SIG.WINCH);
    }
};

const TestEnv = struct {
    allocator: std.mem.Allocator,
    root_path: []u8,
    home_env: [:0]u8,
    agent_dir_env: [:0]u8,

    fn init(allocator: std.mem.Allocator, name: []const u8) !TestEnv {
        const root_path = try std.fmt.allocPrint(
            allocator,
            "/tmp/zi-pty-{s}-{d}",
            .{ name, c.getpid() },
        );
        errdefer allocator.free(root_path);

        const cwd = std.Io.Dir.cwd();
        const io = std.testing.io;

        try cwd.deleteTree(io, root_path);
        try cwd.createDirPath(io, root_path);
        errdefer cwd.deleteTree(io, root_path) catch {};

        const home_env = try std.fmt.allocPrintSentinel(allocator, "HOME={s}", .{root_path}, 0);
        errdefer allocator.free(home_env);
        const agent_dir_env = try std.fmt.allocPrintSentinel(
            allocator,
            "ZI_CODING_AGENT_DIR={s}/agent",
            .{root_path},
            0,
        );
        errdefer allocator.free(agent_dir_env);

        return .{
            .allocator = allocator,
            .root_path = root_path,
            .home_env = home_env,
            .agent_dir_env = agent_dir_env,
        };
    }

    fn deinit(self: *TestEnv) void {
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.root_path) catch |err| {
            std.log.warn("pty: failed to remove test env {s}: {t}", .{ self.root_path, err });
        };
        self.allocator.free(self.agent_dir_env);
        self.allocator.free(self.home_env);
        self.allocator.free(self.root_path);
        self.* = undefined;
    }
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
    var test_env = try TestEnv.init(std.testing.allocator, "start");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);
    try readScreenUntilRowEquals(child, &child_exited, &screen, headerRow(), "zi", test_timeout_ns);
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "idle", test_timeout_ns);
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try expectScreenRowEquals(&screen, headerRow(), "zi");
    try expectScreenRowEquals(&screen, statusRow(), "idle");
    try expectScreenRowEquals(&screen, composerRow(), ">");
    try expectScreenCursorVisible(&screen);
    try expectScreenCursor(&screen, 2, composerRow());
    try writeAll(child.master, "hello");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> hello", test_timeout_ns);
    try expectScreenRowEquals(&screen, composerRow(), "> hello");
    try expectScreenCursor(&screen, 7, composerRow());
    try writeAll(child.master, "\x7f");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> hell", test_timeout_ns);
    try expectScreenRowEquals(&screen, composerRow(), "> hell");
    try expectScreenCursor(&screen, 6, composerRow());

    const resized_cols: u16 = 60;
    const resized_rows: u16 = 18;
    try child.resize(resized_cols, resized_rows);
    screen.resize(resized_cols, resized_rows);
    try readScreenUntilRowEquals(child, &child_exited, &screen, headerRow(), "zi", test_timeout_ns);
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRowFor(resized_rows), "idle", test_timeout_ns);
    try readScreenUntilRowEquals(
        child,
        &child_exited,
        &screen,
        composerRowFor(resized_rows),
        "> hell",
        test_timeout_ns,
    );
    try expectScreenCursor(&screen, 6, composerRowFor(resized_rows));

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary submits composer prompt and renders response" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "submit");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=pty answer",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "hello from pty\r");
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "running", test_timeout_ns);
    try readTranscriptUntilContains(child, &child_exited, &screen, "pty answer", test_timeout_ns);
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "idle", test_timeout_ns);

    try expectTranscriptContainsOrdered(&screen, &.{ "> hello from pty", "pty answer" });
    try expectScreenRowEquals(&screen, composerRow(), ">");

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary composer backspace removes one utf8 codepoint" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "utf8-backspace");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "aé");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> aé", test_timeout_ns);
    try expectScreenCursor(&screen, 4, composerRow());

    try writeAll(child.master, "\x7f");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> a", test_timeout_ns);
    try expectScreenCursor(&screen, 3, composerRow());

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary composer backspace removes one grapheme cluster" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "grapheme-backspace");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "ae\u{0301}");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> ae\u{0301}", test_timeout_ns);
    try expectScreenCursor(&screen, 4, composerRow());

    try writeAll(child.master, "\x7f");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> a", test_timeout_ns);
    try expectScreenCursor(&screen, 3, composerRow());

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary composer cursor follows wide character display width" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "wide-cursor");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "中");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> 中", test_timeout_ns);
    try expectScreenCursor(&screen, 4, composerRow());

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary submits initial argv prompt through tui" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "argv");
    defer test_env.deinit();

    const argv_prompt = "hello from argv";
    const argv = [_:null]?[*:0]const u8{ zi_path.ptr, argv_prompt };
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=argv answer",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readTranscriptUntilContains(child, &child_exited, &screen, "argv answer", test_timeout_ns);
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "idle", test_timeout_ns);

    try expectTranscriptContainsOrdered(&screen, &.{ "> hello from argv", "argv answer" });
    try expectScreenRowEquals(&screen, composerRow(), ">");
    try expectScreenCursor(&screen, 2, composerRow());

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary renders tool call and continued answer" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "tool");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=tool final answer",
        "ZI_PTY_FAUX_TOOL_READ=1",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "use read\r");
    try readTranscriptUntilContains(child, &child_exited, &screen, "[tool] read", test_timeout_ns);
    try readTranscriptUntilContains(child, &child_exited, &screen, "tool final answer", test_timeout_ns);

    try expectTranscriptContainsOrdered(&screen, &.{ "> use read", "[tool] read", "tool final answer" });
    try expectScreenRowEquals(&screen, composerRow(), ">");

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary shows cancel request while run is active" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "cancel");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=cancel me cancel me cancel me cancel me cancel me cancel me",
        "ZI_PTY_FAUX_DELAY_MS=25",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "please cancel\r");
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "running", test_timeout_ns);
    try writeAll(child.master, "\x1b");
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "cancel requested", test_timeout_ns);

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary exits alternate screen when ctrl-c quits active run" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "active-quit");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=still running still running still running still running",
        "ZI_PTY_FAUX_DELAY_MS=25",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "quit while active\r");
    try readScreenUntilRowEquals(child, &child_exited, &screen, statusRow(), "running", test_timeout_ns);

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary modal traps input and dismisses with escape" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "modal");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_TEST_MODAL=1",
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilContains(child, &child_exited, &screen, "PTY MODAL", test_timeout_ns);
    try expectScreenCursorHidden(&screen);
    try writeAll(child.master, "blocked");
    try settleScreen(child.master, &screen);
    try expectScreenRowExcludes(&screen, composerRow(), "blocked");

    try writeAll(child.master, "\x1b");
    try readScreenUntilExcludes(child, &child_exited, &screen, "PTY MODAL", test_timeout_ns);
    try writeAll(child.master, "ok");
    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), "> ok", test_timeout_ns);
    try expectScreenRowEquals(&screen, composerRow(), "> ok");
    try expectScreenCursorVisible(&screen);
    try expectScreenCursor(&screen, 4, composerRow());

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

test "real zi binary renders bounded transcript tail for long response" {
    const zi_path = try std.testing.allocator.dupeZ(u8, pty_options.zi_bin_path);
    defer std.testing.allocator.free(zi_path);
    var test_env = try TestEnv.init(std.testing.allocator, "long");
    defer test_env.deinit();

    const argv = [_:null]?[*:0]const u8{zi_path.ptr};
    const envp = [_:null]?[*:0]const u8{
        "TERM=xterm-256color",
        test_env.home_env.ptr,
        test_env.agent_dir_env.ptr,
        "ZI_PTY_FAUX_RESPONSE=" ++ long_response,
    };
    const child = try spawn(zi_path.ptr, &argv, &envp, test_cols, test_rows);
    var child_exited = false;
    defer cleanupChild(child, &child_exited);

    var received: [8192]u8 = undefined;
    var received_len: usize = 0;
    try readChildOutputUntilContains(child, &child_exited, &received, &received_len, smcup, test_timeout_ns);
    var screen = vscreen.Screen.init(test_cols, test_rows);
    screen.feed(received[0..received_len]);

    try readScreenUntilRowEquals(child, &child_exited, &screen, composerRow(), ">", test_timeout_ns);
    try writeAll(child.master, "long output\r");
    try readTranscriptUntilContains(child, &child_exited, &screen, "line-030", test_timeout_ns);

    try expectTranscriptContains(&screen, "line-030");
    try expectTranscriptExcludes(&screen, "line-001");
    try expectScreenRowEquals(&screen, composerRow(), ">");

    try writeUntilContains(child, &child_exited, &received, &received_len, "\x03", rmcup, test_timeout_ns);
    screen.feed(received[0..received_len]);
    try waitForCleanExit(child, &child_exited, test_timeout_ns);
}

fn headerRow() u16 {
    return 0;
}

fn transcriptRowStart() u16 {
    return 1;
}

fn transcriptRowCount() u16 {
    return test_rows - 3;
}

fn statusRow() u16 {
    return statusRowFor(test_rows);
}

fn composerRow() u16 {
    return composerRowFor(test_rows);
}

fn statusRowFor(rows: u16) u16 {
    std.debug.assert(rows >= 4);
    return rows - 2;
}

fn composerRowFor(rows: u16) u16 {
    std.debug.assert(rows >= 4);
    return rows - 1;
}

fn settleScreen(fd: posix.fd_t, screen: *vscreen.Screen) !void {
    var buf: [256]u8 = undefined;
    var polls_without_input: u8 = 0;
    while (polls_without_input < 3) {
        var fds = [_]posix.pollfd{.{ .fd = fd, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 25);
        if ((fds[0].revents & posix.POLL.IN) == 0) {
            polls_without_input += 1;
            continue;
        }
        const n = try posix.read(fd, &buf);
        if (n == 0) return;
        screen.feed(buf[0..n]);
        polls_without_input = 0;
    }
}

fn readScreenUntilContains(
    child: Child,
    child_exited: *bool,
    screen: *vscreen.Screen,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        if (screen.contains(needle)) return;
        try failIfChildExited(child, child_exited, screen);
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        screen.feed(buf[0..n]);
    }
    try printScreenExpectation(screen, "expected screen before timeout to contain", null, needle);
    return error.TimeoutWaitingForScreen;
}

fn readScreenUntilExcludes(
    child: Child,
    child_exited: *bool,
    screen: *vscreen.Screen,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        if (!screen.contains(needle)) return;
        try failIfChildExited(child, child_exited, screen);
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        screen.feed(buf[0..n]);
    }
    try printScreenExpectation(screen, "expected screen before timeout to exclude", null, needle);
    return error.TimeoutWaitingForScreenExclusion;
}

fn readTranscriptUntilContains(
    child: Child,
    child_exited: *bool,
    screen: *vscreen.Screen,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        if (screen.rowRangeContains(transcriptRowStart(), transcriptRowCount(), needle)) return;
        try failIfChildExited(child, child_exited, screen);
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        screen.feed(buf[0..n]);
    }
    try printTranscriptExpectation(screen, "expected transcript before timeout to contain", needle);
    return error.TimeoutWaitingForTranscript;
}

fn readScreenUntilRowEquals(
    child: Child,
    child_exited: *bool,
    screen: *vscreen.Screen,
    row_index: u16,
    expected: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        if (screen.rowEqualsTrimmedRight(row_index, expected)) return;
        try failIfChildExited(child, child_exited, screen);
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        screen.feed(buf[0..n]);
    }
    try printScreenExpectation(screen, "expected row before timeout to equal", row_index, expected);
    return error.TimeoutWaitingForScreenRowMatch;
}

fn expectTranscriptContains(screen: *const vscreen.Screen, needle: []const u8) !void {
    if (screen.rowRangeContains(transcriptRowStart(), transcriptRowCount(), needle)) return;
    try printTranscriptExpectation(screen, "expected transcript to contain", needle);
    return error.ExpectedTranscriptTextMissing;
}

fn expectTranscriptContainsOrdered(screen: *const vscreen.Screen, needles: []const []const u8) !void {
    if (screen.rowRangeContainsOrdered(transcriptRowStart(), transcriptRowCount(), needles)) return;
    try printTranscriptOrderedExpectation(screen, "expected transcript to contain ordered rows", needles);
    return error.ExpectedTranscriptTextOrderMissing;
}

fn expectTranscriptExcludes(screen: *const vscreen.Screen, needle: []const u8) !void {
    if (!screen.rowRangeContains(transcriptRowStart(), transcriptRowCount(), needle)) return;
    try printTranscriptExpectation(screen, "expected transcript to exclude", needle);
    return error.UnexpectedTranscriptText;
}

fn expectScreenRowEquals(screen: *const vscreen.Screen, row_index: u16, expected: []const u8) !void {
    if (screen.rowEqualsTrimmedRight(row_index, expected)) return;
    try printScreenExpectation(screen, "expected row to equal", row_index, expected);
    return error.ExpectedScreenRowMismatch;
}

fn expectScreenRowExcludes(screen: *const vscreen.Screen, row_index: u16, needle: []const u8) !void {
    if (!screen.rowContains(row_index, needle)) return;
    try printScreenExpectation(screen, "expected row to exclude", row_index, needle);
    return error.UnexpectedScreenRowText;
}

fn expectScreenCursor(screen: *const vscreen.Screen, col: u16, row_index: u16) !void {
    if (screen.cursorEquals(col, row_index)) return;
    try printCursorExpectation(screen, col, row_index);
    return error.ExpectedScreenCursorMismatch;
}

fn expectScreenCursorVisible(screen: *const vscreen.Screen) !void {
    if (screen.cursorIsVisible()) return;
    try printCursorVisibilityExpectation(screen, true);
    return error.ExpectedScreenCursorVisible;
}

fn expectScreenCursorHidden(screen: *const vscreen.Screen) !void {
    if (!screen.cursorIsVisible()) return;
    try printCursorVisibilityExpectation(screen, false);
    return error.ExpectedScreenCursorHidden;
}

fn printScreenExpectation(
    screen: *const vscreen.Screen,
    prefix: []const u8,
    row_index: ?u16,
    needle: []const u8,
) !void {
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    if (row_index) |index| {
        std.debug.print(
            \\{s} {d}: "{s}"
            \\screen:
            \\{s}
            \\
        , .{ prefix, index, needle, try screen.copyText(&snapshot) });
    } else {
        std.debug.print(
            \\{s}: "{s}"
            \\screen:
            \\{s}
            \\
        , .{ prefix, needle, try screen.copyText(&snapshot) });
    }
    printScreenRawTail(screen);
}

fn printTranscriptExpectation(screen: *const vscreen.Screen, prefix: []const u8, needle: []const u8) !void {
    var transcript: [screen_snapshot_size_max]u8 = undefined;
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    std.debug.print(
        \\{s}: "{s}"
        \\transcript rows {d}..{d}:
        \\{s}
        \\screen:
        \\{s}
        \\
    , .{
        prefix,
        needle,
        transcriptRowStart(),
        transcriptRowStart() + transcriptRowCount() - 1,
        try screen.copyRowRangeText(transcriptRowStart(), transcriptRowCount(), &transcript),
        try screen.copyText(&snapshot),
    });
    printScreenRawTail(screen);
}

fn printTranscriptOrderedExpectation(
    screen: *const vscreen.Screen,
    prefix: []const u8,
    needles: []const []const u8,
) !void {
    var transcript: [screen_snapshot_size_max]u8 = undefined;
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    std.debug.print("{s}:\n", .{prefix});
    for (needles, 0..) |needle, index| {
        std.debug.print("  {d}: \"{s}\"\n", .{ index, needle });
    }
    std.debug.print(
        \\transcript rows {d}..{d}:
        \\{s}
        \\screen:
        \\{s}
        \\
    , .{
        transcriptRowStart(),
        transcriptRowStart() + transcriptRowCount() - 1,
        try screen.copyRowRangeText(transcriptRowStart(), transcriptRowCount(), &transcript),
        try screen.copyText(&snapshot),
    });
    printScreenRawTail(screen);
}

fn printCursorExpectation(screen: *const vscreen.Screen, col: u16, row_index: u16) !void {
    const actual = screen.cursor();
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    std.debug.print(
        \\expected cursor at col={d} row={d}, actual col={d} row={d}
        \\screen:
        \\{s}
        \\
    , .{
        col,
        row_index,
        actual.col,
        actual.row,
        try screen.copyText(&snapshot),
    });
    printScreenRawTail(screen);
}

fn printCursorVisibilityExpectation(screen: *const vscreen.Screen, expected_visible: bool) !void {
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    std.debug.print(
        \\expected cursor visible={any}, actual visible={any}
        \\screen:
        \\{s}
        \\
    , .{
        expected_visible,
        screen.cursorIsVisible(),
        try screen.copyText(&snapshot),
    });
    printScreenRawTail(screen);
}

fn printScreenRawTail(screen: *const vscreen.Screen) void {
    std.debug.print("raw tail:\n", .{});
    printEscapedBytes(screen.rawTail());
    std.debug.print("\n", .{});
}

fn printEscapedBytes(bytes: []const u8) void {
    for (bytes) |byte| switch (byte) {
        '\n' => std.debug.print("\\n", .{}),
        '\r' => std.debug.print("\\r", .{}),
        '\t' => std.debug.print("\\t", .{}),
        0x20...0x7e => std.debug.print("{c}", .{byte}),
        else => std.debug.print("\\x{x:0>2}", .{byte}),
    };
}

fn printOutputExpectation(prefix: []const u8, received: []const u8, needle: []const u8) void {
    std.debug.print(
        \\{s}: "{s}"
        \\output:
        \\{s}
        \\
    , .{ prefix, needle, received });
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
    printOutputExpectation(
        "expected output before timeout to contain",
        received[0..received_len.*],
        needle,
    );
    return error.TimeoutWaitingForOutput;
}

fn readChildOutputUntilContains(
    child: Child,
    child_exited: *bool,
    received: []u8,
    received_len: *usize,
    needle: []const u8,
    timeout_ns: i128,
) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var buf: [256]u8 = undefined;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        try failIfChildExitedWithoutScreen(child, child_exited);
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 100);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        if (received_len.* + n > received.len) return error.ReadBufferFull;
        @memcpy(received[received_len.*..][0..n], buf[0..n]);
        received_len.* += n;
        if (std.mem.indexOf(u8, received[0..received_len.*], needle) != null) return;
    }
    printOutputExpectation(
        "expected child output before timeout to contain",
        received[0..received_len.*],
        needle,
    );
    return error.TimeoutWaitingForOutput;
}

fn writeUntilContains(
    child: Child,
    child_exited: *bool,
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
        try failIfChildExitedWithoutScreen(child, child_exited);
        const now_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
        if (now_ns >= next_write_ns) {
            try writeAll(child.master, bytes);
            next_write_ns = now_ns + (100 * std.time.ns_per_ms);
        }

        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 25);
        if ((fds[0].revents & posix.POLL.IN) == 0) continue;
        const n = try posix.read(child.master, &buf);
        if (n == 0) break;
        if (received_len.* + n > received.len) return error.ReadBufferFull;
        @memcpy(received[received_len.*..][0..n], buf[0..n]);
        received_len.* += n;
        if (std.mem.indexOf(u8, received[0..received_len.*], needle) != null) return;
    }
    printOutputExpectation(
        "expected output before timeout to contain",
        received[0..received_len.*],
        needle,
    );
    return error.TimeoutWaitingForOutput;
}

fn failIfChildExited(child: Child, child_exited: *bool, screen: *const vscreen.Screen) !void {
    const status = try pollChildExit(child, child_exited) orelse return;
    printChildExitStatus(status);
    var snapshot: [screen_snapshot_size_max]u8 = undefined;
    std.debug.print(
        \\screen at child exit:
        \\{s}
        \\
    , .{try screen.copyText(&snapshot)});
    return error.ChildExitedBeforeExpectation;
}

fn failIfChildExitedWithoutScreen(child: Child, child_exited: *bool) !void {
    const status = try pollChildExit(child, child_exited) orelse return;
    printChildExitStatus(status);
    return error.ChildExitedBeforeExpectation;
}

fn pollChildExit(child: Child, child_exited: *bool) !?c_int {
    if (child_exited.*) return null;
    var status: c_int = undefined;
    const waited = c.waitpid(child.pid, &status, c.WNOHANG);
    if (waited < 0) return error.WaitFailed;
    if (waited == 0) return null;
    child_exited.* = true;
    return status;
}

fn printChildExitStatus(status: c_int) void {
    std.debug.print("child exited before expected PTY state: raw_status={d}\n", .{status});
}

fn waitForCleanExit(child: Child, child_exited: *bool, timeout_ns: i128) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    var output: [512]u8 = undefined;
    var output_len: usize = 0;
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < timeout_ns) {
        var status: c_int = undefined;
        const waited = c.waitpid(child.pid, &status, c.WNOHANG);
        if (waited < 0) return error.WaitFailed;
        if (waited != 0) {
            child_exited.* = true;
            if (status != 0) return error.ChildExitedUncleanly;
            return;
        }

        try drainShutdownOutput(child, &output, &output_len);
        _ = c.usleep(10_000);
    }
    std.debug.print("expected child {d} to exit before timeout\n", .{child.pid});
    return error.TimeoutWaitingForExit;
}

/// Keep acting like a terminal while the child shuts down. libvaxis wakes its
/// input thread during Loop.stop() by sending DSR (`ESC[5n`) and waiting for a
/// response to arrive on the TTY. If the harness stops reading after `rmcup`,
/// shutdown becomes timing-dependent and can wedge on the input-thread join.
fn drainShutdownOutput(child: Child, output: []u8, output_len: *usize) !void {
    var buf: [256]u8 = undefined;
    while (true) {
        var fds = [_]posix.pollfd{.{ .fd = child.master, .events = posix.POLL.IN, .revents = 0 }};
        _ = try posix.poll(&fds, 0);
        if ((fds[0].revents & posix.POLL.IN) == 0) return;

        const n = posix.read(child.master, &buf) catch |err| switch (err) {
            error.InputOutput => return,
            else => return err,
        };
        if (n == 0) return;

        if (output_len.* + n > output.len) {
            const drop_count = output_len.* + n - output.len;
            const keep_count = output_len.* - @min(output_len.*, drop_count);
            @memmove(output[0..keep_count], output[output_len.* - keep_count .. output_len.*]);
            output_len.* = keep_count;
        }
        @memcpy(output[output_len.*..][0..n], buf[0..n]);
        output_len.* += n;

        if (std.mem.indexOf(u8, output[0..output_len.*], device_status_report) != null) {
            try writeAll(child.master, device_status_ok);
            output_len.* = 0;
        }
    }
}

fn cleanupChild(child: Child, child_exited: *bool) void {
    if (!child_exited.*) {
        posix.kill(child.pid, posix.SIG.KILL) catch |err| {
            std.log.warn("pty: failed to kill child {d}: {t}", .{ child.pid, err });
        };
        waitForKilledChild(child.pid, child_exited) catch |err| {
            std.log.warn("pty: failed to reap child {d}: {t}", .{ child.pid, err });
        };
    }
    _ = c.close(child.master);
}

fn waitForKilledChild(pid: posix.pid_t, child_exited: *bool) !void {
    const io = std.testing.io;
    const start_ns: i128 = @intCast(std.Io.Clock.awake.now(io).nanoseconds);
    while (@as(i128, @intCast(std.Io.Clock.awake.now(io).nanoseconds)) - start_ns < cleanup_timeout_ns) {
        var status: c_int = undefined;
        const waited = c.waitpid(pid, &status, c.WNOHANG);
        if (waited < 0) return error.WaitFailed;
        if (waited != 0) {
            child_exited.* = true;
            return;
        }
        _ = c.usleep(10_000);
    }
    return error.TimeoutWaitingForCleanup;
}
