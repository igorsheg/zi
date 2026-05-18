const std = @import("std");
const protocol = @import("protocol.zig");
const provider = @import("provider.zig");

pub const TerminalKind = enum {
    completed,
    failed,
    aborted,
};

pub fn terminalKind(event: protocol.AssistantMessageEvent) ?TerminalKind {
    return switch (event) {
        .done => .completed,
        .@"error" => |payload| switch (payload.reason) {
            .aborted => .aborted,
            .@"error" => .failed,
        },
        else => null,
    };
}

pub fn isTerminal(event: protocol.AssistantMessageEvent) bool {
    return terminalKind(event) != null;
}

pub const TerminalInvariantError = error{
    MissingTerminal,
    DuplicateTerminal,
};

pub const TerminalTracker = struct {
    terminal_count: usize = 0,
    first_terminal: ?TerminalKind = null,
    duplicate_terminal: bool = false,

    pub fn observe(self: *TerminalTracker, event: protocol.AssistantMessageEvent) void {
        const kind = terminalKind(event) orelse return;
        self.terminal_count += 1;
        if (self.terminal_count == 1) {
            self.first_terminal = kind;
        } else {
            self.duplicate_terminal = true;
        }
    }

    pub fn finish(self: TerminalTracker) TerminalInvariantError!TerminalKind {
        if (self.terminal_count == 0) return error.MissingTerminal;
        if (self.duplicate_terminal) return error.DuplicateTerminal;
        return self.first_terminal.?;
    }
};

pub const TrackingSink = struct {
    tracker: *TerminalTracker,
    inner: provider.StreamEventSink,

    pub fn sink(self: *TrackingSink) provider.StreamEventSink {
        return .{ .func = emit, .ctx = @ptrCast(self) };
    }

    fn emit(event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *TrackingSink = @ptrCast(@alignCast(ctx.?));
        self.tracker.observe(event);
        self.inner.emit(event);
    }
};

const testing = std.testing;

test "terminal tracker requires exactly one terminal event" {
    var tracker: TerminalTracker = .{};
    try testing.expectError(error.MissingTerminal, tracker.finish());

    tracker.observe(.start);
    try testing.expectError(error.MissingTerminal, tracker.finish());

    tracker.observe(.{ .done = .{ .reason = .stop, .message = emptyAssistant(.stop) } });
    try testing.expectEqual(TerminalKind.completed, try tracker.finish());

    tracker.observe(.{ .@"error" = .{ .reason = .@"error", .@"error" = emptyAssistant(.@"error") } });
    try testing.expectError(error.DuplicateTerminal, tracker.finish());
}

test "terminal tracker classifies aborted error terminal" {
    var tracker: TerminalTracker = .{};
    tracker.observe(.{ .@"error" = .{ .reason = .aborted, .@"error" = emptyAssistant(.aborted) } });
    try testing.expectEqual(TerminalKind.aborted, try tracker.finish());
}

fn emptyAssistant(stop_reason: protocol.StopReason) protocol.AssistantMessage {
    return .{
        .content = &.{},
        .api = .openai_completions,
        .provider = .openai,
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}
