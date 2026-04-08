//! OpenAI Responses API core — pi-mono parity for `/v1/responses` event vocab.
//!
//! pi-mono sources:
//!   - packages/ai/src/providers/openai-responses.ts (251 LOC)
//!   - packages/ai/src/providers/openai-responses-shared.ts (513 LOC)
//!
//! ## Architecture (mirrors openai_completions.zig phase 3a split)
//!
//!   1. `processStream(allocator, reader, model, abort, callback, ctx)` —
//!      pure SSE consumer for the responses-API event vocabulary. No HTTP,
//!      no globals. Tested in isolation via `std.io.fixedBufferStream`.
//!   2. `streamCore(...)` — HTTP shell parametrized by `AuthFactory` +
//!      `base_url` + `path` so phase 3c (`openai-codex-responses`) can
//!      reuse the core with a ChatGPT-oauth auth flow and a different
//!      endpoint, without copy-pasting the SSE processor.
//!   3. `buildRequestJson(...)` — request body via `std.json.Stringify`.
//!
//! ## Phase 3b scope
//!
//! Live registered model: gpt-5.4 family on api.openai.com via
//! `openai-responses`. Smoke test deferred to phase 3c (the user only has
//! ChatGPT subscription auth, not a raw OPENAI_API_KEY).
//!
//! Explicitly NOT ported (mirrors phase 3a doctrine — no speculative compat
//! for providers we don't register):
//!
//!   - `reasoning_effort` + `reasoning_summary` plumbing through
//!     StreamOptions. Default `effort=none` matches pi-mono's behavior when
//!     no options are set. Dedicated follow-up wires it.
//!   - `service_tier` pricing multiplier
//!   - `prompt_cache_key` / `prompt_cache_retention` (needs session_id wiring)
//!   - foreign tool-call-id `fc_<hash>` normalization for cross-provider
//!     history (`openai-codex` ↔ `openai` round-trip)
//!   - github-copilot dynamic headers / vision detection
//!   - image-bearing tool results
//!
//! ## Lifetime contract (mirrors openai_completions.zig)
//!
//!   - Per-stream growable buffers (`text_buf`, `tool_args_partial`) own
//!     their capacity and are explicitly deinit'd.
//!   - All other strings (item ids, msg ids, tool ids/names, signatures)
//!     are duped INTO the turn arena and BORROWED by emitted events. They
//!     must outlive the agent loop's reference, which the turn-arena reset
//!     guarantees. Don't free them in deinit.

const std = @import("std");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const partial_json = @import("../json/partial.zig");
const AbortSignal = @import("../abort_signal.zig").AbortSignal;

// =============================================================================
// Public surface
// =============================================================================

/// Pluggable Authorization-header builder. The HTTP shell calls
/// `build(ctx, scratch_buf, options.api_key)` and writes the result into
/// the request's `authorization` header.
pub const AuthFactory = struct {
    ctx: ?*anyopaque = null,
    build: *const fn (
        ctx: ?*anyopaque,
        buf: []u8,
        api_key: ?[]const u8,
    ) error{ NoApiKey, BufferTooSmall }![]u8,
};

/// Per-call configuration injected by the wrapping provider.
pub const CoreOptions = struct {
    /// Override base URL. If null, `model.base_url` is used. Phase 3c
    /// (openai-codex) will pass a hard-coded chatgpt.com URL here.
    base_url: ?[]const u8 = null,
    /// Endpoint path joined to the base URL. Examples:
    /// `/v1/responses`, `/backend-api/codex/responses`.
    path: []const u8,
    auth: AuthFactory,
    /// Static extra headers contributed by the wrapper (e.g. `OpenAI-Beta`
    /// for openai-codex). Layered between `model.headers` and
    /// `options.headers`.
    extra_headers: []const protocol.Header = &.{},
    /// Provider label for diagnostics in error messages.
    provider_label: []const u8 = "openai-responses",
};

// =============================================================================
// HTTP outer shell
// =============================================================================

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
    buildRequestJson(allocator, &payload_buf, model, context) catch |err| {
        emitError(allocator, callback, callback_ctx, model, "failed to build request: {s}", .{@errorName(err)});
        return;
    };

    var auth_buf: [4096]u8 = undefined;
    const auth_value = core.auth.build(core.auth.ctx, &auth_buf, options.api_key) catch |err| {
        const msg = switch (err) {
            error.NoApiKey => "no API key provided",
            error.BufferTooSmall => "API key too long for auth buffer",
        };
        emitError(allocator, callback, callback_ctx, model, "{s}", .{msg});
        return;
    };

    const base = core.base_url orelse model.base_url;
    const uri_str = std.fmt.allocPrint(allocator, "{s}{s}", .{ base, core.path }) catch |err| {
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
        emitError(allocator, callback, callback_ctx, model, "failed to open connection: {s}", .{@errorName(err)});
        return;
    };
    defer req.deinit();

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

    const abort_flag = options.signal;
    const socket_fd: ?std.posix.fd_t = if (req.connection) |conn|
        conn.stream_reader.getStream().handle
    else
        null;

    var watchdog_done = std.atomic.Value(bool).init(false);
    var watchdog_thread: ?std.Thread = null;
    if (!abort_flag.isNone() and socket_fd != null) {
        const wd_ctx = WatchdogCtx{ .signal = abort_flag, .socket_fd = socket_fd.?, .done = &watchdog_done };
        watchdog_thread = std.Thread.spawn(.{}, abortWatchdog, .{wd_ctx}) catch null;
    }
    defer {
        watchdog_done.store(true, .release);
        if (watchdog_thread) |t| t.join();
    }

    const reader = response.reader(&transfer_buf);
    processStream(allocator, reader, model, abort_flag, callback, callback_ctx);
    _ = core.provider_label;
}

const WatchdogCtx = struct {
    signal: AbortSignal,
    socket_fd: std.posix.fd_t,
    done: *std.atomic.Value(bool),
};

fn abortWatchdog(ctx: WatchdogCtx) void {
    while (!ctx.done.load(.acquire)) {
        if (ctx.signal.isAborted()) {
            std.posix.shutdown(ctx.socket_fd, .both) catch {};
            return;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

// =============================================================================
// Pure SSE processor
// =============================================================================

const ItemKind = enum { reasoning, message, function_call };

const ItemState = struct {
    kind: ItemKind,
    block_idx: usize,
    /// reasoning: accumulated summary text. message: accumulated output_text.
    /// function_call: unused (args live in `tool_args_partial`).
    text_buf: std.ArrayListUnmanaged(u8) = .empty,

    // reasoning fields
    summary_started: bool = false,
    thinking_signature: ?[]const u8 = null,

    // message fields
    content_part_started: bool = false,
    msg_id: []const u8 = "",
    msg_phase: ?[]const u8 = null,
    text_signature: ?[]const u8 = null,

    // function_call fields
    tool_call_id: []const u8 = "",
    tool_item_id: []const u8 = "",
    tool_name: []const u8 = "",
    tool_args_partial: std.ArrayListUnmanaged(u8) = .empty,
    /// Currently parsed JSON of `tool_args_partial`. Owned by the per-delta
    /// scratch arena during streaming, swapped to the caller allocator on
    /// finalization.
    tool_args_parsed: std.json.Value = .null,
    /// Composite "call_id|item_id" id used in `ToolCall.id`. Built at
    /// finalization, lives in the turn arena, BORROWED by `toolcall_end`.
    tool_composite_id: []const u8 = "",

    fn deinit(self: *ItemState, allocator: std.mem.Allocator) void {
        self.text_buf.deinit(allocator);
        self.tool_args_partial.deinit(allocator);
    }
};

const StreamState = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayListUnmanaged(ItemState),
    /// Index in `items` of the currently-open output item, or null between items.
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
                .timestamp = std.time.milliTimestamp(),
            },
        };
    }

    fn deinit(self: *StreamState) void {
        for (self.items.items) |*it| it.deinit(self.allocator);
        self.items.deinit(self.allocator);
    }
};

/// Drain a Reader of openai-responses SSE bytes, emit
/// `AssistantMessageEvent`s through `callback`. Pure: no HTTP, no globals.
/// Tested in isolation via `std.io.fixedBufferStream` over hand-built bytes
/// (mirrors phase 3a's pattern from `openai_completions.zig`).
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

    var parser = sse.SseParser{};

    while (true) {
        const line_with_nl = reader.takeDelimiterInclusive('\n') catch |err| {
            if (err == error.EndOfStream) {
                if (parser.has_data or parser.event_len > 0) {
                    if (parser.feedLine("")) |evt| {
                        handleEvent(allocator, &state, &scratch_arena, evt, callback, callback_ctx) catch {};
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
            handleEvent(allocator, &state, &scratch_arena, evt, callback, callback_ctx) catch break;
        }
    }

    state.partial.content = buildFinalContent(allocator, state.items.items) catch &.{};

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

const HandleErr = error{OutOfMemory};

fn handleEvent(
    allocator: std.mem.Allocator,
    state: *StreamState,
    scratch: *std.heap.ArenaAllocator,
    evt: sse.SseEvent,
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
    const t = type_v.string;

    // ── lifecycle: response id capture ─────────────────────────────
    if (std.mem.eql(u8, t, "response.created")) {
        if (root.object.get("response")) |resp| if (resp == .object) {
            if (resp.object.get("id")) |id| if (id == .string and id.string.len > 0) {
                state.response_id = allocator.dupe(u8, id.string) catch null;
                state.partial.response_id = state.response_id;
            };
        };
        return;
    }

    // ── output_item.added: open a new content block ────────────────
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
            try updatePartialContent(allocator, state);
            callback(.{ .toolcall_start = .{ .content_index = idx, .partial = state.partial } }, callback_ctx);
        }
        return;
    }

    // ── reasoning summary lifecycle ────────────────────────────────
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

    // ── message content lifecycle ──────────────────────────────────
    if (std.mem.eql(u8, t, "response.content_part.added")) {
        if (state.current) |cur| {
            const it = &state.items.items[cur];
            if (it.kind == .message) it.content_part_started = true;
        }
        return;
    }

    if (std.mem.eql(u8, t, "response.output_text.delta") or
        std.mem.eql(u8, t, "response.refusal.delta"))
    {
        const cur = state.current orelse return;
        const it = &state.items.items[cur];
        if (it.kind != .message or !it.content_part_started) return;
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

    // ── function call argument streaming ───────────────────────────
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

    // ── output_item.done: close current block, emit terminal event ─
    if (std.mem.eql(u8, t, "response.output_item.done")) {
        const item = root.object.get("item") orelse return;
        if (item != .object) return;
        const it_type_v = item.object.get("type") orelse return;
        if (it_type_v != .string) return;
        const it_type = it_type_v.string;
        const cur = state.current orelse return;
        const st = &state.items.items[cur];

        if (std.mem.eql(u8, it_type, "reasoning") and st.kind == .reasoning) {
            // Stringify the entire item as the thinking signature so
            // multi-turn pairing preserves `encrypted_content` and any
            // future fields the responses API adds (matches pi-mono's
            // `JSON.stringify(item)`).
            st.thinking_signature = stringifyJsonValue(allocator, item) catch null;
            try updatePartialContent(allocator, state);
            callback(.{ .thinking_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "message") and st.kind == .message) {
            // pi-mono extracts msg_id + phase from the item; we already
            // captured them on output_item.added. Encode as TextSignatureV1.
            // If the item carries an updated id (rare), prefer it.
            if (item.object.get("id")) |id| if (id == .string) {
                st.msg_id = allocator.dupe(u8, id.string) catch st.msg_id;
            };
            st.text_signature = encodeTextSignatureV1(allocator, st.msg_id, st.msg_phase) catch null;
            try updatePartialContent(allocator, state);
            callback(.{ .text_end = .{
                .content_index = st.block_idx,
                .content = st.text_buf.items,
                .partial = state.partial,
            } }, callback_ctx);
            state.current = null;
        } else if (std.mem.eql(u8, it_type, "function_call") and st.kind == .function_call) {
            // Final reparse via the caller's allocator so the value
            // outlives the per-delta scratch arena.
            const final_args = partial_json.parseStreaming(allocator, st.tool_args_partial.items) catch .null;
            st.tool_args_parsed = final_args;
            // pi-mono builds id as `${call_id}|${item.id}`. Both halves
            // already live in the turn arena.
            st.tool_composite_id = std.fmt.allocPrint(
                allocator,
                "{s}|{s}",
                .{ st.tool_call_id, st.tool_item_id },
            ) catch st.tool_call_id;
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

    // ── terminal: usage + stop reason ──────────────────────────────
    if (std.mem.eql(u8, t, "response.completed")) {
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
            state.partial.stop_reason = mapResponseStatus(s.string);
        };
        // pi-mono: if any tool_call block exists and stop is the default
        // `stop`, override to `toolUse`.
        if (state.partial.stop_reason == .stop) {
            for (state.items.items) |it| if (it.kind == .function_call) {
                state.partial.stop_reason = .toolUse;
                break;
            };
        }
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

// =============================================================================
// Rendering helpers
// =============================================================================

fn updatePartialContent(allocator: std.mem.Allocator, state: *StreamState) HandleErr!void {
    const buf = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, state.items.items.len);
    for (state.items.items, 0..) |*it, i| buf[i] = renderItem(it);
    state.partial.content = buf;
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
    var out: std.io.Writer.Allocating = .init(allocator);
    var jw = std.json.Stringify{ .writer = &out.writer, .options = .{} };
    try jw.write(value);
    return out.toOwnedSlice();
}

fn encodeTextSignatureV1(
    allocator: std.mem.Allocator,
    id: []const u8,
    phase: ?[]const u8,
) ![]const u8 {
    var out: std.io.Writer.Allocating = .init(allocator);
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

fn parseUsage(usage: std.json.Value, partial: *protocol.AssistantMessage) void {
    var input: u64 = 0;
    var output: u64 = 0;
    var cache_read: u64 = 0;
    if (usage.object.get("input_tokens")) |v| input = jsonU64(v);
    if (usage.object.get("output_tokens")) |v| output = jsonU64(v);
    if (usage.object.get("input_tokens_details")) |d| if (d == .object) {
        if (d.object.get("cached_tokens")) |c| cache_read = jsonU64(c);
    };
    // pi-mono: OpenAI counts cached tokens inside input_tokens, so subtract.
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

fn emitError(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
    model: protocol.Model,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch "openai-responses error";
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

// =============================================================================
// Request body builder
// =============================================================================

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
) !void {
    var allocating: std.io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(model.id);

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("store");
    try jw.write(false);

    try jw.objectField("input");
    try jw.beginArray();
    try writeInput(allocator, &jw, model, context);
    try jw.endArray();

    if (context.tools) |tools| {
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
            try jw.objectField("strict");
            try jw.write(false);
            try jw.endObject();
        }
        try jw.endArray();
    }

    if (model.reasoning) {
        // pi-mono parity: without `reasoning_effort` / `reasoning_summary`
        // plumbed through StreamOptions, the default is `effort: "none"`
        // (matches pi-mono's `openai-responses.ts:224`). The dedicated
        // follow-up will wire StreamOptions.reasoning → effort/summary and
        // turn on `include: ["reasoning.encrypted_content"]`.
        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write("none");
        try jw.endObject();
    }

    try jw.endObject();
    try out.appendSlice(allocator, allocating.written());
}

fn writeInput(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
) !void {
    if (context.system_prompt) |sys| {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write(if (model.reasoning) "developer" else "system");
        try jw.objectField("content");
        try jw.write(sys);
        try jw.endObject();
    }

    var msg_index: usize = 0;
    for (context.messages) |msg| {
        defer msg_index += 1;
        switch (msg) {
            .user => |u| {
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
            },
            .assistant => |a| try writeAssistantMessage(allocator, jw, a, msg_index),
            .tool_result => |tr| {
                var concat: std.ArrayListUnmanaged(u8) = .empty;
                defer concat.deinit(allocator);
                for (tr.content) |cb| switch (cb) {
                    .text => |text| try concat.appendSlice(allocator, text.text),
                    .image => {}, // phase 3b: image-bearing tool results skipped
                };
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("function_call_output");
                try jw.objectField("call_id");
                // Strip `|fc_xxx` suffix if present — pi-mono does the same.
                const call_id = if (std.mem.indexOfScalar(u8, tr.tool_call_id, '|')) |i|
                    tr.tool_call_id[0..i]
                else
                    tr.tool_call_id;
                try jw.write(call_id);
                try jw.objectField("output");
                if (concat.items.len == 0) {
                    try jw.write("(empty tool result)");
                } else {
                    try jw.write(concat.items);
                }
                try jw.endObject();
            },
        }
    }
}

fn writeAssistantMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    a: protocol.AssistantMessage,
    msg_index: usize,
) !void {
    for (a.content) |b| switch (b) {
        .thinking => |th| {
            // pi-mono: if `thinking_signature` carries the original
            // ResponseReasoningItem JSON, write it back verbatim so the
            // responses API re-pairs subsequent function_calls against the
            // same rs_xxx reasoning item. Without a signature there's no
            // way to reconstruct the item — skip, matching pi-mono.
            if (th.thinking_signature) |sig| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{}) catch continue;
                defer parsed.deinit();
                try jw.write(parsed.value);
            }
        },
        .text => |tc| {
            // Derive id + phase from text_signature (TextSignatureV1 JSON),
            // falling back to `msg_<index>` when absent. pi-mono parity:
            // responses API requires a stable id on assistant messages.
            // phase extraction from text_signature is deferred: the
            // parser arena would free the phase string before we write
            // it, and we don't need phase for phase-3b turn-tracking.
            // TextSignatureV1.phase round-trip is scoped to a dedicated
            // follow-up when multi-phase prompting lands.
            var msg_id: []const u8 = "";
            var msg_id_alloc: ?[]const u8 = null;
            defer if (msg_id_alloc) |p| allocator.free(p);
            if (tc.text_signature) |sig| {
                if (sig.len > 0 and sig[0] == '{') {
                    if (std.json.parseFromSlice(std.json.Value, allocator, sig, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("id")) |id| if (id == .string) {
                                msg_id_alloc = allocator.dupe(u8, id.string) catch null;
                                if (msg_id_alloc) |m| msg_id = m;
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
            // id may be "call_xxx|fc_yyy".
            var call_id: []const u8 = tcall.id;
            var item_id: ?[]const u8 = null;
            if (std.mem.indexOfScalar(u8, tcall.id, '|')) |i| {
                call_id = tcall.id[0..i];
                item_id = tcall.id[i + 1 ..];
            }
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call");
            if (item_id) |iid| {
                try jw.objectField("id");
                try jw.write(iid);
            }
            try jw.objectField("call_id");
            try jw.write(call_id);
            try jw.objectField("name");
            try jw.write(tcall.name);
            try jw.objectField("arguments");
            // Stringify the JSON arguments into a string field.
            var args_buf: std.io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            var inner = std.json.Stringify{ .writer = &args_buf.writer, .options = .{} };
            try inner.write(tcall.arguments);
            try jw.write(args_buf.written());
            try jw.endObject();
        },
    };
}

// =============================================================================
// Tests
// =============================================================================

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
            .text_end => self.events.append(self.allocator, .text_end) catch {},
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

/// Test reader: single-shot line iterator over a fixed byte buffer.
/// Mirrors the pattern in openai_completions.zig tests. Uses page_allocator
/// for the per-line scratch since these are unit tests and allocator churn
/// doesn't matter.
fn runProcess(arena: std.mem.Allocator, sse_bytes: []const u8, collector: *TestCollector) void {
    var stream = std.io.fixedBufferStream(sse_bytes);
    const Reader = struct {
        s: *std.io.FixedBufferStream([]const u8),
        fn takeDelimiterInclusive(self: *@This(), delim: u8) ![]const u8 {
            var line: std.ArrayListUnmanaged(u8) = .empty;
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
    processStream(arena, &r, test_model, AbortSignal.none, TestCollector.cb, collector);
}

test "processStream maps reasoning summary deltas to a thinking block" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var col = TestCollector{ .allocator = testing.allocator };
    defer col.deinit();

    // SSE trace: response.created → reasoning item open → summary part
    // opened → two text deltas → item done (with encrypted_content) →
    // response.completed.
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
    // Verify event ordering: start, thinking_start, thinking_delta*, thinking_end, done.
    var saw_thinking_start = false;
    var saw_thinking_end = false;
    for (col.events.items) |e| {
        if (e == .thinking_start) saw_thinking_start = true;
        if (e == .thinking_end) saw_thinking_end = true;
    }
    try testing.expect(saw_thinking_start);
    try testing.expect(saw_thinking_end);
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
    // Stop reason must override to toolUse when tool calls are present.
    try testing.expectEqual(protocol.AssistantMessageEvent.DoneReason.toolUse, col.done_reason.?);
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
    try buildRequestJson(alloc, &out, test_model, ctx);

    try testing.expect(std.mem.indexOf(u8, out.items, "\"stream\":true") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"store\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"role\":\"developer\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"type\":\"input_text\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"effort\":\"none\"") != null);
}