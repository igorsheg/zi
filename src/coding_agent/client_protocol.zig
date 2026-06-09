const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const runtime = @import("../runtime/root.zig");
const session_manager = @import("session_manager.zig");

pub const RequestId = u64;

pub const command_queue_capacity_default = 64;
pub const event_queue_capacity_default = 256;

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
    snapshot_sent,
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

pub const QueueSnapshot = struct {
    revision: u64,
    steering: EventTextList,
    follow_up: EventTextList,

    pub fn deinit(self: *QueueSnapshot) void {
        self.steering.deinit();
        self.follow_up.deinit();
        self.* = undefined;
    }
};

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
