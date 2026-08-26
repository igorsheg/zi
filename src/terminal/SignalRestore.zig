const std = @import("std");
const builtin = @import("builtin");

/// Process-wide fatal-signal terminal restoration.
///
/// The handler uses only async-signal-safe libc calls. It does not allocate, lock, or use
/// `std.Io`. Call `install` before starting threads that can receive process signals. Any later
/// `update` must run on the signal-owning thread while other threads keep these signals blocked.
const SignalRestore = @This();

pub const restore_sequence = "\x1b[?2004l\x1b[?25h\x1b[?2026l";
pub const Hook = *const fn () callconv(.c) void;

pub const State = struct {
    terminal_fd: std.posix.fd_t = std.posix.STDIN_FILENO,
    output_fd: std.posix.fd_t = std.posix.STDOUT_FILENO,
    saved_termios: ?std.posix.termios = null,
    terminal_active: bool = false,
    interactive_terminal: bool = false,
};

pub const InstallError = error{InstallSignalHandlerFailed};
pub const RestoreError = error{
    TerminalRestoreFailed,
    OutputRestoreFailed,
};

const SigactionCall = *const fn (
    ?*anyopaque,
    std.posix.SIG,
    *const std.posix.Sigaction,
    ?*std.posix.Sigaction,
) c_int;

const fatal_signals = [_]std.posix.SIG{
    .INT,
    .TERM,
    .HUP,
    .QUIT,
};

// These fields have process lifetime because POSIX signal handlers have process lifetime.
var saved_termios: std.posix.termios = undefined;
var terminal_fd: std.posix.fd_t = std.posix.STDIN_FILENO;
var output_fd: std.posix.fd_t = std.posix.STDOUT_FILENO;
var saved_termios_valid: std.c.sig_atomic_t = 0;
var terminal_active: std.c.sig_atomic_t = 0;
var interactive_terminal: std.c.sig_atomic_t = 0;
var fatal_signal_hook: ?Hook = null;

const PolicyState = struct {
    hook_present: bool,
    saved_termios_valid: bool,
    terminal_active: bool,
    interactive_terminal: bool,
};

const RestorePolicy = struct {
    call_hook: bool,
    restore_termios: bool,
    write_restore_sequence: bool,
    reset_and_reraise: bool,
};

fn policy(state: PolicyState) RestorePolicy {
    return .{
        .call_hook = state.hook_present,
        .restore_termios = state.saved_termios_valid and state.terminal_active,
        .write_restore_sequence = state.interactive_terminal,
        .reset_and_reraise = true,
    };
}

/// Publishes restoration state and installs handlers for INT, TERM, HUP, and QUIT.
/// Repeated calls replace the published state and reinstall the same handlers.
pub fn install(state: State) InstallError!void {
    const old_mask = blockFatalSignals();
    defer restoreSignalMask(old_mask);

    publish(state);

    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = fatalSignalHandler },
        .mask = fatalSignalMask(),
        .flags = 0,
    };
    try installActions(&action, null, callSigaction);
}

/// Replaces the state used by an already-installed handler.
///
/// The exact termios value and descriptors are copied before `terminal_active` is published.
pub fn update(state: State) void {
    const old_mask = blockFatalSignals();
    defer restoreSignalMask(old_mask);
    publish(state);
}

/// Sets an optional async-signal-safe hook. The hook runs before terminal restoration.
/// The hook itself must use only async-signal-safe operations.
pub fn setHook(hook: ?Hook) void {
    const old_mask = blockFatalSignals();
    defer restoreSignalMask(old_mask);
    volatileStore(?Hook, &fatal_signal_hook, hook);
}

/// Restores the published terminal state during normal control flow.
/// Successful termios restoration clears the active flag, so repeated calls are harmless.
pub fn restore() RestoreError!void {
    const old_mask = blockFatalSignals();
    defer restoreSignalMask(old_mask);

    var terminal_failed = false;
    if (volatileLoad(std.c.sig_atomic_t, &saved_termios_valid) != 0 and
        volatileLoad(std.c.sig_atomic_t, &terminal_active) != 0)
    {
        if (std.c.tcsetattr(terminal_fd, .NOW, &saved_termios) == 0) {
            volatileStore(std.c.sig_atomic_t, &terminal_active, 0);
        } else {
            terminal_failed = true;
        }
    }

    var output_failed = false;
    if (volatileLoad(std.c.sig_atomic_t, &interactive_terminal) != 0) {
        output_failed = !writeAll(output_fd, restore_sequence);
    }

    if (terminal_failed) return error.TerminalRestoreFailed;
    if (output_failed) return error.OutputRestoreFailed;
}

fn callSigaction(
    _: ?*anyopaque,
    signal_number: std.posix.SIG,
    action: *const std.posix.Sigaction,
    old_action: ?*std.posix.Sigaction,
) c_int {
    return std.c.sigaction(signal_number, action, old_action);
}

fn installActions(
    action: *const std.posix.Sigaction,
    context: ?*anyopaque,
    call: SigactionCall,
) InstallError!void {
    var old_actions: [fatal_signals.len]std.posix.Sigaction = undefined;
    var installed: usize = 0;
    while (installed < fatal_signals.len) : (installed += 1) {
        if (call(context, fatal_signals[installed], action, &old_actions[installed]) == 0) continue;

        // Restore in reverse installation order. Best effort is the only useful response if a
        // rollback sigaction itself fails; the original installation error still wins.
        var rollback = installed;
        while (rollback > 0) {
            rollback -= 1;
            _ = call(context, fatal_signals[rollback], &old_actions[rollback], null);
        }
        return error.InstallSignalHandlerFailed;
    }
}

fn publish(state: State) void {
    // Withdraw active state first. A handler can never observe active=true with a partial copy.
    volatileStore(std.c.sig_atomic_t, &terminal_active, 0);
    volatileStore(std.c.sig_atomic_t, &interactive_terminal, 0);
    volatileStore(std.c.sig_atomic_t, &saved_termios_valid, 0);

    terminal_fd = state.terminal_fd;
    output_fd = state.output_fd;
    if (state.saved_termios) |attributes| {
        saved_termios = attributes;
        volatileStore(std.c.sig_atomic_t, &saved_termios_valid, 1);
    }
    volatileStore(
        std.c.sig_atomic_t,
        &interactive_terminal,
        @intFromBool(state.interactive_terminal),
    );
    if (state.saved_termios != null) {
        volatileStore(std.c.sig_atomic_t, &terminal_active, @intFromBool(state.terminal_active));
    }
}

fn fatalSignalMask() std.posix.sigset_t {
    var mask = std.posix.sigemptyset();
    for (fatal_signals) |signal_number| std.posix.sigaddset(&mask, signal_number);
    return mask;
}

fn blockFatalSignals() std.posix.sigset_t {
    const mask = fatalSignalMask();
    var old_mask: std.posix.sigset_t = undefined;
    const rc = std.c.pthread_sigmask(@intCast(std.posix.SIG.BLOCK), &mask, &old_mask);
    std.debug.assert(rc == 0);
    return old_mask;
}

fn restoreSignalMask(mask: std.posix.sigset_t) void {
    var ignored_mask: std.posix.sigset_t = undefined;
    const rc = std.c.pthread_sigmask(@intCast(std.posix.SIG.SETMASK), &mask, &ignored_mask);
    std.debug.assert(rc == 0);
}

const WriteCall = fn (?*anyopaque, std.posix.fd_t, [*]const u8, usize) isize;
const ErrnoCall = fn (?*anyopaque) c_int;

fn writeAll(fd: std.posix.fd_t, bytes: []const u8) bool {
    return writeAllUsing(callWrite, currentErrno, null, fd, bytes);
}

fn callWrite(
    _: ?*anyopaque,
    fd: std.posix.fd_t,
    bytes: [*]const u8,
    length: usize,
) isize {
    return std.c.write(fd, bytes, length);
}

fn currentErrno(_: ?*anyopaque) c_int {
    return std.c._errno().*;
}

fn writeAllUsing(
    comptime write_call: WriteCall,
    comptime errno_call: ErrnoCall,
    context: ?*anyopaque,
    fd: std.posix.fd_t,
    bytes: []const u8,
) bool {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const written = write_call(context, fd, bytes[offset..].ptr, bytes.len - offset);
        if (written > 0) {
            offset += @intCast(written);
            continue;
        }
        if (written < 0 and errno_call(context) == @intFromEnum(std.c.E.INTR)) continue;
        return false;
    }
    return true;
}

fn fatalSignalHandler(signal_number: std.posix.SIG) callconv(.c) void {
    const hook = volatileLoad(?Hook, &fatal_signal_hook);
    const restore_policy = policy(.{
        .hook_present = hook != null,
        .saved_termios_valid = volatileLoad(std.c.sig_atomic_t, &saved_termios_valid) != 0,
        .terminal_active = volatileLoad(std.c.sig_atomic_t, &terminal_active) != 0,
        .interactive_terminal = volatileLoad(std.c.sig_atomic_t, &interactive_terminal) != 0,
    });

    if (restore_policy.call_hook) hook.?();
    if (restore_policy.restore_termios) {
        _ = std.c.tcsetattr(terminal_fd, .NOW, &saved_termios);
        _ = tcflush(terminal_fd, tciflush_selector);
        volatileStore(std.c.sig_atomic_t, &terminal_active, 0);
    }
    if (restore_policy.write_restore_sequence) {
        _ = writeAll(output_fd, restore_sequence);
    }

    // Restore the default disposition and explicitly unblock this signal before
    // resending it. This does not depend on pending-signal delivery after a
    // handler whose action mask blocks every fatal signal returns.
    var empty_mask: std.posix.sigset_t = undefined;
    _ = std.c.sigemptyset(&empty_mask);
    const default_action: std.posix.Sigaction = .{
        .handler = .{ .handler = null },
        .mask = empty_mask,
        .flags = 0,
    };
    if (std.c.sigaction(signal_number, &default_action, null) != 0) {
        exitAfterSignalFailure(signal_number);
    }

    // The active handler and its full action mask both block this signal. Explicitly unblock it
    // after installing the default disposition, then resend it directly to this process.
    var current_signal: std.posix.sigset_t = undefined;
    var ignored_mask: std.posix.sigset_t = undefined;
    if (std.c.sigemptyset(&current_signal) != 0 or
        std.c.sigaddset(&current_signal, signal_number) != 0 or
        std.c.pthread_sigmask(
            @intCast(std.posix.SIG.UNBLOCK),
            &current_signal,
            &ignored_mask,
        ) != 0)
    {
        exitAfterSignalFailure(signal_number);
    }
    if (std.c.kill(std.c.getpid(), signal_number) != 0) {
        exitAfterSignalFailure(signal_number);
    }
}

fn exitAfterSignalFailure(signal_number: std.posix.SIG) noreturn {
    std.c._exit(128 + @as(c_int, @intCast(@intFromEnum(signal_number))));
}

const tciflush_selector: c_int = switch (builtin.os.tag) {
    .macos, .ios, .tvos, .watchos, .visionos, .freebsd, .netbsd, .openbsd, .dragonfly => 1,
    else => 0,
};

extern "c" fn tcflush(fd: c_int, queue_selector: c_int) c_int;

fn volatileLoad(comptime T: type, pointer: *T) T {
    const volatile_pointer: *volatile T = pointer;
    return volatile_pointer.*;
}

fn volatileStore(comptime T: type, pointer: *T, value: T) void {
    const volatile_pointer: *volatile T = pointer;
    volatile_pointer.* = value;
}

test "fatal policy restores active terminal and all interactive controls" {
    const result = policy(.{
        .hook_present = true,
        .saved_termios_valid = true,
        .terminal_active = true,
        .interactive_terminal = true,
    });

    try std.testing.expect(result.call_hook);
    try std.testing.expect(result.restore_termios);
    try std.testing.expect(result.write_restore_sequence);
    try std.testing.expect(result.reset_and_reraise);
}

test "fatal policy does not use unpublished or inactive termios" {
    const unpublished = policy(.{
        .hook_present = false,
        .saved_termios_valid = false,
        .terminal_active = true,
        .interactive_terminal = false,
    });
    const inactive = policy(.{
        .hook_present = false,
        .saved_termios_valid = true,
        .terminal_active = false,
        .interactive_terminal = false,
    });

    try std.testing.expect(!unpublished.restore_termios);
    try std.testing.expect(!inactive.restore_termios);
    try std.testing.expect(unpublished.reset_and_reraise);
    try std.testing.expect(inactive.reset_and_reraise);
}

test "installed handler mask blocks every fatal restoration signal" {
    const mask = fatalSignalMask();
    for (fatal_signals) |signal_number| {
        try std.testing.expect(std.posix.sigismember(&mask, signal_number));
    }
}

test "restore sequence matches hax fatal cleanup order" {
    try std.testing.expectEqualStrings(
        "\x1b[?2004l\x1b[?25h\x1b[?2026l",
        restore_sequence,
    );
}

test "public API compiles without delivering a process signal" {
    const compile_only = struct {
        fn hook() callconv(.c) void {}
    };

    if (false) {
        try SignalRestore.install(.{});
        SignalRestore.update(.{});
        SignalRestore.setHook(compile_only.hook);
        try SignalRestore.restore();
    }
}

const FakeSigactions = struct {
    call_count: usize = 0,
    install_count: usize = 0,
    fail_install_at: usize,
    signals: [8]std.posix.SIG = undefined,
    installing: [8]bool = undefined,
    action_flags: [8]c_uint = undefined,

    fn call(
        context: ?*anyopaque,
        signal_number: std.posix.SIG,
        action: *const std.posix.Sigaction,
        old_action: ?*std.posix.Sigaction,
    ) c_int {
        const fake: *FakeSigactions = @ptrCast(@alignCast(context.?));
        const call_index = fake.call_count;
        fake.call_count += 1;
        fake.signals[call_index] = signal_number;
        fake.installing[call_index] = old_action != null;
        fake.action_flags[call_index] = action.flags;

        if (old_action) |saved| {
            const install_index = fake.install_count;
            fake.install_count += 1;
            if (install_index == fake.fail_install_at) return -1;
            saved.* = .{
                .handler = .{ .handler = null },
                .mask = std.posix.sigemptyset(),
                .flags = @intCast(100 + install_index),
            };
        }
        return 0;
    }
};

test "partial handler installation restores exact old actions in reverse" {
    var fake: FakeSigactions = .{ .fail_install_at = 2 };
    const action: std.posix.Sigaction = .{
        .handler = .{ .handler = fatalSignalHandler },
        .mask = fatalSignalMask(),
        .flags = 0,
    };

    try std.testing.expectError(
        error.InstallSignalHandlerFailed,
        installActions(&action, &fake, FakeSigactions.call),
    );
    try std.testing.expectEqual(@as(usize, 5), fake.call_count);
    try std.testing.expectEqualSlices(
        std.posix.SIG,
        &.{ .INT, .TERM, .HUP, .TERM, .INT },
        fake.signals[0..fake.call_count],
    );
    try std.testing.expectEqualSlices(
        bool,
        &.{ true, true, true, false, false },
        fake.installing[0..fake.call_count],
    );
    try std.testing.expectEqual(@as(c_uint, 101), fake.action_flags[3]);
    try std.testing.expectEqual(@as(c_uint, 100), fake.action_flags[4]);
}

const FakeWrites = struct {
    results: []const isize,
    errors: []const c_int,
    call_count: usize = 0,
    last_call: usize = 0,
    requested: [8]usize = undefined,

    fn write(
        context: ?*anyopaque,
        _: std.posix.fd_t,
        _: [*]const u8,
        length: usize,
    ) isize {
        const fake: *FakeWrites = @ptrCast(@alignCast(context.?));
        const index = fake.call_count;
        fake.call_count += 1;
        fake.last_call = index;
        fake.requested[index] = length;
        return fake.results[index];
    }

    fn errno(context: ?*anyopaque) c_int {
        const fake: *FakeWrites = @ptrCast(@alignCast(context.?));
        return fake.errors[fake.last_call];
    }
};

test "restore write loops after partial progress and EINTR" {
    const results = [_]isize{ 3, -1, restore_sequence.len - 3 };
    const errors = [_]c_int{ 0, @intFromEnum(std.c.E.INTR), 0 };
    var fake: FakeWrites = .{
        .results = &results,
        .errors = &errors,
    };

    try std.testing.expect(writeAllUsing(
        FakeWrites.write,
        FakeWrites.errno,
        &fake,
        7,
        restore_sequence,
    ));
    try std.testing.expectEqual(@as(usize, 3), fake.call_count);
    try std.testing.expectEqualSlices(
        usize,
        &.{ restore_sequence.len, restore_sequence.len - 3, restore_sequence.len - 3 },
        fake.requested[0..fake.call_count],
    );
}

test "restore write rejects no-progress and non-EINTR failures" {
    const zero_results = [_]isize{0};
    const zero_errors = [_]c_int{0};
    var zero: FakeWrites = .{ .results = &zero_results, .errors = &zero_errors };
    try std.testing.expect(!writeAllUsing(FakeWrites.write, FakeWrites.errno, &zero, 7, "x"));

    const failed_results = [_]isize{-1};
    const failed_errors = [_]c_int{@intFromEnum(std.c.E.IO)};
    var failed: FakeWrites = .{ .results = &failed_results, .errors = &failed_errors };
    try std.testing.expect(!writeAllUsing(FakeWrites.write, FakeWrites.errno, &failed, 7, "x"));
}
