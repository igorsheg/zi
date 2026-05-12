const std = @import("std");
const process = @import("../zio/root.zig").process;

pub const Options = struct {
    argv: []const []const u8,
    cwd: std.process.Child.Cwd = .inherit,
    timeout_ms: u64 = 2000,
    max_stdout_bytes: usize = 64 * 1024,
    trim: bool = true,
};

/// Run a small external query and return stdout only when it exits 0.
///
/// This is for product probes such as git branch/status helpers, config value
/// commands, and clipboard adapters. Interactive/user command execution belongs
/// in `zio.process.run` callers, not here.
pub fn stdout(allocator: std.mem.Allocator, io: std.Io, options: Options) ?[]u8 {
    var result = process.run(allocator, io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .timeout_ms = options.timeout_ms,
        .stdout_limit = .limited(options.max_stdout_bytes),
        .stderr = .ignore,
        .kill_scope = .process_group,
    }) catch return null;
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        .timed_out, .stdout_too_long, .stderr_too_long, .aborted => return null,
    };
    switch (completed.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    const bytes = if (options.trim)
        std.mem.trim(u8, completed.stdout, &std.ascii.whitespace)
    else
        completed.stdout;
    if (bytes.len == 0) return null;
    return allocator.dupe(u8, bytes) catch null;
}

pub fn succeeds(allocator: std.mem.Allocator, io: std.Io, argv: []const []const u8, timeout_ms: u64) bool {
    var result = process.run(allocator, io, .{
        .argv = argv,
        .timeout_ms = timeout_ms,
        .stdout = .ignore,
        .stderr = .ignore,
        .kill_scope = .child,
    }) catch return false;
    defer result.deinit(allocator);

    const completed = switch (result) {
        .completed => |completed| completed,
        .timed_out, .stdout_too_long, .stderr_too_long, .aborted => return false,
    };
    return switch (completed.term) {
        .exited => |code| code == 0,
        else => false,
    };
}

test "stdout returns trimmed output for successful small command" {
    const out = stdout(std.testing.allocator, std.Options.debug_io, .{
        .argv = &.{ "/bin/sh", "-c", "printf ' branch\\n'" },
        .timeout_ms = 1000,
    }) orelse return error.MissingOutput;
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("branch", out);
}

test "succeeds reports exit status" {
    try std.testing.expect(succeeds(std.testing.allocator, std.Options.debug_io, &.{ "/bin/sh", "-c", "exit 0" }, 1000));
    try std.testing.expect(!succeeds(std.testing.allocator, std.Options.debug_io, &.{ "/bin/sh", "-c", "exit 7" }, 1000));
}
