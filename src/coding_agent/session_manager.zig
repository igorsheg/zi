//! In-memory view of one session's durable history. History is linear:
//! every entry's parent is the previous entry. The jsonl format still carries
//! `parentId` per entry (one fact, written by us, validated on load); tree
//! branching is deliberately not supported until a product feature needs it.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");

pub const current_session_version = 3;
pub const max_session_entries = 16_384;
pub const max_compaction_summary_bytes = 256 * 1024;
pub const max_compaction_first_kept_entry_id_bytes = 128;
pub const max_compaction_keep_recent_tokens = 1_000_000;
pub const max_compaction_serialized_input_bytes = 512 * 1024;
pub const max_compaction_tool_result_chars = 16 * 1024;

pub const SessionHeader = struct {
    version: u32 = current_session_version,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const CompactionSettings = struct {
    keep_recent_tokens: u64 = 20_000,
    auto_enabled: bool = false,
};

pub const SessionEntry = union(enum) {
    message: Message,
    thinking_level_change: ThinkingLevelChange,
    model_change: ModelChange,
    compaction: Compaction,

    pub const Base = struct {
        id: []const u8,
        parent_id: ?[]const u8,
        timestamp: []const u8,
    };

    pub const Message = struct {
        base: Base,
        message: agent.AgentMessage,
    };

    pub const ThinkingLevelChange = struct {
        base: Base,
        thinking_level: []const u8,
    };

    pub const ModelChange = struct {
        base: Base,
        provider: []const u8,
        model_id: []const u8,
    };

    pub const Compaction = struct {
        base: Base,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
    };

    pub fn id(self: SessionEntry) []const u8 {
        return switch (self) {
            inline else => |entry| entry.base.id,
        };
    }

    pub fn parentId(self: SessionEntry) ?[]const u8 {
        return switch (self) {
            inline else => |entry| entry.base.parent_id,
        };
    }
};

/// Owned input for one generated compaction summary: the messages to
/// summarize, the previous summary if any, and the chosen cut point.
pub const CompactionSummaryInput = struct {
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
    previous_summary: ?[]const u8 = null,
    first_kept_entry_id: []const u8,
    tokens_before: u64,

    pub fn deinit(self: *CompactionSummaryInput) void {
        for (self.messages) |message| agent.deinitAgentMessage(self.allocator, message);
        self.allocator.free(self.messages);
        if (self.previous_summary) |summary| self.allocator.free(summary);
        self.allocator.free(self.first_kept_entry_id);
        self.* = undefined;
    }

    pub const SerializeError = error{
        CompactionSerializedInputTooLarge,
        WriteFailed,
    } || std.mem.Allocator.Error;

    pub fn serialize(self: CompactionSummaryInput, allocator: std.mem.Allocator) SerializeError![]const u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        if (self.previous_summary) |summary| {
            try appendBounded(&writer, "<previous-summary>\n");
            try appendBounded(&writer, summary);
            try appendBounded(&writer, "\n</previous-summary>\n\n");
        }
        try appendBounded(&writer, "<conversation>\n");
        for (self.messages, 0..) |message, index| {
            if (index > 0) try appendBounded(&writer, "\n\n");
            try serializeMessage(&writer, message);
        }
        try appendBounded(&writer, "\n</conversation>\n");
        return writer.toOwnedSlice();
    }

    fn serializeMessage(writer: *std.Io.Writer.Allocating, message: agent.AgentMessage) SerializeError!void {
        switch (message) {
            .user => |user| {
                try appendBounded(writer, "[User]: ");
                switch (user.content) {
                    .string => |text| try appendBounded(writer, text),
                    .blocks => |blocks| for (blocks) |block| switch (block) {
                        .text => |text| try appendBounded(writer, text.text),
                        .image => try appendBounded(writer, "[image]"),
                    },
                }
            },
            .assistant => |assistant| {
                var wrote_any = false;
                for (assistant.content) |block| {
                    if (wrote_any) try appendBounded(writer, "\n");
                    switch (block) {
                        .thinking => |thinking| {
                            try appendBounded(writer, "[Assistant thinking]: ");
                            try appendBounded(writer, thinking.thinking);
                        },
                        .text => |text| {
                            try appendBounded(writer, "[Assistant]: ");
                            try appendBounded(writer, text.text);
                        },
                        .tool_call => |tool_call| {
                            try appendBounded(writer, "[Assistant tool call]: ");
                            try appendBounded(writer, tool_call.name);
                        },
                    }
                    wrote_any = true;
                }
            },
            .tool_result => |tool_result| {
                try appendBounded(writer, "[Tool result]: ");
                var remaining: usize = max_compaction_tool_result_chars;
                for (tool_result.content) |block| switch (block) {
                    .text => |text| {
                        const len = @min(remaining, text.text.len);
                        try appendBounded(writer, text.text[0..len]);
                        remaining -= len;
                        if (remaining == 0) {
                            try appendBounded(writer, "\n[truncated]");
                            return;
                        }
                    },
                    .image => try appendBounded(writer, "[image]"),
                };
            },
            .custom => |custom| {
                try appendBounded(writer, "[Custom ");
                try appendBounded(writer, custom.kind);
                try appendBounded(writer, "]");
            },
        }
    }

    fn appendBounded(writer: *std.Io.Writer.Allocating, text: []const u8) SerializeError!void {
        if (text.len > max_compaction_serialized_input_bytes or
            writer.written().len > max_compaction_serialized_input_bytes - text.len)
        {
            return error.CompactionSerializedInputTooLarge;
        }
        try writer.writer.writeAll(text);
    }
};

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    header: SessionHeader,
    entries: std.ArrayList(SessionEntry) = .empty,
    next_id: u64 = 1,

    pub const Error = error{
        EntryLimitExceeded,
        EntryNotFound,
        AlreadyCompacted,
        NothingToCompact,
        CompactionSummaryTooLarge,
        CompactionFirstKeptEntryIdTooLarge,
        CompactionFirstKeptEntryNotFound,
        CompactionSettingsOutOfBounds,
    } || std.mem.Allocator.Error;

    pub const LoadedEntry = struct {
        id: []const u8,
        parent_id: ?[]const u8,
        timestamp: []const u8,
        value: Value,

        pub const Value = union(enum) {
            message: agent.AgentMessage,
            thinking_level_change: []const u8,
            model_change: struct { provider: []const u8, model_id: []const u8 },
            compaction: struct {
                summary: []const u8,
                first_kept_entry_id: []const u8,
                tokens_before: u64,
            },
        };
    };

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        session_id: []const u8,
        timestamp: []const u8,
    ) !SessionManager {
        const id = try allocator.dupe(u8, session_id);
        errdefer allocator.free(id);
        const timestamp_copy = try allocator.dupe(u8, timestamp);
        errdefer allocator.free(timestamp_copy);
        const cwd_copy = try allocator.dupe(u8, cwd);
        return .{
            .allocator = allocator,
            .header = .{
                .id = id,
                .timestamp = timestamp_copy,
                .cwd = cwd_copy,
            },
        };
    }

    pub fn deinit(self: *SessionManager) void {
        self.allocator.free(self.header.id);
        self.allocator.free(self.header.timestamp);
        self.allocator.free(self.header.cwd);
        if (self.header.parent_session) |parent_session| self.allocator.free(parent_session);
        for (self.entries.items) |entry| self.deinitEntry(entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn appendMessage(self: *SessionManager, message: agent.AgentMessage, timestamp: []const u8) Error![]const u8 {
        try self.ensureAppendCapacity(1);
        const entry = try self.prepareMessageEntry(message, timestamp);
        errdefer self.deinitEntry(entry);
        return self.commitPreparedEntry(entry);
    }

    pub fn appendThinkingLevelChange(
        self: *SessionManager,
        thinking_level: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
        try self.ensureAppendCapacity(1);
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.deinitBase(base);
            break :blk .{ .thinking_level_change = .{
                .base = base,
                .thinking_level = try self.allocator.dupe(u8, thinking_level),
            } };
        };
        return self.commitPreparedEntry(entry);
    }

    pub fn appendModelChange(
        self: *SessionManager,
        provider: []const u8,
        model_id: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
        try self.ensureAppendCapacity(1);
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.deinitBase(base);
            const provider_copy = try self.allocator.dupe(u8, provider);
            errdefer self.allocator.free(provider_copy);
            const model_id_copy = try self.allocator.dupe(u8, model_id);
            break :blk .{ .model_change = .{
                .base = base,
                .provider = provider_copy,
                .model_id = model_id_copy,
            } };
        };
        return self.commitPreparedEntry(entry);
    }

    pub fn appendCompaction(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        timestamp: []const u8,
    ) Error![]const u8 {
        try self.ensureAppendCapacity(1);
        const entry = try self.prepareCompactionEntry(summary, first_kept_entry_id, tokens_before, timestamp);
        errdefer self.deinitEntry(entry);
        return self.commitPreparedEntry(entry);
    }

    /// Prepare/commit split lets the caller persist an entry durably before
    /// it becomes visible in memory (jsonl reaches disk before commit).
    pub fn ensureAppendCapacity(self: *SessionManager, additional_count: usize) Error!void {
        if (additional_count > max_session_entries - self.entries.items.len) return error.EntryLimitExceeded;
        try self.entries.ensureUnusedCapacity(self.allocator, additional_count);
    }

    pub fn prepareMessageEntry(
        self: *SessionManager,
        message: agent.AgentMessage,
        timestamp: []const u8,
    ) Error!SessionEntry {
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        return .{ .message = .{
            .base = base,
            .message = try agent.copyAgentMessage(self.allocator, message),
        } };
    }

    pub fn prepareCompactionEntry(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        timestamp: []const u8,
    ) Error!SessionEntry {
        if (summary.len > max_compaction_summary_bytes) return error.CompactionSummaryTooLarge;
        if (first_kept_entry_id.len > max_compaction_first_kept_entry_id_bytes) {
            return error.CompactionFirstKeptEntryIdTooLarge;
        }
        if (self.findEntryIndex(first_kept_entry_id) == null) return error.CompactionFirstKeptEntryNotFound;
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        const summary_copy = try self.allocator.dupe(u8, summary);
        errdefer self.allocator.free(summary_copy);
        const first_kept_entry_id_copy = try self.allocator.dupe(u8, first_kept_entry_id);
        return .{ .compaction = .{
            .base = base,
            .summary = summary_copy,
            .first_kept_entry_id = first_kept_entry_id_copy,
            .tokens_before = tokens_before,
        } };
    }

    pub fn commitPreparedEntry(self: *SessionManager, entry: SessionEntry) []const u8 {
        std.debug.assert(self.entries.items.len < max_session_entries);
        self.entries.appendAssumeCapacity(entry);
        self.next_id += 1;
        return entry.id();
    }

    pub fn deinitPreparedEntry(self: *SessionManager, entry: SessionEntry) void {
        self.deinitEntry(entry);
    }

    /// Append an entry loaded from disk. The parent link must point at the
    /// previous entry: history is linear, and a duplicated or reordered line
    /// breaks that chain and is rejected here.
    pub fn appendLoadedEntry(self: *SessionManager, loaded: LoadedEntry) Error![]const u8 {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        const last_id: ?[]const u8 = if (self.entries.items.len == 0)
            null
        else
            self.entries.items[self.entries.items.len - 1].id();
        const linear = if (loaded.parent_id) |parent_id|
            last_id != null and std.mem.eql(u8, parent_id, last_id.?)
        else
            last_id == null;
        if (!linear) return error.EntryNotFound;

        const base: SessionEntry.Base = blk: {
            const id = try self.allocator.dupe(u8, loaded.id);
            errdefer self.allocator.free(id);
            const parent_id = if (loaded.parent_id) |parent_id| try self.allocator.dupe(u8, parent_id) else null;
            errdefer if (parent_id) |value| self.allocator.free(value);
            const timestamp = try self.allocator.dupe(u8, loaded.timestamp);
            break :blk .{ .id = id, .parent_id = parent_id, .timestamp = timestamp };
        };
        errdefer self.deinitBase(base);
        const entry: SessionEntry = switch (loaded.value) {
            .message => |message| .{ .message = .{
                .base = base,
                .message = try agent.copyAgentMessage(self.allocator, message),
            } },
            .thinking_level_change => |thinking_level| .{ .thinking_level_change = .{
                .base = base,
                .thinking_level = try self.allocator.dupe(u8, thinking_level),
            } },
            .model_change => |model| blk: {
                const provider = try self.allocator.dupe(u8, model.provider);
                errdefer self.allocator.free(provider);
                const model_id = try self.allocator.dupe(u8, model.model_id);
                break :blk .{ .model_change = .{
                    .base = base,
                    .provider = provider,
                    .model_id = model_id,
                } };
            },
            .compaction => |compaction| blk: {
                if (compaction.summary.len > max_compaction_summary_bytes) return error.CompactionSummaryTooLarge;
                if (compaction.first_kept_entry_id.len > max_compaction_first_kept_entry_id_bytes) {
                    return error.CompactionFirstKeptEntryIdTooLarge;
                }
                if (self.findEntryIndex(compaction.first_kept_entry_id) == null) {
                    return error.CompactionFirstKeptEntryNotFound;
                }
                const summary = try self.allocator.dupe(u8, compaction.summary);
                errdefer self.allocator.free(summary);
                const first_kept_entry_id = try self.allocator.dupe(u8, compaction.first_kept_entry_id);
                break :blk .{ .compaction = .{
                    .base = base,
                    .summary = summary,
                    .first_kept_entry_id = first_kept_entry_id,
                    .tokens_before = compaction.tokens_before,
                } };
            },
        };
        errdefer self.deinitEntry(entry);
        try self.entries.append(self.allocator, entry);
        if (std.fmt.parseInt(u64, loaded.id, 16)) |numeric_id| {
            const after_loaded_id = if (numeric_id == std.math.maxInt(u64)) numeric_id else numeric_id + 1;
            self.next_id = @max(self.next_id, after_loaded_id);
        } else |_| {}
        return entry.id();
    }

    /// Project the entries into the agent's runtime context: the latest
    /// compaction summary (if any), the kept tail before it, then everything
    /// after it. The caller owns the returned messages.
    pub fn contextMessages(self: *const SessionManager, allocator: std.mem.Allocator) Error![]agent.AgentMessage {
        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer freeContextMessages(allocator, &messages);

        const entries = self.entries.items;
        var latest_compaction_index: ?usize = null;
        for (entries, 0..) |entry, index| {
            if (entry == .compaction) latest_compaction_index = index;
        }

        var start: usize = 0;
        if (latest_compaction_index) |compaction_index| {
            const compaction = entries[compaction_index].compaction;
            const summary_text = try std.fmt.allocPrint(
                allocator,
                "The conversation history before this point was compacted into the following summary:\n\n" ++
                    "<summary>\n{s}\n</summary>",
                .{compaction.summary},
            );
            {
                errdefer allocator.free(summary_text);
                try messages.ensureUnusedCapacity(allocator, 1);
            }
            messages.appendAssumeCapacity(.{ .user = .{
                .content = .{ .string = summary_text },
                .timestamp = 0,
            } });
            start = self.findEntryIndex(compaction.first_kept_entry_id) orelse compaction_index + 1;
        }

        for (entries[start..]) |entry| {
            if (entry != .message) continue;
            const copy = try agent.copyAgentMessage(allocator, entry.message.message);
            errdefer agent.deinitAgentMessage(allocator, copy);
            try messages.append(allocator, copy);
        }
        return messages.toOwnedSlice(allocator);
    }

    pub fn deinitContextMessages(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) void {
        for (messages) |message| agent.deinitAgentMessage(allocator, message);
        allocator.free(messages);
    }

    /// Choose a compaction cut and gather the messages to summarize.
    /// Errors with NothingToCompact / AlreadyCompacted when there is no work.
    pub fn buildCompactionSummaryInput(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        settings: CompactionSettings,
    ) Error!CompactionSummaryInput {
        if (settings.keep_recent_tokens > max_compaction_keep_recent_tokens) {
            return error.CompactionSettingsOutOfBounds;
        }
        const entries = self.entries.items;
        if (entries.len == 0) return error.NothingToCompact;
        if (entries[entries.len - 1] == .compaction) return error.AlreadyCompacted;

        // The summarize window starts at the previous compaction's first kept
        // entry (its summary is carried forward), or at the beginning.
        var boundary_start: usize = 0;
        var previous_summary_text: ?[]const u8 = null;
        var index = entries.len;
        while (index > 0) {
            index -= 1;
            if (entries[index] == .compaction) {
                const compaction = entries[index].compaction;
                previous_summary_text = compaction.summary;
                boundary_start = self.findEntryIndex(compaction.first_kept_entry_id) orelse index + 1;
                break;
            }
        }

        // Cut so the kept suffix holds at least keep_recent_tokens. Only a
        // non-tool-result message is a valid cut point.
        var first_valid_cut = boundary_start;
        while (first_valid_cut < entries.len and !isValidCompactionCut(entries[first_valid_cut])) {
            first_valid_cut += 1;
        }
        var cut_index = first_valid_cut;
        if (first_valid_cut == entries.len) {
            cut_index = boundary_start;
        } else {
            var accumulated_tokens: u64 = 0;
            index = entries.len;
            while (index > boundary_start) {
                index -= 1;
                if (entries[index] != .message) continue;
                accumulated_tokens +|= estimateEntryTokens(entries[index]);
                if (accumulated_tokens >= settings.keep_recent_tokens) {
                    cut_index = first_valid_cut;
                    for (entries[index..], index..) |entry, candidate_index| {
                        if (isValidCompactionCut(entry)) {
                            cut_index = candidate_index;
                            break;
                        }
                    }
                    break;
                }
            }
        }
        if (cut_index <= boundary_start) return error.NothingToCompact;

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer freeContextMessages(allocator, &messages);
        for (entries[boundary_start..cut_index]) |entry| {
            if (entry != .message) continue;
            const copy = try agent.copyAgentMessage(allocator, entry.message.message);
            errdefer agent.deinitAgentMessage(allocator, copy);
            try messages.append(allocator, copy);
        }
        if (messages.items.len == 0) return error.NothingToCompact;

        const first_kept_entry_id = try allocator.dupe(u8, entries[cut_index].id());
        errdefer allocator.free(first_kept_entry_id);
        const previous_summary = if (previous_summary_text) |text| try allocator.dupe(u8, text) else null;
        errdefer if (previous_summary) |summary| allocator.free(summary);

        var tokens_before: u64 = 0;
        for (entries) |entry| tokens_before +|= estimateEntryTokens(entry);

        return .{
            .allocator = allocator,
            .messages = try messages.toOwnedSlice(allocator),
            .previous_summary = previous_summary,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = tokens_before,
        };
    }

    fn freeContextMessages(allocator: std.mem.Allocator, messages: *std.ArrayList(agent.AgentMessage)) void {
        for (messages.items) |message| agent.deinitAgentMessage(allocator, message);
        messages.deinit(allocator);
    }

    fn isValidCompactionCut(entry: SessionEntry) bool {
        return switch (entry) {
            .message => |message_entry| message_entry.message != .tool_result,
            else => false,
        };
    }

    fn estimateEntryTokens(entry: SessionEntry) u64 {
        const chars: u64 = switch (entry) {
            .compaction => |compaction| compaction.summary.len,
            .message => |message_entry| switch (message_entry.message) {
                .user => |user| switch (user.content) {
                    .string => |text| text.len,
                    .blocks => |blocks| blk: {
                        var count: u64 = 0;
                        for (blocks) |block| switch (block) {
                            .text => |text| count +|= text.text.len,
                            .image => count +|= 4800,
                        };
                        break :blk count;
                    },
                },
                .assistant => |assistant| blk: {
                    var count: u64 = 0;
                    for (assistant.content) |block| switch (block) {
                        .text => |text| count +|= text.text.len,
                        .thinking => |thinking| count +|= thinking.thinking.len,
                        .tool_call => |tool_call| count +|= tool_call.name.len,
                    };
                    break :blk count;
                },
                .tool_result => |tool_result| blk: {
                    var count: u64 = tool_result.tool_name.len;
                    for (tool_result.content) |block| switch (block) {
                        .text => |text| count +|= text.text.len,
                        .image => count +|= 4800,
                    };
                    break :blk count;
                },
                .custom => |custom| custom.kind.len,
            },
            else => 0,
        };
        return (chars + 3) / 4;
    }

    fn findEntryIndex(self: *const SessionManager, entry_id: []const u8) ?usize {
        // Search newest-first: lookups overwhelmingly target recent entries.
        var index = self.entries.items.len;
        while (index > 0) {
            index -= 1;
            if (std.mem.eql(u8, self.entries.items[index].id(), entry_id)) return index;
        }
        return null;
    }

    fn nextBase(self: *SessionManager, timestamp: []const u8) Error!SessionEntry.Base {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        if (self.next_id == std.math.maxInt(u64)) return error.EntryLimitExceeded;
        const id = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{self.next_id});
        errdefer self.allocator.free(id);
        const parent_id = if (self.entries.items.len == 0)
            null
        else
            try self.allocator.dupe(u8, self.entries.items[self.entries.items.len - 1].id());
        errdefer if (parent_id) |value| self.allocator.free(value);
        const timestamp_copy = try self.allocator.dupe(u8, timestamp);
        return .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp_copy,
        };
    }

    fn deinitEntry(self: *SessionManager, entry: SessionEntry) void {
        switch (entry) {
            .message => |message| {
                self.deinitBase(message.base);
                agent.deinitAgentMessage(self.allocator, message.message);
            },
            .thinking_level_change => |thinking| {
                self.deinitBase(thinking.base);
                self.allocator.free(thinking.thinking_level);
            },
            .model_change => |model| {
                self.deinitBase(model.base);
                self.allocator.free(model.provider);
                self.allocator.free(model.model_id);
            },
            .compaction => |compaction| {
                self.deinitBase(compaction.base);
                self.allocator.free(compaction.summary);
                self.allocator.free(compaction.first_kept_entry_id);
            },
        }
    }

    fn deinitBase(self: *SessionManager, base: SessionEntry.Base) void {
        self.allocator.free(base.id);
        if (base.parent_id) |parent_id| self.allocator.free(parent_id);
        self.allocator.free(base.timestamp);
    }
};

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

test "new session stores header metadata" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "2026-01-01T00:00:00Z");
    defer manager.deinit();

    try std.testing.expectEqual(@as(u32, current_session_version), manager.header.version);
    try std.testing.expectEqualStrings("session-1", manager.header.id);
    try std.testing.expectEqualStrings("/repo", manager.header.cwd);
}

test "append entries link linearly to the previous entry" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const first = try manager.appendMessage(userMessage("one"), "t1");
    _ = try manager.appendThinkingLevelChange("high", "t2");
    _ = try manager.appendModelChange("openai", "gpt", "t3");

    try std.testing.expect(manager.entries.items[0].parentId() == null);
    try std.testing.expectEqualStrings(first, manager.entries.items[1].parentId().?);
    try std.testing.expectEqualStrings("00000002", manager.entries.items[2].parentId().?);
}

test "append compaction stores durable summary entry with bounds" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("before"), "t1");
    _ = try manager.appendCompaction("summary", root, 1200, "t2");

    try std.testing.expectEqualStrings("summary", manager.entries.items[1].compaction.summary);
    try std.testing.expectEqualStrings(root, manager.entries.items[1].compaction.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 1200), manager.entries.items[1].compaction.tokens_before);

    const oversized_summary = try std.testing.allocator.alloc(u8, max_compaction_summary_bytes + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 'a');
    try std.testing.expectError(
        error.CompactionSummaryTooLarge,
        manager.appendCompaction(oversized_summary, root, 1, "t3"),
    );
    try std.testing.expectError(
        error.CompactionFirstKeptEntryNotFound,
        manager.appendCompaction("summary", "missing", 1, "t3"),
    );
    try std.testing.expectEqual(@as(usize, 2), manager.entries.items.len);
}

test "prepared message entry does not mutate entries before commit" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try manager.ensureAppendCapacity(1);
    const entry = try manager.prepareMessageEntry(userMessage("one"), "t1");
    var committed = false;
    errdefer if (!committed) manager.deinitPreparedEntry(entry);

    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);

    const id = manager.commitPreparedEntry(entry);
    committed = true;
    try std.testing.expectEqualStrings("00000001", id);
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "context messages project message entries only" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendModelChange("openai", "gpt", "t1");
    _ = try manager.appendThinkingLevelChange("medium", "t2");
    _ = try manager.appendMessage(userMessage("hello"), "t3");

    const messages = try manager.contextMessages(std.testing.allocator);
    defer SessionManager.deinitContextMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 1), messages.len);
    try std.testing.expectEqualStrings("hello", messages[0].user.content.string);
}

test "context messages project latest compaction summary then kept messages" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("dropped"), "t1");
    const kept = try manager.appendMessage(userMessage("kept"), "t2");
    _ = try manager.appendCompaction("older summary", kept, 3000, "t3");
    _ = try manager.appendMessage(userMessage("after"), "t4");

    const messages = try manager.contextMessages(std.testing.allocator);
    defer SessionManager.deinitContextMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 3), messages.len);
    try std.testing.expect(std.mem.indexOf(u8, messages[0].user.content.string, "older summary") != null);
    try std.testing.expectEqualStrings("kept", messages[1].user.content.string);
    try std.testing.expectEqualStrings("after", messages[2].user.content.string);
}

test "compaction summary input rejects empty small and already compacted histories" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try std.testing.expectError(
        error.NothingToCompact,
        manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 1 }),
    );

    const root = try manager.appendMessage(userMessage("abcd"), "t1");
    try std.testing.expectError(
        error.NothingToCompact,
        manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 100 }),
    );

    _ = try manager.appendCompaction("summary", root, 1, "t2");
    try std.testing.expectError(
        error.AlreadyCompacted,
        manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 1 }),
    );

    _ = try manager.appendMessage(userMessage("after"), "t3");
    try std.testing.expectError(
        error.CompactionSettingsOutOfBounds,
        manager.buildCompactionSummaryInput(std.testing.allocator, .{
            .keep_recent_tokens = max_compaction_keep_recent_tokens + 1,
        }),
    );
}

test "compaction summary input keeps bounded recent suffix" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("aaaaaaaa"), "t1");
    _ = try manager.appendMessage(userMessage("bbbbbbbb"), "t2");
    const kept = try manager.appendMessage(userMessage("cccccccc"), "t3");

    var input = try manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 2 });
    defer input.deinit();

    try std.testing.expectEqual(@as(usize, 2), input.messages.len);
    try std.testing.expectEqualStrings("aaaaaaaa", input.messages[0].user.content.string);
    try std.testing.expectEqualStrings("bbbbbbbb", input.messages[1].user.content.string);
    try std.testing.expectEqualStrings(kept, input.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 6), input.tokens_before);
    try std.testing.expect(input.previous_summary == null);
}

test "compaction summary input reuses previous first kept boundary and summary" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("aaaaaaaa"), "t1");
    _ = try manager.appendCompaction("prior", root, 2, "t2");
    _ = try manager.appendMessage(userMessage("bbbbbbbb"), "t3");
    const kept = try manager.appendMessage(userMessage("cccccccc"), "t4");

    var input = try manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 2 });
    defer input.deinit();

    try std.testing.expectEqual(@as(usize, 2), input.messages.len);
    try std.testing.expectEqualStrings("aaaaaaaa", input.messages[0].user.content.string);
    try std.testing.expectEqualStrings("bbbbbbbb", input.messages[1].user.content.string);
    try std.testing.expectEqualStrings(kept, input.first_kept_entry_id);
    try std.testing.expectEqualStrings("prior", input.previous_summary.?);
}

test "serialize compaction summary input writes deterministic bounded text" {
    const assistant_blocks = [_]ai.AssistantContent{
        .{ .thinking = .{ .thinking = "thought" } },
        .{ .text = .{ .text = "answer" } },
        .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = .null } },
    };
    const tool_blocks = [_]ai.ToolResultContent{.{ .text = .{ .text = "tool output" } }};
    const source_messages = [_]agent.AgentMessage{
        userMessage("question"),
        .{ .assistant = .{
            .content = &assistant_blocks,
            .api = ai.KnownApi.openai_responses,
            .provider = "openai",
            .model = "gpt",
            .usage = ai.protocol.emptyUsage(),
            .stop_reason = .tool_use,
            .timestamp = 0,
        } },
        .{ .tool_result = .{
            .tool_call_id = "call-1",
            .tool_name = "read",
            .content = &tool_blocks,
            .is_error = false,
            .timestamp = 0,
        } },
    };

    const input: CompactionSummaryInput = .{
        .allocator = std.testing.allocator,
        .messages = &source_messages,
        .previous_summary = "prior summary",
        .first_kept_entry_id = "00000004",
        .tokens_before = 42,
    };
    const serialized = try input.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);

    try std.testing.expectEqualStrings(
        "<previous-summary>\n" ++
            "prior summary\n" ++
            "</previous-summary>\n\n" ++
            "<conversation>\n" ++
            "[User]: question\n\n" ++
            "[Assistant thinking]: thought\n" ++
            "[Assistant]: answer\n" ++
            "[Assistant tool call]: read\n\n" ++
            "[Tool result]: tool output\n" ++
            "</conversation>\n",
        serialized,
    );
}

test "serialize compaction summary input truncates tool results and bounds output" {
    const tool_text = try std.testing.allocator.alloc(u8, max_compaction_tool_result_chars + 1);
    defer std.testing.allocator.free(tool_text);
    @memset(tool_text, 't');
    const tool_blocks = [_]ai.ToolResultContent{.{ .text = .{ .text = tool_text } }};
    const source_messages = [_]agent.AgentMessage{.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &tool_blocks,
        .is_error = false,
        .timestamp = 0,
    } }};

    const input: CompactionSummaryInput = .{
        .allocator = std.testing.allocator,
        .messages = &source_messages,
        .first_kept_entry_id = "00000002",
        .tokens_before = 42,
    };
    const serialized = try input.serialize(std.testing.allocator);
    defer std.testing.allocator.free(serialized);
    try std.testing.expect(std.mem.indexOf(u8, serialized, "\n[truncated]") != null);

    const oversized = try std.testing.allocator.alloc(u8, max_compaction_serialized_input_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    const oversized_input: CompactionSummaryInput = .{
        .allocator = std.testing.allocator,
        .messages = &.{},
        .previous_summary = oversized,
        .first_kept_entry_id = &.{},
        .tokens_before = 0,
    };
    try std.testing.expectError(
        error.CompactionSerializedInputTooLarge,
        oversized_input.serialize(std.testing.allocator),
    );
}

test "loaded entries preserve ids and continue id generation" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "0000000a",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    _ = try manager.appendLoadedEntry(.{
        .id = "0000000b",
        .parent_id = "0000000a",
        .timestamp = "t2",
        .value = .{ .compaction = .{
            .summary = "summary",
            .first_kept_entry_id = "0000000a",
            .tokens_before = 100,
        } },
    });
    _ = try manager.appendMessage(userMessage("next"), "t3");

    try std.testing.expectEqualStrings("0000000c", manager.entries.items[2].id());
    try std.testing.expectEqualStrings("0000000b", manager.entries.items[2].parentId().?);
}

test "loaded entries reject non linear parent links" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    // Duplicate line: parent points at its own id's predecessor, not the tail.
    try std.testing.expectError(error.EntryNotFound, manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    }));
    try std.testing.expectError(error.EntryNotFound, manager.appendLoadedEntry(.{
        .id = "00000003",
        .parent_id = "missing",
        .timestamp = "t2",
        .value = .{ .message = userMessage("orphan") },
    }));
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "loaded compaction entries enforce durable bounds" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    const oversized_summary = try std.testing.allocator.alloc(u8, max_compaction_summary_bytes + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 'a');

    try std.testing.expectError(error.CompactionSummaryTooLarge, manager.appendLoadedEntry(.{
        .id = "00000002",
        .parent_id = "00000001",
        .timestamp = "t2",
        .value = .{ .compaction = .{
            .summary = oversized_summary,
            .first_kept_entry_id = "00000001",
            .tokens_before = 1,
        } },
    }));
    try std.testing.expectError(error.CompactionFirstKeptEntryNotFound, manager.appendLoadedEntry(.{
        .id = "00000002",
        .parent_id = "00000001",
        .timestamp = "t2",
        .value = .{ .compaction = .{
            .summary = "summary",
            .first_kept_entry_id = "missing",
            .tokens_before = 1,
        } },
    }));
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}
