const std = @import("std");
const mem = @import("../../runtime/root.zig");

pub const Error = error{
    BodyTooLarge,
    OutOfMemory,
};

pub fn bearerHeader(allocator: std.mem.Allocator, token: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{token});
}

pub fn appendPath(
    allocator: std.mem.Allocator,
    base_url: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error![]const u8 {
    std.debug.assert(suffix.len > 0);
    std.debug.assert(suffix[0] != '/');
    if (std.mem.endsWith(u8, base_url, suffix)) return allocator.dupe(u8, base_url);
    if (std.mem.endsWith(u8, base_url, "/")) return std.fmt.allocPrint(allocator, "{s}{s}", .{ base_url, suffix });
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ base_url, suffix });
}

pub fn readBoundedBody(allocator: std.mem.Allocator, reader: anytype, max_bytes: usize) ![]u8 {
    var body = mem.ByteBuilder.initBounded(allocator, max_bytes);
    errdefer body.deinit();

    while (body.items().len < max_bytes) {
        var chunk: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&chunk);
        const remaining = @min(chunk.len, max_bytes - body.items().len);
        const n = reader.stream(&writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try body.append(chunk[0..n]);
    }

    var extra: [1]u8 = undefined;
    var extra_writer: std.Io.Writer = .fixed(&extra);
    const extra_count = reader.stream(&extra_writer, .limited(extra.len)) catch |err| switch (err) {
        error.EndOfStream => return body.toOwnedSlice(),
        else => return err,
    };
    if (extra_count > 0) return error.BodyTooLarge;

    return body.toOwnedSlice();
}

test "appendPath joins slash-separated suffix" {
    const allocator = std.testing.allocator;
    const a = try appendPath(allocator, "https://example.test/v1", "responses");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("https://example.test/v1/responses", a);

    const b = try appendPath(allocator, "https://example.test/v1/", "responses");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("https://example.test/v1/responses", b);
}

test "bearerHeader formats authorization header" {
    const value = try bearerHeader(std.testing.allocator, "token");
    defer std.testing.allocator.free(value);
    try std.testing.expectEqualStrings("Bearer token", value);
}

test "readBoundedBody returns body at limit when stream ends" {
    var reader = std.Io.Reader.fixed("abcd");
    const body = try readBoundedBody(std.testing.allocator, &reader, 4);
    defer std.testing.allocator.free(body);

    try std.testing.expectEqualStrings("abcd", body);
}

test "readBoundedBody rejects body larger than limit" {
    var reader = std.Io.Reader.fixed("abcde");

    try std.testing.expectError(error.BodyTooLarge, readBoundedBody(std.testing.allocator, &reader, 4));
}
