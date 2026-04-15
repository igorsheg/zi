const std = @import("std");

pub const SseEvent = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: []const u8,
};

pub const EventHandler = struct {
    func: *const fn (event: SseEvent, ctx: ?*anyopaque) anyerror!void,
    ctx: ?*anyopaque = null,

    pub fn call(self: EventHandler, event: SseEvent) anyerror!void {
        return self.func(event, self.ctx);
    }
};

/// Line-oriented SSE parser following W3C Server-Sent Events spec (§9.2).
/// Event data is buffered in a retained-capacity growable buffer so large
/// provider payloads (for example Codex terminal events) don't get silently
/// truncated. Emitted slices are valid until the next call to feedLine() or
/// reset().
pub const max_event_data_bytes: usize = 1024 * 1024;

pub const SseParser = struct {
    allocator: std.mem.Allocator,
    // Per-event buffers (cleared on event dispatch)
    event_buf: [256]u8 = undefined,
    event_len: usize = 0,
    id_buf: [512]u8 = undefined,
    id_len: usize = 0,
    has_id: bool = false,
    data_buf: std.ArrayListUnmanaged(u8) = .empty,

    // Persistent state (survives event boundaries)
    last_event_id_buf: [512]u8 = undefined,
    last_event_id_len: usize = 0,
    retry_ms: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *SseParser) void {
        self.data_buf.deinit(self.allocator);
    }

    pub fn lastEventId(self: *const SseParser) ?[]const u8 {
        if (self.last_event_id_len == 0) return null;
        return self.last_event_id_buf[0..self.last_event_id_len];
    }

    /// Feed a single line (without trailing \n or \r\n).
    /// Returns SseEvent on event boundary (blank line) if data was present.
    pub fn feedLine(self: *SseParser, line: []const u8) error{ OutOfMemory, EventDataTooLarge }!?SseEvent {
        // Blank line → dispatch event if we have data
        if (line.len == 0) {
            if (self.data_buf.items.len == 0) {
                self.reset();
                return null;
            }

            // Strip trailing \n from multi-line data join (W3C §9.2.6)
            var dlen = self.data_buf.items.len;
            if (dlen > 0 and self.data_buf.items[dlen - 1] == '\n') {
                dlen -= 1;
            }

            const evt = SseEvent{
                .id = if (self.has_id) self.id_buf[0..self.id_len] else self.lastEventId(),
                .event = if (self.event_len > 0) self.event_buf[0..self.event_len] else null,
                .data = self.data_buf.items[0..dlen],
            };

            // Persist id for subsequent events
            if (self.has_id) {
                @memcpy(self.last_event_id_buf[0..self.id_len], self.id_buf[0..self.id_len]);
                self.last_event_id_len = self.id_len;
            }

            self.reset();
            return evt;
        }

        // Comment line
        if (line[0] == ':') return null;

        // Parse field:value
        var field: []const u8 = "";
        var value: []const u8 = "";

        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            field = line[0..colon];
            var v = line[colon + 1 ..];
            if (v.len > 0 and v[0] == ' ') v = v[1..];
            value = v;
        } else {
            // Entire line is the field name, value is empty string
            field = line;
        }

        if (std.mem.eql(u8, field, "data")) {
            const needed = value.len + 1; // +1 for \n separator
            if (self.data_buf.items.len + needed > max_event_data_bytes) {
                return error.EventDataTooLarge;
            }
            try self.data_buf.ensureUnusedCapacity(self.allocator, needed);
            self.data_buf.appendSliceAssumeCapacity(value);
            self.data_buf.appendAssumeCapacity('\n');
        } else if (std.mem.eql(u8, field, "event")) {
            const len = @min(value.len, self.event_buf.len);
            @memcpy(self.event_buf[0..len], value[0..len]);
            self.event_len = len;
        } else if (std.mem.eql(u8, field, "id")) {
            // W3C: if value contains U+0000, ignore the field
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                const len = @min(value.len, self.id_buf.len);
                @memcpy(self.id_buf[0..len], value[0..len]);
                self.id_len = len;
                self.has_id = true;
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            if (std.fmt.parseUnsigned(u64, value, 10)) |ms| {
                self.retry_ms = ms;
            } else |_| {} // W3C: ignore malformed retry values
        }

        return null;
    }

    /// Reset per-event state. Does NOT clear last_event_id or retry_ms.
    pub fn reset(self: *SseParser) void {
        self.event_len = 0;
        self.id_len = 0;
        self.has_id = false;
        self.data_buf.clearRetainingCapacity();
    }
};

/// Feed a reader into the parser with chunked reads, calling the handler for
/// each completed event. This avoids per-line reader capacity limits.
pub fn streamEvents(
    allocator: std.mem.Allocator,
    reader: anytype,
    parser: *SseParser,
    chunk_size: usize,
    handler: EventHandler,
) !void {
    var pending: std.ArrayListUnmanaged(u8) = .empty;
    defer pending.deinit(allocator);

    const effective_chunk_size = if (chunk_size == 0) 4096 else chunk_size;
    const chunk_buf = try allocator.alloc(u8, effective_chunk_size);
    defer allocator.free(chunk_buf);

    while (true) {
        var chunk_writer: std.Io.Writer = .fixed(chunk_buf);
        const n = reader.stream(&chunk_writer, .limited(effective_chunk_size)) catch |err| switch (err) {
            error.EndOfStream => {
                try flushPendingLines(parser, &pending, handler, false);
                return;
            },
            error.WriteFailed => unreachable,
            else => return err,
        };

        if (n == 0) continue;

        try pending.appendSlice(allocator, chunk_writer.buffered());
        try flushPendingLines(parser, &pending, handler, false);
    }
}

fn flushPendingLines(
    parser: *SseParser,
    pending: *std.ArrayListUnmanaged(u8),
    handler: EventHandler,
    flush_tail: bool,
) !void {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, pending.items, start, '\n')) |newline_idx| {
        var line = pending.items[start..newline_idx];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (try parser.feedLine(line)) |evt| {
            try handler.call(evt);
        }
        start = newline_idx + 1;
    }

    if (flush_tail and start < pending.items.len) {
        var tail = pending.items[start..];
        if (tail.len > 0 and tail[tail.len - 1] == '\r') tail = tail[0 .. tail.len - 1];
        if (try parser.feedLine(tail)) |evt| {
            try handler.call(evt);
        }
        start = pending.items.len;
    }

    if (start == 0) return;
    if (start >= pending.items.len) {
        pending.clearRetainingCapacity();
        return;
    }

    const remaining = pending.items.len - start;
    std.mem.copyForwards(u8, pending.items[0..remaining], pending.items[start..]);
    pending.items.len = remaining;
}

// =============================================================================
// Tests
// =============================================================================

test "basic event with event type and data" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expect((try p.feedLine("event: message_start")) == null);
    try std.testing.expect((try p.feedLine("data: {\"type\":\"message_start\"}")) == null);
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("message_start", evt.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", evt.data);
}

test "id field captured and persists across events" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("id: 42");
    _ = try p.feedLine("data: first");
    const e1 = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("42", e1.id.?);

    // second event has no id: field but inherits last_event_id
    _ = try p.feedLine("data: second");
    const e2 = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("42", e2.id.?);
}

test "retry field parsed" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("retry: 3000");
    _ = try p.feedLine("data: x");
    _ = try p.feedLine("");
    try std.testing.expectEqual(@as(u64, 3000), p.retry_ms.?);

    // non-numeric retry ignored
    _ = try p.feedLine("retry: abc");
    try std.testing.expectEqual(@as(u64, 3000), p.retry_ms.?);
}

test "multi-line data joined with newline" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("data: line1");
    _ = try p.feedLine("data: line2");
    _ = try p.feedLine("data: line3");
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("line1\nline2\nline3", evt.data);
}

test "comments ignored" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    try std.testing.expect((try p.feedLine(": this is a comment")) == null);
    _ = try p.feedLine("data: hello");
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("hello", evt.data);
}

test "blank line without data emits nothing" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("event: ping");
    try std.testing.expect((try p.feedLine("")) == null);
}

test "bare data: dispatches event with empty data" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("data:");
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("", evt.data);
}

test "event with no data does not dispatch" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("event: ping");
    try std.testing.expect((try p.feedLine("")) == null);
}

test "colon without space preserves full value" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    _ = try p.feedLine("data:no-space");
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("no-space", evt.data);
}

test "CRLF handling via trimmed input" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();
    // simulate what streamEvents does: trim \r
    const line = std.mem.trimRight(u8, "data: hello\r", "\r");
    _ = try p.feedLine(line);
    const evt = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("hello", evt.data);
}

test "multiple events in sequence" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();

    _ = try p.feedLine("event: a");
    _ = try p.feedLine("data: 1");
    const e1 = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("a", e1.event.?);
    try std.testing.expectEqualStrings("1", e1.data);

    _ = try p.feedLine("event: b");
    _ = try p.feedLine("data: 2");
    const e2 = (try p.feedLine("")).?;
    try std.testing.expectEqualStrings("b", e2.event.?);
    try std.testing.expectEqualStrings("2", e2.data);
}

test "event data larger than max fails instead of truncating" {
    var p = SseParser.init(std.testing.allocator);
    defer p.deinit();

    const big = try std.testing.allocator.alloc(u8, max_event_data_bytes - 7);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');

    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try line.ensureUnusedCapacity(std.testing.allocator, 6 + big.len);
    line.appendSliceAssumeCapacity("data: ");
    line.appendSliceAssumeCapacity(big);

    _ = try p.feedLine(line.items);
    try std.testing.expectError(error.EventDataTooLarge, p.feedLine("data: overflow"));
}

test "streamEvents feeds reader into parser" {
    const input = "event: test\ndata: hello\n\nevent: done\ndata: bye\n\n";
    var reader: std.Io.Reader = .fixed(input);

    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();
    var count: usize = 0;

    const Ctx = struct {
        count: *usize,

        fn cb(evt: SseEvent, ctx: ?*anyopaque) anyerror!void {
            _ = evt;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count.* += 1;
        }
    };

    var ctx = Ctx{ .count = &count };
    try streamEvents(std.testing.allocator, &reader, &parser, 8, .{
        .func = &Ctx.cb,
        .ctx = @ptrCast(&ctx),
    });
    try std.testing.expectEqual(@as(usize, 2), count);
}

test "streamEvents handles lines longer than chunk size" {
    const SliceReader = struct {
        input: []const u8,
        pos: usize = 0,

        fn stream(self: *@This(), w: *std.Io.Writer, limit: std.Io.Limit) !usize {
            if (self.pos >= self.input.len) return error.EndOfStream;
            const remaining = self.input.len - self.pos;
            const n = @min(limit.minInt(remaining), remaining);
            try w.writeAll(self.input[self.pos .. self.pos + n]);
            self.pos += n;
            return n;
        }
    };

    const long_json = "{\"type\":\"response.output_text.delta\",\"delta\":\"" ++ ("x" ** 20000) ++ "\"}";
    const input = "data: " ++ long_json ++ "\n\n";
    var reader = SliceReader{ .input = input };
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    const Ctx = struct {
        seen: bool = false,
        data_len: usize = 0,

        fn cb(evt: SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen = true;
            self.data_len = evt.data.len;
        }
    };

    var ctx = Ctx{};
    try streamEvents(std.testing.allocator, &reader, &parser, 64, .{
        .func = &Ctx.cb,
        .ctx = @ptrCast(&ctx),
    });

    try std.testing.expect(ctx.seen);
    try std.testing.expectEqual(long_json.len, ctx.data_len);
}

test "streamEvents retries after zero-byte read instead of treating it as EOF" {
    const ZeroThenMoreReader = struct {
        calls: usize = 0,

        fn stream(self: *@This(), w: *std.Io.Writer, limit: std.Io.Limit) !usize {
            const chunk = switch (self.calls) {
                0 => "data: hel",
                1 => {
                    self.calls += 1;
                    return 0;
                },
                2 => "lo\n\n",
                else => return error.EndOfStream,
            };
            self.calls += 1;
            const n = @min(limit.minInt(chunk.len), chunk.len);
            try w.writeAll(chunk[0..n]);
            return n;
        }
    };

    var reader = ZeroThenMoreReader{};
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    const Ctx = struct {
        seen: bool = false,
        data: ?[]const u8 = null,

        fn cb(evt: SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.seen = true;
            self.data = evt.data;
        }
    };

    var ctx = Ctx{};
    try streamEvents(std.testing.allocator, &reader, &parser, 64, .{
        .func = &Ctx.cb,
        .ctx = @ptrCast(&ctx),
    });

    try std.testing.expect(ctx.seen);
    try std.testing.expectEqualStrings("hello", ctx.data.?);
}

test "streamEvents discards unterminated tail at EOF" {
    const ZeroAtEndReader = struct {
        input: []const u8,
        pos: usize = 0,
        returned_zero: bool = false,

        fn stream(self: *@This(), w: *std.Io.Writer, limit: std.Io.Limit) !usize {
            if (self.pos < self.input.len) {
                const remaining = self.input.len - self.pos;
                const n = @min(limit.minInt(remaining), remaining);
                try w.writeAll(self.input[self.pos .. self.pos + n]);
                self.pos += n;
                return n;
            }
            if (!self.returned_zero) {
                self.returned_zero = true;
                return 0;
            }
            return error.EndOfStream;
        }
    };

    var reader = ZeroAtEndReader{ .input = "data: {\"type\":\"response.completed\"" };
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    const Ctx = struct {
        count: usize = 0,

        fn cb(_: SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.count += 1;
        }
    };

    var ctx = Ctx{};
    try streamEvents(std.testing.allocator, &reader, &parser, 64, .{
        .func = &Ctx.cb,
        .ctx = @ptrCast(&ctx),
    });

    try std.testing.expectEqual(@as(usize, 0), ctx.count);
}
