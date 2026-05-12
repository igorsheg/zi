const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const faux = ai.faux;

pub const ContextUsage = struct {
    tokens: ?u64,
    context_window: u64,

    percent: ?f64,
};

pub const ContextUsageEstimate = struct {
    tokens: u64,
    usage_tokens: u64,
    trailing_tokens: u64,
    last_usage_index: ?usize,
};

pub fn calculateContextTokens(usage: ai.protocol.Usage) u64 {
    return if (usage.total_tokens != 0)
        usage.total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
}

pub fn estimateContextTokens(messages: []const agent.protocol.AgentMessage) ContextUsageEstimate {
    var estimator = ContextUsageEstimator{};
    for (messages) |message| estimator.observe(message);
    return estimator.finish();
}

pub fn estimateContextTokensWithInFlight(
    committed: []const agent.protocol.AgentMessage,
    in_flight: *const agent.conversation_state.InFlightState,
) ContextUsageEstimate {
    var estimator = ContextUsageEstimator{};
    for (committed) |message| estimator.observe(message);
    if (in_flight.assistant) |assistant| {
        estimator.observe(.{ .assistant = assistant });
    }
    for (in_flight.tool_executions.items) |execution| {
        if (execution.result_message) |tool_result| {
            estimator.observe(.{ .tool_result = tool_result });
        }
    }
    return estimator.finish();
}

const ContextUsageEstimator = struct {
    index: usize = 0,
    pre_usage_tokens: u64 = 0,
    usage_tokens: u64 = 0,
    trailing_tokens: u64 = 0,
    last_usage_index: ?usize = null,

    fn observe(self: *ContextUsageEstimator, message: agent.protocol.AgentMessage) void {
        if (getAssistantUsage(message)) |usage| {
            self.usage_tokens = calculateContextTokens(usage);
            self.trailing_tokens = 0;
            self.last_usage_index = self.index;
        } else if (self.last_usage_index == null) {
            self.pre_usage_tokens += estimateTokens(message);
        } else {
            self.trailing_tokens += estimateTokens(message);
        }
        self.index += 1;
    }

    fn finish(self: ContextUsageEstimator) ContextUsageEstimate {
        if (self.last_usage_index == null) {
            return .{
                .tokens = self.pre_usage_tokens,
                .usage_tokens = 0,
                .trailing_tokens = self.pre_usage_tokens,
                .last_usage_index = null,
            };
        }
        return .{
            .tokens = self.usage_tokens + self.trailing_tokens,
            .usage_tokens = self.usage_tokens,
            .trailing_tokens = self.trailing_tokens,
            .last_usage_index = self.last_usage_index,
        };
    }
};

pub fn estimateTokens(message: agent.protocol.AgentMessage) u64 {
    var chars: usize = 0;

    switch (message) {
        .user => |u| switch (u.content) {
            .text => |t| chars += t.len,
            .blocks => |blocks| for (blocks) |block| switch (block) {
                .text => |t| chars += t.text.len,
                else => {},
            },
        },
        .assistant => |a| {
            for (a.content) |block| switch (block) {
                .text => |t| chars += t.text.len,
                .thinking => |t| chars += t.thinking.len,
                .tool_call => |tc| chars += tc.name.len + estimateJsonSize(tc.arguments),
            };
        },
        .custom => |c| switch (c.content) {
            .text => |t| chars += t.len,
            .blocks => |blocks| for (blocks) |block| switch (block) {
                .text => |t| chars += t.text.len,
                .image => chars += 4800,
            },
        },
        .tool_result => |tr| {
            for (tr.content) |block| switch (block) {
                .text => |t| chars += t.text.len,
                .image => chars += 4800,
            };
        },
        .branch_summary => |bs| chars += bs.summary.len,
        .compaction_summary => |cs| chars += cs.summary.len,
    }

    return @intCast(@divTrunc(chars + 3, 4));
}

fn getAssistantUsage(message: agent.protocol.AgentMessage) ?ai.protocol.Usage {
    switch (message) {
        .assistant => |assistant| switch (assistant.stop_reason) {
            .aborted, .@"error" => return null,
            else => return assistant.usage,
        },
        else => return null,
    }
}

fn estimateJsonSize(value: std.json.Value) usize {
    var out: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    jw.write(value) catch return 0;
    return out.written().len;
}

const testing = std.testing;

test "estimateContextTokensWithInFlight uses assistant message-end usage before turn commit" {
    var in_flight = agent.conversation_state.InFlightState.init(testing.allocator);
    defer in_flight.deinit();

    const committed = [_]agent.protocol.AgentMessage{.{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } }};
    const assistant = ai.protocol.AssistantMessage{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{
            .input = 100,
            .output = 20,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 2,
    };
    const tool_result = agent.protocol.ToolResultMessage{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "abcdefgh" } }},
        .is_error = false,
        .timestamp = 3,
    };

    _ = in_flight.applyEvent(.{ .message_end = .{ .message = .{ .assistant = assistant } } });
    _ = in_flight.applyEvent(.{ .message_end = .{ .message = .{ .tool_result = tool_result } } });

    const estimate = estimateContextTokensWithInFlight(&committed, &in_flight);

    try testing.expectEqual(@as(u64, 122), estimate.tokens);
    try testing.expectEqual(@as(u64, 120), estimate.usage_tokens);
    try testing.expectEqual(@as(u64, 2), estimate.trailing_tokens);
    try testing.expectEqual(@as(?usize, 1), estimate.last_usage_index);
}

test "estimateTokens counts tool call arguments using stringified json size" {
    const parsed = try std.json.parseFromSlice(
        std.json.Value,
        testing.allocator,
        "{\"path\":\"a\\nb\",\"items\":[1,true,null]}",
        .{ .allocate = .alloc_always },
    );
    defer parsed.deinit();

    const content = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        faux.fauxToolCall("read", "tc-1", parsed.value),
    };
    const message = agent.protocol.AgentMessage{
        .assistant = faux.fauxAssistantMessage(testing.allocator, &content, .stop),
    };
    defer testing.allocator.free(message.assistant.content);

    try testing.expectEqual(@as(u64, 11), estimateTokens(message));
}
