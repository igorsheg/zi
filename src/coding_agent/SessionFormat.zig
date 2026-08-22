const std = @import("std");
const bounded_json = @import("../BoundedJson.zig");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const ai_message = ai.message;
const ai_usage = ai.usage;

pub const max_header_bytes = 64 * 1024;
pub const max_record_bytes = 64 * 1024 * 1024;
pub const max_journal_bytes = 64 * 1024 * 1024;
pub const max_entries = 65_536;
const max_value_bytes = 64 * 1024 * 1024;
const max_json_depth = 32;
const max_collection_items = 4096;
const max_id_bytes = 128;
const max_provider_id_bytes = 256;
const max_model_id_bytes = 512;
const max_tool_call_id_bytes = 4 * 1024;
const max_tool_name_bytes = 256;
const max_tool_arguments_bytes = 1024 * 1024;
const max_path_bytes = 32 * 1024;
const max_unresolved_tool_calls = 64;

pub const Error = error{
    OutOfMemory,
    InvalidHeader,
    InvalidRecord,
    UnsupportedVersion,
    SessionTooLarge,
    TooManyEntries,
};

pub const Header = struct {
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
};

pub const OwnedHeader = struct {
    arena: std.heap.ArenaAllocator,
    value: Header,

    pub fn deinit(self: *OwnedHeader) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn decodeOwnedHeader(
    allocator: std.mem.Allocator,
    encoded_header: []const u8,
) Error!OwnedHeader {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const value = try decodeHeader(allocator, arena.allocator(), encoded_header);
    return .{
        .arena = arena,
        .value = value,
    };
}

/// Fixed-width canonical session id text.
pub const stamp_id_width = 36;

/// Formats one 128-bit id into its fixed-width text. The hex field widths
/// 8+1+4+1+4+1+4+1+12 compose to exactly stamp_id_width, so the print cannot
/// run out of space; keeping the proof here means every stamp site shares it.
fn writeStampId(buffer: *[stamp_id_width]u8, id_bytes: *const [16]u8) void {
    _ = std.fmt.bufPrint(
        buffer,
        "{x:0>8}-{x:0>4}-{x:0>4}-{x:0>4}-{x:0>12}",
        .{
            std.mem.readInt(u32, id_bytes[0..4], .big),
            std.mem.readInt(u16, id_bytes[4..6], .big),
            std.mem.readInt(u16, id_bytes[6..8], .big),
            std.mem.readInt(u16, id_bytes[8..10], .big),
            std.mem.readInt(u48, id_bytes[10..16], .big),
        },
    ) catch unreachable;
}

pub const Sources = struct {
    id_context: *anyopaque,
    nextIdFn: *const fn (context: *anyopaque) [16]u8,
    clock_context: *anyopaque,
    nowMsFn: *const fn (context: *anyopaque) u64,

    pub fn next(self: Sources) Error!Stamp {
        const id_bytes = self.nextIdFn(self.id_context);
        const unix_ms = self.nowMsFn(self.clock_context);
        var stamp: Stamp = undefined;
        writeStampId(&stamp.id_buffer, &id_bytes);
        try formatTimestamp(&stamp.timestamp_buffer, unix_ms);
        return stamp;
    }
};

pub const Stamp = struct {
    id_buffer: [36]u8,
    timestamp_buffer: [24]u8,

    pub fn id(self: *const Stamp) []const u8 {
        return &self.id_buffer;
    }

    pub fn timestamp(self: *const Stamp) []const u8 {
        return &self.timestamp_buffer;
    }

    pub fn base(self: *const Stamp, parent_id: ?[]const u8) EntryBase {
        return .{
            .id = self.id(),
            .parent_id = parent_id,
            .timestamp = self.timestamp(),
        };
    }
};

pub const EntryBase = struct {
    id: []const u8,
    parent_id: ?[]const u8,
    timestamp: []const u8,
};

pub const FailureCategory = enum {
    resource_exhausted,
    timed_out,
    unsupported_capability,
    unsupported_setting,
    invalid_request,
    connection_failed,
    rate_limited,
    provider_rejected_request,
    provider_unavailable,
    invalid_provider_response,
    stream_interrupted,
    stream_consumer_stopped,
    handoff_rejected,
    max_model_requests_exceeded,
    max_tool_calls_exceeded,
    tool_result_too_large,
    tool_control_unavailable,
    persistence_failed,
};

pub const TurnOutcome = union(enum) {
    completed,
    failed: FailureCategory,
    cancelled,
    interrupted,
};

pub const Entry = union(enum) {
    message: MessageEntry,
    model_change: ModelChangeEntry,
    turn_end: TurnEndEntry,

    pub fn base(self: Entry) EntryBase {
        return switch (self) {
            inline else => |entry| entry.base,
        };
    }
};

pub const MessageEntry = struct {
    base: EntryBase,
    message: ai_message.Message,
};

pub const ModelChangeEntry = struct {
    base: EntryBase,
    selection: ai_message.ModelIdentity,
};

pub const TurnEndEntry = struct {
    base: EntryBase,
    turn_id: []const u8,
    outcome: TurnOutcome,
};

pub const Recovery = union(enum) {
    clean,
    interrupted: struct { turn_id: []const u8 },
};

pub const Restored = struct {
    arena: std.heap.ArenaAllocator,
    header: Header,
    entries: []const Entry,
    active_leaf_id: ?[]const u8,
    active_model: ?ai_message.ModelIdentity,
    context_messages: []const ai_message.Message,
    recovery: Recovery,

    pub fn deinit(self: *Restored) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Restorer = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    header: Header,
    entries: std.ArrayList(Entry) = .empty,
    by_id: std.StringHashMapUnmanaged(usize) = .empty,
    encoded_bytes: usize,

    pub fn init(
        allocator: std.mem.Allocator,
        encoded_header: []const u8,
    ) Error!Restorer {
        if (encoded_header.len > max_header_bytes) return error.InvalidHeader;
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const header = try decodeHeader(allocator, arena.allocator(), encoded_header);
        const encoded_bytes = std.math.add(usize, encoded_header.len, 1) catch
            return error.SessionTooLarge;
        if (encoded_bytes > max_journal_bytes) return error.SessionTooLarge;
        return .{
            .allocator = allocator,
            .arena = arena,
            .header = header,
            .encoded_bytes = encoded_bytes,
        };
    }

    pub fn deinit(self: *Restorer) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn append(self: *Restorer, encoded_record: []const u8) Error!void {
        if (self.entries.items.len >= max_entries) return error.TooManyEntries;
        if (encoded_record.len > max_record_bytes) return error.InvalidRecord;
        const record_bytes = std.math.add(usize, encoded_record.len, 1) catch
            return error.SessionTooLarge;
        const encoded_bytes = std.math.add(usize, self.encoded_bytes, record_bytes) catch
            return error.SessionTooLarge;
        if (encoded_bytes > max_journal_bytes) return error.SessionTooLarge;

        const entry = try decodeEntry(self.allocator, self.arena.allocator(), encoded_record);
        const base = entry.base();
        if (self.by_id.contains(base.id)) return error.InvalidRecord;
        if (self.entries.items.len == 0) {
            if (base.parent_id != null) return error.InvalidRecord;
        } else {
            const parent_id = base.parent_id orelse return error.InvalidRecord;
            if (!self.by_id.contains(parent_id)) return error.InvalidRecord;
        }

        try self.entries.append(self.arena.allocator(), entry);
        try self.by_id.put(self.arena.allocator(), base.id, self.entries.items.len - 1);
        self.encoded_bytes = encoded_bytes;
    }

    pub fn finish(self: *Restorer) Error!Restored {
        const projection = try project(
            self.arena.allocator(),
            self.entries.items,
            &self.by_id,
        );
        const result: Restored = .{
            .arena = self.arena,
            .header = self.header,
            .entries = self.entries.items,
            .active_leaf_id = if (self.entries.items.len == 0)
                null
            else
                self.entries.items[self.entries.items.len - 1].base().id,
            .active_model = projection.active_model,
            .context_messages = projection.context_messages,
            .recovery = projection.recovery,
        };
        self.* = undefined;
        return result;
    }
};

const WireHeader = struct {
    type: []const u8,
    version: u32,
    id: []const u8,
    timestamp: []const u8,
    cwd: []const u8,
};

const WireBase = struct {
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
};

const WireRecordKind = struct {
    type: []const u8,
};

const WireMessageEntry = struct {
    type: []const u8,
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    message: WireMessage,
};

const WireModelChangeEntry = struct {
    type: []const u8,
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    provider: []const u8,
    modelId: []const u8,
};

const WireTurnEndEntry = struct {
    type: []const u8,
    id: []const u8,
    parentId: ?[]const u8,
    timestamp: []const u8,
    turnId: []const u8,
    outcome: WireTurnOutcome,
    failure: ?FailureCategory = null,
};

const WireTurnOutcome = enum {
    completed,
    failed,
    cancelled,
    interrupted,
};

const WireMessage = union(enum) {
    request: WireRequest,
    response: WireResponse,
};

const WireRequest = struct {
    parts: []const WireRequestPart,
};

const WireRequestPart = union(enum) {
    user: WireUser,
    toolResult: WireToolResult,
};

const WireUser = struct {
    text: []const u8,
};

const WireToolResult = struct {
    callId: []const u8,
    name: []const u8,
    content: []const WireContent,
    outcome: ai_message.ToolResult.Outcome,
};

const WireContent = union(enum) {
    text: []const u8,
};

const WireResponse = struct {
    parts: []const WireResponsePart,
    provider: []const u8,
    model: []const u8,
    usage: WireUsage,
    finish: WireFinish,
};

const WireResponsePart = union(enum) {
    text: WireTextPart,
    thinking: WireThinkingPart,
    toolCall: WireToolCall,
};

const WireTextPart = struct {
    text: []const u8,
    providerState: ?WireProviderState = null,
};

const WireThinkingPart = struct {
    text: []const u8,
    providerState: ?WireProviderState = null,
};

const WireToolCall = struct {
    id: []const u8,
    name: []const u8,
    arguments: []const u8,
    providerState: ?WireProviderState = null,
};

const WireProviderState = struct {
    provider: []const u8,
    protocol: []const u8,
    value: std.json.Value,
};

const WireUsage = struct {
    inputTokens: u64,
    outputTokens: u64,
    cachedInputTokens: u64,
    reasoningTokens: u64,
};

const WireFinish = struct {
    category: ai_usage.FinishCategory,
    rawReason: ?[]const u8,
};

fn decodeHeader(
    scratch: std.mem.Allocator,
    allocator: std.mem.Allocator,
    encoded: []const u8,
) Error!Header {
    try preflight(scratch, error.InvalidHeader, encoded, max_header_bytes);
    const wire = std.json.parseFromSliceLeaky(WireHeader, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_header_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidHeader,
    };
    if (!std.mem.eql(u8, wire.type, "session")) return error.InvalidHeader;
    if (wire.version != 1) return error.UnsupportedVersion;
    try validateIdentifier(error.InvalidHeader, wire.id, max_id_bytes);
    try validateTimestamp(error.InvalidHeader, wire.timestamp);
    try validatePath(error.InvalidHeader, wire.cwd);
    const normalized = std.fs.path.resolve(allocator, &.{wire.cwd}) catch
        return error.OutOfMemory;
    if (!std.mem.eql(u8, normalized, wire.cwd)) return error.InvalidHeader;
    return .{
        .id = wire.id,
        .timestamp = wire.timestamp,
        .cwd = normalized,
    };
}

fn decodeEntry(
    scratch: std.mem.Allocator,
    allocator: std.mem.Allocator,
    encoded: []const u8,
) Error!Entry {
    try preflight(scratch, error.InvalidRecord, encoded, max_record_bytes);
    const kind = std.json.parseFromSliceLeaky(WireRecordKind, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = true,
        .max_value_len = max_value_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRecord,
    };
    if (std.mem.eql(u8, kind.type, "message")) {
        const wire = try parseWire(WireMessageEntry, allocator, encoded);
        if (!std.mem.eql(u8, wire.type, "message")) return error.InvalidRecord;
        const base = try decodeBase(.{
            .id = wire.id,
            .parentId = wire.parentId,
            .timestamp = wire.timestamp,
        });
        return .{ .message = .{
            .base = base,
            .message = try decodeMessage(scratch, allocator, wire.message),
        } };
    }
    if (std.mem.eql(u8, kind.type, "model_change")) {
        const wire = try parseWire(WireModelChangeEntry, allocator, encoded);
        if (!std.mem.eql(u8, wire.type, "model_change")) return error.InvalidRecord;
        try validateIdentifier(error.InvalidRecord, wire.provider, max_provider_id_bytes);
        try validateIdentifier(error.InvalidRecord, wire.modelId, max_model_id_bytes);
        return .{ .model_change = .{
            .base = try decodeBase(.{
                .id = wire.id,
                .parentId = wire.parentId,
                .timestamp = wire.timestamp,
            }),
            .selection = .{ .provider = wire.provider, .model = wire.modelId },
        } };
    }
    if (std.mem.eql(u8, kind.type, "turn_end")) {
        const wire = try parseWire(WireTurnEndEntry, allocator, encoded);
        if (!std.mem.eql(u8, wire.type, "turn_end")) return error.InvalidRecord;
        try validateIdentifier(error.InvalidRecord, wire.turnId, max_id_bytes);
        const outcome: TurnOutcome = switch (wire.outcome) {
            .completed => completed: {
                if (wire.failure != null) return error.InvalidRecord;
                break :completed .completed;
            },
            .failed => .{ .failed = wire.failure orelse return error.InvalidRecord },
            .cancelled => cancelled: {
                if (wire.failure != null) return error.InvalidRecord;
                break :cancelled .cancelled;
            },
            .interrupted => interrupted: {
                if (wire.failure != null) return error.InvalidRecord;
                break :interrupted .interrupted;
            },
        };
        return .{ .turn_end = .{
            .base = try decodeBase(.{
                .id = wire.id,
                .parentId = wire.parentId,
                .timestamp = wire.timestamp,
            }),
            .turn_id = wire.turnId,
            .outcome = outcome,
        } };
    }
    return error.InvalidRecord;
}

fn parseWire(
    comptime T: type,
    allocator: std.mem.Allocator,
    encoded: []const u8,
) Error!T {
    return std.json.parseFromSliceLeaky(T, allocator, encoded, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = max_value_bytes,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRecord,
    };
}

fn decodeBase(wire: WireBase) Error!EntryBase {
    try validateIdentifier(error.InvalidRecord, wire.id, max_id_bytes);
    if (wire.parentId) |parent_id| {
        try validateIdentifier(error.InvalidRecord, parent_id, max_id_bytes);
        if (std.mem.eql(u8, wire.id, parent_id)) return error.InvalidRecord;
    }
    try validateTimestamp(error.InvalidRecord, wire.timestamp);
    return .{
        .id = wire.id,
        .parent_id = wire.parentId,
        .timestamp = wire.timestamp,
    };
}

fn decodeMessage(
    scratch: std.mem.Allocator,
    allocator: std.mem.Allocator,
    wire: WireMessage,
) Error!ai_message.Message {
    return switch (wire) {
        .request => |request| .{ .request = .{
            .parts = try decodeRequestParts(allocator, request.parts),
        } },
        .response => |response| .{ .response = try decodeResponse(scratch, allocator, response) },
    };
}

fn decodeRequestParts(
    allocator: std.mem.Allocator,
    wire_parts: []const WireRequestPart,
) Error![]const ai_message.RequestPart {
    if (wire_parts.len == 0 or wire_parts.len > max_collection_items) return error.InvalidRecord;
    const parts = try allocator.alloc(ai_message.RequestPart, wire_parts.len);
    for (wire_parts, parts) |wire, *part| part.* = switch (wire) {
        .user => |user| user_part: {
            try validateMessageText(user.text);
            break :user_part .{ .user = .{ .text = user.text } };
        },
        .toolResult => |result| .{ .tool_result = .{
            .call_id = try validatedToolCallId(result.callId),
            .name = try validatedToolName(result.name),
            .content = try decodeContent(allocator, result.content),
            .outcome = result.outcome,
        } },
    };
    return parts;
}

fn decodeContent(
    allocator: std.mem.Allocator,
    wire_content: []const WireContent,
) Error![]const ai_message.Content {
    if (wire_content.len == 0 or wire_content.len > max_collection_items) return error.InvalidRecord;
    const content = try allocator.alloc(ai_message.Content, wire_content.len);
    for (wire_content, content) |wire, *item| item.* = switch (wire) {
        .text => |value| text: {
            try validateMessageText(value);
            break :text .{ .text = value };
        },
    };
    return content;
}

fn decodeResponse(
    scratch: std.mem.Allocator,
    allocator: std.mem.Allocator,
    wire: WireResponse,
) Error!ai_message.ResponseMessage {
    if (wire.parts.len > max_collection_items) return error.InvalidRecord;
    try validateIdentifier(error.InvalidRecord, wire.provider, max_provider_id_bytes);
    try validateIdentifier(error.InvalidRecord, wire.model, max_model_id_bytes);
    if (wire.finish.rawReason) |reason| {
        if (reason.len > 4096 or !std.unicode.utf8ValidateSlice(reason)) return error.InvalidRecord;
    }

    const parts = try allocator.alloc(ai_message.ResponsePart, wire.parts.len);
    for (wire.parts, parts) |wire_part, *part| part.* = switch (wire_part) {
        .text => |text| value: {
            try validateMessageText(text.text);
            break :value .{ .text = .{
                .text = text.text,
                .provider_state = try decodeProviderState(text.providerState, wire.provider),
            } };
        },
        .thinking => |thinking| value: {
            try validateMessageText(thinking.text);
            break :value .{ .thinking = .{
                .text = thinking.text,
                .provider_state = try decodeProviderState(thinking.providerState, wire.provider),
            } };
        },
        .toolCall => |call| value: {
            try validateToolArguments(scratch, call.arguments);
            break :value .{ .tool_call = .{
                .id = try validatedToolCallId(call.id),
                .name = try validatedToolName(call.name),
                .arguments_json = call.arguments,
                .provider_state = try decodeProviderState(call.providerState, wire.provider),
            } };
        },
    };
    return .{
        .parts = parts,
        .identity = .{ .provider = wire.provider, .model = wire.model },
        .usage = .{
            .input_tokens = wire.usage.inputTokens,
            .output_tokens = wire.usage.outputTokens,
            .cached_input_tokens = wire.usage.cachedInputTokens,
            .reasoning_tokens = wire.usage.reasoningTokens,
        },
        .finish = .{
            .category = wire.finish.category,
            .raw_reason = wire.finish.rawReason,
        },
    };
}

fn decodeProviderState(
    wire: ?WireProviderState,
    response_provider: []const u8,
) Error!?ai_message.ProviderState {
    const state = wire orelse return null;
    try validateIdentifier(error.InvalidRecord, state.provider, max_provider_id_bytes);
    try validateIdentifier(error.InvalidRecord, state.protocol, 256);
    if (!std.mem.eql(u8, state.provider, response_provider)) return error.InvalidRecord;
    return .{
        .provider = state.provider,
        .protocol = state.protocol,
        .value = state.value,
    };
}

fn preflight(
    allocator: std.mem.Allocator,
    comptime invalid: Error,
    encoded: []const u8,
    document_bytes: usize,
) Error!void {
    bounded_json.validate(allocator, encoded, .{
        .document_bytes = document_bytes,
        .value_bytes = max_value_bytes,
        .depth = max_json_depth,
        .collection_items = max_collection_items,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return invalid,
    };
}

fn validateIdentifier(comptime invalid: Error, value: []const u8, maximum: usize) Error!void {
    if (value.len == 0 or value.len > maximum or !std.unicode.utf8ValidateSlice(value)) return invalid;
    for (value) |byte| {
        if (std.ascii.isControl(byte) or std.ascii.isWhitespace(byte)) return invalid;
    }
}

fn validatePath(comptime invalid: Error, value: []const u8) Error!void {
    if (value.len == 0 or value.len > max_path_bytes or !std.unicode.utf8ValidateSlice(value)) return invalid;
    if (std.mem.indexOfScalar(u8, value, 0) != null or !std.fs.path.isAbsolute(value)) return invalid;
}

fn validateMessageText(value: []const u8) Error!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidRecord;
}

fn validatedToolCallId(value: []const u8) Error![]const u8 {
    try validateIdentifier(error.InvalidRecord, value, max_tool_call_id_bytes);
    return value;
}

fn validatedToolName(value: []const u8) Error![]const u8 {
    try validateIdentifier(error.InvalidRecord, value, max_tool_name_bytes);
    return value;
}

fn validateToolArguments(allocator: std.mem.Allocator, encoded: []const u8) Error!void {
    if (encoded.len > max_tool_arguments_bytes) return error.InvalidRecord;
    bounded_json.validate(allocator, encoded, .{
        .document_bytes = max_tool_arguments_bytes,
        .value_bytes = max_tool_arguments_bytes,
        .depth = max_json_depth,
        .collection_items = max_collection_items,
    }) catch |failure| switch (failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRecord,
    };
    var parsed = std.json.parseFromSlice(
        std.json.Value,
        allocator,
        encoded,
        .{},
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRecord,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidRecord;
}

fn validateTimestamp(comptime invalid: Error, value: []const u8) Error!void {
    if (value.len != 24 or value[4] != '-' or value[7] != '-' or value[10] != 'T' or
        value[13] != ':' or value[16] != ':' or value[19] != '.' or value[23] != 'Z')
    {
        return invalid;
    }
    const year = parseTimestampPart(u16, value[0..4]) orelse return invalid;
    const month_number = parseTimestampPart(u4, value[5..7]) orelse return invalid;
    const day = parseTimestampPart(u5, value[8..10]) orelse return invalid;
    const hour = parseTimestampPart(u5, value[11..13]) orelse return invalid;
    const minute = parseTimestampPart(u6, value[14..16]) orelse return invalid;
    const second = parseTimestampPart(u6, value[17..19]) orelse return invalid;
    _ = parseTimestampPart(u10, value[20..23]) orelse return invalid;
    if (year == 0 or month_number < 1 or month_number > 12 or hour > 23 or minute > 59 or second > 59) {
        return invalid;
    }
    const month: std.time.epoch.Month = @enumFromInt(month_number);
    if (day == 0 or day > std.time.epoch.getDaysInMonth(year, month)) return invalid;
}

fn parseTimestampPart(comptime T: type, value: []const u8) ?T {
    for (value) |byte| if (!std.ascii.isDigit(byte)) return null;
    return std.fmt.parseInt(T, value, 10) catch null;
}

fn formatTimestamp(buffer: *[24]u8, unix_ms: u64) Error!void {
    // The clamped range keeps every field within its width, so the widths
    // 4+1+2+1+2+1+2+1+2+1+2+1+3+1 compose to exactly buffer.len below.
    const max_unix_ms = 253_402_300_799_999;
    if (unix_ms > max_unix_ms) return error.InvalidRecord;
    const epoch_seconds: std.time.epoch.EpochSeconds = .{ .secs = unix_ms / 1000 };
    const year_day = epoch_seconds.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_seconds = epoch_seconds.getDaySeconds();
    _ = std.fmt.bufPrint(
        buffer,
        "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.{d:0>3}Z",
        .{
            year_day.year,
            month_day.month.numeric(),
            month_day.day_index + 1,
            day_seconds.getHoursIntoDay(),
            day_seconds.getMinutesIntoHour(),
            day_seconds.getSecondsIntoMinute(),
            unix_ms % 1000,
        },
    ) catch unreachable;
}

const Projection = struct {
    active_model: ?ai_message.ModelIdentity,
    context_messages: []const ai_message.Message,
    recovery: Recovery,
};

const BranchState = struct {
    model: ?ai_message.ModelIdentity = null,
    turn_id: ?[]const u8 = null,
    pending_response: ?usize = null,
    resolved_calls: u64 = 0,
    call_count: u7 = 0,
    final_response_seen: bool = false,
};

const RequestKind = enum { user, tool_results };

const ProjectedTurn = struct {
    id: []const u8,
    context: agent.context_projection.State = .{},
};

const ProjectionTurn = union(enum) {
    idle,
    active: ProjectedTurn,
};

fn project(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    by_id: *const std.StringHashMapUnmanaged(usize),
) Error!Projection {
    const states = try validateBranches(allocator, entries, by_id);
    var path: std.ArrayList(usize) = .empty;
    if (entries.len > 0) {
        var index = entries.len - 1;
        while (true) {
            try path.append(allocator, index);
            const parent_id = entries[index].base().parent_id orelse break;
            index = by_id.get(parent_id) orelse return error.InvalidRecord;
        }
        std.mem.reverse(usize, path.items);
    }

    var context: std.ArrayList(ai_message.Message) = .empty;
    var active_model: ?ai_message.ModelIdentity = null;
    var turn: ProjectionTurn = .idle;
    for (path.items) |index| switch (entries[index]) {
        .model_change => |change| active_model = change.selection,
        .message => |message_entry| {
            switch (message_entry.message) {
                .request => |request| switch (try classifyRequest(request)) {
                    .user => turn = .{ .active = .{ .id = message_entry.base.id } },
                    .tool_results => if (states[index].pending_response == null) {
                        turn.active.context.completeToolExchange();
                    },
                },
                .response => |response| turn.active.context.publishResponse(context.items.len, response),
            }
            try context.append(allocator, message_entry.message);
        },
        .turn_end => |terminal| {
            context.items.len = switch (terminal.outcome) {
                .completed => turn.active.context.completed(context.items.len),
                .failed, .cancelled, .interrupted => turn.active.context.abandoned(context.items.len),
            };
            turn = .idle;
        },
    };

    const recovery: Recovery = switch (turn) {
        .idle => .clean,
        .active => |active_value| interrupted: {
            var active = active_value;
            context.items.len = active.context.abandoned(context.items.len);
            break :interrupted .{ .interrupted = .{ .turn_id = active.id } };
        },
    };
    return .{
        .active_model = active_model,
        .context_messages = context.items,
        .recovery = recovery,
    };
}

fn validateBranches(
    allocator: std.mem.Allocator,
    entries: []const Entry,
    by_id: *const std.StringHashMapUnmanaged(usize),
) Error![]const BranchState {
    const states = try allocator.alloc(BranchState, entries.len);
    for (entries, states, 0..) |entry, *state, index| {
        state.* = if (entry.base().parent_id) |parent_id|
            states[by_id.get(parent_id) orelse return error.InvalidRecord]
        else
            .{};
        switch (entry) {
            .model_change => |change| {
                if (state.turn_id != null) return error.InvalidRecord;
                state.model = change.selection;
            },
            .message => |message_entry| switch (message_entry.message) {
                .request => |request| switch (try classifyRequest(request)) {
                    .user => {
                        if (state.turn_id != null) return error.InvalidRecord;
                        state.turn_id = message_entry.base.id;
                        state.final_response_seen = false;
                    },
                    .tool_results => {
                        if (state.turn_id == null or state.final_response_seen) return error.InvalidRecord;
                        const response_index = state.pending_response orelse return error.InvalidRecord;
                        for (request.parts) |part| try resolveToolResult(
                            &state.resolved_calls,
                            entries[response_index].message.message.response,
                            part.tool_result,
                        );
                        if (state.resolved_calls == resolvedMask(state.call_count)) {
                            state.pending_response = null;
                            state.resolved_calls = 0;
                            state.call_count = 0;
                        }
                    },
                },
                .response => |response| {
                    if (state.turn_id == null or state.pending_response != null or
                        state.final_response_seen) return error.InvalidRecord;
                    const selection = state.model orelse return error.InvalidRecord;
                    if (!sameModel(selection, response.identity)) return error.InvalidRecord;
                    const call_count = try validateResponse(response);
                    if (call_count == 0) {
                        state.final_response_seen = true;
                    } else {
                        state.pending_response = index;
                        state.call_count = @intCast(call_count);
                        state.resolved_calls = 0;
                    }
                },
            },
            .turn_end => |terminal| {
                const turn_id = state.turn_id orelse return error.InvalidRecord;
                if (!std.mem.eql(u8, turn_id, terminal.turn_id)) return error.InvalidRecord;
                switch (terminal.outcome) {
                    .completed => if (!state.final_response_seen or state.pending_response != null) {
                        return error.InvalidRecord;
                    },
                    .failed, .cancelled, .interrupted => {},
                }
                state.turn_id = null;
                state.pending_response = null;
                state.resolved_calls = 0;
                state.call_count = 0;
                state.final_response_seen = false;
            },
        }
    }
    return states;
}

fn classifyRequest(request: ai_message.RequestMessage) Error!RequestKind {
    var user_parts: usize = 0;
    var result_parts: usize = 0;
    for (request.parts) |part| switch (part) {
        .user => user_parts += 1,
        .tool_result => result_parts += 1,
        .retry_prompt => unreachable,
    };
    if (user_parts == request.parts.len) return .user;
    if (result_parts == request.parts.len) return .tool_results;
    return error.InvalidRecord;
}

fn validateResponse(response: ai_message.ResponseMessage) Error!usize {
    const call_count = countToolCalls(response);
    if (call_count > max_unresolved_tool_calls) return error.InvalidRecord;
    for (response.parts, 0..) |part, index| switch (part) {
        .tool_call => |call| for (response.parts[0..index]) |earlier| switch (earlier) {
            .tool_call => |other| if (std.mem.eql(u8, call.id, other.id)) return error.InvalidRecord,
            else => {},
        },
        else => {},
    };
    switch (response.finish.category) {
        .tool_calls => if (call_count == 0) return error.InvalidRecord,
        .stop, .content_filter, .unknown => if (call_count != 0) return error.InvalidRecord,
        .length => {},
        .cancelled, .provider_error => return error.InvalidRecord,
    }
    return call_count;
}

fn countToolCalls(response: ai_message.ResponseMessage) usize {
    var count: usize = 0;
    for (response.parts) |part| switch (part) {
        .tool_call => count += 1,
        else => {},
    };
    return count;
}

fn resolveToolResult(
    resolved_calls: *u64,
    response: ai_message.ResponseMessage,
    result: ai_message.ToolResult,
) Error!void {
    var call_index: usize = 0;
    for (response.parts) |part| switch (part) {
        .tool_call => |call| {
            if (std.mem.eql(u8, call.id, result.call_id)) {
                if (!std.mem.eql(u8, call.name, result.name)) return error.InvalidRecord;
                const bit = @as(u64, 1) << @intCast(call_index);
                if (resolved_calls.* & bit != 0) return error.InvalidRecord;
                resolved_calls.* |= bit;
                return;
            }
            call_index += 1;
        },
        else => {},
    };
    return error.InvalidRecord;
}

fn resolvedMask(call_count: u7) u64 {
    if (call_count == 64) return std.math.maxInt(u64);
    return (@as(u64, 1) << @intCast(call_count)) - 1;
}

fn sameModel(left: ai_message.ModelIdentity, right: ai_message.ModelIdentity) bool {
    return std.mem.eql(u8, left.provider, right.provider) and
        std.mem.eql(u8, left.model, right.model);
}

pub fn encodeHeader(allocator: std.mem.Allocator, header: Header) Error![]u8 {
    try validateIdentifier(error.InvalidHeader, header.id, max_id_bytes);
    try validateTimestamp(error.InvalidHeader, header.timestamp);
    try validatePath(error.InvalidHeader, header.cwd);
    const normalized = std.fs.path.resolve(allocator, &.{header.cwd}) catch return error.OutOfMemory;
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, header.cwd)) return error.InvalidHeader;

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    try writeField(&json, "type", "session");
    try writeField(&json, "version", @as(u32, 1));
    try writeField(&json, "id", header.id);
    try writeField(&json, "timestamp", header.timestamp);
    try writeField(&json, "cwd", header.cwd);
    json.endObject() catch return error.OutOfMemory;
    const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
    if (encoded.len > max_header_bytes) {
        allocator.free(encoded);
        return error.InvalidHeader;
    }
    return encoded;
}

pub fn encodeEntry(allocator: std.mem.Allocator, entry: Entry) Error![]u8 {
    const base = entry.base();
    try validateIdentifier(error.InvalidRecord, base.id, max_id_bytes);
    if (base.parent_id) |parent_id| {
        try validateIdentifier(error.InvalidRecord, parent_id, max_id_bytes);
        if (std.mem.eql(u8, base.id, parent_id)) return error.InvalidRecord;
    }
    try validateTimestamp(error.InvalidRecord, base.timestamp);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    switch (entry) {
        .message => |message| {
            try writeField(&json, "type", "message");
            try writeBase(&json, message.base);
            json.objectField("message") catch return error.OutOfMemory;
            try writeMessage(allocator, &json, message.message);
        },
        .model_change => |change| {
            try validateIdentifier(error.InvalidRecord, change.selection.provider, max_provider_id_bytes);
            try validateIdentifier(error.InvalidRecord, change.selection.model, max_model_id_bytes);
            try writeField(&json, "type", "model_change");
            try writeBase(&json, change.base);
            try writeField(&json, "provider", change.selection.provider);
            try writeField(&json, "modelId", change.selection.model);
        },
        .turn_end => |terminal| {
            try validateIdentifier(error.InvalidRecord, terminal.turn_id, max_id_bytes);
            try writeField(&json, "type", "turn_end");
            try writeBase(&json, terminal.base);
            try writeField(&json, "turnId", terminal.turn_id);
            switch (terminal.outcome) {
                .completed => try writeField(&json, "outcome", "completed"),
                .failed => |failure| {
                    try writeField(&json, "outcome", "failed");
                    try writeField(&json, "failure", @tagName(failure));
                },
                .cancelled => try writeField(&json, "outcome", "cancelled"),
                .interrupted => try writeField(&json, "outcome", "interrupted"),
            }
        },
    }
    json.endObject() catch return error.OutOfMemory;
    const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
    if (encoded.len > max_record_bytes) {
        allocator.free(encoded);
        return error.InvalidRecord;
    }
    return encoded;
}

fn writeBase(json: *std.json.Stringify, base: EntryBase) Error!void {
    try writeField(json, "id", base.id);
    json.objectField("parentId") catch return error.OutOfMemory;
    json.write(base.parent_id) catch return error.OutOfMemory;
    try writeField(json, "timestamp", base.timestamp);
}

fn writeMessage(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    message: ai_message.Message,
) Error!void {
    json.beginObject() catch return error.OutOfMemory;
    switch (message) {
        .request => |request| {
            json.objectField("request") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            json.objectField("parts") catch return error.OutOfMemory;
            json.beginArray() catch return error.OutOfMemory;
            if (request.parts.len == 0 or request.parts.len > max_collection_items) return error.InvalidRecord;
            for (request.parts) |part| try writeRequestPart(json, part);
            json.endArray() catch return error.OutOfMemory;
            json.endObject() catch return error.OutOfMemory;
        },
        .response => |response| {
            try validateIdentifier(error.InvalidRecord, response.identity.provider, max_provider_id_bytes);
            try validateIdentifier(error.InvalidRecord, response.identity.model, max_model_id_bytes);
            if (response.parts.len > max_collection_items) return error.InvalidRecord;
            json.objectField("response") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            json.objectField("parts") catch return error.OutOfMemory;
            json.beginArray() catch return error.OutOfMemory;
            for (response.parts) |part| try writeResponsePart(allocator, json, response.identity.provider, part);
            json.endArray() catch return error.OutOfMemory;
            try writeField(json, "provider", response.identity.provider);
            try writeField(json, "model", response.identity.model);
            json.objectField("usage") catch return error.OutOfMemory;
            try writeUsage(json, response.usage);
            json.objectField("finish") catch return error.OutOfMemory;
            try writeFinish(json, response.finish);
            json.endObject() catch return error.OutOfMemory;
        },
    }
    json.endObject() catch return error.OutOfMemory;
}

fn writeRequestPart(json: *std.json.Stringify, part: ai_message.RequestPart) Error!void {
    json.beginObject() catch return error.OutOfMemory;
    switch (part) {
        .user => |user| switch (user) {
            .text => |text| {
                try validateMessageText(text);
                json.objectField("user") catch return error.OutOfMemory;
                json.beginObject() catch return error.OutOfMemory;
                try writeField(json, "text", text);
                json.endObject() catch return error.OutOfMemory;
            },
            .image => return error.InvalidRecord,
        },
        .tool_result => |result| {
            _ = try validatedToolCallId(result.call_id);
            _ = try validatedToolName(result.name);
            if (result.content.len == 0 or result.content.len > max_collection_items) return error.InvalidRecord;
            json.objectField("toolResult") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            try writeField(json, "callId", result.call_id);
            try writeField(json, "name", result.name);
            json.objectField("content") catch return error.OutOfMemory;
            json.beginArray() catch return error.OutOfMemory;
            for (result.content) |content| {
                json.beginObject() catch return error.OutOfMemory;
                switch (content) {
                    .text => |text| {
                        try validateMessageText(text);
                        try writeField(json, "text", text);
                    },
                    .image => return error.InvalidRecord,
                }
                json.endObject() catch return error.OutOfMemory;
            }
            json.endArray() catch return error.OutOfMemory;
            try writeField(json, "outcome", @tagName(result.outcome));
            json.endObject() catch return error.OutOfMemory;
        },
        .retry_prompt => return error.InvalidRecord,
    }
    json.endObject() catch return error.OutOfMemory;
}

fn writeResponsePart(
    allocator: std.mem.Allocator,
    json: *std.json.Stringify,
    response_provider: []const u8,
    part: ai_message.ResponsePart,
) Error!void {
    json.beginObject() catch return error.OutOfMemory;
    switch (part) {
        .text => |text| {
            try validateMessageText(text.text);
            json.objectField("text") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            try writeField(json, "text", text.text);
            try writeProviderState(json, response_provider, text.provider_state);
            json.endObject() catch return error.OutOfMemory;
        },
        .thinking => |thinking| {
            try validateMessageText(thinking.text);
            json.objectField("thinking") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            try writeField(json, "text", thinking.text);
            try writeProviderState(json, response_provider, thinking.provider_state);
            json.endObject() catch return error.OutOfMemory;
        },
        .tool_call => |call| {
            _ = try validatedToolCallId(call.id);
            _ = try validatedToolName(call.name);
            try validateToolArguments(allocator, call.arguments_json);
            json.objectField("toolCall") catch return error.OutOfMemory;
            json.beginObject() catch return error.OutOfMemory;
            try writeField(json, "id", call.id);
            try writeField(json, "name", call.name);
            try writeField(json, "arguments", call.arguments_json);
            try writeProviderState(json, response_provider, call.provider_state);
            json.endObject() catch return error.OutOfMemory;
        },
    }
    json.endObject() catch return error.OutOfMemory;
}

fn writeProviderState(
    json: *std.json.Stringify,
    response_provider: []const u8,
    state: ?ai_message.ProviderState,
) Error!void {
    json.objectField("providerState") catch return error.OutOfMemory;
    const value = state orelse {
        json.write(null) catch return error.OutOfMemory;
        return;
    };
    try validateIdentifier(error.InvalidRecord, value.provider, max_provider_id_bytes);
    try validateIdentifier(error.InvalidRecord, value.protocol, 256);
    if (!std.mem.eql(u8, value.provider, response_provider)) return error.InvalidRecord;
    json.beginObject() catch return error.OutOfMemory;
    try writeField(json, "provider", value.provider);
    try writeField(json, "protocol", value.protocol);
    json.objectField("value") catch return error.OutOfMemory;
    json.write(value.value) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
}

fn writeUsage(json: *std.json.Stringify, usage: ai_usage.Usage) Error!void {
    json.beginObject() catch return error.OutOfMemory;
    try writeField(json, "inputTokens", usage.input_tokens);
    try writeField(json, "outputTokens", usage.output_tokens);
    try writeField(json, "cachedInputTokens", usage.cached_input_tokens);
    try writeField(json, "reasoningTokens", usage.reasoning_tokens);
    json.endObject() catch return error.OutOfMemory;
}

fn writeFinish(json: *std.json.Stringify, finish: ai_usage.Finish) Error!void {
    json.beginObject() catch return error.OutOfMemory;
    try writeField(json, "category", @tagName(finish.category));
    json.objectField("rawReason") catch return error.OutOfMemory;
    json.write(finish.raw_reason) catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
}

fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) Error!void {
    json.objectField(name) catch return error.OutOfMemory;
    json.write(value) catch return error.OutOfMemory;
}

const test_timestamp = "2026-08-19T10:30:00.000Z";

fn testBase(id: []const u8, parent_id: ?[]const u8) EntryBase {
    return .{ .id = id, .parent_id = parent_id, .timestamp = test_timestamp };
}

fn appendEncoded(restorer: *Restorer, entry: Entry) !void {
    const encoded = try encodeEntry(std.testing.allocator, entry);
    defer std.testing.allocator.free(encoded);
    try restorer.append(encoded);
}

fn testRestorer() !Restorer {
    const encoded = try encodeHeader(std.testing.allocator, .{
        .id = "session-1",
        .timestamp = test_timestamp,
        .cwd = "/tmp/zi-project",
    });
    defer std.testing.allocator.free(encoded);
    return Restorer.init(std.testing.allocator, encoded);
}

test "session format round trips a completed tool turn" {
    var restorer = try testRestorer();
    errdefer restorer.deinit();

    try appendEncoded(&restorer, .{ .model_change = .{
        .base = testBase("entry-1", null),
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("entry-2", "entry-1"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "Read the file." } }} } },
    } });
    const provider_state: ai_message.ProviderState = .{
        .provider = "openai",
        .protocol = "openai-responses",
        .value = .{ .string = "opaque-state" },
    };
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("entry-3", "entry-2"),
        .message = .{ .response = .{
            .parts = &.{.{ .tool_call = .{
                .id = "call-1",
                .name = "read",
                .arguments_json = "{\"path\":\"README.md\"}",
                .provider_state = provider_state,
            } }},
            .identity = .{ .provider = "openai", .model = "gpt-5.2" },
            .usage = .{ .input_tokens = 10, .output_tokens = 4, .cached_input_tokens = 2 },
            .finish = .{ .category = .tool_calls, .raw_reason = "tool_calls" },
        } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("entry-4", "entry-3"),
        .message = .{ .request = .{ .parts = &.{.{ .tool_result = .{
            .call_id = "call-1",
            .name = "read",
            .content = &.{.{ .text = "contents" }},
            .outcome = .success,
        } }} } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("entry-5", "entry-4"),
        .message = .{ .response = .{
            .parts = &.{
                .{ .thinking = .{ .text = "done", .provider_state = provider_state } },
                .{ .text = .{ .text = "Finished." } },
            },
            .identity = .{ .provider = "openai", .model = "gpt-5.2" },
            .usage = .{ .input_tokens = 20, .output_tokens = 6, .reasoning_tokens = 1 },
            .finish = .{ .category = .stop },
        } },
    } });
    try appendEncoded(&restorer, .{ .turn_end = .{
        .base = testBase("entry-6", "entry-5"),
        .turn_id = "entry-2",
        .outcome = .completed,
    } });

    var restored = try restorer.finish();
    defer restored.deinit();
    try std.testing.expectEqualStrings("session-1", restored.header.id);
    try std.testing.expectEqualStrings("/tmp/zi-project", restored.header.cwd);
    try std.testing.expectEqual(@as(usize, 6), restored.entries.len);
    try std.testing.expectEqualStrings("entry-6", restored.active_leaf_id.?);
    try std.testing.expectEqualStrings("gpt-5.2", restored.active_model.?.model);
    try std.testing.expectEqual(@as(usize, 4), restored.context_messages.len);
    try std.testing.expectEqualStrings(
        "call-1",
        restored.context_messages[1].response.parts[0].tool_call.id,
    );
    try std.testing.expectEqualStrings(
        "opaque-state",
        restored.context_messages[1].response.parts[0].tool_call.provider_state.?.value.string,
    );
    try std.testing.expectEqualStrings(
        "contents",
        restored.context_messages[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expect(restored.recovery == .clean);
}

test "session restore trims unresolved tool protocol but retains durable entries" {
    const terminal_outcomes = [_]?TurnOutcome{
        .cancelled,
        .{ .failed = .tool_control_unavailable },
        .interrupted,
        null,
    };
    for (terminal_outcomes) |terminal_outcome| {
        var restorer = try testRestorer();
        errdefer restorer.deinit();
        try appendEncoded(&restorer, .{ .model_change = .{
            .base = testBase("model", null),
            .selection = .{ .provider = "openai", .model = "gpt-5.2" },
        } });
        try appendEncoded(&restorer, .{ .message = .{
            .base = testBase("turn", "model"),
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "Change it." } }} } },
        } });
        try appendEncoded(&restorer, .{ .message = .{
            .base = testBase("calls", "turn"),
            .message = .{ .response = .{
                .parts = &.{
                    .{ .tool_call = .{ .id = "call-a", .name = "read", .arguments_json = "{}" } },
                    .{ .tool_call = .{ .id = "call-b", .name = "edit", .arguments_json = "{}" } },
                },
                .identity = .{ .provider = "openai", .model = "gpt-5.2" },
                .finish = .{ .category = .tool_calls },
            } },
        } });
        try appendEncoded(&restorer, .{ .message = .{
            .base = testBase("result", "calls"),
            .message = .{ .request = .{ .parts = &.{.{ .tool_result = .{
                .call_id = "call-a",
                .name = "read",
                .content = &.{.{ .text = "contents" }},
                .outcome = .success,
            } }} } },
        } });
        if (terminal_outcome) |outcome| try appendEncoded(&restorer, .{ .turn_end = .{
            .base = testBase("terminal", "result"),
            .turn_id = "turn",
            .outcome = outcome,
        } });

        var restored = try restorer.finish();
        defer restored.deinit();
        try std.testing.expectEqual(@as(usize, 1), restored.context_messages.len);
        try std.testing.expectEqualStrings("Change it.", restored.context_messages[0].request.parts[0].user.text);
        try std.testing.expectEqual(if (terminal_outcome == null) @as(usize, 4) else 5, restored.entries.len);
        if (terminal_outcome == null) {
            try std.testing.expect(restored.recovery == .interrupted);
            try std.testing.expectEqualStrings("turn", restored.recovery.interrupted.turn_id);
        } else {
            try std.testing.expect(restored.recovery == .clean);
        }
    }
}

test "session restore follows the final parent-linked branch" {
    var restorer = try testRestorer();
    errdefer restorer.deinit();
    try appendEncoded(&restorer, .{ .model_change = .{
        .base = testBase("model", null),
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("turn-a", "model"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "branch a" } }} } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("answer-a", "turn-a"),
        .message = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "answer a" } }},
            .identity = .{ .provider = "openai", .model = "gpt-5.2" },
            .finish = .{ .category = .stop },
        } },
    } });
    try appendEncoded(&restorer, .{ .turn_end = .{
        .base = testBase("end-a", "answer-a"),
        .turn_id = "turn-a",
        .outcome = .completed,
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("turn-b", "model"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "branch b" } }} } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("answer-b", "turn-b"),
        .message = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "answer b" } }},
            .identity = .{ .provider = "openai", .model = "gpt-5.2" },
            .finish = .{ .category = .stop },
        } },
    } });
    try appendEncoded(&restorer, .{ .turn_end = .{
        .base = testBase("end-b", "answer-b"),
        .turn_id = "turn-b",
        .outcome = .completed,
    } });

    var restored = try restorer.finish();
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 2), restored.context_messages.len);
    try std.testing.expectEqualStrings(
        "branch b",
        restored.context_messages[0].request.parts[0].user.text,
    );
    try std.testing.expectEqualStrings(
        "answer b",
        restored.context_messages[1].response.parts[0].text.text,
    );
}

test "session restore rejects semantic corruption on an inactive branch" {
    var restorer = try testRestorer();
    errdefer restorer.deinit();
    try appendEncoded(&restorer, .{ .model_change = .{
        .base = testBase("model", null),
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("bad-turn", "model"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "bad branch" } }} } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("bad-answer", "bad-turn"),
        .message = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "wrong model" } }},
            .identity = .{ .provider = "openai", .model = "other" },
            .finish = .{ .category = .stop },
        } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("good-turn", "model"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "good branch" } }} } },
    } });
    try appendEncoded(&restorer, .{ .message = .{
        .base = testBase("good-answer", "good-turn"),
        .message = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "right model" } }},
            .identity = .{ .provider = "openai", .model = "gpt-5.2" },
            .finish = .{ .category = .stop },
        } },
    } });
    try appendEncoded(&restorer, .{ .turn_end = .{
        .base = testBase("good-end", "good-answer"),
        .turn_id = "good-turn",
        .outcome = .completed,
    } });
    try std.testing.expectError(error.InvalidRecord, restorer.finish());
    restorer.deinit();
}

test "session format rejects corrupt structure and semantics" {
    const unsupported_version =
        "{\"type\":\"session\",\"version\":2,\"id\":\"s\"," ++
        "\"timestamp\":\"2026-08-19T10:30:00.000Z\",\"cwd\":\"/tmp\"}";
    try std.testing.expectError(
        error.UnsupportedVersion,
        Restorer.init(std.testing.allocator, unsupported_version),
    );
    const invalid_header =
        "{\"type\":\"session\",\"version\":1,\"id\":\"s\"," ++
        "\"timestamp\":\"2026-02-30T10:30:00.000Z\",\"cwd\":\"/tmp/../tmp\"}";
    try std.testing.expectError(
        error.InvalidHeader,
        Restorer.init(std.testing.allocator, invalid_header),
    );

    var missing_parent = try testRestorer();
    defer missing_parent.deinit();
    try appendEncoded(&missing_parent, .{ .model_change = .{
        .base = testBase("model", null),
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } });
    const orphan = try encodeEntry(std.testing.allocator, .{ .message = .{
        .base = testBase("orphan", "missing"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } });
    defer std.testing.allocator.free(orphan);
    try std.testing.expectError(error.InvalidRecord, missing_parent.append(orphan));

    var wrong_model = try testRestorer();
    errdefer wrong_model.deinit();
    try appendEncoded(&wrong_model, .{ .model_change = .{
        .base = testBase("model", null),
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } });
    try appendEncoded(&wrong_model, .{ .message = .{
        .base = testBase("turn", "model"),
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } });
    try appendEncoded(&wrong_model, .{ .message = .{
        .base = testBase("answer", "turn"),
        .message = .{ .response = .{
            .parts = &.{.{ .text = .{ .text = "hello" } }},
            .identity = .{ .provider = "openai", .model = "different" },
            .finish = .{ .category = .stop },
        } },
    } });
    try std.testing.expectError(error.InvalidRecord, wrong_model.finish());
    wrong_model.deinit();

    var unknown = try testRestorer();
    defer unknown.deinit();
    const unknown_field =
        "{\"type\":\"model_change\",\"id\":\"one\",\"parentId\":null," ++
        "\"timestamp\":\"2026-08-19T10:30:00.000Z\",\"provider\":\"openai\"," ++
        "\"modelId\":\"gpt-5.2\",\"future\":true}";
    try std.testing.expectError(
        error.InvalidRecord,
        unknown.append(unknown_field),
    );
}

test "session format rejects unsupported image and retry messages" {
    const image_bytes = [_]u8{ 1, 2, 3 };
    try std.testing.expectError(
        error.InvalidRecord,
        encodeEntry(std.testing.allocator, .{ .message = .{
            .base = testBase("image", null),
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .image = .{
                .media_type = "image/png",
                .source = .{ .bytes = &image_bytes },
            } } }} } },
        } }),
    );
    try std.testing.expectError(
        error.InvalidRecord,
        encodeEntry(std.testing.allocator, .{ .message = .{
            .base = testBase("retry", null),
            .message = .{ .request = .{ .parts = &.{.{ .retry_prompt = "again" }} } },
        } }),
    );
}

const DeterministicSources = struct {
    id: [16]u8,
    unix_ms: u64,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *DeterministicSources = @ptrCast(@alignCast(context));
        return self.id;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *DeterministicSources = @ptrCast(@alignCast(context));
        return self.unix_ms;
    }

    fn sources(self: *DeterministicSources) Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

test "session stamps use only injected identity and time" {
    var deterministic: DeterministicSources = .{
        .id = .{ 0x01, 0x8f, 0x11, 0x22, 0x33, 0x44, 0x75, 0x66, 0x88, 0x99, 0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff },
        .unix_ms = 1_755_600_600_123,
    };
    const stamp = try deterministic.sources().next();
    try std.testing.expectEqualStrings("018f1122-3344-7566-8899-aabbccddeeff", stamp.id());
    try std.testing.expectEqualStrings("2025-08-19T10:50:00.123Z", stamp.timestamp());
    try std.testing.expectEqualStrings("parent", stamp.base("parent").parent_id.?);
}

fn restoreCompletedTurn(allocator: std.mem.Allocator) !void {
    const header = try encodeHeader(allocator, .{
        .id = "session",
        .timestamp = test_timestamp,
        .cwd = "/tmp/project",
    });
    defer allocator.free(header);
    var restorer = try Restorer.init(allocator, header);
    errdefer restorer.deinit();

    const entries = [_]Entry{
        .{ .model_change = .{
            .base = testBase("model", null),
            .selection = .{ .provider = "openai", .model = "gpt-5.2" },
        } },
        .{ .message = .{
            .base = testBase("turn", "model"),
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
        } },
        .{ .message = .{
            .base = testBase("answer", "turn"),
            .message = .{ .response = .{
                .parts = &.{.{ .text = .{ .text = "hello" } }},
                .identity = .{ .provider = "openai", .model = "gpt-5.2" },
                .finish = .{ .category = .stop },
            } },
        } },
        .{ .turn_end = .{
            .base = testBase("end", "answer"),
            .turn_id = "turn",
            .outcome = .completed,
        } },
    };
    for (entries) |entry| {
        const encoded = try encodeEntry(allocator, entry);
        defer allocator.free(encoded);
        try restorer.append(encoded);
    }
    var restored = try restorer.finish();
    restored.deinit();
}

test "session codec and projection settle every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        restoreCompletedTurn,
        .{},
    );
}
