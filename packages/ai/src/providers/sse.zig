const std = @import("std");

/// A parsed Server-Sent Event
pub const SseEvent = struct {
    /// Optional event type (e.g., "message_start", "content_block_delta")
    event: ?[]const u8 = null,
    /// Required data payload (usually JSON)
    data: []const u8,

    /// Free the event data using the provided allocator
    pub fn deinit(self: SseEvent, allocator: std.mem.Allocator) void {
        if (self.event) |e| {
            allocator.free(e);
        }
        allocator.free(self.data);
    }
};

/// SSE parser that processes a byte stream line by line.
/// SSE format:
///   event: message_start
///   data: {"type":"message_start",...}
///   
///   (blank line marks event boundary)
pub const SseParser = struct {
    allocator: std.mem.Allocator,
    /// Buffer for accumulating partial lines across feed() calls
    buffer: std.ArrayList(u8),
    /// Current event type being built
    current_event: ?[]const u8,
    /// Current data being accumulated
    current_data: std.ArrayList(u8),

    pub fn init(allocator: std.mem.Allocator) SseParser {
        return .{
            .allocator = allocator,
            .buffer = std.ArrayList(u8).init(allocator),
            .current_event = null,
            .current_data = std.ArrayList(u8).init(allocator),
        };
    }

    pub fn deinit(self: *SseParser) void {
        self.buffer.deinit();
        if (self.current_event) |e| {
            self.allocator.free(e);
        }
        self.current_data.deinit();
    }

    /// Feed a chunk of bytes. Returns an array of parsed events.
    /// Caller owns the returned events and must free them using event.deinit() or freeEvents().
    pub fn feed(self: *SseParser, chunk: []const u8) ![]SseEvent {
        var events = std.ArrayList(SseEvent).init(self.allocator);
        errdefer self.freeEvents(events.items);

        // Append new chunk to any buffered data
        try self.buffer.appendSlice(chunk);

        // Process complete lines from the buffer
        var start: usize = 0;
        while (start < self.buffer.items.len) {
            // Find end of line (\n or \r\n)
            var end = start;
            while (end < self.buffer.items.len and self.buffer.items[end] != '\n') {
                end += 1;
            }

            // If we didn't find a newline, we have a partial line - keep it in buffer
            if (end >= self.buffer.items.len) {
                // Remove processed bytes before the partial line
                if (start > 0) {
                    const remaining = self.buffer.items[start..];
                    std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
                    try self.buffer.resize(remaining.len);
                }
                break;
            }

            // Extract the line (excluding the newline)
            var line = self.buffer.items[start..end];
            // Strip \r if present (CRLF line endings)
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0..(line.len - 1)];
            }

            // Process the complete line
            try self.processLine(&events, line);

            // Move past the newline
            start = end + 1;
        }

        // If we processed all data, clear the buffer
        if (start >= self.buffer.items.len) {
            self.buffer.clearRetainingCapacity();
        } else if (start > 0) {
            // Keep any remaining partial data
            const remaining = self.buffer.items[start..];
            std.mem.copyForwards(u8, self.buffer.items[0..remaining.len], remaining);
            try self.buffer.resize(remaining.len);
        }

        return events.toOwnedSlice();
    }

    /// Free an array of events and the events array itself
    pub fn freeEvents(self: *SseParser, events: []SseEvent) void {
        for (events) |event| {
            event.deinit(self.allocator);
        }
        self.allocator.free(events);
    }

    /// Process a single line of SSE input
    fn processLine(self: *SseParser, events: *std.ArrayList(SseEvent), line: []const u8) !void {
        // Empty line marks event boundary - emit event if we have data
        if (line.len == 0) {
            if (self.current_data.items.len > 0) {
                const event_copy = if (self.current_event) |e|
                    try self.allocator.dupe(u8, e)
                else
                    null;
                errdefer if (event_copy) |e| self.allocator.free(e);

                const data_copy = try self.allocator.dupe(u8, self.current_data.items);
                errdefer self.allocator.free(data_copy);

                try events.append(.{
                    .event = event_copy,
                    .data = data_copy,
                });

                // Reset state for next event
                self.current_data.clearRetainingCapacity();
                if (self.current_event) |e| {
                    self.allocator.free(e);
                    self.current_event = null;
                }
            }
            return;
        }

        // Lines starting with ":" are comments - ignore them
        if (line[0] == ':') {
            return;
        }

        // Parse field: value format
        if (std.mem.indexOfScalar(u8, line, ':')) |colon_pos| {
            const field = line[0..colon_pos];
            // Value starts after colon, with optional leading space stripped
            var value = line[colon_pos + 1..];
            if (value.len > 0 and value[0] == ' ') {
                value = value[1..];
            }

            if (std.mem.eql(u8, field, "data")) {
                // Append data field value
                try self.current_data.appendSlice(value);
            } else if (std.mem.eql(u8, field, "event")) {
                // Set event type, replacing any previous event type
                if (self.current_event) |e| {
                    self.allocator.free(e);
                }
                self.current_event = try self.allocator.dupe(u8, value);
            }
            // "id" and "retry" fields are ignored for now (per spec but not needed for LLM APIs)
        }
        // Lines without colon are ignored (per SSE spec)
    }

    /// Call when stream ends to flush any remaining partial event
    pub fn flush(self: *SseParser) !?SseEvent {
        // Process any remaining buffered data as a final line
        if (self.buffer.items.len > 0) {
            var line = self.buffer.items;
            // Strip \r if present
            if (line.len > 0 and line[line.len - 1] == '\r') {
                line = line[0..(line.len - 1)];
            }
            
            // Create a temporary events list to process the final line
            var events = std.ArrayList(SseEvent).init(self.allocator);
            defer events.deinit();
            try self.processLine(&events, line);
            self.buffer.clearRetainingCapacity();
        }

        // Emit any pending event (even without trailing blank line)
        if (self.current_data.items.len > 0) {
            const event_copy = if (self.current_event) |e|
                try self.allocator.dupe(u8, e)
            else
                null;
            const data_copy = try self.allocator.dupe(u8, self.current_data.items);
            
            // Reset state
            self.current_data.clearRetainingCapacity();
            if (self.current_event) |e| {
                self.allocator.free(e);
                self.current_event = null;
            }

            return .{
                .event = event_copy,
                .data = data_copy,
            };
        }

        return null;
    }
};

test "SSE parser basic event" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const chunk = "event: message_start\ndata: {\"type\":\"message_start\"}\n\n";
    const events = try parser.feed(chunk);
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("message_start", events[0].event.?);
    try std.testing.expectEqualStrings("{\"type\":\"message_start\"}", events[0].data);
}

test "SSE parser multiple events" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const chunk = 
        "event: message_start\n" ++
        "data: {\"type\":\"message_start\"}\n" ++
        "\n" ++
        "event: content_block_delta\n" ++
        "data: {\"type\":\"content_block_delta\"}\n" ++
        "\n";
    
    const events = try parser.feed(chunk);
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 2), events.len);
    try std.testing.expectEqualStrings("message_start", events[0].event.?);
    try std.testing.expectEqualStrings("content_block_delta", events[1].event.?);
}

test "SSE parser chunked data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Feed partial data
    const chunk1 = "event: message_start\ndata: {\"type\":\"mess";
    const events1 = try parser.feed(chunk1);
    defer parser.freeEvents(events1);
    try std.testing.expectEqual(@as(usize, 0), events1.len);

    // Complete the event
    const chunk2 = "age_start\"}\n\n";
    const events2 = try parser.feed(chunk2);
    defer parser.freeEvents(events2);

    try std.testing.expectEqual(@as(usize, 1), events2.len);
    try std.testing.expectEqualStrings("message_start", events2[0].event.?);
}

test "SSE parser ignores comments" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const chunk = ":this is a comment\n" ++
        "event: test\n" ++
        "data: hello\n" ++
        "\n";
    
    const events = try parser.feed(chunk);
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test", events[0].event.?);
    try std.testing.expectEqualStrings("hello", events[0].data);
}

test "SSE parser multiline data" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    // Multiple data lines are concatenated
    const chunk = 
        "event: test\n" ++
        "data: line1\n" ++
        "data: line2\n" ++
        "\n";
    
    const events = try parser.feed(chunk);
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("line1line2", events[0].data);
}

test "SSE parser CRLF line endings" {
    const allocator = std.testing.allocator;
    var parser = SseParser.init(allocator);
    defer parser.deinit();

    const chunk = "event: test\r\ndata: hello\r\n\r\n";
    const events = try parser.feed(chunk);
    defer parser.freeEvents(events);

    try std.testing.expectEqual(@as(usize, 1), events.len);
    try std.testing.expectEqualStrings("test", events[0].event.?);
    try std.testing.expectEqualStrings("hello", events[0].data);
}
