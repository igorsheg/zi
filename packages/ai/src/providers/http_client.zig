const std = @import("std");
const sse = @import("sse.zig");

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// Streaming HTTP+SSE client for LLM API calls.
/// Combines HTTP POST with SSE response parsing using zig 0.15 std.http.Client.
pub const LlmStream = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    request: ?std.http.Client.Request = null,
    response: ?std.http.Client.Response = null,

    // Owned buffers for request/response lifecycle
    body_buf: ?[]u8 = null,
    redirect_buf: [1024]u8 = undefined,
    transfer_buf: [16384]u8 = undefined,

    pub fn init(allocator: std.mem.Allocator) LlmStream {
        return .{
            .allocator = allocator,
            .client = .{ .allocator = allocator },
        };
    }

    pub fn deinit(self: *LlmStream) void {
        if (self.request) |*req| req.deinit();
        if (self.body_buf) |buf| self.allocator.free(buf);
        self.client.deinit();
    }

    /// POST JSON to an API endpoint and stream SSE events back via callback.
    pub fn postAndStream(
        self: *LlmStream,
        url: []const u8,
        headers: []const HttpHeader,
        body: []const u8,
        callback: anytype,
    ) !void {
        const uri = std.Uri.parse(url) catch return error.InvalidUrl;

        // Convert HttpHeader to std.http.Header
        var extra = std.ArrayList(std.http.Header).init(self.allocator);
        defer extra.deinit();
        for (headers) |h| {
            try extra.append(.{ .name = h.name, .value = h.value });
        }

        var req = try self.client.request(.POST, uri, .{
            .headers = .{ .content_type = .{ .override = "application/json" } },
            .extra_headers = extra.items,
        });
        errdefer req.deinit();

        // sendBodyComplete needs []u8 (mutable), so dupe if needed
        const mutable_body = try self.allocator.dupe(u8, body);
        self.body_buf = mutable_body;

        try req.sendBodyComplete(mutable_body);

        var resp = try req.receiveHead(&self.redirect_buf);
        self.request = req;
        self.response = resp;

        // Stream SSE events from response body
        const body_reader = resp.reader(&self.transfer_buf);
        var parser = sse.SseParser{};
        var line_buf: [65536]u8 = undefined;

        try sse.streamEvents(body_reader, &parser, &line_buf, callback);
    }

    /// HTTP response status, available after request completes.
    pub fn status(self: *LlmStream) ?std.http.Status {
        const resp = self.response orelse return null;
        return resp.head.status;
    }
};

/// Simple one-shot POST for non-streaming API calls.
/// Caller owns the returned memory.
pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const HttpHeader,
    body: []const u8,
) ![]u8 {
    const uri = std.Uri.parse(url) catch return error.InvalidUrl;

    var extra = std.ArrayList(std.http.Header).init(allocator);
    defer extra.deinit();
    for (headers) |h| {
        try extra.append(.{ .name = h.name, .value = h.value });
    }

    var client: std.http.Client = .{ .allocator = allocator };
    defer client.deinit();

    var req = try client.request(.POST, uri, .{
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = extra.items,
    });
    defer req.deinit();

    const mutable_body = try allocator.dupe(u8, body);
    defer allocator.free(mutable_body);

    try req.sendBodyComplete(mutable_body);

    var resp = try req.receiveHead(&.{});
    const resp_status = resp.head.status;
    if (@intFromEnum(resp_status) < 200 or @intFromEnum(resp_status) >= 300) {
        return error.RequestFailed;
    }

    var transfer_buf: [16384]u8 = undefined;
    const reader = resp.reader(&transfer_buf);

    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = reader.read(&buf) catch break;
        if (n == 0) break;
        try result.appendSlice(buf[0..n]);
    }

    return result.toOwnedSlice();
}
