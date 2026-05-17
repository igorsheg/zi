const std = @import("std");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const provider_failure = @import("provider_failure.zig");
const partial_json = @import("../json/partial.zig");
const json_value = @import("../json/value.zig");
const Token = protocol.CancelToken;

pub fn processStream(
    allocator: std.mem.Allocator,
    reader: anytype,
    model: protocol.Model,
    abort_flag: Token,
    sink: ai_provider.StreamEventSink,
) void {
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var state = StreamState.init(allocator, model);
    defer state.deinit();

    sink.emit(.start);

    var parser = sse.SseParser.init(allocator);
    defer parser.deinit();

    const StreamCtx = struct {
        allocator: std.mem.Allocator,
        state: *StreamState,
        scratch: *std.heap.ArenaAllocator,
        sink: ai_provider.StreamEventSink,

        fn onEvent(evt: sse.SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try handleSseEvent(self.allocator, self.state, self.scratch, evt, self.sink);
        }
    };

    var stream_ctx = StreamCtx{
        .allocator = allocator,
        .state = &state,
        .scratch = &scratch_arena,
        .sink = sink,
    };

    sse.streamEvents(allocator, reader, &parser, 4096, .{
        .func = &StreamCtx.onEvent,
        .ctx = @ptrCast(&stream_ctx),
    }) catch |err| {
        if (abort_flag.isAborted()) {
            state.message.stop_reason = .aborted;
        } else if (err == error.EventDataTooLarge) {
            emitError(allocator, sink, model, "stream event exceeded {d} bytes", .{sse.max_event_data_bytes});
            return;
        } else {
            emitError(allocator, sink, model, "stream read error: {s}", .{@errorName(err)});
            return;
        }
    };

    finishCurrentBlock(allocator, &state, sink) catch |err| {
        emitError(allocator, sink, model, "failed to finish stream block: {s}", .{@errorName(err)});
        return;
    };
    state.message.content = buildFinalContent(allocator, state.content_blocks.items) catch |err| {
        emitError(allocator, sink, model, "failed to build final content: {s}", .{@errorName(err)});
        return;
    };

    if (state.message.stop_reason == .aborted) {
        sink.emit(.{ .done = .{ .reason = .stop, .message = state.message } });
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

const BlockKind = enum { text, thinking, tool_call };

const ContentBlockState = struct {
    kind: BlockKind,
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

    tool_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_args_partial: std.ArrayListUnmanaged(u8) = .empty,
    tool_args_parsed: std.json.Value = .null,

    thought_signature: ?[]const u8 = null,

    fn deinit(self: *ContentBlockState, allocator: std.mem.Allocator) void {
        self.text_buf.deinit(allocator);
        self.tool_args_partial.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    content_blocks: std.ArrayListUnmanaged(ContentBlockState),
    current_index: ?usize = null,
    message: protocol.AssistantMessage,
    response_id: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, model: protocol.Model) StreamState {
        return .{
            .allocator = allocator,
            .content_blocks = .empty,
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
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            },
        };
    }

    fn deinit(self: *StreamState) void {
        for (self.content_blocks.items) |*b| b.deinit(self.allocator);
        self.content_blocks.deinit(self.allocator);
        if (self.response_id) |rid| self.allocator.free(rid);
    }
};

const HandleErr = error{OutOfMemory};

fn handleSseEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    evt: sse.SseEvent,
    sink: ai_provider.StreamEventSink,
) HandleErr!void {
    if (std.mem.eql(u8, evt.data, "[DONE]")) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, evt.data, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return,
    };
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    if (state.response_id == null) {
        if (root.object.get("id")) |id_val| {
            if (id_val == .string and id_val.string.len > 0) {
                state.response_id = try allocator.dupe(u8, id_val.string);
                state.message.response_id = state.response_id;
            }
        }
    }

    if (root.object.get("usage")) |usage_val| {
        if (usage_val == .object) parseUsage(usage_val, &state.message);
    }

    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            try applyProviderError(allocator, &state.message, err_val.object);
        }
        return;
    }

    const choices_val = root.object.get("choices") orelse return;
    if (choices_val != .array or choices_val.array.items.len == 0) return;
    const choice = choices_val.array.items[0];
    if (choice != .object) return;

    if (state.message.usage.input == 0 and state.message.usage.output == 0) {
        if (choice.object.get("usage")) |cu| {
            if (cu == .object) parseUsage(cu, &state.message);
        }
    }

    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            state.message.stop_reason = mapFinishReason(fr.string);
            state.message.failure = mapFinishReasonFailure(fr.string);
            if (state.message.stop_reason == .@"error") {
                state.message.error_message = try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{fr.string});
            }
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            try ensureBlock(allocator, state, .text, sink);
            const idx = state.current_index.?;
            try state.content_blocks.items[idx].text_buf.appendSlice(allocator, c.string);
            sink.emit(.{ .text_delta = .{
                .content_index = idx,
                .delta = c.string,
            } });
        }
    }

    const reasoning_fields = [_][]const u8{ "reasoning_content", "reasoning", "reasoning_text" };
    var reasoning_field: ?[]const u8 = null;
    var reasoning_delta: []const u8 = "";
    for (reasoning_fields) |f| {
        if (delta.object.get(f)) |rv| {
            if (rv == .string and rv.string.len > 0) {
                reasoning_field = f;
                reasoning_delta = rv.string;
                break;
            }
        }
    }
    if (reasoning_field) |_| {
        try ensureBlock(allocator, state, .thinking, sink);
        const idx = state.current_index.?;
        try state.content_blocks.items[idx].text_buf.appendSlice(allocator, reasoning_delta);
        sink.emit(.{ .thinking_delta = .{
            .content_index = idx,
            .delta = reasoning_delta,
        } });
    }

    if (delta.object.get("tool_calls")) |tcs_val| {
        if (tcs_val == .array) {
            for (tcs_val.array.items) |tc| {
                if (tc != .object) continue;
                try handleToolCallDelta(allocator, state, scratch, tc, sink);
            }
        }
    }

    if (delta.object.get("reasoning_details")) |rd| {
        if (rd == .array) {
            for (rd.array.items) |detail| {
                if (detail != .object) continue;
                const t = detail.object.get("type") orelse continue;
                if (t != .string) continue;
                if (!std.mem.eql(u8, t.string, "reasoning.encrypted")) continue;
                const id_v = detail.object.get("id") orelse continue;
                if (id_v != .string) continue;
                const data_v = detail.object.get("data") orelse continue;
                if (data_v != .string) continue;
                try attachThoughtSignature(allocator, state, id_v.string, detail);
            }
        }
    }
}

fn handleToolCallDelta(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    tc: std.json.Value,
    sink: ai_provider.StreamEventSink,
) HandleErr!void {
    const id_v = tc.object.get("id");
    const new_id_str: ?[]const u8 = if (id_v) |v|
        (if (v == .string) v.string else null)
    else
        null;

    const start_new = blk: {
        const cur = state.current_index orelse break :blk true;
        const blk_state = &state.content_blocks.items[cur];
        if (blk_state.kind != .tool_call) break :blk true;
        if (new_id_str) |nid| {
            if (!std.mem.eql(u8, blk_state.tool_id, nid)) break :blk true;
        }
        break :blk false;
    };

    if (start_new) {
        try ensureBlock(allocator, state, .tool_call, sink);
    }

    const idx = state.current_index.?;
    var blk_state = &state.content_blocks.items[idx];

    if (new_id_str) |nid| {
        if (blk_state.tool_id.len == 0) {
            blk_state.tool_id = try allocator.dupe(u8, nid);
        }
    }

    const fn_v = tc.object.get("function");
    var delta_str: []const u8 = "";
    if (fn_v) |f| {
        if (f == .object) {
            if (f.object.get("name")) |nv| {
                if (nv == .string and nv.string.len > 0 and blk_state.tool_name.len == 0) {
                    blk_state.tool_name = try allocator.dupe(u8, nv.string);
                }
            }
            if (f.object.get("arguments")) |av| {
                if (av == .string) {
                    delta_str = av.string;
                    try blk_state.tool_args_partial.appendSlice(allocator, av.string);
                    _ = scratch.reset(.retain_capacity);
                    const sa = scratch.allocator();
                    blk_state.tool_args_parsed = partial_json.parseStreaming(
                        sa,
                        blk_state.tool_args_partial.items,
                    ) catch .null;
                }
            }
        }
    }

    sink.emit(.{ .toolcall_delta = .{
        .content_index = idx,
        .delta = delta_str,
    } });
}

fn ensureBlock(
    allocator: std.mem.Allocator,
    state: *StreamState,
    kind: BlockKind,
    sink: ai_provider.StreamEventSink,
) HandleErr!void {
    if (state.current_index) |cur| {
        if (state.content_blocks.items[cur].kind == kind and kind != .tool_call) return;
        try finishCurrentBlock(allocator, state, sink);
    }

    const new_idx = state.content_blocks.items.len;
    try state.content_blocks.append(allocator, .{ .kind = kind });
    state.current_index = new_idx;

    const start_event: protocol.AssistantMessageEvent = switch (kind) {
        .text => .{ .text_start = .{ .content_index = new_idx } },
        .thinking => .{ .thinking_start = .{ .content_index = new_idx } },
        .tool_call => .{ .toolcall_start = .{ .content_index = new_idx } },
    };
    sink.emit(start_event);
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    state: *StreamState,
    sink: ai_provider.StreamEventSink,
) HandleErr!void {
    const cur = state.current_index orelse return;
    const blk_state = &state.content_blocks.items[cur];
    switch (blk_state.kind) {
        .text => {
            sink.emit(.{ .text_end = .{
                .content_index = cur,
                .content = blk_state.text_buf.items,
            } });
        },
        .thinking => {
            sink.emit(.{ .thinking_end = .{
                .content_index = cur,
                .content = blk_state.text_buf.items,
            } });
        },
        .tool_call => {
            const final_args = partial_json.parseStreaming(
                allocator,
                blk_state.tool_args_partial.items,
            ) catch .null;
            blk_state.tool_args_parsed = final_args;
            const tc: protocol.ToolCall = .{
                .id = blk_state.tool_id,
                .name = blk_state.tool_name,
                .arguments = final_args,
                .thought_signature = blk_state.thought_signature,
            };
            sink.emit(.{ .toolcall_end = .{
                .content_index = cur,
                .tool_call = tc,
            } });
        },
    }
    state.current_index = null;
}

fn renderBlock(b: *const ContentBlockState) protocol.AssistantMessage.AssistantContentBlock {
    return switch (b.kind) {
        .text => .{ .text = .{ .text = b.text_buf.items } },
        .thinking => .{ .thinking = .{ .thinking = b.text_buf.items } },
        .tool_call => .{ .tool_call = .{
            .id = b.tool_id,
            .name = b.tool_name,
            .arguments = b.tool_args_parsed,
            .thought_signature = b.thought_signature,
        } },
    };
}

fn buildFinalContent(
    allocator: std.mem.Allocator,
    blocks: []const ContentBlockState,
) ![]protocol.AssistantMessage.AssistantContentBlock {
    const out = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, blocks.len);
    for (blocks, 0..) |*b, i| {
        out[i] = renderBlock(b);
    }
    return out;
}

fn attachThoughtSignature(
    allocator: std.mem.Allocator,
    state: *StreamState,
    tool_id: []const u8,
    detail: std.json.Value,
) !void {
    for (state.content_blocks.items) |*b| {
        if (b.kind != .tool_call) continue;
        if (!std.mem.eql(u8, b.tool_id, tool_id)) continue;
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
        try jw.write(detail);
        b.thought_signature = try out.toOwnedSlice();
        return;
    }
}

fn parseUsage(usage: std.json.Value, partial: *protocol.AssistantMessage) void {
    var input: u64 = 0;
    var output: u64 = 0;
    var cache_read: u64 = 0;
    var reasoning: u64 = 0;
    if (usage.object.get("prompt_tokens")) |v| input = jsonU64(v);
    if (usage.object.get("completion_tokens")) |v| output = jsonU64(v);
    if (usage.object.get("prompt_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("cached_tokens")) |c| cache_read = jsonU64(c);
        }
    }
    if (usage.object.get("completion_tokens_details")) |d| {
        if (d == .object) {
            if (d.object.get("reasoning_tokens")) |r| reasoning = jsonU64(r);
        }
    }
    const non_cached_input = if (input > cache_read) input - cache_read else 0;
    const total_output = output + reasoning;
    partial.usage.input = non_cached_input;
    partial.usage.output = total_output;
    partial.usage.cache_read = cache_read;
    partial.usage.cache_write = 0;
    partial.usage.total_tokens = non_cached_input + total_output + cache_read;
}

fn jsonU64(v: std.json.Value) u64 {
    return switch (v) {
        .integer => |i| if (i < 0) 0 else @intCast(i),
        .float => |f| if (f < 0) 0 else @intFromFloat(f),
        else => 0,
    };
}

fn mapFinishReason(reason: []const u8) protocol.StopReason {
    if (std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "end")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) return .toolUse;
    return .@"error";
}

fn mapFinishReasonFailure(reason: []const u8) ?protocol.NormalizedFailure {
    if (std.mem.eql(u8, reason, "network_error")) return .{ .kind = .transient };
    if (std.mem.eql(u8, reason, "content_filter")) return .{ .kind = .invalid_request };
    if (std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "end") or std.mem.eql(u8, reason, "length") or std.mem.eql(u8, reason, "tool_calls") or std.mem.eql(u8, reason, "function_call")) {
        return null;
    }
    return .{ .kind = .fatal };
}

fn applyProviderError(
    allocator: std.mem.Allocator,
    partial: *protocol.AssistantMessage,
    err_obj: std.json.ObjectMap,
) error{OutOfMemory}!void {
    const provider_type = if (err_obj.get("type")) |v| if (v == .string and v.string.len > 0) try allocator.dupe(u8, v.string) else null else null;
    const provider_code = if (err_obj.get("code")) |v| try dupErrorCode(allocator, v) else null;
    const message = if (err_obj.get("message")) |v| if (v == .string and v.string.len > 0) v.string else "unknown provider error" else "unknown provider error";
    const detail = if (err_obj.get("metadata")) |metadata| try formatProviderMetadataRaw(allocator, metadata) else null;
    const combined_message = if (detail) |detail_text|
        try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ message, detail_text })
    else
        try allocator.dupe(u8, message);

    partial.stop_reason = .@"error";
    partial.error_message = combined_message;
    partial.failure = .{
        .kind = provider_failure.classifyProviderFailure(provider_type, provider_code, combined_message),
        .provider_type = provider_type,
        .provider_code = provider_code,
    };
}

fn dupErrorCode(allocator: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!?[]const u8 {
    return switch (value) {
        .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
        .integer => |i| try std.fmt.allocPrint(allocator, "{d}", .{i}),
        .float => |f| try std.fmt.allocPrint(allocator, "{d}", .{f}),
        else => null,
    };
}

fn formatProviderMetadataRaw(allocator: std.mem.Allocator, metadata: std.json.Value) error{OutOfMemory}!?[]const u8 {
    if (metadata != .object) return null;
    const raw = metadata.object.get("raw") orelse return null;
    return switch (raw) {
        .string => |s| if (s.len > 0) try allocator.dupe(u8, s) else null,
        else => blk: {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
            jw.write(raw) catch return error.OutOfMemory;
            const rendered = try out.toOwnedSlice();
            if (rendered.len == 0 or std.mem.eql(u8, rendered, "null")) {
                allocator.free(rendered);
                break :blk null;
            }
            break :blk rendered;
        },
    };
}

pub fn emitError(
    allocator: std.mem.Allocator,
    sink: ai_provider.StreamEventSink,
    model: protocol.Model,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "openai-completions error";
    const normalized = provider_failure.formatTransportFailure(allocator, msg) catch null;
    emitFailure(sink, model, if (normalized) |n| n.failure else null, msg);
}

pub fn emitFailure(
    sink: ai_provider.StreamEventSink,
    model: protocol.Model,
    failure: ?protocol.NormalizedFailure,
    message: []const u8,
) void {
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
        .error_message = message,
        .failure = failure,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    };
    sink.emit(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } });
}
