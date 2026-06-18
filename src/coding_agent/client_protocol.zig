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
pub const history_page_items_max = 64;
pub const history_page_item_text_bytes_max = snapshot_history_item_text_bytes_max;
pub const history_page_total_text_bytes_max = 64 * 1024;
pub const snapshot_model_text_bytes_max = 256;

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
    replay: ReplayRequest,
    history_page: HistoryPageRequest,
    switch_session: SwitchSession,
    shutdown,

    pub fn deinit(self: *ClientCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submit => |prompt| allocator.free(prompt.text),
            .history_page => |request| allocator.free(request.before_entry_id),
            .switch_session => |request| allocator.free(request.session_file_name),
            .cancel, .queue, .snapshot, .replay, .shutdown => {},
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
            inline .shutdown_started, .operation_started, .session_changed => |_, tag| try writeObject(@tagName(tag), stringify, .{}),
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
        const before_index = findReconstructedIndex(session_items, before_entry_id) orelse return error.HistoryEntryNotFound;
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
        var item = (try itemFromReconstructed(allocator, session_items[index])) orelse continue;
        const full_bytes = itemTextBytes(item);
        const text = utf8Prefix(item.text.text, limits.item_text_bytes_max);
        const resident_bytes = text.len + toolCallsTextBytes(item.tool_calls);
        if (items.items.len == limits.items_max or total_text_bytes + resident_bytes > limits.total_text_bytes_max) {
            dropped_items += 1;
            dropped_text_bytes += full_bytes;
            item.deinit(allocator);
            continue;
        }
        dropped_text_bytes += item.text.text.len - text.len;
        if (text.len < item.text.text.len) {
            const truncated = EventText.init(allocator, text) catch |err| {
                item.deinit(allocator);
                return err;
            };
            item.text.deinit(allocator);
            item.text = truncated;
        }
        {
            errdefer item.deinit(allocator);
            try items.append(allocator, item);
        }
        total_text_bytes += text.len;
    }
    std.mem.reverse(HistorySnapshotItem, items.items);
    return .{
        .items = try items.toOwnedSlice(allocator),
        .dropped_items = dropped_items,
        .dropped_text_bytes = dropped_text_bytes,
    };
}

fn itemTextBytes(item: HistorySnapshotItem) usize {
    return item.text.text.len + toolCallsTextBytes(item.tool_calls);
}

fn toolCallsTextBytes(tool_calls: []const HistoryToolCall) usize {
    var total: usize = 0;
    for (tool_calls) |tool_call| total += tool_call.title.text.len;
    return total;
}

fn itemFromReconstructed(
    allocator: std.mem.Allocator,
    item: session_manager.ReconstructedSessionItem,
) !?HistorySnapshotItem {
    switch (item.content) {
        .compaction_summary => |summary| {
            var entry_id = try EventText.init(allocator, item.entry_id);
            errdefer entry_id.deinit(allocator);
            return .{
                .entry_id = entry_id,
                .kind = .system,
                .text = try EventText.init(allocator, summary.summary),
            };
        },
        .message => |message| switch (message) {
            .user => |user| {
                const text = message_policy.userText(user) orelse return null;
                var entry_id = try EventText.init(allocator, item.entry_id);
                errdefer entry_id.deinit(allocator);
                return .{ .entry_id = entry_id, .kind = .user, .text = try EventText.init(allocator, text) };
            },
            .assistant => |assistant| {
                const entry_id = try EventText.init(allocator, item.entry_id);
                return assistantHistoryItem(allocator, entry_id, assistant);
            },
            .tool_result => |tool_result| {
                const entry_id = try EventText.init(allocator, item.entry_id);
                return try toolResultHistoryItem(allocator, entry_id, tool_result);
            },
            .custom => return null,
        },
    }
}

fn assistantHistoryItem(
    allocator: std.mem.Allocator,
    entry_id: EventText,
    assistant: ai.AssistantMessage,
) !?HistorySnapshotItem {
    var owned_entry_id = entry_id;
    errdefer owned_entry_id.deinit(allocator);

    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var tool_calls = std.ArrayList(HistoryToolCall).empty;
    errdefer {
        for (tool_calls.items) |*tool_call| tool_call.deinit(allocator);
        tool_calls.deinit(allocator);
    }

    for (assistant.content) |content| switch (content) {
        .text => |text| {
            if (writer.written().len > 0) try writer.writer.writeByte('\n');
            try writer.writer.writeAll(text.text);
        },
        .tool_call => |tool_call| try tool_calls.append(allocator, try historyToolCall(allocator, tool_call)),
        .thinking => {},
    };

    if (writer.written().len == 0 and tool_calls.items.len == 0) {
        const error_message = assistant.error_message orelse {
            owned_entry_id.deinit(allocator);
            return null;
        };
        return .{
            .entry_id = owned_entry_id,
            .kind = .system,
            .text = try EventText.init(allocator, error_message),
        };
    }

    const text = try writer.toOwnedSlice();
    errdefer allocator.free(text);
    return .{
        .entry_id = owned_entry_id,
        .kind = .assistant,
        .text = .{ .text = text },
        .tool_calls = try tool_calls.toOwnedSlice(allocator),
    };
}

fn historyToolCall(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !HistoryToolCall {
    var id = try EventText.init(allocator, tool_call.id);
    errdefer id.deinit(allocator);
    var name = try EventText.init(allocator, tool_call.name);
    errdefer name.deinit(allocator);
    return .{
        .id = id,
        .name = name,
        .title = try toolCallTitle(allocator, tool_call),
    };
}

fn toolCallTitle(allocator: std.mem.Allocator, tool_call: ai.ToolCall) !EventText {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    try writer.writer.writeAll(tool_call.name);
    try writer.writer.writeByte(' ');
    try std.json.Stringify.value(tool_call.arguments, .{}, &writer.writer);
    return EventText.init(allocator, utf8Prefix(writer.written(), snapshot_history_item_text_bytes_max));
}

fn toolResultHistoryItem(
    allocator: std.mem.Allocator,
    entry_id: EventText,
    tool_result: ai.ToolResultMessage,
) !HistorySnapshotItem {
    var owned_entry_id = entry_id;
    errdefer owned_entry_id.deinit(allocator);
    var tool_call_id = try EventText.init(allocator, tool_result.tool_call_id);
    errdefer tool_call_id.deinit(allocator);
    var tool_name = try EventText.init(allocator, tool_result.tool_name);
    errdefer tool_name.deinit(allocator);
    return .{
        .entry_id = owned_entry_id,
        .kind = .tool_result,
        .text = try toolResultText(allocator, tool_result.content),
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .is_error = tool_result.is_error,
    };
}

fn toolResultText(allocator: std.mem.Allocator, content: []const ai.ToolResultContent) !EventText {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    defer writer.deinit();
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |value| value.text,
            .image => |image| imageFallbackText(image.mime_type),
        };
        if (text.len == 0) continue;
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(text);
        wrote_any = true;
    }
    return .{ .text = try writer.toOwnedSlice() };
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
