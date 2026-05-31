const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");

pub const current_session_version = 3;
pub const max_session_entries = 16_384;
pub const max_branch_depth = 16_384;
pub const max_compaction_summary_bytes = 256 * 1024;
pub const max_compaction_first_kept_entry_id_bytes = 128;
pub const max_compaction_keep_recent_tokens = 1_000_000;

pub const SessionHeader = struct {
    version: u32 = current_session_version,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    parent_session: ?[]const u8 = null,
};

pub const ModelRef = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const SessionContext = struct {
    messages: []const agent.AgentMessage,
    thinking_level: []const u8,
    model: ?ModelRef,
};

pub const CompactionSettings = struct {
    keep_recent_tokens: u64 = 20_000,

    pub fn validate(self: CompactionSettings) error{CompactionSettingsOutOfBounds}!void {
        if (self.keep_recent_tokens > max_compaction_keep_recent_tokens) return error.CompactionSettingsOutOfBounds;
    }
};

pub const CompactionPreparation = struct {
    allocator: std.mem.Allocator,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    summarize_start_index: usize,
    summarize_end_index: usize,
    previous_summary: ?[]const u8 = null,

    pub fn deinit(self: *CompactionPreparation) void {
        self.allocator.free(self.first_kept_entry_id);
        if (self.previous_summary) |summary| self.allocator.free(summary);
        self.* = undefined;
    }
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

pub const SessionManager = struct {
    allocator: std.mem.Allocator,
    header: SessionHeader,
    entries: std.ArrayList(SessionEntry) = .empty,
    leaf_id: ?[]const u8 = null,
    next_id: u64 = 1,

    pub const Error = error{
        EntryLimitExceeded,
        BranchDepthExceeded,
        EntryNotFound,
        DuplicateEntryId,
        AlreadyCompacted,
        NothingToCompact,
        CompactionSummaryTooLarge,
        CompactionFirstKeptEntryIdTooLarge,
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
            model_change: ModelRef,
            compaction: Compaction,

            pub const Compaction = struct {
                summary: []const u8,
                first_kept_entry_id: []const u8,
                tokens_before: u64,
            };
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

    pub fn commitPreparedEntry(self: *SessionManager, entry: SessionEntry) []const u8 {
        std.debug.assert(self.entries.items.len < max_session_entries);
        const id = entry.id();
        self.entries.appendAssumeCapacity(entry);
        self.leaf_id = id;
        self.next_id += 1;
        return id;
    }

    pub fn deinitPreparedEntry(self: *SessionManager, entry: SessionEntry) void {
        self.deinitEntry(entry);
    }

    pub fn appendThinkingLevelChange(
        self: *SessionManager,
        thinking_level: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
        const base = try self.nextBase(timestamp);
        const entry: SessionEntry = blk: {
            errdefer self.deinitBase(base);
            break :blk .{ .thinking_level_change = .{
                .base = base,
                .thinking_level = try self.allocator.dupe(u8, thinking_level),
            } };
        };
        errdefer self.deinitEntry(entry);
        return self.appendEntry(entry);
    }

    pub fn appendModelChange(
        self: *SessionManager,
        provider: []const u8,
        model_id: []const u8,
        timestamp: []const u8,
    ) Error![]const u8 {
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
        errdefer self.deinitEntry(entry);
        return self.appendEntry(entry);
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

    pub fn prepareCompactionEntry(
        self: *SessionManager,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        timestamp: []const u8,
    ) Error!SessionEntry {
        try validateCompactionInput(summary, first_kept_entry_id);
        const base = try self.nextBase(timestamp);
        errdefer self.deinitBase(base);
        return blk: {
            const summary_copy = try self.allocator.dupe(u8, summary);
            errdefer self.allocator.free(summary_copy);
            const first_kept_entry_id_copy = try self.allocator.dupe(u8, first_kept_entry_id);
            break :blk .{ .compaction = .{
                .base = base,
                .summary = summary_copy,
                .first_kept_entry_id = first_kept_entry_id_copy,
                .tokens_before = tokens_before,
            } };
        };
    }

    pub fn appendLoadedEntry(self: *SessionManager, loaded: LoadedEntry) Error![]const u8 {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        if (self.findEntry(loaded.id) != null) return error.DuplicateEntryId;
        if (loaded.parent_id) |parent_id| {
            if (self.findEntry(parent_id) == null) return error.EntryNotFound;
        } else if (self.entries.items.len > 0) {
            return error.EntryNotFound;
        }
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
                try validateCompactionInput(compaction.summary, compaction.first_kept_entry_id);
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
        var next_id = self.next_id;
        if (std.fmt.parseInt(u64, loaded.id, 16)) |numeric_id| {
            const after_loaded_id = if (numeric_id == std.math.maxInt(u64)) numeric_id else numeric_id + 1;
            next_id = @max(next_id, after_loaded_id);
        } else |_| {}
        const appended_id = try self.appendEntry(entry);
        self.next_id = next_id;
        return appended_id;
    }

    pub fn branch(self: *SessionManager, id: []const u8) Error!void {
        self.leaf_id = (try self.getEntry(id)).id();
    }

    pub fn resetLeaf(self: *SessionManager) void {
        self.leaf_id = null;
    }

    pub fn getEntry(self: *const SessionManager, id: []const u8) Error!*const SessionEntry {
        return self.findEntry(id) orelse error.EntryNotFound;
    }

    pub fn getLeafEntry(self: *const SessionManager) Error!?*const SessionEntry {
        return if (self.leaf_id) |id| try self.getEntry(id) else null;
    }

    pub fn getTree(self: *const SessionManager) []const SessionEntry {
        return self.entries.items;
    }

    pub fn getChildren(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        parent_id: ?[]const u8,
    ) Error![]const SessionEntry {
        var children = std.ArrayList(SessionEntry).empty;
        errdefer children.deinit(allocator);
        for (self.entries.items) |entry| {
            const entry_parent_id = entry.parentId();
            const matches = if (parent_id) |expected|
                entry_parent_id != null and std.mem.eql(u8, entry_parent_id.?, expected)
            else
                entry_parent_id == null;
            if (matches) try children.append(allocator, entry);
        }
        return children.toOwnedSlice(allocator);
    }

    pub fn getBranch(self: *const SessionManager, allocator: std.mem.Allocator) Error![]const SessionEntry {
        return self.getBranchFrom(allocator, self.leaf_id);
    }

    pub fn getBranchFrom(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        leaf_id: ?[]const u8,
    ) Error![]const SessionEntry {
        var path = std.ArrayList(SessionEntry).empty;
        errdefer path.deinit(allocator);
        var current_id = leaf_id;
        var depth: usize = 0;
        while (current_id) |id| {
            if (depth == max_branch_depth) return error.BranchDepthExceeded;
            const entry = self.findEntry(id) orelse return error.EntryNotFound;
            try path.append(allocator, entry.*);
            current_id = entry.parentId();
            depth += 1;
        }
        std.mem.reverse(SessionEntry, path.items);
        return path.toOwnedSlice(allocator);
    }

    pub fn buildSessionContext(self: *const SessionManager, allocator: std.mem.Allocator) Error!SessionContext {
        const branch_entries = try self.getBranch(allocator);
        defer allocator.free(branch_entries);

        var messages = std.ArrayList(agent.AgentMessage).empty;
        errdefer {
            for (messages.items) |message| agent.deinitAgentMessage(allocator, message);
            messages.deinit(allocator);
        }
        var thinking_level: []const u8 = "off";
        var model: ?ModelRef = null;
        var latest_compaction_index: ?usize = null;

        for (branch_entries, 0..) |entry, index| {
            switch (entry) {
                .message => |message_entry| {
                    if (message_entry.message == .assistant) {
                        model = .{
                            .provider = message_entry.message.assistant.provider,
                            .model_id = message_entry.message.assistant.model,
                        };
                    }
                },
                .thinking_level_change => |thinking| thinking_level = thinking.thinking_level,
                .model_change => |model_change| model = .{
                    .provider = model_change.provider,
                    .model_id = model_change.model_id,
                },
                .compaction => latest_compaction_index = index,
            }
        }

        if (latest_compaction_index) |compaction_index| {
            const compaction = branch_entries[compaction_index].compaction;
            try appendContextMessage(
                allocator,
                &messages,
                try compactionSummaryMessage(allocator, compaction),
            );

            var found_first_kept = false;
            for (branch_entries[0..compaction_index]) |entry| {
                if (std.mem.eql(u8, entry.id(), compaction.first_kept_entry_id)) found_first_kept = true;
                if (found_first_kept) switch (entry) {
                    .message => |message_entry| try appendContextMessageCopy(
                        allocator,
                        &messages,
                        message_entry.message,
                    ),
                    else => {},
                };
            }

            for (branch_entries[compaction_index + 1 ..]) |entry| {
                switch (entry) {
                    .message => |message_entry| try appendContextMessageCopy(
                        allocator,
                        &messages,
                        message_entry.message,
                    ),
                    else => {},
                }
            }
        } else {
            for (branch_entries) |entry| {
                switch (entry) {
                    .message => |message_entry| try appendContextMessageCopy(
                        allocator,
                        &messages,
                        message_entry.message,
                    ),
                    else => {},
                }
            }
        }

        return .{
            .messages = try messages.toOwnedSlice(allocator),
            .thinking_level = thinking_level,
            .model = model,
        };
    }

    pub fn prepareCompaction(
        self: *const SessionManager,
        allocator: std.mem.Allocator,
        settings: CompactionSettings,
    ) Error!CompactionPreparation {
        try settings.validate();
        const branch_entries = try self.getBranch(allocator);
        defer allocator.free(branch_entries);
        if (branch_entries.len == 0) return error.NothingToCompact;
        if (branch_entries[branch_entries.len - 1] == .compaction) return error.AlreadyCompacted;

        var previous_compaction_index: ?usize = null;
        var index = branch_entries.len;
        while (index > 0) {
            index -= 1;
            if (branch_entries[index] == .compaction) {
                previous_compaction_index = index;
                break;
            }
        }

        var boundary_start: usize = 0;
        var previous_summary: ?[]const u8 = null;
        if (previous_compaction_index) |compaction_index| {
            const compaction = branch_entries[compaction_index].compaction;
            previous_summary = try allocator.dupe(u8, compaction.summary);
            errdefer if (previous_summary) |summary| allocator.free(summary);
            boundary_start = findEntryIndex(branch_entries, compaction.first_kept_entry_id) orelse
                compaction_index + 1;
        }

        const first_kept_index = findCompactionCutPoint(
            branch_entries,
            boundary_start,
            branch_entries.len,
            settings.keep_recent_tokens,
        );
        if (first_kept_index <= boundary_start) return error.NothingToCompact;

        const first_kept_entry_id = try allocator.dupe(u8, branch_entries[first_kept_index].id());
        errdefer allocator.free(first_kept_entry_id);

        return .{
            .allocator = allocator,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = estimateBranchTokens(branch_entries),
            .summarize_start_index = boundary_start,
            .summarize_end_index = first_kept_index,
            .previous_summary = previous_summary,
        };
    }

    fn validateCompactionInput(summary: []const u8, first_kept_entry_id: []const u8) Error!void {
        if (summary.len > max_compaction_summary_bytes) return error.CompactionSummaryTooLarge;
        if (first_kept_entry_id.len > max_compaction_first_kept_entry_id_bytes) {
            return error.CompactionFirstKeptEntryIdTooLarge;
        }
    }

    pub fn deinitSessionContext(_: *const SessionManager, allocator: std.mem.Allocator, context: SessionContext) void {
        for (context.messages) |message| agent.deinitAgentMessage(allocator, message);
        allocator.free(context.messages);
    }

    fn compactionSummaryMessage(
        allocator: std.mem.Allocator,
        compaction: SessionEntry.Compaction,
    ) std.mem.Allocator.Error!agent.AgentMessage {
        const text = try std.fmt.allocPrint(
            allocator,
            "The conversation history before this point was compacted into the following summary:\n\n" ++
                "<summary>\n{s}\n</summary>",
            .{compaction.summary},
        );
        errdefer allocator.free(text);
        return .{ .user = .{
            .content = .{ .string = text },
            .timestamp = 0,
        } };
    }

    fn appendContextMessage(
        allocator: std.mem.Allocator,
        messages: *std.ArrayList(agent.AgentMessage),
        message: agent.AgentMessage,
    ) std.mem.Allocator.Error!void {
        errdefer agent.deinitAgentMessage(allocator, message);
        try messages.append(allocator, message);
    }

    fn appendContextMessageCopy(
        allocator: std.mem.Allocator,
        messages: *std.ArrayList(agent.AgentMessage),
        message: agent.AgentMessage,
    ) std.mem.Allocator.Error!void {
        try appendContextMessage(allocator, messages, try agent.copyAgentMessage(allocator, message));
    }

    fn findCompactionCutPoint(
        entries: []const SessionEntry,
        start_index: usize,
        end_index: usize,
        keep_recent_tokens: u64,
    ) usize {
        var first_valid_cut = start_index;
        while (first_valid_cut < end_index and !isValidCompactionCut(entries[first_valid_cut])) {
            first_valid_cut += 1;
        }
        if (first_valid_cut == end_index) return start_index;

        var accumulated_tokens: u64 = 0;
        var cut_index = first_valid_cut;
        var index = end_index;
        while (index > start_index) {
            index -= 1;
            if (entries[index] != .message) continue;
            accumulated_tokens +|= estimateEntryTokens(entries[index]);
            if (accumulated_tokens >= keep_recent_tokens) {
                cut_index = firstValidCutAtOrAfter(entries, index, end_index) orelse first_valid_cut;
                break;
            }
        }
        return cut_index;
    }

    fn firstValidCutAtOrAfter(entries: []const SessionEntry, start_index: usize, end_index: usize) ?usize {
        for (entries[start_index..end_index], start_index..) |entry, index| {
            if (isValidCompactionCut(entry)) return index;
        }
        return null;
    }

    fn isValidCompactionCut(entry: SessionEntry) bool {
        return switch (entry) {
            .message => |message_entry| message_entry.message != .tool_result,
            else => false,
        };
    }

    fn estimateBranchTokens(entries: []const SessionEntry) u64 {
        var tokens: u64 = 0;
        for (entries) |entry| tokens +|= estimateEntryTokens(entry);
        return tokens;
    }

    fn estimateEntryTokens(entry: SessionEntry) u64 {
        return switch (entry) {
            .message => |message_entry| estimateMessageTokens(message_entry.message),
            .compaction => |compaction| estimateTextTokens(compaction.summary),
            else => 0,
        };
    }

    fn estimateMessageTokens(message: agent.AgentMessage) u64 {
        const chars: u64 = switch (message) {
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
        };
        return (chars + 3) / 4;
    }

    fn estimateTextTokens(text: []const u8) u64 {
        return (text.len + 3) / 4;
    }

    fn findEntryIndex(entries: []const SessionEntry, entry_id: []const u8) ?usize {
        for (entries, 0..) |entry, index| {
            if (std.mem.eql(u8, entry.id(), entry_id)) return index;
        }
        return null;
    }

    fn nextBase(self: *SessionManager, timestamp: []const u8) Error!SessionEntry.Base {
        if (self.entries.items.len == max_session_entries) return error.EntryLimitExceeded;
        if (self.next_id == std.math.maxInt(u64)) return error.EntryLimitExceeded;
        const id = try std.fmt.allocPrint(self.allocator, "{x:0>8}", .{self.next_id});
        errdefer self.allocator.free(id);
        const parent_id = if (self.leaf_id) |leaf_id| try self.allocator.dupe(u8, leaf_id) else null;
        errdefer if (parent_id) |value| self.allocator.free(value);
        const timestamp_copy = try self.allocator.dupe(u8, timestamp);
        return .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = timestamp_copy,
        };
    }

    fn appendEntry(self: *SessionManager, entry: SessionEntry) Error![]const u8 {
        const id = entry.id();
        try self.entries.append(self.allocator, entry);
        self.leaf_id = id;
        self.next_id += 1;
        return id;
    }

    fn findEntry(self: *const SessionManager, id: []const u8) ?*const SessionEntry {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.id(), id)) return entry;
        }
        return null;
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

fn assistantMessage(provider: []const u8, model: []const u8) agent.AgentMessage {
    return .{ .assistant = .{
        .content = &.{},
        .api = ai.KnownApi.openai_responses,
        .provider = provider,
        .model = model,
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
    try std.testing.expect(manager.leaf_id == null);
}

test "append entries create parent linked branch" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const first = try manager.appendMessage(userMessage("one"), "t1");
    const second = try manager.appendThinkingLevelChange("high", "t2");

    try std.testing.expectEqualStrings(first, manager.entries.items[1].parentId().?);
    try std.testing.expectEqualStrings(second, manager.leaf_id.?);
}

test "append compaction stores durable summary entry" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("before"), "t1");
    const compacted = try manager.appendCompaction("summary", root, 1200, "t2");

    try std.testing.expectEqualStrings(root, manager.entries.items[1].parentId().?);
    try std.testing.expectEqualStrings(compacted, manager.leaf_id.?);
    try std.testing.expectEqualStrings("summary", manager.entries.items[1].compaction.summary);
    try std.testing.expectEqualStrings(root, manager.entries.items[1].compaction.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 1200), manager.entries.items[1].compaction.tokens_before);
}

test "append compaction enforces bounded owned fields before mutation" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("before"), "t1");
    const oversized_summary = try std.testing.allocator.alloc(u8, max_compaction_summary_bytes + 1);
    defer std.testing.allocator.free(oversized_summary);
    @memset(oversized_summary, 'a');

    try std.testing.expectError(
        error.CompactionSummaryTooLarge,
        manager.appendCompaction(oversized_summary, root, 1, "t2"),
    );
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);

    const oversized_id = try std.testing.allocator.alloc(u8, max_compaction_first_kept_entry_id_bytes + 1);
    defer std.testing.allocator.free(oversized_id);
    @memset(oversized_id, 'b');

    try std.testing.expectError(
        error.CompactionFirstKeptEntryIdTooLarge,
        manager.appendCompaction("summary", oversized_id, 1, "t2"),
    );
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "prepared message entry does not mutate active leaf before commit" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try manager.ensureAppendCapacity(1);
    const entry = try manager.prepareMessageEntry(userMessage("one"), "t1");
    var committed = false;
    errdefer if (!committed) manager.deinitPreparedEntry(entry);

    try std.testing.expect(manager.leaf_id == null);
    try std.testing.expectEqual(@as(usize, 0), manager.entries.items.len);

    const id = manager.commitPreparedEntry(entry);
    committed = true;
    try std.testing.expectEqualStrings("00000001", id);
    try std.testing.expectEqualStrings(id, manager.leaf_id.?);
}

test "build context follows active leaf" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendModelChange("openai", "gpt", "t1");
    _ = try manager.appendThinkingLevelChange("medium", "t2");
    _ = try manager.appendMessage(userMessage("hello"), "t3");
    _ = try manager.appendMessage(assistantMessage("anthropic", "claude"), "t4");

    const context = try manager.buildSessionContext(std.testing.allocator);
    defer manager.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("medium", context.thinking_level);
    try std.testing.expectEqualStrings("anthropic", context.model.?.provider);
    try std.testing.expectEqualStrings("claude", context.model.?.model_id);
}

test "branching preserves old entries and appends from selected leaf" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("root"), "t1");
    _ = try manager.appendMessage(userMessage("main"), "t2");
    try manager.branch(root);
    _ = try manager.appendMessage(userMessage("branch"), "t3");

    const context = try manager.buildSessionContext(std.testing.allocator);
    defer manager.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 2), context.messages.len);
    try std.testing.expectEqualStrings("root", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("branch", context.messages[1].user.content.string);
    try std.testing.expectEqual(@as(usize, 3), manager.entries.items.len);
}

test "build context projects latest compaction summary then kept messages" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("dropped"), "t1");
    const kept = try manager.appendMessage(userMessage("kept"), "t2");
    _ = try manager.appendCompaction("older summary", kept, 3000, "t3");
    _ = try manager.appendMessage(userMessage("after"), "t4");

    const context = try manager.buildSessionContext(std.testing.allocator);
    defer manager.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 3), context.messages.len);
    try std.testing.expect(std.mem.indexOf(u8, context.messages[0].user.content.string, "older summary") != null);
    try std.testing.expectEqualStrings("kept", context.messages[1].user.content.string);
    try std.testing.expectEqualStrings("after", context.messages[2].user.content.string);
}

test "prepare compaction rejects empty small and already compacted branches" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try std.testing.expectError(
        error.NothingToCompact,
        manager.prepareCompaction(std.testing.allocator, .{ .keep_recent_tokens = 1 }),
    );

    const root = try manager.appendMessage(userMessage("abcd"), "t1");
    try std.testing.expectError(
        error.NothingToCompact,
        manager.prepareCompaction(std.testing.allocator, .{ .keep_recent_tokens = 100 }),
    );

    _ = try manager.appendCompaction("summary", root, 1, "t2");
    try std.testing.expectError(
        error.AlreadyCompacted,
        manager.prepareCompaction(std.testing.allocator, .{ .keep_recent_tokens = 1 }),
    );
}

test "prepare compaction rejects out of bounds settings" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("aaaaaaaa"), "t1");
    _ = try manager.appendMessage(userMessage("bbbbbbbb"), "t2");

    try std.testing.expectError(
        error.CompactionSettingsOutOfBounds,
        manager.prepareCompaction(std.testing.allocator, .{
            .keep_recent_tokens = max_compaction_keep_recent_tokens + 1,
        }),
    );
}

test "prepare compaction keeps bounded recent suffix" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(userMessage("aaaaaaaa"), "t1");
    _ = try manager.appendMessage(userMessage("bbbbbbbb"), "t2");
    const kept = try manager.appendMessage(userMessage("cccccccc"), "t3");

    var preparation = try manager.prepareCompaction(std.testing.allocator, .{ .keep_recent_tokens = 2 });
    defer preparation.deinit();

    try std.testing.expectEqualStrings(kept, preparation.first_kept_entry_id);
    try std.testing.expectEqual(@as(usize, 0), preparation.summarize_start_index);
    try std.testing.expectEqual(@as(usize, 2), preparation.summarize_end_index);
    try std.testing.expectEqual(@as(u64, 6), preparation.tokens_before);
    try std.testing.expect(preparation.previous_summary == null);
}

test "prepare compaction reuses previous first kept boundary" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("aaaaaaaa"), "t1");
    _ = try manager.appendCompaction("prior", root, 2, "t2");
    _ = try manager.appendMessage(userMessage("bbbbbbbb"), "t3");
    const kept = try manager.appendMessage(userMessage("cccccccc"), "t4");

    var preparation = try manager.prepareCompaction(std.testing.allocator, .{ .keep_recent_tokens = 2 });
    defer preparation.deinit();

    try std.testing.expectEqualStrings(kept, preparation.first_kept_entry_id);
    try std.testing.expectEqual(@as(usize, 0), preparation.summarize_start_index);
    try std.testing.expectEqual(@as(usize, 3), preparation.summarize_end_index);
    try std.testing.expectEqualStrings("prior", preparation.previous_summary.?);
}

test "tree navigation returns entries leaf and children" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(userMessage("root"), "t1");
    const left = try manager.appendMessage(userMessage("left"), "t2");
    try manager.branch(root);
    const right = try manager.appendMessage(userMessage("right"), "t3");

    try std.testing.expectEqual(@as(usize, 3), manager.getTree().len);
    try std.testing.expectEqualStrings(right, (try manager.getLeafEntry()).?.id());
    try std.testing.expectEqualStrings(left, (try manager.getEntry(left)).id());

    const children = try manager.getChildren(std.testing.allocator, root);
    defer std.testing.allocator.free(children);
    try std.testing.expectEqual(@as(usize, 2), children.len);
    try std.testing.expectEqualStrings(left, children[0].id());
    try std.testing.expectEqualStrings(right, children[1].id());
}

test "loaded entries preserve ids parent links and next generated id" {
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
    try std.testing.expectEqual(@as(usize, 1), manager.entries.items.len);
}

test "loaded entries reject duplicate ids and missing parents" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t1",
        .value = .{ .message = userMessage("root") },
    });
    try std.testing.expectError(error.DuplicateEntryId, manager.appendLoadedEntry(.{
        .id = "00000001",
        .parent_id = null,
        .timestamp = "t2",
        .value = .{ .message = userMessage("duplicate") },
    }));
    try std.testing.expectError(error.EntryNotFound, manager.appendLoadedEntry(.{
        .id = "00000002",
        .parent_id = "missing",
        .timestamp = "t2",
        .value = .{ .message = userMessage("orphan") },
    }));
}

test "branch rejects unknown entry" {
    var manager = try SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    try std.testing.expectError(error.EntryNotFound, manager.branch("missing"));
}
