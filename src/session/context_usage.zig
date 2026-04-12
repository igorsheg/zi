const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const faux = ai.faux;

pub const ContextUsage = struct {
    /// Estimated context tokens, or null when unknown immediately after
    /// compaction and before the first post-compaction assistant usage.
    tokens: ?u64,
    context_window: u64,
    /// Percent of the model context window consumed. Null when `tokens`
    /// is unknown.
    percent: ?f64,
};

pub const ContextUsageEstimate = struct {
    tokens: u64,
    usage_tokens: u64,
    trailing_tokens: u64,
    last_usage_index: ?usize,
};

/// pi-mono source:
/// packages/coding-agent/src/core/compaction/compaction.ts:135-137
pub fn calculateContextTokens(usage: ai.protocol.Usage) u64 {
    return if (usage.total_tokens != 0)
        usage.total_tokens
    else
        usage.input + usage.output + usage.cache_read + usage.cache_write;
}

/// pi-mono source:
/// packages/coding-agent/src/core/compaction/compaction.ts:186-214
pub fn estimateContextTokens(messages: []const agent.protocol.AgentMessage) ContextUsageEstimate {
    const usage_info = getLastAssistantUsageInfo(messages);

    if (usage_info == null) {
        var estimated: u64 = 0;
        for (messages) |message| {
            estimated += estimateTokens(message);
        }
        return .{
            .tokens = estimated,
            .usage_tokens = 0,
            .trailing_tokens = estimated,
            .last_usage_index = null,
        };
    }

    const info = usage_info.?;
    const usage_tokens = calculateContextTokens(info.usage);
    var trailing_tokens: u64 = 0;
    for (messages[info.index + 1 ..]) |message| {
        trailing_tokens += estimateTokens(message);
    }

    return .{
        .tokens = usage_tokens + trailing_tokens,
        .usage_tokens = usage_tokens,
        .trailing_tokens = trailing_tokens,
        .last_usage_index = info.index,
    };
}

/// pi-mono source:
/// packages/coding-agent/src/core/compaction/compaction.ts:232-290
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

pub fn getLatestCompactionEntry(entries: []const proto.SessionEntry) ?proto.CompactionEntry {
    var i: usize = entries.len;
    while (i > 0) {
        i -= 1;
        switch (entries[i].entry) {
            .compaction => |c| return c,
            else => {},
        }
    }
    return null;
}

pub fn buildBranchEntries(
    allocator: std.mem.Allocator,
    entries: []const proto.SessionEntry,
    leaf_id: ?[]const u8,
) ![]const proto.SessionEntry {
    var by_id = std.StringHashMap(usize).init(allocator);
    defer by_id.deinit();
    for (entries, 0..) |*entry, idx| {
        try by_id.put(entry.id, idx);
    }

    var leaf_idx: ?usize = null;
    if (leaf_id) |lid| leaf_idx = by_id.get(lid);
    if (leaf_idx == null and entries.len > 0) leaf_idx = entries.len - 1;
    const idx = leaf_idx orelse return &.{};

    var rev: std.ArrayList(proto.SessionEntry) = .empty;
    defer rev.deinit(allocator);
    var current: ?usize = idx;
    while (current) |cur| {
        try rev.append(allocator, entries[cur]);
        current = if (entries[cur].parent_id) |pid| by_id.get(pid) else null;
    }

    const out = try allocator.alloc(proto.SessionEntry, rev.items.len);
    var src_i = rev.items.len;
    var dst_i: usize = 0;
    while (src_i > 0) {
        src_i -= 1;
        out[dst_i] = rev.items[src_i];
        dst_i += 1;
    }
    return out;
}

fn getLastAssistantUsageInfo(messages: []const agent.protocol.AgentMessage) ?struct { usage: ai.protocol.Usage, index: usize } {
    var i: usize = messages.len;
    while (i > 0) {
        i -= 1;
        if (getAssistantUsage(messages[i])) |usage| {
            return .{ .usage = usage, .index = i };
        }
    }
    return null;
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
    var out: std.io.Writer.Allocating = .init(std.heap.page_allocator);
    defer out.deinit();

    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    jw.write(value) catch return 0;
    return out.written().len;
}

const testing = std.testing;

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

    try testing.expectEqual(@as(u64, 10), estimateTokens(message));
}
