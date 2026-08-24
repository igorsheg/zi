const std = @import("std");

pub const Limits = struct {
    max_line_bytes: usize,
    max_event_bytes: usize,
    max_data_bytes: usize,
};

pub const DeliveryError = error{Cancelled};

/// Synchronous sink for one parsed SSE event. Both slices are parser-owned and
/// valid only until `emit` returns.
pub const EventSink = struct {
    context: *anyopaque,
    emit_fn: *const fn (*anyopaque, []const u8, []const u8) DeliveryError!void,

    pub fn emit(self: EventSink, event_name: []const u8, data: []const u8) DeliveryError!void {
        return self.emit_fn(self.context, event_name, data);
    }

    pub fn from(implementation: anytype) EventSink {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("EventSink.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn emit(context: *anyopaque, event_name: []const u8, data: []const u8) DeliveryError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.emit(event_name, data);
            }
        };
        return .{ .context = implementation, .emit_fn = Adapter.emit };
    }
};

pub const ParseError = error{
    OutOfMemory,
    Cancelled,
    LineTooLong,
    EventTooLong,
    DataTooLong,
};

const Failure = enum {
    out_of_memory,
    line_too_long,
    event_too_long,
    data_too_long,

    fn toError(self: Failure) ParseError {
        return switch (self) {
            .out_of_memory => error.OutOfMemory,
            .line_too_long => error.LineTooLong,
            .event_too_long => error.EventTooLong,
            .data_too_long => error.DataTooLong,
        };
    }
};

/// Incremental, explicitly bounded SSE parser.
///
/// A non-cancellation parse failure is sticky because `feed` cannot report how
/// much of its input was consumed. `deinit` remains valid after every failure.
pub const Parser = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    sink: EventSink,
    line: std.ArrayList(u8) = .empty,
    event: std.ArrayList(u8) = .empty,
    data: std.ArrayList(u8) = .empty,
    failure: ?Failure = null,
    callback_stopped: bool = false,

    pub fn init(allocator: std.mem.Allocator, limits: Limits, sink: EventSink) Parser {
        return .{ .allocator = allocator, .limits = limits, .sink = sink };
    }

    pub fn deinit(self: *Parser) void {
        self.line.deinit(self.allocator);
        self.event.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.* = undefined;
    }

    /// Consumes arbitrary chunks. Partial lines are retained between calls.
    pub fn feed(self: *Parser, bytes: []const u8) ParseError!void {
        try self.checkState();

        var line_start: usize = 0;
        for (bytes, 0..) |byte, index| {
            if (byte != '\n') continue;

            self.appendLine(bytes[line_start..index]) catch |err| return self.fail(err);
            self.processLine(self.line.items) catch |err| return self.failOrStop(err);
            self.line.clearRetainingCapacity();
            line_start = index + 1;
        }
        if (line_start < bytes.len) {
            self.appendLine(bytes[line_start..]) catch |err| return self.fail(err);
        }
    }

    /// Processes a final partial line and dispatches the final buffered event.
    /// Calling `finalize` again after success is a no-op.
    pub fn finalize(self: *Parser) ParseError!void {
        try self.checkState();
        if (self.line.items.len > 0) {
            self.processLine(self.line.items) catch |err| return self.failOrStop(err);
            self.line.clearRetainingCapacity();
        }
        self.emitEvent() catch |err| return self.stop(err);
    }

    fn checkState(self: *const Parser) ParseError!void {
        if (self.failure) |failure| return failure.toError();
        if (self.callback_stopped) return error.Cancelled;
    }

    fn appendLine(self: *Parser, bytes: []const u8) error{ OutOfMemory, LineTooLong }!void {
        if (bytes.len > self.limits.max_line_bytes -| self.line.items.len) return error.LineTooLong;
        try self.line.appendSlice(self.allocator, bytes);
    }

    fn processLine(self: *Parser, raw_line: []const u8) ParseError!void {
        var line = raw_line;
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];

        if (line.len == 0) return self.emitEvent();
        if (line[0] == ':') return;

        const colon_index = std.mem.findScalar(u8, line, ':');
        const field = if (colon_index) |index| line[0..index] else line;
        var value = if (colon_index) |index| line[index + 1 ..] else "";
        if (value.len > 0 and value[0] == ' ') value = value[1..];

        if (std.mem.eql(u8, field, "event")) {
            if (value.len > self.limits.max_event_bytes) return error.EventTooLong;
            try self.event.ensureTotalCapacity(self.allocator, value.len);
            self.event.clearRetainingCapacity();
            self.event.appendSliceAssumeCapacity(value);
        } else if (std.mem.eql(u8, field, "data")) {
            const separator_len: usize = if (self.data.items.len > 0) 1 else 0;
            const available = self.limits.max_data_bytes -| self.data.items.len;
            if (separator_len > available or value.len > available - separator_len) return error.DataTooLong;
            try self.data.ensureUnusedCapacity(self.allocator, separator_len + value.len);
            if (separator_len != 0) self.data.appendAssumeCapacity('\n');
            self.data.appendSliceAssumeCapacity(value);
        }
    }

    fn emitEvent(self: *Parser) DeliveryError!void {
        if (self.event.items.len == 0 and self.data.items.len == 0) return;
        defer {
            self.event.clearRetainingCapacity();
            self.data.clearRetainingCapacity();
        }
        self.sink.emit(self.event.items, self.data.items) catch |err| return self.stop(err);
    }

    fn fail(self: *Parser, err: error{ OutOfMemory, LineTooLong }) ParseError {
        self.failure = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.LineTooLong => .line_too_long,
        };
        return err;
    }

    fn failOrStop(self: *Parser, err: ParseError) ParseError {
        if (err == error.Cancelled) return self.stop(error.Cancelled);
        self.failure = switch (err) {
            error.OutOfMemory => .out_of_memory,
            error.LineTooLong => .line_too_long,
            error.EventTooLong => .event_too_long,
            error.DataTooLong => .data_too_long,
            error.Cancelled => unreachable,
        };
        return err;
    }

    fn stop(self: *Parser, err: DeliveryError) error{Cancelled} {
        self.callback_stopped = true;
        return err;
    }
};

const Capture = struct {
    const max_events = 8;
    const max_bytes = 64;

    events: [max_events][max_bytes]u8 = undefined,
    event_lengths: [max_events]usize = @splat(0),
    data_items: [max_events][max_bytes]u8 = undefined,
    data_lengths: [max_events]usize = @splat(0),
    count: usize = 0,
    cancel_after: ?usize = null,

    fn emit(self: *Capture, event_name: []const u8, data: []const u8) DeliveryError!void {
        if (self.count >= max_events or event_name.len > max_bytes or data.len > max_bytes) unreachable;
        @memcpy(self.events[self.count][0..event_name.len], event_name);
        @memcpy(self.data_items[self.count][0..data.len], data);
        self.event_lengths[self.count] = event_name.len;
        self.data_lengths[self.count] = data.len;
        self.count += 1;
        if (self.cancel_after == self.count) return error.Cancelled;
    }

    fn eventAt(self: *const Capture, index: usize) []const u8 {
        return self.events[index][0..self.event_lengths[index]];
    }

    fn dataAt(self: *const Capture, index: usize) []const u8 {
        return self.data_items[index][0..self.data_lengths[index]];
    }
};

const test_limits: Limits = .{
    .max_line_bytes = 128,
    .max_event_bytes = 32,
    .max_data_bytes = 128,
};

fn expectInputWithSplit(input: []const u8, split: usize) !void {
    var capture: Capture = .{};
    var parser = Parser.init(std.testing.allocator, test_limits, EventSink.from(&capture));
    defer parser.deinit();
    try parser.feed(input[0..split]);
    try parser.feed(input[split..]);
    try parser.finalize();

    try std.testing.expectEqual(@as(usize, 2), capture.count);
    try std.testing.expectEqualStrings("replacement", capture.eventAt(0));
    try std.testing.expectEqualStrings("one\ntwo", capture.dataAt(0));
    try std.testing.expectEqualStrings("", capture.eventAt(1));
    try std.testing.expectEqualStrings("tail", capture.dataAt(1));
}

test "arbitrary splits preserve LF and CRLF events" {
    const lf = ": ignored\nevent: old\nevent: replacement\nunknown: value\ndata: one\ndata:two\n\ndata: tail";
    for (0..lf.len + 1) |split| try expectInputWithSplit(lf, split);

    const crlf = ": ignored\r\nevent: old\r\nevent: replacement\r\n" ++
        "unknown: value\r\ndata: one\r\ndata:two\r\n\r\ndata: tail";
    for (0..crlf.len + 1) |split| try expectInputWithSplit(crlf, split);
}

test "byte-at-a-time feed consumes one optional space and final partial line" {
    var capture: Capture = .{};
    var parser = Parser.init(std.testing.allocator, test_limits, EventSink.from(&capture));
    defer parser.deinit();
    const input = "event:no-space\ndata:  one-space-remains\n\n";
    for (input) |byte| try parser.feed(&.{byte});
    try parser.finalize();
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqualStrings("no-space", capture.eventAt(0));
    try std.testing.expectEqualStrings(" one-space-remains", capture.dataAt(0));
}

test "blank input and empty fields are suppressed" {
    var capture: Capture = .{};
    var parser = Parser.init(std.testing.allocator, test_limits, EventSink.from(&capture));
    defer parser.deinit();
    try parser.feed("\n\r\ndata:\n\nevent:\n\n");
    try parser.finalize();
    try parser.finalize();
    try std.testing.expectEqual(@as(usize, 0), capture.count);
}

test "callback cancellation is terminal and clears borrowed event" {
    var capture: Capture = .{ .cancel_after = 1 };
    var parser = Parser.init(std.testing.allocator, test_limits, EventSink.from(&capture));
    defer parser.deinit();
    try std.testing.expectError(error.Cancelled, parser.feed("data: first\n\ndata: second\n\n"));
    try std.testing.expectError(error.Cancelled, parser.feed("data: third\n\n"));
    try std.testing.expectError(error.Cancelled, parser.finalize());
    try std.testing.expectEqual(@as(usize, 1), capture.count);
    try std.testing.expectEqual(@as(usize, 0), parser.event.items.len);
    try std.testing.expectEqual(@as(usize, 0), parser.data.items.len);
}

test "each explicit bound is enforced and failure is sticky" {
    var capture: Capture = .{};

    var line_parser = Parser.init(std.testing.allocator, .{
        .max_line_bytes = 4,
        .max_event_bytes = 4,
        .max_data_bytes = 4,
    }, EventSink.from(&capture));
    defer line_parser.deinit();
    try std.testing.expectError(error.LineTooLong, line_parser.feed("data:"));
    try std.testing.expectError(error.LineTooLong, line_parser.finalize());

    var event_parser = Parser.init(std.testing.allocator, .{
        .max_line_bytes = 32,
        .max_event_bytes = 3,
        .max_data_bytes = 32,
    }, EventSink.from(&capture));
    defer event_parser.deinit();
    try std.testing.expectError(error.EventTooLong, event_parser.feed("event: four\n"));
    try std.testing.expectError(error.EventTooLong, event_parser.feed("event: ok\n"));

    var data_parser = Parser.init(std.testing.allocator, .{
        .max_line_bytes = 32,
        .max_event_bytes = 32,
        .max_data_bytes = 3,
    }, EventSink.from(&capture));
    defer data_parser.deinit();
    try data_parser.feed("data: ab\n");
    try std.testing.expectError(error.DataTooLong, data_parser.feed("data: c\n"));
}

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var capture: Capture = .{};
    var parser = Parser.init(allocator, test_limits, EventSink.from(&capture));
    defer parser.deinit();
    try parser.feed("event: initial\nevent: replacement\ndata: alpha\ndata: beta\n\ndata: trailing");
    try parser.finalize();
}

test "allocation failures leak no parser storage" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}
