//! OpenAI chat/completions provider — `POST /chat/completions` with
//! SSE streaming. Used by openrouter today; future custom OpenAI-
//! compatible providers can use the same `api = .openai_completions`
//! tag and reuse this implementation.
//!
//! pi-mono source: packages/ai/src/providers/openai-completions.ts (871 LOC)
//!
//! ## Phase 3a scope
//!
//! Focused port. The full pi-mono provider handles ~10 different
//! upstream variants (zai, qwen, groq, xai, github-copilot, vercel
//! gateway, openrouter, etc.) with a `detectCompat` switchboard. zi
//! only registers openrouter under this api in the phase 3a catalog,
//! so this file ports:
//!
//!   - openrouter compat path (thinking_format = openrouter, nested
//!     `reasoning: { effort }` field, no `store`, default
//!     `max_completion_tokens`)
//!   - openai api-key path with `Authorization: Bearer ...`
//!   - text + image content for user messages
//!   - assistant messages with text and tool_calls
//!   - tool result messages
//!   - SSE chunk parsing: text deltas, reasoning deltas, tool-call
//!     deltas with split-arg concatenation, finish_reason mapping,
//!     usage capture
//!
//! Explicitly NOT ported (will land when zi registers a model that
//! needs them, per the doctrine "DO NOT skip the compat field — but
//! also DO NOT speculatively implement compat for providers we don't
//! support"):
//!
//!   - zai / qwen / qwen-chat-template thinking formats
//!   - github-copilot dynamic headers
//!   - vercel-ai-gateway routing
//!   - cerebras / xai / chutes / deepseek non-standard quirks
//!   - cache_control insertion for anthropic-via-openrouter
//!   - cross-provider tool-call-id normalization (pipe-stripped /
//!     truncated ids from openai-codex / opencode)
//!
//! ## Architecture
//!
//! Two layers, threaded together by `streamImpl`:
//!
//!   1. `processStream(allocator, reader, model, callback, ctx)` —
//!      pure SSE event consumer. Takes any `std.io.Reader`, drains
//!      it, emits `AssistantMessageEvent`s through `callback`. NO
//!      HTTP code. Tested in isolation against synthetic SSE bytes
//!      (mirrors pi-mono's `openai-codex-stream.test.ts` pattern).
//!
//!   2. `streamImpl(...)` — opens an HTTP request, builds the body
//!      via `buildRequestJson`, hands the response reader to
//!      `processStream`. NOT unit-tested; smoke-tested via the
//!      live openrouter call.

const std = @import("std");
const protocol = @import("protocol.zig");
const ai_models = @import("models.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const provider_failure = @import("provider_failure.zig");
const request_transform = @import("request_transform.zig");
const json_util = @import("json_util.zig");
const partial_json = @import("../json/partial.zig");
const json_value = @import("../json/value.zig");
const zio_abort = @import("../zio/root.zig").abort;
const AbortSignal = zio_abort.AbortSignal;
const AbortGuard = zio_abort.AbortGuard;
const env_api_keys = @import("env_api_keys.zig");

pub const OpenAICompletionsProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAICompletionsProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *OpenAICompletionsProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamImplWrapper,
                .stream_simple = streamSimpleImplWrapper,
                .get_name = getNameImpl,
                .deinit = deinitImpl,
            },
        };
    }

    fn streamImplWrapper(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self: *OpenAICompletionsProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options, null, callback, callback_ctx);
    }

    fn streamSimpleImplWrapper(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self: *OpenAICompletionsProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options.base, ai_models.clampReasoning(options.reasoning, model), callback, callback_ctx);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "openai-completions";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn streamImpl(
        self: *OpenAICompletionsProvider,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        reasoning: ?protocol.ThinkingLevel,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        _ = self;

        var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_buf.deinit(allocator);
        buildRequestJson(allocator, &payload_buf, model, context, reasoning) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to build request: {s}", .{@errorName(err)});
            return;
        };
        const transformed_payload = request_transform.transformJsonPayload(allocator, payload_buf.items, .{
            .model = &model,
            .stream_options = options,
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to transform request: {s}", .{@errorName(err)});
            return;
        };
        defer if (transformed_payload) |payload| allocator.free(payload);
        const request_payload = transformed_payload orelse payload_buf.items;

        const api_key = options.api_key orelse {
            emitError(allocator, callback, callback_ctx, model, "no API key provided", .{});
            return;
        };

        const uri_str = std.fmt.allocPrint(allocator, "{s}/chat/completions", .{model.base_url}) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to build URI: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to parse URI: {s}", .{@errorName(err)});
            return;
        };

        var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
        defer client.deinit();

        var auth_buf: [4096]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch {
            emitError(allocator, callback, callback_ctx, model, "API key too long for auth buffer", .{});
            return;
        };

        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;
        extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
        n_extra += 1;

        if (model.headers) |mh| {
            for (mh) |h| {
                if (n_extra >= extra_headers_buf.len) break;
                extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                n_extra += 1;
            }
        }
        if (options.headers) |custom_headers| {
            for (custom_headers) |h| {
                if (n_extra >= extra_headers_buf.len) break;
                extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                n_extra += 1;
            }
        }

        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers_buf[0..n_extra],
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to open connection: {s}", .{@errorName(err)});
            return;
        };
        defer req.deinit();

        var abort_guard = AbortGuard.start(options.io, options.signal, .{
            .shutdown_fd = AbortGuard.httpRequestShutdownFd(&req),
        });
        defer abort_guard.stop();

        req.sendBodyComplete(request_payload) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to send body: {s}", .{@errorName(err)});
            return;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "request failed: {s}", .{@errorName(err)});
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
                emitError(allocator, callback, callback_ctx, model, "failed to normalize HTTP error: {s}", .{@errorName(err)});
                return;
            };
            emitFailure(callback, callback_ctx, model, normalized.failure, normalized.display_message);
            return;
        }

        const reader = response.reader(&transfer_buf);
        processStream(allocator, reader, model, options.signal, callback, callback_ctx);
    }
};

/// Drain a Reader of OpenAI chat/completions SSE bytes, emit
/// `AssistantMessageEvent`s. Pure: no HTTP, no allocator escape, no
/// global state. Tested in isolation via `std.io.fixedBufferStream`
/// over hand-built byte sequences. The `reader` parameter is
/// `anytype` so we can swap in either an `std.http.Response.Reader`
/// or a fixed buffer reader.
pub fn processStream(
    allocator: std.mem.Allocator,
    reader: anytype,
    model: protocol.Model,
    abort_flag: AbortSignal,
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
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,

        fn onEvent(evt: sse.SseEvent, ctx: ?*anyopaque) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            try handleSseEvent(self.allocator, self.state, self.scratch, evt, self.callback, self.callback_ctx);
        }
    };

    var stream_ctx = StreamCtx{
        .allocator = allocator,
        .state = &state,
        .scratch = &scratch_arena,
        .callback = callback,
        .callback_ctx = callback_ctx,
    };

    sse.streamEvents(allocator, reader, &parser, 4096, .{
        .func = &StreamCtx.onEvent,
        .ctx = @ptrCast(&stream_ctx),
    }) catch |err| {
        if (abort_flag.isAborted()) {
            state.partial.stop_reason = .aborted;
        } else if (err == error.EventDataTooLarge) {
            emitError(allocator, callback, callback_ctx, model, "stream event exceeded {d} bytes", .{sse.max_event_data_bytes});
            return;
        } else {
            emitError(allocator, callback, callback_ctx, model, "stream read error: {s}", .{@errorName(err)});
            return;
        }
    };

    finishCurrentBlock(allocator, &state, callback, callback_ctx) catch {};
    state.partial.content = buildFinalContent(allocator, state.content_blocks.items) catch &.{};

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

const BlockKind = enum { text, thinking, tool_call };

const ContentBlockState = struct {
    kind: BlockKind,
    /// For text/thinking: accumulated chars. For tool_call: empty
    /// (the partial JSON lives in `tool_args_partial`).
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

    tool_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_args_partial: std.ArrayListUnmanaged(u8) = .empty,
    /// Currently parsed JSON value of `tool_args_partial`. Owned by
    /// the per-delta scratch arena, NOT by the allocator.
    tool_args_parsed: std.json.Value = .null,

    /// Optional reasoning_details thoughtSignature payload (json
    /// stringified) attached to a tool call when openrouter sends a
    /// `reasoning.encrypted` block referring to it.
    thought_signature: ?[]const u8 = null,

    fn deinit(self: *ContentBlockState, allocator: std.mem.Allocator) void {
        // Lifetime contract (mirrors anthropic.zig): only the
        // growable buffers (`text_buf`, `tool_args_partial`) get
        // explicit frees because they're ArrayLists that manage
        // their own capacity. `tool_id`, `tool_name`, and
        // `thought_signature` are duped INTO the turn arena; they
        // are BORROWED by the emitted `toolcall_end` event and
        // must survive until the agent loop drops its reference,
        // which outlives this deinit. Turn-arena reset at end of
        // the agent call reclaims them.
        self.text_buf.deinit(allocator);
        self.tool_args_partial.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    content_blocks: std.ArrayListUnmanaged(ContentBlockState),
    /// Index of the currently-streaming block, or null if none.
    current_index: ?usize = null,
    partial: protocol.AssistantMessage,
    response_id: ?[]const u8 = null,

    fn init(allocator: std.mem.Allocator, model: protocol.Model) StreamState {
        return .{
            .allocator = allocator,
            .content_blocks = .empty,
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
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) HandleErr!void {
    if (std.mem.eql(u8, evt.data, "[DONE]")) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, evt.data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    if (state.response_id == null) {
        if (root.object.get("id")) |id_val| {
            if (id_val == .string and id_val.string.len > 0) {
                state.response_id = allocator.dupe(u8, id_val.string) catch null;
                state.partial.response_id = state.response_id;
            }
        }
    }

    if (root.object.get("usage")) |usage_val| {
        if (usage_val == .object) parseUsage(usage_val, &state.partial);
    }

    if (root.object.get("error")) |err_val| {
        if (err_val == .object) {
            try applyProviderError(allocator, &state.partial, err_val.object);
        }
        return;
    }

    const choices_val = root.object.get("choices") orelse return;
    if (choices_val != .array or choices_val.array.items.len == 0) return;
    const choice = choices_val.array.items[0];
    if (choice != .object) return;

    if (state.partial.usage.input == 0 and state.partial.usage.output == 0) {
        if (choice.object.get("usage")) |cu| {
            if (cu == .object) parseUsage(cu, &state.partial);
        }
    }

    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            state.partial.stop_reason = mapFinishReason(fr.string);
            state.partial.failure = mapFinishReasonFailure(fr.string);
            if (state.partial.stop_reason == .@"error") {
                state.partial.error_message = try std.fmt.allocPrint(allocator, "Provider finish_reason: {s}", .{fr.string});
            }
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    if (delta.object.get("content")) |c| {
        if (c == .string and c.string.len > 0) {
            try ensureBlock(allocator, state, .text, callback, callback_ctx);
            const idx = state.current_index.?;
            try state.content_blocks.items[idx].text_buf.appendSlice(allocator, c.string);
            updatePartialContent(allocator, state) catch {};
            callback(.{ .text_delta = .{
                .content_index = idx,
                .delta = c.string,
                .partial = state.partial,
            } }, callback_ctx);
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
        try ensureBlock(allocator, state, .thinking, callback, callback_ctx);
        const idx = state.current_index.?;
        try state.content_blocks.items[idx].text_buf.appendSlice(allocator, reasoning_delta);
        updatePartialContent(allocator, state) catch {};
        callback(.{ .thinking_delta = .{
            .content_index = idx,
            .delta = reasoning_delta,
            .partial = state.partial,
        } }, callback_ctx);
    }

    if (delta.object.get("tool_calls")) |tcs_val| {
        if (tcs_val == .array) {
            for (tcs_val.array.items) |tc| {
                if (tc != .object) continue;
                try handleToolCallDelta(allocator, state, scratch, tc, callback, callback_ctx);
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
                attachThoughtSignature(allocator, state, id_v.string, detail) catch {};
            }
        }
    }
}

fn handleToolCallDelta(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    tc: std.json.Value,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
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
        try ensureBlock(allocator, state, .tool_call, callback, callback_ctx);
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

    updatePartialContent(allocator, state) catch {};
    callback(.{ .toolcall_delta = .{
        .content_index = idx,
        .delta = delta_str,
        .partial = state.partial,
    } }, callback_ctx);
}

/// Open a new content block of `kind`, finalizing any current block.
fn ensureBlock(
    allocator: std.mem.Allocator,
    state: *StreamState,
    kind: BlockKind,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) HandleErr!void {
    if (state.current_index) |cur| {
        if (state.content_blocks.items[cur].kind == kind and kind != .tool_call) return;
        try finishCurrentBlock(allocator, state, callback, callback_ctx);
    }

    const new_idx = state.content_blocks.items.len;
    try state.content_blocks.append(allocator, .{ .kind = kind });
    state.current_index = new_idx;

    updatePartialContent(allocator, state) catch {};

    const start_event: protocol.AssistantMessageEvent = switch (kind) {
        .text => .{ .text_start = .{ .content_index = new_idx, .partial = state.partial } },
        .thinking => .{ .thinking_start = .{ .content_index = new_idx, .partial = state.partial } },
        .tool_call => .{ .toolcall_start = .{ .content_index = new_idx, .partial = state.partial } },
    };
    callback(start_event, callback_ctx);
}

fn finishCurrentBlock(
    allocator: std.mem.Allocator,
    state: *StreamState,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) HandleErr!void {
    const cur = state.current_index orelse return;
    const blk_state = &state.content_blocks.items[cur];
    updatePartialContent(allocator, state) catch {};
    switch (blk_state.kind) {
        .text => {
            callback(.{ .text_end = .{
                .content_index = cur,
                .content = blk_state.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
        },
        .thinking => {
            callback(.{ .thinking_end = .{
                .content_index = cur,
                .content = blk_state.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
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
            callback(.{ .toolcall_end = .{
                .content_index = cur,
                .tool_call = tc,
                .partial = state.partial,
            } }, callback_ctx);
        },
    }
    state.current_index = null;
}

/// Rebuild `state.partial.content` to reflect the current set of
/// blocks. Allocates a fresh slice on every call — pi-mono does the
/// same effective thing by mutating in place. The slice lifetime is
/// the caller's allocator (the streaming arena), and we never free
/// the previous slice; it leaks into the arena and dies on arena
/// reset. Acceptable for the duration of one stream.
fn updatePartialContent(
    allocator: std.mem.Allocator,
    state: *StreamState,
) HandleErr!void {
    const buf = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, state.content_blocks.items.len);
    for (state.content_blocks.items, 0..) |*b, i| {
        buf[i] = renderBlock(b);
    }
    state.partial.content = buf;
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
        jw.write(detail) catch return;
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
    // pi-mono parity: cached tokens are subtracted from prompt
    // because OpenAI counts them in both buckets, and reasoning
    // tokens are added to output because some providers don't.
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

/// Map a pi-ai thinking-level string through an optional provider-specific
/// effort map. Falls through to the original string when the map is null or
/// the level has no override. (pi-mono: openai-completions.ts mapReasoningEffort)
fn mapReasoningEffort(effort: []const u8, map: ?protocol.OpenAICompletionsCompat.ReasoningEffortMap) []const u8 {
    const m = map orelse return effort;
    if (std.mem.eql(u8, effort, "minimal")) return m.minimal orelse effort;
    if (std.mem.eql(u8, effort, "low")) return m.low orelse effort;
    if (std.mem.eql(u8, effort, "medium")) return m.medium orelse effort;
    if (std.mem.eql(u8, effort, "high")) return m.high orelse effort;
    if (std.mem.eql(u8, effort, "xhigh")) return m.xhigh orelse effort;
    return effort;
}

/// Build the JSON request body for chat/completions. Writes into
/// `out`, which must be empty on entry. Mirrors pi-mono's
/// `buildParams` + `convertMessages` for the openrouter compat path.
fn buildRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
    reasoning: ?protocol.ThinkingLevel,
) !void {
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(model.id);

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("stream_options");
    try jw.beginObject();
    try jw.objectField("include_usage");
    try jw.write(true);
    try jw.endObject();

    try jw.objectField("messages");
    try jw.beginArray();
    try writeMessages(allocator, &jw, model, context);
    try jw.endArray();

    if (context.tools) |tools| {
        try jw.objectField("tools");
        try jw.beginArray();
        for (tools) |tool| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tool.name);
            try jw.objectField("description");
            try jw.write(tool.description);
            try jw.objectField("parameters");
            try jw.write(tool.parameters);
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
    }

    // reasoning_effort for reasoning models (pi-mono: openai-completions.ts:410-428)
    if (model.reasoning) {
        if (reasoning) |level| {
            const effort_str = protocol.thinkingLevelToString(level);
            if (model.compat) |compat_union| {
                switch (compat_union) {
                    .openai_completions => |compat| {
                        if (compat.thinking_format) |fmt| {
                            if (fmt == .openrouter) {
                                try jw.objectField("reasoning");
                                try jw.beginObject();
                                try jw.objectField("effort");
                                try jw.write(mapReasoningEffort(effort_str, compat.reasoning_effort_map));
                                try jw.endObject();
                            }
                        } else if (compat.supports_reasoning_effort orelse false) {
                            try jw.objectField("reasoning_effort");
                            try jw.write(mapReasoningEffort(effort_str, compat.reasoning_effort_map));
                        }
                    },
                    else => {},
                }
            }
        } else {
            // OpenRouter: no reasoning level → send effort: "none" (pi-mono:423-424)
            if (model.compat) |compat_union| {
                switch (compat_union) {
                    .openai_completions => |compat| {
                        if (compat.thinking_format) |fmt| {
                            if (fmt == .openrouter) {
                                try jw.objectField("reasoning");
                                try jw.beginObject();
                                try jw.objectField("effort");
                                try jw.write("none");
                                try jw.endObject();
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

fn writeMessages(allocator: std.mem.Allocator, jw: *std.json.Stringify, model: protocol.Model, context: protocol.Context) !void {
    if (context.system_prompt) |sys| {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("system");
        try jw.objectField("content");
        try jw.write(sys);
        try jw.endObject();
    }

    var i: usize = 0;
    while (i < context.messages.len) : (i += 1) {
        const msg = context.messages[i];
        switch (msg) {
            .user => |u| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("user");
                try jw.objectField("content");
                switch (u.content) {
                    .text => |t| try jw.write(t),
                    .blocks => |blocks| {
                        try jw.beginArray();
                        for (blocks) |b| {
                            try jw.beginObject();
                            switch (b) {
                                .text => |tc| {
                                    try jw.objectField("type");
                                    try jw.write("text");
                                    try jw.objectField("text");
                                    try jw.write(tc.text);
                                },
                                .image => |ic| {
                                    try jw.objectField("type");
                                    try jw.write("image_url");
                                    try jw.objectField("image_url");
                                    try jw.beginObject();
                                    try jw.objectField("url");
                                    const data_url = try std.fmt.allocPrint(
                                        allocator,
                                        "data:{s};base64,{s}",
                                        .{ ic.mime_type, ic.data },
                                    );
                                    defer allocator.free(data_url);
                                    try jw.write(data_url);
                                    try jw.endObject();
                                },
                            }
                            try jw.endObject();
                        }
                        try jw.endArray();
                    },
                }
                try jw.endObject();
            },
            .assistant => |a| {
                try writeAssistantMessage(allocator, jw, a);
            },
            .tool_result => |tr| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(tr.tool_call_id);
                try jw.objectField("content");
                var concat: std.ArrayListUnmanaged(u8) = .empty;
                defer concat.deinit(allocator);
                for (tr.content) |cb| {
                    switch (cb) {
                        .text => |t| try concat.appendSlice(allocator, t.text),
                        .image => {}, // skipped: phase 3a doesn't ship images-in-tool-results
                    }
                }
                if (concat.items.len == 0) {
                    try jw.write("(empty tool result)");
                } else {
                    try jw.write(concat.items);
                }
                try jw.endObject();
            },
        }
    }
    _ = model;
}

fn writeAssistantMessage(allocator: std.mem.Allocator, jw: *std.json.Stringify, a: protocol.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");

    var text_concat: std.ArrayListUnmanaged(u8) = .empty;
    defer text_concat.deinit(allocator);
    for (a.content) |b| {
        switch (b) {
            .text => |tc| if (tc.text.len > 0) try text_concat.appendSlice(allocator, tc.text),
            else => {},
        }
    }

    var has_content = false;
    if (text_concat.items.len > 0) {
        try jw.objectField("content");
        try jw.write(text_concat.items);
        has_content = true;
    }

    var tool_count: usize = 0;
    for (a.content) |b| if (b == .tool_call) {
        tool_count += 1;
    };
    if (tool_count > 0) {
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (a.content) |b| {
            if (b != .tool_call) continue;
            const tc = b.tool_call;
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(tc.id);
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tc.name);
            try jw.objectField("arguments");
            var args_buf: std.Io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            var inner = std.json.Stringify{ .writer = &args_buf.writer, .options = .{} };
            try inner.write(tc.arguments);
            try jw.write(args_buf.written());
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        has_content = true;
    }

    if (!has_content) {
        try jw.objectField("content");
        try jw.write("");
    }
    try jw.endObject();
}

fn emitError(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
    model: protocol.Model,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "openai-completions error";
    const normalized = provider_failure.formatTransportFailure(allocator, msg) catch null;
    emitFailure(callback, callback_ctx, model, if (normalized) |n| n.failure else null, msg);
}

fn emitFailure(
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
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
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } }, callback_ctx);
}

const testing = std.testing;

const TestCollector = struct {
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    final_args: std.ArrayListUnmanaged(u8) = .empty,
    final_tool_id: []const u8 = "",
    final_tool_name: []const u8 = "",
    final_error_message: ?[]const u8 = null,
    final_failure_kind: ?protocol.NormalizedFailure.Kind = null,
    final_provider_type: ?[]const u8 = null,
    allocator: std.mem.Allocator,

    const EventKind = enum { start, text_start, text_delta, text_end, toolcall_start, toolcall_delta, toolcall_end, done, err, thinking_start, thinking_delta, thinking_end };

    fn deinit(self: *TestCollector) void {
        self.events.deinit(self.allocator);
        self.text.deinit(self.allocator);
        self.final_args.deinit(self.allocator);
    }

    fn callback(evt: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *TestCollector = @ptrCast(@alignCast(ctx.?));
        switch (evt) {
            .start => self.events.append(self.allocator, .start) catch {},
            .text_start => self.events.append(self.allocator, .text_start) catch {},
            .text_delta => |d| {
                self.events.append(self.allocator, .text_delta) catch {};
                self.text.appendSlice(self.allocator, d.delta) catch {};
            },
            .text_end => self.events.append(self.allocator, .text_end) catch {},
            .toolcall_start => self.events.append(self.allocator, .toolcall_start) catch {},
            .toolcall_delta => |d| {
                self.events.append(self.allocator, .toolcall_delta) catch {};
                self.final_args.appendSlice(self.allocator, d.delta) catch {};
            },
            .toolcall_end => |e| {
                self.events.append(self.allocator, .toolcall_end) catch {};
                self.final_tool_id = e.tool_call.id;
                self.final_tool_name = e.tool_call.name;
            },
            .thinking_start => self.events.append(self.allocator, .thinking_start) catch {},
            .thinking_delta => self.events.append(self.allocator, .thinking_delta) catch {},
            .thinking_end => self.events.append(self.allocator, .thinking_end) catch {},
            .done => self.events.append(self.allocator, .done) catch {},
            .@"error" => |e| {
                self.events.append(self.allocator, .err) catch {};
                self.final_error_message = e.@"error".error_message;
                self.final_failure_kind = if (e.@"error".failure) |f| f.kind else null;
                self.final_provider_type = if (e.@"error".failure) |f| f.provider_type else null;
            },
        }
    }
};

const test_model: protocol.Model = .{
    .id = "openai/gpt-test",
    .name = "test",
    .api = .openai_completions,
    .provider = .openrouter,
    .base_url = "https://openrouter.ai/api/v1",
    .reasoning = false,
    .input = &.{.text},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 4096,
    .max_tokens = 1024,
};

fn runProcess(arena: std.mem.Allocator, sse_bytes: []const u8, collector: *TestCollector) void {
    var reader: std.Io.Reader = .fixed(sse_bytes);
    processStream(arena, &reader, test_model, AbortSignal.none, TestCollector.callback, collector);
}

test "processStream emits text_delta then done for a simple text response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expect(col.events.items.len >= 6);
    try testing.expectEqual(TestCollector.EventKind.start, col.events.items[0]);
    try testing.expectEqual(TestCollector.EventKind.text_start, col.events.items[1]);
    try testing.expectEqual(TestCollector.EventKind.text_delta, col.events.items[2]);
    try testing.expectEqual(TestCollector.EventKind.text_delta, col.events.items[3]);
    try testing.expectEqual(TestCollector.EventKind.text_end, col.events.items[col.events.items.len - 2]);
    try testing.expectEqual(TestCollector.EventKind.done, col.events.items[col.events.items.len - 1]);
    try testing.expectEqualStrings("Hello world", col.text.items);
}

test "processStream concatenates split tool-call argument chunks" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"t1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"echo hi\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    var saw_end = false;
    for (col.events.items) |e| {
        if (e == .toolcall_end) saw_end = true;
    }
    try testing.expect(saw_end);
    try testing.expectEqualStrings("t1", col.final_tool_id);
    try testing.expectEqualStrings("bash", col.final_tool_name);
    try testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", col.final_args.items);
}

test "processStream normalizes openrouter error events carried in a 200 stream" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-err\",\"error\":{\"code\":429,\"message\":\"Rate limit exceeded\",\"metadata\":{\"raw\":\"provider overload\"}}}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqual(TestCollector.EventKind.err, col.events.items[col.events.items.len - 1]);
    try testing.expectEqual(protocol.NormalizedFailure.Kind.rate_limited, col.final_failure_kind.?);
    try testing.expectEqualStrings("Rate limit exceeded\nprovider overload", col.final_error_message.?);
}

test "processStream maps network_error finish_reason to transient failure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    const sse_bytes =
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"network_error\"}]}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    try testing.expectEqual(TestCollector.EventKind.err, col.events.items[col.events.items.len - 1]);
    try testing.expectEqual(protocol.NormalizedFailure.Kind.transient, col.final_failure_kind.?);
    try testing.expectEqualStrings("Provider finish_reason: network_error", col.final_error_message.?);
}

test "buildRequestJson emits stream:true and message round-trip" {
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
    try buildRequestJson(alloc, &out, test_model, ctx, null);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "be helpful") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"openai/gpt-test\"") != null);
}
