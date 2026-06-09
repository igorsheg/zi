const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const session_manager = @import("session_manager.zig");

pub const RequestId = u64;

pub const command_queue_capacity_default = 64;
pub const event_queue_capacity_default = 256;
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
        return .{ .id = id, .command = .{ .submit_prompt = .{ .text = try allocator.dupe(u8, text) } } };
    }

    pub fn deinit(self: *CommandEnvelope, allocator: std.mem.Allocator) void {
        self.command.deinit(allocator);
        self.* = undefined;
    }
};

pub const ClientCommand = union(enum) {
    submit_prompt: SubmitPrompt,
    cancel,
    clear_queue,
    request_snapshot,
    shutdown,

    pub fn deinit(self: *ClientCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .submit_prompt => |prompt| allocator.free(prompt.text),
            .cancel, .clear_queue, .request_snapshot, .shutdown => {},
        }
        self.* = undefined;
    }
};

pub const SubmitPrompt = struct {
    text: []u8,
};

pub const EventEnvelope = struct {
    request_id: ?RequestId = null,
    event: ClientEvent,

    pub fn deinit(self: *EventEnvelope, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.event.deinit();
        self.* = undefined;
    }
};

pub const ClientEvent = union(enum) {
    rejected: Rejection,
    response: Response,
    agent_event: OwnedAgentEvent,
    queue_update: QueueUpdate,
    prompt_command: PromptCommand,
    snapshot: Snapshot,
    compaction_start: CompactionStart,
    session_info_changed: SessionInfoChanged,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,
    event_overflow: EventOverflow,

    pub fn deinit(self: *ClientEvent) void {
        switch (self.*) {
            .rejected => |*rejection| rejection.message.deinit(),
            .agent_event => |*payload| payload.deinit(),
            .queue_update => |*payload| payload.deinit(),
            .prompt_command => |*payload| payload.deinit(),
            .snapshot => |*payload| payload.deinit(),
            .session_info_changed => |*payload| if (payload.name) |*name| name.deinit(),
            .compaction_end => |*payload| payload.deinit(),
            .auto_retry_start => |*payload| payload.error_message.deinit(),
            .auto_retry_end => |*payload| if (payload.final_error) |*err| err.deinit(),
            .response, .compaction_start, .event_overflow => {},
        }
        self.* = undefined;
    }

    pub fn jsonStringify(self: ClientEvent, stringify: *std.json.Stringify) !void {
        switch (self) {
            .agent_event => |event| try stringify.write(event),
            .queue_update => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "queue_update");
                try writeJsonField("steering", stringify, payload.steering);
                try writeJsonField("followUp", stringify, payload.follow_up);
                try writeJsonField("revision", stringify, payload.revision);
                try stringify.endObject();
            },
            .prompt_command => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "prompt_command");
                try writeJsonField("command", stringify, payload.command);
                try writeJsonField("result", stringify, payload.result);
                try writeJsonField("message", stringify, payload.message);
                try stringify.endObject();
            },
            .snapshot => |payload| try stringify.write(payload),
            .compaction_start => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "compaction_start");
                try writeJsonField("reason", stringify, payload.reason);
                try stringify.endObject();
            },
            .session_info_changed => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "session_info_changed");
                if (payload.name) |name| try writeJsonField("name", stringify, name);
                try stringify.endObject();
            },
            .compaction_end => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "compaction_end");
                try writeJsonField("reason", stringify, payload.reason);
                if (payload.result) |result| try writeJsonField("result", stringify, result);
                try writeJsonField("aborted", stringify, payload.aborted);
                try writeJsonField("willRetry", stringify, payload.will_retry);
                if (payload.error_message) |message| try writeJsonField("errorMessage", stringify, message);
                try stringify.endObject();
            },
            .auto_retry_start => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "auto_retry_start");
                try writeJsonField("attempt", stringify, payload.attempt);
                try writeJsonField("maxAttempts", stringify, payload.max_attempts);
                try writeJsonField("delayMs", stringify, payload.delay_ms);
                try writeJsonField("errorMessage", stringify, payload.error_message);
                try stringify.endObject();
            },
            .auto_retry_end => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "auto_retry_end");
                try writeJsonField("success", stringify, payload.success);
                try writeJsonField("attempt", stringify, payload.attempt);
                if (payload.final_error) |err| try writeJsonField("finalError", stringify, err);
                try stringify.endObject();
            },
            .event_overflow => |payload| {
                try stringify.beginObject();
                try writeJsonField("type", stringify, "public_event_overflow");
                try writeJsonField("droppedCount", stringify, payload.dropped_count);
                try stringify.endObject();
            },
            .rejected => |payload| try stringify.write(.{ .type = "rejected", .message = payload.message.text }),
            .response => |payload| try stringify.write(.{ .type = "response", .response = payload }),
        }
    }
};

pub const Rejection = struct {
    code: Code,
    message: EventText,

    pub const Code = enum {
        busy,
        queue_full,
        shutting_down,
        invalid_command,
        overflow,
    };
};

pub const Response = union(enum) {
    prompt_finished,
    canceled,
    queue_cleared,
    shutdown_started,
};

pub const EventText = struct {
    allocator: std.mem.Allocator,
    text: []const u8,

    pub fn init(allocator: std.mem.Allocator, text: []const u8) !EventText {
        return .{ .allocator = allocator, .text = try allocator.dupe(u8, text) };
    }

    pub fn initOwned(allocator: std.mem.Allocator, text: []const u8) EventText {
        return .{ .allocator = allocator, .text = text };
    }

    pub fn deinit(self: *EventText) void {
        self.allocator.free(self.text);
        self.* = undefined;
    }

    pub fn jsonStringify(self: EventText, stringify: *std.json.Stringify) !void {
        try stringify.write(self.text);
    }
};

pub const EventTextList = struct {
    allocator: std.mem.Allocator,
    items: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, source: []const []const u8) !EventTextList {
        const items = try allocator.alloc([]const u8, source.len);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |item| allocator.free(item);
        }
        for (source) |text| {
            items[initialized] = try allocator.dupe(u8, text);
            initialized += 1;
        }
        return .{ .allocator = allocator, .items = items };
    }

    pub fn deinit(self: *EventTextList) void {
        for (self.items) |item| self.allocator.free(item);
        self.allocator.free(self.items);
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
        return .{
            .summary = try EventText.init(allocator, entry.summary),
            .first_kept_entry_id = try EventText.init(allocator, entry.first_kept_entry_id),
            .tokens_before = entry.tokens_before,
        };
    }

    pub fn deinit(self: *CompactionResult) void {
        self.summary.deinit();
        self.first_kept_entry_id.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: CompactionResult, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("summary", stringify, self.summary);
        try writeJsonField("firstKeptEntryId", stringify, self.first_kept_entry_id);
        try writeJsonField("tokensBefore", stringify, self.tokens_before);
        try stringify.endObject();
    }
};

pub const OwnedAgentEvent = struct {
    allocator: std.mem.Allocator,
    event: agent_mod.AgentEvent,

    pub fn init(allocator: std.mem.Allocator, event: agent_mod.AgentEvent) !OwnedAgentEvent {
        return .{ .allocator = allocator, .event = try agent_mod.copyAgentEvent(allocator, event) };
    }

    pub fn deinit(self: *OwnedAgentEvent) void {
        agent_mod.deinitAgentEvent(self.allocator, self.event);
        self.* = undefined;
    }

    pub fn jsonStringify(self: OwnedAgentEvent, stringify: *std.json.Stringify) !void {
        try stringify.write(self.event);
    }
};

pub const QueueUpdate = struct {
    steering: EventTextList,
    follow_up: EventTextList,
    revision: u64,

    pub fn deinit(self: *QueueUpdate) void {
        self.steering.deinit();
        self.follow_up.deinit();
        self.* = undefined;
    }
};

pub const PromptCommandResult = enum {
    handled,
    unknown,
};

pub const PromptCommand = struct {
    command: EventText,
    result: PromptCommandResult,
    message: EventText,

    pub fn deinit(self: *PromptCommand) void {
        self.command.deinit();
        self.message.deinit();
        self.* = undefined;
    }
};

pub const CompactionReason = enum {
    manual,
    threshold,
    overflow,
};

pub const CompactionStart = struct {
    reason: CompactionReason,
};

pub const SessionInfoChanged = struct {
    name: ?EventText,
};

pub const CompactionEnd = struct {
    reason: CompactionReason,
    result: ?CompactionResult = null,
    aborted: bool,
    will_retry: bool,
    error_message: ?EventText = null,

    pub fn deinit(self: *CompactionEnd) void {
        if (self.result) |*result| result.deinit();
        if (self.error_message) |*message| message.deinit();
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

pub const Snapshot = struct {
    header: SessionHeaderSnapshot,
    model: ModelSnapshot,
    queue: QueueSnapshot,
    active_request_id: ?RequestId,
    history: HistorySnapshot,

    pub fn init(
        allocator: std.mem.Allocator,
        header: session_manager.SessionHeader,
        model: ai.Model,
        queue: QueueSnapshot,
        active_request_id: ?RequestId,
        history_items: []const HistorySnapshotItem.Source,
    ) !Snapshot {
        var owned_header = try SessionHeaderSnapshot.init(allocator, header);
        errdefer owned_header.deinit();
        var owned_model = try ModelSnapshot.init(allocator, model);
        errdefer owned_model.deinit();
        var owned_history = try HistorySnapshot.init(allocator, history_items);
        errdefer owned_history.deinit();
        return .{
            .header = owned_header,
            .model = owned_model,
            .queue = queue,
            .active_request_id = active_request_id,
            .history = owned_history,
        };
    }

    pub fn deinit(self: *Snapshot) void {
        self.header.deinit();
        self.model.deinit();
        self.queue.deinit();
        self.history.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: Snapshot, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("type", stringify, "snapshot");
        try writeJsonField("header", stringify, self.header);
        try writeJsonField("model", stringify, self.model);
        try writeJsonField("queue", stringify, self.queue);
        if (self.active_request_id) |id| try writeJsonField("activeRequestId", stringify, id);
        try writeJsonField("history", stringify, self.history);
        try stringify.endObject();
    }
};

pub const SessionHeaderSnapshot = struct {
    id: EventText,
    timestamp: EventText,
    cwd: EventText,
    parent_session: ?EventText = null,
    version: u32,

    pub fn init(allocator: std.mem.Allocator, header: session_manager.SessionHeader) !SessionHeaderSnapshot {
        var id = try EventText.init(allocator, header.id);
        errdefer id.deinit();
        var timestamp = try EventText.init(allocator, header.timestamp);
        errdefer timestamp.deinit();
        var cwd = try EventText.init(allocator, header.cwd);
        errdefer cwd.deinit();
        var parent_session: ?EventText = if (header.parent_session) |parent|
            try EventText.init(allocator, parent)
        else
            null;
        errdefer if (parent_session) |*parent| parent.deinit();
        return .{
            .id = id,
            .timestamp = timestamp,
            .cwd = cwd,
            .parent_session = parent_session,
            .version = header.version,
        };
    }

    pub fn deinit(self: *SessionHeaderSnapshot) void {
        self.id.deinit();
        self.timestamp.deinit();
        self.cwd.deinit();
        if (self.parent_session) |*parent| parent.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: SessionHeaderSnapshot, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("version", stringify, self.version);
        try writeJsonField("id", stringify, self.id);
        try writeJsonField("timestamp", stringify, self.timestamp);
        try writeJsonField("cwd", stringify, self.cwd);
        if (self.parent_session) |parent| try writeJsonField("parentSession", stringify, parent);
        try stringify.endObject();
    }
};

pub const ModelSnapshot = struct {
    provider: EventText,
    id: EventText,

    pub fn init(allocator: std.mem.Allocator, model: ai.Model) !ModelSnapshot {
        var provider = try EventText.init(allocator, utf8Prefix(model.provider, snapshot_model_text_bytes_max));
        errdefer provider.deinit();
        var id = try EventText.init(allocator, utf8Prefix(model.id, snapshot_model_text_bytes_max));
        errdefer id.deinit();
        return .{ .provider = provider, .id = id };
    }

    pub fn deinit(self: *ModelSnapshot) void {
        self.provider.deinit();
        self.id.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: ModelSnapshot, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("provider", stringify, self.provider);
        try writeJsonField("id", stringify, self.id);
        try stringify.endObject();
    }
};

pub const HistorySnapshot = struct {
    items: []HistorySnapshotItem,
    allocator: std.mem.Allocator,
    dropped_items: usize = 0,
    dropped_text_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, source: []const HistorySnapshotItem.Source) !HistorySnapshot {
        const keep_count = @min(source.len, snapshot_history_items_max);
        const dropped_items = source.len - keep_count;
        const start = source.len - keep_count;
        var items = try allocator.alloc(HistorySnapshotItem, keep_count);
        errdefer allocator.free(items);
        var initialized: usize = 0;
        errdefer {
            for (items[0..initialized]) |*item| item.deinit();
        }
        var total_text_bytes: usize = 0;
        var dropped_text_bytes: usize = 0;
        for (source[start..]) |item| {
            const text = utf8Prefix(item.text, snapshot_history_item_text_bytes_max);
            dropped_text_bytes += item.text.len - text.len;
            if (total_text_bytes + text.len > snapshot_history_total_text_bytes_max) {
                dropped_text_bytes += text.len;
                continue;
            }
            items[initialized] = try HistorySnapshotItem.init(allocator, item.role, text);
            initialized += 1;
            total_text_bytes += text.len;
        }
        return .{
            .items = try allocator.realloc(items, initialized),
            .allocator = allocator,
            .dropped_items = dropped_items + (keep_count - initialized),
            .dropped_text_bytes = dropped_text_bytes,
        };
    }

    pub fn deinit(self: *HistorySnapshot) void {
        for (self.items) |*item| item.deinit();
        self.allocator.free(self.items);
        self.* = undefined;
    }

    pub fn jsonStringify(self: HistorySnapshot, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("items", stringify, self.items);
        try writeJsonField("droppedItems", stringify, self.dropped_items);
        try writeJsonField("droppedTextBytes", stringify, self.dropped_text_bytes);
        try stringify.endObject();
    }
};

pub const HistorySnapshotItem = struct {
    role: Role,
    text: EventText,

    pub const Source = struct {
        role: Role,
        text: []const u8,
    };

    pub const Role = enum { user, assistant, system };

    pub fn init(allocator: std.mem.Allocator, role: Role, text: []const u8) !HistorySnapshotItem {
        return .{ .role = role, .text = try EventText.init(allocator, text) };
    }

    pub fn deinit(self: *HistorySnapshotItem) void {
        self.text.deinit();
        self.* = undefined;
    }
};

pub const QueueSnapshot = struct {
    revision: u64,
    steering: EventTextList,
    follow_up: EventTextList,

    pub fn deinit(self: *QueueSnapshot) void {
        self.steering.deinit();
        self.follow_up.deinit();
        self.* = undefined;
    }

    pub fn jsonStringify(self: QueueSnapshot, stringify: *std.json.Stringify) !void {
        try stringify.beginObject();
        try writeJsonField("revision", stringify, self.revision);
        try writeJsonField("steering", stringify, self.steering);
        try writeJsonField("followUp", stringify, self.follow_up);
        try stringify.endObject();
    }
};

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
    try std.testing.expectEqualStrings("hello", envelope.command.submit_prompt.text);
}

test "event envelope deinitializes owned client event" {
    var event: EventEnvelope = .{ .event = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try EventText.init(std.testing.allocator, "ok"),
    } } };
    event.deinit(std.testing.allocator);
}

test "history snapshot caps item count" {
    var source: [snapshot_history_items_max + 1]HistorySnapshotItem.Source = undefined;
    for (&source, 0..) |*item, index| {
        item.* = .{ .role = .user, .text = if (index == 0) "drop" else "keep" };
    }

    var snapshot = try HistorySnapshot.init(std.testing.allocator, &source);
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, snapshot_history_items_max), snapshot.items.len);
    try std.testing.expectEqual(@as(usize, 1), snapshot.dropped_items);
    try std.testing.expectEqualStrings("keep", snapshot.items[0].text.text);
}

test "history snapshot caps text bytes and reports truncation" {
    const oversized = "a" ** (snapshot_history_item_text_bytes_max + 4);
    var snapshot = try HistorySnapshot.init(std.testing.allocator, &.{.{ .role = .assistant, .text = oversized }});
    defer snapshot.deinit();

    try std.testing.expectEqual(@as(usize, 1), snapshot.items.len);
    try std.testing.expectEqual(@as(usize, 4), snapshot.dropped_text_bytes);
    try std.testing.expectEqual(@as(usize, snapshot_history_item_text_bytes_max), snapshot.items[0].text.text.len);
}

test "prompt command event serializes public shape" {
    var unknown_event: ClientEvent = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "missing"),
        .result = .unknown,
        .message = try EventText.init(std.testing.allocator, "unknown command: /missing"),
    } };
    defer unknown_event.deinit();

    var unknown_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer unknown_writer.deinit();

    try std.json.Stringify.value(unknown_event, .{}, &unknown_writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt_command\",\"command\":\"missing\",\"result\":\"unknown\"," ++
            "\"message\":\"unknown command: /missing\"}",
        unknown_writer.written(),
    );

    var handled_event: ClientEvent = .{ .prompt_command = .{
        .command = try EventText.init(std.testing.allocator, "help"),
        .result = .handled,
        .message = try EventText.init(std.testing.allocator, "available commands: /help, /session"),
    } };
    defer handled_event.deinit();

    var handled_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer handled_writer.deinit();

    try std.json.Stringify.value(handled_event, .{}, &handled_writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"prompt_command\",\"command\":\"help\",\"result\":\"handled\"," ++
            "\"message\":\"available commands: /help, /session\"}",
        handled_writer.written(),
    );
}

test "failed compaction end event omits result" {
    var event: ClientEvent = .{ .compaction_end = .{
        .reason = .manual,
        .aborted = true,
        .will_retry = false,
        .error_message = try EventText.init(std.testing.allocator, "not implemented"),
    } };
    defer event.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"aborted\":true," ++
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
        .reason = .manual,
        .result = try CompactionResult.init(
            std.testing.allocator,
            manager.entries.items[1].compaction,
        ),
        .aborted = false,
        .will_retry = false,
    } };
    defer event.deinit();

    var writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer writer.deinit();

    try std.json.Stringify.value(event, .{}, &writer.writer);

    try std.testing.expectEqualStrings(
        "{\"type\":\"compaction_end\",\"reason\":\"manual\",\"result\":{\"summary\":\"summary\"," ++
            "\"firstKeptEntryId\":\"00000001\",\"tokensBefore\":42},\"aborted\":false,\"willRetry\":false}",
        writer.written(),
    );
}
