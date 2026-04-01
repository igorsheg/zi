const std = @import("std");

pub const HttpError = error{
    ConnectionFailed,
    RequestFailed,
    InvalidUrl,
    Timeout,
    TooManyRedirects,
    OutOfMemory,
} || std.http.Client.RequestError || std.http.Client.Request.SendError || std.http.Client.Request.WaitError || std.http.Client.Request.ReadError;

pub const HttpHeader = struct {
    name: []const u8,
    value: []const u8,
};

/// A streaming HTTP request that provides incremental response reading.
/// Wraps std.http.Client to provide a simpler API for LLM streaming.
pub const StreamingRequest = struct {
    allocator: std.mem.Allocator,
    client: std.http.Client,
    request: ?std.http.Client.Request,
    response_body: ?std.http.Client.Request.Reader,
    url_buffer: []u8,
    header_buffer: []u8,

    pub fn init(allocator: std.mem.Allocator) StreamingRequest {
        return .{
            .allocator = allocator,
            .client = std.http.Client{ .allocator = allocator },
            .request = null,
            .response_body = null,
            .url_buffer = &.{},
            .header_buffer = &.{},
        };
    }

    pub fn deinit(self: *StreamingRequest) void {
        if (self.request) |*req| {
            req.deinit();
        }
        self.client.deinit();
        if (self.url_buffer.len > 0) {
            self.allocator.free(self.url_buffer);
        }
        if (self.header_buffer.len > 0) {
            self.allocator.free(self.header_buffer);
        }
    }

    /// Start a streaming POST request.
    /// The request body is sent immediately, and the response can be read incrementally.
    pub fn post(
        self: *StreamingRequest,
        url: []const u8,
        headers: []const HttpHeader,
        body: []const u8,
    ) HttpError!void {
        // Parse the URL
        const uri = std.Uri.parse(url) catch return HttpError.InvalidUrl;

        // Allocate buffer for URL headers (needed by http client)
        const header_buffer_size = 16 * 1024;
        if (self.header_buffer.len == 0) {
            self.header_buffer = try self.allocator.alloc(u8, header_buffer_size);
        }

        // Prepare headers
        var header_list = std.ArrayList(std.http.Header).init(self.allocator);
        defer header_list.deinit();

        // Add provided headers
        for (headers) |h| {
            try header_list.append(.{
                .name = h.name,
                .value = h.value,
            });
        }

        // Add default Content-Type if not present
        var has_content_type = false;
        for (headers) |h| {
            if (std.ascii.eqlIgnoreCase(h.name, "content-type")) {
                has_content_type = true;
                break;
            }
        }
        if (!has_content_type) {
            try header_list.append(.{
                .name = "content-type",
                .value = "application/json",
            });
        }

        // Open connection and send request
        const req_options = std.http.Client.RequestOptions{
            .server_header_buffer = self.header_buffer,
            .headers = .{
                .content_type = .{ .override = "application/json" },
            },
            .extra_headers = header_list.items,
        };

        var req = try self.client.open(.POST, uri, req_options);
        errdefer req.deinit();

        // Send the request body
        req.transfer_encoding = .{ .content_length = body.len };
        try req.send();
        
        if (body.len > 0) {
            try req.writeAll(body);
        }
        try req.finish();
        try req.wait();

        self.request = req;
    }

    /// Read the next chunk of response body data.
    /// Returns number of bytes read (0 means end of stream).
    pub fn read(self: *StreamingRequest, buf: []u8) HttpError!usize {
        const req = self.request orelse return HttpError.RequestFailed;
        return try req.read(buf);
    }

    /// Get the HTTP status code of the response.
    /// Returns null if request hasn't been started.
    pub fn statusCode(self: *StreamingRequest) ?std.http.Status {
        const req = self.request orelse return null;
        return req.response.status;
    }

    /// Check if the response indicates success (2xx status)
    pub fn isSuccess(self: *StreamingRequest) bool {
        const status = self.statusCode() orelse return false;
        return @intFromEnum(status) >= 200 and @intFromEnum(status) < 300;
    }
};

/// Simple non-streaming POST request for one-shot API calls.
/// Caller owns the returned memory and must free it.
pub fn post(
    allocator: std.mem.Allocator,
    url: []const u8,
    headers: []const HttpHeader,
    body: []const u8,
) HttpError![]u8 {
    var client = StreamingRequest.init(allocator);
    defer client.deinit();

    try client.post(url, headers, body);

    const status = client.statusCode() orelse return HttpError.RequestFailed;
    if (@intFromEnum(status) < 200 or @intFromEnum(status) >= 300) {
        return HttpError.RequestFailed;
    }

    // Read full response
    var response = std.ArrayList(u8).init(allocator);
    defer response.deinit();

    var buf: [4096]u8 = undefined;
    while (true) {
        const n = try client.read(&buf);
        if (n == 0) break;
        try response.appendSlice(buf[0..n]);
    }

    return response.toOwnedSlice();
}
