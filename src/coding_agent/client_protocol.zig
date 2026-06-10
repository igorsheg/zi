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
pub const snapshot_model_text_bytes_max = 256;

pub const CommandQueue = runtime.BoundedQueue(CommandEnvelope);
pub const EventQueue = runtime.BoundedQueue(EventEnvelope);

pub const CommandEnvelope = struct {
    id: ?RequestId = null,
    command: ClientCommand,

    pub fn initSubmitPrompt(allocator: std.mem.Allocator, id: ?RequestId, text: []const u8) !CommandEnvelope {
        return .{ .id = id, .command = .{ .submit = .{ .text = try allocator.dupe(u8, text), .mode = .auto } } };
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
    shutdown,

    pub fn deinit(self: *ClientCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submit => |prompt| allocator.free(prompt.text),
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
            .compaction_end => |*payload| payload.deinit(allocator),
            .auto_retry_start => |*payload| payload.error_message.deinit(allocator),
            .auto_retry_end => |*payload| if (payload.final_error) |*err| err.deinit(allocator),
            .operation_started,
            .operation_finished,
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
            .replay => |payload| try stringify.write(payload),
            inline .shutdown_started, .operation_started => |_, tag| try writeObject(stringify, @tagName(tag), .{}),
            inline else => |payload, tag| try writeObject(stringify, @tagName(tag), payload),
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
        try writeObject(stringify, null, self);
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
        try writeObject(stringify, "snapshot", self);
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
        try writeObject(stringify, null, self);
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
        try writeObject(stringify, null, self);
    }
};

pub const HistorySnapshot = struct {
    items: []HistorySnapshotItem,
    dropped_items: usize = 0,
    dropped_text_bytes: usize = 0,

    /// Project session entries into a bounded text transcript seed. This is
    /// the one truncation policy for snapshot history: oversized item text is
    /// cut at a utf8 boundary, and when the item/byte budget is full the
    /// remaining *older* entries are dropped and counted. Operational data
    /// never makes this fail.
    pub fn fromEntries(
        allocator: std.mem.Allocator,
        entries: []const session_manager.SessionEntry,
    ) !HistorySnapshot {
        var items = std.ArrayList(HistorySnapshotItem).empty;
        errdefer {
            for (items.items) |*item| item.deinit(allocator);
            items.deinit(allocator);
        }
        var total_text_bytes: usize = 0;
        var dropped_items: usize = 0;
        var dropped_text_bytes: usize = 0;

        // Walk newest-first so budget pressure drops the oldest history.
        var index = entries.len;
        while (index > 0) {
            index -= 1;
            if (entries[index] != .message) continue;
            var item = (try itemFromMessage(allocator, entries[index].message.message)) orelse continue;
            const text = utf8Prefix(item.text.text, snapshot_history_item_text_bytes_max);
            if (items.items.len == snapshot_history_items_max or
                total_text_bytes + text.len > snapshot_history_total_text_bytes_max)
            {
                dropped_items += 1;
                dropped_text_bytes += item.text.text.len;
                item.deinit(allocator);
                continue;
            }
            dropped_text_bytes += item.text.text.len - text.len;
            if (text.len < item.text.text.len) {
                const role = item.role;
                const truncated = allocator.dupe(u8, text) catch |err| {
                    item.deinit(allocator);
                    return err;
                };
                item.deinit(allocator);
                item = .{ .role = role, .text = .{ .text = truncated } };
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

    fn itemFromMessage(allocator: std.mem.Allocator, message: agent_mod.AgentMessage) !?HistorySnapshotItem {
        switch (message) {
            .user => |user| {
                const text = message_policy.userText(user) orelse return null;
                return .{ .role = .user, .text = try EventText.init(allocator, text) };
            },
            .assistant => |assistant| {
                var writer: std.Io.Writer.Allocating = .init(allocator);
                defer writer.deinit();
                for (assistant.content) |content| {
                    if (content != .text) continue;
                    if (writer.written().len > 0) try writer.writer.writeByte('\n');
                    try writer.writer.writeAll(content.text.text);
                }
                if (writer.written().len == 0) {
                    const error_message = assistant.error_message orelse return null;
                    return .{ .role = .system, .text = try EventText.init(allocator, error_message) };
                }
                return .{ .role = .assistant, .text = .{ .text = try writer.toOwnedSlice() } };
            },
            .tool_result, .custom => return null,
        }
    }

    pub fn deinit(self: *HistorySnapshot, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HistorySnapshot, stringify: *std.json.Stringify) !void {
        try writeObject(stringify, null, self);
    }
};

pub const HistorySnapshotItem = struct {
    role: Role,
    text: EventText,

    pub const Role = enum { user, assistant, system };

    pub fn deinit(self: *HistorySnapshotItem, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.* = undefined;
    }
};

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
        try writeObject(stringify, null, self);
    }
};

/// Write a payload struct as a JSON object: optional `"type"` tag first,
/// then every field under its camelCase name; null optionals are omitted.
/// This is the one owner of the wire field-naming policy.
fn writeObject(
    stringify: *std.json.Stringify,
    comptime type_tag: ?[]const u8,
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

test "command envelope owns prompt text" {
    var envelope = try CommandEnvelope.initSubmitPrompt(std.testing.allocator, 7, "hello");
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

test "history snapshot from entries maps roles and keeps newest under caps" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "t1");
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &.{.{ .text = .{ .text = "hi" } }},
        .api = ai.KnownApi.openai_responses,
        .provider = "openai",
        .model = "gpt",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .stop,
        .timestamp = 0,
    } }, "t2");

    var snapshot = try HistorySnapshot.fromEntries(std.testing.allocator, manager.entries.items);
    defer snapshot.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), snapshot.items.len);
    try std.testing.expectEqual(HistorySnapshotItem.Role.user, snapshot.items[0].role);
    try std.testing.expectEqualStrings("hello", snapshot.items[0].text.text);
    try std.testing.expectEqual(HistorySnapshotItem.Role.assistant, snapshot.items[1].role);
    try std.testing.expectEqualStrings("hi", snapshot.items[1].text.text);
}

test "history snapshot truncates oversized items and drops oldest under byte budget" {
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "s", "t0");
    defer manager.deinit();

    const oversized = try std.testing.allocator.alloc(u8, snapshot_history_item_text_bytes_max + 4);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'a');
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = oversized }, .timestamp = 0 } }, "t1");

    var snapshot = try HistorySnapshot.fromEntries(std.testing.allocator, manager.entries.items);
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
        _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = big }, .timestamp = 0 } }, "t2");
    }
    var full = try HistorySnapshot.fromEntries(std.testing.allocator, manager.entries.items);
    defer full.deinit(std.testing.allocator);
    try std.testing.expect(full.dropped_items > 0);
    try std.testing.expectEqualStrings(big, full.items[full.items.len - 1].text.text);
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

    const first_kept = try manager.appendMessage(.{ .user = .{
        .content = .{ .string = "kept" },
        .timestamp = 0,
    } }, "t1");
    _ = try manager.appendCompaction("summary", first_kept, 42, "t2");

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
