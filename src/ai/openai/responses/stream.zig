const std = @import("std");
const protocol = @import("../../protocol.zig");
const sse = @import("../../sse.zig");
const ai_provider = @import("../../provider.zig");
const provider_failure = @import("../../provider_failure.zig");
const partial_json = @import("../../../json/partial.zig");
const json_value = @import("../../../json/value.zig");
const Token = protocol.CancelToken;

pub const EventMapOutcome = union(enum) {
    pass_through,
    normalized: struct {
        event_type: []const u8,
        stop_after_event: bool = false,
        normalize_terminal_status: bool = false,
    },
    fail: []const u8,
};

pub const EventMapper = struct {
    ctx: ?*anyopaque = null,
    map: *const fn (
        allocator: std.mem.Allocator,
        root: std.json.Value,
        event_type: []const u8,
        ctx: ?*anyopaque,
    ) anyerror!EventMapOutcome,
};

const ItemKind = enum { reasoning, message, function_call };
const MessagePartKind = enum { output_text, refusal };

const ItemState = struct {
    kind: ItemKind,
    block_idx: usize,
    text_buf: std.ArrayList(u8) = .empty,

    summary_started: bool = false,
    thinking_signature: ?[]const u8 = null,

    content_part_started: bool = false,
    message_part_kind: ?MessagePartKind = null,
    msg_id: []const u8 = "",
    msg_phase: ?[]const u8 = null,
    text_signature: ?[]const u8 = null,

    tool_call_id: []const u8 = "",
    tool_item_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_args_partial: std.ArrayList(u8) = .empty,
    tool_args_parsed: json_value.OwnedValue = .null,

    tool_composite_id: []const u8 = "",

    fn deinit(self: *ItemState, allocator: std.mem.Allocator) void {
        self.text_buf.deinit(allocator);
        self.tool_args_partial.deinit(allocator);
        self.tool_args_parsed.deinit();
        if (self.thinking_signature) |signature| allocator.free(signature);
        self.* = undefined;
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(ItemState),
    current: ?usize = null,
    message: protocol.AssistantMessage,
    response_id: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, io: std.Io, model: protocol.Model) StreamState {
        return .{
            .allocator = allocator,
            .items = .empty,
            .message = .{
                .content = &.{},
                .api = model.api,
                .provider = model.provider,
                .model = model.id,
                .usage = .{
                    .input = 0,
                    .output = 0,
                    .cache_read = 0,
                    .cache_write = 0,
                    .total_tokens = 0,
                    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
                },
                .stop_reason = .stop,
                .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
            },
        };
    }

    fn deinit(self: *StreamState) void {
        for (self.items.items) |*it| it.deinit(self.allocator);
        self.items.deinit(self.allocator);
        if (self.message.content.len > 0) self.allocator.free(self.message.content);
        self.* = undefined;
    }
};

fn assistantHasToolCalls(msg: protocol.AssistantMessage) bool {
    for (msg.content) |block| {
        if (block == .tool_call) return true;
    }
    return false;
}

pub fn processStream(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: anytype,
    model: protocol.Model,
    abort_flag: Token,
    provider_label: []const u8,
    sink: ai_provider.StreamEventSink,
) void {
    processStreamMapped(
        allocator,
        io,
        reader,
        model,
        abort_flag,
        provider_label,
        .{ .map = identityEventMapper },
        sink,
    );
}

pub fn processStreamMapped(
    allocator: std.mem.Allocator,
    io: std.Io,
    reader: anytype,
    model: protocol.Model,
    abort_flag: Token,
    provider_label: []const u8,
    event_mapper: EventMapper,
    sink: ai_provider.StreamEventSink,
) void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var state = StreamState.init(allocator, io, model);
    defer state.deinit();

    sink.emit(.start);

    var parser = sse.SseParser.init(allocator);
    defer parser.deinit();

    const StreamCtx = struct {
        allocator: std.mem.Allocator,
        state: *StreamState,
        scratch: *std.heap.ArenaAllocator,
        mapper: EventMapper,
        sink: ai_provider.StreamEventSink,

        const Self = @This();

        fn onEvent(evt: sse.SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            try handleEvent(self.allocator, self.state, self.scratch, evt, self.mapper, self.sink);
        }
    };

    var stream_ctx: StreamCtx = .{
        .allocator = allocator,
        .state = &state,
        .scratch = &scratch_arena,
        .mapper = event_mapper,
        .sink = sink,
    };

    sse.streamEvents(allocator, reader, &parser, 4096, .{
        .func = &StreamCtx.onEvent,
        .ctx = @ptrCast(&stream_ctx),
    }) catch |err| {
        switch (err) {
            error.StopStreaming => if (abort_flag.isAborted()) {
                state.message.stop_reason = .aborted;
            },
            else => if (abort_flag.isAborted()) {
                state.message.stop_reason = .aborted;
            } else if (err == error.EventDataTooLarge) {
                emitError(
                    allocator,
                    io,
                    sink,
                    model,
                    provider_label,
                    "stream event exceeded {d} bytes",
                    .{sse.max_event_data_bytes},
                );
                return;
            } else {
                emitError(
                    allocator,
                    io,
                    sink,
                    model,
                    provider_label,
                    "stream read error: {s}",
                    .{@errorName(err)},
                );
                return;
            },
        }
    };

    state.message.content = buildFinalContent(allocator, state.items.items) catch |err| {
        emitError(
            allocator,
            io,
            sink,
            model,
            provider_label,
            "failed to build final content: {s}",
            .{@errorName(err)},
        );
        return;
    };
    if (state.message.stop_reason == .stop and assistantHasToolCalls(state.message)) {
        state.message.stop_reason = .toolUse;
    }

    if (state.message.stop_reason == .aborted) {
        sink.emit(.{ .@"error" = .{ .reason = .aborted, .@"error" = state.message } });
    } else if (state.message.stop_reason == .@"error") {
        sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = state.message } });
    } else {
        const reason: protocol.AssistantMessageEvent.DoneReason = switch (state.message.stop_reason) {
            .stop => .stop,
            .length => .length,
            .toolUse => .toolUse,
            else => .stop,
        };
        sink.emit(.{ .done = .{ .reason = reason, .message = state.message } });
    }
}

const HandleErr = error{ OutOfMemory, StopStreaming };

fn handleEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    evt: sse.SseEvent,
    event_mapper: EventMapper,
    sink: ai_provider.StreamEventSink,
) HandleErr!void {
    if (evt.data.len == 0) return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, evt.data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    const type_v = root.object.get("type") orelse return;
    if (type_v != .string) return;
    const raw_type = type_v.string;

    var mapped_type = raw_type;
    var stop_after_event = false;
    var normalize_terminal_status = false;
    switch (event_mapper.map(allocator, root, raw_type, event_mapper.ctx) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    }) {
        .pass_through => {},
        .normalized => |normalized| {
            mapped_type = normalized.event_type;
            stop_after_event = normalized.stop_after_event;
            normalize_terminal_status = normalized.normalize_terminal_status;
        },
        .fail => |message| {
            state.message.stop_reason = .@"error";
            state.message.error_message = message;
            return error.StopStreaming;
        },
    }
    const t = mapped_type;

    if (std.mem.eql(u8, t, "response.created")) {
        if (root.object.get("response")) |resp| if (resp == .object) {
            if (resp.object.get("id")) |id| if (id == .string and id.string.len > 0) {
                state.response_id = try allocator.dupe(u8, id.string);
                state.message.response_id = state.response_id;
            };
        };
        return;
    }

    if (std.mem.eql(u8, t, "response.output_item.added")) {
        const item = root.object.get("item") orelse return;
        if (item != .object) return;
        const it_type_v = item.object.get("type") orelse return;
        if (it_type_v != .string) return;
        const it_type = it_type_v.string;

        if (std.mem.eql(u8, it_type, "reasoning")) {
            const idx = state.items.items.len;
            try state.items.append(allocator, .{ .kind = .reasoning, .block_idx = idx });
            state.current = idx;
            sink.emit(.{ .thinking_start = .{ .content_index = idx } });
        } else if (std.mem.eql(u8, it_type, "message")) {
            const idx = state.items.items.len;
            try state.items.append(allocator, .{ .kind = .message, .block_idx = idx });
            state.current = idx;
            const it = &state.items.items[idx];
            if (item.object.get("id")) |id| if (id == .string) {
                it.msg_id = try allocator.dupe(u8, id.string);
            };
            if (item.object.get("phase")) |ph| if (ph == .string) {
                it.msg_phase = try allocator.dupe(u8, ph.string);
            };
            sink.emit(.{ .text_start = .{ .content_index = idx } });
        } else if (std.mem.eql(u8, it_type, "function_call")) {
            const idx = state.items.items.len;
            try state.items.append(allocator, .{ .kind = .function_call, .block_idx = idx });
            state.current = idx;
            const it = &state.items.items[idx];
            if (item.object.get("call_id")) |c| if (c == .string) {
                it.tool_call_id = try allocator.dupe(u8, c.string);
            };
            if (item.object.get("id")) |c| if (c == .string) {
                it.tool_item_id = try allocator.dupe(u8, c.string);
            };
            if (item.object.get("name")) |n| if (n == .string) {
                it.tool_name = try allocator.dupe(u8, n.string);
            };
            if (item.object.get("arguments")) |a| if (a == .string and a.string.len > 0) {
                try it.tool_args_partial.appendSlice(allocator, a.string);
            };
            try ensureToolCompositeId(allocator, it);
            sink.emit(.{ .toolcall_start = .{ .content_index = idx } });
        }
        return;
    }

    if (std.mem.eql(u8, t, "response.reasoning_summary_part.added")) {
        if (state.current) |cur| {
            const it = &state.items.items[cur];
            if (it.kind == .reasoning) it.summary_started = true;
        }
        return;
    }

    if (std.mem.eql(u8, t, "response.reasoning_summary_text.delta")) {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .reasoning or !it.summary_started) return;
        const dv = root.object.get("delta") orelse return;
        if (dv != .string) return;
        try it.text_buf.appendSlice(allocator, dv.string);
        sink.emit(.{ .thinking_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
        } });
        return;
    }

    if (std.mem.eql(u8, t, "response.reasoning_summary_part.done")) {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .reasoning or !it.summary_started) return;
        try it.text_buf.appendSlice(allocator, "\n\n");
        sink.emit(.{ .thinking_delta = .{
            .content_index = it.block_idx,
            .delta = "\n\n",
        } });
        return;
    }

    if (std.mem.eql(u8, t, "response.content_part.added")) {
        if (state.current) |cur| {
            const it = &state.items.items[cur];
            if (it.kind == .message) {
                if (root.object.get("part")) |part| if (part == .object) {
                    if (part.object.get("type")) |part_type| if (part_type == .string) {
                        if (std.mem.eql(u8, part_type.string, "output_text")) {
                            it.content_part_started = true;
                            it.message_part_kind = .output_text;
                        } else if (std.mem.eql(u8, part_type.string, "refusal")) {
                            it.content_part_started = true;
                            it.message_part_kind = .refusal;
                        }
                    };
                };
            }
        }
        return;
    }

    if (std.mem.eql(u8, t, "response.output_text.delta") or
        std.mem.eql(u8, t, "response.refusal.delta"))
    {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .message or !it.content_part_started) return;
        if (std.mem.eql(u8, t, "response.output_text.delta") and it.message_part_kind != .output_text) return;
        if (std.mem.eql(u8, t, "response.refusal.delta") and it.message_part_kind != .refusal) return;
        const dv = root.object.get("delta") orelse return;
        if (dv != .string) return;
        try it.text_buf.appendSlice(allocator, dv.string);
        sink.emit(.{ .text_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
        } });
        return;
    }

    if (std.mem.eql(u8, t, "response.function_call_arguments.delta")) {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .function_call) return;
        const dv = root.object.get("delta") orelse return;
        if (dv != .string) return;
        try it.tool_args_partial.appendSlice(allocator, dv.string);
        _ = scratch.reset(.retain_capacity);
        const partial_args = partial_json.parseStreaming(
            scratch.allocator(),
            it.tool_args_partial.items,
        ) catch .null;
        it.tool_args_parsed = json_value.OwnedValue.adopt(scratch.allocator(), partial_args);
        sink.emit(.{ .toolcall_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
        } });
        return;
    }

    if (std.mem.eql(u8, t, "response.function_call_arguments.done")) {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .function_call) return;
        if (root.object.get("arguments")) |a| if (a == .string) {
            it.tool_args_partial.clearRetainingCapacity();
            try it.tool_args_partial.appendSlice(allocator, a.string);
        };
        return;
    }

    if (std.mem.eql(u8, t, "response.output_item.done")) {
        const item = root.object.get("item") orelse return;
        if (item != .object) return;
        const it_type_v = item.object.get("type") orelse return;
        if (it_type_v != .string) return;
        const it_type = it_type_v.string;
        const cur = state.current orelse return;
        const st = &state.items.items[cur];

        if (std.mem.eql(u8, it_type, "reasoning") and st.kind == .reasoning) {
            const final_text = try finalThinkingTextFromItem(allocator, item);
            defer allocator.free(final_text);
            try clearAndSetText(allocator, &st.text_buf, final_text);
            st.thinking_signature = stringifyJsonValue(allocator, item) catch return error.OutOfMemory;
            sink.emit(.{ .thinking_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
            } });
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "message") and st.kind == .message) {
            if (item.object.get("id")) |id| if (id == .string) {
                st.msg_id = try allocator.dupe(u8, id.string);
            };
            if (item.object.get("phase")) |phase| if (phase == .string) {
                st.msg_phase = try allocator.dupe(u8, phase.string);
            };
            const final_text = try finalMessageTextFromItem(allocator, item);
            defer allocator.free(final_text);
            try clearAndSetText(allocator, &st.text_buf, final_text);
            st.text_signature = encodeTextSignatureV1(
                allocator,
                st.msg_id,
                st.msg_phase,
            ) catch return error.OutOfMemory;
            sink.emit(.{ .text_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
            } });
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "function_call") and st.kind == .function_call) {
            if (item.object.get("call_id")) |call_id| if (call_id == .string) {
                st.tool_call_id = try allocator.dupe(u8, call_id.string);
            };
            if (item.object.get("id")) |item_id| if (item_id == .string) {
                st.tool_item_id = try allocator.dupe(u8, item_id.string);
            };
            if (item.object.get("name")) |name| if (name == .string) {
                st.tool_name = try allocator.dupe(u8, name.string);
            };
            if (item.object.get("arguments")) |arguments| if (arguments == .string) {
                st.tool_args_partial.clearRetainingCapacity();
                try st.tool_args_partial.appendSlice(allocator, arguments.string);
            };
            const final_args = partial_json.parseStreaming(allocator, st.tool_args_partial.items) catch .null;
            st.tool_args_parsed = json_value.OwnedValue.adopt(allocator, final_args);
            st.tool_composite_id = "";
            try ensureToolCompositeId(allocator, st);
            const tc: protocol.ToolCall = .{
                .id = st.tool_composite_id,
                .name = st.tool_name,
                .arguments = st.tool_args_parsed,
            };
            sink.emit(.{ .toolcall_end = .{
                .content_index = st.block_idx,
                .tool_call = tc,
            } });
            state.current = null;
        }
        return;
    }

    if (std.mem.eql(u8, t, "response.completed") or
        std.mem.eql(u8, t, "response.done") or
        std.mem.eql(u8, t, "response.incomplete"))
    {
        const resp = root.object.get("response") orelse return;
        if (resp != .object) return;
        if (resp.object.get("id")) |id| if (id == .string and id.string.len > 0) {
            if (state.response_id == null) {
                state.response_id = try allocator.dupe(u8, id.string);
                state.message.response_id = state.response_id;
            }
        };
        if (resp.object.get("usage")) |u| if (u == .object) parseUsage(u, &state.message);
        if (resp.object.get("status")) |s| if (s == .string) {
            const status = if (normalize_terminal_status) normalizeCodexStatus(s.string) else s.string;
            state.message.stop_reason = mapResponseStatus(status);
        };
        if (state.message.stop_reason == .stop) {
            for (state.items.items) |it| if (it.kind == .function_call) {
                state.message.stop_reason = .toolUse;
                break;
            };
        }
        if (stop_after_event) return error.StopStreaming;
        return;
    }

    if (std.mem.eql(u8, t, "error") or std.mem.eql(u8, t, "response.failed")) {
        state.message.stop_reason = .@"error";
        if (root.object.get("message")) |m| if (m == .string) {
            state.message.error_message = try allocator.dupe(u8, m.string);
        };
        return;
    }
}

fn clearAndSetText(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), text: []const u8) !void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, text);
}

fn finalThinkingTextFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    if (item != .object) return allocator.dupe(u8, "");
    const summary = item.object.get("summary") orelse return allocator.dupe(u8, "");
    if (summary != .array) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (summary.array.items, 0..) |part, idx| {
        if (part != .object) continue;
        const text = part.object.get("text") orelse continue;
        if (text != .string) continue;
        if (idx > 0) try out.appendSlice(allocator, "\n\n");
        try out.appendSlice(allocator, text.string);
    }
    return out.toOwnedSlice(allocator);
}

fn finalMessageTextFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    if (item != .object) return allocator.dupe(u8, "");
    const content = item.object.get("content") orelse return allocator.dupe(u8, "");
    if (content != .array) return allocator.dupe(u8, "");

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    for (content.array.items) |part| {
        if (part != .object) continue;
        const part_type = part.object.get("type") orelse continue;
        if (part_type != .string) continue;
        if (std.mem.eql(u8, part_type.string, "output_text")) {
            const text = part.object.get("text") orelse continue;
            if (text != .string) continue;
            try out.appendSlice(allocator, text.string);
        } else if (std.mem.eql(u8, part_type.string, "refusal")) {
            const refusal = part.object.get("refusal") orelse continue;
            if (refusal != .string) continue;
            try out.appendSlice(allocator, refusal.string);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn ensureToolCompositeId(allocator: std.mem.Allocator, it: *ItemState) !void {
    if (it.kind != .function_call) return;
    if (it.tool_composite_id.len > 0) return;
    if (it.tool_call_id.len == 0 or it.tool_item_id.len == 0) return;
    it.tool_composite_id = try std.fmt.allocPrint(
        allocator,
        "{s}|{s}",
        .{ it.tool_call_id, it.tool_item_id },
    );
}

fn renderItem(it: *const ItemState) protocol.AssistantMessage.AssistantContentBlock {
    return switch (it.kind) {
        .reasoning => .{ .thinking = .{
            .thinking = it.text_buf.items,
            .thinking_signature = it.thinking_signature,
        } },
        .message => .{ .text = .{
            .text = it.text_buf.items,
            .text_signature = it.text_signature,
        } },
        .function_call => .{ .tool_call = .{
            .id = if (it.tool_composite_id.len > 0) it.tool_composite_id else it.tool_call_id,
            .name = it.tool_name,
            .arguments = it.tool_args_parsed,
        } },
    };
}

fn buildFinalContent(
    allocator: std.mem.Allocator,
    items: []const ItemState,
) ![]protocol.AssistantMessage.AssistantContentBlock {
    const out = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, items.len);
    for (items, 0..) |*it, i| out[i] = renderItem(it);
    return out;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    try std.json.Stringify.value(value, .{}, &out.writer);
    return out.toOwnedSlice();
}

fn encodeTextSignatureV1(
    allocator: std.mem.Allocator,
    id: []const u8,
    phase: ?[]const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try jw.beginObject();
    try jw.objectField("v");
    try jw.write(@as(u8, 1));
    try jw.objectField("id");
    try jw.write(id);
    if (phase) |p| {
        try jw.objectField("phase");
        try jw.write(p);
    }
    try jw.endObject();
    return out.toOwnedSlice();
}

pub fn identityEventMapper(
    _: std.mem.Allocator,
    _: std.json.Value,
    _: []const u8,
    _: ?*anyopaque,
) anyerror!EventMapOutcome {
    return .pass_through;
}

pub fn codexEventMapper(
    allocator: std.mem.Allocator,
    root: std.json.Value,
    event_type: []const u8,
    _: ?*anyopaque,
) anyerror!EventMapOutcome {
    if (std.mem.eql(u8, event_type, "error")) {
        const code = if (root.object.get("code")) |c| if (c == .string) c.string else "" else "";
        const message = if (root.object.get("message")) |m| if (m == .string) m.string else "" else "";
        if (message.len > 0) return .{ .fail = try std.fmt.allocPrint(allocator, "Codex error: {s}", .{message}) };
        if (code.len > 0) return .{ .fail = try std.fmt.allocPrint(allocator, "Codex error: {s}", .{code}) };
        const json = try stringifyJsonValue(allocator, root);
        return .{ .fail = try std.fmt.allocPrint(allocator, "Codex error: {s}", .{json}) };
    }

    if (std.mem.eql(u8, event_type, "response.failed")) {
        if (root.object.get("response")) |resp| if (resp == .object) {
            if (resp.object.get("error")) |err| if (err == .object) {
                if (err.object.get("message")) |message| if (message == .string and message.string.len > 0) {
                    return .{ .fail = try allocator.dupe(u8, message.string) };
                };
            };
        };
        return .{ .fail = try allocator.dupe(u8, "Codex response failed") };
    }

    if (std.mem.eql(u8, event_type, "response.done") or
        std.mem.eql(u8, event_type, "response.completed") or
        std.mem.eql(u8, event_type, "response.incomplete"))
    {
        return .{ .normalized = .{
            .event_type = "response.completed",
            .stop_after_event = true,
            .normalize_terminal_status = true,
        } };
    }

    return .pass_through;
}

fn normalizeCodexStatus(status: []const u8) []const u8 {
    if (std.mem.eql(u8, status, "completed")) return "completed";
    if (std.mem.eql(u8, status, "incomplete")) return "incomplete";
    if (std.mem.eql(u8, status, "failed")) return "failed";
    if (std.mem.eql(u8, status, "cancelled")) return "cancelled";
    if (std.mem.eql(u8, status, "queued")) return "queued";
    if (std.mem.eql(u8, status, "in_progress")) return "in_progress";
    return "completed";
}

fn parseUsage(usage: std.json.Value, partial: *protocol.AssistantMessage) void {
    var input: u64 = 0;
    var output: u64 = 0;
    var cache_read: u64 = 0;
    if (usage.object.get("input_tokens")) |v| input = jsonU64(v);
    if (usage.object.get("output_tokens")) |v| output = jsonU64(v);
    if (usage.object.get("input_tokens_details")) |d| if (d == .object) {
        if (d.object.get("cached_tokens")) |c| cache_read = jsonU64(c);
    };
    const non_cached_input = if (input > cache_read) input - cache_read else 0;
    partial.usage.input = non_cached_input;
    partial.usage.output = output;
    partial.usage.cache_read = cache_read;
    partial.usage.cache_write = 0;
    partial.usage.total_tokens = if (usage.object.get("total_tokens")) |t|
        jsonU64(t)
    else
        non_cached_input + output + cache_read;
}

fn jsonU64(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn mapResponseStatus(status: []const u8) protocol.StopReason {
    if (std.mem.eql(u8, status, "completed")) return .stop;
    if (std.mem.eql(u8, status, "incomplete")) return .length;
    if (std.mem.eql(u8, status, "failed") or std.mem.eql(u8, status, "cancelled")) return .@"error";
    return .stop;
}

pub fn emitError(
    allocator: std.mem.Allocator,
    io: std.Io,
    sink: ai_provider.StreamEventSink,
    model: protocol.Model,
    provider_label: []const u8,
    comptime fmt: []const u8, // ziglint-ignore: Z023
    args: anytype,
) void {
    const inner = std.fmt.allocPrint(allocator, fmt, args) catch "error";
    const normalized = provider_failure.formatTransportFailure(allocator, inner) catch null;
    emitFailure(allocator, io, sink, model, provider_label, if (normalized) |n| n.failure else null, inner);
}

pub fn emitFailure(
    allocator: std.mem.Allocator,
    io: std.Io,
    sink: ai_provider.StreamEventSink,
    model: protocol.Model,
    provider_label: []const u8,
    failure: ?protocol.NormalizedFailure,
    message: []const u8,
) void {
    const msg = std.fmt.allocPrint(allocator, "{s}: {s}", .{ provider_label, message }) catch provider_label;
    const err_msg: protocol.AssistantMessage = .{
        .content = &.{},
        .api = model.api,
        .provider = model.provider,
        .model = model.id,
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = msg,
        .failure = failure,
        .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
    };
    sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } });
}
