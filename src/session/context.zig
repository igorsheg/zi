const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const context_usage = @import("context_usage.zig");

pub const SessionContext = struct {
    messages: []agent.protocol.AgentMessage,
    thinking_level: []const u8,
    model: ?ModelInfo,

    pub const ModelInfo = struct {
        provider: []const u8,
        model_id: []const u8,
    };
};

pub const LeafSelection = union(enum) {
    current,
    before_first,
    entry_id: []const u8,
};

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
    selection: LeafSelection,
) ![]const proto.SessionEntry {
    var by_id = std.StringHashMap(usize).init(allocator);
    defer by_id.deinit();
    for (entries, 0..) |*entry, idx| {
        try by_id.put(entry.id, idx);
    }

    const idx = resolveLeafIndex(entries, &by_id, selection) orelse return &.{};

    var path: std.ArrayList(proto.SessionEntry) = .empty;
    errdefer path.deinit(allocator);
    var current: ?usize = idx;
    while (current) |cur| {
        try path.append(allocator, entries[cur]);
        current = if (entries[cur].parent_id) |pid| by_id.get(pid) else null;
    }

    std.mem.reverse(proto.SessionEntry, path.items);
    return try path.toOwnedSlice(allocator);
}

pub fn buildSessionContext(
    allocator: std.mem.Allocator,
    entries: []const proto.SessionEntry,
    selection: LeafSelection,
) !SessionContext {
    const path = try buildBranchEntries(allocator, entries, selection);

    if (path.len == 0) {
        return .{ .messages = &.{}, .thinking_level = "off", .model = null };
    }

    var thinking_level: []const u8 = "off";
    var model: ?SessionContext.ModelInfo = null;
    var compaction_path_pos: ?usize = null;
    var compaction_data: ?proto.CompactionEntry = null;

    for (path, 0..) |entry, path_pos| {
        switch (entry.entry) {
            .thinking_level_change => |t| thinking_level = t.thinking_level,
            .model_change => |m| model = .{ .provider = m.provider, .model_id = m.model_id },
            .message => |msg| {
                switch (msg.message) {
                    .assistant => |a| model = .{ .provider = ai.json_util.providerToString(a.provider), .model_id = a.model },
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

    var messages: std.ArrayListUnmanaged(agent.protocol.AgentMessage) = .empty;

    if (compaction_data) |cd| {
        try messages.append(allocator, .{ .compaction_summary = .{
            .summary = cd.summary,
            .tokens_before = cd.tokens_before,
            .timestamp = isoToEpochMs(path[compaction_path_pos.?].timestamp),
        } });

        const compaction_pos = compaction_path_pos.?;

        var found_first_kept = false;
        for (path[0..compaction_pos]) |entry| {
            if (std.mem.eql(u8, entry.id, cd.first_kept_entry_id)) {
                found_first_kept = true;
            }
            if (found_first_kept) {
                if (extractMessage(&entry)) |msg| try messages.append(allocator, msg);
            }
        }

        if (compaction_pos + 1 < path.len) {
            for (path[compaction_pos + 1 ..]) |entry| {
                if (extractMessage(&entry)) |msg| try messages.append(allocator, msg);
            }
        }
    } else {
        for (path) |entry| {
            if (extractMessage(&entry)) |msg| try messages.append(allocator, msg);
        }
    }

    return .{
        .messages = messages.items,
        .thinking_level = thinking_level,
        .model = model,
    };
}

fn resolveLeafIndex(
    entries: []const proto.SessionEntry,
    by_id: *const std.StringHashMap(usize),
    selection: LeafSelection,
) ?usize {
    return switch (selection) {
        .current => if (entries.len > 0) entries.len - 1 else null,
        .before_first => null,
        .entry_id => |entry_id| by_id.get(entry_id) orelse if (entries.len > 0) entries.len - 1 else null,
    };
}

fn extractMessage(entry: *const proto.SessionEntry) ?agent.protocol.AgentMessage {
    switch (entry.entry) {
        .message => |m| return m.message,
        .custom_message => |cm| {
            if (!cm.include_in_context) return null;
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

fn isoToEpochMs(timestamp: []const u8) i64 {
    const secs = parseIsoToEpochSeconds(timestamp) orelse return 0;
    return secs * 1000;
}

const ParsedIsoTimestamp = struct {
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
};

fn parseIsoToEpochSeconds(timestamp: []const u8) ?i64 {
    const parts = parseIsoTimestamp(timestamp) orelse return null;
    const m_idx: usize = @intCast(parts.month - 1);
    const max_day = daysInMonth(parts.year, parts.month);
    if (parts.day < 1 or parts.day > max_day) return null;

    const y = parts.year - 1;
    const era_days = y * 365 + @divFloor(y, 4) - @divFloor(y, 100) + @divFloor(y, 400);
    const month_days = [_]i64{ 0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334 };
    var days = era_days + month_days[m_idx] + parts.day;
    if (parts.month > 2 and isLeapYear(parts.year)) days += 1;

    const unix_days = days - 719163;
    return unix_days * 86400 + parts.hour * 3600 + parts.minute * 60 + parts.second;
}

fn parseIsoTimestamp(timestamp: []const u8) ?ParsedIsoTimestamp {
    if (timestamp.len < 19) return null;
    if (timestamp[4] != '-' or timestamp[7] != '-' or timestamp[10] != 'T' or timestamp[13] != ':' or timestamp[16] != ':') return null;

    const year = std.fmt.parseInt(i64, timestamp[0..4], 10) catch return null;
    const month = std.fmt.parseInt(i64, timestamp[5..7], 10) catch return null;
    const day = std.fmt.parseInt(i64, timestamp[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(i64, timestamp[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(i64, timestamp[14..16], 10) catch return null;
    const second = std.fmt.parseInt(i64, timestamp[17..19], 10) catch return null;

    if (month < 1 or month > 12) return null;
    if (hour < 0 or hour > 23) return null;
    if (minute < 0 or minute > 59) return null;
    if (second < 0 or second > 59) return null;

    return .{ .year = year, .month = month, .day = day, .hour = hour, .minute = minute, .second = second };
}

fn isLeapYear(year: i64) bool {
    return (@mod(year, 4) == 0 and @mod(year, 100) != 0) or @mod(year, 400) == 0;
}

fn daysInMonth(year: i64, month: i64) i64 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn testMsg(allocator: std.mem.Allocator, id: []const u8, parent_id: ?[]const u8, role: enum { user, assistant }, text: []const u8) proto.SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{
            .message = .{
                .message = switch (role) {
                    .user => .{ .user = .{ .content = .{ .text = text }, .timestamp = 1 } },
                    .assistant => blk: {
                        const content = allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1) catch unreachable;
                        content[0] = .{ .text = .{ .text = text } };
                        break :blk .{ .assistant = .{
                            .content = content,
                            .api = .anthropic_messages,
                            .provider = .anthropic,
                            .model = "claude-test",
                            .usage = .{
                                .input = 1,
                                .output = 1,
                                .cache_read = 0,
                                .cache_write = 0,
                                .total_tokens = 2,
                                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                            },
                            .stop_reason = .stop,
                            .timestamp = 1,
                        } };
                    },
                },
            },
        },
    };
}

fn testCompaction(id: []const u8, parent_id: ?[]const u8, summary: []const u8, first_kept: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{ .compaction = .{
        .summary = summary,
        .first_kept_entry_id = first_kept,
        .tokens_before = 1000,
    } } };
}

fn testBranchSummary(id: []const u8, parent_id: ?[]const u8, summary: []const u8, from_id: []const u8) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{ .branch_summary = .{
        .summary = summary,
        .from_id = from_id,
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

fn testCustomMessage(id: []const u8, parent_id: ?[]const u8, text: []const u8, include_in_context: bool) proto.SessionEntry {
    return .{ .id = id, .parent_id = parent_id, .timestamp = "2025-01-01T00:00:00Z", .entry = .{
        .custom_message = .{
            .custom_type = "test.custom",
            .content = .{ .text = text },
            .display = true,
            .include_in_context = include_in_context,
        },
    } };
}

fn getUserText(msg: agent.protocol.AgentMessage) ?[]const u8 {
    switch (msg) {
        .user => |u| return switch (u.content) {
            .text => |t| t,
            .blocks => null,
        },
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

fn expectDefaultContext(ctx: SessionContext) !void {
    try std.testing.expectEqual(@as(usize, 0), ctx.messages.len);
    try std.testing.expectEqualStrings("off", ctx.thinking_level);
    try std.testing.expect(ctx.model == null);
}

fn expectUserTextAt(ctx: SessionContext, index: usize, expected: []const u8) !void {
    try std.testing.expect(index < ctx.messages.len);
    const actual = getUserText(ctx.messages[index]) orelse return error.ExpectedUserMessage;
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectAssistantTextAt(ctx: SessionContext, index: usize, expected: []const u8) !void {
    try std.testing.expect(index < ctx.messages.len);
    const actual = getAssistantText(ctx.messages[index]) orelse return error.ExpectedAssistantMessage;
    try std.testing.expectEqualStrings(expected, actual);
}

fn expectCompactionSummaryAt(ctx: SessionContext, index: usize, expected_summary: []const u8, expected_tokens: u64) !void {
    try std.testing.expect(index < ctx.messages.len);
    switch (ctx.messages[index]) {
        .compaction_summary => |cs| {
            try std.testing.expectEqualStrings(expected_summary, cs.summary);
            try std.testing.expectEqual(expected_tokens, cs.tokens_before);
        },
        else => return error.ExpectedCompactionSummary,
    }
}

fn expectBranchSummaryAt(ctx: SessionContext, index: usize, expected_summary: []const u8) !void {
    try std.testing.expect(index < ctx.messages.len);
    switch (ctx.messages[index]) {
        .branch_summary => |bs| try std.testing.expectEqualStrings(expected_summary, bs.summary),
        else => return error.ExpectedBranchSummary,
    }
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

test "empty and before_first selections produce default context" {
    var arena = testArena();
    defer arena.deinit();

    var empty_entries = [_]proto.SessionEntry{};
    const empty_ctx = try buildSessionContext(arena.allocator(), &empty_entries, .current);
    try expectDefaultContext(empty_ctx);

    var entries = [_]proto.SessionEntry{testMsg(arena.allocator(), "1", null, .user, "hello")};
    const before_first_ctx = try buildSessionContext(arena.allocator(), &entries, .before_first);
    try expectDefaultContext(before_first_ctx);
}

test "conversation context preserves path order and selected leaf" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "1", .assistant, "hi there"),
        testMsg(arena.allocator(), "3", "2", .user, "branch A"),
        testMsg(arena.allocator(), "4", "2", .user, "branch B"),
    };

    const current_ctx = try buildSessionContext(arena.allocator(), &entries, .current);
    try std.testing.expectEqual(@as(usize, 3), current_ctx.messages.len);
    try expectUserTextAt(current_ctx, 0, "hello");
    try expectAssistantTextAt(current_ctx, 1, "hi there");
    try expectUserTextAt(current_ctx, 2, "branch B");

    const branch_a_ctx = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "3" });
    try std.testing.expectEqual(@as(usize, 3), branch_a_ctx.messages.len);
    try expectUserTextAt(branch_a_ctx, 2, "branch A");
}

test "tracks user-visible thinking level and model state" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testThinkingLevel("2", "1", "high"),
        testModelChange("3", "2", "openai", "gpt-4"),
        testMsg(arena.allocator(), "4", "3", .assistant, "hi"),
    };

    const ctx = try buildSessionContext(arena.allocator(), &entries, .current);
    try std.testing.expectEqualStrings("high", ctx.thinking_level);
    try std.testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try std.testing.expectEqualStrings("anthropic", ctx.model.?.provider);
    try std.testing.expectEqualStrings("claude-test", ctx.model.?.model_id);
}

test "compaction emits latest summary, kept messages, and later messages" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "first"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response1"),
        testCompaction("3", "2", "First summary", "1"),
        testMsg(arena.allocator(), "4", "3", .user, "second"),
        testMsg(arena.allocator(), "5", "4", .assistant, "response2"),
        testCompaction("6", "5", "Second summary", "4"),
        testMsg(arena.allocator(), "7", "6", .user, "third"),
        testMsg(arena.allocator(), "8", "7", .assistant, "response3"),
    };

    const ctx = try buildSessionContext(arena.allocator(), &entries, .current);
    try std.testing.expectEqual(@as(usize, 5), ctx.messages.len);
    try expectCompactionSummaryAt(ctx, 0, "Second summary", 1000);
    try expectUserTextAt(ctx, 1, "second");
    try expectAssistantTextAt(ctx, 2, "response2");
    try expectUserTextAt(ctx, 3, "third");
    try expectAssistantTextAt(ctx, 4, "response3");
}

test "compaction preserves kept pre-compaction assistant usage like pi-mono" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "first"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response1"),
        testMsg(arena.allocator(), "3", "2", .user, "second"),
        testMsg(arena.allocator(), "4", "3", .assistant, "response2"),
        testCompaction("5", "4", "summary", "3"),
        testMsg(arena.allocator(), "6", "5", .user, "third"),
    };
    entries[3].entry.message.message.assistant.usage.total_tokens = 195_000;

    const ctx = try buildSessionContext(arena.allocator(), &entries, .current);
    try std.testing.expectEqual(@as(usize, 4), ctx.messages.len);
    try std.testing.expectEqual(@as(u64, 195_000), ctx.messages[2].assistant.usage.total_tokens);

    const estimate = context_usage.estimateContextTokens(ctx.messages);
    try std.testing.expect(estimate.tokens >= 195_000);
}

test "branch summary appears only on selected branch" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "start"),
        testMsg(arena.allocator(), "2", "1", .assistant, "response"),
        testMsg(arena.allocator(), "3", "2", .user, "abandoned path"),
        testBranchSummary("4", "2", "Summary of abandoned work", "3"),
        testMsg(arena.allocator(), "5", "4", .user, "new direction"),
        testMsg(arena.allocator(), "6", "2", .user, "other branch"),
    };

    const summary_branch = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "5" });
    try std.testing.expectEqual(@as(usize, 4), summary_branch.messages.len);
    try expectBranchSummaryAt(summary_branch, 2, "Summary of abandoned work");
    try expectUserTextAt(summary_branch, 3, "new direction");

    const other_branch = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "6" });
    try std.testing.expectEqual(@as(usize, 3), other_branch.messages.len);
    try expectUserTextAt(other_branch, 2, "other branch");
}

test "complex branch selection combines compaction and branch summaries" {
    var arena = testArena();
    defer arena.deinit();
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

    const ctx_main = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "7" });
    try std.testing.expectEqual(@as(usize, 5), ctx_main.messages.len);
    try expectCompactionSummaryAt(ctx_main, 0, "Compacted history", 1000);
    try expectUserTextAt(ctx_main, 1, "q2");
    try expectAssistantTextAt(ctx_main, 2, "r2");
    try expectUserTextAt(ctx_main, 3, "q3");
    try expectAssistantTextAt(ctx_main, 4, "r3");

    const ctx_branch = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "11" });
    try std.testing.expectEqual(@as(usize, 5), ctx_branch.messages.len);
    try expectUserTextAt(ctx_branch, 0, "start");
    try expectAssistantTextAt(ctx_branch, 1, "r1");
    try expectUserTextAt(ctx_branch, 2, "q2");
    try expectBranchSummaryAt(ctx_branch, 3, "Tried wrong approach");
    try expectUserTextAt(ctx_branch, 4, "better approach");
}

test "unknown leaf falls back to current context" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testMsg(arena.allocator(), "2", "1", .assistant, "hi"),
    };

    const ctx = try buildSessionContext(arena.allocator(), &entries, .{ .entry_id = "nonexistent" });
    try std.testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try expectUserTextAt(ctx, 0, "hello");
    try expectAssistantTextAt(ctx, 1, "hi");
}

test "custom messages only enter context when included" {
    var arena = testArena();
    defer arena.deinit();
    var entries = [_]proto.SessionEntry{
        testMsg(arena.allocator(), "1", null, .user, "hello"),
        testCustomMessage("2", "1", "hidden", false),
        testCustomMessage("3", "2", "visible", true),
    };

    const ctx = try buildSessionContext(arena.allocator(), &entries, .current);
    try std.testing.expectEqual(@as(usize, 2), ctx.messages.len);
    try expectUserTextAt(ctx, 0, "hello");
    try std.testing.expect(ctx.messages[1] == .custom);
    try std.testing.expectEqualStrings("visible", ctx.messages[1].custom.content.text);
}
