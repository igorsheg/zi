const std = @import("std");

pub const Limits = struct {
    max_line_bytes: usize = 64 * 1024,
    max_event_name_bytes: usize = 128,
    max_data_bytes: usize = 4 * 1024 * 1024,
    max_id_bytes: usize = 1024,
};

pub const Event = struct {
    event: ?[]const u8 = null,
    data: []const u8,
    id: ?[]const u8 = null,
    retry_ms: ?u64 = null,
};

pub const Error = error{
    OutOfMemory,
    LineTooLong,
    EventNameTooLong,
    DataTooLarge,
    IdTooLong,
};

pub const Parser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    pending_line: std.ArrayList(u8) = .empty,
    event_name: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    id: std.ArrayList(u8) = .empty,
    retry_ms: ?u64 = null,
    data_line_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Parser {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Parser) void {
        self.pending_line.deinit(self.allocator);
        self.event_name.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.id.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn feed(self: *Parser, bytes: []const u8, sink: anytype) !void {
        for (bytes) |byte| {
            if (byte == '\n') {
                try self.processLine(stripCarriageReturn(self.pending_line.items), sink);
                self.pending_line.clearRetainingCapacity();
                continue;
            }
            if (self.pending_line.items.len >= self.limits.max_line_bytes) return error.LineTooLong;
            try self.pending_line.append(self.allocator, byte);
        }
    }

    pub fn finish(self: *Parser, sink: anytype) !void {
        if (self.pending_line.items.len > 0) {
            try self.processLine(stripCarriageReturn(self.pending_line.items), sink);
            self.pending_line.clearRetainingCapacity();
        }
        try self.dispatch(sink);
        self.resetEvent();
    }

    fn processLine(self: *Parser, line: []const u8, sink: anytype) !void {
        if (line.len == 0) {
            try self.dispatch(sink);
            self.resetEvent();
            return;
        }
        if (line[0] == ':') return;

        const colon = std.mem.findScalar(u8, line, ':');
        const field = if (colon) |index| line[0..index] else line;
        var value = if (colon) |index| line[index + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            if (value.len > self.limits.max_event_name_bytes) return error.EventNameTooLong;
            self.event_name.clearRetainingCapacity();
            try self.event_name.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "data")) {
            const separator: usize = if (self.data_line_count > 0) 1 else 0;
            const next_length = std.math.add(usize, self.data.items.len, separator) catch return error.DataTooLarge;
            if (value.len > self.limits.max_data_bytes -| next_length) return error.DataTooLarge;
            if (separator == 1) try self.data.append(self.allocator, '\n');
            try self.data.appendSlice(self.allocator, value);
            self.data_line_count += 1;
        } else if (std.mem.eql(u8, field, "id")) {
            if (std.mem.findScalar(u8, value, 0) != null) return;
            if (value.len > self.limits.max_id_bytes) return error.IdTooLong;
            self.id.clearRetainingCapacity();
            try self.id.appendSlice(self.allocator, value);
        } else if (std.mem.eql(u8, field, "retry")) {
            self.retry_ms = std.fmt.parseUnsigned(u64, value, 10) catch self.retry_ms;
        }
    }

    fn dispatch(self: *Parser, sink: anytype) !void {
        if (self.data_line_count == 0 and self.event_name.items.len == 0 and self.id.items.len == 0) return;
        try sink.emit(.{
            .event = if (self.event_name.items.len > 0) self.event_name.items else null,
            .data = self.data.items,
            .id = if (self.id.items.len > 0) self.id.items else null,
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

fn stripCarriageReturn(line: []const u8) []const u8 {
    if (line.len > 0 and line[line.len - 1] == '\r') return line[0 .. line.len - 1];
    return line;
}

const CollectingSink = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *CollectingSink) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    fn emit(self: *CollectingSink, event: Event) !void {
        try self.values.append(self.allocator, try self.allocator.dupe(u8, event.data));
    }
};

test "SSE parser preserves split and multiline data" {
    var parser = Parser.init(std.testing.allocator, .{});
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed("event: message\nda", &sink);
    try parser.feed("ta: one\r\ndata: two\r\n\r\n", &sink);

    try std.testing.expectEqual(@as(usize, 1), sink.values.items.len);
    try std.testing.expectEqualStrings("one\ntwo", sink.values.items[0]);
}

test "SSE parser flushes final event and enforces bounds" {
    var parser = Parser.init(std.testing.allocator, .{ .max_line_bytes = 12, .max_data_bytes = 4 });
    defer parser.deinit();
    var sink: CollectingSink = .{ .allocator = std.testing.allocator };
    defer sink.deinit();

    try parser.feed("data: four", &sink);
    try parser.finish(&sink);
    try std.testing.expectEqualStrings("four", sink.values.items[0]);

    parser.deinit();
    parser = Parser.init(std.testing.allocator, .{ .max_line_bytes = 3 });
    try std.testing.expectError(error.LineTooLong, parser.feed("abcd", &sink));
}
