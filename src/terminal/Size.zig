const std = @import("std");
const builtin = @import("builtin");
const Size = @This();

const default_columns: usize = 80;
const default_rows: usize = 24;
/// Matches the current EditLayout dimension bound without coupling this policy to that leaf module.
const max_dimension: usize = 4096;

columns: usize,
rows: usize,

/// Queries terminal geometry without allocating. An unsupported target or failed query
/// returns 80x24. A successful query normalizes zero dimensions independently.
pub fn query(fd: std.posix.fd_t) Size {
    return queryWithFallback(fd, default_columns);
}

/// Returns the content-width terminal snapshot used by banner and summary
/// policy. Hax presentation falls back to 100 columns when no width is known;
/// editor geometry keeps the narrower 80-column fallback in `query`.
pub fn presentationColumns(fd: std.posix.fd_t) usize {
    return queryWithFallback(fd, 100).columns;
}

fn queryWithFallback(fd: std.posix.fd_t, fallback_columns: usize) Size {
    const fallback: Size = .{ .columns = fallback_columns, .rows = default_rows };
    const request: c_int = switch (builtin.os.tag) {
        .linux => 0x5413,
        .macos, .ios, .tvos, .watchos, .visionos => 0x40087468,
        else => return fallback,
    };

    var raw: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    if (std.c.ioctl(fd, request, &raw) != 0) return fallback;
    return normalize(raw.col, raw.row, fallback_columns);
}

fn normalize(columns: usize, rows: usize, fallback_columns: usize) Size {
    return .{
        .columns = normalizeDimension(columns, fallback_columns),
        .rows = normalizeDimension(rows, default_rows),
    };
}

fn normalizeDimension(value: usize, default_value: usize) usize {
    return if (value == 0) default_value else @min(value, max_dimension);
}

extern "c" fn openpty(
    master: *c_int,
    slave: *c_int,
    name: ?[*]u8,
    termios_value: ?*const std.posix.termios,
    window_size: ?*const std.posix.winsize,
) c_int;

fn expectSize(columns: usize, rows: usize, actual: Size) !void {
    try std.testing.expectEqual(columns, actual.columns);
    try std.testing.expectEqual(rows, actual.rows);
}

test "normalize preserves dimensions within the bound" {
    try expectSize(132, 43, normalize(132, 43, default_columns));
}

test "normalize replaces zero dimensions independently" {
    try expectSize(80, 43, normalize(0, 43, default_columns));
    try expectSize(132, 24, normalize(132, 0, default_columns));
    try expectSize(80, 24, normalize(0, 0, default_columns));
}

test "normalize caps each dimension" {
    try expectSize(4096, 4096, normalize(4097, 65535, default_columns));
    try expectSize(80, 4096, normalize(0, 5000, default_columns));
}

test "query reads a valid pseudo-terminal size" {
    const supported = switch (builtin.os.tag) {
        .linux, .macos => true,
        else => false,
    };
    if (!supported) return error.SkipZigTest;

    var requested: std.posix.winsize = std.mem.zeroes(std.posix.winsize);
    requested.row = 33;
    requested.col = 47;
    var master: c_int = -1;
    var slave: c_int = -1;
    if (openpty(&master, &slave, null, null, &requested) != 0) return error.SkipZigTest;
    const master_file: std.Io.File = .{ .handle = master, .flags = .{ .nonblocking = false } };
    const slave_file: std.Io.File = .{ .handle = slave, .flags = .{ .nonblocking = false } };
    defer master_file.close(std.testing.io);
    defer slave_file.close(std.testing.io);

    try expectSize(47, 33, query(slave));
    try std.testing.expectEqual(@as(usize, 47), presentationColumns(slave));
}

test "query falls back for an invalid descriptor" {
    const supported = switch (builtin.os.tag) {
        .linux, .macos, .ios, .tvos, .watchos, .visionos => true,
        else => false,
    };
    if (!supported) return error.SkipZigTest;
    try expectSize(default_columns, default_rows, query(-1));
    try std.testing.expectEqual(@as(usize, 100), presentationColumns(-1));
}
