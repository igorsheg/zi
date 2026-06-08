const std = @import("std");

pub const snapshot_size_max: usize = 1024 * 1024;

pub const Options = struct {
    trim_trailing_whitespace: bool = true,
};

pub const SnapshotError = error{ SnapshotMismatch, SnapshotTooLarge };

pub fn expectSnapshot(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
) !void {
    return expectSnapshotOpts(allocator, path, actual, .{});
}

pub fn expectSnapshotOpts(
    allocator: std.mem.Allocator,
    path: []const u8,
    actual: []const u8,
    options: Options,
) !void {
    const normalized = try normalizeAlloc(allocator, actual, options);
    defer allocator.free(normalized);

    if (std.fs.path.dirname(path)) |dir| try std.fs.cwd().makePath(dir);

    if (snapshotsUpdateEnabled()) {
        try writeSnapshot(path, normalized);
        return;
    }

    const existing = std.fs.cwd().readFileAlloc(allocator, path, snapshot_size_max) catch |err| switch (err) {
        error.FileNotFound => {
            try writeSnapshot(path, normalized);
            return;
        },
        else => return err,
    };
    defer allocator.free(existing);

    const expected = try normalizeAlloc(allocator, existing, options);
    defer allocator.free(expected);

    if (!std.mem.eql(u8, expected, normalized)) return SnapshotError.SnapshotMismatch;
}

pub fn normalizeAlloc(allocator: std.mem.Allocator, text: []const u8, options: Options) ![]u8 {
    if (text.len > snapshot_size_max) return SnapshotError.SnapshotTooLarge;
    if (!options.trim_trailing_whitespace) return allocator.dupe(u8, text);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) try out.append(allocator, '\n');
        first = false;
        try out.appendSlice(allocator, trimRight(line));
    }
    return out.toOwnedSlice(allocator);
}

fn trimRight(line: []const u8) []const u8 {
    var end = line.len;
    while (end > 0) {
        const byte = line[end - 1];
        if (byte != ' ' and byte != '\t' and byte != '\r') break;
        end -= 1;
    }
    return line[0..end];
}

fn snapshotsUpdateEnabled() bool {
    const value = std.posix.getenv("ZI_UPDATE_SNAPSHOTS") orelse return false;
    return value.len > 0 and !std.mem.eql(u8, value, "0");
}

fn writeSnapshot(path: []const u8, text: []const u8) !void {
    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    var buffer: [4096]u8 = undefined;
    var writer = file.writer(&buffer);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

test "snapshot normalization trims trailing whitespace" {
    const normalized = try normalizeAlloc(std.testing.allocator, "a  \n b\t\r\n", .{});
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("a\n b\n", normalized);
}

test "snapshot normalization can preserve whitespace" {
    const normalized = try normalizeAlloc(
        std.testing.allocator,
        "a  ",
        .{ .trim_trailing_whitespace = false },
    );
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("a  ", normalized);
}
