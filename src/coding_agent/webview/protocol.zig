const std = @import("std");
const types = @import("types.zig");

pub const HostEvent = union(enum) {
    ready: struct { window_id: []const u8 },
    closed: struct { window_id: []const u8 },
    err: struct { window_id: []const u8, message: []const u8 },
    bridge: BridgeEvent,

    pub const BridgeEvent = struct {
        window_id: []const u8,
        id: []const u8,
        command: []const u8,
        payload_json: []const u8,
    };

    pub fn deinit(self: *HostEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .ready => |v| allocator.free(v.window_id),
            .closed => |v| allocator.free(v.window_id),
            .err => |v| {
                allocator.free(v.window_id);
                allocator.free(v.message);
            },
            .bridge => |v| {
                allocator.free(v.window_id);
                allocator.free(v.id);
                allocator.free(v.command);
                allocator.free(v.payload_json);
            },
        }
        self.* = undefined;
    }
};

pub fn parseHostEvent(allocator: std.mem.Allocator, line: []const u8) !HostEvent {
    if (line.len > types.max_host_line_bytes) return error.EventTooLarge;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidEvent;
    const obj = parsed.value.object;
    const type_v = obj.get("type") orelse return error.InvalidEvent;
    if (type_v != .string) return error.InvalidEvent;
    const window_id = try dupJsonString(allocator, obj.get("window_id") orelse std.json.Value{ .string = "main" });
    errdefer allocator.free(window_id);

    if (std.mem.eql(u8, type_v.string, "ready")) {
        return .{ .ready = .{ .window_id = window_id } };
    }
    if (std.mem.eql(u8, type_v.string, "closed")) {
        return .{ .closed = .{ .window_id = window_id } };
    }
    if (std.mem.eql(u8, type_v.string, "error")) {
        const message = try dupJsonString(allocator, obj.get("message") orelse std.json.Value{ .string = "unknown error" });
        return .{ .err = .{ .window_id = window_id, .message = message } };
    }
    if (std.mem.eql(u8, type_v.string, "bridge")) {
        const id = try dupJsonString(allocator, obj.get("id") orelse return error.InvalidEvent);
        errdefer allocator.free(id);
        const command = try dupJsonString(allocator, obj.get("command") orelse return error.InvalidEvent);
        errdefer allocator.free(command);
        const payload_v = obj.get("payload") orelse std.json.Value.null;
        const payload_json = try stringifyJsonValue(allocator, payload_v);
        errdefer allocator.free(payload_json);
        if (payload_json.len > types.max_request_bytes) return error.PayloadTooLarge;
        return .{ .bridge = .{ .window_id = window_id, .id = id, .command = command, .payload_json = payload_json } };
    }
    return error.InvalidEvent;
}

pub fn writeJsonLine(allocator: std.mem.Allocator, file: std.Io.File, writer_io: std.Io, line: []const u8) !void {
    const framed = try allocator.alloc(u8, line.len + 1);
    defer allocator.free(framed);
    @memcpy(framed[0..line.len], line);
    framed[line.len] = '\n';
    try file.writeStreamingAll(writer_io, framed);
}

pub fn encodeBase64(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const Encoder = std.base64.standard.Encoder;
    const encoded = try allocator.alloc(u8, Encoder.calcSize(raw.len));
    _ = Encoder.encode(encoded, raw);
    return encoded;
}

fn dupJsonString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    if (value != .string) return error.InvalidEvent;
    return allocator.dupe(u8, value.string);
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

test "webview host event parser rejects lines over the host limit" {
    const line = try std.testing.allocator.alloc(u8, types.max_host_line_bytes + 1);
    defer std.testing.allocator.free(line);
    @memset(line, 'x');
    try std.testing.expectError(error.EventTooLarge, parseHostEvent(std.testing.allocator, line));
}

test "webview host event parser preserves bridge payload JSON" {
    var event = try parseHostEvent(std.testing.allocator,
        \\{"type":"bridge","window_id":"w","id":"1","command":"load_diff","payload":{"scope":"branch"}}
    );
    defer event.deinit(std.testing.allocator);
    try std.testing.expect(event == .bridge);
    try std.testing.expectEqualStrings("w", event.bridge.window_id);
    try std.testing.expectEqualStrings("1", event.bridge.id);
    try std.testing.expectEqualStrings("load_diff", event.bridge.command);
    try std.testing.expect(std.mem.indexOf(u8, event.bridge.payload_json, "branch") != null);
}
