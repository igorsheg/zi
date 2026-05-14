const std = @import("std");
const net = std.Io.net;
const posix = std.posix;

const log = std.log.scoped(.callback_server);
const zio = @import("../../zio/root.zig");

pub const CallbackResult = union(enum) {
    success: struct {
        code: []const u8,
        state: []const u8,
    },
    err: []const u8,
    timeout,
    cancelled,

    pub fn deinit(self: CallbackResult, allocator: std.mem.Allocator) void {
        switch (self) {
            .success => |s| {
                allocator.free(s.code);
                allocator.free(s.state);
            },
            .err, .timeout, .cancelled => {},
        }
    }
};

pub fn waitForCallback(
    allocator: std.mem.Allocator,
    port: u16,
    path: []const u8,
    expected_state: []const u8,
    signal: zio.cancel.Token,
) CallbackResult {
    const address = net.IpAddress.parseIp4("127.0.0.1", port) catch unreachable;
    var server = address.listen(std.Options.debug_io, .{ .reuse_address = true }) catch |err| {
        log.err("failed to listen on port {d}: {s}", .{ port, @errorName(err) });
        return .{ .err = "failed to bind callback server" };
    };
    defer server.deinit(std.Options.debug_io);

    const cancel_fd = signal.wakeReadFd();
    while (!signal.isAborted()) {
        var pfd = [1]posix.pollfd{.{
            .fd = server.socket.handle,
            .events = posix.POLL.IN,
            .revents = undefined,
        }};
        var pfds_with_cancel = [2]posix.pollfd{
            pfd[0],
            .{ .fd = cancel_fd orelse -1, .events = posix.POLL.IN, .revents = 0 },
        };
        const ready = if (cancel_fd != null) posix.poll(&pfds_with_cancel, -1) catch continue else posix.poll(&pfd, 500) catch continue;
        if (ready == 0) continue;
        if (cancel_fd != null and pfds_with_cancel[1].revents & posix.POLL.IN != 0) {
            signal.acknowledgeWake();
            return .cancelled;
        }
        if (cancel_fd != null) pfd[0] = pfds_with_cancel[0];

        const stream = server.accept(std.Options.debug_io) catch continue;
        defer stream.close(std.Options.debug_io);

        var read_buf: [4096]u8 = undefined;
        var reader = stream.reader(std.Options.debug_io, &read_buf);
        const request_line = (reader.interface.takeDelimiter('\n') catch {
            sendResponse(stream, "400 Bad Request", error_html);
            continue;
        }) orelse {
            sendResponse(stream, "400 Bad Request", error_html);
            continue;
        };

        const result = parseCallbackRequest(allocator, request_line, path, expected_state);

        switch (result) {
            .success => {
                sendResponse(stream, "200 OK", success_html);
                return result;
            },
            .err => {
                sendResponse(stream, "400 Bad Request", error_html);
                continue;
            },
            else => continue,
        }
    }

    return .cancelled;
}

fn sendResponse(stream: net.Stream, status: []const u8, body: []const u8) void {
    var write_buf: [4096]u8 = undefined;
    var writer = stream.writer(std.Options.debug_io, &write_buf);
    const w = &writer.interface;

    w.print("HTTP/1.1 {s}\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: {d}\r\nConnection: close\r\n\r\n{s}", .{
        status,
        body.len,
        body,
    }) catch return;
    w.flush() catch return;
}

pub fn parseCallbackRequest(
    allocator: std.mem.Allocator,
    request_line: []const u8,
    expected_path: []const u8,
    expected_state: []const u8,
) CallbackResult {
    const line = std.mem.trimEnd(u8, request_line, "\r");

    if (!std.mem.startsWith(u8, line, "GET ")) {
        return .{ .err = "not a GET request" };
    }

    const after_get = line[4..];
    const uri_end = std.mem.indexOf(u8, after_get, " ") orelse after_get.len;
    const uri = after_get[0..uri_end];

    const query_start = std.mem.indexOf(u8, uri, "?") orelse {
        return .{ .err = "no query string" };
    };

    const req_path = uri[0..query_start];
    if (!std.mem.eql(u8, req_path, expected_path)) {
        return .{ .err = "path mismatch" };
    }

    const query = uri[query_start + 1 ..];
    var code: ?[]const u8 = null;
    var state: ?[]const u8 = null;
    var oauth_error: ?[]const u8 = null;

    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |param| {
        const eq = std.mem.indexOf(u8, param, "=") orelse continue;
        const key = param[0..eq];
        const value = param[eq + 1 ..];
        if (std.mem.eql(u8, key, "code")) {
            code = value;
        } else if (std.mem.eql(u8, key, "state")) {
            state = value;
        } else if (std.mem.eql(u8, key, "error")) {
            oauth_error = value;
        }
    }

    if (oauth_error) |_| {
        return .{ .err = "authentication did not complete" };
    }

    const code_val = code orelse return .{ .err = "missing code parameter" };
    const state_val = state orelse return .{ .err = "missing state parameter" };

    if (!std.mem.eql(u8, state_val, expected_state)) {
        return .{ .err = "state mismatch" };
    }

    const owned_code = allocator.dupe(u8, code_val) catch return .{ .err = "allocation failed" };
    const owned_state = allocator.dupe(u8, state_val) catch {
        allocator.free(owned_code);
        return .{ .err = "allocation failed" };
    };

    return .{ .success = .{ .code = owned_code, .state = owned_state } };
}

const success_html =
    \\<!doctype html><html><head><meta charset="utf-8"><title>Authentication successful</title>
    \\<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    \\background:#09090b;color:#fafafa;font-family:system-ui,sans-serif;text-align:center}
    \\h1{font-size:28px;font-weight:650}p{color:#a1a1aa;font-size:15px}</style></head>
    \\<body><main><h1>Authentication successful</h1>
    \\<p>You can close this window and return to the terminal.</p></main></body></html>
;

const error_html =
    \\<!doctype html><html><head><meta charset="utf-8"><title>Authentication failed</title>
    \\<style>body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
    \\background:#09090b;color:#fafafa;font-family:system-ui,sans-serif;text-align:center}
    \\h1{font-size:28px;font-weight:650}p{color:#a1a1aa;font-size:15px}</style></head>
    \\<body><main><h1>Authentication failed</h1>
    \\<p>Something went wrong. Please try again.</p></main></body></html>
;

test "parseCallbackRequest extracts code and state" {
    const alloc = std.testing.allocator;
    const result = parseCallbackRequest(
        alloc,
        "GET /callback?code=abc123&state=xyz789 HTTP/1.1\r",
        "/callback",
        "xyz789",
    );
    defer result.deinit(alloc);

    switch (result) {
        .success => |s| {
            try std.testing.expectEqualStrings("abc123", s.code);
            try std.testing.expectEqualStrings("xyz789", s.state);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parseCallbackRequest rejects wrong path" {
    const result = parseCallbackRequest(
        std.testing.allocator,
        "GET /wrong?code=abc&state=xyz HTTP/1.1\r",
        "/callback",
        "xyz",
    );
    switch (result) {
        .err => |msg| try std.testing.expectEqualStrings("path mismatch", msg),
        else => return error.TestUnexpectedResult,
    }
}

test "parseCallbackRequest rejects state mismatch" {
    const result = parseCallbackRequest(
        std.testing.allocator,
        "GET /callback?code=abc&state=wrong HTTP/1.1\r",
        "/callback",
        "expected",
    );
    switch (result) {
        .err => |msg| try std.testing.expectEqualStrings("state mismatch", msg),
        else => return error.TestUnexpectedResult,
    }
}
