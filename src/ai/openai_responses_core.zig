const std = @import("std");
const protocol = @import("protocol.zig");
const json_util = @import("json_util.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const provider_failure = @import("provider_failure.zig");
const request_transform = @import("request_transform.zig");
const partial_json = @import("../json/partial.zig");
const replay = @import("openai_responses_replay.zig");
const Token = protocol.CancelToken;
const http_cancel = @import("http_cancel.zig");

pub const AuthFactory = struct {
    ctx: ?*anyopaque = null,
    build: *const fn (
        ctx: ?*anyopaque,
        buf: []u8,
        api_key: ?[]const u8,
    ) error{ NoApiKey, BufferTooSmall }![]u8,
};

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
    map: *const fn (allocator: std.mem.Allocator, root: std.json.Value, event_type: []const u8, ctx: ?*anyopaque) anyerror!EventMapOutcome,
};

pub const CoreOptions = struct {
    base_url: ?[]const u8 = null,
    path: []const u8,
    auth: AuthFactory,
    extra_headers: []const protocol.Header = &.{},
    provider_label: []const u8 = "openai-responses",
    event_mapper: EventMapper = .{ .map = identityEventMapper },
    reasoning_effort: ?[]const u8 = null,
    reasoning_summary: ?[]const u8 = null,
    build_request: ?*const fn (
        allocator: std.mem.Allocator,
        out: *std.ArrayListUnmanaged(u8),
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        reasoning_effort: ?[]const u8,
        reasoning_summary: ?[]const u8,
    ) anyerror!void = null,
};

pub fn streamCore(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    core: CoreOptions,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer payload_buf.deinit(allocator);
    const build_fn = core.build_request orelse &buildRequestJson;
    build_fn(allocator, &payload_buf, model, context, options, core.reasoning_effort, core.reasoning_summary) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to build request: {s}", .{@errorName(err)});
        return;
    };
    const transformed_payload = request_transform.transformJsonPayload(allocator, payload_buf.items, .{
        .model = &model,
        .stream_options = options,
    }) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to transform request: {s}", .{@errorName(err)});
        return;
    };
    defer if (transformed_payload) |payload| allocator.free(payload);
    const request_payload = transformed_payload orelse payload_buf.items;

    var auth_buf: [4096]u8 = undefined;
    const auth_value = core.auth.build(core.auth.ctx, &auth_buf, options.api_key) catch |err| {
        const msg = switch (err) {
            error.NoApiKey => "no API key provided",
            error.BufferTooSmall => "API key too long for auth buffer",
        };
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "{s}", .{msg});
        return;
    };

    const base = core.base_url orelse model.base_url;
    const uri_str = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, core.path }) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to build URI: {s}", .{@errorName(err)});
        return;
    };
    defer allocator.free(uri_str);

    const uri = std.Uri.parse(uri_str) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to parse URI: {s}", .{@errorName(err)});
        return;
    };

    var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
    defer client.deinit();

    var extra_headers_buf: [16]std.http.Header = undefined;
    var n_extra: usize = 0;
    extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
    n_extra += 1;

    if (model.headers) |mh| for (mh) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    };
    for (core.extra_headers) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    }
    if (options.headers) |custom| for (custom) |h| {
        if (n_extra >= extra_headers_buf.len) break;
        extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
        n_extra += 1;
    };

    var req = client.request(.POST, uri, .{
        .extra_headers = extra_headers_buf[0..n_extra],
        .headers = .{
            .content_type = .{ .override = "application/json" },
            .accept_encoding = .{ .override = "identity" },
        },
    }) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to open connection: {s}", .{@errorName(err)});
        return;
    };
    defer req.deinit();

    var abort_guard = http_cancel.ShutdownOnCancel.start(options.io, options.signal, &req) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to start interrupt guard: {s}", .{@errorName(err)});
        return;
    };
    defer abort_guard.stop();

    req.sendBodyComplete(request_payload) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to send body: {s}", .{@errorName(err)});
        return;
    };

    var redirect_buf: [4096]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch |err| {
        emitError(allocator, callback, callback_ctx, model, core.provider_label, "request failed: {s}", .{@errorName(err)});
        return;
    };

    const status = response.head.status;
    var transfer_buf: [16384]u8 = undefined;
    if (status != .ok) {
        var reader = response.reader(&transfer_buf);
        var err_body_buf: [4096]u8 = undefined;
        var n_read: usize = 0;
        while (n_read < err_body_buf.len) {
            var writer: std.Io.Writer = .fixed(err_body_buf[n_read..]);
            const n = reader.stream(&writer, .limited(err_body_buf.len - n_read)) catch |err| switch (err) {
                error.EndOfStream => break,
                error.WriteFailed => unreachable,
                else => break,
            };
            if (n == 0) break;
            n_read += n;
        }
        const normalized = provider_failure.normalizeHttpFailure(allocator, status, err_body_buf[0..n_read]) catch |err| {
            emitError(allocator, callback, callback_ctx, model, core.provider_label, "failed to normalize HTTP error: {s}", .{@errorName(err)});
            return;
        };
        emitFailure(allocator, callback, callback_ctx, model, core.provider_label, normalized.failure, normalized.display_message);
        return;
    }

    var reader = response.reader(&transfer_buf);
    processStreamMapped(allocator, &reader, model, options.signal, core.provider_label, core.event_mapper, callback, callback_ctx);
}

const ItemKind = enum { reasoning, message, function_call };
const MessagePartKind = enum { output_text, refusal };

const ItemState = struct {
    kind: ItemKind,
    block_idx: usize,
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

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
    tool_args_partial: std.ArrayListUnmanaged(u8) = .empty,
    tool_args_parsed: std.json.Value = .null,

    tool_composite_id: []const u8 = "",

    fn deinit(self: *ItemState, allocator: std.mem.Allocator) void {
        self.text_buf.deinit(allocator);
        self.tool_args_partial.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ItemState),
    current: ?usize = null,
    partial: protocol.AssistantMessage,
    response_id: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, model: protocol.Model) StreamState {
        return .{
            .allocator = allocator,
            .items = .empty,
            .partial = .{
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
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            },
        };
    }

    fn deinit(self: *StreamState) void {
        for (self.items.items) |*it| it.deinit(self.allocator);
        self.items.deinit(self.allocator);
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
    reader: anytype,
    model: protocol.Model,
    abort_flag: Token,
    provider_label: []const u8,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    processStreamMapped(allocator, reader, model, abort_flag, provider_label, .{ .map = identityEventMapper }, callback, callback_ctx);
}

pub fn processStreamMapped(
    allocator: std.mem.Allocator,
    reader: anytype,
    model: protocol.Model,
    abort_flag: Token,
    provider_label: []const u8,
    event_mapper: EventMapper,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var state = StreamState.init(allocator, model);
    defer state.deinit();

    callback(.{ .start = .{ .partial = state.partial } }, callback_ctx);

    var parser = sse.SseParser.init(allocator);
    defer parser.deinit();

    const StreamCtx = struct {
        allocator: std.mem.Allocator,
        state: *StreamState,
        scratch: *std.heap.ArenaAllocator,
        mapper: EventMapper,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,

        fn onEvent(evt: sse.SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try handleEvent(self.allocator, self.state, self.scratch, evt, self.mapper, self.callback, self.callback_ctx);
        }
    };

    var stream_ctx = StreamCtx{
        .allocator = allocator,
        .state = &state,
        .scratch = &scratch_arena,
        .mapper = event_mapper,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };

    sse.streamEvents(allocator, reader, &parser, 4096, .{
        .func = &StreamCtx.onEvent,
        .ctx = @ptrCast(&stream_ctx),
    }) catch |err| {
        switch (err) {
            error.StopStreaming => {},
            else => if (abort_flag.isAborted()) {
                state.partial.stop_reason = .aborted;
            } else if (err == error.EventDataTooLarge) {
                emitError(
                    allocator,
                    callback,
                    callback_ctx,
                    model,
                    provider_label,
                    "stream event exceeded {d} bytes",
                    .{sse.max_event_data_bytes},
                );
                return;
            } else {
                emitError(allocator, callback, callback_ctx, model, provider_label, "stream read error: {s}", .{@errorName(err)});
                return;
            },
        }
    };

    state.partial.content = buildFinalContent(allocator, state.items.items) catch &.{};
    if (state.partial.stop_reason == .stop and assistantHasToolCalls(state.partial)) {
        state.partial.stop_reason = .toolUse;
    }

    if (state.partial.stop_reason == .aborted) {
        callback(.{ .done = .{ .reason = .stop, .message = state.partial } }, callback_ctx);
    } else if (state.partial.stop_reason == .@"error") {
        callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = state.partial } }, callback_ctx);
    } else {
        const reason: protocol.AssistantMessageEvent.DoneReason = switch (state.partial.stop_reason) {
            .stop => .stop,
            .length => .length,
            .toolUse => .toolUse,
            else => .stop,
        };
        callback(.{ .done = .{ .reason = reason, .message = state.partial } }, callback_ctx);
    }
}

const HandleErr = error{ OutOfMemory, StopStreaming };

fn handleEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    evt: sse.SseEvent,
    event_mapper: EventMapper,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) HandleErr!void {
    if (evt.data.len == 0) return;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, evt.data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    const type_v = root.object.get("type") orelse return;
    if (type_v != .string) return;
    const raw_type = type_v.string;

    var mapped_type = raw_type;
    var stop_after_event = false;
    var normalize_terminal_status = false;
    switch (event_mapper.map(allocator, root, raw_type, event_mapper.ctx) catch return) {
        .pass_through => {},
        .normalized => |normalized| {
            mapped_type = normalized.event_type;
            stop_after_event = normalized.stop_after_event;
            normalize_terminal_status = normalized.normalize_terminal_status;
        },
        .fail => |message| {
            state.partial.stop_reason = .@"error";
            state.partial.error_message = message;
            return error.StopStreaming;
        },
    }
    const t = mapped_type;

    if (std.mem.eql(u8, t, "response.created")) {
        if (root.object.get("response")) |resp| if (resp == .object) {
            if (resp.object.get("id")) |id| if (id == .string and id.string.len > 0) {
                state.response_id = allocator.dupe(u8, id.string) catch null;
                state.partial.response_id = state.response_id;
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
            try updatePartialContent(allocator, state);
            callback(.{ .thinking_start = .{ .content_index = idx, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, it_type, "message")) {
            const idx = state.items.items.len;
            try state.items.append(allocator, .{ .kind = .message, .block_idx = idx });
            state.current = idx;
            const it = &state.items.items[idx];
            if (item.object.get("id")) |id| if (id == .string) {
                it.msg_id = allocator.dupe(u8, id.string) catch "";
            };
            if (item.object.get("phase")) |ph| if (ph == .string) {
                it.msg_phase = allocator.dupe(u8, ph.string) catch null;
            };
            try updatePartialContent(allocator, state);
            callback(.{ .text_start = .{ .content_index = idx, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, it_type, "function_call")) {
            const idx = state.items.items.len;
            try state.items.append(allocator, .{ .kind = .function_call, .block_idx = idx });
            state.current = idx;
            const it = &state.items.items[idx];
            if (item.object.get("call_id")) |c| if (c == .string) {
                it.tool_call_id = allocator.dupe(u8, c.string) catch "";
            };
            if (item.object.get("id")) |c| if (c == .string) {
                it.tool_item_id = allocator.dupe(u8, c.string) catch "";
            };
            if (item.object.get("name")) |n| if (n == .string) {
                it.tool_name = allocator.dupe(u8, n.string) catch "";
            };
            if (item.object.get("arguments")) |a| if (a == .string and a.string.len > 0) {
                try it.tool_args_partial.appendSlice(allocator, a.string);
            };
            try ensureToolCompositeId(allocator, it);
            try updatePartialContent(allocator, state);
            callback(.{ .toolcall_start = .{ .content_index = idx, .partial = state.partial } }, callback_ctx);
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
        try updatePartialContent(allocator, state);
        callback(.{ .thinking_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
            .partial = state.partial,
        } }, callback_ctx);
        return;
    }

    if (std.mem.eql(u8, t, "response.reasoning_summary_part.done")) {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .reasoning or !it.summary_started) return;
        try it.text_buf.appendSlice(allocator, "\n\n");
        try updatePartialContent(allocator, state);
        callback(.{ .thinking_delta = .{
            .content_index = it.block_idx,
            .delta = "\n\n",
            .partial = state.partial,
        } }, callback_ctx);
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
        try updatePartialContent(allocator, state);
        callback(.{ .text_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
            .partial = state.partial,
        } }, callback_ctx);
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
        it.tool_args_parsed = partial_json.parseStreaming(scratch.allocator(), it.tool_args_partial.items) catch .null;
        try updatePartialContent(allocator, state);
        callback(.{ .toolcall_delta = .{
            .content_index = it.block_idx,
            .delta = dv.string,
            .partial = state.partial,
        } }, callback_ctx);
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
            const final_text = finalThinkingTextFromItem(allocator, item) catch null;
            if (final_text) |text| {
                defer allocator.free(text);
                try clearAndSetText(&st.text_buf, allocator, text);
            }
            st.thinking_signature = stringifyJsonValue(allocator, item) catch null;
            try updatePartialContent(allocator, state);
            callback(.{ .thinking_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "message") and st.kind == .message) {
            if (item.object.get("id")) |id| if (id == .string) {
                st.msg_id = allocator.dupe(u8, id.string) catch st.msg_id;
            };
            if (item.object.get("phase")) |phase| if (phase == .string) {
                st.msg_phase = allocator.dupe(u8, phase.string) catch st.msg_phase;
            };
            const final_text = finalMessageTextFromItem(allocator, item) catch null;
            if (final_text) |text| {
                defer allocator.free(text);
                try clearAndSetText(&st.text_buf, allocator, text);
            }
            st.text_signature = encodeTextSignatureV1(allocator, st.msg_id, st.msg_phase) catch null;
            try updatePartialContent(allocator, state);
            callback(.{ .text_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "function_call") and st.kind == .function_call) {
            if (item.object.get("call_id")) |call_id| if (call_id == .string) {
                st.tool_call_id = allocator.dupe(u8, call_id.string) catch st.tool_call_id;
            };
            if (item.object.get("id")) |item_id| if (item_id == .string) {
                st.tool_item_id = allocator.dupe(u8, item_id.string) catch st.tool_item_id;
            };
            if (item.object.get("name")) |name| if (name == .string) {
                st.tool_name = allocator.dupe(u8, name.string) catch st.tool_name;
            };
            if (item.object.get("arguments")) |arguments| if (arguments == .string) {
                st.tool_args_partial.clearRetainingCapacity();
                try st.tool_args_partial.appendSlice(allocator, arguments.string);
            };
            const final_args = partial_json.parseStreaming(allocator, st.tool_args_partial.items) catch .null;
            st.tool_args_parsed = final_args;
            st.tool_composite_id = "";
            try ensureToolCompositeId(allocator, st);
            try updatePartialContent(allocator, state);
            const tc: protocol.ToolCall = .{
                .id = st.tool_composite_id,
                .name = st.tool_name,
                .arguments = final_args,
            };
            callback(.{ .toolcall_end = .{
                .content_index = st.block_idx,
                .tool_call = tc,
                .partial = state.partial,
            } }, callback_ctx);
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
                state.response_id = allocator.dupe(u8, id.string) catch null;
                state.partial.response_id = state.response_id;
            }
        };
        if (resp.object.get("usage")) |u| if (u == .object) parseUsage(u, &state.partial);
        if (resp.object.get("status")) |s| if (s == .string) {
            state.partial.stop_reason = mapResponseStatus(if (normalize_terminal_status) normalizeCodexStatus(s.string) else s.string);
        };
        if (state.partial.stop_reason == .stop) {
            for (state.items.items) |it| if (it.kind == .function_call) {
                state.partial.stop_reason = .toolUse;
                break;
            };
        }
        if (stop_after_event) return error.StopStreaming;
        return;
    }

    if (std.mem.eql(u8, t, "error") or std.mem.eql(u8, t, "response.failed")) {
        state.partial.stop_reason = .@"error";
        if (root.object.get("message")) |m| if (m == .string) {
            state.partial.error_message = allocator.dupe(u8, m.string) catch null;
        };
        return;
    }
}

fn clearAndSetText(buf: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    buf.clearRetainingCapacity();
    try buf.appendSlice(allocator, text);
}

fn finalThinkingTextFromItem(allocator: std.mem.Allocator, item: std.json.Value) ![]const u8 {
    if (item != .object) return allocator.dupe(u8, "");
    const summary = item.object.get("summary") orelse return allocator.dupe(u8, "");
    if (summary != .array) return allocator.dupe(u8, "");

    var out: std.ArrayListUnmanaged(u8) = .empty;
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
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

fn updatePartialContent(allocator: std.mem.Allocator, state: *StreamState) HandleErr!void {
    const buf = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, state.items.items.len);
    for (state.items.items, 0..) |*it, i| buf[i] = renderItem(it);
    state.partial.content = buf;
}

fn ensureToolCompositeId(allocator: std.mem.Allocator, it: *ItemState) !void {
    if (it.kind != .function_call) return;
    if (it.tool_composite_id.len > 0) return;
    if (it.tool_call_id.len == 0 or it.tool_item_id.len == 0) return;
    it.tool_composite_id = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ it.tool_call_id, it.tool_item_id });
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

fn buildFinalContent(allocator: std.mem.Allocator, items: []const ItemState) ![]protocol.AssistantMessage.AssistantContentBlock {
    const out = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, items.len);
    for (items, 0..) |*it, i| out[i] = renderItem(it);
    return out;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
    return out.toOwnedSlice();
}

fn encodeTextSignatureV1(
    allocator: std.mem.Allocator,
    id: []const u8,
    phase: ?[]const u8,
) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
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

fn identityEventMapper(
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
        return .{ .fail = try std.fmt.allocPrint(allocator, "Codex error: {s}", .{try stringifyJsonValue(allocator, root)}) };
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
    partial.usage.total_tokens = if (usage.object.get("total_tokens")) |t| jsonU64(t) else (non_cached_input + output + cache_read);
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
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
    model: protocol.Model,
    provider_label: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const inner = std.fmt.allocPrint(allocator, fmt, args) catch "error";
    const normalized = provider_failure.formatTransportFailure(allocator, inner) catch null;
    emitFailure(allocator, callback, callback_ctx, model, provider_label, if (normalized) |n| n.failure else null, inner);
}

pub fn emitFailure(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
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
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } }, callback_ctx);
}

pub fn writeBaseFields(jw: *std.json.Stringify, model: protocol.Model) !void {
    try jw.objectField("model");
    try jw.write(model.id);

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("store");
    try jw.write(false);
}

pub const ToolStrictMode = enum {
    omit,
    false_value,
    null_value,
};

pub fn writeTools(jw: *std.json.Stringify, tools: []const protocol.Tool, strict_mode: ToolStrictMode) !void {
    try jw.objectField("tools");
    try jw.beginArray();
    for (tools) |tool| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("name");
        try jw.write(tool.name);
        try jw.objectField("description");
        try jw.write(tool.description);
        try jw.objectField("parameters");
        try jw.write(tool.parameters);
        switch (strict_mode) {
            .omit => {},
            .false_value => {
                try jw.objectField("strict");
                try jw.write(false);
            },
            .null_value => {
                try jw.objectField("strict");
                try jw.write(null);
            },
        }
        try jw.endObject();
    }
    try jw.endArray();
}

fn resolveCacheRetention(env: @import("../runtime/env.zig").Env, cache_retention: ?protocol.CacheRetention) protocol.CacheRetention {
    if (cache_retention) |retention| return retention;
    const value = env.get("PI_CACHE_RETENTION") orelse return .short;
    if (std.mem.eql(u8, value, "long")) return .long;
    return .short;
}

fn getPromptCacheRetention(base_url: []const u8, cache_retention: protocol.CacheRetention) ?[]const u8 {
    if (cache_retention != .long) return null;
    if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) return "24h";
    return null;
}

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    reasoning_effort: ?[]const u8,
    reasoning_summary: ?[]const u8,
) !void {
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try writeBaseFields(&jw, model);

    try jw.objectField("input");
    try jw.beginArray();
    try writeInput(allocator, &jw, model, context);
    try jw.endArray();

    const cache_retention = resolveCacheRetention(options.env, options.cache_retention);
    if (cache_retention != .none) {
        if (options.session_id) |sid| {
            try jw.objectField("prompt_cache_key");
            try jw.write(sid);
        }
    }
    if (getPromptCacheRetention(model.base_url, cache_retention)) |retention| {
        try jw.objectField("prompt_cache_retention");
        try jw.write(retention);
    }

    if (options.max_tokens) |max_tokens| {
        try jw.objectField("max_output_tokens");
        try jw.write(max_tokens);
    }

    if (options.temperature) |temperature| {
        try jw.objectField("temperature");
        try jw.write(temperature);
    }

    if (context.tools) |tools| {
        try writeTools(&jw, tools, .false_value);
    }

    if (model.reasoning) {
        if (reasoning_effort) |effort| {
            try jw.objectField("reasoning");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write(effort);
            try jw.objectField("summary");
            try jw.write(reasoning_summary orelse "auto");
            try jw.endObject();
            try jw.objectField("include");
            try jw.beginArray();
            try jw.write("reasoning.encrypted_content");
            try jw.endArray();
        } else if (model.provider != .github_copilot) {
            try jw.objectField("reasoning");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write("none");
            try jw.endObject();
        }
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

pub fn writeInput(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
) !void {
    writeInputOpts(allocator, jw, model, context, true) catch |err| return err;
}

pub fn writeInputOpts(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
    include_system_prompt: bool,
) !void {
    try replay.writeResponsesInput(allocator, jw, model, context, .{ .include_system_prompt = include_system_prompt });
}

const ToolCallIdMapping = struct {
    original_id: []const u8,
    mapped_id: []const u8,

    fn deinit(self: ToolCallIdMapping, allocator: std.mem.Allocator) void {
        allocator.free(self.original_id);
        allocator.free(self.mapped_id);
    }
};

const PendingToolCall = struct {
    id: []const u8,
    name: []const u8,

    fn deinit(self: PendingToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

fn writeUserMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    u: protocol.UserMessage,
) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.beginArray();
    switch (u.content) {
        .text => |text| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_text");
            try jw.objectField("text");
            try jw.write(text);
            try jw.endObject();
        },
        .blocks => |blocks| for (blocks) |b| switch (b) {
            .text => |tc| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_text");
                try jw.objectField("text");
                try jw.write(tc.text);
                try jw.endObject();
            },
            .image => |ic| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_image");
                try jw.objectField("detail");
                try jw.write("auto");
                try jw.objectField("image_url");
                const url = try std.fmt.allocPrint(
                    allocator,
                    "data:{s};base64,{s}",
                    .{ ic.mime_type, ic.data },
                );
                defer allocator.free(url);
                try jw.write(url);
                try jw.endObject();
            },
        },
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeToolResultMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    tr: protocol.ToolResultMessage,
    mapped_tool_call_id: []const u8,
) !void {
    var concat: std.ArrayListUnmanaged(u8) = .empty;
    defer concat.deinit(allocator);
    var saw_text = false;
    for (tr.content) |cb| switch (cb) {
        .text => |text| {
            if (saw_text) try concat.appendSlice(allocator, "\n");
            try concat.appendSlice(allocator, text.text);
            saw_text = true;
        },
        .image => {},
    };

    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function_call_output");
    try jw.objectField("call_id");
    const call_id = if (std.mem.indexOfScalar(u8, mapped_tool_call_id, '|')) |i|
        mapped_tool_call_id[0..i]
    else
        mapped_tool_call_id;
    try jw.write(call_id);
    try jw.objectField("output");
    if (concat.items.len == 0) {
        try jw.write("(empty tool result)");
    } else {
        const sanitized = try json_util.utf8LossyAlloc(allocator, concat.items);
        defer allocator.free(sanitized);
        try jw.write(sanitized);
    }
    try jw.endObject();
}

fn getMappedToolCallId(
    allocator: std.mem.Allocator,
    mappings: []const ToolCallIdMapping,
    tool_call_id: []const u8,
) ![]const u8 {
    for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.original_id, tool_call_id)) {
            return allocator.dupe(u8, mapping.mapped_id);
        }
    }
    return allocator.dupe(u8, tool_call_id);
}

fn recordToolCallIdMapping(
    allocator: std.mem.Allocator,
    tool_id_map: *std.ArrayListUnmanaged(ToolCallIdMapping),
    original_id: []const u8,
    normalized: NormalizedToolCallId,
) !void {
    var mapped = std.ArrayListUnmanaged(u8).empty;
    defer mapped.deinit(allocator);
    try mapped.appendSlice(allocator, normalized.call_id);
    if (normalized.item_id) |item_id| {
        try mapped.append(allocator, '|');
        try mapped.appendSlice(allocator, item_id);
    }
    const mapped_id = try mapped.toOwnedSlice(allocator);
    errdefer allocator.free(mapped_id);

    for (tool_id_map.items) |*mapping| {
        if (std.mem.eql(u8, mapping.original_id, original_id)) {
            allocator.free(mapping.mapped_id);
            mapping.mapped_id = mapped_id;
            return;
        }
    }

    try tool_id_map.append(allocator, .{
        .original_id = try allocator.dupe(u8, original_id),
        .mapped_id = mapped_id,
    });
}

fn flushPendingSyntheticToolResults(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    pending_tool_calls: *std.ArrayListUnmanaged(PendingToolCall),
    existing_tool_result_ids: []const []const u8,
    tool_id_map: *std.ArrayListUnmanaged(ToolCallIdMapping),
) !void {
    for (pending_tool_calls.items) |pending| {
        var found = false;
        for (existing_tool_result_ids) |existing| {
            if (std.mem.eql(u8, existing, pending.id)) {
                found = true;
                break;
            }
        }
        if (found) continue;

        const synthetic: protocol.ToolResultMessage = .{
            .tool_call_id = pending.id,
            .tool_name = pending.name,
            .content = &.{.{ .text = .{ .text = "No result provided" } }},
            .details = null,
            .is_error = true,
            .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
        };
        const mapped_id = try getMappedToolCallId(allocator, tool_id_map.items, pending.id);
        defer allocator.free(mapped_id);
        try writeToolResultMessage(allocator, jw, synthetic, mapped_id);
    }
}

fn writeAssistantMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    target_model: protocol.Model,
    a: protocol.AssistantMessage,
    msg_index: usize,
    tool_id_map: *std.ArrayListUnmanaged(ToolCallIdMapping),
) !void {
    for (a.content) |b| switch (b) {
        .thinking => |th| {
            if (th.thinking_signature) |sig| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{}) catch continue;
                defer parsed.deinit();
                try jw.write(parsed.value);
            }
        },
        .text => |tc| {
            var msg_id: []const u8 = "";
            var msg_id_alloc: ?[]const u8 = null;
            var msg_phase: ?[]const u8 = null;
            var msg_phase_alloc: ?[]const u8 = null;
            defer if (msg_id_alloc) |p| allocator.free(p);
            defer if (msg_phase_alloc) |p| allocator.free(p);
            if (tc.text_signature) |sig| {
                if (sig.len > 0 and sig[0] == '{') {
                    if (std.json.parseFromSlice(std.json.Value, allocator, sig, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("id")) |id| if (id == .string) {
                                msg_id_alloc = allocator.dupe(u8, id.string) catch null;
                                if (msg_id_alloc) |m| msg_id = m;
                            };
                            if (parsed.value.object.get("phase")) |phase| if (phase == .string) {
                                msg_phase_alloc = allocator.dupe(u8, phase.string) catch null;
                                if (msg_phase_alloc) |p| msg_phase = p;
                            };
                        }
                    } else |_| {}
                }
            }
            if (msg_id.len == 0) {
                const fallback = try std.fmt.allocPrint(allocator, "msg_{d}", .{msg_index});
                msg_id_alloc = fallback;
                msg_id = fallback;
            }
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("message");
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("status");
            try jw.write("completed");
            try jw.objectField("id");
            try jw.write(msg_id);
            if (msg_phase) |phase| {
                try jw.objectField("phase");
                try jw.write(phase);
            }
            try jw.objectField("content");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("output_text");
            try jw.objectField("text");
            try jw.write(tc.text);
            try jw.objectField("annotations");
            try jw.beginArray();
            try jw.endArray();
            try jw.endObject();
            try jw.endArray();
            try jw.endObject();
        },
        .tool_call => |tcall| {
            var normalized = try normalizeResponsesToolCallId(allocator, target_model, a, tcall.id);
            defer normalized.deinit(allocator);
            try recordToolCallIdMapping(allocator, tool_id_map, tcall.id, normalized);
            const is_different_model = !std.mem.eql(u8, a.model, target_model.id) and
                providersEqual(a.provider, target_model.provider) and
                apisEqual(a.api, target_model.api);
            const include_item_id = if (normalized.item_id) |iid|
                !(is_different_model and std.mem.startsWith(u8, iid, "fc_"))
            else
                false;

            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call");
            if (include_item_id) {
                try jw.objectField("id");
                try jw.write(normalized.item_id.?);
            }
            try jw.objectField("call_id");
            try jw.write(normalized.call_id);
            try jw.objectField("name");
            try jw.write(tcall.name);
            try jw.objectField("arguments");
            var args_buf: std.Io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            var inner = std.json.Stringify{ .writer = &args_buf.writer, .options = .{} };
            try inner.write(tcall.arguments);
            try jw.write(args_buf.written());
            try jw.endObject();
        },
    };
}

const NormalizedToolCallId = struct {
    call_id: []const u8,
    item_id: ?[]const u8,

    fn deinit(self: *NormalizedToolCallId, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        if (self.item_id) |item_id| allocator.free(item_id);
    }
};

fn normalizeResponsesToolCallId(
    allocator: std.mem.Allocator,
    target_model: protocol.Model,
    source: protocol.AssistantMessage,
    id: []const u8,
) !NormalizedToolCallId {
    const same_model = providersEqual(source.provider, target_model.provider) and
        apisEqual(source.api, target_model.api) and
        std.mem.eql(u8, source.model, target_model.id);
    if (!targetUsesResponsesToolCallNormalization(target_model.provider)) {
        return .{ .call_id = try normalizeIdPart(allocator, id), .item_id = null };
    }
    if (std.mem.indexOfScalar(u8, id, '|')) |sep| {
        if (same_model) {
            return .{
                .call_id = try allocator.dupe(u8, id[0..sep]),
                .item_id = try allocator.dupe(u8, id[sep + 1 ..]),
            };
        }
        const call_id = try normalizeIdPart(allocator, id[0..sep]);
        const item_part = id[sep + 1 ..];
        var item_id = if (!providersEqual(source.provider, target_model.provider) or !apisEqual(source.api, target_model.api))
            try buildForeignResponsesItemId(allocator, item_part)
        else
            try normalizeIdPart(allocator, item_part);
        if (!std.mem.startsWith(u8, item_id, "fc_")) {
            const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{item_id});
            allocator.free(item_id);
            item_id = try normalizeIdPart(allocator, prefixed);
            allocator.free(prefixed);
        }
        return .{ .call_id = call_id, .item_id = item_id };
    }
    if (same_model) {
        return .{ .call_id = try allocator.dupe(u8, id), .item_id = null };
    }
    return .{ .call_id = try normalizeIdPart(allocator, id), .item_id = null };
}

fn targetUsesResponsesToolCallNormalization(provider: protocol.Provider) bool {
    return switch (provider) {
        .openai, .openai_codex, .opencode, .opencode_go => true,
        else => false,
    };
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8).empty;
    defer out.deinit(allocator);
    for (part) |c| {
        const normalized = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => c,
            else => '_',
        };
        try out.append(allocator, normalized);
        if (out.items.len >= 64) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }
    return if (out.items.len == 0) allocator.dupe(u8, "id") else out.toOwnedSlice(allocator);
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, item_id);
    const raw = try std.fmt.allocPrint(allocator, "fc_{x}", .{hash});
    defer allocator.free(raw);
    return normalizeIdPart(allocator, raw);
}

fn providersEqual(a: protocol.Provider, b: protocol.Provider) bool {
    return std.meta.eql(a, b);
}

fn apisEqual(a: protocol.Api, b: protocol.Api) bool {
    return std.meta.eql(a, b);
}

fn formatHttpErrorDetail(allocator: std.mem.Allocator, status: std.http.Status, body: []const u8) ![]const u8 {
    const status_code = @intFromEnum(status);
    const reason = status.phrase() orelse "";
    const trimmed = std.mem.trim(u8, body, &std.ascii.whitespace);
    if (trimmed.len == 0) {
        if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s} (empty body)", .{ status_code, reason });
        return std.fmt.allocPrint(allocator, "HTTP {d} (empty body)", .{status_code});
    }

    if (std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{})) |parsed| {
        defer parsed.deinit();
        if (extractJsonErrorMessage(parsed.value)) |message| {
            if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s}: {s}", .{ status_code, reason, message });
            return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status_code, message });
        }
    } else |_| {}

    if (reason.len > 0) return std.fmt.allocPrint(allocator, "HTTP {d} {s}: {s}", .{ status_code, reason, trimmed });
    return std.fmt.allocPrint(allocator, "HTTP {d}: {s}", .{ status_code, trimmed });
}

fn extractJsonErrorMessage(value: std.json.Value) ?[]const u8 {
    if (value != .object) return null;
    if (value.object.get("error")) |err| {
        switch (err) {
            .string => |s| return s,
            .object => {
                if (err.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) return msg.string;
                if (err.object.get("code")) |code| if (code == .string and code.string.len > 0) return code.string;
            },
            else => {},
        }
    }
    if (value.object.get("message")) |msg| if (msg == .string and msg.string.len > 0) return msg.string;
    return null;
}

const testing = std.testing;

const TestCollector = struct {
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    thinking: std.ArrayListUnmanaged(u8) = .empty,
    tool_args: std.ArrayListUnmanaged(u8) = .empty,
    final_tool_id: []const u8 = "",
    final_tool_name: []const u8 = "",
    final_response_id: ?[]const u8 = null,
    done_reason: ?protocol.AssistantMessageEvent.DoneReason = null,
    allocator: std.mem.Allocator,

    const EventKind = enum {
        start,
        text_start,
        text_delta,
        text_end,
        thinking_start,
        thinking_delta,
        thinking_end,
        toolcall_start,
        toolcall_delta,
        toolcall_end,
        done,
        err,
    };

    fn deinit(self: *TestCollector) void {
        self.events.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.thinking.deinit(self.allocator);
        self.tool_args.deinit(self.allocator);
    }

    fn cb(evt: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        switch (evt) {
            .start => |s| {
                self.events.append(self.allocator, .start) catch {};
                if (s.partial.response_id) |rid| self.final_response_id = rid;
            },
            .text_start => self.events.append(self.allocator, .text_start) catch {},
            .text_delta => |d| {
                self.events.append(self.allocator, .text_delta) catch {};
                self.text.appendSlice(self.allocator, d.delta) catch {};
                if (d.partial.response_id) |rid| self.final_response_id = rid;
            },
            .text_end => |end| {
                self.events.append(self.allocator, .text_end) catch {};
                if (end.content.len > 0) {
                    self.text.clearRetainingCapacity();
                    self.text.appendSlice(self.allocator, end.content) catch {};
                }
            },
            .thinking_start => self.events.append(self.allocator, .thinking_start) catch {},
            .thinking_delta => |d| {
                self.events.append(self.allocator, .thinking_delta) catch {};
                self.thinking.appendSlice(self.allocator, d.delta) catch {};
            },
            .thinking_end => self.events.append(self.allocator, .thinking_end) catch {},
            .toolcall_start => self.events.append(self.allocator, .toolcall_start) catch {},
            .toolcall_delta => |d| {
                self.events.append(self.allocator, .toolcall_delta) catch {};
                self.tool_args.appendSlice(self.allocator, d.delta) catch {};
            },
            .toolcall_end => |e| {
                self.events.append(self.allocator, .toolcall_end) catch {};
                self.final_tool_id = e.tool_call.id;
                self.final_tool_name = e.tool_call.name;
            },
            .done => |d| {
                self.events.append(self.allocator, .done) catch {};
                self.done_reason = d.reason;
                if (d.message.response_id) |rid| self.final_response_id = rid;
            },
            .@"error" => self.events.append(self.allocator, .err) catch {},
        }
    }
};

const test_model: protocol.Model = .{
    .id = "openai/gpt-test",
    .name = "test",
    .api = .openai_responses,
    .provider = .openai,
    .base_url = "https://api.openai.com",
    .reasoning = true,
    .input = &.{.text},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 4096,
    .max_tokens = 1024,
};

fn runProcessWithMapper(
    arena: std.mem.Allocator,
    sse_bytes: []const u8,
    event_mapper: EventMapper,
    collector: *TestCollector,
) void {
    var reader: std.Io.Reader = .fixed(sse_bytes);
    processStreamMapped(arena, &reader, test_model, Token.none, "openai-responses", event_mapper, TestCollector.cb, collector);
}

fn runProcess(arena: std.mem.Allocator, sse_bytes: []const u8, collector: *TestCollector) void {
    runProcessWithMapper(arena, sse_bytes, .{ .map = identityEventMapper }, collector);
}

fn expectCollectorSaw(col: TestCollector, kind: TestCollector.EventKind) !void {
    for (col.events.items) |event| {
        if (event == kind) return;
    }
    return error.TestExpectedEqual;
}

fn writeInputToJson(allocator: std.mem.Allocator, model: protocol.Model, ctx: protocol.Context) ![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, &out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };
    try jw.beginArray();
    try writeInputOpts(allocator, &jw, model, ctx, false);
    try jw.endArray();
    return allocating.toOwnedSlice();
}

test "processStream maps reasoning summary deltas to a thinking block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_abc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_part.added\",\"part\":{\"type\":\"summary_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\"Let me think\"}\n\n" ++
        "data: {\"type\":\"response.reasoning_summary_text.delta\",\"delta\":\" carefully.\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"reasoning\",\"id\":\"rs_1\",\"encrypted_content\":\"opaque-blob\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_abc\",\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":20,\"total_tokens\":30}}}\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("Let me think carefully.", col.thinking.items);
    try testing.expectEqualStrings("resp_abc", col.final_response_id.?);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
    try expectCollectorSaw(col, .thinking_start);
    try expectCollectorSaw(col, .thinking_end);
}

test "processStream maps output_text deltas to a text block with response_id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_xyz\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" world\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_xyz\",\"status\":\"completed\"}}\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("Hello world", col.text.items);
    try testing.expectEqualStrings("resp_xyz", col.final_response_id.?);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
}

test "processStream concatenates function_call argument chunks and overrides stop to toolUse" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"cmd\\\":\\\"\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"echo hi\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_tc\",\"status\":\"completed\"}}\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("call_abc|fc_1", col.final_tool_id);
    try testing.expectEqualStrings("bash", col.final_tool_name);
    try testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", col.tool_args.items);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.toolUse, col.done_reason.?);
}

test "processStreamMapped codex mapper stops after terminal response.completed" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Hello\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_1\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":5,\"output_tokens\":3,\"total_tokens\":8}}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\" ignored\"}\n\n";

    runProcessWithMapper(alloc, sse_bytes, .{ .map = codexEventMapper }, &col);

    try testing.expectEqualStrings("Hello", col.text.items);
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.stop, col.done_reason.?);
}

test "processStream uses final output_item payload for message phase and tool ids" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"message\",\"id\":\"msg_added\"}}\n\n" ++
        "data: {\"type\":\"response.content_part.added\",\"part\":{\"type\":\"output_text\",\"text\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.output_text.delta\",\"delta\":\"draft\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"message\",\"id\":\"msg_final\",\"phase\":\"final_answer\",\"content\":[{\"type\":\"output_text\",\"text\":\"final text\"}]}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_added\",\"call_id\":\"call_added\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"draft\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.delta\",\"delta\":\"{\\\"cmd\\\":\\\"draft\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_final\",\"call_id\":\"call_final\",\"name\":\"bash_final\",\"arguments\":\"{\\\"cmd\\\":\\\"final\\\"}\"}}\n\n" ++
        "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqualStrings("final text", col.text.items);
    try testing.expectEqualStrings("call_final|fc_final", col.final_tool_id);
    try testing.expectEqualStrings("bash_final", col.final_tool_name);
}

test "buildRequestJson emits store:false, input[], and reasoning:none for reasoning model" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ctx: protocol.Context = .{
        .system_prompt = "be helpful",
        .messages = &.{
            .{ .user = .{ .content = .{ .text = "hi" }, .timestamp = 0 } },
        },
        .tools = null,
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try buildRequestJson(alloc, &out, test_model, ctx, .{}, null, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"store\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"developer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"input_text\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"none\"") != null);
}

test "buildRequestJson includes prompt cache, max_output_tokens, and temperature" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const ctx: protocol.Context = .{
        .messages = &.{
            .{ .user = .{ .content = .{ .text = "hi" }, .timestamp = 0 } },
        },
    };

    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);
    try buildRequestJson(alloc, &out, test_model, ctx, .{
        .session_id = "session-123",
        .cache_retention = .long,
        .max_tokens = 321,
        .temperature = 0.5,
    }, null, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_key\":\"session-123\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_retention\":\"24h\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"max_output_tokens\":321") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"temperature\":0.5") != null);
}

test "writeInputOpts remaps foreign tool result ids to the replayed function call id" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var foreign_args = std.json.Value{ .object = .{} };
    defer foreign_args.object.deinit(alloc);

    const assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call:bad|item bad!!!",
            .name = "bash",
            .arguments = foreign_args,
        } }},
        .api = .openai_completions,
        .provider = .openrouter,
        .model = "openai/gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tool_result: protocol.ToolResultMessage = .{
        .tool_call_id = "call:bad|item bad!!!",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "ok" } }},
        .details = null,
        .is_error = false,
        .timestamp = 0,
    };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = assistant }, .{ .tool_result = tool_result } } };

    const written = try writeInputToJson(alloc, test_model, ctx);
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "\"call_id\":\"call_bad\"") != null);
    try testing.expectEqual(@as(usize, 2), std.mem.count(u8, written, "\"call_id\":\"call_bad\""));
}

test "writeInputOpts inserts synthetic tool result and skips errored assistants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var synthetic_args = std.json.Value{ .object = .{} };
    defer synthetic_args.object.deinit(alloc);

    const tool_calling_assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call_1|fc_1",
            .name = "bash",
            .arguments = synthetic_args,
        } }},
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .model = "gpt-5.4",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const errored_assistant = protocol.AssistantMessage{
        .content = &.{.{ .text = .{ .text = "should not replay" } }},
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .model = "gpt-5.4",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .@"error",
        .timestamp = 0,
    };
    const user = protocol.UserMessage{ .content = .{ .text = "next" }, .timestamp = 0 };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = tool_calling_assistant }, .{ .assistant = errored_assistant }, .{ .user = user } } };

    const written = try writeInputToJson(alloc, .{
        .id = "gpt-5.4",
        .name = "codex",
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 4096,
        .max_tokens = 1024,
    }, ctx);
    defer alloc.free(written);
    try testing.expect(std.mem.indexOf(u8, written, "No result provided") != null);
    try testing.expect(std.mem.indexOf(u8, written, "should not replay") == null);
}

test "writeInputOpts serializes invalid tool-result utf-8 as output text" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var foreign_args = std.json.Value{ .object = .{} };
    defer foreign_args.object.deinit(alloc);

    const assistant = protocol.AssistantMessage{
        .content = &.{.{ .tool_call = .{
            .id = "call:bad|item bad!!!",
            .name = "bash",
            .arguments = foreign_args,
        } }},
        .api = .openai_completions,
        .provider = .openrouter,
        .model = "openai/gpt-test",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .toolUse,
        .timestamp = 0,
    };
    const tool_result: protocol.ToolResultMessage = .{
        .tool_call_id = "call:bad|item bad!!!",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "bad\xaa\xfftail" } }},
        .details = null,
        .is_error = false,
        .timestamp = 0,
    };
    const ctx: protocol.Context = .{ .messages = &.{ .{ .assistant = assistant }, .{ .tool_result = tool_result } } };

    const written = try writeInputToJson(alloc, test_model, ctx);
    defer alloc.free(written);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, written, .{});
    defer parsed.deinit();

    var found = false;
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const kind = item.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "function_call_output")) continue;
        const output = item.object.get("output") orelse continue;
        try testing.expect(output == .string);
        try testing.expect(std.mem.indexOf(u8, output.string, "tail") != null);
        found = true;
        break;
    }
    try testing.expect(found);
}

test "processStream infers toolUse at EOF when tool calls are present" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"type\":\"response.created\",\"response\":{\"id\":\"resp_tc\"}}\n\n" ++
        "data: {\"type\":\"response.output_item.added\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"\"}}\n\n" ++
        "data: {\"type\":\"response.function_call_arguments.done\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}\n\n" ++
        "data: {\"type\":\"response.output_item.done\",\"item\":{\"type\":\"function_call\",\"id\":\"fc_1\",\"call_id\":\"call_abc\",\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"echo hi\\\"}\"}}\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.toolUse, col.done_reason.?);
}
