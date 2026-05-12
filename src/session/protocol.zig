const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");

pub const CURRENT_SESSION_VERSION: u32 = 3;

pub const SessionHeader = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    version: u32 = CURRENT_SESSION_VERSION,
    parent_session: ?[]const u8 = null,
};

pub const SessionEntry = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    entry: EntryType,

    pub const EntryType = union(enum) {
        message: MessageEntry,
        thinking_level_change: ThinkingLevelChangeEntry,
        model_change: ModelChangeEntry,
        compaction: CompactionEntry,
        branch_summary: BranchSummaryEntry,
        custom: CustomEntry,
        custom_message: CustomMessageEntry,
        label: LabelEntry,
        session_info: SessionInfoEntry,
    };
};

pub const MessageEntry = struct {
    message: agent.protocol.AgentMessage,
};

pub const ThinkingLevelChangeEntry = struct {
    thinking_level: []const u8,
};

pub const ModelChangeEntry = struct {
    provider: []const u8,
    model_id: []const u8,
};

pub const CompactionEntry = struct {
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    details: ?std.json.Value = null,
    from_hook: ?bool = null,
};

pub const BranchSummaryEntry = struct {
    from_id: []const u8,
    summary: []const u8,
    details: ?std.json.Value = null,
    from_hook: ?bool = null,
};

pub const CustomEntry = struct {
    custom_type: []const u8,
    data: ?std.json.Value = null,
};

pub const CustomMessageEntry = struct {
    custom_type: []const u8,
    content: agent.protocol.AgentMessage.CustomContent,
    details: ?std.json.Value = null,
    display: bool,
};

pub const LabelEntry = struct {
    target_id: []const u8,
    label: ?[]const u8,
};

pub const SessionInfoEntry = struct {
    name: ?[]const u8 = null,
};

pub const FileEntry = union(enum) {
    header: SessionHeader,
    entry: SessionEntry,
};
