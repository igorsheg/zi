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
    event_buf: [256]u8 = undefined,
    event_len: usize = 0,
    id_buf: [512]u8 = undefined,
    id_len: usize = 0,
    has_id: bool = false,
    needs_reset: bool = false,
    data_buf: std.ArrayListUnmanaged(u8) = .empty,

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
        if (self.needs_reset and line.len != 0) self.reset();

        if (line.len == 0) {
            if (self.data_buf.items.len == 0) {
                self.reset();
                return null;
            }

            var dlen = self.data_buf.items.len;
            if (dlen > 0 and self.data_buf.items[dlen - 1] == '\n') {
                dlen -= 1;
            }

            const evt = SseEvent{
                .id = if (self.has_id) self.id_buf[0..self.id_len] else self.lastEventId(),
                .event = if (self.event_len > 0) self.event_buf[0..self.event_len] else null,
                .data = self.data_buf.items[0..dlen],
            };

            if (self.has_id) {
                @memcpy(self.last_event_id_buf[0..self.id_len], self.id_buf[0..self.id_len]);
                self.last_event_id_len = self.id_len;
            }

            self.needs_reset = true;
            return evt;
        }

        if (line[0] == ':') return null;

        var field: []const u8 = "";
        var value: []const u8 = "";

        if (std.mem.indexOfScalar(u8, line, ':')) |colon| {
            field = line[0..colon];
            var v = line[colon + 1 ..];
            if (v.len > 0 and v[0] == ' ') v = v[1..];
            value = v;
        } else {
            field = line;
        }

        if (std.mem.eql(u8, field, "data")) {
            const needed = value.len + 1;
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
            if (std.mem.indexOfScalar(u8, value, 0) == null) {
                const len = @min(value.len, self.id_buf.len);
                @memcpy(self.id_buf[0..len], value[0..len]);
                self.id_len = len;
                self.has_id = true;
            }
        } else if (std.mem.eql(u8, field, "retry")) {
            if (std.fmt.parseUnsigned(u64, value, 10)) |ms| {
                self.retry_ms = ms;
            } else |_| {}
        }

        return null;
    }

    /// Reset per-event state. Does NOT clear last_event_id or retry_ms.
    pub fn reset(self: *SseParser) void {
        self.event_len = 0;
        self.id_len = 0;
        self.has_id = false;
        self.needs_reset = false;
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
        const n = streamReaderChunk(reader, &chunk_writer, .limited(effective_chunk_size)) catch |err| {
            if (err == error.EndOfStream) {
                _ = try drainReaderBufferInto(reader, &pending, allocator);
                try flushPendingLines(parser, &pending, handler, false);
                return;
            }
            if (err == error.WriteFailed) unreachable;
            return err;
        };

        var progressed = false;
        _ = n;
        if (chunk_writer.buffered().len != 0) {
            try pending.appendSlice(allocator, chunk_writer.buffered());
            progressed = true;
        }

        if (try drainReaderBufferInto(reader, &pending, allocator)) progressed = true;

        if (!progressed) continue;
        try flushPendingLines(parser, &pending, handler, false);
    }
}

fn streamReaderChunk(reader: anytype, w: *std.Io.Writer, limit: std.Io.Limit) !usize {
    return switch (comptime @typeInfo(@TypeOf(reader))) {
        .pointer => |info| switch (comptime @typeInfo(info.child)) {
            .pointer => streamReaderChunk(reader.*, w, limit),
            else => reader.*.stream(w, limit),
        },
        else => reader.stream(w, limit),
    };
}

fn drainReaderBufferInto(
    reader: anytype,
    pending: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,
) !bool {
    switch (comptime @typeInfo(@TypeOf(reader))) {
        .pointer => |info| switch (comptime @typeInfo(info.child)) {
            .pointer => return drainReaderBufferInto(reader.*, pending, allocator),
            else => {
                const R = info.child;
                if (comptime !@hasDecl(R, "buffered") or !@hasDecl(R, "tossBuffered")) return false;
                const buffered = reader.buffered();
                if (buffered.len == 0) return false;
                try pending.appendSlice(allocator, buffered);
                reader.tossBuffered();
                return true;
            },
        },
        else => return false,
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

fn expectNoEvent(parser: *SseParser, line: []const u8) !void {
    try std.testing.expectEqual(@as(?SseEvent, null), try parser.feedLine(line));
}

fn expectNextEvent(parser: *SseParser, expected_data: []const u8) !SseEvent {
    const event = (try parser.feedLine("")) orelse return error.TestExpectedEvent;
    try std.testing.expectEqualStrings(expected_data, event.data);
    return event;
}

fn feedDataLine(parser: *SseParser, data: []const u8) !void {
    var line: std.ArrayListUnmanaged(u8) = .empty;
    defer line.deinit(std.testing.allocator);
    try line.appendSlice(std.testing.allocator, "data: ");
    try line.appendSlice(std.testing.allocator, data);
    try expectNoEvent(parser, line.items);
}

const CapturedEvents = struct {
    count: usize = 0,
    last_event: ?[]const u8 = null,
    last_data: ?[]const u8 = null,

    fn handler(event: SseEvent, ctx: ?*anyopaque) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        self.count += 1;
        self.last_event = event.event;
        self.last_data = event.data;
    }

    fn eventHandler(self: *@This()) EventHandler {
        return .{ .func = &handler, .ctx = @ptrCast(self) };
    }
};

const ChunkedSliceReader = struct {
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

test "SseParser emits complete event with id, type, retry, and joined data" {
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    try expectNoEvent(&parser, "id: 42");
    try expectNoEvent(&parser, "retry: 3000");
    try expectNoEvent(&parser, "event: message_start");
    try expectNoEvent(&parser, "data: line1");
    try expectNoEvent(&parser, "data: line2");

    const event = try expectNextEvent(&parser, "line1\nline2");
    try std.testing.expectEqualStrings("42", event.id.?);
    try std.testing.expectEqualStrings("message_start", event.event.?);
    try std.testing.expectEqual(@as(?u64, 3000), parser.retry_ms);
}

test "SseParser carries last event id and ignores malformed retry" {
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    try expectNoEvent(&parser, "id: 42");
    try expectNoEvent(&parser, "retry: 3000");
    try feedDataLine(&parser, "first");
    _ = try expectNextEvent(&parser, "first");

    try feedDataLine(&parser, "second");
    const inherited = try expectNextEvent(&parser, "second");
    try std.testing.expectEqualStrings("42", inherited.id.?);

    try expectNoEvent(&parser, "retry: abc");
    try std.testing.expectEqual(@as(?u64, 3000), parser.retry_ms);
}

test "SseParser ignores comments and event-only blocks while preserving empty data events" {
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    try expectNoEvent(&parser, ": comment");
    try expectNoEvent(&parser, "event: ping");
    try expectNoEvent(&parser, "");

    try expectNoEvent(&parser, "data:");
    _ = try expectNextEvent(&parser, "");
}

test "SseParser accepts no-space values, CR-trimmed lines, and consecutive events" {
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    try expectNoEvent(&parser, "data:no-space");
    _ = try expectNextEvent(&parser, "no-space");

    const crlf_line = std.mem.trimEnd(u8, "data: crlf\r", "\r");
    try expectNoEvent(&parser, crlf_line);
    _ = try expectNextEvent(&parser, "crlf");

    try expectNoEvent(&parser, "event: a");
    try feedDataLine(&parser, "1");
    const first = try expectNextEvent(&parser, "1");
    try std.testing.expectEqualStrings("a", first.event.?);

    try expectNoEvent(&parser, "event: b");
    try feedDataLine(&parser, "2");
    const second = try expectNextEvent(&parser, "2");
    try std.testing.expectEqualStrings("b", second.event.?);
}

test "SseParser rejects event data beyond configured limit" {
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();

    const fitting_payload = try std.testing.allocator.alloc(u8, max_event_data_bytes - "data: ".len - 1);
    defer std.testing.allocator.free(fitting_payload);
    @memset(fitting_payload, 'x');

    try feedDataLine(&parser, fitting_payload);
    try std.testing.expectError(error.EventDataTooLarge, parser.feedLine("data: overflow"));
}

test "streamEvents feeds reader into parser" {
    const input = "event: test\ndata: hello\n\nevent: done\ndata: bye\n\n";
    var reader: std.Io.Reader = .fixed(input);
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();
    var captured = CapturedEvents{};

    try streamEvents(std.testing.allocator, &reader, &parser, 8, captured.eventHandler());

    try std.testing.expectEqual(@as(usize, 2), captured.count);
    try std.testing.expectEqualStrings("done", captured.last_event.?);
    try std.testing.expectEqualStrings("bye", captured.last_data.?);
}

test "streamEvents emits a data line longer than the read chunk" {
    const long_json = "{\"type\":\"response.output_text.delta\",\"delta\":\"" ++ ("x" ** 20000) ++ "\"}";
    const input = "data: " ++ long_json ++ "\n\n";
    var reader = ChunkedSliceReader{ .input = input };
    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();
    var captured = CapturedEvents{};

    try streamEvents(std.testing.allocator, &reader, &parser, 64, captured.eventHandler());

    try std.testing.expectEqual(@as(usize, 1), captured.count);
    try std.testing.expectEqualStrings(long_json, captured.last_data.?);
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
    var captured = CapturedEvents{};

    try streamEvents(std.testing.allocator, &reader, &parser, 64, captured.eventHandler());

    try std.testing.expectEqual(@as(usize, 1), captured.count);
    try std.testing.expectEqualStrings("hello", captured.last_data.?);
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
    var captured = CapturedEvents{};

    try streamEvents(std.testing.allocator, &reader, &parser, 64, captured.eventHandler());

    try std.testing.expectEqual(@as(usize, 0), captured.count);
}

test "streamEvents makes forward progress when stream parks bytes in reader buffer" {
    const input = "data: hello\n\n";
    var source_reader: std.Io.Reader = .fixed(input);

    var indirect_buf: [32]u8 = undefined;
    var indirect: std.testing.ReaderIndirect = .init(&source_reader, &indirect_buf);

    var parser = SseParser.init(std.testing.allocator);
    defer parser.deinit();
    var captured = CapturedEvents{};

    try streamEvents(std.testing.allocator, &indirect.interface, &parser, 16, captured.eventHandler());

    try std.testing.expectEqual(@as(usize, 1), captured.count);
    try std.testing.expectEqualStrings("hello", captured.last_data.?);
}
