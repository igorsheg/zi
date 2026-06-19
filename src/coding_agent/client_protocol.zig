//! Typed client protocol for the session mailbox: commands in, sequenced
//! event envelopes out. Every payload here is owned; deinit takes the
//! allocator that created it (no allocator is embedded in payloads).

const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const message_policy = @import("message_policy.zig");
const session_manager = @import("session_manager.zig");

pub const RequestId = u64;
pub const OperationId = u64;
pub const EventSeq = u64;

pub const command_queue_capacity_default = 64;
pub const event_queue_capacity_default = 256;
pub const retained_event_count_default = 256;
pub const retained_event_bytes_default = 512 * 1024;
pub const replay_event_count_max = 64;
pub const snapshot_history_items_max = 512;
pub const snapshot_history_item_text_bytes_max = 16 * 1024;
pub const snapshot_history_total_text_bytes_max = 128 * 1024;
const history_tool_id_bytes_max = 256;
const history_tool_name_bytes_max = 128;
pub const history_page_items_max = 64;
pub const history_page_item_text_bytes_max = snapshot_history_item_text_bytes_max;
pub const history_page_total_text_bytes_max = 64 * 1024;
pub const snapshot_model_text_bytes_max = 256;
/// Mirrors current TUI picker caps without importing TUI into the core protocol.
pub const completion_item_count_max = 384;
pub const completion_id_bytes_max = 128;
pub const completion_label_bytes_max = 160;
pub const completion_detail_bytes_max = 160;

pub const CommandQueue = runtime.BoundedQueue(CommandEnvelope);
pub const EventQueue = runtime.BoundedQueue(EventEnvelope);

pub const CommandEnvelope = struct {
    id: ?RequestId = null,
    command: ClientCommand,

    pub fn initSubmitPrompt(
        allocator: std.mem.Allocator,
        id: ?RequestId,
        text: []const u8,
        mode: Submit.Mode,
    ) !CommandEnvelope {
        return .{ .id = id, .command = .{ .submit = .{ .text = try allocator.dupe(u8, text), .mode = mode } } };
    }

    pub fn initHistoryPage(
        allocator: std.mem.Allocator,
        id: ?RequestId,
        before_entry_id: []const u8,
    ) !CommandEnvelope {
        return .{ .id = id, .command = .{ .history_page = .{
            .before_entry_id = try allocator.dupe(u8, before_entry_id),
        } } };
    }

    pub fn initSwitchSession(
        allocator: std.mem.Allocator,
        id: ?RequestId,
        session_file_name: []const u8,
    ) !CommandEnvelope {
        return .{ .id = id, .command = .{ .switch_session = .{
            .session_file_name = try allocator.dupe(u8, session_file_name),
        } } };
    }

    pub fn deinit(self: *CommandEnvelope, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientCommand = union(enum) {
    submit: Submit,
    cancel: Cancel,
    queue: QueueCommand,
    snapshot,
    completion_snapshot,
    replay: ReplayRequest,
    history_page: HistoryPageRequest,
    switch_session: SwitchSession,
    shutdown,

    pub fn deinit(self: *ClientCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submit => |prompt| allocator.free(prompt.text),
            .history_page => |request| allocator.free(request.before_entry_id),
            .switch_session => |request| allocator.free(request.session_file_name),
            .cancel, .queue, .snapshot, .completion_snapshot, .replay, .shutdown => {},
        }
        self.* = undefined;
    }
};

pub const Submit = struct {
    text: []u8,
    mode: Mode = .auto,

    pub const Mode = enum { auto, start, enqueue, steer };
};

pub const Cancel = struct {
    target: Target = .active,

    pub const Target = union(enum) {
        active,
        request_id: RequestId,
        operation_id: OperationId,
    };
};

pub const QueueCommand = union(enum) {
    clear,
};

pub const ReplayRequest = struct {
    after: EventSeq,
};

pub const HistoryPageRequest = struct {
    before_entry_id: []u8,
};

pub const SwitchSession = struct {
    session_file_name: []u8,
};

pub const EventEnvelope = struct {
    seq: EventSeq = 0,
    request_id: ?RequestId = null,
    operation_id: ?OperationId = null,
    event: ClientEvent,

    pub fn deinit(self: *EventEnvelope, allocator: std.mem.Allocator) void {
        self.event.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventEnvelope, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("seq", stringify, self.seq);
        if (self.request_id) |id| try writeJsonField("id", stringify, id);
        if (self.operation_id) |id| try writeJsonField("operationId", stringify, id);
        try writeJsonField("event", stringify, self.event);
        try stringify.endObject();
    }
};

pub const ClientEvent = union(enum) {
    rejected: Rejection,
    operation_started,
    operation_finished: OperationFinished,
    shutdown_started,
    agent_event: OwnedAgentEvent,
    queue_changed: QueueChanged,
    snapshot: Snapshot,
    completion_snapshot: CompletionSnapshot,
    replay: ReplayBatch,
    replay_gap: ReplayGap,
    history_page: HistoryPage,
    prompt_command: PromptCommand,
    session_changed,
    session_chrome: SessionChromeSnapshot,
    compaction_start: CompactionStart,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,
    event_overflow: EventOverflow,

    pub fn deinit(self: *ClientEvent, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .rejected => |*rejection| rejection.message.deinit(allocator),
            .agent_event => |*payload| payload.deinit(allocator),
            .snapshot => |*payload| payload.deinit(allocator),
            .completion_snapshot => |*payload| payload.deinit(allocator),
            .replay => |*payload| payload.deinit(allocator),
            .history_page => |*payload| payload.deinit(allocator),
            .prompt_command => |*payload| payload.deinit(allocator),
            .session_chrome => |*payload| payload.deinit(allocator),
            .compaction_end => |*payload| payload.deinit(allocator),
            .auto_retry_start => |*payload| payload.error_message.deinit(allocator),
            .auto_retry_end => |*payload| if (payload.final_error) |*err| err.deinit(allocator),
            .operation_started,
            .operation_finished,
            .session_changed,
            .shutdown_started,
            .queue_changed,
            .replay_gap,
            .compaction_start,
            .event_overflow,
            => {},
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: ClientEvent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .agent_event => |event| try stringify.write(event),
            .snapshot => |payload| try stringify.write(payload),
            .history_page => |payload| try stringify.write(payload),
            .replay => |payload| try stringify.write(payload),
            inline .shutdown_started, .operation_started, .session_changed => |_, tag| try writeObject(
                @tagName(tag),
                stringify,
                .{},
            ),
            inline else => |payload, tag| try writeObject(@tagName(tag), stringify, payload),
        }
    }
};

pub const Rejection = struct {
    code: Code,
    message: EventText,

    pub const Code = enum {
        busy,
        queue_full,
        invalid_command,
        /// The host ran out of a resource (e.g. memory); the command itself
        /// was well-formed and may succeed if retried later.
        exhausted,
        /// A reply could not be delivered in-band (e.g. too large to encode).
        overflow,
    };
};

pub const OperationFinished = struct {
    reason: Reason,

    pub const Reason = enum {
        completed,
        canceled,
        failed,
    };
};

/// Reply to a slash command intercepted at the mailbox boundary. The text
/// is a session fact for display; it never reaches the model or the prompt
/// queues.
pub const PromptCommandSessionStats = struct {
    user_messages: usize = 0,
    assistant_messages: usize = 0,
    tool_calls: usize = 0,
    tool_results: usize = 0,
    total_messages: usize = 0,
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cache_read_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    total_tokens: u64 = 0,
    cost: f64 = 0,
};

pub const PromptCommandSessionInfo = struct {
    file: ?EventText,
    id: EventText,
    user_messages: usize,
    assistant_messages: usize,
    tool_calls: usize,
    tool_results: usize,
    total_messages: usize,
    input_tokens: u64,
    output_tokens: u64,
    cache_read_tokens: u64,
    cache_write_tokens: u64,
    total_tokens: u64,
    cost: f64,

    pub fn init(
        allocator: std.mem.Allocator,
        file: ?[]const u8,
        id: []const u8,
        stats: PromptCommandSessionStats,
    ) !PromptCommandSessionInfo {
        var file_text: ?EventText = if (file) |text| try EventText.init(allocator, text) else null;
        errdefer if (file_text) |*text| text.deinit(allocator);
        const id_text = try EventText.init(allocator, id);
        return .{
            .file = file_text,
            .id = id_text,
            .user_messages = stats.user_messages,
            .assistant_messages = stats.assistant_messages,
            .tool_calls = stats.tool_calls,
            .tool_results = stats.tool_results,
            .total_messages = stats.total_messages,
            .input_tokens = stats.input_tokens,
            .output_tokens = stats.output_tokens,
            .cache_read_tokens = stats.cache_read_tokens,
            .cache_write_tokens = stats.cache_write_tokens,
            .total_tokens = stats.total_tokens,
            .cost = stats.cost,
        };
    }

    pub fn deinit(self: *PromptCommandSessionInfo, allocator: std.mem.Allocator) void {
        if (self.file) |*file| file.deinit(allocator);
        self.id.deinit(allocator);
        self.* = undefined;
    }
};

pub const PromptCommand = struct {
    command: EventText,
    result: Result,
    /// Bounded fallback text for simple clients. Rich clients should prefer
    /// typed payload fields when present.
    message: EventText,
    presentation: Presentation = .status,
    session_info: ?PromptCommandSessionInfo = null,

    pub const Result = enum { handled, unknown, failed };
    pub const Presentation = enum { status, transcript };

    pub fn deinit(self: *PromptCommand, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.message.deinit(allocator);
        if (self.session_info) |*info| info.deinit(allocator);
        self.* = undefined;
    }
};

pub const EventText = struct {
    text: []const u8,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !EventText {
        return .{ .text = try allocator.dupe(u8, text) };
    }

    pub fn deinit(self: *EventText, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventText, stringify: *std.json.Stringify) !void {
        try stringify.write(self.text);
    }
};

pub const EventTextList = struct {
    items: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const []const u8) !EventTextList {
        const items = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer for (items[0..initialized]) |item| allocator.free(item);
        for (source) |text| {
            items[initialized] = try allocator.dupe(u8, text);
            initialized += 1;
        }
        return .{ .items = items };
    }

    pub fn deinit(self: *EventTextList, allocator: std.mem.Allocator) void {
        for (self.items) |item| allocator.free(item);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventTextList, stringify: *std.json.Stringify) !void {
        try stringify.beginArray();
        for (self.items) |item| try stringify.write(item);
        try stringify.endArray();
    }
};

pub const CompactionResult = struct {
    summary: EventText,
    first_kept_entry_id: EventText,
    tokens_before: u64,

    pub fn init(
        allocator: std.mem.Allocator,
        entry: session_manager.SessionEntry.Compaction,
    ) !CompactionResult {
        var summary = try EventText.init(allocator, entry.summary);
        errdefer summary.deinit(allocator);
        return .{
            .summary = summary,
            .first_kept_entry_id = try EventText.init(allocator, entry.first_kept_entry_id),
            .tokens_before = entry.tokens_before,
        };
    }

    pub fn deinit(self: *CompactionResult, allocator: std.mem.Allocator) void {
        self.summary.deinit(allocator);
        self.first_kept_entry_id.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompactionResult, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const OwnedAgentEvent = struct {
    event: agent_mod.AgentEvent,

    pub fn init(allocator: std.mem.Allocator, event: agent_mod.AgentEvent) !OwnedAgentEvent {
        return .{ .event = try agent_mod.copyAgentEvent(allocator, event) };
    }

    pub fn deinit(self: *OwnedAgentEvent, allocator: std.mem.Allocator) void {
        agent_mod.deinitAgentEvent(allocator, self.event);
        self.* = undefined;
    }

    pub fn jsonStringify(self: OwnedAgentEvent, stringify: *std.json.Stringify) !void {
        try stringify.write(self.event);
    }
};

pub const QueueChanged = struct {
    steering_count: usize,
    follow_up_count: usize,
    revision: u64,
};

pub const CompactionReason = enum {
    threshold,
    overflow,
};

pub const CompactionStart = struct {
    reason: CompactionReason,
};

pub const CompactionEnd = struct {
    reason: CompactionReason,
    result: ?CompactionResult = null,
    aborted: bool,
    will_retry: bool,
    error_message: ?EventText = null,

    pub fn deinit(self: *CompactionEnd, allocator: std.mem.Allocator) void {
        if (self.result) |*result| result.deinit(allocator);
        if (self.error_message) |*message| message.deinit(allocator);
        self.* = undefined;
    }
};

pub const AutoRetryStart = struct {
    attempt: usize,
    max_attempts: usize,
    delay_ms: u64,
    error_message: EventText,
};

pub const AutoRetryEnd = struct {
    success: bool,
    attempt: usize,
    final_error: ?EventText = null,
};

pub const EventOverflow = struct {
    dropped_count: usize,
};

pub const RetainedEvent = struct {
    seq: EventSeq,
    json: EventText,

    pub const Source = struct {
        seq: EventSeq,
        json: []const u8,
    };
};

pub const ReplayBatch = struct {
    requested_after: EventSeq,
    first_retained_seq: EventSeq,
    last_retained_seq: EventSeq,
    events: []RetainedEvent,

    pub fn init(
        allocator: std.mem.Allocator,
        requested_after: EventSeq,
        first_retained_seq: EventSeq,
        last_retained_seq: EventSeq,
        source: []const RetainedEvent.Source,
    ) !ReplayBatch {
        const events = try allocator.alloc(RetainedEvent, source.len);
        errdefer allocator.free(events);
        var initialized: usize = 0;
        errdefer for (events[0..initialized]) |*event| event.json.deinit(allocator);
        for (source) |event| {
            events[initialized] = .{
                .seq = event.seq,
                .json = try EventText.init(allocator, event.json),
            };
            initialized += 1;
        }
        return .{
            .requested_after = requested_after,
            .first_retained_seq = first_retained_seq,
            .last_retained_seq = last_retained_seq,
            .events = events,
        };
    }

    pub fn deinit(self: *ReplayBatch, allocator: std.mem.Allocator) void {
        for (self.events) |*event| event.json.deinit(allocator);
        allocator.free(self.events);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ReplayBatch, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "replay");
        try writeJsonField("requestedAfter", stringify, self.requested_after);
        try writeJsonField("firstRetainedSeq", stringify, self.first_retained_seq);
        try writeJsonField("lastRetainedSeq", stringify, self.last_retained_seq);
        try stringify.objectField("events");
        try stringify.beginArray();
        for (self.events, 0..) |event, index| {
            if (index != 0) try stringify.writer.writeByte(',');
            try stringify.writer.writeAll(event.json.text);
        }
        try stringify.endArray();
        try stringify.endObject();
    }
};

pub const ReplayGap = struct {
    requested_after: EventSeq,
    first_retained_seq: EventSeq,
    last_retained_seq: EventSeq,
};

pub const CompletionItem = struct {
    id: EventText,
    label: EventText,
    detail: EventText,

    pub const Source = struct {
        id: []const u8,
        label: []const u8,
        detail: []const u8 = "",
    };

    pub fn init(allocator: std.mem.Allocator, source: Source) !CompletionItem {
        var id = try EventText.init(allocator, utf8Prefix(source.id, completion_id_bytes_max));
        errdefer id.deinit(allocator);
        var label = try EventText.init(allocator, utf8Prefix(source.label, completion_label_bytes_max));
        errdefer label.deinit(allocator);
        return .{
            .id = id,
            .label = label,
            .detail = try EventText.init(allocator, utf8Prefix(source.detail, completion_detail_bytes_max)),
        };
    }

    pub fn deinit(self: *CompletionItem, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.label.deinit(allocator);
        self.detail.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompletionItem, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const CompletionList = struct {
    items: []CompletionItem,
    truncated: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        source: []const CompletionItem.Source,
        source_truncated: bool,
    ) !CompletionList {
        const keep = @min(source.len, completion_item_count_max);
        const items = try allocator.alloc(CompletionItem, keep);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer for (items[0..initialized]) |*item| item.deinit(allocator);
        for (source[0..keep]) |item| {
            items[initialized] = try CompletionItem.init(allocator, item);
            initialized += 1;
        }
        return .{
            .items = items,
            .truncated = source_truncated or source.len > keep,
        };
    }

    pub fn deinit(self: *CompletionList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompletionList, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const CompletionSnapshot = struct {
    models: CompletionList,
    resume_sessions: CompletionList,

    pub fn init(
        allocator: std.mem.Allocator,
        model_items: []const CompletionItem.Source,
        models_truncated: bool,
        resume_items: []const CompletionItem.Source,
        resume_truncated: bool,
    ) !CompletionSnapshot {
        var models = try CompletionList.init(allocator, model_items, models_truncated);
        errdefer models.deinit(allocator);
        return .{
            .models = models,
            .resume_sessions = try CompletionList.init(allocator, resume_items, resume_truncated),
        };
    }

    pub fn deinit(self: *CompletionSnapshot, allocator: std.mem.Allocator) void {
        self.models.deinit(allocator);
        self.resume_sessions.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompletionSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject("completion_snapshot", stringify, self);
    }
};

pub const Snapshot = struct {
    header: SessionHeaderSnapshot,
    model: ModelSnapshot,
    thinking_level: agent_mod.ThinkingLevel,
    context: ContextUsageSnapshot,
    queue: QueueSnapshot,
    active_request_id: ?RequestId,
    history: HistorySnapshot,

    pub fn deinit(self: *Snapshot, allocator: std.mem.Allocator) void {
        self.header.deinit(allocator);
        self.model.deinit(allocator);
        self.queue.deinit(allocator);
        self.history.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: Snapshot, stringify: *std.json.Stringify) !void {
        try writeObject("snapshot", stringify, self);
    }
};

pub const SessionHeaderSnapshot = struct {
    version: u32,
    id: EventText,
    timestamp: EventText,
    cwd: EventText,
    parent_session: ?EventText = null,

    pub fn init(allocator: std.mem.Allocator, header: session_manager.SessionHeader) !SessionHeaderSnapshot {
        var id = try EventText.init(allocator, header.id);
        errdefer id.deinit(allocator);
        var timestamp = try EventText.init(allocator, header.timestamp);
        errdefer timestamp.deinit(allocator);
        var cwd = try EventText.init(allocator, header.cwd);
        errdefer cwd.deinit(allocator);
        const parent_session: ?EventText = if (header.parent_session) |parent|
            try EventText.init(allocator, parent)
        else
            null;
        return .{
            .id = id,
            .timestamp = timestamp,
            .cwd = cwd,
            .parent_session = parent_session,
            .version = header.version,
        };
    }

    pub fn deinit(self: *SessionHeaderSnapshot, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.timestamp.deinit(allocator);
        self.cwd.deinit(allocator);
        if (self.parent_session) |*parent| parent.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SessionHeaderSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const ModelSnapshot = struct {
    provider: EventText,
    id: EventText,

    pub fn init(allocator: std.mem.Allocator, model: ai.Model) !ModelSnapshot {
        var provider = try EventText.init(allocator, utf8Prefix(model.provider, snapshot_model_text_bytes_max));
        errdefer provider.deinit(allocator);
        return .{
            .provider = provider,
            .id = try EventText.init(allocator, utf8Prefix(model.id, snapshot_model_text_bytes_max)),
        };
    }

    pub fn deinit(self: *ModelSnapshot, allocator: std.mem.Allocator) void {
        self.provider.deinit(allocator);
        self.id.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: ModelSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const ContextUsageSnapshot = struct {
    tokens: ?u64 = null,
    window: u64 = 0,
    percent_tenths: ?u32 = null,

    pub fn jsonStringify(self: ContextUsageSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const SessionChromeSnapshot = struct {
    cwd: EventText,
    model: ModelSnapshot,
    thinking_level: agent_mod.ThinkingLevel,
    context: ContextUsageSnapshot,

    pub fn init(
        allocator: std.mem.Allocator,
        cwd: []const u8,
        model: ai.Model,
        thinking_level: agent_mod.ThinkingLevel,
        context: ContextUsageSnapshot,
    ) !SessionChromeSnapshot {
        var cwd_text = try EventText.init(allocator, cwd);
        errdefer cwd_text.deinit(allocator);
        var model_snapshot = try ModelSnapshot.init(allocator, model);
        errdefer model_snapshot.deinit(allocator);
        return .{
            .cwd = cwd_text,
            .model = model_snapshot,
            .thinking_level = thinking_level,
            .context = context,
        };
    }

    pub fn deinit(self: *SessionChromeSnapshot, allocator: std.mem.Allocator) void {
        self.cwd.deinit(allocator);
        self.model.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: SessionChromeSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject("session_chrome", stringify, self);
    }
};

pub const HistorySnapshot = struct {
    items: []HistorySnapshotItem,
    dropped_items: usize = 0,
    dropped_text_bytes: usize = 0,

    /// Project durable session facts into a bounded transcript seed. This is
    /// the one truncation policy for snapshot history: oversized item text is
    /// cut at a utf8 boundary, and when the item/byte budget is full the
    /// remaining *older* entries are dropped and counted. Operational data
    /// never makes this fail.
    pub fn fromSession(
        allocator: std.mem.Allocator,
        manager: *const session_manager.SessionManager,
    ) !HistorySnapshot {
        const session_items = try manager.reconstructSession(allocator);
        defer allocator.free(session_items);
        const collected = try collectHistoryBefore(allocator, session_items, session_items.len, .{
            .items_max = snapshot_history_items_max,
            .item_text_bytes_max = snapshot_history_item_text_bytes_max,
            .total_text_bytes_max = snapshot_history_total_text_bytes_max,
        });
        return .{
            .items = collected.items,
            .dropped_items = collected.dropped_items,
            .dropped_text_bytes = collected.dropped_text_bytes,
        };
    }

    pub fn deinit(self: *HistorySnapshot, allocator: std.mem.Allocator) void {
        deinitHistoryItems(allocator, self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HistorySnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const HistoryPage = struct {
    before_entry_id: EventText,
    items: []HistorySnapshotItem,
    has_more_before: bool = false,
    dropped_items: usize = 0,
    dropped_text_bytes: usize = 0,

    pub fn beforeEntry(
        allocator: std.mem.Allocator,
        manager: *const session_manager.SessionManager,
        before_entry_id: []const u8,
    ) !HistoryPage {
        const session_items = try manager.reconstructSession(allocator);
        defer allocator.free(session_items);
        const before_index = findReconstructedIndex(session_items, before_entry_id) orelse
            return error.HistoryEntryNotFound;
        var before = try EventText.init(allocator, before_entry_id);
        errdefer before.deinit(allocator);
        const collected = try collectHistoryBefore(allocator, session_items, before_index, .{
            .items_max = history_page_items_max,
            .item_text_bytes_max = history_page_item_text_bytes_max,
            .total_text_bytes_max = history_page_total_text_bytes_max,
        });
        return .{
            .before_entry_id = before,
            .items = collected.items,
            .has_more_before = collected.dropped_items > 0,
            .dropped_items = collected.dropped_items,
            .dropped_text_bytes = collected.dropped_text_bytes,
        };
    }

    pub fn deinit(self: *HistoryPage, allocator: std.mem.Allocator) void {
        self.before_entry_id.deinit(allocator);
        deinitHistoryItems(allocator, self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HistoryPage, stringify: *std.json.Stringify) !void {
        try writeObject("history_page", stringify, self);
    }
};

pub const HistorySnapshotItem = struct {
    entry_id: EventText,
    kind: Kind,
    text: EventText,
    tool_calls: []HistoryToolCall = &.{},
    tool_call_id: ?EventText = null,
    tool_name: ?EventText = null,
    is_error: bool = false,

    pub const Kind = enum { user, assistant, system, tool_result };

    pub fn deinit(self: *HistorySnapshotItem, allocator: std.mem.Allocator) void {
        self.entry_id.deinit(allocator);
        self.text.deinit(allocator);
        for (self.tool_calls) |*tool_call| tool_call.deinit(allocator);
        if (self.tool_calls.len > 0) allocator.free(self.tool_calls);
        if (self.tool_call_id) |*id| id.deinit(allocator);
        if (self.tool_name) |*name| name.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HistorySnapshotItem, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

pub const HistoryToolCall = struct {
    id: EventText,
    name: EventText,
    title: EventText,

    pub fn deinit(self: *HistoryToolCall, allocator: std.mem.Allocator) void {
        self.id.deinit(allocator);
        self.name.deinit(allocator);
        self.title.deinit(allocator);
        self.* = undefined;
    }
};

const HistoryLimits = struct {
    items_max: usize,
    item_text_bytes_max: usize,
    total_text_bytes_max: usize,
};

const HistoryCollectResult = struct {
    items: []HistorySnapshotItem,
    dropped_items: usize = 0,
    dropped_text_bytes: usize = 0,
};

fn collectHistoryBefore(
    allocator: std.mem.Allocator,
    session_items: []const session_manager.ReconstructedSessionItem,
    end_index: usize,
    limits: HistoryLimits,
) !HistoryCollectResult {
    var items = std.ArrayList(HistorySnapshotItem).empty;
    errdefer {
        for (items.items) |*item| item.deinit(allocator);
        items.deinit(allocator);
    }
    var total_text_bytes: usize = 0;
    var dropped_items: usize = 0;
    var dropped_text_bytes: usize = 0;

    // Walk newest-first so budget pressure drops the oldest history.
    var index = @min(end_index, session_items.len);
    while (index > 0) {
        index -= 1;
        const built = (try itemFromReconstructed(allocator, session_items[index], limits.item_text_bytes_max)) orelse
            continue;
        var item = built.item;
        const resident_bytes = itemTextBytes(item);
        const budget_full = total_text_bytes >= limits.total_text_bytes_max or
            resident_bytes > limits.total_text_bytes_max - total_text_bytes;
        if (items.items.len == limits.items_max or budget_full) {
            dropped_items += 1;
            dropped_text_bytes +|= built.full_text_bytes;
            item.deinit(allocator);
            continue;
        }
        dropped_text_bytes +|= built.full_text_bytes -| resident_bytes;
        {
            errdefer item.deinit(allocator);
            try items.append(allocator, item);
        }
        total_text_bytes += resident_bytes;
    }
    std.mem.reverse(HistorySnapshotItem, items.items);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .dropped_items = dropped_items,
        .dropped_text_bytes = dropped_text_bytes,
    };
}

fn itemTextBytes(item: HistorySnapshotItem) usize {
    var total = item.text.text.len + toolCallsTextBytes(item.tool_calls);
    if (item.tool_call_id) |id| total += id.text.len;
    if (item.tool_name) |name| total += name.text.len;
    return total;
}

fn toolCallsTextBytes(tool_calls: []const HistoryToolCall) usize {
    var total: usize = 0;
    for (tool_calls) |tool_call| {
        total += tool_call.id.text.len + tool_call.name.text.len + tool_call.title.text.len;
    }
    return total;
}

const BuiltHistoryItem = struct {
    item: HistorySnapshotItem,
    full_text_bytes: usize,
};

const BuiltHistoryToolCall = struct {
    tool_call: HistoryToolCall,
    full_text_bytes: usize,
};

const BoundedHistoryText = struct {
    text: EventText,
    full_bytes: usize,
};

fn itemFromReconstructed(
    allocator: std.mem.Allocator,
    item: session_manager.ReconstructedSessionItem,
    item_text_bytes_max: usize,
) !?BuiltHistoryItem {
    switch (item.content) {
        .compaction_summary => |summary| {
            var entry_id = try EventText.init(allocator, item.entry_id);
            errdefer entry_id.deinit(allocator);
            const text = try boundedHistoryText(allocator, summary.summary, item_text_bytes_max);
            return .{
                .item = .{ .entry_id = entry_id, .kind = .system, .text = text.text },
                .full_text_bytes = text.full_bytes,
            };
        },
        .message => |message| switch (message) {
            .user => |user| {
                const text = message_policy.userText(user) orelse return null;
                var entry_id = try EventText.init(allocator, item.entry_id);
                errdefer entry_id.deinit(allocator);
                const bounded = try boundedHistoryText(allocator, text, item_text_bytes_max);
                return .{
                    .item = .{ .entry_id = entry_id, .kind = .user, .text = bounded.text },
                    .full_text_bytes = bounded.full_bytes,
                };
            },
            .assistant => |assistant| {
                const entry_id = try EventText.init(allocator, item.entry_id);
                return assistantHistoryItem(allocator, entry_id, assistant, item_text_bytes_max);
            },
            .tool_result => |tool_result| {
                const entry_id = try EventText.init(allocator, item.entry_id);
                return try toolResultHistoryItem(allocator, entry_id, tool_result, item_text_bytes_max);
            },
            .custom => return null,
        },
    }
}

fn assistantHistoryItem(
    allocator: std.mem.Allocator,
    entry_id: EventText,
    assistant: ai.AssistantMessage,
    item_text_bytes_max: usize,
) !?BuiltHistoryItem {
    var owned_entry_id = entry_id;
    errdefer owned_entry_id.deinit(allocator);

    var buffer: [snapshot_history_item_text_bytes_max]u8 = undefined;
    var writer = boundedHistoryWriter(&buffer, item_text_bytes_max);
    var text_full_bytes: usize = 0;
    var wrote_text = false;
    var tool_calls_full_bytes: usize = 0;
    var tool_calls = std.ArrayList(HistoryToolCall).empty;
    errdefer {
        for (tool_calls.items) |*tool_call| tool_call.deinit(allocator);
        tool_calls.deinit(allocator);
    }

    for (assistant.content) |content| switch (content) {
        .text => |text| {
            if (wrote_text) {
                text_full_bytes += 1;
                try appendBoundedHistoryText(&writer, "\n");
            }
            text_full_bytes += text.text.len;
            try appendBoundedHistoryText(&writer, text.text);
            wrote_text = true;
        },
        .tool_call => |tool_call| {
            var built = try historyToolCall(allocator, tool_call, item_text_bytes_max);
            tool_calls.append(allocator, built.tool_call) catch |err| {
                built.tool_call.deinit(allocator);
                return err;
            };
            tool_calls_full_bytes += built.full_text_bytes;
        },
        .thinking => {},
    };

    if (writer.buffered().len == 0 and tool_calls.items.len == 0) {
        const error_message = assistant.error_message orelse {
            owned_entry_id.deinit(allocator);
            return null;
        };
        const text = try boundedHistoryText(allocator, error_message, item_text_bytes_max);
        return .{
            .item = .{ .entry_id = owned_entry_id, .kind = .system, .text = text.text },
            .full_text_bytes = text.full_bytes,
        };
    }

    var text = try EventText.init(allocator, utf8Prefix(writer.buffered(), writer.buffered().len));
    errdefer text.deinit(allocator);
    return .{
        .item = .{
            .entry_id = owned_entry_id,
            .kind = .assistant,
            .text = text,
            .tool_calls = try tool_calls.toOwnedSlice(allocator),
        },
        .full_text_bytes = text_full_bytes + tool_calls_full_bytes,
    };
}

fn historyToolCall(
    allocator: std.mem.Allocator,
    tool_call: ai.ToolCall,
    item_text_bytes_max: usize,
) !BuiltHistoryToolCall {
    var id = try boundedHistoryText(allocator, tool_call.id, history_tool_id_bytes_max);
    errdefer id.text.deinit(allocator);
    var name = try boundedHistoryText(allocator, tool_call.name, history_tool_name_bytes_max);
    errdefer name.text.deinit(allocator);
    const title = try toolCallTitle(allocator, tool_call, item_text_bytes_max);
    return .{
        .tool_call = .{ .id = id.text, .name = name.text, .title = title.text },
        .full_text_bytes = id.full_bytes + name.full_bytes + title.full_bytes,
    };
}

fn toolCallTitle(
    allocator: std.mem.Allocator,
    tool_call: ai.ToolCall,
    item_text_bytes_max: usize,
) !BoundedHistoryText {
    var buffer: [snapshot_history_item_text_bytes_max]u8 = undefined;
    var writer = boundedHistoryWriter(&buffer, item_text_bytes_max);
    try appendBoundedHistoryText(&writer, tool_call.name);
    try appendBoundedHistoryText(&writer, " ");
    std.json.Stringify.value(tool_call.arguments, .{}, &writer) catch |err| switch (err) {
        error.WriteFailed => {},
    };

    var counter = std.Io.Writer.Discarding.init(&.{});
    try std.json.Stringify.value(tool_call.arguments, .{}, &counter.writer);
    const args_bytes = std.math.lossyCast(usize, counter.fullCount());
    return .{
        .text = try EventText.init(allocator, utf8Prefix(writer.buffered(), writer.buffered().len)),
        .full_bytes = tool_call.name.len + 1 + args_bytes,
    };
}

fn toolResultHistoryItem(
    allocator: std.mem.Allocator,
    entry_id: EventText,
    tool_result: ai.ToolResultMessage,
    item_text_bytes_max: usize,
) !BuiltHistoryItem {
    var owned_entry_id = entry_id;
    errdefer owned_entry_id.deinit(allocator);
    var tool_call_id = try boundedHistoryText(allocator, tool_result.tool_call_id, history_tool_id_bytes_max);
    errdefer tool_call_id.text.deinit(allocator);
    var tool_name = try boundedHistoryText(allocator, tool_result.tool_name, history_tool_name_bytes_max);
    errdefer tool_name.text.deinit(allocator);
    const text = try toolResultText(allocator, tool_result.content, item_text_bytes_max);
    return .{
        .item = .{
            .entry_id = owned_entry_id,
            .kind = .tool_result,
            .text = text.text,
            .tool_call_id = tool_call_id.text,
            .tool_name = tool_name.text,
            .is_error = tool_result.is_error,
        },
        .full_text_bytes = text.full_bytes + tool_call_id.full_bytes + tool_name.full_bytes,
    };
}

fn toolResultText(
    allocator: std.mem.Allocator,
    content: []const ai.ToolResultContent,
    item_text_bytes_max: usize,
) !BoundedHistoryText {
    var buffer: [snapshot_history_item_text_bytes_max]u8 = undefined;
    var writer = boundedHistoryWriter(&buffer, item_text_bytes_max);
    var full_bytes: usize = 0;
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |value| value.text,
            .image => |image| imageFallbackText(image.mime_type),
        };
        if (text.len == 0) continue;
        if (wrote_any) {
            full_bytes += 1;
            try appendBoundedHistoryText(&writer, "\n");
        }
        full_bytes += text.len;
        try appendBoundedHistoryText(&writer, text);
        wrote_any = true;
    }
    return .{
        .text = try EventText.init(allocator, utf8Prefix(writer.buffered(), writer.buffered().len)),
        .full_bytes = full_bytes,
    };
}

fn boundedHistoryText(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) !BoundedHistoryText {
    return .{
        .text = try EventText.init(allocator, utf8Prefix(text, max_bytes)),
        .full_bytes = text.len,
    };
}

fn boundedHistoryWriter(buffer: *[snapshot_history_item_text_bytes_max]u8, max_bytes: usize) std.Io.Writer {
    std.debug.assert(max_bytes <= buffer.len);
    return std.Io.Writer.fixed(buffer[0..max_bytes]);
}

fn appendBoundedHistoryText(writer: *std.Io.Writer, text: []const u8) !void {
    const prefix = utf8Prefix(text, writer.unusedCapacityLen());
    if (prefix.len > 0) try writer.writeAll(prefix);
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn deinitHistoryItems(allocator: std.mem.Allocator, items: []HistorySnapshotItem) void {
    for (items) |*item| item.deinit(allocator);
    allocator.free(items);
}

fn findReconstructedIndex(items: []const session_manager.ReconstructedSessionItem, entry_id: []const u8) ?usize {
    for (items, 0..) |item, index| {
        if (std.mem.eql(u8, item.entry_id, entry_id)) return index;
    }
    return null;
}

pub const QueueSnapshot = struct {
    revision: u64,
    steering: EventTextList,
    follow_up: EventTextList,

    pub fn deinit(self: *QueueSnapshot, allocator: std.mem.Allocator) void {
        self.steering.deinit(allocator);
        self.follow_up.deinit(allocator);
        self.* = undefined;
    }

    pub fn jsonStringify(self: QueueSnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(null, stringify, self);
    }
};

/// Write a payload struct as a JSON object: optional `"type"` tag first,
/// then every field under its camelCase name; null optionals are omitted.
/// This is the one owner of the wire field-naming policy.
fn writeObject(
    comptime type_tag: ?[]const u8,
    stringify: *std.json.Stringify,
    payload: anytype,
) !void {
    try stringify.beginObject();
    if (type_tag) |tag| try writeJsonField("type", stringify, tag);
    inline for (@typeInfo(@TypeOf(payload)).@"struct".fields) |field| {
        const value = @field(payload, field.name);
        const camel = comptime camelCase(field.name);
        if (@typeInfo(field.type) == .optional) {
            if (value) |resolved| try writeJsonField(camel, stringify, resolved);
        } else {
            try writeJsonField(camel, stringify, value);
        }
    }
    try stringify.endObject();
}

fn camelCase(comptime name: []const u8) []const u8 {
    comptime {
        var out: [name.len]u8 = undefined;
        var len: usize = 0;
        var upper = false;
        for (name) |char| {
            if (char == '_') {
                upper = true;
                continue;
            }
            out[len] = if (upper) std.ascii.toUpper(char) else char;
            upper = false;
            len += 1;
        }
        const final = out[0..len].*;
        return &final;
    }
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

fn writeJsonField(comptime name: []const u8, stringify: *std.json.Stringify, value: anytype) !void {
    try stringify.objectField(name);
    try stringify.write(value);
}

fn appendTestMessage(
    manager: *session_manager.SessionManager,
    message: agent_mod.AgentMessage,
    timestamp: []const u8,
) ![]const u8 {
    const entry = try manager.prepareMessageEntry(message, timestamp);
    errdefer manager.deinitPreparedEntry(entry);
    return manager.commitPreparedEntry(entry);
}

fn appendTestCompaction(
    manager: *session_manager.SessionManager,
    summary: []const u8,
    first_kept_entry_id: []const u8,
    tokens_before: u64,
    timestamp: []const u8,
) ![]const u8 {
    const entry = try manager.prepareCompactionEntry(summary, first_kept_entry_id, tokens_before, timestamp);
    errdefer manager.deinitPreparedEntry(entry);
    return manager.commitPreparedEntry(entry);
}

test "command envelope owns prompt text" {
    var envelope = try CommandEnvelope.initSubmitPrompt(std.testing.allocator, 7, "hello", .auto);
    defer envelope.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(?RequestId, 7), envelope.id);
    try std.testing.expectEqualStrings("hello", envelope.command.submit.text);
}

test "event envelope deinitializes owned client event" {
    var event: EventEnvelope = .{ .event = .{ .rejected = .{
        .code = .invalid_command,
        .message = try EventText.init(std.testing.allocator, "no"),
    } } };
    event.deinit(std.testing.allocator);
}

test "completion snapshot owns and deinitializes strings" {
    const models = [_]CompletionItem.Source{.{ .id = "provider/model", .label = "provider/model", .detail = "ready" }};
    const sessions = [_]CompletionItem.Source{.{ .id = "session.jsonl", .label = "session", .detail = "today" }};
    var snapshot = try CompletionSnapshot.init(std.testing.allocator, &models, false, &sessions, false);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("provider/model", snapshot.models.items[0].id.text);
    try std.testing.expectEqualStrings("session", snapshot.resume_sessions.items[0].label.text);
}

test "completion snapshot truncates item count and text fields" {
    const long_id = "i" ** (completion_id_bytes_max + 4);
    const long_label = "l" ** (completion_label_bytes_max + 4);
    const long_detail = "d" ** (completion_detail_bytes_max + 4);
    const source = try std.testing.allocator.alloc(CompletionItem.Source, completion_item_count_max + 1);
    defer std.testing.allocator.free(source);
    for (source) |*item| item.* = .{ .id = long_id, .label = long_label, .detail = long_detail };

    var list = try CompletionList.init(std.testing.allocator, source, false);
    defer list.deinit(std.testing.allocator);

    try std.testing.expect(list.truncated);
    try std.testing.expectEqual(completion_item_count_max, list.items.len);
    try std.testing.expectEqual(completion_id_bytes_max, list.items[0].id.text.len);
    try std.testing.expectEqual(completion_label_bytes_max, list.items[0].label.text.len);
    try std.testing.expectEqual(completion_detail_bytes_max, list.items[0].detail.text.len);
}

test "history snapshot from session maps roles and keeps newest under caps" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "t1");
    _ = try appendTestMessage(&manager, .{ .assistant = .{
        .content = &.{.{ .text = .{ .text = "hi" } }},
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } }, "t2");

    var snapshot = try HistorySnapshot.fromSession(std.testing.allocator, &manager);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqualStrings("00000001", snapshot.items[0].entry_id.text);
    try std.testing.expectEqual(HistorySnapshotItem.Kind.user, snapshot.items[0].kind);
    try std.testing.expectEqualStrings("hello", snapshot.items[0].text.text);
    try std.testing.expectEqualStrings("00000002", snapshot.items[1].entry_id.text);
    try std.testing.expectEqual(HistorySnapshotItem.Kind.assistant, snapshot.items[1].kind);
    try std.testing.expectEqualStrings("hi", snapshot.items[1].text.text);
}

test "history snapshot projects assistant tool calls and tool results" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    _ = try appendTestMessage(&manager, .{ .assistant = .{
        .content = &.{
            .{ .text = .{ .text = "I'll read it." } },
            .{ .tool_call = .{ .id = "call-1", .name = "read", .arguments = .{ .object = .empty } } },
        },
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    } }, "t1");
    _ = try appendTestMessage(&manager, .{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "read",
        .content = &.{.{ .text = .{ .text = "file contents" } }},
        .is_error = false,
        .timestamp = 0,
    } }, "t2");

    var snapshot = try HistorySnapshot.fromSession(std.testing.allocator, &manager);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(HistorySnapshotItem.Kind.assistant, snapshot.items[0].kind);
    try std.testing.expectEqualStrings("I'll read it.", snapshot.items[0].text.text);
    try std.testing.expectEqual(@as(usize, 1), snapshot.items[0].tool_calls.len);
    try std.testing.expectEqualStrings("call-1", snapshot.items[0].tool_calls[0].id.text);
    try std.testing.expectEqualStrings("read", snapshot.items[0].tool_calls[0].name.text);
    try std.testing.expectEqual(HistorySnapshotItem.Kind.tool_result, snapshot.items[1].kind);
    try std.testing.expectEqualStrings("call-1", snapshot.items[1].tool_call_id.?.text);
    try std.testing.expectEqualStrings("file contents", snapshot.items[1].text.text);
}

test "history bounds tool text before storing snapshot items" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    const huge = try std.testing.allocator.alloc(u8, snapshot_history_item_text_bytes_max * 2);
    defer std.testing.allocator.free(huge);
    @memset(huge, 'x');
    const huge_id = try std.testing.allocator.alloc(u8, history_tool_id_bytes_max + 8);
    defer std.testing.allocator.free(huge_id);
    @memset(huge_id, 'i');
    const huge_name = try std.testing.allocator.alloc(u8, history_tool_name_bytes_max + 8);
    defer std.testing.allocator.free(huge_name);
    @memset(huge_name, 'n');

    var args = std.json.ObjectMap.empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "payload", .{ .string = huge });
    const tool_call: ai.ToolCall = .{ .id = huge_id, .name = huge_name, .arguments = .{ .object = args } };
    _ = try appendTestMessage(&manager, .{ .assistant = .{
        .content = &.{.{ .tool_call = tool_call }},
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    } }, "t1");
    _ = try appendTestMessage(&manager, .{ .tool_result = .{
        .tool_call_id = huge_id,
        .tool_name = huge_name,
        .content = &.{.{ .text = .{ .text = huge } }},
        .is_error = false,
        .timestamp = 0,
    } }, "t2");

    var snapshot = try HistorySnapshot.fromSession(std.testing.allocator, &manager);
    defer snapshot.deinit(std.testing.allocator);

    const call = snapshot.items[0].tool_calls[0];
    try std.testing.expectEqual(history_tool_id_bytes_max, call.id.text.len);
    try std.testing.expectEqual(history_tool_name_bytes_max, call.name.text.len);
    try std.testing.expect(call.title.text.len <= snapshot_history_item_text_bytes_max);
    try std.testing.expectEqual(snapshot_history_item_text_bytes_max, snapshot.items[1].text.text.len);
    try std.testing.expectEqual(history_tool_id_bytes_max, snapshot.items[1].tool_call_id.?.text.len);
    try std.testing.expectEqual(history_tool_name_bytes_max, snapshot.items[1].tool_name.?.text.len);
    try std.testing.expect(snapshot.dropped_text_bytes > 0);
}

test "history page returns bounded items before an entry id" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = "one" }, .timestamp = 0 } }, "t1");
    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = "two" }, .timestamp = 0 } }, "t2");
    const before = try appendTestMessage(&manager, .{ .user = .{
        .content = .{ .string = "three" },
        .timestamp = 0,
    } }, "t3");

    var page = try HistoryPage.beforeEntry(std.testing.allocator, &manager, before);
    defer page.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), page.items.len);
    try std.testing.expectEqualStrings("00000001", page.items[0].entry_id.text);
    try std.testing.expectEqualStrings("one", page.items[0].text.text);
    try std.testing.expectEqualStrings("00000002", page.items[1].entry_id.text);
    try std.testing.expectEqualStrings("two", page.items[1].text.text);
    try std.testing.expect(!page.has_more_before);
}

test "history budget counts assistant tool call titles" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    const tool_call: ai.ToolCall = .{ .id = "call-1", .name = "bash", .arguments = .{ .object = .empty } };
    var title = try toolCallTitle(std.testing.allocator, tool_call, snapshot_history_item_text_bytes_max);
    defer title.text.deinit(std.testing.allocator);

    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = "old" }, .timestamp = 0 } }, "t1");
    _ = try appendTestMessage(&manager, .{ .assistant = .{
        .content = &.{.{ .tool_call = tool_call }},
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 0,
    } }, "t2");
    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = "new" }, .timestamp = 0 } }, "t3");

    const session_items = try manager.reconstructSession(std.testing.allocator);
    defer std.testing.allocator.free(session_items);
    const tool_call_bytes = tool_call.id.len + tool_call.name.len + title.text.text.len;
    const collected = try collectHistoryBefore(std.testing.allocator, session_items, session_items.len, .{
        .items_max = 8,
        .item_text_bytes_max = 128,
        .total_text_bytes_max = "new".len + tool_call_bytes,
    });
    defer deinitHistoryItems(std.testing.allocator, collected.items);

    try std.testing.expectEqual(@as(usize, 2), collected.items.len);
    try std.testing.expectEqual(@as(usize, 1), collected.dropped_items);
    try std.testing.expectEqual(@as(usize, "old".len), collected.dropped_text_bytes);
    try std.testing.expectEqual(HistorySnapshotItem.Kind.assistant, collected.items[0].kind);
    try std.testing.expectEqualStrings("new", collected.items[1].text.text);
}

test "history snapshot truncates oversized items and drops oldest under byte budget" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    const oversized = try std.testing.allocator.alloc(u8, snapshot_history_item_text_bytes_max + 4);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = oversized }, .timestamp = 0 } }, "t1");

    var snapshot = try HistorySnapshot.fromSession(std.testing.allocator, &manager);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqual(@as(usize, 4), snapshot.dropped_text_bytes);
    try std.testing.expectEqual(snapshot_history_item_text_bytes_max, snapshot.items[0].text.text.len);

    // Fill past the total budget: the oldest items are dropped, newest kept.
    const big = try std.testing.allocator.alloc(u8, snapshot_history_item_text_bytes_max);
    defer std.testing.allocator.free(big);
    @memset(big, 'b');
    const needed = snapshot_history_total_text_bytes_max / snapshot_history_item_text_bytes_max + 1;
    for (0..needed) |_| {
        _ = try appendTestMessage(&manager, .{ .user = .{ .content = .{ .string = big }, .timestamp = 0 } }, "t2");
    }
    var full = try HistorySnapshot.fromSession(std.testing.allocator, &manager);
    defer full.deinit(std.testing.allocator);
    try std.testing.expect(full.dropped_items > 0);
    try std.testing.expectEqualStrings(big, full.items[full.items.len - 1].text.text);
}

test "prompt command event serializes public shape" {
    var event: ClientEvent = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try EventText.init(std.testing.allocator, "available commands: /help, /session"),
    } };
    defer event.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();
    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt_command\",\"command\":\"help\",\"result\":\"handled\"," ++
            "\"message\":\"available commands: /help, /session\",\"presentation\":\"status\"}",
        writer.written(),
    );
}

test "failed compaction end event omits result" {
    var event: ClientEvent = .{ .compaction_end = .{
        .reason = .threshold,
        .aborted = true,
        .will_retry = false,
        .error_message = try EventText.init(std.testing.allocator, "not implemented"),
    } };
    defer event.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"threshold\",\"aborted\":true," ++
            "\"willRetry\":false,\"errorMessage\":\"not implemented\"}",
        writer.written(),
    );
}

test "compaction end event serializes owned result" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const first_kept = try appendTestMessage(&manager, .{ .user = .{
        .content = .{ .string = "kept" },
        .timestamp = 0,
    } }, "t1");
    _ = try appendTestCompaction(&manager, "summary", first_kept, 42, "t2");

    var event: ClientEvent = .{ .compaction_end = .{
        .reason = .threshold,
        .result = try CompactionResult.init(
            std.testing.allocator,
            manager.entries.items[1].compaction,
        ),
        .aborted = false,
        .will_retry = false,
    } };
    defer event.deinit(std.testing.allocator);

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"threshold\",\"result\":{\"summary\":\"summary\"," ++
            "\"firstKeptEntryId\":\"00000001\",\"tokensBefore\":42},\"aborted\":false,\"willRetry\":false}",
        writer.written(),
    );
}
