const std = @import("std");
const ai = @import("../ai/root.zig");
const agent_message = @import("../agent/message.zig");
const json_value = @import("../json/value.zig");

pub const CURRENT_SESSION_VERSION: u32 = 3;
pub const event_id_byte_len: usize = 16;
pub const event_id_hex_len: usize = event_id_byte_len * 2;

pub const EventId = [event_id_hex_len]u8;

pub fn randomEventId(random: std.Random) EventId {
    var bytes: [event_id_byte_len]u8 = undefined;
    random.bytes(&bytes);
    return std.fmt.bytesToHex(bytes, .lower);
}

pub const Header = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
    version: u32 = CURRENT_SESSION_VERSION,
    parent_session: ?[]const u8 = null,
};

pub const Event = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
    payload: Event.Payload,

    pub const Payload = union(enum) {
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
    message: agent_message.AgentMessage,
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
    details: ?json_value.OwnedValue = null,
    from_hook: ?bool = null,
};

pub const BranchSummaryEntry = struct {
    from_id: []const u8,
    summary: []const u8,
    details: ?json_value.OwnedValue = null,
    from_hook: ?bool = null,
};

pub const CustomEntry = struct {
    custom_type: []const u8,
    data: ?json_value.OwnedValue = null,
};

pub const CustomMessageEntry = struct {
    custom_type: []const u8,
    content: agent_message.AgentMessage.CustomContent,
    details: ?json_value.OwnedValue = null,
    display: bool,
    include_in_context: bool = true,
};

pub const LabelEntry = struct {
    target_id: []const u8,
    label: ?[]const u8,
};

pub const SessionInfoEntry = struct {
    name: ?[]const u8 = null,
};

pub const FileEntry = union(enum) {
    header: Header,
    event: Event,
};

pub const Payload = Event.Payload;

pub const PayloadKind = enum {
    message,
    thinking_level_change,
    model_change,
    compaction,
    branch_summary,
    custom,
    custom_message,
    label,
    session_info,
};

pub fn payloadKind(payload: Payload) PayloadKind {
    return switch (payload) {
        .message => .message,
        .thinking_level_change => .thinking_level_change,
        .model_change => .model_change,
        .compaction => .compaction,
        .branch_summary => .branch_summary,
        .custom => .custom,
        .custom_message => .custom_message,
        .label => .label,
        .session_info => .session_info,
    };
}

pub fn payloadKindTag(kind: PayloadKind) []const u8 {
    return @tagName(kind);
}

pub fn payloadKindFromTag(tag: []const u8) !PayloadKind {
    inline for (@typeInfo(PayloadKind).@"enum".fields) |field| {
        if (std.mem.eql(u8, tag, field.name)) return @field(PayloadKind, field.name);
    }
    return error.UnknownEntryType;
}
