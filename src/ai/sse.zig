const std = @import("std");
const mem = @import("../runtime/root.zig");

pub const default_max_line_bytes: usize = 64 * 1024;
pub const default_max_event_name_bytes: usize = 128;
pub const default_max_data_bytes: usize = 4 * 1024 * 1024;
pub const default_max_id_bytes: usize = 1024;

pub const Limits = struct {
    max_line_bytes: usize = default_max_line_bytes,
    max_event_name_bytes: usize = default_max_event_name_bytes,
    max_data_bytes: usize = default_max_data_bytes,
    max_id_bytes: usize = default_max_id_bytes,
};

pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
};

pub const Error = error{
    LineTooLong,
    EventNameTooLong,
    DataTooLarge,
    IdTooLong,
    OutOfMemory,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    pending_line: mem.ByteBuilder,
    event_name: mem.ByteBuilder,
    data: mem.ByteBuilder,
    id: mem.ByteBuilder,
    retry_ms: ?u64 = null,
    data_line_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Parser {
        return .{
            .allocator = allocator,
            .limits = limits,
            .pending_line = mem.ByteBuilder.init(allocator),
            .event_name = mem.ByteBuilder.init(allocator),
            .data = mem.ByteBuilder.init(allocator),
            .id = mem.ByteBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *Parser) void {
        self.pending_line.deinit();
        self.event_name.deinit();
        self.data.deinit();
        self.id.deinit();
        self.* = undefined;
    }

    pub fn reset(self: *Parser) void {
        self.pending_line.clearRetainingCapacity();
        self.resetEvent();
    }

    pub fn feed(
        self: *Parser,
        bytes: []const u8,
        sink: anytype,
    ) anyerror!void {
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(stripTrailingCarriageReturn(self.pending_line.items()), sink);
                self.pending_line.clearRetainingCapacity();
                continue;
            }

            if (self.pending_line.items().len + 1 > self.limits.max_line_bytes) return error.LineTooLong;
            try self.pending_line.appendByte(byte);
        }
    }

    pub fn finish(self: *Parser, sink: anytype) anyerror!void {
        if (self.pending_line.items().len > 0) {
            try self.processLine(stripTrailingCarriageReturn(self.pending_line.items()), sink);
            self.pending_line.clearRetainingCapacity();
        }
        try self.dispatchIfNotEmpty(sink);
    }

    fn processLine(self: *Parser, line: []const u8, sink: anytype) anyerror!void {
        if (line.len == 0) {
            try self.dispatchIfNotEmpty(sink);
            self.resetEvent();
            return;
        }

        if (line[0] == ':') return;

        const delimiter = std.mem.findScalar(u8, line, ':');
        const field = if (delimiter) |index| line[0..index] else line;
        var value = if (delimiter) |index| line[index + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            if (value.len > self.limits.max_event_name_bytes) return error.EventNameTooLong;
            self.event_name.clearRetainingCapacity();
            try self.event_name.append(value);
        } else if (std.mem.eql(u8, field, "data")) {
            const separator_len: usize = if (self.data_line_count > 0) 1 else 0;
            if (self.data.items().len + separator_len + value.len > self.limits.max_data_bytes) {
                return error.DataTooLarge;
            }
            if (separator_len == 1) try self.data.appendByte('\n');
            try self.data.append(value);
            self.data_line_count += 1;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.findScalar(u8, value, 0) != null) return;
            if (value.len > self.limits.max_id_bytes) return error.IdTooLong;
            self.id.clearRetainingCapacity();
            try self.id.append(value);
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry_ms = std.fmt.parseUnsigned(u64, value, 10) catch self.retry_ms;
        }
    }

    fn dispatchIfNotEmpty(self: *Parser, sink: anytype) anyerror!void {
        if (self.data_line_count == 0 and self.event_name.items().len == 0 and self.id.items().len == 0) return;
        try sink.emit(.{
            .event = if (self.event_name.items().len > 0) self.event_name.items() else null,
            .data = self.data.items(),
            .id = if (self.id.items().len > 0) self.id.items() else null,
            .retry_ms = self.retry_ms,
        });
    }

    fn resetEvent(self: *Parser) void {
        self.event_name.clearRetainingCapacity();
        self.data.clearRetainingCapacity();
        self.id.clearRetainingCapacity();
        self.retry_ms = null;
        self.data_line_count = 0;
    }
};

fn stripTrailingCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

const CollectingSink = struct {
    allocator: std.mem.Allocator,
    events: std.ArrayList(RetainedEvent) = .empty,

    fn deinit(self: *CollectingSink) void {
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.* = undefined;
    }

    fn emit(self: *CollectingSink, event: Event) !void {
        try self.events.append(self.allocator, try RetainedEvent.copy(self.allocator, event));
    }
};

const RetainedEvent = struct {
    event: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,

    fn copy(allocator: std.mem.Allocator, source: Event) !RetainedEvent {
        return .{
            .event = if (source.event) |value| try allocator.dupe(u8, value) else null,
            .data = try allocator.dupe(u8, source.data),
            .id = if (source.id) |value| try allocator.dupe(u8, value) else null,
            .retry_ms = source.retry_ms,
        };
    }

    fn deinit(self: *RetainedEvent, allocator: std.mem.Allocator) void {
        if (self.event) |value| allocator.free(value);
        allocator.free(self.data);
        if (self.id) |value| allocator.free(value);
        self.* = undefined;
    }
};

test "parser emits data event split across chunks" {
    var parser = Parser.init(std.testing.allocator, .{});
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed("event: message\nda", &sink);
    try parser.feed("ta: hello\n\n", &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("message", sink.events.items[0].event.?);
    try std.testing.expectEqualStrings("hello", sink.events.items[0].data);
}

test "parser joins multiline data with newline" {
    var parser = Parser.init(std.testing.allocator, .{});
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed("data: one\r\ndata: two\r\n\r\n", &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("one\ntwo", sink.events.items[0].data);
}

test "parser ignores comments and captures id and retry" {
    var parser = Parser.init(std.testing.allocator, .{});
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed(": ping\nid: abc\nretry: 42\ndata: ok\n\n", &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("abc", sink.events.items[0].id.?);
    try std.testing.expectEqual(@as(?u64, 42), sink.events.items[0].retry_ms);
    try std.testing.expectEqualStrings("ok", sink.events.items[0].data);
}

test "finish flushes trailing event without blank line" {
    var parser = Parser.init(std.testing.allocator, .{});
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed("data: final", &sink);
    try parser.finish(&sink);

    try std.testing.expectEqual(@as(usize, 1), sink.events.items.len);
    try std.testing.expectEqualStrings("final", sink.events.items[0].data);
}

test "parser enforces line and data bounds" {
    var parser = Parser.init(std.testing.allocator, .{ .max_line_bytes = 3, .max_data_bytes = 4 });
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try std.testing.expectError(error.LineTooLong, parser.feed("abcd", &sink));
    parser.deinit();
    parser = Parser.init(std.testing.allocator, .{ .max_data_bytes = 4 });
    try std.testing.expectError(error.DataTooLarge, parser.feed("data: fives\n", &sink));
}
