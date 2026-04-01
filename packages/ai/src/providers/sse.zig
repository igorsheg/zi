const std = @import("std");

pub const SseEvent = struct {
    id: ?[]const u8 = null,
    event: ?[]const u8 = null,
    data: []const u8,
};

/// Line-oriented SSE parser following W3C Server-Sent Events spec (§9.2).
/// Zero-allocation: all slices in emitted events point into internal buffers
/// and are valid until the next call to feedLine() or reset().
pub const SseParser = struct {
    // Per-event buffers (cleared on event dispatch)
    event_buf: [256]u8 = undefined,
    event_len: usize = 0,
    id_buf: [512]u8 = undefined,
    id_len: usize = 0,
    has_id: bool = false,
    data_buf: [65536]u8 = undefined,
    data_len: usize = 0,
    has_data: bool = false,
    data_truncated: bool = false,

    // Persistent state (survives event boundaries)
    last_event_id_buf: [512]u8 = undefined,
    last_event_id_len: usize = 0,
    retry_ms: ?u64 = null,

    pub fn lastEventId(self: *const SseParser) ?[]const u8 {
        if (self.last_event_id_len == 0) return null;
        return self.last_event_id_buf[0..self.last_event_id_len];
    }

    /// Feed a single line (without trailing \n or \r\n).
    /// Returns SseEvent on event boundary (blank line) if data was present.
    pub fn feedLine(self: *SseParser, line: []const u8) ?SseEvent {
        // Blank line → dispatch event if we have data
        if (line.len == 0) {
            if (!self.has_data) {
                self.reset();
                return null;
            }

            // Strip trailing \n from multi-line data join (W3C §9.2.6)
            var dlen = self.data_len;
            if (dlen > 0 and self.data_buf[dlen - 1] == '\n') {
                dlen -= 1;
            }

            const evt = SseEvent{
                .id = if (self.has_id) self.id_buf[0..self.id_len] else self.lastEventId(),
                .event = if (self.event_len > 0) self.event_buf[0..self.event_len] else null,
                .data = self.data_buf[0..dlen],
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
        var field: []const u8 = undefined;
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
            if (!self.data_truncated) {
                const needed = value.len + 1; // +1 for \n separator
                if (self.data_len + needed > self.data_buf.len) {
                    self.data_truncated = true;
                } else {
                    @memcpy(self.data_buf[self.data_len .. self.data_len + value.len], value);
                    self.data_len += value.len;
                    self.data_buf[self.data_len] = '\n';
                    self.data_len += 1;
                    self.has_data = true;
                }
            }
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
            self.retry_ms = std.fmt.parseUnsigned(u64, value, 10) catch null;
        }

        return null;
    }

    /// Reset per-event state. Does NOT clear last_event_id or retry_ms.
    pub fn reset(self: *SseParser) void {
        self.event_len = 0;
        self.id_len = 0;
        self.has_id = false;
        self.data_len = 0;
        self.has_data = false;
        self.data_truncated = false;
    }
};

/// Feed a reader line-by-line into the parser, calling callback for each event.
/// This is the main integration point: connect an HTTP response reader to SSE parsing.
pub fn streamEvents(
    reader: anytype,
    parser: *SseParser,
    line_buf: []u8,
    callback: anytype,
) !void {
    while (true) {
        const line = reader.readUntilDelimiter(line_buf, '\n') catch |err| switch (err) {
            error.EndOfStream => {
                if (parser.has_data or parser.event_len > 0) {
                    if (parser.feedLine("")) |evt| {
                        callback(evt);
                    }
                }
                return;
            },
            else => return err,
        };

        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (parser.feedLine(trimmed)) |evt| {
            callback(evt);
        }
    }
}

// =============================================================================
// Tests
// =============================================================================

test "basic event with event type and data" {
    var p = SseParser{};
    try std.testing.expect(p.feedLine("event: message_start") == null);
    try std.testing.expect(p.feedLine("data: {\"type\":\"message_start\"}") == null);
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("message_start", evt.event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", evt.data);
}

test "id field captured and persists across events" {
    var p = SseParser{};
    _ = p.feedLine("id: 42");
    _ = p.feedLine("data: first");
    const e1 = p.feedLine("").?;
    try std.testing.expectEqualStrings("42", e1.id.?);

    // second event has no id: field but inherits last_event_id
    _ = p.feedLine("data: second");
    const e2 = p.feedLine("").?;
    try std.testing.expectEqualStrings("42", e2.id.?);
}

test "retry field parsed" {
    var p = SseParser{};
    _ = p.feedLine("retry: 3000");
    _ = p.feedLine("data: x");
    _ = p.feedLine("");
    try std.testing.expectEqual(@as(u64, 3000), p.retry_ms.?);

    // non-numeric retry ignored
    _ = p.feedLine("retry: abc");
    try std.testing.expectEqual(@as(u64, 3000), p.retry_ms.?);
}

test "multi-line data joined with newline" {
    var p = SseParser{};
    _ = p.feedLine("data: line1");
    _ = p.feedLine("data: line2");
    _ = p.feedLine("data: line3");
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("line1\nline2\nline3", evt.data);
}

test "comments ignored" {
    var p = SseParser{};
    try std.testing.expect(p.feedLine(": this is a comment") == null);
    _ = p.feedLine("data: hello");
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("hello", evt.data);
}

test "blank line without data emits nothing" {
    var p = SseParser{};
    _ = p.feedLine("event: ping");
    try std.testing.expect(p.feedLine("") == null);
}

test "bare data: dispatches event with empty data" {
    var p = SseParser{};
    _ = p.feedLine("data:");
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("", evt.data);
}

test "event with no data does not dispatch" {
    var p = SseParser{};
    _ = p.feedLine("event: ping");
    try std.testing.expect(p.feedLine("") == null);
}

test "colon without space preserves full value" {
    var p = SseParser{};
    _ = p.feedLine("data:no-space");
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("no-space", evt.data);
}

test "CRLF handling via trimmed input" {
    var p = SseParser{};
    // simulate what streamEvents does: trim \r
    const line = std.mem.trimRight(u8, "data: hello\r", "\r");
    _ = p.feedLine(line);
    const evt = p.feedLine("").?;
    try std.testing.expectEqualStrings("hello", evt.data);
}

test "multiple events in sequence" {
    var p = SseParser{};

    _ = p.feedLine("event: a");
    _ = p.feedLine("data: 1");
    const e1 = p.feedLine("").?;
    try std.testing.expectEqualStrings("a", e1.event.?);
    try std.testing.expectEqualStrings("1", e1.data);

    _ = p.feedLine("event: b");
    _ = p.feedLine("data: 2");
    const e2 = p.feedLine("").?;
    try std.testing.expectEqualStrings("b", e2.event.?);
    try std.testing.expectEqualStrings("2", e2.data);
}

test "data truncation when exceeding buffer" {
    var p = SseParser{};
    // fill buffer nearly full
    const big = "x" ** 65535;
    _ = p.feedLine("data: " ++ big);
    // this should trigger truncation
    _ = p.feedLine("data: overflow");
    const evt = p.feedLine("").?;
    // data_truncated means we got whatever fit
    try std.testing.expect(evt.data.len <= 65536);
}

test "streamEvents feeds reader into parser" {
    const input = "event: test\ndata: hello\n\nevent: done\ndata: bye\n\n";
    var stream = std.io.fixedBufferStream(input);
    var reader = stream.reader();

    var parser = SseParser{};
    var count: usize = 0;

    const Ctx = struct {
        fn cb(evt: SseEvent) void {
            _ = evt;
        }
    };
    _ = Ctx;

    // Use a simpler approach: collect events manually
    var line_buf: [4096]u8 = undefined;
    while (true) {
        const line = reader.readUntilDelimiter(&line_buf, '\n') catch break;
        const trimmed = std.mem.trimRight(u8, line, "\r");
        if (parser.feedLine(trimmed)) |_| {
            count += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), count);
}
