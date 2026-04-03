const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");

/// Result of building session context from entries.
pub const SessionContext = struct {
    messages: []agent.protocol.AgentMessage,
    thinking_level: []const u8,
    model: ?ModelInfo,

    pub const ModelInfo = struct {
        provider: []const u8,
        model_id: []const u8,
    };
};

/// Build the session context from entries using tree traversal.
/// Walks from leaf to root, collecting the path, then processes entries in order.
/// Handles compaction entries along the path.
///
/// pi-mono source: packages/coding-agent/src/core/session-manager.ts:310-417
pub fn buildSessionContext(
    allocator: std.mem.Allocator,
    entries: []const proto.SessionEntry,
    leaf_id: ?[]const u8,
) !SessionContext {
    var by_id = std.StringHashMap(usize).init(allocator);
    defer by_id.deinit();
    for (entries, 0..) |*entry, i| {
        try by_id.put(entry.id, i);
    }

    // Find leaf index
    var leaf_idx: ?usize = null;
    if (leaf_id) |lid| {
        leaf_idx = by_id.get(lid);
    }
    if (leaf_idx == null and entries.len > 0) {
        leaf_idx = entries.len - 1;
    }

    if (leaf_idx == null) {
        return .{ .messages = &.{}, .thinking_level = "off", .model = null };
    }

    // Walk from leaf to root, collecting path indices
    var path_indices: std.ArrayListUnmanaged(usize) = .empty;
    defer path_indices.deinit(allocator);
    var current_idx: ?usize = leaf_idx;
    while (current_idx) |idx| {
        try path_indices.insert(allocator, 0, idx);
        current_idx = if (entries[idx].parent_id) |pid| by_id.get(pid) else null;
    }

    // Extract settings and find compaction
    var thinking_level: []const u8 = "off";
    var model: ?SessionContext.ModelInfo = null;
    var compaction_path_pos: ?usize = null;
    var compaction_data: ?proto.CompactionEntry = null;

    for (path_indices.items, 0..) |idx, path_pos| {
        const entry = &entries[idx];
        switch (entry.entry) {
            .thinking_level_change => |t| thinking_level = t.thinking_level,
            .model_change => |m| model = .{ .provider = m.provider, .model_id = m.model_id },
            .message => |msg| {
                switch (msg.message) {
                    .assistant => |a| model = .{ .provider = providerToString(a.provider), .model_id = a.model },
                    else => {},
                }
            },
            .compaction => |c| {
                compaction_path_pos = path_pos;
                compaction_data = c;
            },
            else => {},
        }
    }

    // Build messages
    var messages: std.ArrayListUnmanaged(agent.protocol.AgentMessage) = .empty;

    if (compaction_data) |cd| {
        // pi-mono: createCompactionSummaryMessage (messages.ts:109-119)
        try messages.append(allocator, .{ .compaction_summary = .{
            .summary = cd.summary,
            .tokens_before = cd.tokens_before,
            .timestamp = isoToEpochMs(entries[path_indices.items[compaction_path_pos.?]].timestamp),
        } });

        const compaction_pos = compaction_path_pos.?;

        // Emit kept messages (before compaction, starting from firstKeptEntryId)
        var found_first_kept = false;
        for (path_indices.items[0..compaction_pos]) |idx| {
            if (std.mem.eql(u8, entries[idx].id, cd.first_kept_entry_id)) {
                found_first_kept = true;
            }
            if (found_first_kept) {
                if (extractMessage(&entries[idx])) |msg| try messages.append(allocator, msg);
            }
        }

        // Emit messages after compaction
        if (compaction_pos + 1 < path_indices.items.len) {
            for (path_indices.items[compaction_pos + 1 ..]) |idx| {
                if (extractMessage(&entries[idx])) |msg| try messages.append(allocator, msg);
            }
        }
    } else {
        for (path_indices.items) |idx| {
            if (extractMessage(&entries[idx])) |msg| try messages.append(allocator, msg);
        }
    }

    return .{
        .messages = messages.items,
        .thinking_level = thinking_level,
        .model = model,
    };
}

/// Extract an AgentMessage from a session entry, if applicable.
/// pi-mono source: session-manager.ts:373-383 (appendMessage in buildSessionContext)
fn extractMessage(entry: *const proto.SessionEntry) ?agent.protocol.AgentMessage {
    switch (entry.entry) {
        .message => |m| return m.message,
        .custom_message => |cm| {
            // pi-mono: createCustomMessage (messages.ts:122-137)
            return .{ .custom = .{
                .custom_type = cm.custom_type,
                .content = cm.content,
                .display = cm.display,
                .details = cm.details,
                .timestamp = isoToEpochMs(entry.timestamp),
            } };
        },
        .branch_summary => |bs| {
            if (bs.summary.len > 0) {
                // pi-mono: createBranchSummaryMessage (messages.ts:100-107)
                return .{ .branch_summary = .{
                    .summary = bs.summary,
                    .from_id = bs.from_id,
                    .timestamp = isoToEpochMs(entry.timestamp),
                } };
            }
            return null;
        },
        else => return null,
    }
}

// ─── Test helpers (ported from pi-mono build-context.test.ts) ────────

fn testMsg(allocator: std.mem.Allocator, id: []const u8, parent_id: ?[]const u8, role: enum { user, assistant }, text: []const u8) proto.SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .message = .{ .message = switch (role) {
            .user => .{ .user = .{ .content = .{ .text = text }, .timestamp = 1 } },
            .assistant => blk: {
                // Allocate content block on the arena
                const content = allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
                content[0] = .{ .text = .{ .text = text } };
                break :blk .{ .assistant = .{
                    .content = content,
                    .api = .anthropic_messages,
                    .provider = .anthropic,
                    .model = "claude-test",
                    .usage = .{
                        .input = 1, .output = 1, .cache_read = 0, .cache_write = 0, .total_tokens = 2,
                        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                    },
                    .stop_reason = .stop,
                    .timestamp = 1,
                } };
            },
        } } },
    };
}

fn testCompaction(id: []const u8, parent_id: ?[]const u8, summary: []const u8, first_kept: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{ .compaction = .{
        .summary = summary, .first_kept_entry_id = first_kept, .tokens_before = 1000,
    } } };
}

fn testBranchSummary(id: []const u8, parent_id: ?[]const u8, summary: []const u8, from_id: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{ .branch_summary = .{
        .summary = summary, .from_id = from_id,
    } } };
}

fn testThinkingLevel(id: []const u8, parent_id: ?[]const u8, level: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{
        .thinking_level_change = .{ .thinking_level = level },
    } };
}

fn testModelChange(id: []const u8, parent_id: ?[]const u8, provider: []const u8, model_id: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{
        .model_change = .{ .provider = provider, .model_id = model_id },
    } };
}

fn getUserText(msg: agent.protocol.AgentMessage) ?[]const u8 {
    switch (msg) {
        .user => |u| return switch (u.content) { .text => |t| t, .blocks => null },
        else => return null,
    }
}

fn getAssistantText(msg: agent.protocol.AgentMessage) ?[]const u8 {
    switch (msg) {
        .assistant => |a| {
            if (a.content.len > 0) {
                switch (a.content[0]) {
                    .text => |tc| return tc.text,
                    else => return null,
                }
            }
            return null;
        },
        else => return null,
    }
}

// ─── Conformance tests ported from pi-mono build-context.test.ts ────

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "empty entries returns empty context" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{};
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    try std.testing.expectEqual(@as(usize, 0), ctx.messages.len);
    try std.testing.expectEqualStrings("off", ctx.thinking_level);
    try std.testing.expect(ctx.model == null);
}

test "single user message" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{testMsg(arena.allocator(), "1", null, .user, "hello")};
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    try std.testing.expectEqual(@as(usize, 1), ctx.messages.len);
    try std.testing.expectEqualStrings("hello", getUserText(ctx.messages[0]).?);
}

test "simple conversation preserves order" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "1", .assistant, "hi there"),
        testMsg(arena.allocator(), "3", "2", .user, "how are you"),
        testMsg(arena.allocator(), "4", "3", .assistant, "great"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    try std.testing.expectEqual(@as(usize, 4), ctx.messages.len);
    try std.testing.expectEqualStrings("hello", getUserText(ctx.messages[0]).?);
    
    try std.testing.expectEqualStrings("hi there", getAssistantText(ctx.messages[1]).?);
    try std.testing.expectEqualStrings("how are you", getUserText(ctx.messages[2]).?);
    try std.testing.expectEqualStrings("great", getAssistantText(ctx.messages[3]).?);
}

test "tracks thinking level changes" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testThinkingLevel("2", "1", "high"),
        testMsg(arena.allocator(), "3", "2", .assistant, "thinking hard"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    try std.testing.expectEqualStrings("high", ctx.thinking_level);
    try std.testing.expectEqual(@as(usize, 2), ctx.messages.len);
}

test "tracks model from assistant message" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "1", .assistant, "hi"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    try std.testing.expectEqualStrings("anthropic", ctx.model.?.provider);
    try std.testing.expectEqualStrings("claude-test", ctx.model.?.model_id);
}

test "assistant message overwrites model_change entry" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testModelChange("2", "1", "openai", "gpt-4"),
        testMsg(arena.allocator(), "3", "2", .assistant, "hi"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    // assistant message overwrites the model_change
    try std.testing.expectEqualStrings("anthropic", ctx.model.?.provider);
    try std.testing.expectEqualStrings("claude-test", ctx.model.?.model_id);
}

test "compaction: summary + kept + after" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "first"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response1"),
        testMsg(arena.allocator(), "3", "2", .user, "second"),
        testMsg(arena.allocator(), "4", "3", .assistant, "response2"),
        testCompaction("5", "4", "Summary of first two turns", "3"),
        testMsg(arena.allocator(), "6", "5", .user, "third"),
        testMsg(arena.allocator(), "7", "6", .assistant, "response3"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    // summary + kept(3,4) + after(6,7) = 5
    try std.testing.expectEqual(@as(usize, 5), ctx.messages.len);
    // first message is compaction summary
    switch (ctx.messages[0]) {
        .compaction_summary => |cs| try std.testing.expect(std.mem.indexOf(u8, cs.summary, "Summary of first two turns") != null),
        else => return error.ExpectedCompactionSummary,
    }
    try std.testing.expectEqualStrings("second", getUserText(ctx.messages[1]).?);
    try std.testing.expectEqualStrings("response2", getAssistantText(ctx.messages[2]).?);
    try std.testing.expectEqualStrings("third", getUserText(ctx.messages[3]).?);
    try std.testing.expectEqualStrings("response3", getAssistantText(ctx.messages[4]).?);
}

test "compaction: keeping from first message" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "first"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response"),
        testCompaction("3", "2", "Empty summary", "1"),
        testMsg(arena.allocator(), "4", "3", .user, "second"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    // summary + all messages(1,2,4)
    try std.testing.expectEqual(@as(usize, 4), ctx.messages.len);
    switch (ctx.messages[0]) {
        .compaction_summary => |cs| try std.testing.expect(std.mem.indexOf(u8, cs.summary, "Empty summary") != null),
        else => return error.ExpectedCompactionSummary,
    }
}

test "multiple compactions uses latest" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "a"),
        testMsg(arena.allocator(), "2", "1", .assistant, "b"),
        testCompaction("3", "2", "First summary", "1"),
        testMsg(arena.allocator(), "4", "3", .user, "c"),
        testMsg(arena.allocator(), "5", "4", .assistant, "d"),
        testCompaction("6", "5", "Second summary", "4"),
        testMsg(arena.allocator(), "7", "6", .user, "e"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, null);
    // second summary, keep from 4
    try std.testing.expectEqual(@as(usize, 4), ctx.messages.len);
    switch (ctx.messages[0]) {
        .compaction_summary => |cs| try std.testing.expect(std.mem.indexOf(u8, cs.summary, "Second summary") != null),
        else => return error.ExpectedCompactionSummary,
    }
}

test "branches: follows path to specified leaf" {
    var arena = testArena();
    defer arena.deinit();
    // Tree: 1 -> 2 -> 3 (branch A), 2 -> 4 (branch B)
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "start"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response"),
        testMsg(arena.allocator(), "3", "2", .user, "branch A"),
        testMsg(arena.allocator(), "4", "2", .user, "branch B"),
    };
    const ctx_a = try buildSessionContext(arena.allocator(), &entries, "3");
    try std.testing.expectEqual(@as(usize, 3), ctx_a.messages.len);
    try std.testing.expectEqualStrings("branch A", getUserText(ctx_a.messages[2]).?);

    const ctx_b = try buildSessionContext(arena.allocator(), &entries, "4");
    try std.testing.expectEqual(@as(usize, 3), ctx_b.messages.len);
    try std.testing.expectEqualStrings("branch B", getUserText(ctx_b.messages[2]).?);
}

test "branches: includes branch summary in path" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "start"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response"),
        testMsg(arena.allocator(), "3", "2", .user, "abandoned path"),
        testBranchSummary("4", "2", "Summary of abandoned work", "3"),
        testMsg(arena.allocator(), "5", "4", .user, "new direction"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, "5");
    try std.testing.expectEqual(@as(usize, 4), ctx.messages.len);
    switch (ctx.messages[2]) {
        .branch_summary => |bs| try std.testing.expect(std.mem.indexOf(u8, bs.summary, "Summary of abandoned work") != null),
        else => return error.ExpectedBranchSummary,
    }
    try std.testing.expectEqualStrings("new direction", getUserText(ctx.messages[3]).?);
}

test "branches: complex tree with compaction and branch summary" {
    var arena = testArena();
    defer arena.deinit();
    // Tree:
    //   1 -> 2 -> 3 -> 4 -> compaction(5) -> 6 -> 7 (main path)
    //              \-> 8 -> 9 (abandoned)
    //                    \-> branchSummary(10) -> 11 (resumed from 3)
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "start"),
        testMsg(arena.allocator(), "2", "1", .assistant, "r1"),
        testMsg(arena.allocator(), "3", "2", .user, "q2"),
        testMsg(arena.allocator(), "4", "3", .assistant, "r2"),
        testCompaction("5", "4", "Compacted history", "3"),
        testMsg(arena.allocator(), "6", "5", .user, "q3"),
        testMsg(arena.allocator(), "7", "6", .assistant, "r3"),
        testMsg(arena.allocator(), "8", "3", .user, "wrong path"),
        testMsg(arena.allocator(), "9", "8", .assistant, "wrong response"),
        testBranchSummary("10", "3", "Tried wrong approach", "9"),
        testMsg(arena.allocator(), "11", "10", .user, "better approach"),
    };

    // Main path to 7: summary + kept(3,4) + after(6,7)
    const ctx_main = try buildSessionContext(arena.allocator(), &entries, "7");
    try std.testing.expectEqual(@as(usize, 5), ctx_main.messages.len);
    switch (ctx_main.messages[0]) {
        .compaction_summary => |cs| try std.testing.expect(std.mem.indexOf(u8, cs.summary, "Compacted history") != null),
        else => return error.ExpectedCompactionSummary,
    }
    try std.testing.expectEqualStrings("q2", getUserText(ctx_main.messages[1]).?);
    try std.testing.expectEqualStrings("r2", getAssistantText(ctx_main.messages[2]).?);
    try std.testing.expectEqualStrings("q3", getUserText(ctx_main.messages[3]).?);
    try std.testing.expectEqualStrings("r3", getAssistantText(ctx_main.messages[4]).?);

    // Branch path to 11: 1,2,3 + branch_summary + 11
    const ctx_branch = try buildSessionContext(arena.allocator(), &entries, "11");
    try std.testing.expectEqual(@as(usize, 5), ctx_branch.messages.len);
    try std.testing.expectEqualStrings("start", getUserText(ctx_branch.messages[0]).?);
    try std.testing.expectEqualStrings("r1", getAssistantText(ctx_branch.messages[1]).?);
    try std.testing.expectEqualStrings("q2", getUserText(ctx_branch.messages[2]).?);
    switch (ctx_branch.messages[3]) {
        .branch_summary => |bs| try std.testing.expect(std.mem.indexOf(u8, bs.summary, "Tried wrong approach") != null),
        else => return error.ExpectedBranchSummary,
    }
    try std.testing.expectEqualStrings("better approach", getUserText(ctx_branch.messages[4]).?);
}

test "edge: uses last entry when leafId not found" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "1", .assistant, "hi"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, "nonexistent");
    try std.testing.expectEqual(@as(usize, 2), ctx.messages.len);
}

test "edge: orphaned entry produces partial path" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "missing", .assistant, "orphan"),
    };
    const ctx = try buildSessionContext(arena.allocator(), &entries, "2");
    try std.testing.expectEqual(@as(usize, 1), ctx.messages.len);
}

/// Convert provider union to string.
fn providerToString(p: ai.protocol.Provider) []const u8 {
    return switch (p) {
        .amazon_bedrock => "amazon-bedrock",
        .anthropic => "anthropic",
        .google => "google",
        .google_gemini_cli => "google-gemini-cli",
        .google_antigravity => "google-antigravity",
        .google_vertex => "google-vertex",
        .openai => "openai",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex => "openai-codex",
        .github_copilot => "github-copilot",
        .xai => "xai",
        .groq => "groq",
        .cerebras => "cerebras",
        .openrouter => "openrouter",
        .vercel_ai_gateway => "vercel-ai-gateway",
        .zai => "zai",
        .mistral => "mistral",
        .minimax => "minimax",
        .minimax_cn => "minimax-cn",
        .huggingface => "huggingface",
        .opencode => "opencode",
        .opencode_go => "opencode-go",
        .kimi_coding => "kimi-coding",
        .custom => |s| s,
    };
}

/// Parse an ISO 8601 timestamp ("YYYY-MM-DDTHH:MM:SS..." format) to epoch milliseconds.
/// Returns 0 on parse failure.
fn isoToEpochMs(timestamp: []const u8) i64 {
    if (timestamp.len < 19) return 0;
    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return 0;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return 0;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return 0;
    const hour = std.fmt.parseInt(i64, timestamp[11..13], 10) catch return 0;
    const min = std.fmt.parseInt(i64, timestamp[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(i64, timestamp[17..19], 10) catch return 0;

    // Days from complete years (year-1 because current year days added via month/day)
    const y = year - 1;
    const era_days = y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    // Cumulative days before each month (non-leap)
    const month_days = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    const m_idx: usize = @intCast(month - 1);
    if (m_idx >= 12) return 0;
    var days = era_days + month_days[m_idx] + day;
    // Leap year adjustment for months after February
    if (month > 2) {
        const is_leap = (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
        if (is_leap) days += 1;
    }
    // Unix epoch is Jan 1 1970 = day 719163 from year 0
    const unix_days = days - 719163;
    return (unix_days * 86400 + hour * 3600 + min * 60 + sec) * 1000;
}

test "isoToEpochMs parses standard ISO timestamps" {
    // 2025-01-01T00:00:00Z = 1735689600000ms
    try std.testing.expectEqual(@as(i64, 1735689600000), isoToEpochMs("2025-01-01T00:00:00Z"));
    // 1970-01-01T00:00:00Z = 0ms
    try std.testing.expectEqual(@as(i64, 0), isoToEpochMs("1970-01-01T00:00:00Z"));
    // 2024-02-29T12:30:45Z (leap day)
    try std.testing.expectEqual(@as(i64, 1709209845000), isoToEpochMs("2024-02-29T12:30:45Z"));
    // Too short
    try std.testing.expectEqual(@as(i64, 0), isoToEpochMs("2025"));
}
