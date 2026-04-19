const std = @import("std");
const agent = @import("../../agent3/root.zig");
const ai = @import("../../ai/root.zig");
const coding_agent = @import("../root.zig");
const context_mod = @import("../../session/context.zig");
const context_usage = @import("../../session/context_usage.zig");
const proto = @import("../../session/protocol.zig");
const session_runner = @import("../session_runner.zig");

const AgentSession = coding_agent.AgentSession;
const AgentMessage = agent.protocol.AgentMessage;
const CompactionPolicy = session_runner.CompactionPolicy;
const CompactionReason = session_runner.CompactionReason;
const CompactionExecutor = session_runner.CompactionExecutor;
const CompactionResult = session_runner.CompactionResult;

const summarization_system_prompt =
    "You are summarizing conversation history for another coding agent. Be precise, terse, and preserve exact file paths, function names, constraints, errors, and next steps.";

const summarization_prompt =
    "Summarize the conversation below for a coding agent that will continue the work.\n\n" ++
    "Use this exact structure:\n\n" ++
    "## Goal\n" ++
    "[what the user is trying to accomplish]\n\n" ++
    "## Constraints & Preferences\n" ++
    "- [constraints, preferences, or requirements]\n\n" ++
    "## Progress\n" ++
    "### Done\n" ++
    "- [completed work]\n\n" ++
    "### In Progress\n" ++
    "- [current work]\n\n" ++
    "### Blocked\n" ++
    "- [blockers or none]\n\n" ++
    "## Key Decisions\n" ++
    "- [decision and rationale]\n\n" ++
    "## Next Steps\n" ++
    "1. [next actions]\n\n" ++
    "## Critical Context\n" ++
    "- [important concrete details]\n\n" ++
    "Keep it concise. Preserve exact file paths, function names, and error messages.";

pub fn createExecutor() CompactionExecutor {
    return .{
        .func = &execute,
    };
}

fn execute(session: *AgentSession, reason: CompactionReason, policy: CompactionPolicy, ctx: ?*anyopaque) anyerror!CompactionResult {
    _ = reason;
    _ = ctx;

    var arena = std.heap.ArenaAllocator.init(session.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = try session.session_store.readEntries();
    const prep = try prepareCompaction(allocator, entries, .current, policy);

    const prompt_text = try buildPrompt(allocator, prep.messages_to_summarize, prep.previous_summary);
    const max_tokens = @max(@divTrunc(policy.reserve_tokens * 4, 5), 1024);
    const summary = try session.completeUserText(session.allocator, summarization_system_prompt, prompt_text, max_tokens);

    const new_context = try session.session_store.applyCompaction(summary, prep.first_kept_entry_id, prep.tokens_before);
    try session.agent.setMessages(new_context.messages);
    session.noteCompactionApplied();
    session.agent.clearError();

    return .{
        .summary = summary,
        .first_kept_entry_id = prep.first_kept_entry_id,
        .tokens_before = prep.tokens_before,
    };
}

const Preparation = struct {
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    previous_summary: ?[]const u8,
    messages_to_summarize: []const AgentMessage,
};

fn prepareCompaction(
    allocator: std.mem.Allocator,
    entries: []const proto.SessionEntry,
    selection: context_mod.LeafSelection,
    policy: CompactionPolicy,
) !Preparation {
    const path = try context_mod.buildBranchEntries(allocator, entries, selection);
    if (path.len == 0) return error.NothingToCompact;
    if (path[path.len - 1].entry == .compaction) return error.AlreadyCompacted;

    const current_context = try context_mod.buildSessionContext(allocator, entries, selection);
    const tokens_before = context_usage.estimateContextTokens(current_context.messages).tokens;

    var boundary_start: usize = 0;
    var previous_summary: ?[]const u8 = null;
    var i: usize = path.len;
    while (i > 0) {
        i -= 1;
        if (path[i].entry == .compaction) {
            previous_summary = path[i].entry.compaction.summary;
            boundary_start = findEntryIndexById(path, path[i].entry.compaction.first_kept_entry_id) orelse (i + 1);
            break;
        }
    }

    const cut_index = findCutPoint(path, boundary_start, policy.keep_recent_tokens);
    if (cut_index <= boundary_start) return error.NothingToCompact;

    var messages = std.ArrayList(AgentMessage).empty;
    for (path[boundary_start..cut_index]) |entry| {
        if (extractMessage(entry)) |msg| try messages.append(allocator, msg);
    }
    if (messages.items.len == 0) return error.NothingToCompact;

    return .{
        .first_kept_entry_id = path[cut_index].id,
        .tokens_before = tokens_before,
        .previous_summary = previous_summary,
        .messages_to_summarize = messages.items,
    };
}

fn findEntryIndexById(entries: []const proto.SessionEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.id, id)) return idx;
    }
    return null;
}

fn findCutPoint(entries: []const proto.SessionEntry, start_index: usize, keep_recent_tokens: u64) usize {
    var accumulated: u64 = 0;
    var cut_index = start_index;
    var i: usize = entries.len;
    while (i > start_index) {
        i -= 1;
        if (extractMessage(entries[i])) |msg| {
            accumulated += context_usage.estimateTokens(msg);
            if (accumulated >= keep_recent_tokens) {
                cut_index = findNextValidCut(entries, i, start_index) orelse start_index;
                break;
            }
        }
    }
    return cut_index;
}

fn findNextValidCut(entries: []const proto.SessionEntry, candidate_index: usize, start_index: usize) ?usize {
    var i = candidate_index;
    while (i < entries.len) : (i += 1) {
        if (i < start_index) continue;
        if (isValidCutEntry(entries[i])) return i;
    }
    return null;
}

fn isValidCutEntry(entry: proto.SessionEntry) bool {
    switch (entry.entry) {
        .message => |m| return switch (m.message) {
            .user, .custom => true,
            else => false,
        },
        .branch_summary, .custom_message => return true,
        else => return false,
    }
}

fn buildPrompt(allocator: std.mem.Allocator, messages: []const AgentMessage, previous_summary: ?[]const u8) ![]u8 {
    const conversation = try serializeConversation(allocator, messages);
    if (previous_summary) |prev| {
        return std.fmt.allocPrint(
            allocator,
            "<conversation>\n{s}\n</conversation>\n\n<previous-summary>\n{s}\n</previous-summary>\n\n{s}",
            .{ conversation, prev, summarization_prompt },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "<conversation>\n{s}\n</conversation>\n\n{s}",
        .{ conversation, summarization_prompt },
    );
}

fn serializeConversation(allocator: std.mem.Allocator, messages: []const AgentMessage) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    for (messages) |msg| {
        switch (msg) {
            .user => |u| {
                try out.appendSlice(allocator, "[user]\n");
                switch (u.content) {
                    .text => |t| try out.appendSlice(allocator, t),
                    .blocks => |blocks| for (blocks) |block| switch (block) {
                        .text => |t| try out.appendSlice(allocator, t.text),
                        else => {},
                    },
                }
                try out.appendSlice(allocator, "\n\n");
            },
            .assistant => |a| {
                try out.appendSlice(allocator, "[assistant]\n");
                for (a.content) |block| switch (block) {
                    .text => |t| try out.appendSlice(allocator, t.text),
                    .thinking => |t| try out.appendSlice(allocator, t.thinking),
                    .tool_call => |tc| {
                        try out.writer(allocator).print("tool {s} ", .{tc.name});
                    },
                };
                if (a.error_message) |err| {
                    try out.appendSlice(allocator, "\nerror: ");
                    try out.appendSlice(allocator, err);
                }
                try out.appendSlice(allocator, "\n\n");
            },
            .tool_result => |tr| {
                try out.writer(allocator).print("[tool_result:{s}]\n", .{tr.tool_name});
                for (tr.content) |block| switch (block) {
                    .text => |t| try out.appendSlice(allocator, t.text),
                    else => {},
                };
                try out.appendSlice(allocator, "\n\n");
            },
            .compaction_summary => |cs| {
                try out.appendSlice(allocator, "[compaction_summary]\n");
                try out.appendSlice(allocator, cs.summary);
                try out.appendSlice(allocator, "\n\n");
            },
            .branch_summary => |bs| {
                try out.appendSlice(allocator, "[branch_summary]\n");
                try out.appendSlice(allocator, bs.summary);
                try out.appendSlice(allocator, "\n\n");
            },
            .custom => |cm| {
                try out.writer(allocator).print("[custom:{s}]\n", .{cm.custom_type});
                switch (cm.content) {
                    .text => |t| try out.appendSlice(allocator, t),
                    .blocks => |blocks| for (blocks) |block| switch (block) {
                        .text => |t| try out.appendSlice(allocator, t.text),
                        else => {},
                    },
                }
                try out.appendSlice(allocator, "\n\n");
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn extractMessage(entry: proto.SessionEntry) ?AgentMessage {
    switch (entry.entry) {
        .message => |m| return m.message,
        .branch_summary => |bs| {
            if (bs.summary.len == 0) return null;
            return .{ .branch_summary = .{
                .summary = bs.summary,
                .from_id = bs.from_id,
                .timestamp = 0,
            } };
        },
        .custom_message => |cm| return .{ .custom = .{
            .custom_type = cm.custom_type,
            .content = cm.content,
            .display = cm.display,
            .details = cm.details,
            .timestamp = 0,
        } },
        else => return null,
    }
}

const testing = std.testing;

fn testUserEntry(id: []const u8, parent_id: ?[]const u8, text: []const u8) proto.SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .message = .{ .message = .{
            .user = .{ .content = .{ .text = text }, .timestamp = 1 },
        } } },
    };
}

fn testAssistantEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    text: []const u8,
) !proto.SessionEntry {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .message = .{ .message = .{
            .assistant = .{
                .content = content,
                .api = .openai_responses,
                .provider = .openai,
                .model = "gpt-test",
                .usage = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total_tokens = 0,
                    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                },
                .stop_reason = .stop,
                .timestamp = 1,
            },
        } } },
    };
}

test "prepareCompaction stops at user boundaries even when an assistant-heavy tail blocks a smaller cut" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]proto.SessionEntry{
        testUserEntry("u1", null, "first prompt"),
        try testAssistantEntry(allocator, "a1", "u1", "first answer"),
        testUserEntry("u2", "a1", "second prompt"),
        try testAssistantEntry(allocator, "a2", "u2", "this assistant tail is intentionally long enough to exceed the keep recent token budget by itself"),
    };

    try testing.expectError(error.NothingToCompact, prepareCompaction(allocator, &entries, .{ .entry_id = "a2" }, .{
        .keep_recent_tokens = 8,
    }));
}
