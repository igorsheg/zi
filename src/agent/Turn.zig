const std = @import("std");
const ai = @import("../ai/root.zig");

const Item = ai.Item.Item;
const StreamEvent = ai.StreamEvent.StreamEvent;

pub const State = enum {
    streaming,
    done,
    failed,
};

pub const Limits = struct {
    items: usize = 256,
    pending_tool_calls: usize = 64,
    text_bytes: usize = 8 * 1024 * 1024,
    reasoning_bytes: usize = 8 * 1024 * 1024,
    tool_arguments_bytes: usize = 1024 * 1024,
    tool_id_bytes: usize = 4 * 1024,
    tool_name_bytes: usize = 256,
    reasoning_opaque_bytes: usize = 1024 * 1024,
};

pub const Error = error{
    OutOfMemory,
    TooManyItems,
    TooManyPendingToolCalls,
    TextTooLarge,
    ReasoningTooLarge,
    ToolArgumentsTooLarge,
    ToolIdTooLarge,
    ToolNameTooLarge,
    ReasoningOpaqueTooLarge,
};

const PendingToolCall = struct {
    id: []u8,
    name: []u8,
    arguments: std.ArrayList(u8) = .empty,

    fn deinit(self: *PendingToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        self.arguments.deinit(allocator);
        self.* = undefined;
    }
};

/// Pure assembly state for one provider stream.
/// The turn owns all buffered bytes and assembled items.
pub const Turn = struct {
    allocator: std.mem.Allocator,
    limits: Limits,
    items: std.ArrayList(Item) = .empty,
    text: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
    has_text: bool = false,
    has_reasoning: bool = false,
    pending_calls: std.ArrayList(PendingToolCall) = .empty,
    state: State = .streaming,
    /// Usage from the terminal attempt. Retried attempts stay separate so this
    /// attempt alone determines the last context window.
    usage: ai.Usage.StreamUsage = .{},
    retry_usage: ai.Usage.StreamUsage = .{},
    last_context_tokens: ?u64 = null,

    pub fn init(allocator: std.mem.Allocator, limits: Limits) Turn {
        return .{ .allocator = allocator, .limits = limits };
    }

    pub fn deinit(self: *Turn) void {
        self.clearOwned();
        self.* = undefined;
    }

    /// Frees all assembly and accounting state and leaves the turn ready for another stream.
    pub fn reset(self: *Turn) void {
        self.resetAttempt();
        self.usage = .{};
        self.retry_usage = .{};
        self.last_context_tokens = null;
    }

    pub fn hasAssistantText(self: *const Turn) bool {
        if (self.has_text) return true;
        for (self.items.items) |item| if (item == .assistant_message) return true;
        return false;
    }

    pub fn survivesCancel(self: *const Turn) bool {
        if (self.has_text) return true;
        for (self.items.items) |item| {
            if (item == .assistant_message or item == .tool_call) return true;
        }
        return false;
    }

    /// Returns billable usage for the terminal attempt and every retried attempt.
    pub fn totalUsage(self: *const Turn) ai.Usage.StreamUsage {
        var total = self.usage;
        ai.Usage.add(&total, self.retry_usage);
        return total;
    }

    fn resetAttempt(self: *Turn) void {
        self.clearOwned();
        self.items = .empty;
        self.text = .empty;
        self.reasoning = .empty;
        self.pending_calls = .empty;
        self.has_text = false;
        self.has_reasoning = false;
        self.state = .streaming;
    }

    fn clearOwned(self: *Turn) void {
        for (self.pending_calls.items) |*call| call.deinit(self.allocator);
        self.pending_calls.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.reasoning.deinit(self.allocator);
        for (self.items.items) |*item| item.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }

    /// Consumes one borrowed event. Events after a terminal event are ignored.
    pub fn consume(self: *Turn, event: StreamEvent) Error!void {
        if (self.state != .streaming) return;

        switch (event) {
            .text_delta => |delta| try self.consumeTextDelta(delta),
            .tool_call_start => |start| try self.consumeToolStart(start.id, start.name),
            .tool_call_delta => |delta| try self.appendToolArguments(delta.id, delta.arguments_delta),
            .tool_call_end => |id| try self.finishToolCall(id),
            .reasoning_delta => |maybe_delta| if (maybe_delta) |delta| {
                if (delta.len != 0) {
                    try appendBounded(
                        self.allocator,
                        error.ReasoningTooLarge,
                        &self.reasoning,
                        delta,
                        self.limits.reasoning_bytes,
                    );
                    self.has_reasoning = true;
                }
            },
            .reasoning_item => |reasoning_item| try self.consumeReasoningItem(reasoning_item.opaque_json),
            .retry => |retry| {
                if (retry.usage) |usage| ai.Usage.add(&self.retry_usage, usage);
                self.resetAttempt();
            },
            .progress => {},
            .done => |done| {
                self.recordTerminalUsage(done.usage);
                try self.consumeDone();
            },
            .failure => |failure| {
                if (failure.usage) |usage| self.recordTerminalUsage(usage);
                self.state = .failed;
            },
        }
    }

    /// Commits buffered assistant text and appends a non-empty suffix first.
    /// All fallible work completes before the source buffer changes.
    pub fn flushText(self: *Turn, suffix: ?[]const u8) Error!void {
        if (!self.has_text) return;
        const value = suffix orelse "";
        if (value.len > self.limits.text_bytes -| self.text.items.len) return error.TextTooLarge;
        try self.reserveItems(1);
        const combined = try self.allocator.alloc(u8, self.text.items.len + value.len);
        errdefer self.allocator.free(combined);
        @memcpy(combined[0..self.text.items.len], self.text.items);
        @memcpy(combined[self.text.items.len..], value);

        self.text.deinit(self.allocator);
        self.text = .empty;
        self.has_text = false;
        self.items.appendAssumeCapacity(.{ .assistant_message = .{ .text = combined } });
    }

    fn flushReasoning(self: *Turn) Error!void {
        if (!self.has_reasoning) return;
        try self.reserveItems(1);
        const text = try self.allocator.dupe(u8, self.reasoning.items);
        errdefer self.allocator.free(text);

        self.reasoning.deinit(self.allocator);
        self.reasoning = .empty;
        self.has_reasoning = false;
        self.items.appendAssumeCapacity(.{ .reasoning = .{ .text = text } });
    }

    /// Discards reasoning that has not yet become an item.
    pub fn discardReasoning(self: *Turn) void {
        self.reasoning.deinit(self.allocator);
        self.reasoning = .empty;
        self.has_reasoning = false;
    }

    /// Keeps only assistant text after a failed provider attempt.
    pub fn keepText(self: *Turn) void {
        self.discardReasoning();
        var kept: usize = 0;
        for (self.items.items) |*item| {
            if (item.* == .assistant_message) {
                self.items.items[kept] = item.*;
                kept += 1;
            } else {
                item.deinit(self.allocator);
            }
        }
        self.items.items.len = kept;
    }

    /// Transfers the assembled item slice to the caller.
    pub fn takeItems(self: *Turn) Error![]Item {
        const result = try self.items.toOwnedSlice(self.allocator);
        self.items = .empty;
        return result;
    }

    fn reserveItems(self: *Turn, count: usize) Error!void {
        if (count > self.limits.items -| self.items.items.len) return error.TooManyItems;
        try self.items.ensureUnusedCapacity(self.allocator, count);
    }

    fn consumeTextDelta(self: *Turn, delta: []const u8) Error!void {
        if (delta.len > self.limits.text_bytes -| self.text.items.len) return error.TextTooLarge;
        try self.text.ensureUnusedCapacity(self.allocator, delta.len);
        try self.flushReasoning();
        self.text.appendSliceAssumeCapacity(delta);
        self.has_text = true;
    }

    fn consumeToolStart(self: *Turn, id: []const u8, name: []const u8) Error!void {
        if (id.len > self.limits.tool_id_bytes) return error.ToolIdTooLarge;
        if (name.len > self.limits.tool_name_bytes) return error.ToolNameTooLarge;
        if (self.pending_calls.items.len >= self.limits.pending_tool_calls) {
            return error.TooManyPendingToolCalls;
        }
        const flush_count = @as(usize, @intFromBool(self.has_reasoning)) +
            @as(usize, @intFromBool(self.has_text));
        try self.reserveItems(flush_count);
        try self.pending_calls.ensureUnusedCapacity(self.allocator, 1);

        const owned_id = try self.allocator.dupe(u8, id);
        errdefer self.allocator.free(owned_id);
        const owned_name = try self.allocator.dupe(u8, name);
        errdefer self.allocator.free(owned_name);
        const reasoning_text = if (self.has_reasoning)
            try self.allocator.dupe(u8, self.reasoning.items)
        else
            null;
        errdefer if (reasoning_text) |text| self.allocator.free(text);
        const assistant_text = if (self.has_text)
            try self.allocator.dupe(u8, self.text.items)
        else
            null;
        errdefer if (assistant_text) |text| self.allocator.free(text);

        if (reasoning_text) |text| {
            self.reasoning.deinit(self.allocator);
            self.reasoning = .empty;
            self.has_reasoning = false;
            self.items.appendAssumeCapacity(.{ .reasoning = .{ .text = text } });
        }
        if (assistant_text) |text| {
            self.text.deinit(self.allocator);
            self.text = .empty;
            self.has_text = false;
            self.items.appendAssumeCapacity(.{ .assistant_message = .{ .text = text } });
        }
        self.pending_calls.appendAssumeCapacity(.{ .id = owned_id, .name = owned_name });
    }

    fn consumeReasoningItem(self: *Turn, opaque_json: []const u8) Error!void {
        if (opaque_json.len > self.limits.reasoning_opaque_bytes) {
            return error.ReasoningOpaqueTooLarge;
        }
        const item_count: usize = 1 + @as(usize, @intFromBool(self.has_text));
        try self.reserveItems(item_count);
        const assistant_text = if (self.has_text)
            try self.allocator.dupe(u8, self.text.items)
        else
            null;
        errdefer if (assistant_text) |text| self.allocator.free(text);
        const owned_opaque = try self.allocator.dupe(u8, opaque_json);
        errdefer self.allocator.free(owned_opaque);
        const reasoning_text = if (self.has_reasoning)
            try self.allocator.dupe(u8, self.reasoning.items)
        else
            null;
        errdefer if (reasoning_text) |text| self.allocator.free(text);

        if (assistant_text) |text| {
            self.text.deinit(self.allocator);
            self.text = .empty;
            self.has_text = false;
            self.items.appendAssumeCapacity(.{ .assistant_message = .{ .text = text } });
        }
        if (reasoning_text != null) {
            self.reasoning.deinit(self.allocator);
            self.reasoning = .empty;
            self.has_reasoning = false;
        }
        self.items.appendAssumeCapacity(.{ .reasoning = .{
            .opaque_json = owned_opaque,
            .text = reasoning_text,
        } });
    }

    fn consumeDone(self: *Turn) Error!void {
        const item_count = @as(usize, @intFromBool(self.has_reasoning)) +
            @as(usize, @intFromBool(self.has_text));
        try self.reserveItems(item_count);
        const reasoning_text = if (self.has_reasoning)
            try self.allocator.dupe(u8, self.reasoning.items)
        else
            null;
        errdefer if (reasoning_text) |text| self.allocator.free(text);
        const assistant_text = if (self.has_text)
            try self.allocator.dupe(u8, self.text.items)
        else
            null;
        errdefer if (assistant_text) |text| self.allocator.free(text);

        if (reasoning_text) |text| {
            self.reasoning.deinit(self.allocator);
            self.reasoning = .empty;
            self.has_reasoning = false;
            self.items.appendAssumeCapacity(.{ .reasoning = .{ .text = text } });
        }
        if (assistant_text) |text| {
            self.text.deinit(self.allocator);
            self.text = .empty;
            self.has_text = false;
            self.items.appendAssumeCapacity(.{ .assistant_message = .{ .text = text } });
        }
        self.state = .done;
    }

    fn recordTerminalUsage(self: *Turn, usage: ai.Usage.StreamUsage) void {
        self.usage = usage;
        if (self.usage.cost_usd) |cost| {
            if (!std.math.isFinite(cost) or cost < 0) self.usage.cost_usd = null;
        }
        self.last_context_tokens = if (usage.input_tokens) |input|
            if (usage.output_tokens) |output| input +| output else null
        else
            null;
    }

    fn appendToolArguments(self: *Turn, id: []const u8, delta: []const u8) Error!void {
        const call = self.findPendingCall(id) orelse return;
        try appendBounded(
            self.allocator,
            error.ToolArgumentsTooLarge,
            &call.arguments,
            delta,
            self.limits.tool_arguments_bytes,
        );
    }

    fn finishToolCall(self: *Turn, id: []const u8) Error!void {
        const index = self.findPendingCallIndex(id) orelse return;
        try self.reserveItems(1);
        const arguments = try self.allocator.dupe(u8, self.pending_calls.items[index].arguments.items);
        errdefer self.allocator.free(arguments);

        var call = self.pending_calls.orderedRemove(index);
        call.arguments.deinit(self.allocator);
        self.items.appendAssumeCapacity(.{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments_json = arguments,
        } });
    }

    fn findPendingCall(self: *Turn, id: []const u8) ?*PendingToolCall {
        const index = self.findPendingCallIndex(id) orelse return null;
        return &self.pending_calls.items[index];
    }

    fn findPendingCallIndex(self: *const Turn, id: []const u8) ?usize {
        for (self.pending_calls.items, 0..) |call, index| {
            if (std.mem.eql(u8, call.id, id)) return index;
        }
        return null;
    }
};

fn appendBounded(
    allocator: std.mem.Allocator,
    comptime too_large: Error,
    list: *std.ArrayList(u8),
    bytes: []const u8,
    maximum: usize,
) Error!void {
    if (bytes.len > maximum -| list.items.len) return too_large;
    try list.appendSlice(allocator, bytes);
}

fn deinitItems(allocator: std.mem.Allocator, items: []Item) void {
    ai.Item.deinitSlice(allocator, items);
}

test "turn preserves interleaved reasoning text and assistant text order" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "thinking" });
    try turn.consume(.{ .text_delta = "answer" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("thinking", items[0].reasoning.text.?);
    try std.testing.expectEqualStrings("answer", items[1].assistant_message.text);
}

test "opaque reasoning seals preceding reasoning text into one item" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "visible" });
    try turn.consume(.{ .reasoning_item = .{ .opaque_json = "{\"id\":1}" } });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("visible", items[0].reasoning.text.?);
    try std.testing.expectEqualStrings("{\"id\":1}", items[0].reasoning.opaque_json.?);
}

test "turn assembles interleaved tool calls by id" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .tool_call_start = .{ .id = "one", .name = "read" } });
    try turn.consume(.{ .tool_call_start = .{ .id = "two", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "two", .arguments_delta = "{\"command\":" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "one", .arguments_delta = "{\"path\":\"a\"}" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "two", .arguments_delta = "\"pwd\"}" } });
    try turn.consume(.{ .tool_call_end = "one" });
    try turn.consume(.{ .tool_call_end = "two" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("one", items[0].tool_call.id);
    try std.testing.expectEqualStrings("{\"path\":\"a\"}", items[0].tool_call.arguments_json);
    try std.testing.expectEqualStrings("two", items[1].tool_call.id);
    try std.testing.expectEqualStrings("{\"command\":\"pwd\"}", items[1].tool_call.arguments_json);
}

test "retry clears partial attempt and terminal events ignore later input" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "discard" });
    try turn.consume(.{ .retry = .{ .attempt = 1, .maximum_attempts = 2, .delay_ms = 10 } });
    try turn.consume(.{ .text_delta = "keep" });
    try turn.consume(.{ .done = .{} });
    try turn.consume(.{ .text_delta = "ignored" });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("keep", items[0].assistant_message.text);
}

test "failed turn keeps visible text only when repaired" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "visible" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "{}" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .reasoning_delta = "truncated" });
    try turn.consume(.{ .failure = .{ .message = "connection lost" } });
    try turn.flushText(" [interrupted]");
    turn.keepText();

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("visible", items[0].assistant_message.text);
}

test "failed buffered text accepts an interruption marker" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "partial" });
    try turn.consume(.{ .failure = .{ .message = "connection lost" } });
    try turn.flushText(" [interrupted]");

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqualStrings("partial [interrupted]", items[0].assistant_message.text);
}

test "turn enforces byte and item bounds" {
    var turn = Turn.init(std.testing.allocator, .{ .text_bytes = 3, .items = 1 });
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "abc" });
    try std.testing.expectError(error.TextTooLarge, turn.consume(.{ .text_delta = "d" }));
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try std.testing.expectError(
        error.TooManyItems,
        turn.consume(.{ .reasoning_item = .{ .opaque_json = "{}" } }),
    );
}

test "empty done stream is terminal and has no items" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .done = .{} });
    try std.testing.expectEqual(State.done, turn.state);
    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), items.len);
}

test "text tool and trailing text preserve semantic block order" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "Running... " });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "{" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "}" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .text_delta = "Done." });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqualStrings("Running... ", items[0].assistant_message.text);
    try std.testing.expectEqualStrings("{}", items[1].tool_call.arguments_json);
    try std.testing.expectEqualStrings("Done.", items[2].assistant_message.text);
}

test "unknown and duplicate tool events are ignored" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "other", .arguments_delta = "ignored" } });
    try turn.consume(.{ .tool_call_end = "missing" });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqual(@as(usize, 0), items[0].tool_call.arguments_json.len);
}

test "empty reasoning activity creates no history item" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = null });
    try turn.consume(.{ .reasoning_delta = "" });
    try turn.consume(.{ .reasoning_item = .{ .opaque_json = "{}" } });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expect(items[0].reasoning.text == null);
}

test "discard reasoning drops only the open reasoning buffer" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "sealed" });
    try turn.consume(.{ .text_delta = "text" });
    try turn.consume(.{ .reasoning_delta = "open" });
    turn.discardReasoning();
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("sealed", items[0].reasoning.text.?);
    try std.testing.expectEqualStrings("text", items[1].assistant_message.text);
}

test "failure preserves buffered text and ignores every later event" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "partial" });
    try turn.consume(.{ .failure = .{ .message = "failed" } });
    try turn.consume(.{ .done = .{} });
    try turn.consume(.{ .text_delta = "ignored" });
    try std.testing.expectEqual(State.failed, turn.state);
    try turn.flushText("\n[interrupted]");

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqualStrings("partial\n[interrupted]", items[0].assistant_message.text);
}

test "retry clears sealed items open buffers and pending calls" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "reasoning" });
    try turn.consume(.{ .text_delta = "text" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "partial" } });
    try turn.consume(.{ .retry = .{ .attempt = 1, .maximum_attempts = 2, .delay_ms = 1 } });
    try std.testing.expectEqual(State.streaming, turn.state);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), turn.pending_calls.items.len);
    try turn.consume(.{ .text_delta = "replacement" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("replacement", items[0].assistant_message.text);
}

test "turn bounds provider-owned identifiers and opaque reasoning" {
    var turn = Turn.init(std.testing.allocator, .{
        .tool_id_bytes = 2,
        .tool_name_bytes = 3,
        .reasoning_opaque_bytes = 2,
    });
    defer turn.deinit();

    try turn.consume(.{ .tool_call_start = .{ .id = "id", .name = "run" } });
    try std.testing.expectError(
        error.ToolIdTooLarge,
        turn.consume(.{ .tool_call_start = .{ .id = "long", .name = "run" } }),
    );
    try std.testing.expectError(
        error.ToolNameTooLarge,
        turn.consume(.{ .tool_call_start = .{ .id = "ok", .name = "long" } }),
    );
    try turn.consume(.{ .reasoning_item = .{ .opaque_json = "{}" } });
    try std.testing.expectError(
        error.ReasoningOpaqueTooLarge,
        turn.consume(.{ .reasoning_item = .{ .opaque_json = "123" } }),
    );
}

fn exerciseAllocationPaths(allocator: std.mem.Allocator) !void {
    var turn = Turn.init(allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "visible reasoning" });
    try turn.consume(.{ .reasoning_item = .{ .opaque_json = "{\"opaque\":true}" } });
    try turn.consume(.{ .text_delta = "assistant" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "{\"command\":\"pwd\"}" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .done = .{} });
    const items = try turn.takeItems();
    deinitItems(allocator, items);
    turn.reset();
}

test "turn allocation failures leave all owned state deinitializable" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationPaths,
        .{},
    );
}

test "reasoning seals before a tool call" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "why" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 2), items.len);
    try std.testing.expectEqualStrings("why", items[0].reasoning.text.?);
    try std.testing.expect(items[1] == .tool_call);
}

test "reasoning-only turn seals on done" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "only" });
    try turn.consume(.{ .done = .{} });

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("only", items[0].reasoning.text.?);
}

test "failure with an incomplete tool call preserves only sealed text" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "visible" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "partial" } });
    try turn.consume(.{ .failure = .{ .message = "failed" } });
    turn.keepText();

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("visible", items[0].assistant_message.text);
}

test "keep text preserves an open assistant buffer" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "drop" });
    try turn.consume(.{ .text_delta = "open" });
    turn.keepText();
    try turn.flushText(null);

    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 1), items.len);
    try std.testing.expectEqualStrings("open", items[0].assistant_message.text);
}

test "taking items clears vector ownership and reset remains safe" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .text_delta = "owned" });
    try turn.consume(.{ .done = .{} });
    const items = try turn.takeItems();
    defer deinitItems(std.testing.allocator, items);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
    turn.reset();
    try std.testing.expectEqual(State.streaming, turn.state);
}

test "reset before done frees every kind of partial state" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .reasoning_delta = "open reasoning" });
    try turn.consume(.{ .text_delta = "text" });
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "bash" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "partial" } });
    turn.reset();

    try std.testing.expectEqual(State.streaming, turn.state);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), turn.pending_calls.items.len);
    try std.testing.expect(!turn.has_text);
    try std.testing.expect(!turn.has_reasoning);
}

test "tool-call end OOM preserves pending call for retry" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var turn = Turn.init(failing.allocator(), .{});
    defer turn.deinit();
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_delta = .{ .id = "call", .arguments_delta = "{}" } });
    try turn.items.ensureUnusedCapacity(failing.allocator(), 1);
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, turn.consume(.{ .tool_call_end = "call" }));
    try std.testing.expectEqual(@as(usize, 1), turn.pending_calls.items.len);
    try std.testing.expectEqualStrings("{}", turn.pending_calls.items[0].arguments.items);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);

    failing.fail_index = std.math.maxInt(usize);
    try turn.consume(.{ .tool_call_end = "call" });
    try std.testing.expectEqual(@as(usize, 0), turn.pending_calls.items.len);
    try std.testing.expectEqualStrings("{}", turn.items.items[0].tool_call.arguments_json);
}

test "flush-text OOM does not append or duplicate the suffix" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var turn = Turn.init(failing.allocator(), .{});
    defer turn.deinit();
    try turn.consume(.{ .text_delta = "partial" });
    try turn.items.ensureUnusedCapacity(failing.allocator(), 1);
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, turn.flushText("\n[interrupted]"));
    try std.testing.expect(turn.has_text);
    try std.testing.expectEqualStrings("partial", turn.text.items);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);

    failing.fail_index = std.math.maxInt(usize);
    try turn.flushText("\n[interrupted]");
    try std.testing.expectEqualStrings(
        "partial\n[interrupted]",
        turn.items.items[0].assistant_message.text,
    );
}

test "tool-call start is logically atomic at every allocation" {
    var offset: usize = 0;
    while (offset < 8) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var turn = Turn.init(failing.allocator(), .{});
        defer turn.deinit();
        try turn.consume(.{ .text_delta = "text" });
        try turn.consume(.{ .reasoning_delta = "reasoning" });
        failing.fail_index = failing.alloc_index + offset;

        if (turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } })) |_| {
            try std.testing.expectEqual(@as(usize, 2), turn.items.items.len);
            try std.testing.expectEqual(@as(usize, 1), turn.pending_calls.items.len);
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
            try std.testing.expectEqual(@as(usize, 0), turn.pending_calls.items.len);
            try std.testing.expect(turn.has_text);
            try std.testing.expect(turn.has_reasoning);
            try std.testing.expectEqualStrings("text", turn.text.items);
            try std.testing.expectEqualStrings("reasoning", turn.reasoning.items);
        }
    } else return error.TestUnexpectedResult;
}

test "reasoning item is logically atomic at every allocation" {
    var offset: usize = 0;
    while (offset < 6) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var turn = Turn.init(failing.allocator(), .{});
        defer turn.deinit();
        try turn.consume(.{ .text_delta = "text" });
        try turn.consume(.{ .reasoning_delta = "reasoning" });
        failing.fail_index = failing.alloc_index + offset;

        if (turn.consume(.{ .reasoning_item = .{ .opaque_json = "{}" } })) |_| {
            try std.testing.expectEqual(@as(usize, 2), turn.items.items.len);
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
            try std.testing.expect(turn.has_text);
            try std.testing.expect(turn.has_reasoning);
            try std.testing.expectEqualStrings("text", turn.text.items);
            try std.testing.expectEqualStrings("reasoning", turn.reasoning.items);
        }
    } else return error.TestUnexpectedResult;
}

test "done is logically atomic at every allocation" {
    var offset: usize = 0;
    while (offset < 5) : (offset += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
        var turn = Turn.init(failing.allocator(), .{});
        defer turn.deinit();
        try turn.consume(.{ .text_delta = "text" });
        try turn.consume(.{ .reasoning_delta = "reasoning" });
        failing.fail_index = failing.alloc_index + offset;

        if (turn.consume(.{ .done = .{} })) |_| {
            try std.testing.expectEqual(State.done, turn.state);
            try std.testing.expectEqual(@as(usize, 2), turn.items.items.len);
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(State.streaming, turn.state);
            try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
            try std.testing.expect(turn.has_text);
            try std.testing.expect(turn.has_reasoning);
        }
    } else return error.TestUnexpectedResult;
}

test "turn accumulates retries but terminal attempt owns last context" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .retry = .{
        .attempt = 1,
        .maximum_attempts = 3,
        .delay_ms = 1,
        .usage = .{ .input_tokens = 40, .cost_usd = 0.2 },
    } });
    try turn.consume(.{ .retry = .{
        .attempt = 2,
        .maximum_attempts = 3,
        .delay_ms = 1,
        .usage = .{ .input_tokens = 50, .output_tokens = 4, .cost_usd = 0.3 },
    } });
    try turn.consume(.{ .done = .{ .usage = .{
        .input_tokens = 100,
        .output_tokens = 20,
        .cost_usd = 0.5,
    } } });

    try std.testing.expectEqual(@as(?u64, 120), turn.last_context_tokens);
    try std.testing.expectEqual(@as(?u64, 100), turn.usage.input_tokens);
    const total = turn.totalUsage();
    try std.testing.expectEqual(@as(?u64, 190), total.input_tokens);
    try std.testing.expectEqual(@as(?u64, 24), total.output_tokens);
    try std.testing.expectEqual(@as(?f64, 1.0), total.cost_usd);
}

test "unpriced retry invalidates terminal exact cost" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .retry = .{
        .attempt = 1,
        .maximum_attempts = 2,
        .delay_ms = 1,
        .usage = .{ .input_tokens = 40 },
    } });
    try turn.consume(.{ .done = .{ .usage = .{
        .input_tokens = 100,
        .output_tokens = 20,
        .cost_usd = 0.5,
    } } });

    try std.testing.expect(turn.totalUsage().cost_usd == null);
    try std.testing.expectEqual(@as(?u64, 120), turn.last_context_tokens);
}

test "terminal failure usage sets context without counting retries in it" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .retry = .{
        .attempt = 1,
        .maximum_attempts = 2,
        .delay_ms = 1,
        .usage = .{ .input_tokens = 40, .output_tokens = 1 },
    } });
    try turn.consume(.{ .failure = .{
        .message = "failed",
        .usage = .{ .input_tokens = 100, .output_tokens = 20 },
    } });

    try std.testing.expectEqual(State.failed, turn.state);
    try std.testing.expectEqual(@as(?u64, 120), turn.last_context_tokens);
    const total = turn.totalUsage();
    try std.testing.expectEqual(@as(?u64, 140), total.input_tokens);
    try std.testing.expectEqual(@as(?u64, 21), total.output_tokens);
}

test "last context requires both terminal counters and reset clears accounting" {
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();

    try turn.consume(.{ .retry = .{
        .attempt = 1,
        .maximum_attempts = 2,
        .delay_ms = 1,
        .usage = .{ .input_tokens = 40, .output_tokens = 2 },
    } });
    try turn.consume(.{ .done = .{ .usage = .{ .input_tokens = 100 } } });
    try std.testing.expect(turn.last_context_tokens == null);
    try std.testing.expectEqual(@as(?u64, 140), turn.totalUsage().input_tokens);

    turn.reset();
    try std.testing.expect(!ai.Usage.usageReported(turn.totalUsage()));
    try std.testing.expect(turn.last_context_tokens == null);
}
