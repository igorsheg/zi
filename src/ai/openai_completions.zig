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
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const json_util = @import("json_util.zig");
const partial_json = @import("../json/partial.zig");
const json_value = @import("../json/value.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const AbortGuard = @import("../abort_guard.zig").AbortGuard;
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
        self.streamImpl(allocator, model, context, options.base, protocol.clampReasoning(options.reasoning, model), callback, callback_ctx);    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "openai-completions";
    }

    fn deinitImpl(_: *anyopaque) void {}

    // ── HTTP outer shell ─────────────────────────────────────────

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

        // Build payload.
        var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_buf.deinit(allocator);
        buildRequestJson(allocator, &payload_buf, model, context, reasoning) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to build request: {s}", .{@errorName(err)});
            return;
        };

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

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Bearer token in Authorization header. Stack buffer for
        // formatting; api keys are well under 4KB.
        var auth_buf: [4096]u8 = undefined;
        const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch {
            emitError(allocator, callback, callback_ctx, model, "API key too long for auth buffer", .{});
            return;
        };

        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;
        extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
        n_extra += 1;

        // Caller-supplied extra headers (per-request) win over none;
        // model.headers (catalog default) gets layered first.
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

        var abort_guard = AbortGuard.start(options.signal, .{
            .shutdown_fd = if (req.connection) |conn| conn.stream_reader.getStream().handle else null,
        });
        defer abort_guard.stop();

        const body_copy = allocator.dupe(u8, payload_buf.items) catch |err| {
            emitError(allocator, callback, callback_ctx, model, "failed to allocate body: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(body_copy);

        req.sendBodyComplete(body_copy) catch |err| {
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
                const data = reader.take(err_body_buf.len - n_read) catch break;
                if (data.len == 0) break;
                @memcpy(err_body_buf[n_read..][0..data.len], data);
                n_read += data.len;
            }
            emitError(allocator, callback, callback_ctx, model, "HTTP {d}: {s}", .{ @intFromEnum(status), err_body_buf[0..n_read] });
            return;
        }


        const reader = response.reader(&transfer_buf);
        processStream(allocator, reader, model, options.signal, callback, callback_ctx);
    }
};

// ── pure SSE processor ──────────────────────────────────────────────

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
    // Per-stream scratch arena for partial-JSON reparses on every
    // tool-call delta. Reset between deltas to keep peak usage flat.
    var scratch_arena = std.heap.ArenaAllocator.init(allocator);
    defer scratch_arena.deinit();

    var state = StreamState.init(allocator, model);
    defer state.deinit();

    callback(.{ .start = .{ .partial = state.partial } }, callback_ctx);

    var parser = sse.SseParser{};

    while (true) {
        // Catch *any* error from the reader. EndOfStream is the
        // normal terminator; anything else is either an abort
        // (socket shut down by the watchdog) or a transport fault.
        // Using a single catch keeps this generic over both the
        // http reader (many error variants) and the test reader
        // (only `EndOfStream`).
        const line_with_nl = reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) {
                if (parser.has_data or parser.event_len > 0) {
                    if (parser.feedLine("")) |evt| {
                        handleSseEvent(allocator, &state, &scratch_arena, evt, callback, callback_ctx) catch break;
                    }
                }
                break;
            }
            if (abort_flag.isAborted()) {
                state.partial.stop_reason = .aborted;
                break;
            }
            emitError(allocator, callback, callback_ctx, model, "stream read error: {s}", .{@errorName(err)});
            return;
        };
        var line = line_with_nl;
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (parser.feedLine(line)) |evt| {
            handleSseEvent(allocator, &state, &scratch_arena, evt, callback, callback_ctx) catch break;
        }
    }

    // Finalize any open block, materialize content into the partial
    // message, emit terminal event.
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

// ── stream state ────────────────────────────────────────────────────

const BlockKind = enum { text, thinking, tool_call };

const ContentBlockState = struct {
    kind: BlockKind,
    /// For text/thinking: accumulated chars. For tool_call: empty
    /// (the partial JSON lives in `tool_args_partial`).
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

    // tool_call only
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
                .timestamp = std.time.milliTimestamp(),
            },
        };
    }

    fn deinit(self: *StreamState) void {
        for (self.content_blocks.items) |*b| b.deinit(self.allocator);
        self.content_blocks.deinit(self.allocator);
        if (self.response_id) |rid| self.allocator.free(rid);
    }
};

// ── SSE event handler ───────────────────────────────────────────────

const HandleErr = error{OutOfMemory};

fn handleSseEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    evt: sse.SseEvent,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) HandleErr!void {
    // OpenAI uses `data: [DONE]` as a terminator with no event type.
    if (std.mem.eql(u8, evt.data, "[DONE]")) return;

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, evt.data, .{}) catch return;
    defer parsed.deinit();
    const root = parsed.value;
    if (root != .object) return;

    // Capture response id from chunk.id (every chunk carries the
    // same id; we set on first non-empty).
    if (state.response_id == null) {
        if (root.object.get("id")) |id_val| {
            if (id_val == .string and id_val.string.len > 0) {
                state.response_id = allocator.dupe(u8, id_val.string) catch null;
                state.partial.response_id = state.response_id;
            }
        }
    }

    // Top-level usage (preferred location).
    if (root.object.get("usage")) |usage_val| {
        if (usage_val == .object) parseUsage(usage_val, &state.partial);
    }

    const choices_val = root.object.get("choices") orelse return;
    if (choices_val != .array or choices_val.array.items.len == 0) return;
    const choice = choices_val.array.items[0];
    if (choice != .object) return;

    // Some providers (Moonshot) put usage on choice.usage.
    if (state.partial.usage.input == 0 and state.partial.usage.output == 0) {
        if (choice.object.get("usage")) |cu| {
            if (cu == .object) parseUsage(cu, &state.partial);
        }
    }

    // finish_reason → stop_reason. Set as we see it; the terminal
    // event happens after the loop.
    if (choice.object.get("finish_reason")) |fr| {
        if (fr == .string) {
            state.partial.stop_reason = mapFinishReason(fr.string);
        }
    }

    const delta = choice.object.get("delta") orelse return;
    if (delta != .object) return;

    // 1. text content.
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

    // 2. reasoning content. pi-mono walks `reasoning_content`,
    //    `reasoning`, `reasoning_text` and uses the first non-empty.
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

    // 3. tool_calls. Each entry has an optional `id`, `function.name`,
    //    `function.arguments`. Arguments come as concatenated string
    //    chunks; we accumulate then re-parse on each delta so the
    //    partial message reflects in-progress tool call args.
    if (delta.object.get("tool_calls")) |tcs_val| {
        if (tcs_val == .array) {
            for (tcs_val.array.items) |tc| {
                if (tc != .object) continue;
                try handleToolCallDelta(allocator, state, scratch, tc, callback, callback_ctx);
            }
        }
    }

    // 4. reasoning_details (openrouter encrypted thought sigs for
    //    a specific tool call id). Attach the JSON-stringified detail
    //    to the matching tool_call's thought_signature.
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

    // Decide whether this delta belongs to the current block or
    // starts a new one. New tool call when:
    //  - no current block, or
    //  - current block is not a tool_call, or
    //  - delta carries an id that differs from current.
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
                    // Re-parse the partial json into the scratch
                    // arena. parseStreaming returns `{}` on
                    // unparseable input which is fine — that's the
                    // pi-mono semantics for an in-flight tool call.
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
            // Final reparse via the caller's allocator so the value
            // outlives the per-delta scratch arena.
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
        // Stringify the detail object via std.json.Stringify.
        var out: std.io.Writer.Allocating = .init(allocator);
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
    // Cost is left zero in phase 3a; the agent loop computes it
    // separately via models.calculateCost when it cares.
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

// ── payload builder ─────────────────────────────────────────────────

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
    var allocating: std.io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
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
    try writeMessages(&jw, model, context);
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

    try out.appendSlice(allocator, allocating.written());
}

fn writeMessages(jw: *std.json.Stringify, model: protocol.Model, context: protocol.Context) !void {
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
                                    // data:<mime>;base64,<data> — assembled
                                    // on the page allocator, freed before
                                    // the field closes.
                                    const data_url = try std.fmt.allocPrint(
                                        std.heap.page_allocator,
                                        "data:{s};base64,{s}",
                                        .{ ic.mime_type, ic.data },
                                    );
                                    defer std.heap.page_allocator.free(data_url);
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
                try writeAssistantMessage(jw, a);
            },
            .tool_result => |tr| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(tr.tool_call_id);
                try jw.objectField("content");
                // Concatenate text content blocks.
                var concat: std.ArrayListUnmanaged(u8) = .empty;
                defer concat.deinit(std.heap.page_allocator);
                for (tr.content) |cb| {
                    switch (cb) {
                        .text => |t| try concat.appendSlice(std.heap.page_allocator, t.text),
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

fn writeAssistantMessage(jw: *std.json.Stringify, a: protocol.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");

    // Concatenate non-empty text blocks. pi-mono uses
    // join("") which is just byte concatenation.
    var text_concat: std.ArrayListUnmanaged(u8) = .empty;
    defer text_concat.deinit(std.heap.page_allocator);
    for (a.content) |b| {
        switch (b) {
            .text => |tc| if (tc.text.len > 0) try text_concat.appendSlice(std.heap.page_allocator, tc.text),
            else => {},
        }
    }

    var has_content = false;
    if (text_concat.items.len > 0) {
        try jw.objectField("content");
        try jw.write(text_concat.items);
        has_content = true;
    }

    // Tool calls.
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
            // Stringify the JSON value as a string field.
            var args_buf: std.io.Writer.Allocating = .init(std.heap.page_allocator);
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
        // Empty assistant — emit content: "" so the API doesn't reject.
        try jw.objectField("content");
        try jw.write("");
    }
    try jw.endObject();
}

// ── error helper ────────────────────────────────────────────────────

fn emitError(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
    model: protocol.Model,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "openai-completions error";
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
        .timestamp = std.time.milliTimestamp(),
    };
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = err_msg } }, callback_ctx);
}


// ── tests ───────────────────────────────────────────────────────────

const testing = std.testing;

const TestCollector = struct {
    events: std.ArrayListUnmanaged(EventKind) = .empty,
    text: std.ArrayListUnmanaged(u8) = .empty,
    final_args: std.ArrayListUnmanaged(u8) = .empty,
    final_tool_id: []const u8 = "",
    final_tool_name: []const u8 = "",
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
            .@"error" => self.events.append(self.allocator, .err) catch {},
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
    var stream = std.io.fixedBufferStream(sse_bytes);
    const Reader = struct {
        s: *std.io.FixedBufferStream([]const u8),
        fn takeDelimiterInclusive(self: *@This(), delim: u8) ![]const u8 {
            var line: std.ArrayListUnmanaged(u8) = .empty;
            // Single-shot reader that returns one line including \n,
            // or error.EndOfStream when out of data. We don't need
            // efficient buffering for tests.
            while (true) {
                var byte: [1]u8 = undefined;
                const n = self.s.read(&byte) catch return error.EndOfStream;
                if (n == 0) {
                    if (line.items.len == 0) return error.EndOfStream;
                    return line.toOwnedSlice(std.heap.page_allocator) catch return error.EndOfStream;
                }
                line.append(std.heap.page_allocator, byte[0]) catch return error.EndOfStream;
                if (byte[0] == delim) {
                    return line.toOwnedSlice(std.heap.page_allocator) catch return error.EndOfStream;
                }
            }
        }
    };
    var r = Reader{ .s = &stream };
    processStream(arena, &r, test_model, AbortSignal.none, TestCollector.callback, collector);
}

test "processStream emits text_delta then done for a simple text response" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    // Synthetic SSE following pi-mono's openai-codex-stream test pattern.
    const sse_bytes =
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\"Hello\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{\"content\":\" world\"}}]}\n\n" ++
        "data: {\"id\":\"chat-1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\n" ++
        "data: {\"usage\":{\"prompt_tokens\":5,\"completion_tokens\":2}}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    // Required event ordering: start, text_start, text_delta, text_delta, text_end, done.
    try testing.expect(col.events.items.len >= 6);
    try testing.expectEqual(TestCollector.EventKind.start, col.events.items[0]);
    try testing.expectEqual(TestCollector.EventKind.text_start, col.events.items[1]);
    try testing.expectEqual(TestCollector.EventKind.text_delta, col.events.items[2]);
    try testing.expectEqual(TestCollector.EventKind.text_delta, col.events.items[3]);
    // text_end comes from the finalize-on-stream-end path
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

    // Tool call streaming: id arrives once, then arguments split across
    // three chunks. Final finish_reason: tool_calls.
    const sse_bytes =
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"id\":\"t1\",\"function\":{\"name\":\"bash\",\"arguments\":\"{\\\"cmd\\\":\\\"\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"echo hi\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{\"tool_calls\":[{\"function\":{\"arguments\":\"\\\"}\"}}]}}]}\n\n" ++
        "data: {\"id\":\"c1\",\"choices\":[{\"delta\":{},\"finish_reason\":\"tool_calls\"}]}\n\n" ++
        "data: [DONE]\n\n";

    runProcess(alloc, sse_bytes, &col);

    // Find toolcall_end event
    var saw_end = false;
    for (col.events.items) |e| {
        if (e == .toolcall_end) saw_end = true;
    }
    try testing.expect(saw_end);
    try testing.expectEqualStrings("t1", col.final_tool_id);
    try testing.expectEqualStrings("bash", col.final_tool_name);
    // Concatenated arguments delta should be the full json string.
    try testing.expectEqualStrings("{\"cmd\":\"echo hi\"}", col.final_args.items);
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
    try buildRequestJson(alloc, &out, test_model, ctx);

    // Spot-check key fields. Full schema validation lives in the
    // smoke test against a real openrouter response.
    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"system\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"user\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "be helpful") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"openai/gpt-test\"") != null);
}
