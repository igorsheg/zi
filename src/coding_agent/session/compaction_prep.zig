//! Pure compaction domain logic.
//!
//! This module owns the cut-point + split-turn + file-op semantics of a
//! compaction. It does not mutate session state, publish events, read
//! credentials, or touch any mailbox. Session mutation and LLM I/O belong
//! to the executor (`compactor.zig`).
//!
//! pi-mono parity references:
//!  .references/pi-mono/packages/coding-agent/src/core/compaction/compaction.ts
//!  .references/pi-mono/packages/coding-agent/src/core/compaction/utils.ts
//!
//! Owned by slice zi-v3j.10.2.

const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const proto = @import("../../session/protocol.zig");
const context_mod = @import("../../session/context.zig");
const context_usage = @import("../../session/context_usage.zig");

const AgentMessage = agent.protocol.AgentMessage;
const SessionEntry = proto.SessionEntry;

pub const TOOL_RESULT_MAX_CHARS: usize = 2000;

pub const CompactionSettings = struct {
    enabled: bool = true,
    reserve_tokens: u64 = 16_384,
    keep_recent_tokens: u64 = 20_000,
};

pub const FileOperations = struct {
    read: std.StringHashMapUnmanaged(void) = .{},
    written: std.StringHashMapUnmanaged(void) = .{},
    edited: std.StringHashMapUnmanaged(void) = .{},

    pub fn deinit(self: *FileOperations, allocator: std.mem.Allocator) void {
        self.read.deinit(allocator);
        self.written.deinit(allocator);
        self.edited.deinit(allocator);
    }
};

/// pi-mono utils.ts: extractFileOpsFromMessage
pub fn extractFileOpsFromMessage(
    allocator: std.mem.Allocator,
    message: AgentMessage,
    file_ops: *FileOperations,
) !void {
    switch (message) {
        .assistant => |a| for (a.content) |block| switch (block) {
            .tool_call => |tc| {
                if (tc.arguments != .object) continue;
                const path_val = tc.arguments.object.get("path") orelse continue;
                if (path_val != .string) continue;
                const path = path_val.string;
                if (std.mem.eql(u8, tc.name, "read")) {
                    try file_ops.read.put(allocator, path, {});
                } else if (std.mem.eql(u8, tc.name, "write")) {
                    try file_ops.written.put(allocator, path, {});
                } else if (std.mem.eql(u8, tc.name, "edit")) {
                    try file_ops.edited.put(allocator, path, {});
                }
            },
            else => {},
        },
        else => {},
    }
}

pub const ComputedFileLists = struct {
    read_files: []const []const u8,
    modified_files: []const []const u8,
};

/// pi-mono utils.ts: computeFileLists
pub fn computeFileLists(
    allocator: std.mem.Allocator,
    file_ops: *const FileOperations,
) !ComputedFileLists {
    var modified_set: std.StringHashMapUnmanaged(void) = .{};
    defer modified_set.deinit(allocator);

    var it = file_ops.edited.iterator();
    while (it.next()) |e| try modified_set.put(allocator, e.key_ptr.*, {});
    it = file_ops.written.iterator();
    while (it.next()) |e| try modified_set.put(allocator, e.key_ptr.*, {});

    var modified_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var mi = modified_set.iterator();
    while (mi.next()) |e| try modified_list.append(allocator, e.key_ptr.*);

    var read_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var ri = file_ops.read.iterator();
    while (ri.next()) |e| {
        if (!modified_set.contains(e.key_ptr.*)) {
            try read_list.append(allocator, e.key_ptr.*);
        }
    }

    std.mem.sort([]const u8, read_list.items, {}, strLessThan);
    std.mem.sort([]const u8, modified_list.items, {}, strLessThan);

    return .{
        .read_files = try read_list.toOwnedSlice(allocator),
        .modified_files = try modified_list.toOwnedSlice(allocator),
    };
}

/// pi-mono utils.ts: formatFileOperations
pub fn formatFileOperations(
    allocator: std.mem.Allocator,
    read_files: []const []const u8,
    modified_files: []const []const u8,
) ![]u8 {
    if (read_files.len == 0 and modified_files.len == 0) {
        return try allocator.dupe(u8, "");
    }
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.appendSlice(allocator, "\n\n");
    if (read_files.len > 0) {
        try out.appendSlice(allocator, "<read-files>\n");
        for (read_files, 0..) |f, i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, f);
        }
        try out.appendSlice(allocator, "\n</read-files>");
    }
    if (modified_files.len > 0) {
        if (read_files.len > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, "<modified-files>\n");
        for (modified_files, 0..) |f, i| {
            if (i > 0) try out.append(allocator, '\n');
            try out.appendSlice(allocator, f);
        }
        try out.appendSlice(allocator, "\n</modified-files>");
    }
    return try out.toOwnedSlice(allocator);
}

fn strLessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub const CutPointResult = struct {
    first_kept_entry_index: usize,
    /// Index of the user-role entry that starts a split turn, or null when
    /// the cut falls cleanly at a user boundary.
    turn_start_index: ?usize,
    is_split_turn: bool,
};

fn isValidCutEntry(entry: SessionEntry) bool {
    return switch (entry.entry) {
        .message => |m| switch (m.message) {
            .user, .assistant, .custom, .branch_summary, .compaction_summary => true,
            .tool_result => false,
        },
        .branch_summary, .custom_message => true,
        else => false,
    };
}

/// Is this entry a valid *turn start* boundary for split-turn handling?
/// pi-mono findTurnStartIndex: user (or bashExecution, n/a here) messages,
/// plus branch_summary and custom_message entry types.
fn isTurnStartEntry(entry: SessionEntry) bool {
    return switch (entry.entry) {
        .message => |m| m.message == .user,
        .branch_summary, .custom_message => true,
        else => false,
    };
}

fn isUserRoleCut(entry: SessionEntry) bool {
    return switch (entry.entry) {
        .message => |m| m.message == .user,
        else => false,
    };
}

/// pi-mono compaction.ts: findTurnStartIndex
pub fn findTurnStartIndex(
    entries: []const SessionEntry,
    entry_index: usize,
    start_index: usize,
) ?usize {
    var i = entry_index + 1;
    while (i > start_index) {
        i -= 1;
        if (isTurnStartEntry(entries[i])) return i;
    }
    return null;
}

/// pi-mono compaction.ts: findCutPoint + findValidCutPoints
///
/// Walk backwards from newest in [start_index, end_index), accumulating
/// estimated message tokens. Once we meet `keep_recent_tokens`, snap to
/// the nearest valid cut at or after that entry. Then pull the cut back
/// over any non-message entries (settings changes, etc.) that belong with
/// the kept region.
pub fn findCutPoint(
    entries: []const SessionEntry,
    start_index: usize,
    end_index: usize,
    keep_recent_tokens: u64,
) CutPointResult {
    if (end_index <= start_index) {
        return .{ .first_kept_entry_index = start_index, .turn_start_index = null, .is_split_turn = false };
    }

    var cut_index: usize = start_index;
    var have_default = false;
    {
        var k = start_index;
        while (k < end_index) : (k += 1) {
            if (isValidCutEntry(entries[k])) {
                cut_index = k;
                have_default = true;
                break;
            }
        }
    }
    if (!have_default) {
        return .{ .first_kept_entry_index = start_index, .turn_start_index = null, .is_split_turn = false };
    }

    var accumulated: u64 = 0;
    var i = end_index;
    while (i > start_index) {
        i -= 1;
        const entry = entries[i];
        if (entry.entry != .message) continue;
        accumulated += context_usage.estimateTokens(entry.entry.message.message);
        if (accumulated >= keep_recent_tokens) {
            var c = i;
            while (c < end_index) : (c += 1) {
                if (isValidCutEntry(entries[c])) {
                    cut_index = c;
                    break;
                }
            }
            break;
        }
    }

    while (cut_index > start_index) {
        const prev = entries[cut_index - 1];
        if (prev.entry == .compaction) break;
        if (prev.entry == .message) break;
        cut_index -= 1;
    }

    const cut_entry = entries[cut_index];
    const at_user_boundary = isUserRoleCut(cut_entry);
    const turn_start: ?usize = if (at_user_boundary) null else findTurnStartIndex(entries, cut_index, start_index);

    return .{
        .first_kept_entry_index = cut_index,
        .turn_start_index = turn_start,
        .is_split_turn = !at_user_boundary and turn_start != null,
    };
}

pub const CompactionPreparation = struct {
    first_kept_entry_id: []const u8,
    messages_to_summarize: []const AgentMessage,
    turn_prefix_messages: []const AgentMessage,
    is_split_turn: bool,
    tokens_before: u64,
    previous_summary: ?[]const u8,
    file_ops: FileOperations,
    settings: CompactionSettings,
};

/// pi-mono compaction.ts: prepareCompaction
///
/// Returns null when there is nothing the domain layer can compact
/// (empty branch, already-compacted tail, or no messages to summarize).
/// The executor maps that into the appropriate lifecycle event.
pub fn prepareCompaction(
    allocator: std.mem.Allocator,
    path_entries: []const SessionEntry,
    settings: CompactionSettings,
) !?CompactionPreparation {
    if (path_entries.len == 0) return null;
    if (path_entries[path_entries.len - 1].entry == .compaction) return null;

    var prev_compaction_index: ?usize = null;
    var i: usize = path_entries.len;
    while (i > 0) {
        i -= 1;
        if (path_entries[i].entry == .compaction) {
            prev_compaction_index = i;
            break;
        }
    }

    var previous_summary: ?[]const u8 = null;
    var boundary_start: usize = 0;
    if (prev_compaction_index) |pci| {
        const prev_comp = path_entries[pci].entry.compaction;
        previous_summary = prev_comp.summary;
        boundary_start = findEntryIndexById(path_entries, prev_comp.first_kept_entry_id) orelse (pci + 1);
    }
    const boundary_end = path_entries.len;

    const ctx = try context_mod.buildSessionContext(allocator, path_entries, .current);
    const tokens_before = context_usage.estimateContextTokens(ctx.messages).tokens;

    const cut = findCutPoint(path_entries, boundary_start, boundary_end, settings.keep_recent_tokens);

    const first_kept_entry = path_entries[cut.first_kept_entry_index];
    if (first_kept_entry.id.len == 0) return null;
    const first_kept_entry_id = first_kept_entry.id;

    const history_end: usize = if (cut.is_split_turn) cut.turn_start_index.? else cut.first_kept_entry_index;

    var messages_to_summarize: std.ArrayListUnmanaged(AgentMessage) = .empty;
    if (history_end > boundary_start) {
        for (path_entries[boundary_start..history_end]) |entry| {
            if (messageFromEntryForCompaction(entry)) |msg| {
                try messages_to_summarize.append(allocator, msg);
            }
        }
    }

    var turn_prefix_messages: std.ArrayListUnmanaged(AgentMessage) = .empty;
    if (cut.is_split_turn) {
        const ts = cut.turn_start_index.?;
        for (path_entries[ts..cut.first_kept_entry_index]) |entry| {
            if (messageFromEntryForCompaction(entry)) |msg| {
                try turn_prefix_messages.append(allocator, msg);
            }
        }
    }

    var file_ops: FileOperations = .{};
    try collectCarriedFileOps(allocator, &file_ops, path_entries, prev_compaction_index);
    for (messages_to_summarize.items) |msg| try extractFileOpsFromMessage(allocator, msg, &file_ops);
    if (cut.is_split_turn) {
        for (turn_prefix_messages.items) |msg| try extractFileOpsFromMessage(allocator, msg, &file_ops);
    }

    return .{
        .first_kept_entry_id = first_kept_entry_id,
        .messages_to_summarize = messages_to_summarize.items,
        .turn_prefix_messages = turn_prefix_messages.items,
        .is_split_turn = cut.is_split_turn,
        .tokens_before = tokens_before,
        .previous_summary = previous_summary,
        .file_ops = file_ops,
        .settings = settings,
    };
}

fn findEntryIndexById(entries: []const SessionEntry, id: []const u8) ?usize {
    for (entries, 0..) |entry, idx| {
        if (std.mem.eql(u8, entry.id, id)) return idx;
    }
    return null;
}

fn messageFromEntryForCompaction(entry: SessionEntry) ?AgentMessage {
    return switch (entry.entry) {
        .message => |m| m.message,
        .branch_summary => |bs| if (bs.summary.len == 0) null else AgentMessage{ .branch_summary = .{
            .summary = bs.summary,
            .from_id = bs.from_id,
            .timestamp = 0,
        } },
        .custom_message => |cm| AgentMessage{ .custom = .{
            .custom_type = cm.custom_type,
            .content = cm.content,
            .display = cm.display,
            .details = cm.details,
            .timestamp = 0,
        } },
        else => null,
    };
}

fn collectCarriedFileOps(
    allocator: std.mem.Allocator,
    file_ops: *FileOperations,
    path_entries: []const SessionEntry,
    prev_compaction_index: ?usize,
) !void {
    const pci = prev_compaction_index orelse return;
    const prev = path_entries[pci].entry.compaction;
    if (prev.from_hook == true) return;
    const details = prev.details orelse return;
    if (details != .object) return;

    if (details.object.get("readFiles")) |rf| {
        if (rf == .array) for (rf.array.items) |v| {
            if (v == .string) try file_ops.read.put(allocator, v.string, {});
        };
    }
    if (details.object.get("modifiedFiles")) |mf| {
        if (mf == .array) for (mf.array.items) |v| {
            if (v == .string) try file_ops.edited.put(allocator, v.string, {});
        };
    }
}

/// pi-mono utils.ts: serializeConversation
///
/// Serializes conversation messages to a text block that cannot be mistaken
/// for a continuation turn. Tool results are truncated to
/// TOOL_RESULT_MAX_CHARS to keep the summarization request bounded.
pub fn serializeConversation(
    allocator: std.mem.Allocator,
    messages: []const AgentMessage,
) ![]u8 {
    var parts: std.ArrayListUnmanaged([]u8) = .empty;
    defer {
        for (parts.items) |p| allocator.free(p);
        parts.deinit(allocator);
    }

    for (messages) |msg| {
        switch (msg) {
            .user => |u| {
                const text = try renderUserContent(allocator, u.content);
                defer allocator.free(text);
                if (text.len == 0) continue;
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "[User]: {s}", .{text}));
            },
            .assistant => |a| try appendAssistantParts(allocator, &parts, a),
            .tool_result => |tr| {
                var collected: std.ArrayListUnmanaged(u8) = .empty;
                defer collected.deinit(allocator);
                for (tr.content) |block| switch (block) {
                    .text => |t| try collected.appendSlice(allocator, t.text),
                    .image => {},
                };
                if (collected.items.len == 0) continue;
                const truncated = try truncateForSummary(allocator, collected.items, TOOL_RESULT_MAX_CHARS);
                defer allocator.free(truncated);
                try parts.append(allocator, try std.fmt.allocPrint(allocator, "[Tool result]: {s}", .{truncated}));
            },
            .branch_summary => |bs| try parts.append(
                allocator,
                try std.fmt.allocPrint(allocator, "[Branch summary]: {s}", .{bs.summary}),
            ),
            .compaction_summary => |cs| try parts.append(
                allocator,
                try std.fmt.allocPrint(allocator, "[Compaction summary]: {s}", .{cs.summary}),
            ),
            .custom => |c| {
                const text = try renderUserContent(allocator, c.content);
                defer allocator.free(text);
                try parts.append(
                    allocator,
                    try std.fmt.allocPrint(allocator, "[Custom {s}]: {s}", .{ c.custom_type, text }),
                );
            },
        }
    }

    return try joinParts(allocator, parts.items, "\n\n");
}

fn appendAssistantParts(
    allocator: std.mem.Allocator,
    parts: *std.ArrayListUnmanaged([]u8),
    a: ai.protocol.AssistantMessage,
) !void {
    var text_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer text_buf.deinit(allocator);
    var thinking_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer thinking_buf.deinit(allocator);
    var tool_call_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer tool_call_buf.deinit(allocator);

    var first_text = true;
    var first_thinking = true;
    var first_tc = true;

    for (a.content) |block| switch (block) {
        .text => |t| {
            if (!first_text) try text_buf.append(allocator, '\n');
            try text_buf.appendSlice(allocator, t.text);
            first_text = false;
        },
        .thinking => |t| {
            if (!first_thinking) try thinking_buf.append(allocator, '\n');
            try thinking_buf.appendSlice(allocator, t.thinking);
            first_thinking = false;
        },
        .tool_call => |tc| {
            if (!first_tc) try tool_call_buf.appendSlice(allocator, "; ");
            const args_str = try stringifyJson(allocator, tc.arguments);
            defer allocator.free(args_str);
            try tool_call_buf.print(allocator, "{s}({s})", .{ tc.name, args_str });
            first_tc = false;
        },
    };

    if (thinking_buf.items.len > 0) {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "[Assistant thinking]: {s}", .{thinking_buf.items}));
    }
    if (text_buf.items.len > 0) {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "[Assistant]: {s}", .{text_buf.items}));
    }
    if (tool_call_buf.items.len > 0) {
        try parts.append(allocator, try std.fmt.allocPrint(allocator, "[Assistant tool calls]: {s}", .{tool_call_buf.items}));
    }
}

fn renderUserContent(allocator: std.mem.Allocator, content: anytype) ![]u8 {
    switch (content) {
        .text => |t| return try allocator.dupe(u8, t),
        .blocks => |blocks| {
            var out: std.ArrayListUnmanaged(u8) = .empty;
            for (blocks) |block| switch (block) {
                .text => |t| try out.appendSlice(allocator, t.text),
                .image => {},
            };
            return try out.toOwnedSlice(allocator);
        },
    }
}

fn truncateForSummary(allocator: std.mem.Allocator, text: []const u8, max_chars: usize) ![]u8 {
    if (text.len <= max_chars) return try allocator.dupe(u8, text);
    return try std.fmt.allocPrint(
        allocator,
        "{s}\n\n[... {d} more characters truncated]",
        .{ text[0..max_chars], text.len - max_chars },
    );
}

fn stringifyJson(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
    return try allocator.dupe(u8, out.written());
}

fn joinParts(allocator: std.mem.Allocator, parts: []const []u8, sep: []const u8) ![]u8 {
    if (parts.len == 0) return try allocator.dupe(u8, "");
    var total: usize = 0;
    for (parts) |p| total += p.len;
    total += sep.len * (parts.len - 1);
    var buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (parts, 0..) |p, i| {
        if (i > 0) {
            @memcpy(buf[pos..][0..sep.len], sep);
            pos += sep.len;
        }
        @memcpy(buf[pos..][0..p.len], p);
        pos += p.len;
    }
    return buf;
}

const testing = std.testing;

fn testUserEntry(id: []const u8, parent_id: ?[]const u8, text: []const u8) SessionEntry {
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
) !SessionEntry {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return testAssistantContentEntry(id, parent_id, content);
}

fn testAssistantContentEntry(
    id: []const u8,
    parent_id: ?[]const u8,
    content: []const ai.protocol.AssistantMessage.AssistantContentBlock,
) SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .message = .{ .message = .{ .assistant = testAssistantMessage(content) } } },
    };
}

fn testAssistantMessage(content: []const ai.protocol.AssistantMessage.AssistantContentBlock) ai.protocol.AgentMessage {
    return .{ .assistant = .{
        .content = content,
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = zeroUsage(),
        .stop_reason = .stop,
        .timestamp = 1,
    } };
}

fn zeroUsage() ai.protocol.Usage {
    return .{
        .input = 0,
        .output = 0,
        .cache_read = 0,
        .cache_write = 0,
        .total_tokens = 0,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    };
}

fn testBranchSummaryEntry(id: []const u8, parent_id: ?[]const u8, summary: []const u8) SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .branch_summary = .{ .from_id = parent_id orelse id, .summary = summary } },
    };
}

fn testCustomMessageEntry(id: []const u8, parent_id: ?[]const u8, text: []const u8) SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .custom_message = .{
            .custom_type = "test",
            .content = .{ .text = text },
            .display = true,
        } },
    };
}

fn testCompactionEntry(id: []const u8, parent_id: ?[]const u8, summary: []const u8, first_kept: []const u8, details: ?std.json.Value) SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00Z",
        .entry = .{ .compaction = .{
            .summary = summary,
            .first_kept_entry_id = first_kept,
            .tokens_before = 50,
            .details = details,
        } },
    };
}

fn testAssistantToolCallEntry(
    allocator: std.mem.Allocator,
    id: []const u8,
    parent_id: ?[]const u8,
    tool_name: []const u8,
    path: []const u8,
) !SessionEntry {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    var args_obj: std.json.ObjectMap = .{};
    try args_obj.put(allocator, "path", .{ .string = path });
    content[0] = .{ .tool_call = .{
        .id = "tc-1",
        .name = tool_name,
        .arguments = .{ .object = args_obj },
    } };
    return testAssistantContentEntry(id, parent_id, content);
}

fn expectCut(cut: CutPointResult, first_kept: usize, turn_start: ?usize, is_split_turn: bool) !void {
    try testing.expectEqual(first_kept, cut.first_kept_entry_index);
    try testing.expectEqual(turn_start, cut.turn_start_index);
    try testing.expectEqual(is_split_turn, cut.is_split_turn);
}

fn expectPreparation(
    prep: CompactionPreparation,
    first_kept_entry_id: []const u8,
    is_split_turn: bool,
    summarized_count: usize,
    prefix_count: usize,
) !void {
    try testing.expectEqualStrings(first_kept_entry_id, prep.first_kept_entry_id);
    try testing.expectEqual(is_split_turn, prep.is_split_turn);
    try testing.expectEqual(summarized_count, prep.messages_to_summarize.len);
    try testing.expectEqual(prefix_count, prep.turn_prefix_messages.len);
}

fn expectFileLists(lists: ComputedFileLists, read_files: []const []const u8, modified_files: []const []const u8) !void {
    try testing.expectEqual(read_files.len, lists.read_files.len);
    for (read_files, 0..) |expected, i| try testing.expectEqualStrings(expected, lists.read_files[i]);
    try testing.expectEqual(modified_files.len, lists.modified_files.len);
    for (modified_files, 0..) |expected, i| try testing.expectEqualStrings(expected, lists.modified_files[i]);
}

test "findCutPoint keeps the recent turn at a user boundary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u1", null, "older prompt with enough text to summarize"),
        try testAssistantEntry(allocator, "a1", "u1", "older answer"),
        testUserEntry("u2", "a1", "recent prompt"),
        try testAssistantEntry(allocator, "a2", "u2", "recent answer"),
    };

    const cut = findCutPoint(&entries, 0, entries.len, 5);
    try expectCut(cut, 2, null, false);
}

test "findCutPoint cuts inside a turn when assistant tail exceeds budget" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u1", null, "first prompt"),
        try testAssistantEntry(allocator, "a1", "u1", "first answer"),
        testUserEntry("u2", "a1", "second prompt"),
        try testAssistantEntry(allocator, "a2", "u2", "this assistant tail is intentionally long enough to exceed the keep recent token budget by itself"),
    };

    const cut = findCutPoint(&entries, 0, entries.len, 8);
    try expectCut(cut, 3, 2, true);
}

test "prepareCompaction summarizes older history when cut lands on a user turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u1", null, "first prompt is quite long so it dominates the budget budget budget"),
        try testAssistantEntry(allocator, "a1", "u1", "short"),
        testUserEntry("u2", "a1", "second"),
        try testAssistantEntry(allocator, "a2", "u2", "second answer"),
    };

    const prep = (try prepareCompaction(allocator, &entries, .{ .keep_recent_tokens = 5 })).?;
    try expectPreparation(prep, "u2", false, 2, 0);
}

test "prepareCompaction carries turn prefix when cut splits a turn" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u1", null, "first prompt"),
        try testAssistantEntry(allocator, "a1", "u1", "first answer"),
        testUserEntry("u2", "a1", "second prompt opens a long turn that will be cut in the middle"),
        try testAssistantEntry(allocator, "a2", "u2", "long assistant tail that by itself exceeds the keep recent token budget configured for this test"),
    };

    const prep = (try prepareCompaction(allocator, &entries, .{ .keep_recent_tokens = 8 })).?;
    try expectPreparation(prep, "a2", true, 2, 1);
}

test "prepareCompaction returns null when latest entry is compaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u1", null, "hi"),
        try testAssistantEntry(allocator, "a1", "u1", "there"),
        .{
            .id = "c1",
            .parent_id = "a1",
            .timestamp = "2025-01-01T00:00:00Z",
            .entry = .{ .compaction = .{
                .summary = "prior",
                .first_kept_entry_id = "u1",
                .tokens_before = 10,
            } },
        },
    };

    try testing.expectEqual(@as(?CompactionPreparation, null), try prepareCompaction(allocator, &entries, .{}));
}

test "prepareCompaction carries previous compaction summary" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u0", null, "before first compaction"),
        try testAssistantEntry(allocator, "a0", "u0", "ok"),
        .{
            .id = "c1",
            .parent_id = "a0",
            .timestamp = "2025-01-01T00:00:00Z",
            .entry = .{ .compaction = .{
                .summary = "earlier summary",
                .first_kept_entry_id = "u0",
                .tokens_before = 50,
            } },
        },
        testUserEntry("u1", "c1", "hello again"),
        try testAssistantEntry(allocator, "a1", "u1", "response with enough text to drive the cut backwards into the kept region"),
        testUserEntry("u2", "a1", "one more"),
        try testAssistantEntry(allocator, "a2", "u2", "second response"),
    };

    const prep = (try prepareCompaction(allocator, &entries, .{ .keep_recent_tokens = 4 })).?;
    try testing.expect(prep.previous_summary != null);
    try testing.expectEqualStrings("earlier summary", prep.previous_summary.?);
}

test "prepareCompaction resumes after previous compaction when kept id is gone" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const entries = [_]SessionEntry{
        testUserEntry("u0", null, "old"),
        try testAssistantEntry(allocator, "a0", "u0", "old answer"),
        testCompactionEntry("c1", "a0", "previous", "does-not-exist", null),
        testUserEntry("u1", "c1", "new work that should be the boundary start"),
        try testAssistantEntry(allocator, "a1", "u1", "new response long enough to be recent"),
    };

    const prep = (try prepareCompaction(allocator, &entries, .{ .keep_recent_tokens = 1 })).?;
    try testing.expectEqualStrings("previous", prep.previous_summary.?);
    try testing.expectEqual(@as(usize, 0), prep.messages_to_summarize.len);
    try testing.expectEqualStrings("a1", prep.first_kept_entry_id);
}

test "prepareCompaction carries file ops from previous pi-generated compaction" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var obj: std.json.ObjectMap = .{};
    var read_arr = std.json.Array.init(allocator);
    try read_arr.append(.{ .string = "/tmp/old-read.txt" });
    var mod_arr = std.json.Array.init(allocator);
    try mod_arr.append(.{ .string = "/tmp/old-modified.txt" });
    try obj.put(allocator, "readFiles", .{ .array = read_arr });
    try obj.put(allocator, "modifiedFiles", .{ .array = mod_arr });

    const entries = [_]SessionEntry{
        testUserEntry("u0", null, "old"),
        try testAssistantEntry(allocator, "a0", "u0", "old answer"),
        testCompactionEntry("c1", "a0", "previous", "u0", .{ .object = obj }),
        testUserEntry("u1", "c1", "new"),
        try testAssistantToolCallEntry(allocator, "a1", "u1", "read", "/tmp/new-read.txt"),
        testUserEntry("u2", "a1", "keep"),
    };

    const prep = (try prepareCompaction(allocator, &entries, .{ .keep_recent_tokens = 1 })).?;
    const lists = try computeFileLists(allocator, &prep.file_ops);
    try expectFileLists(lists, &.{ "/tmp/new-read.txt", "/tmp/old-read.txt" }, &.{"/tmp/old-modified.txt"});
}

test "findCutPoint reports split metadata for branch and custom message boundaries" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const branch_entries = [_]SessionEntry{
        testUserEntry("u1", null, "old prompt"),
        try testAssistantEntry(allocator, "a1", "u1", "old answer"),
        testBranchSummaryEntry("b1", "a1", "branch context that is large enough to cross budget"),
        try testAssistantEntry(allocator, "a2", "b1", "tail"),
    };
    const branch_cut = findCutPoint(&branch_entries, 2, branch_entries.len, 10_000);
    try expectCut(branch_cut, 2, 2, true);

    const custom_entries = [_]SessionEntry{
        testUserEntry("u1", null, "old prompt"),
        try testAssistantEntry(allocator, "a1", "u1", "old answer"),
        testCustomMessageEntry("m1", "a1", "custom context that is large enough to cross budget"),
        try testAssistantEntry(allocator, "a2", "m1", "tail"),
    };
    const custom_cut = findCutPoint(&custom_entries, 2, custom_entries.len, 10_000);
    try expectCut(custom_cut, 2, 2, true);
}

test "file operations: extract, dedupe, classify, and format summary lists" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const read_entry = try testAssistantToolCallEntry(allocator, "a1", null, "read", "/tmp/read-only.txt");
    const read_then_edit = try testAssistantToolCallEntry(allocator, "a2", "a1", "read", "/tmp/changed.txt");
    const edit_entry = try testAssistantToolCallEntry(allocator, "a3", "a2", "edit", "/tmp/changed.txt");
    const write_entry = try testAssistantToolCallEntry(allocator, "a4", "a3", "write", "/tmp/new.txt");

    var file_ops: FileOperations = .{};
    try extractFileOpsFromMessage(allocator, read_entry.entry.message.message, &file_ops);
    try extractFileOpsFromMessage(allocator, read_then_edit.entry.message.message, &file_ops);
    try extractFileOpsFromMessage(allocator, edit_entry.entry.message.message, &file_ops);
    try extractFileOpsFromMessage(allocator, write_entry.entry.message.message, &file_ops);

    const lists = try computeFileLists(allocator, &file_ops);
    try expectFileLists(lists, &.{"/tmp/read-only.txt"}, &.{ "/tmp/changed.txt", "/tmp/new.txt" });

    const out = try formatFileOperations(allocator, lists.read_files, lists.modified_files);
    try testing.expectEqualStrings(
        "\n\n<read-files>\n/tmp/read-only.txt\n</read-files>\n\n<modified-files>\n/tmp/changed.txt\n/tmp/new.txt\n</modified-files>",
        out,
    );
}

test "serializeConversation: emits summary roles and truncates long tool results" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    const assistant_content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    assistant_content[0] = .{ .text = .{ .text = "hi there" } };

    const big_text = try allocator.alloc(u8, TOOL_RESULT_MAX_CHARS + 500);
    @memset(big_text, 'x');
    const tool_content = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, 1);
    tool_content[0] = .{ .text = .{ .text = big_text } };

    const messages = [_]AgentMessage{
        .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 0 } },
        .{ .assistant = .{
            .content = assistant_content,
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
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "tc-1",
            .tool_name = "read",
            .content = tool_content,
            .is_error = false,
            .timestamp = 0,
        } },
    };

    const out = try serializeConversation(allocator, &messages);
    try testing.expect(std.mem.indexOf(u8, out, "[User]: hello") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[Assistant]: hi there") != null);
    try testing.expect(std.mem.indexOf(u8, out, "[Tool result]:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "truncated]") != null);
}
