//! Durable session history: entry shapes and bounds, the in-memory state,
//! the jsonl encoding, and the file store. History is linear: every entry's
//! parent is the previous entry, so `parentId` is an encoding detail of the
//! jsonl line (written at append, validated on load), not stored state.
//! Tree branching is deliberately not supported until a product feature
//! needs it.

const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const paths_mod = @import("paths.zig");
const runtime = @import("../runtime/root.zig");

pub const current_session_version = 3;
pub const max_session_file_bytes = 64 * 1024 * 1024;
pub const max_session_line_bytes = 1024 * 1024;
pub const max_session_entries = 16_384;
pub const max_compaction_summary_bytes = 256 * 1024;
pub const max_compaction_first_kept_entry_id_bytes = 128;
pub const max_model_provider_bytes = 64;
pub const max_model_id_bytes = 128;
pub const max_thinking_level_bytes = 32;
pub const max_compaction_keep_recent_tokens = 1_000_000;
pub const max_compaction_reserve_tokens = 1_000_000;
pub const max_compaction_serialized_input_bytes = 512 * 1024;
pub const max_compaction_tool_result_chars = 16 * 1024;
pub const timestamp_bytes_len: usize = 20;

pub fn timestampFromNanoseconds(nanoseconds: i96) [timestamp_bytes_len]u8 {
    const seconds_total = @divFloor(nanoseconds, std.time.ns_per_s);
    const epoch_seconds: std.time.epoch.EpochSeconds = .{
        .secs = if (seconds_total > 0) @intCast(seconds_total) else 0,
    };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    var text: [timestamp_bytes_len]u8 = undefined;
    _ = std.fmt.bufPrint(&text, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
        year_day.year,
        month_day.month.numeric(),
        month_day.day_index + 1,
        day_seconds.getHoursIntoDay(),
        day_seconds.getMinutesIntoHour(),
        day_seconds.getSecondsIntoMinute(),
    }) catch unreachable;
    return text;
}

pub fn timestampNow(io: std.Io) [timestamp_bytes_len]u8 {
    return timestampFromNanoseconds(std.Io.Timestamp.now(io, .real).nanoseconds);
}

pub const SessionHeader = struct {
    version: u32 = current_session_version,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const CompactionSettings = struct {
    keep_recent_tokens: u64 = 20_000,
    reserve_tokens: u64 = 16_384,
    auto_enabled: bool = true,
};

pub const SessionEntry = union(enum) {
    message: Message,
    compaction: Compaction,
    model_change: ModelChange,
    thinking_level_change: ThinkingLevelChange,

    pub const Base = struct {
        id: []const u8,
        timestamp: []const u8,
    };

    pub const Message = struct {
        base: Base,
        message: agent.AgentMessage,
    };

    pub const Compaction = struct {
        base: Base,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
    };

    pub const ModelChange = struct {
        base: Base,
        provider: []const u8,
        model_id: []const u8,
    };

    pub const ThinkingLevelChange = struct {
        base: Base,
        thinking_level: []const u8,
    };

    pub fn id(self: SessionEntry) []const u8 {
        return switch (self) {
            inline else => |entry| entry.base.id,
        };
    }
};

pub const ReconstructedSessionItem = struct {
    entry_id: []const u8,
    timestamp: []const u8,
    content: Content,

    pub const Content = union(enum) {
        message: agent.AgentMessage,
        compaction_summary: CompactionSummary,
    };

    pub const CompactionSummary = struct {
        summary: []const u8,
        tokens_before: u64,
    };
};

/// Owned input for one generated compaction summary: the messages to
/// summarize, the previous summary if any, and the chosen cut point.
pub const CompactionSummaryInput = struct {
    allocator: std.mem.Allocator,
    messages: []const agent.AgentMessage,
    turn_prefix_messages: []const agent.AgentMessage = &.{},
    is_split_turn: bool = false,
    previous_summary: ?[]const u8 = null,
    first_kept_entry_id: []const u8,
    tokens_before: u64,

    pub fn deinit(self: *CompactionSummaryInput) void {
        for (self.messages) |message| agent.deinitAgentMessage(self.allocator, message);
        self.allocator.free(self.messages);
        for (self.turn_prefix_messages) |message| agent.deinitAgentMessage(self.allocator, message);
        if (self.turn_prefix_messages.len > 0) self.allocator.free(self.turn_prefix_messages);
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
        try appendBounded(&writer, "<conversation>\n");
        try serializeMessages(&writer, self.messages);
        try appendBounded(&writer, "\n</conversation>\n");
        if (self.previous_summary) |summary| {
            try appendBounded(&writer, "\n<previous-summary>\n");
            try appendBounded(&writer, summary);
            try appendBounded(&writer, "\n</previous-summary>\n");
        }
        return writer.toOwnedSlice();
    }

    pub fn serializeTurnPrefix(self: CompactionSummaryInput, allocator: std.mem.Allocator) SerializeError![]const u8 {
        var writer: std.Io.Writer.Allocating = .init(allocator);
        errdefer writer.deinit();
        try appendBounded(&writer, "<turn-prefix>\n");
        try serializeMessages(&writer, self.turn_prefix_messages);
        try appendBounded(&writer, "\n</turn-prefix>\n");
        return writer.toOwnedSlice();
    }

    fn serializeMessages(writer: *std.Io.Writer.Allocating, messages: []const agent.AgentMessage) SerializeError!void {
        for (messages, 0..) |message, index| {
            if (index > 0) try appendBounded(writer, "\n\n");
            try serializeMessage(writer, message);
        }
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
        InvalidEntryId,
        AlreadyCompacted,
        NothingToCompact,
        CompactionSummaryTooLarge,
        CompactionFirstKeptEntryIdTooLarge,
        CompactionFirstKeptEntryNotFound,
        CompactionSettingsOutOfBounds,
    } || std.mem.Allocator.Error;

    pub const SessionPreferences = struct {
        model: ?Model = null,
        thinking_level: ?[]const u8 = null,

        pub const Model = struct {
            provider: []const u8,
            model_id: []const u8,
        };
    };

    const LoadedValue = union(enum) {
        message: agent.AgentMessage,
        compaction: struct {
            summary: []const u8,
            first_kept_entry_id: []const u8,
            tokens_before: u64,
        },
        model_change: struct {
            provider: []const u8,
            model_id: []const u8,
        },
        thinking_level_change: []const u8,
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

    fn appendMessage(self: *SessionManager, message: agent.AgentMessage, timestamp: []const u8) Error![]const u8 {
        const entry = try self.prepareMessageEntry(message, timestamp);
        errdefer self.deinitEntry(entry);
        return self.commitPreparedEntry(entry);
    }

    fn appendCompaction(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        timestamp: []const u8,
    ) Error![]const u8 {
        const entry = try self.prepareCompactionEntry(summary, first_kept_entry_id, tokens_before, timestamp);
        errdefer self.deinitEntry(entry);
        return self.commitPreparedEntry(entry);
    }

    /// Prepare/commit split lets the caller persist an entry durably before
    /// it becomes visible in memory (jsonl reaches disk before commit).
    fn ensureAppendCapacity(self: *SessionManager, additional_count: usize) Error!void {
        if (additional_count > max_session_entries - self.entries.items.len) return error.EntryLimitExceeded;
        try self.entries.ensureUnusedCapacity(self.allocator, additional_count);
    }

    pub fn prepareMessageEntry(
        self: *SessionManager,
        message: agent.AgentMessage,
        timestamp: []const u8,
    ) Error!SessionEntry {
        try self.ensureAppendCapacity(1);
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
        try self.ensureAppendCapacity(1);
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        return self.compactionEntryFromParts(base, summary, first_kept_entry_id, tokens_before);
    }

    pub fn prepareModelChangeEntry(
        self: *SessionManager,
        provider: []const u8,
        model_id: []const u8,
        timestamp: []const u8,
    ) Error!SessionEntry {
        try self.ensureAppendCapacity(1);
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        return self.modelChangeEntryFromParts(base, provider, model_id);
    }

    pub fn prepareThinkingLevelChangeEntry(
        self: *SessionManager,
        thinking_level: []const u8,
        timestamp: []const u8,
    ) Error!SessionEntry {
        try self.ensureAppendCapacity(1);
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        return self.thinkingLevelChangeEntryFromParts(base, thinking_level);
    }

    /// Single validation and construction site for compaction entries,
    /// shared by the live prepare path and the load path. Takes ownership
    /// of `base` only on success.
    fn compactionEntryFromParts(
        self: *SessionManager,
        base: SessionEntry.Base,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
    ) Error!SessionEntry {
        if (summary.len > max_compaction_summary_bytes) return error.CompactionSummaryTooLarge;
        if (first_kept_entry_id.len > max_compaction_first_kept_entry_id_bytes) {
            return error.CompactionFirstKeptEntryIdTooLarge;
        }
        if (self.findEntryIndex(first_kept_entry_id) == null) return error.CompactionFirstKeptEntryNotFound;
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

    fn modelChangeEntryFromParts(
        self: *SessionManager,
        base: SessionEntry.Base,
        provider: []const u8,
        model_id: []const u8,
    ) Error!SessionEntry {
        if (provider.len == 0 or provider.len > max_model_provider_bytes) return error.InvalidEntryId;
        if (model_id.len == 0 or model_id.len > max_model_id_bytes) return error.InvalidEntryId;
        const provider_copy = try self.allocator.dupe(u8, provider);
        errdefer self.allocator.free(provider_copy);
        const model_id_copy = try self.allocator.dupe(u8, model_id);
        return .{ .model_change = .{
            .base = base,
            .provider = provider_copy,
            .model_id = model_id_copy,
        } };
    }

    fn thinkingLevelChangeEntryFromParts(
        self: *SessionManager,
        base: SessionEntry.Base,
        thinking_level: []const u8,
    ) Error!SessionEntry {
        if (thinking_level.len == 0 or thinking_level.len > max_thinking_level_bytes) return error.InvalidEntryId;
        return .{ .thinking_level_change = .{
            .base = base,
            .thinking_level = try self.allocator.dupe(u8, thinking_level),
        } };
    }

    pub fn lastEntryId(self: *const SessionManager) ?[]const u8 {
        if (self.entries.items.len == 0) return null;
        return self.entries.items[self.entries.items.len - 1].id();
    }

    pub fn commitPreparedEntry(self: *SessionManager, entry: SessionEntry) []const u8 {
        std.debug.assert(self.entries.items.len < max_session_entries);
        var expected_id_buffer: [16]u8 = undefined;
        const expected_id = std.fmt.bufPrint(&expected_id_buffer, "{x:0>8}", .{self.next_id}) catch unreachable;
        std.debug.assert(std.mem.eql(u8, entry.id(), expected_id));
        self.entries.appendAssumeCapacity(entry);
        self.next_id += 1;
        return entry.id();
    }

    pub fn deinitPreparedEntry(self: *SessionManager, entry: SessionEntry) void {
        self.deinitEntry(entry);
    }

    /// Append one entry loaded from disk. The line's parent link must point
    /// at the previous entry: history is linear, and a duplicated or
    /// reordered line breaks that chain and is rejected. Ids are zi-written
    /// `{x:0>8}` hex; anything else is interior corruption and is rejected
    /// (a foreign id could collide with a generated one).
    fn appendLoadedEntry(
        self: *SessionManager,
        id: []const u8,
        parent_id: ?[]const u8,
        timestamp: []const u8,
        value: LoadedValue,
    ) Error!void {
        try self.ensureAppendCapacity(1);
        const numeric_id = std.fmt.parseInt(u64, id, 16) catch return error.InvalidEntryId;
        const last_id = self.lastEntryId();
        const linear = if (parent_id) |parent|
            last_id != null and std.mem.eql(u8, parent, last_id.?)
        else
            last_id == null;
        if (!linear) return error.EntryNotFound;

        const base: SessionEntry.Base = blk: {
            const id_copy = try self.allocator.dupe(u8, id);
            errdefer self.allocator.free(id_copy);
            break :blk .{ .id = id_copy, .timestamp = try self.allocator.dupe(u8, timestamp) };
        };
        var base_owned = true;
        errdefer if (base_owned) self.deinitBase(base);
        const entry: SessionEntry = switch (value) {
            .message => |message| .{ .message = .{
                .base = base,
                .message = try agent.copyAgentMessage(self.allocator, message),
            } },
            .compaction => |compaction| try self.compactionEntryFromParts(
                base,
                compaction.summary,
                compaction.first_kept_entry_id,
                compaction.tokens_before,
            ),
            .model_change => |model_change| try self.modelChangeEntryFromParts(
                base,
                model_change.provider,
                model_change.model_id,
            ),
            .thinking_level_change => |thinking_level| try self.thinkingLevelChangeEntryFromParts(
                base,
                thinking_level,
            ),
        };
        base_owned = false;
        // Capacity was reserved above, so this append cannot fail and the
        // entry has exactly one owner from here.
        self.entries.appendAssumeCapacity(entry);
        self.next_id = @max(self.next_id, numeric_id +| 1);
    }

    pub const ProjectedSessionIterator = struct {
        manager: *const SessionManager,
        next_index: usize,
        compaction_index: ?usize,
        emitted_summary: bool = false,

        fn init(manager: *const SessionManager) ProjectedSessionIterator {
            var latest_compaction_index: ?usize = null;
            for (manager.entries.items, 0..) |entry, index| {
                if (entry == .compaction) latest_compaction_index = index;
            }
            var start: usize = 0;
            if (latest_compaction_index) |index| {
                const compaction = manager.entries.items[index].compaction;
                start = manager.findEntryIndex(compaction.first_kept_entry_id) orelse index + 1;
            }
            return .{ .manager = manager, .next_index = start, .compaction_index = latest_compaction_index };
        }

        pub fn next(self: *ProjectedSessionIterator) ?ReconstructedSessionItem {
            if (!self.emitted_summary) {
                self.emitted_summary = true;
                if (self.compaction_index) |index| {
                    const compaction = self.manager.entries.items[index].compaction;
                    return .{
                        .entry_id = compaction.base.id,
                        .timestamp = compaction.base.timestamp,
                        .content = .{ .compaction_summary = .{
                            .summary = compaction.summary,
                            .tokens_before = compaction.tokens_before,
                        } },
                    };
                }
            }
            while (self.next_index < self.manager.entries.items.len) : (self.next_index += 1) {
                const entry = self.manager.entries.items[self.next_index];
                if (entry != .message) continue;
                self.next_index += 1;
                return .{
                    .entry_id = entry.message.base.id,
                    .timestamp = entry.message.base.timestamp,
                    .content = .{ .message = entry.message.message },
                };
            }
            return null;
        }
    };

    /// Project the entries into the agent's runtime context: the latest
    /// compaction summary (if any), the kept tail before it, then everything
    /// after it. The caller owns the returned messages.
    pub fn contextMessages(self: *const SessionManager, allocator: std.mem.Allocator) Error![]agent.AgentMessage {
        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer freeContextMessages(allocator, &messages);

        var projection = self.projectSession();
        while (projection.next()) |item| switch (item.content) {
            .compaction_summary => |summary| {
                const summary_text = try std.fmt.allocPrint(
                    allocator,
                    "The conversation history before this point was compacted into the following summary:\n\n" ++
                        "<summary>\n{s}\n</summary>",
                    .{summary.summary},
                );
                errdefer allocator.free(summary_text);
                try messages.append(allocator, .{ .user = .{
                    .content = .{ .string = summary_text },
                    .timestamp = 0,
                } });
            },
            .message => |message| {
                const copy = try agent.copyAgentMessage(allocator, message);
                errdefer agent.deinitAgentMessage(allocator, copy);
                try messages.append(allocator, copy);
            },
        };
        return messages.toOwnedSlice(allocator);
    }

    pub fn projectSession(self: *const SessionManager) ProjectedSessionIterator {
        return ProjectedSessionIterator.init(self);
    }

    /// Rebuild the durable session transcript view. The returned slice is owned
    /// by the caller; item payloads borrow from this manager.
    pub fn reconstructSession(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
    ) Error![]ReconstructedSessionItem {
        var items = std.ArrayList(ReconstructedSessionItem).empty;
        errdefer items.deinit(allocator);
        var projection = self.projectSession();
        while (projection.next()) |item| try items.append(allocator, item);
        return items.toOwnedSlice(allocator);
    }

    pub fn deinitContextMessages(allocator: std.mem.Allocator, messages: []const agent.AgentMessage) void {
        for (messages) |message| agent.deinitAgentMessage(allocator, message);
        allocator.free(messages);
    }

    pub fn sessionPreferences(self: *const SessionManager) SessionPreferences {
        var preferences: SessionPreferences = .{};
        for (self.entries.items) |entry| switch (entry) {
            .model_change => |model_change| preferences.model = .{
                .provider = model_change.provider,
                .model_id = model_change.model_id,
            },
            .thinking_level_change => |thinking| preferences.thinking_level = thinking.thinking_level,
            .message => |message_entry| switch (message_entry.message) {
                .assistant => |assistant| preferences.model = .{
                    .provider = assistant.provider,
                    .model_id = assistant.model,
                },
                .user, .tool_result, .custom => {},
            },
            .compaction => {},
        };
        return preferences;
    }

    /// Choose a compaction cut and gather the messages to summarize.
    /// Errors with NothingToCompact / AlreadyCompacted when there is no work.
    pub fn buildCompactionSummaryInput(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        settings: CompactionSettings,
    ) Error!CompactionSummaryInput {
        if (settings.keep_recent_tokens > max_compaction_keep_recent_tokens or
            settings.reserve_tokens > max_compaction_reserve_tokens)
        {
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
        const cut_point = findCompactionCutPoint(entries, boundary_start, entries.len, settings.keep_recent_tokens);
        const cut_index = cut_point.first_kept_index;
        if (cut_index <= boundary_start) return error.NothingToCompact;

        const history_end = if (cut_point.is_split_turn) cut_point.turn_start_index.? else cut_index;
        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer freeContextMessages(allocator, &messages);
        for (entries[boundary_start..history_end]) |entry| {
            if (entry != .message) continue;
            const copy = try agent.copyAgentMessage(allocator, entry.message.message);
            errdefer agent.deinitAgentMessage(allocator, copy);
            try messages.append(allocator, copy);
        }

        var turn_prefix_messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer freeContextMessages(allocator, &turn_prefix_messages);
        if (cut_point.is_split_turn) {
            for (entries[cut_point.turn_start_index.?..cut_index]) |entry| {
                if (entry != .message) continue;
                const copy = try agent.copyAgentMessage(allocator, entry.message.message);
                errdefer agent.deinitAgentMessage(allocator, copy);
                try turn_prefix_messages.append(allocator, copy);
            }
        }
        if (messages.items.len == 0 and turn_prefix_messages.items.len == 0) return error.NothingToCompact;

        const first_kept_entry_id = try allocator.dupe(u8, entries[cut_index].id());
        errdefer allocator.free(first_kept_entry_id);
        const previous_summary = if (previous_summary_text) |text| try allocator.dupe(u8, text) else null;
        errdefer if (previous_summary) |summary| allocator.free(summary);

        var tokens_before: u64 = 0;
        for (entries) |entry| tokens_before +|= estimateEntryTokens(entry);

        return .{
            .allocator = allocator,
            .messages = try messages.toOwnedSlice(allocator),
            .turn_prefix_messages = try turn_prefix_messages.toOwnedSlice(allocator),
            .is_split_turn = cut_point.is_split_turn,
            .previous_summary = previous_summary,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = tokens_before,
        };
    }

    const CompactionCutPoint = struct {
        first_kept_index: usize,
        turn_start_index: ?usize = null,
        is_split_turn: bool = false,
    };

    fn findCompactionCutPoint(
        entries: []const SessionEntry,
        start_index: usize,
        end_index: usize,
        keep_recent_tokens: u64,
    ) CompactionCutPoint {
        var first_valid_cut = start_index;
        while (first_valid_cut < end_index and !isValidCompactionCut(entries[first_valid_cut])) {
            first_valid_cut += 1;
        }
        if (first_valid_cut == end_index) return .{ .first_kept_index = start_index };

        var cut_index = first_valid_cut;
        var accumulated_tokens: u64 = 0;
        var index = end_index;
        while (index > start_index) {
            index -= 1;
            if (entries[index] != .message) continue;
            accumulated_tokens +|= estimateEntryTokens(entries[index]);
            if (accumulated_tokens >= keep_recent_tokens) {
                cut_index = first_valid_cut;
                for (entries[index..end_index], index..) |entry, candidate_index| {
                    if (isValidCompactionCut(entry)) {
                        cut_index = candidate_index;
                        break;
                    }
                }
                break;
            }
        }

        while (cut_index > start_index) {
            const previous = entries[cut_index - 1];
            if (previous == .compaction) break;
            if (previous == .message) break;
            cut_index -= 1;
        }

        const is_user_message = entries[cut_index] == .message and entries[cut_index].message.message == .user;
        if (is_user_message) return .{ .first_kept_index = cut_index };
        const turn_start_index = findCompactionTurnStartIndex(entries, cut_index, start_index) orelse
            return .{ .first_kept_index = cut_index };
        return .{ .first_kept_index = cut_index, .turn_start_index = turn_start_index, .is_split_turn = true };
    }

    fn findCompactionTurnStartIndex(entries: []const SessionEntry, entry_index: usize, start_index: usize) ?usize {
        var index = entry_index + 1;
        while (index > start_index) {
            index -= 1;
            const entry = entries[index];
            if (entry != .message) continue;
            switch (entry.message.message) {
                .user, .custom => return index,
                .assistant, .tool_result => {},
            }
        }
        return null;
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

    pub fn estimateEntryTokens(entry: SessionEntry) u64 {
        const chars: u64 = switch (entry) {
            .model_change, .thinking_level_change => 0,
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
        if (self.next_id == std.math.maxInt(u64)) return error.EntryLimitExceeded;
        const id = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{self.next_id});
        errdefer self.allocator.free(id);
        const timestamp_copy = try self.allocator.dupe(u8, timestamp);
        return .{ .id = id, .timestamp = timestamp_copy };
    }

    fn deinitEntry(self: *SessionManager, entry: SessionEntry) void {
        switch (entry) {
            .message => |message| {
                self.deinitBase(message.base);
                agent.deinitAgentMessage(self.allocator, message.message);
            },
            .compaction => |compaction| {
                self.deinitBase(compaction.base);
                self.allocator.free(compaction.summary);
                self.allocator.free(compaction.first_kept_entry_id);
            },
            .model_change => |model_change| {
                self.deinitBase(model_change.base);
                self.allocator.free(model_change.provider);
                self.allocator.free(model_change.model_id);
            },
            .thinking_level_change => |thinking| {
                self.deinitBase(thinking.base);
                self.allocator.free(thinking.thinking_level);
            },
        }
    }

    fn deinitBase(self: *SessionManager, base: SessionEntry.Base) void {
        self.allocator.free(base.id);
        self.allocator.free(base.timestamp);
    }
};

/// The jsonl file behind one session: header line, then one entry per line.
/// Append-only after creation; load truncates a torn trailing line so the
/// next append cannot glue onto it.
pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    dir: std.Io.Dir,
    file_name: []const u8,
    pending_header: ?SessionHeader = null,

    pub const CreateOptions = struct {
        /// Directory for the session file, created if missing; null writes
        /// the file directly into `dir`.
        sessions_dir: ?[]const u8 = null,
        cwd: []const u8,
        session_id: []const u8,
        timestamp: []const u8,
    };

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        options: CreateOptions,
    ) !SessionStore {
        var store = try createDeferred(allocator, io, dir, options);
        errdefer store.deinit();
        try store.ensureCreated(io);
        return store;
    }

    pub fn createDeferred(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        options: CreateOptions,
    ) !SessionStore {
        const file_name = blk: {
            const leaf_name = try paths_mod.sessionFileLeafName(allocator, options.timestamp, options.session_id);
            const sessions_dir = options.sessions_dir orelse break :blk leaf_name;
            defer allocator.free(leaf_name);
            try dir.createDirPath(io, sessions_dir);
            break :blk try std.fs.path.join(allocator, &.{ sessions_dir, leaf_name });
        };
        errdefer allocator.free(file_name);
        const id = try allocator.dupe(u8, options.session_id);
        errdefer allocator.free(id);
        const timestamp = try allocator.dupe(u8, options.timestamp);
        errdefer allocator.free(timestamp);
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);
        return .{
            .allocator = allocator,
            .dir = dir,
            .file_name = file_name,
            .pending_header = .{
                .id = id,
                .timestamp = timestamp,
                .cwd = cwd,
            },
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.allocator.free(self.file_name);
        if (self.pending_header) |header| {
            self.allocator.free(header.id);
            self.allocator.free(header.timestamp);
            self.allocator.free(header.cwd);
            if (header.parent_session) |parent_session| self.allocator.free(parent_session);
        }
        self.* = undefined;
    }

    /// Append one entry line. `parent_id` is the id of the previous entry
    /// (null for the first): the parent link is derived at the encoding
    /// boundary, not stored in the entry.
    pub fn appendEntry(
        self: *SessionStore,
        io: std.Io,
        entry: SessionEntry,
        parent_id: ?[]const u8,
    ) !void {
        try self.ensureCreated(io);
        const line = try formatEntryLine(self.allocator, entry, parent_id);
        defer self.allocator.free(line);
        try appendLine(io, self.dir, self.file_name, line);
    }

    pub fn load(self: SessionStore, io: std.Io) !SessionManager {
        const data = try self.dir.readFileAlloc(io, self.file_name, self.allocator, .limited(max_session_file_bytes));
        defer self.allocator.free(data);
        var parsed = try parseSession(self.allocator, data);
        if (parsed.repair_length) |length| {
            // The dropped torn line is still on disk. Truncate it away now,
            // or the next append glues onto the fragment and corrupts both
            // lines -- turning a recoverable tail into fatal interior damage.
            self.truncateTo(io, length) catch |err| {
                parsed.manager.deinit();
                return err;
            };
        }
        return parsed.manager;
    }

    fn truncateTo(self: SessionStore, io: std.Io, length: u64) !void {
        const file = try self.dir.openFile(io, self.file_name, .{ .mode = .read_write });
        defer file.close(io);
        try file.setLength(io, length);
    }

    fn ensureCreated(self: *SessionStore, io: std.Io) !void {
        const header = self.pending_header orelse return;
        const line = try formatHeaderLine(self.allocator, header);
        defer self.allocator.free(line);
        try writeFileAtomic(self.allocator, io, self.dir, self.file_name, line);
        self.pending_header = null;
        self.allocator.free(header.id);
        self.allocator.free(header.timestamp);
        self.allocator.free(header.cwd);
        if (header.parent_session) |parent_session| self.allocator.free(parent_session);
    }
};

fn writeFileAtomic(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    file_name: []const u8,
    data: []const u8,
) !void {
    const tmp_leaf = try std.fmt.allocPrint(allocator, ".{s}.tmp", .{std.fs.path.basename(file_name)});
    defer allocator.free(tmp_leaf);
    const tmp_name = if (std.fs.path.dirname(file_name)) |parent|
        try std.fs.path.join(allocator, &.{ parent, tmp_leaf })
    else
        try allocator.dupe(u8, tmp_leaf);
    defer allocator.free(tmp_name);
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = data });
    try std.Io.Dir.rename(dir, tmp_name, dir, file_name, io);
}

fn appendLine(io: std.Io, dir: std.Io.Dir, file_name: []const u8, line: []const u8) !void {
    if (line.len > max_session_line_bytes) return error.LineTooLong;
    const file = try dir.openFile(io, file_name, .{ .mode = .read_write });
    defer file.close(io);
    const offset = try file.length(io);
    // Keep the write bound coherent with the load bound: a session this
    // store writes must remain loadable by this store.
    if (offset + line.len > max_session_file_bytes) return error.SessionFileFull;
    try file.writePositionalAll(io, line, offset);
}

fn formatHeaderLine(allocator: std.mem.Allocator, header: SessionHeader) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"type\":\"session\",\"version\":");
    try writer.writer.print("{}", .{header.version});
    try writer.writer.writeAll(",\"id\":");
    try std.json.Stringify.value(header.id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(header.timestamp, .{}, &writer.writer);
    try writer.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(header.cwd, .{}, &writer.writer);
    if (header.parent_session) |parent_session| {
        try writer.writer.writeAll(",\"parentSession\":");
        try std.json.Stringify.value(parent_session, .{}, &writer.writer);
    }
    try writer.writer.writeAll("}\n");
    return writer.toOwnedSlice();
}

fn formatEntryLine(allocator: std.mem.Allocator, entry: SessionEntry, parent_id: ?[]const u8) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    switch (entry) {
        .message => |message| {
            try writeEntryBase("message", &writer.writer, message.base, parent_id);
            try writer.writer.writeAll(",\"message\":");
            try writeAgentMessage(&writer.writer, message.message);
        },
        .compaction => |compaction| {
            try writeEntryBase("compaction", &writer.writer, compaction.base, parent_id);
            try writer.writer.writeAll(",\"summary\":");
            try std.json.Stringify.value(compaction.summary, .{}, &writer.writer);
            try writer.writer.writeAll(",\"firstKeptEntryId\":");
            try std.json.Stringify.value(compaction.first_kept_entry_id, .{}, &writer.writer);
            try writer.writer.writeAll(",\"tokensBefore\":");
            try writer.writer.print("{}", .{compaction.tokens_before});
        },
        .model_change => |model_change| {
            try writeEntryBase("model_change", &writer.writer, model_change.base, parent_id);
            try writer.writer.writeAll(",\"provider\":");
            try std.json.Stringify.value(model_change.provider, .{}, &writer.writer);
            try writer.writer.writeAll(",\"modelId\":");
            try std.json.Stringify.value(model_change.model_id, .{}, &writer.writer);
        },
        .thinking_level_change => |thinking| {
            try writeEntryBase("thinking_level_change", &writer.writer, thinking.base, parent_id);
            try writer.writer.writeAll(",\"thinkingLevel\":");
            try std.json.Stringify.value(thinking.thinking_level, .{}, &writer.writer);
        },
    }
    try writer.writer.writeAll("}\n");
    return writer.toOwnedSlice();
}

fn writeEntryBase(
    comptime entry_type: []const u8,
    writer: *std.Io.Writer,
    base: SessionEntry.Base,
    parent_id: ?[]const u8,
) !void {
    try writer.writeAll("{\"type\":\"");
    try writer.writeAll(entry_type);
    try writer.writeAll("\",\"id\":");
    try std.json.Stringify.value(base.id, .{}, writer);
    try writer.writeAll(",\"parentId\":");
    if (parent_id) |parent| {
        try std.json.Stringify.value(parent, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(base.timestamp, .{}, writer);
}

fn writeAgentMessage(writer: *std.Io.Writer, message: agent.AgentMessage) !void {
    switch (message) {
        .custom => |custom| {
            try writer.writeAll("{\"role\":\"custom\",\"customType\":");
            try std.json.Stringify.value(custom.kind, .{}, writer);
            try writer.writeAll(",\"payload\":");
            try std.json.Stringify.value(custom.payload, .{}, writer);
            try writer.print(",\"timestamp\":{}", .{custom.timestamp});
            try writer.writeAll("}");
        },
        else => try std.json.Stringify.value(message, .{}, writer),
    }
}

const ParsedSession = struct {
    manager: SessionManager,
    /// When a torn trailing line was dropped: byte length of the good
    /// prefix. The file must be truncated to it before any append.
    repair_length: ?u64,
};

fn parseSession(allocator: std.mem.Allocator, data: []const u8) !ParsedSession {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header_line = lines.next() orelse return error.MissingHeader;
    var parsed_header = try runtime.JsonOwned(std.json.Value).parseJson(allocator, header_line, .{});
    defer parsed_header.deinit();
    const header = try jsonObject(parsed_header.value, error.InvalidHeader);
    if (!std.mem.eql(u8, try jsonString(header.get("type") orelse return error.InvalidHeader), "session")) {
        return error.InvalidHeader;
    }
    const version = try jsonInteger(header.get("version") orelse return error.InvalidHeader);
    if (version != current_session_version) return error.UnsupportedVersion;
    var manager = try SessionManager.init(
        allocator,
        try jsonString(header.get("cwd") orelse return error.InvalidHeader),
        try jsonString(header.get("id") orelse return error.InvalidHeader),
        try jsonString(header.get("timestamp") orelse return error.InvalidHeader),
    );
    errdefer manager.deinit();
    if (header.get("parentSession")) |parent_session| {
        manager.header.parent_session = try allocator.dupe(u8, try jsonString(parent_session));
    }

    var good_length: usize = @min(header_line.len + 1, data.len);
    while (lines.next()) |line| {
        const line_end = (@intFromPtr(line.ptr) - @intFromPtr(data.ptr)) + line.len;
        if (std.mem.trim(u8, line, " \t\r").len == 0) {
            good_length = @min(line_end + 1, data.len);
            continue;
        }
        if (line.len > max_session_line_bytes) return error.LineTooLong;
        parseEntryLine(allocator, &manager, line) catch |err| {
            if (err == error.OutOfMemory) return err;
            // A failing final line is a torn append from a crash: drop it
            // and keep what loaded. Interior corruption stays fatal.
            if (std.mem.trim(u8, lines.rest(), " \t\r\n").len == 0) {
                return .{ .manager = manager, .repair_length = good_length };
            }
            return err;
        };
        good_length = @min(line_end + 1, data.len);
    }
    return .{ .manager = manager, .repair_length = null };
}

fn parseEntryLine(allocator: std.mem.Allocator, manager: *SessionManager, line: []const u8) !void {
    var parsed = try runtime.JsonOwned(std.json.Value).parseJson(allocator, line, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value, error.InvalidEntry);
    const entry_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
    const id = try jsonString(object.get("id") orelse return error.InvalidEntry);
    const parent_id = try jsonOptionalString(object.get("parentId") orelse return error.InvalidEntry);
    const timestamp = try jsonString(object.get("timestamp") orelse return error.InvalidEntry);
    if (std.mem.eql(u8, entry_type, "message")) {
        const message = try parseMessage(allocator, object.get("message") orelse return error.InvalidEntry);
        defer deinitParsedMessageContainers(allocator, message);
        try manager.appendLoadedEntry(id, parent_id, timestamp, .{ .message = message });
    } else if (std.mem.eql(u8, entry_type, "compaction")) {
        try manager.appendLoadedEntry(id, parent_id, timestamp, .{ .compaction = .{
            .summary = try jsonString(object.get("summary") orelse return error.InvalidEntry),
            .first_kept_entry_id = try jsonString(object.get("firstKeptEntryId") orelse return error.InvalidEntry),
            .tokens_before = try jsonNonNegativeInteger(object.get("tokensBefore") orelse return error.InvalidEntry),
        } });
    } else if (std.mem.eql(u8, entry_type, "model_change")) {
        try manager.appendLoadedEntry(id, parent_id, timestamp, .{ .model_change = .{
            .provider = try jsonString(object.get("provider") orelse return error.InvalidEntry),
            .model_id = try jsonString(object.get("modelId") orelse return error.InvalidEntry),
        } });
    } else if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        try manager.appendLoadedEntry(
            id,
            parent_id,
            timestamp,
            .{ .thinking_level_change = try jsonString(object.get("thinkingLevel") orelse return error.InvalidEntry) },
        );
    } else {
        return error.InvalidEntry;
    }
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentMessage {
    const object = try jsonObject(value, error.InvalidEntry);
    const role = try jsonString(object.get("role") orelse return error.InvalidEntry);
    if (std.mem.eql(u8, role, "user")) {
        const raw_content = object.get("content") orelse return error.InvalidEntry;
        const content: ai.UserMessage.Content = switch (raw_content) {
            .string => |text| .{ .string = text },
            .array => |array| .{ .blocks = try parseUserContent(allocator, array.items) },
            else => return error.InvalidEntry,
        };
        errdefer switch (content) {
            .string => {},
            .blocks => |blocks| allocator.free(blocks),
        };
        return .{ .user = .{
            .content = content,
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        const content = try parseAssistantContent(
            allocator,
            try jsonArray(object.get("content") orelse return error.InvalidEntry),
        );
        errdefer allocator.free(content);
        return .{ .assistant = .{
            .content = content,
            .api = try jsonString(object.get("api") orelse return error.InvalidEntry),
            .provider = try jsonString(object.get("provider") orelse return error.InvalidEntry),
            .model = try jsonString(object.get("model") orelse return error.InvalidEntry),
            .response_id = try jsonOptionalFieldString(object.get("responseId")),
            .usage = try parseUsage(object.get("usage") orelse return error.InvalidEntry),
            .stop_reason = try parseStopReason(
                try jsonString(object.get("stopReason") orelse return error.InvalidEntry),
            ),
            .error_message = try jsonOptionalFieldString(object.get("errorMessage")),
            .operational_failure = try parseOperationalFailure(object.get("operationalFailure")),
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        const content = try parseToolResultContent(
            allocator,
            try jsonArray(object.get("content") orelse return error.InvalidEntry),
        );
        errdefer allocator.free(content);
        return .{ .tool_result = .{
            .tool_call_id = try jsonString(object.get("toolCallId") orelse return error.InvalidEntry),
            .tool_name = try jsonString(object.get("toolName") orelse return error.InvalidEntry),
            .content = content,
            .details = object.get("details"),
            .is_error = try jsonBool(object.get("isError") orelse return error.InvalidEntry),
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "custom")) {
        return .{ .custom = .{
            .kind = try jsonString(object.get("customType") orelse return error.InvalidEntry),
            .payload = object.get("payload") orelse return error.InvalidEntry,
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    return error.InvalidEntry;
}

fn parseUserContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.UserContent {
    const out = try allocator.alloc(ai.UserContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "image")) {
            content.* = .{ .image = try parseImageContent(object) };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseOperationalFailure(value: ?std.json.Value) !?ai.OperationalFailure {
    const object = try jsonObject(value orelse return null, error.InvalidEntry);
    return .{
        .category = try parseOperationalFailureCategory(try jsonString(object.get("category") orelse return error.InvalidEntry)),
        .message = boundedJsonString(
            try jsonString(object.get("message") orelse return error.InvalidEntry),
            ai.OperationalFailure.message_bytes_max,
        ),
        .detail = boundedOptionalJsonString(try jsonOptionalFieldString(object.get("detail")), ai.OperationalFailure.detail_bytes_max),
        .retryable = try parseOperationalFailureRetryable(try jsonString(object.get("retryable") orelse return error.InvalidEntry)),
        .provider = boundedOptionalJsonString(try jsonOptionalFieldString(object.get("provider")), max_model_provider_bytes),
        .model = boundedOptionalJsonString(try jsonOptionalFieldString(object.get("model")), max_model_id_bytes),
    };
}

fn boundedOptionalJsonString(text: ?[]const u8, max_bytes: usize) ?[]const u8 {
    const value = text orelse return null;
    return boundedJsonString(value, max_bytes);
}

fn boundedJsonString(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

fn parseOperationalFailureCategory(text: []const u8) !ai.OperationalFailure.Category {
    if (std.mem.eql(u8, text, "authMissing")) return .auth_missing;
    if (std.mem.eql(u8, text, "authRejected")) return .auth_rejected;
    if (std.mem.eql(u8, text, "rateLimited")) return .rate_limited;
    if (std.mem.eql(u8, text, "contextOverflow")) return .context_overflow;
    if (std.mem.eql(u8, text, "providerUnavailable")) return .provider_unavailable;
    if (std.mem.eql(u8, text, "transport")) return .transport;
    if (std.mem.eql(u8, text, "malformedResponse")) return .malformed_response;
    if (std.mem.eql(u8, text, "canceled")) return .canceled;
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    return error.InvalidEntry;
}

fn parseOperationalFailureRetryable(text: []const u8) !ai.OperationalFailure.Retryable {
    if (std.mem.eql(u8, text, "yes")) return .yes;
    if (std.mem.eql(u8, text, "no")) return .no;
    if (std.mem.eql(u8, text, "unknown")) return .unknown;
    return error.InvalidEntry;
}

fn parseAssistantContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.AssistantContent {
    const out = try allocator.alloc(ai.AssistantContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            content.* = .{ .thinking = .{
                .thinking = try jsonString(object.get("thinking") orelse return error.InvalidEntry),
                .thinking_signature = try jsonOptionalFieldString(object.get("thinkingSignature")),
                .redacted = if (object.get("redacted")) |redacted| try jsonBool(redacted) else false,
            } };
        } else if (std.mem.eql(u8, block_type, "toolCall")) {
            content.* = .{ .tool_call = .{
                .id = try jsonString(object.get("id") orelse return error.InvalidEntry),
                .name = try jsonString(object.get("name") orelse return error.InvalidEntry),
                .arguments = object.get("arguments") orelse return error.InvalidEntry,
                .thought_signature = try jsonOptionalFieldString(object.get("thoughtSignature")),
            } };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseToolResultContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.ToolResultContent {
    const out = try allocator.alloc(ai.ToolResultContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "image")) {
            content.* = .{ .image = try parseImageContent(object) };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseImageContent(object: std.json.ObjectMap) !ai.ImageContent {
    return .{
        .data = try jsonString(object.get("data") orelse return error.InvalidEntry),
        .mime_type = try jsonString(object.get("mimeType") orelse return error.InvalidEntry),
    };
}

fn parseUsage(value: std.json.Value) !ai.Usage {
    const object = try jsonObject(value, error.InvalidEntry);
    const cost = try jsonObject(object.get("cost") orelse return error.InvalidEntry, error.InvalidEntry);
    return .{
        .input = try jsonNonNegativeInteger(object.get("input") orelse return error.InvalidEntry),
        .output = try jsonNonNegativeInteger(object.get("output") orelse return error.InvalidEntry),
        .cache_read = try jsonNonNegativeInteger(object.get("cacheRead") orelse return error.InvalidEntry),
        .cache_write = try jsonNonNegativeInteger(object.get("cacheWrite") orelse return error.InvalidEntry),
        .total_tokens = try jsonNonNegativeInteger(object.get("totalTokens") orelse return error.InvalidEntry),
        .cost = .{
            .input = try jsonFloat(cost.get("input") orelse return error.InvalidEntry),
            .output = try jsonFloat(cost.get("output") orelse return error.InvalidEntry),
            .cache_read = try jsonFloat(cost.get("cacheRead") orelse return error.InvalidEntry),
            .cache_write = try jsonFloat(cost.get("cacheWrite") orelse return error.InvalidEntry),
            .total = try jsonFloat(cost.get("total") orelse return error.InvalidEntry),
        },
    };
}

fn parseStopReason(value: []const u8) !ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return error.InvalidEntry;
}

fn deinitParsedMessageContainers(allocator: std.mem.Allocator, message: agent.AgentMessage) void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => {},
            .blocks => |blocks| allocator.free(blocks),
        },
        .assistant => |assistant| allocator.free(assistant.content),
        .tool_result => |tool_result| allocator.free(tool_result.content),
        .custom => {},
    }
}

fn jsonObject(value: std.json.Value, err: anyerror) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => err,
    };
}

fn jsonArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidEntry,
    };
}

fn jsonOptionalFieldString(value: ?std.json.Value) !?[]const u8 {
    return if (value) |actual| try jsonOptionalString(actual) else null;
}

fn jsonInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |actual| actual,
        else => error.InvalidEntry,
    };
}

fn jsonNonNegativeInteger(value: std.json.Value) !u64 {
    const integer = try jsonInteger(value);
    if (integer < 0) return error.InvalidEntry;
    return @intCast(integer);
}

fn jsonBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |actual| actual,
        else => error.InvalidEntry,
    };
}

fn jsonFloat(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |actual| actual,
        .integer => |actual| @floatFromInt(actual),
        else => error.InvalidEntry,
    };
}

fn jsonOptionalString(value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidEntry,
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidEntry,
    };
}

fn userMessage(text: []const u8) agent.AgentMessage {
    return .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } };
}

fn assistantTextMessage(content: []const ai.AssistantContent) agent.AgentMessage {
    return .{ .assistant = .{
        .content = content,
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } };
}

test "new session stores header metadata" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "2026-01-01T00:00:00Z");
    defer manager.deinit();

    try std.testing.expectEqual(@as(u32, current_session_version), manager.header.version);
    try std.testing.expectEqualStrings("session-1", manager.header.id);
    try std.testing.expectEqualStrings("/repo", manager.header.cwd);
}

test "append entries assign sequential ids" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try std.testing.expectEqual(@as(?[]const u8, null), manager.lastEntryId());
    const first = try manager.appendMessage(userMessage("one"), "t1");
    _ = try manager.appendMessage(userMessage("two"), "t2");

    try std.testing.expectEqualStrings("00000001", first);
    try std.testing.expectEqualStrings("00000002", manager.entries.items[1].id());
    try std.testing.expectEqualStrings("00000002", manager.lastEntryId().?);
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

    const entry = try manager.prepareMessageEntry(userMessage("one"), "t1");
    var committed = false;
    errdefer if (!committed) manager.deinitPreparedEntry(entry);

    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);

    const id = manager.commitPreparedEntry(entry);
    committed = true;
    try std.testing.expectEqualStrings("00000001", id);
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "prepare rejects exhausted generated entry id" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();
    manager.next_id = std.math.maxInt(u64);

    try std.testing.expectError(error.EntryLimitExceeded, manager.prepareMessageEntry(userMessage("one"), "t1"));
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

test "compaction summary input splits oversized turn prefix" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const assistant_blocks = [_]ai.AssistantContent{.{ .text = .{ .text = "assistant suffix" } }};
    _ = try manager.appendMessage(userMessage("old history"), "t1");
    _ = try manager.appendMessage(userMessage("large turn request"), "t2");
    const kept = try manager.appendMessage(assistantTextMessage(&assistant_blocks), "t3");

    var input = try manager.buildCompactionSummaryInput(std.testing.allocator, .{ .keep_recent_tokens = 1 });
    defer input.deinit();

    try std.testing.expect(input.is_split_turn);
    try std.testing.expectEqual(@as(usize, 1), input.messages.len);
    try std.testing.expectEqual(@as(usize, 1), input.turn_prefix_messages.len);
    try std.testing.expectEqualStrings("old history", input.messages[0].user.content.string);
    try std.testing.expectEqualStrings("large turn request", input.turn_prefix_messages[0].user.content.string);
    try std.testing.expectEqualStrings(kept, input.first_kept_entry_id);
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
        "<conversation>\n" ++
            "[User]: question\n\n" ++
            "[Assistant thinking]: thought\n" ++
            "[Assistant]: answer\n" ++
            "[Assistant tool call]: read\n\n" ++
            "[Tool result]: tool output\n" ++
            "</conversation>\n" ++
            "\n<previous-summary>\n" ++
            "prior summary\n" ++
            "</previous-summary>\n",
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

    try manager.appendLoadedEntry("0000000a", null, "t1", .{ .message = userMessage("root") });
    try manager.appendLoadedEntry("0000000b", "0000000a", "t2", .{ .compaction = .{
        .summary = "summary",
        .first_kept_entry_id = "0000000a",
        .tokens_before = 100,
    } });
    _ = try manager.appendMessage(userMessage("next"), "t3");

    try std.testing.expectEqualStrings("0000000c", manager.entries.items[2].id());
}

test "loaded entries reject non linear parent links and foreign ids" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try manager.appendLoadedEntry("00000001", null, "t1", .{ .message = userMessage("root") });
    // Duplicate line: parent points at its own id's predecessor, not the tail.
    try std.testing.expectError(
        error.EntryNotFound,
        manager.appendLoadedEntry("00000001", null, "t1", .{ .message = userMessage("root") }),
    );
    try std.testing.expectError(
        error.EntryNotFound,
        manager.appendLoadedEntry("00000003", "missing", "t2", .{ .message = userMessage("orphan") }),
    );
    // A non-hex id could collide with a generated one later: reject it.
    try std.testing.expectError(
        error.InvalidEntryId,
        manager.appendLoadedEntry("not-hex", "00000001", "t2", .{ .message = userMessage("alien") }),
    );
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "loaded compaction entries enforce durable bounds" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try manager.appendLoadedEntry("00000001", null, "t1", .{ .message = userMessage("root") });
    const oversized_summary = try std.testing.allocator.alloc(u8, max_compaction_summary_bytes + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 'a');

    try std.testing.expectError(error.CompactionSummaryTooLarge, manager.appendLoadedEntry(
        "00000002",
        "00000001",
        "t2",
        .{ .compaction = .{
            .summary = oversized_summary,
            .first_kept_entry_id = "00000001",
            .tokens_before = 1,
        } },
    ));
    try std.testing.expectError(error.CompactionFirstKeptEntryNotFound, manager.appendLoadedEntry(
        "00000002",
        "00000001",
        "t2",
        .{ .compaction = .{
            .summary = "summary",
            .first_kept_entry_id = "missing",
            .tokens_before = 1,
        } },
    ));
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "session parser drops torn trailing line and reports the repair length" {
    const good_prefix =
        "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
        "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
        "{\"role\":\"user\",\"content\":\"hello\",\"timestamp\":0}}\n";
    var parsed = try parseSession(
        std.testing.allocator,
        good_prefix ++ "{\"type\":\"message\",\"id\":\"0000",
    );
    defer parsed.manager.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.manager.entries.items.len);
    try std.testing.expectEqual(@as(u64, good_prefix.len), parsed.repair_length.?);

    var clean = try parseSession(std.testing.allocator, good_prefix);
    defer clean.manager.deinit();
    try std.testing.expectEqual(@as(?u64, null), clean.repair_length);
}

test "session store load repairs torn trailing line before future appends" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();
    _ = try manager.appendMessage(userMessage("one"), "t1");
    try store.appendEntry(std.testing.io, manager.entries.items[0], null);

    // Simulate a crash mid-append: a torn fragment without trailing newline.
    {
        const file = try tmp.dir.openFile(std.testing.io, store.file_name, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        const offset = try file.length(std.testing.io);
        try file.writePositionalAll(std.testing.io, "{\"type\":\"message\",\"id\":\"00", offset);
    }

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 1), loaded.entries.items.len);

    // Without the on-load repair this append glues onto the fragment and
    // the file becomes unloadable (fatal interior corruption).
    _ = try loaded.appendMessage(userMessage("two"), "t2");
    try store.appendEntry(
        std.testing.io,
        loaded.entries.items[1],
        loaded.entries.items[0].id(),
    );

    var reloaded = try store.load(std.testing.io);
    defer reloaded.deinit();
    try std.testing.expectEqual(@as(usize, 2), reloaded.entries.items.len);
}

test "session store append rejects writes past the session file cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();
    _ = try manager.appendMessage(userMessage("one"), "t1");

    // Grow the file sparsely to the cap; any further append must be refused
    // so the session this store writes stays loadable by this store.
    {
        const file = try tmp.dir.openFile(std.testing.io, store.file_name, .{ .mode = .read_write });
        defer file.close(std.testing.io);
        try file.writePositionalAll(std.testing.io, "x", max_session_file_bytes - 1);
    }

    try std.testing.expectError(
        error.SessionFileFull,
        store.appendEntry(std.testing.io, manager.entries.items[0], null),
    );
}

const valid_user_line =
    "{\"type\":\"message\",\"id\":\"00000002\",\"parentId\":\"00000001\",\"timestamp\":\"t\"," ++
    "\"message\":{\"role\":\"user\",\"content\":\"next\",\"timestamp\":0}}\n";

test "session parser rejects malformed interior json shapes" {
    try std.testing.expectError(error.InvalidHeader, parseSession(std.testing.allocator, "[]\n"));
    // A malformed line followed by more content is interior corruption.
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n[]\n" ++
                valid_user_line,
        ),
    );
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
                "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
                "{\"role\":\"assistant\",\"content\":123}}\n" ++ valid_user_line,
        ),
    );
}

test "session parser rejects interior parent chain breaks" {
    // The second line claims a parent that is not the tail; a valid line
    // follows, so this is interior corruption, not a torn tail.
    try std.testing.expectError(
        error.EntryNotFound,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
                "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
                "{\"role\":\"user\",\"content\":\"root\",\"timestamp\":0}}\n" ++
                "{\"type\":\"message\",\"id\":\"00000002\",\"parentId\":\"wrong\",\"timestamp\":\"t\"," ++
                "\"message\":{\"role\":\"user\",\"content\":\"broken\",\"timestamp\":0}}\n" ++
                "{\"type\":\"message\",\"id\":\"00000003\",\"parentId\":\"00000002\",\"timestamp\":\"t\"," ++
                "\"message\":{\"role\":\"user\",\"content\":\"after\",\"timestamp\":0}}\n",
        ),
    );
}

test "session parser rejects interior negative usage" {
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
                "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
                "{\"role\":\"assistant\",\"content\":[],\"api\":\"openai-responses\",\"provider\":\"openai\"," ++
                "\"model\":\"gpt\",\"usage\":{\"input\":-1,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0," ++
                "\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0," ++
                "\"total\":0}},\"stopReason\":\"stop\",\"timestamp\":0}}\n" ++ valid_user_line,
        ),
    );
}

test "session store creates header file and loads empty manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("session-1", loaded.header.id);
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

test "session store creates the sessions directory when asked" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .sessions_dir = "agent/sessions/--repo--",
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();

    try std.testing.expectEqualStrings("agent/sessions/--repo--/t0_session-1.jsonl", store.file_name);
    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();
    try std.testing.expectEqualStrings("session-1", loaded.header.id);
}

test "session store appends entries and round trips context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("hello"), "t1");
    try store.appendEntry(std.testing.io, manager.entries.items[0], null);
    _ = try manager.appendMessage(userMessage("again"), "t2");
    try store.appendEntry(
        std.testing.io,
        manager.entries.items[1],
        manager.entries.items[0].id(),
    );

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();
    const messages = try loaded.contextMessages(std.testing.allocator);
    defer SessionManager.deinitContextMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 2), messages.len);
    try std.testing.expectEqualStrings("hello", messages[0].user.content.string);
    try std.testing.expectEqualStrings("again", messages[1].user.content.string);
}

test "session store round trips agent message variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(.{ .user = .{
        .content = .{ .blocks = &.{.{ .text = .{ .text = "hello" } }} },
        .timestamp = 11,
    } }, "t1");
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &.{
            .{ .text = .{ .text = "hi" } },
            .{ .thinking = .{ .thinking = "hmm", .redacted = true } },
            .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = .{ .object = .empty } } },
        },
        .api = ai.KnownApi.anthropic_messages,
        .provider = "anthropic",
        .model = "claude",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .error_,
        .error_message = "MissingApiKey",
        .operational_failure = .{
            .category = .auth_missing,
            .message = "Missing provider API key",
            .detail = "MissingApiKey",
            .retryable = .no,
            .provider = "anthropic",
            .model = "claude",
        },
        .timestamp = 12,
    } }, "t2");
    _ = try manager.appendMessage(.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "ok" } }},
        .details = .{ .string = "detail" },
        .is_error = false,
        .timestamp = 13,
    } }, "t3");
    _ = try manager.appendMessage(.{ .custom = .{
        .kind = "extension",
        .payload = .{ .string = "payload" },
        .timestamp = 14,
    } }, "t4");
    for (manager.entries.items, 0..) |entry, index| {
        const parent = if (index == 0) null else manager.entries.items[index - 1].id();
        try store.appendEntry(std.testing.io, entry, parent);
    }

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();
    const messages = try loaded.contextMessages(std.testing.allocator);
    defer SessionManager.deinitContextMessages(std.testing.allocator, messages);

    try std.testing.expectEqual(@as(usize, 4), messages.len);
    try std.testing.expectEqualStrings("hello", messages[0].user.content.blocks[0].text.text);
    try std.testing.expectEqualStrings("hi", messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("call-1", messages[1].assistant.content[2].tool_call.id);
    const failure = messages[1].assistant.operational_failure.?;
    try std.testing.expectEqual(ai.OperationalFailure.Category.auth_missing, failure.category);
    try std.testing.expectEqual(ai.OperationalFailure.Retryable.no, failure.retryable);
    try std.testing.expectEqualStrings("Missing provider API key", failure.message);
    try std.testing.expectEqualStrings("MissingApiKey", failure.detail.?);
    try std.testing.expectEqualStrings("ok", messages[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("extension", messages[3].custom.kind);

    const reconstructed = try loaded.reconstructSession(std.testing.allocator);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqual(@as(usize, 4), reconstructed.len);
    try std.testing.expectEqualStrings("00000002", reconstructed[1].entry_id);
    try std.testing.expect(reconstructed[1].content == .message);
    try std.testing.expectEqualStrings("call-1", reconstructed[1].content.message.assistant.content[2].tool_call.id);
    try std.testing.expectEqual(ai.OperationalFailure.Category.auth_missing, reconstructed[1].content.message.assistant.operational_failure.?.category);
    try std.testing.expect(reconstructed[2].content == .message);
    try std.testing.expectEqualStrings("call-1", reconstructed[2].content.message.tool_result.tool_call_id);
    try std.testing.expectEqualStrings("ok", reconstructed[2].content.message.tool_result.content[0].text.text);
}

test "session store load preserves entry ids and continues id generation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("root"), "t1");
    try store.appendEntry(std.testing.io, manager.entries.items[0], null);
    const child = try manager.appendMessage(userMessage("child"), "t2");
    try store.appendEntry(std.testing.io, manager.entries.items[1], root);

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqualStrings(root, loaded.entries.items[0].id());
    try std.testing.expectEqualStrings(child, loaded.entries.items[1].id());

    _ = try loaded.appendMessage(userMessage("next"), "t3");
    try std.testing.expectEqualStrings("00000003", loaded.entries.items[2].id());
}

test "session store round trips compaction entries" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, .{
        .cwd = "/repo",
        .session_id = "session-1",
        .timestamp = "t0",
    });
    defer store.deinit();
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const old = try manager.appendMessage(userMessage("old"), "t1");
    try store.appendEntry(std.testing.io, manager.entries.items[0], null);
    const kept = try manager.appendMessage(userMessage("kept"), "t2");
    try store.appendEntry(std.testing.io, manager.entries.items[1], old);
    _ = try manager.appendCompaction("summary", kept, 2048, "t3");
    try store.appendEntry(std.testing.io, manager.entries.items[2], kept);

    var loaded = try store.load(std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqual(@as(usize, 3), loaded.entries.items.len);
    try std.testing.expectEqualStrings("summary", loaded.entries.items[2].compaction.summary);
    try std.testing.expectEqualStrings(kept, loaded.entries.items[2].compaction.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 2048), loaded.entries.items[2].compaction.tokens_before);

    const reconstructed = try loaded.reconstructSession(std.testing.allocator);
    defer std.testing.allocator.free(reconstructed);
    try std.testing.expectEqual(@as(usize, 2), reconstructed.len);
    try std.testing.expect(reconstructed[0].content == .compaction_summary);
    try std.testing.expectEqualStrings("summary", reconstructed[0].content.compaction_summary.summary);
    try std.testing.expect(reconstructed[1].content == .message);
    try std.testing.expectEqualStrings("kept", reconstructed[1].content.message.user.content.string);
}
