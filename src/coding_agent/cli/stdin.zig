const std = @import("std");

const max_piped_stdin_bytes = 100 * 1024 * 1024;
const stdin_file: std.Io.File = .{ .handle = std.posix.STDIN_FILENO, .flags = .{ .nonblocking = false } };

pub fn readPipedStdin(allocator: std.mem.Allocator) !?[]const u8 {
    if (try stdin_file.isTty(std.Options.debug_io)) return null;

    var buf: [4096]u8 = undefined;
    var reader = stdin_file.reader(std.Options.debug_io, &buf);
    const raw = try reader.interface.allocRemaining(allocator, .limited(max_piped_stdin_bytes));
    return try normalizeOwnedPipedStdin(allocator, raw);
}

fn normalizeOwnedPipedStdin(allocator: std.mem.Allocator, raw: []u8) !?[]const u8 {
    errdefer allocator.free(raw);

    const trimmed = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        allocator.free(raw);
        return null;
    }
    if (trimmed.ptr == raw.ptr and trimmed.len == raw.len) {
        return raw;
    }

    const normalized = try allocator.dupe(u8, trimmed);
    allocator.free(raw);
    return normalized;
}

test "piped stdin trims outer whitespace and treats empty input as absent" {
    const empty_raw = try std.testing.allocator.dupe(u8, " \n\t ");
    try std.testing.expect((try normalizeOwnedPipedStdin(std.testing.allocator, empty_raw)) == null);

    const text_raw = try std.testing.allocator.dupe(u8, "\nfrom stdin\n");
    const text = (try normalizeOwnedPipedStdin(std.testing.allocator, text_raw)).?;
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("from stdin", text);
}
