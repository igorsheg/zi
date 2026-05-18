const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_message = @import("../agent/message.zig");
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

pub const InFlightUsageInput = struct {
    assistant: ?ai.protocol.AssistantMessage = null,
    tool_results: []const ai.protocol.ToolResultMessage = &.{},
};

pub fn calculateContextTokens(usage: ai.protocol.Usage) u64 {
    return if (usage.total_tokens != 0)
        usage.total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
}

pub fn estimateContextTokens(messages: []const agent_message.AgentMessage) ContextUsageEstimate {
    var estimator = ContextUsageEstimator{};
    for (messages) |message| estimator.observe(message);
    return estimator.finish();
}

pub fn estimateContextTokensWithInFlight(
    committed: []const agent_message.AgentMessage,
    in_flight: InFlightUsageInput,
) ContextUsageEstimate {
    var estimator = ContextUsageEstimator{};
    for (committed) |message| estimator.observe(message);
    if (in_flight.assistant) |assistant| {
        estimator.observe(.{ .assistant = assistant });
    }
    for (in_flight.tool_results) |tool_result| {
        estimator.observe(.{ .tool_result = tool_result });
    }
    return estimator.finish();
}

const ContextUsageEstimator = struct {
    index: usize = 0,
    pre_usage_tokens: u64 = 0,
    usage_tokens: u64 = 0,
    trailing_tokens: u64 = 0,
    last_usage_index: ?usize = null,

    fn observe(self: *ContextUsageEstimator, message: agent_message.AgentMessage) void {
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

pub fn estimateTokens(message: agent_message.AgentMessage) u64 {
    var chars: usize = 0;

    switch (message) {
        .user => |u| switch (u.content) {
            .text => |t| chars += t.len,
            .blocks => |blocks| {
                for (blocks) |block| chars += estimateUserContentBlock(block);
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
            .blocks => |blocks| {
                for (blocks) |block| chars += estimateUserContentBlock(block);
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

fn estimateUserContentBlock(block: ai.protocol.UserMessage.UserMessageContent.Block) usize {
    return switch (block) {
        .text => |t| t.text.len,
        .image => 4800,
    };
}

fn getAssistantUsage(message: agent_message.AgentMessage) ?ai.protocol.Usage {
    switch (message) {
        .assistant => |assistant| switch (assistant.stop_reason) {
            .aborted, .@"error" => return null,
            else => return assistant.usage,
        },
        else => return null,
    }
}

fn estimateJsonSize(value: std.json.Value) usize {
    return switch (value) {
        .null => 4,
        .bool => |b| if (b) 4 else 5,
        .integer => |i| countPrint("{d}", .{i}),
        .float => |f| countPrint("{d}", .{f}),
        .number_string => |s| s.len,
        .string => |s| estimateJsonStringSize(s),
        .array => |arr| estimateJsonArraySize(arr),
        .object => |obj| estimateJsonObjectSize(obj),
    };
}

fn estimateJsonArraySize(arr: std.json.Array) usize {
    var size: usize = 2;
    for (arr.items, 0..) |item, i| {
        if (i > 0) size += 1;
        size += estimateJsonSize(item);
    }
    return size;
}

fn estimateJsonObjectSize(obj: std.json.ObjectMap) usize {
    var size: usize = 2;
    var i: usize = 0;
    var it = obj.iterator();
    while (it.next()) |entry| : (i += 1) {
        if (i > 0) size += 1;
        size += estimateJsonStringSize(entry.key_ptr.*);
        size += 1;
        size += estimateJsonSize(entry.value_ptr.*);
    }
    return size;
}

fn estimateJsonStringSize(s: []const u8) usize {
    var size: usize = 2;
    for (s) |c| {
        size += switch (c) {
            '"', '\\' => 2,
            0x00...0x1f => 6,
            else => 1,
        };
    }
    return size;
}

fn countPrint(comptime fmt: []const u8, args: anytype) usize {
    var buf: [128]u8 = undefined;
    return (std.fmt.bufPrint(&buf, fmt, args) catch return buf.len).len;
}

const testing = std.testing;

test "estimateContextTokensWithInFlight uses assistant message-end usage before turn commit" {
    const committed = [_]agent_message.AgentMessage{.{ .user = .{
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
    const tool_result = agent_message.ToolResultMessage{
        .tool_call_id = "tool-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "abcdefgh" } }},
        .is_error = false,
        .timestamp = 3,
    };

    const estimate = estimateContextTokensWithInFlight(&committed, .{ .assistant = assistant, .tool_results = &.{tool_result} });

    try testing.expectEqual(@as(u64, 122), estimate.tokens);
    try testing.expectEqual(@as(u64, 120), estimate.usage_tokens);
    try testing.expectEqual(@as(u64, 2), estimate.trailing_tokens);
    try testing.expectEqual(@as(?usize, 1), estimate.last_usage_index);
}

test "estimateTokens counts serialized tool call arguments" {
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
    const message = agent_message.AgentMessage{
        .assistant = faux.fauxAssistantMessage(testing.allocator, &content, .stop),
    };
    defer testing.allocator.free(message.assistant.content);

    try testing.expectEqual(@as(u64, 11), estimateTokens(message));
}
