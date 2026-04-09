const AbortSignal = @import("../abort_signal.zig").AbortSignal;
const std = @import("std");
const protocol = @import("protocol.zig");
const sse = @import("sse.zig");
const ai_provider = @import("provider.zig");
const json_util = @import("json_util.zig");
const partial_json = @import("../json/partial.zig");
const json_value = @import("../json/value.zig");

/// Anthropic Messages API provider implementation.
/// Streams to `{model.base_url}/v1/messages` with SSE parsing.
pub const AnthropicProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnthropicProvider {
        return .{ .allocator = allocator };
    }

    /// Returns a vtable-wrapped Provider interface.
    pub fn provider(self: *AnthropicProvider) ai_provider.Provider {
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

    // =================================================================
    // VTable implementations
    // =================================================================

    fn streamImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options, null, null, callback, callback_ctx);
    }

    fn streamSimpleImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.SimpleStreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options.base, protocol.clampReasoning(options.reasoning, model), options.thinking_budgets, callback, callback_ctx);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn deinitImpl(_: *anyopaque) void {}

    // =================================================================
    // Main streaming implementation
    // =================================================================

    fn streamImpl(self: *AnthropicProvider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, reasoning: ?protocol.ThinkingLevel, thinking_budgets: ?protocol.ThinkingBudgets, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        _ = self;

        // Build request payload
        var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_buf.deinit(allocator);

        const is_oauth_token = if (options.api_key) |k| std.mem.indexOf(u8, k, "sk-ant-oat") != null else false;
        buildRequestJson(allocator, &payload_buf, model, context, options, is_oauth_token, reasoning, thinking_budgets) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to build request: {s}", .{@errorName(err)});
            return;
        };

        const api_key = options.api_key orelse {
            emitError(allocator, callback, callback_ctx, "no API key provided", .{});
            return;
        };

        const uri_str = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{model.base_url}) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to build URI: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to parse URI: {s}", .{@errorName(err)});
            return;
        };

        // Setup HTTP client
        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Build extra headers
        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;

        extra_headers_buf[n_extra] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        n_extra += 1;


        // OAuth tokens (sk-ant-oat*) use Bearer auth + claude-code identity headers.
        // API keys use x-api-key header.
        const is_oauth = std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;

        // Stack buffer for Bearer auth header value
        var auth_buf: [4096]u8 = undefined;
        if (is_oauth) {
            const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch {
                emitError(allocator, callback, callback_ctx, "API key too long for auth buffer", .{});
                return;
            };
            extra_headers_buf[n_extra] = .{ .name = "authorization", .value = auth_value };
            n_extra += 1;
            extra_headers_buf[n_extra] = .{ .name = "anthropic-beta", .value = "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14" };
            n_extra += 1;
            extra_headers_buf[n_extra] = .{ .name = "anthropic-dangerous-direct-browser-access", .value = "true" };
            n_extra += 1;
            extra_headers_buf[n_extra] = .{ .name = "user-agent", .value = "claude-cli/2.1.75" };
            n_extra += 1;
            extra_headers_buf[n_extra] = .{ .name = "x-app", .value = "cli" };
            n_extra += 1;
        } else {
            extra_headers_buf[n_extra] = .{ .name = "x-api-key", .value = api_key };
            n_extra += 1;
            // Match pi-mono: API-key auth also enables fine-grained
            // tool streaming so the model can emit tool inputs in
            // arbitrary partial chunks instead of being constrained
            // to JSON sub-tree boundaries. Without this header,
            // Anthropic falls back to stricter streaming and the
            // streaming behavior diverges from what pi-mono ships.
            extra_headers_buf[n_extra] = .{ .name = "anthropic-beta", .value = "fine-grained-tool-streaming-2025-05-14" };
            n_extra += 1;
        }

        if (options.headers) |custom_headers| {
            for (custom_headers) |h| {
                if (n_extra < extra_headers_buf.len) {
                    extra_headers_buf[n_extra] = .{ .name = h.key, .value = h.value };
                    n_extra += 1;
                }
            }
        }

        // Send request (zig 0.15 API) — disable compression so SSE arrives as plaintext
        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers_buf[0..n_extra],
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to open connection: {s}", .{@errorName(err)});
            return;
        };
        defer req.deinit();

        // sendBodyComplete needs mutable slice
        const body_copy = allocator.dupe(u8, payload_buf.items) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to allocate body: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(body_copy);

        req.sendBodyComplete(body_copy) catch |err| {
            emitError(allocator, callback, callback_ctx, "failed to send body: {s}", .{@errorName(err)});
            return;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            emitError(allocator, callback, callback_ctx, "request failed: {s}", .{@errorName(err)});
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
            emitError(allocator, callback, callback_ctx, "HTTP {d}: {s}", .{ @intFromEnum(status), err_body_buf[0..n_read] });
            return;
        }

        // Parse SSE stream line by line
        var parser = sse.SseParser{};
        var reader = response.reader(&transfer_buf);

        // Per-delta scratch arena for partial-JSON reparses.
        // See StreamState.scratch for rationale.
        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();

        // Streaming state
        var state = StreamState{
            .allocator = allocator,
            .scratch = &scratch_arena,
            .content_blocks = .{},
            .partial = protocol.AssistantMessage{
                .content = &.{},
                .api = .anthropic_messages,
                .provider = .anthropic,
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
            .stop_reason = null,
        };
        defer {
            for (state.content_blocks.items) |*block| {
                block.deinit(allocator);
            }
            state.content_blocks.deinit(allocator);
        }

        // Abort: the signal is a typed AbortSignal. When set, we need to break
        // out of the blocking read. Since zig's chunked HTTP parser is NOT
        // retry-safe (SO_RCVTIMEO corrupts parser state), we close the
        // socket from a watchdog thread. This causes the blocking read to
        // fail with an error, which we catch and classify as aborted.
        const abort_flag = options.signal;
        const socket_fd: ?std.posix.fd_t = if (req.connection) |conn|
            conn.stream_reader.getStream().handle
        else
            null;

        // Spawn abort watchdog: polls the abort flag every 100ms,
        // shuts down the socket when abort is requested.
        var watchdog_done = std.atomic.Value(bool).init(false);
        var watchdog_thread: ?std.Thread = null;
        if (!abort_flag.isNone() and socket_fd != null) {
            const wd_ctx = WatchdogCtx{ .signal = abort_flag, .socket_fd = socket_fd.?, .done = &watchdog_done };
            watchdog_thread = std.Thread.spawn(.{}, abortWatchdog, .{wd_ctx}) catch null;
        }
        defer {
            // Signal watchdog to exit and wait for it BEFORE req.deinit()
            // closes the socket fd.
            watchdog_done.store(true, .release);
            if (watchdog_thread) |t| t.join();
        }

        // Emit start event
        callback(.{ .start = .{ .partial = state.partial } }, callback_ctx);

        // Process SSE events line by line.

        while (true) {
            const line_with_nl = reader.takeDelimiterInclusive('\n') catch |err| switch (err) {
                error.EndOfStream => {
                    if (parser.has_data or parser.event_len > 0) {
                        if (parser.feedLine("")) |evt| {
                            handleSseEvent(evt, &state, callback, callback_ctx);
                        }
                    }
                    break;
                },
                else => {
                    // Check if this was caused by abort
                    if (abort_flag.isAborted()) {
                        state.partial.stop_reason = .aborted;
                        break;
                    }                    emitError(allocator, callback, callback_ctx, "stream read error: {s}", .{@errorName(err)});
                    return;
                },
            };

            // Strip trailing \n and \r
            var line = line_with_nl;
            if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (parser.feedLine(line)) |evt| {
                handleSseEvent(evt, &state, callback, callback_ctx);
            }
        }

        // Build final content blocks from accumulated streaming state.
        // Allocations go through the caller's allocator (arena) so they survive
        // after this function returns.
        state.partial.content = buildFinalContent(allocator, state.content_blocks.items) catch &.{};

        // Emit final done event
        if (state.partial.stop_reason == .aborted) {
            callback(.{ .done = .{ .reason = .stop, .message = state.partial } }, callback_ctx);
        } else if (state.stop_reason) |sr| {
            const done_reason: protocol.AssistantMessageEvent.DoneReason = switch (sr) {
                .end_turn => .stop,
                .max_tokens => .length,
                .tool_use => .toolUse,
                else => .stop,
            };
            state.partial.stop_reason = switch (sr) {
                .end_turn => .stop,
                .max_tokens => .length,
                .tool_use => .toolUse,
                else => .stop,
            };
            callback(.{ .done = .{ .reason = done_reason, .message = state.partial } }, callback_ctx);
        } else {
            callback(.{ .done = .{ .reason = .stop, .message = state.partial } }, callback_ctx);
        }
    }
};

// =================================================================
// Streaming state
// =================================================================

const ContentBlockState = struct {
    block_type: BlockType,
    index: usize,
    text: std.ArrayListUnmanaged(u8),
    thinking: std.ArrayListUnmanaged(u8),
    tool_call: ?protocol.ToolCall,

    const BlockType = enum { text, thinking, tool_call };

    fn init(block_type: BlockType, index: usize) ContentBlockState {
        return .{
            .block_type = block_type,
            .index = index,
            .text = .empty,
            .thinking = .empty,
            .tool_call = null,
        };
    }

    fn deinit(self: *ContentBlockState, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.thinking.deinit(allocator);
    }
};

const StreamState = struct {
    /// Turn arena: lives for the full stream. All durable allocations
    /// (content block buffers, cloned tool-call args, partial.content
    /// slices) go here. Caller owns and resets it between turns.
    allocator: std.mem.Allocator,
    /// Per-delta scratch arena, reset with `retain_capacity` before
    /// every partial-JSON reparse. Bounds memory growth during tool
    /// argument streaming: the old std.json.Value tree is dropped on
    /// reset instead of accumulating in the turn arena. Lives for
    /// the same lifetime as `allocator`; backed by the turn arena's
    /// underlying allocator.
    scratch: *std.heap.ArenaAllocator,
    content_blocks: std.ArrayListUnmanaged(ContentBlockState),
    partial: protocol.AssistantMessage,
    stop_reason: ?StopReason,
};

const StopReason = enum {
    end_turn,
    max_tokens,
    tool_use,
    stop_sequence,
    sensitive,
};

// =================================================================
// SSE event handling
// =================================================================

/// Handle a single Anthropic SSE event. The `data` payload is parsed
/// once via `std.json.parseFromSliceLeaky` into `state.scratch` and
/// walked structurally with the typed accessors in `json.value`.
///
/// Lifetime contract:
///   - `state.scratch` is reset before parse, so any prior tree
///     (including the previous tool-arg parse from `parseToolArgs`)
///     is dropped here. This is safe because everything we needed
///     from the previous event was either copied into the turn arena
///     (block buffers, cloned tc.arguments) or already consumed by
///     the callback.
///   - String/object fields read from the parsed value are slices
///     into scratch memory. Anything that must survive past this
///     function (or past a subsequent `state.scratch.reset` inside
///     `parseToolArgs`) MUST be copied into `state.allocator` (the
///     turn arena) before that point. We copy via `appendSlice` /
///     `dupe`, never store raw scratch slices.
///
/// Errors during parse or shape mismatch are silently dropped — SSE
/// is best-effort and the next event will reset and retry.
fn handleSseEvent(evt: sse.SseEvent, state: *StreamState, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
    const data = evt.data;
    if (data.len == 0) return;

    _ = state.scratch.reset(.retain_capacity);
    const scratch = state.scratch.allocator();
    const parsed = std.json.parseFromSliceLeaky(
        std.json.Value,
        scratch,
        data,
        .{},
    ) catch return;
    if (parsed != .object) return;
    const obj = parsed.object;

    const event_type = json_value.asString(obj.get("type")) orelse return;

    if (std.mem.eql(u8, event_type, "message_start")) {
        // Shape: { message: { usage: { input_tokens, output_tokens } } }
        const message = json_value.asObject(obj.get("message")) orelse return;
        const usage = json_value.asObject(message.get("usage")) orelse return;
        if (json_value.asU64(usage.get("input_tokens"))) |n| state.partial.usage.input = n;
        if (json_value.asU64(usage.get("output_tokens"))) |n| state.partial.usage.output = n;
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
        // Shape: { index, content_block: { type, id?, name?, ... } }
        const block_json = json_value.asObject(obj.get("content_block")) orelse return;
        const block_type = json_value.asString(block_json.get("type")) orelse "text";
        const index = json_value.asU64(obj.get("index")) orelse state.content_blocks.items.len;

        if (std.mem.eql(u8, block_type, "text")) {
            const block = ContentBlockState.init(.text, index);
            state.content_blocks.append(state.allocator, block) catch return;
            callback(.{ .text_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            const block = ContentBlockState.init(.thinking, index);
            state.content_blocks.append(state.allocator, block) catch return;
            callback(.{ .thinking_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, block_type, "tool_use")) {
            var block = ContentBlockState.init(.tool_call, index);
            // id/name slices live in scratch — dupe into the turn
            // arena before the next SSE event resets it.
            const tool_id = state.allocator.dupe(u8, json_value.asString(block_json.get("id")) orelse "") catch "";
            const tool_name = state.allocator.dupe(u8, json_value.asString(block_json.get("name")) orelse "") catch "";
            block.tool_call = .{
                .id = tool_id,
                .name = tool_name,
                .arguments = .null,
                .thought_signature = null,
            };
            state.content_blocks.append(state.allocator, block) catch return;
            callback(.{ .toolcall_start = .{ .content_index = state.content_blocks.items.len - 1, .partial = state.partial } }, callback_ctx);
        }
    } else if (std.mem.eql(u8, event_type, "content_block_delta")) {
        // Shape: { index, delta: { type, text? | thinking? | partial_json? } }
        const delta_obj = json_value.asObject(obj.get("delta")) orelse return;
        const delta_type = json_value.asString(delta_obj.get("type")) orelse return;
        const index = json_value.asU64(obj.get("index")) orelse return;
        if (index >= state.content_blocks.items.len) return;
        const block = &state.content_blocks.items[index];

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = json_value.asString(delta_obj.get("text")) orelse return;
            // Append to the block buffer (turn arena), then re-slice
            // into the buffer to get a turn-arena-owned delta payload.
            // No extra dupe needed.
            const old_len = block.text.items.len;
            block.text.appendSlice(state.allocator, text) catch return;
            const text_val = block.text.items[old_len..];
            callback(.{ .text_delta = .{ .content_index = index, .delta = text_val, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, delta_type, "thinking_delta")) {
            const thinking = json_value.asString(delta_obj.get("thinking")) orelse return;
            const old_len = block.thinking.items.len;
            block.thinking.appendSlice(state.allocator, thinking) catch return;
            const thinking_val = block.thinking.items[old_len..];
            callback(.{ .thinking_delta = .{ .content_index = index, .delta = thinking_val, .partial = state.partial } }, callback_ctx);
        } else if (std.mem.eql(u8, delta_type, "input_json_delta")) {
            const partial = json_value.asString(delta_obj.get("partial_json")) orelse return;
            if (block.tool_call) |*tc| {
                const old_len = block.text.items.len;
                block.text.appendSlice(state.allocator, partial) catch return;
                // parseToolArgs resets state.scratch internally —
                // safe because `partial` is already copied into
                // block.text and we no longer need scratch's parse
                // tree.
                tc.arguments = parseToolArgs(state, block.text.items);
                const json_delta = block.text.items[old_len..];
                // Refresh live partial.content so downstream
                // subscribers see the in-progress tool_call with
                // parsed partial args (pi-mono parity).
                state.partial.content = buildLiveContent(state.allocator, state.content_blocks.items) catch state.partial.content;
                callback(.{ .toolcall_delta = .{ .content_index = index, .delta = json_delta, .partial = state.partial } }, callback_ctx);
            }
        }
    } else if (std.mem.eql(u8, event_type, "content_block_stop")) {
        const index = json_value.asU64(obj.get("index")) orelse return;
        if (index >= state.content_blocks.items.len) return;

        const block = &state.content_blocks.items[index];
        switch (block.block_type) {
            .text => {
                callback(.{ .text_end = .{ .content_index = index, .content = block.text.items, .partial = state.partial } }, callback_ctx);
            },
            .thinking => {
                callback(.{ .thinking_end = .{ .content_index = index, .content = block.thinking.items, .partial = state.partial } }, callback_ctx);
            },
            .tool_call => {
                if (block.tool_call) |tc| {
                    var final_tc = tc;
                    // Final parse: buffer should be complete, so
                    // parseStreaming's strict-first fast path wins.
                    final_tc.arguments = parseToolArgs(state, block.text.items);
                    block.tool_call = final_tc;
                    callback(.{ .toolcall_end = .{ .content_index = index, .tool_call = final_tc, .partial = state.partial } }, callback_ctx);
                }
            },
        }
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
        // Shape: { delta: { stop_reason, stop_sequence }, usage: { output_tokens } }
        if (json_value.asObject(obj.get("delta"))) |delta_obj| {
            if (json_value.asString(delta_obj.get("stop_reason"))) |reason| {
                if (std.mem.eql(u8, reason, "end_turn")) {
                    state.stop_reason = .end_turn;
                } else if (std.mem.eql(u8, reason, "max_tokens")) {
                    state.stop_reason = .max_tokens;
                } else if (std.mem.eql(u8, reason, "tool_use")) {
                    state.stop_reason = .tool_use;
                }
            }
        }
        if (json_value.asObject(obj.get("usage"))) |usage| {
            if (json_value.asU64(usage.get("input_tokens"))) |n| state.partial.usage.input = n;
            if (json_value.asU64(usage.get("output_tokens"))) |n| state.partial.usage.output = n;
        }
    } else if (std.mem.eql(u8, event_type, "error")) {
        // Shape: { error: { type, message } }
        const err_obj = json_value.asObject(obj.get("error")) orelse return;
        const err_msg = json_value.asString(err_obj.get("message")) orelse "unknown error";
        // err_msg lives in scratch; emitErrorDirect copies what it
        // needs synchronously, so passing the scratch slice is safe.
        emitErrorDirect(callback, callback_ctx, err_msg);
    }
}

// =================================================================
// Final content building
// =================================================================

fn buildFinalContent(allocator: std.mem.Allocator, blocks: []const ContentBlockState) ![]const protocol.AssistantMessage.AssistantContentBlock {
    const content = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, blocks.len);
    for (blocks, 0..) |block, i| {
        content[i] = switch (block.block_type) {
            .text => .{ .text = .{
                .text = try allocator.dupe(u8, block.text.items),
            } },
            .thinking => .{ .thinking = .{
                .thinking = try allocator.dupe(u8, block.thinking.items),
            } },
            .tool_call => .{ .tool_call = block.tool_call orelse .{
                .id = "",
                .name = "",
                .arguments = .null,
            } },
        };
    }
    return content;
}

/// pi-mono: anthropic.ts:446-454
fn supportsAdaptiveThinking(model_id: []const u8) bool {
    if (std.mem.indexOf(u8, model_id, "opus-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "opus-4.6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4.6") != null) return true;
    return false;
}

/// pi-mono: anthropic.ts:460-474
fn mapThinkingLevelToEffort(level: protocol.ThinkingLevel, model_id: []const u8) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (std.mem.indexOf(u8, model_id, "opus-4-6") != null or
            std.mem.indexOf(u8, model_id, "opus-4.6") != null) "max" else "high",
    };
}

/// pi-mono: simple-options.ts:22-46
fn adjustMaxTokensForThinking(
    base_max_tokens: u64,
    model_max_tokens: u64,
    level: protocol.ThinkingLevel,
    custom_budgets: ?protocol.ThinkingBudgets,
) struct { max_tokens: u64, thinking_budget: u64 } {
    const default_budgets = .{
        .minimal = @as(u64, 1024),
        .low = @as(u64, 2048),
        .medium = @as(u64, 8192),
        .high = @as(u64, 16384),
    };

    const thinking_budget_raw: u64 = switch (level) {
        .minimal => if (custom_budgets) |b| b.minimal orelse default_budgets.minimal else default_budgets.minimal,
        .low => if (custom_budgets) |b| b.low orelse default_budgets.low else default_budgets.low,
        .medium => if (custom_budgets) |b| b.medium orelse default_budgets.medium else default_budgets.medium,
        .high, .xhigh => if (custom_budgets) |b| b.high orelse default_budgets.high else default_budgets.high,
    };

    const min_output_tokens: u64 = 1024;
    const max_tokens = @min(base_max_tokens + thinking_budget_raw, model_max_tokens);
    const thinking_budget = if (max_tokens <= thinking_budget_raw)
        if (max_tokens > min_output_tokens) max_tokens - min_output_tokens else 0
    else
        thinking_budget_raw;

    return .{ .max_tokens = max_tokens, .thinking_budget = thinking_budget };
}

// =================================================================
// JSON request building — uses std.json.Stringify
// =================================================================

fn buildRequestJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, is_oauth: bool, reasoning: ?protocol.ThinkingLevel, thinking_budgets: ?protocol.ThinkingBudgets) !void {
    var out = std.io.Writer.Allocating.fromArrayList(allocator, buf);
    var jw: std.json.Stringify = .{ .writer = &out.writer };

    try jw.beginObject();
    try jw.objectField("model");
    try jw.write(model.id);
    const effective_max_tokens = blk: {
        if (model.reasoning) {
            if (reasoning) |level| {
                if (!supportsAdaptiveThinking(model.id)) {
                    const adjusted = adjustMaxTokensForThinking(
                        options.max_tokens orelse model.max_tokens,
                        model.max_tokens,
                        level,
                        thinking_budgets,
                    );
                    break :blk adjusted.max_tokens;
                }
            }
        }
        break :blk options.max_tokens orelse model.max_tokens;
    };
    try jw.objectField("max_tokens");
    try jw.write(effective_max_tokens);
    try jw.objectField("stream");
    try jw.write(true);

    if (is_oauth) {
        try jw.objectField("system");
        try jw.beginArray();
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("text");
        try jw.objectField("text");
        try jw.write("You are Claude Code, Anthropic's official CLI for Claude.");
        try jw.endObject();
        if (context.system_prompt) |system| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("text");
            try jw.objectField("text");
            try jw.write(system);
            try jw.endObject();
        }
        try jw.endArray();
    } else if (context.system_prompt) |system| {
        try jw.objectField("system");
        try jw.write(system);
    }

    try jw.objectField("messages");
    try jw.beginArray();
    for (context.messages) |msg| {
        try writeMessageJson(&jw, msg);
    }
    try jw.endArray();

    if (context.tools) |tools| {
        if (tools.len > 0) {
            try jw.objectField("tools");
            try jw.beginArray();
            for (tools) |tool| {
                try jw.beginObject();
                try jw.objectField("name");
                try jw.write(tool.name);
                try jw.objectField("description");
                try jw.write(tool.description);
                try jw.objectField("input_schema");
                try jw.write(tool.parameters);
                try jw.endObject();
            }
            try jw.endArray();
        }
    }

    // Temperature is incompatible with extended thinking
    if (options.temperature) |temp| {
        if (reasoning == null) {
            try jw.objectField("temperature");
            try jw.print("{d}", .{temp});
        }
    }

    // Thinking configuration — pi-mono: anthropic.ts:659-677
    if (model.reasoning) {
        if (reasoning) |level| {
            if (supportsAdaptiveThinking(model.id)) {
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("adaptive");
                try jw.endObject();
                try jw.objectField("output_config");
                try jw.beginObject();
                try jw.objectField("effort");
                try jw.write(mapThinkingLevelToEffort(level, model.id));
                try jw.endObject();
            } else {
                const adjusted = adjustMaxTokensForThinking(
                    options.max_tokens orelse model.max_tokens,
                    model.max_tokens,
                    level,
                    thinking_budgets,
                );
                try jw.objectField("thinking");
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("enabled");
                try jw.objectField("budget_tokens");
                try jw.write(adjusted.thinking_budget);
                try jw.endObject();
            }
        } else {
            try jw.objectField("thinking");
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("disabled");
            try jw.endObject();
        }
    }

    try jw.endObject();
    buf.* = out.toArrayList();
}

fn writeMessageJson(jw: *std.json.Stringify, msg: protocol.Message) !void {
    try jw.beginObject();
    switch (msg) {
        .user => |user| {
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            switch (user.content) {
                .text => |text_val| try jw.write(text_val),
                .blocks => |blocks| {
                    try jw.beginArray();
                    for (blocks) |block| {
                        switch (block) {
                            .text => |t| {
                                try jw.beginObject();
                                try jw.objectField("type");
                                try jw.write("text");
                                try jw.objectField("text");
                                try jw.write(t.text);
                                try jw.endObject();
                            },
                            .image => |img| try writeAnthropicImageBlock(jw, img),
                        }
                    }
                    try jw.endArray();
                },
            }
        },
        .assistant => |assistant| {
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("content");
            try jw.beginArray();
            for (assistant.content) |block| {
                switch (block) {
                    .text => |t| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("text");
                        try jw.objectField("text");
                        try jw.write(t.text);
                        try jw.endObject();
                    },
                    .thinking => |th| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("thinking");
                        try jw.objectField("thinking");
                        try jw.write(th.thinking);
                        if (th.thinking_signature) |sig| {
                            try jw.objectField("signature");
                            try jw.write(sig);
                        }
                        try jw.endObject();
                    },
                    .tool_call => |tc| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("tool_use");
                        try jw.objectField("id");
                        try jw.write(tc.id);
                        try jw.objectField("name");
                        try jw.write(tc.name);
                        try jw.objectField("input");
                        // Anthropic requires `input` to be a JSON object
                        // (it 400s on null or scalars). Coerce defensively
                        // here so any future code path that produces null
                        // arguments can't break the round-trip; the real
                        // upstream fix is in `parsePartialJson` but this
                        // is cheap insurance.
                        if (tc.arguments == .null) {
                            try jw.beginObject();
                            try jw.endObject();
                        } else {
                            try jw.write(tc.arguments);
                        }
                        try jw.endObject();
                    },
                }
            }
            try jw.endArray();
        },
        .tool_result => |tr| {
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("tool_result");
            try jw.objectField("tool_use_id");
            try jw.write(tr.tool_call_id);
            try jw.objectField("content");
            try jw.beginArray();
            for (tr.content) |content_block| {
                switch (content_block) {
                    .text => |t| {
                        try jw.beginObject();
                        try jw.objectField("type");
                        try jw.write("text");
                        try jw.objectField("text");
                        try jw.write(t.text);
                        try jw.endObject();
                    },
                    .image => |img| try writeAnthropicImageBlock(jw, img),
                }
            }
            try jw.endArray();
            if (tr.is_error) {
                try jw.objectField("is_error");
                try jw.write(true);
            }
            try jw.endObject();
            try jw.endArray();
        },
    }
    try jw.endObject();
}

fn writeAnthropicImageBlock(jw: *std.json.Stringify, img: protocol.ImageContent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("image");
    try jw.objectField("source");
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("base64");
    try jw.objectField("media_type");
    try jw.write(img.mime_type);
    try jw.objectField("data");
    try jw.write(img.data);
    try jw.endObject();
    try jw.endObject();
}

/// Parse a (possibly incomplete) tool-argument JSON buffer and
/// return a std.json.Value owned by the turn arena.
///
/// Arena split:
///   - `state.scratch` is reset with `retain_capacity` and the
///     partial JSON parser allocates into it. Old scratch trees
///     (from the previous delta) are dropped in bulk on reset, so
///     per-turn memory is bounded by the single largest tool-args
///     snapshot, not the sum of every intermediate parse.
///   - The parsed value is then deep-cloned into the turn arena
///     (`state.allocator`) which owns `tc.arguments`. The clone is
///     the only durable allocation per delta.
///
/// Empty/malformed input → `{}`. A tool call with no arguments is
/// `{}`, not `.null`: Anthropic's next request rejects `"input":null`
/// with HTTP 400, and downstream tool-arg extraction reports a
/// misleading "missing field" when the model simply emitted no args.
fn parseToolArgs(state: *StreamState, json_str: []const u8) std.json.Value {
    _ = state.scratch.reset(.retain_capacity);
    const scratch = state.scratch.allocator();
    const parsed = partial_json.parseStreaming(scratch, json_str) catch {
        // OutOfMemory in the scratch arena — fall back to an empty
        // object in the turn arena. Better than crashing mid-stream.
        return emptyObject(state.allocator);
    };
    return json_util.cloneJsonValue(state.allocator, parsed) catch emptyObject(state.allocator);
}

fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    return .{ .object = std.json.ObjectMap.init(allocator) };
}

/// Build a snapshot of `state.partial.content` for mid-stream
/// subscribers. Unlike `buildFinalContent`, this BORROWS the text /
/// thinking byte slices from `ContentBlockState` storage instead of
/// duping them — those buffers live in the turn arena and are
/// mutation-stable for the lifetime of the delta callback (the next
/// delta runs after the callback returns synchronously on the same
/// thread). Downstream consumers that need to retain the content
/// past the callback must deep-clone it themselves — which
/// `convertAgentEvent` in the TUI already does via `cloneJsonValue`.
fn buildLiveContent(allocator: std.mem.Allocator, blocks: []const ContentBlockState) ![]const protocol.AssistantMessage.AssistantContentBlock {
    const content = try allocator.alloc(protocol.AssistantMessage.AssistantContentBlock, blocks.len);
    for (blocks, 0..) |block, i| {
        content[i] = switch (block.block_type) {
            .text => .{ .text = .{ .text = block.text.items } },
            .thinking => .{ .thinking = .{ .thinking = block.thinking.items } },
            .tool_call => .{ .tool_call = block.tool_call orelse .{
                .id = "",
                .name = "",
                .arguments = .null,
            } },
        };
    }
    return content;
}

// =================================================================
// Error handling
// =================================================================

fn emitError(allocator: std.mem.Allocator, callback: ai_provider.EventCallback, ctx: ?*anyopaque, comptime fmt: []const u8, args: anytype) void {
    const msg = std.fmt.allocPrint(allocator, fmt, args) catch {
        callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
            .content = &.{},
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "unknown",
            .usage = .{
                .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .@"error",
            .error_message = "failed to format error",
            .timestamp = std.time.milliTimestamp(),
        } } }, ctx);
        return;
    };
    defer allocator.free(msg);
    emitErrorDirect(callback, ctx, msg);
}

const WatchdogCtx = struct {
    signal: AbortSignal,
    socket_fd: std.posix.fd_t,
    /// Set to true when the stream ends normally so the watchdog exits.
    /// Accessed atomically across threads.
    done: *std.atomic.Value(bool),
};

/// Watchdog thread: polls abort flag every 100ms. When set, shuts down
/// the socket to unblock any blocking read on the SSE reader thread.
/// Uses shutdown() instead of close() to avoid double-close with req.deinit().
fn abortWatchdog(ctx: WatchdogCtx) void {
    while (true) {
        // Check done FIRST (acquire fence ensures we see the main thread's write)
        if (ctx.done.load(.acquire)) return;
        if (ctx.signal.isAborted()) break;
        std.Thread.sleep(100_000_000); // 100ms
    }
    // Double-check done after seeing abort — the stream may have
    // finished between the abort check and now.
    if (ctx.done.load(.acquire)) return;
    // Shutdown the socket (not close) to unblock reads.
    // shutdown() makes the fd return 0/error on reads but keeps it valid
    // for req.deinit() to close later.
    const SHUT_RDWR = 2;
    _ = std.posix.system.shutdown(ctx.socket_fd, SHUT_RDWR);
}
fn emitErrorDirect(callback: ai_provider.EventCallback, ctx: ?*anyopaque, msg: []const u8) void {
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
        .content = &.{},
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "unknown",
        .usage = .{
            .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = msg,
        .timestamp = std.time.milliTimestamp(),
    } } }, ctx);
}

// =================================================================
// Tests
// =================================================================

const testing = std.testing;

// Regression test for the streaming bug where Anthropic input_json_delta
// events with embedded `{` / `}` inside their `partial_json` string
// payload broke the old substring extractor's brace depth counter,
// causing truncated extractions and lost tool arguments. The Edit
// tool's args would silently end up empty {} → "missing 'path'" →
// infinite retry. The fix was to parse SSE data via std.json instead
// of substring scanning; this test pins that behavior.
test "SSE parse: braces inside string values survive a real Edit-tool payload" {
    const data =
        \\{"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\"path\":\"/foo/bar.zig\",\"old_str\":\"a {b} c\"}"}}
    ;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), data, .{});
    try testing.expect(parsed == .object);
    const delta_obj = json_value.asObject(parsed.object.get("delta")).?;
    try testing.expectEqualStrings("input_json_delta", json_value.asString(delta_obj.get("type")).?);
    const partial = json_value.asString(delta_obj.get("partial_json")).?;
    // After std.json's escape decoding, the embedded braces are
    // literal characters in the result — no truncation, no lost
    // closing brace.
    try testing.expectEqualStrings("{\"path\":\"/foo/bar.zig\",\"old_str\":\"a {b} c\"}", partial);
}
