const zio_abort = @import("../zio/root.zig").abort;
const AbortSignal = zio_abort.AbortSignal;
const AbortGuard = zio_abort.AbortGuard;
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

pub const AnthropicProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) AnthropicProvider {
        return .{ .allocator = allocator };
    }

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

    fn streamImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options, null, null, callback, callback_ctx);
    }

    fn streamSimpleImplWrapper(ptr: *anyopaque, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.SimpleStreamOptions, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        const self: *AnthropicProvider = @ptrCast(@alignCast(ptr));
        self.streamImpl(allocator, model, context, options.base, ai_models.clampReasoning(options.reasoning, model), options.thinking_budgets, callback, callback_ctx);
    }

    fn getNameImpl(_: *anyopaque) []const u8 {
        return "anthropic";
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn streamImpl(self: *AnthropicProvider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, reasoning: ?protocol.ThinkingLevel, thinking_budgets: ?protocol.ThinkingBudgets, callback: ai_provider.EventCallback, callback_ctx: ?*anyopaque) void {
        _ = self;

        var payload_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer payload_buf.deinit(allocator);

        const is_oauth_token = if (options.api_key) |k| std.mem.indexOf(u8, k, "sk-ant-oat") != null else false;
        buildRequestJson(allocator, &payload_buf, model, context, options, is_oauth_token, reasoning, thinking_budgets) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to build request: {s}", .{@errorName(err)});
            return;
        };

        var decorators_buf: [1]request_transform.Decorator = undefined;
        var decorator_count: usize = 0;
        var metadata_context = AnthropicMetadataContext{ .metadata = options.metadata };
        if (anthropicMetadataUserId(options.metadata) != null) {
            decorators_buf[decorator_count] = .{ .func = addAnthropicMetadata, .ctx = @ptrCast(&metadata_context) };
            decorator_count += 1;
        }
        const transformed_payload = request_transform.transformJsonPayload(allocator, payload_buf.items, .{
            .model = &model,
            .stream_options = options,
            .decorators = decorators_buf[0..decorator_count],
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to transform request: {s}", .{@errorName(err)});
            return;
        };
        defer if (transformed_payload) |payload| allocator.free(payload);
        const request_payload = transformed_payload orelse payload_buf.items;

        const api_key = options.api_key orelse {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "no API key provided", .{});
            return;
        };

        const uri_str = std.fmt.allocPrint(allocator, "{s}/v1/messages", .{model.base_url}) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to build URI: {s}", .{@errorName(err)});
            return;
        };
        defer allocator.free(uri_str);

        const uri = std.Uri.parse(uri_str) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to parse URI: {s}", .{@errorName(err)});
            return;
        };

        var client: std.http.Client = .{ .allocator = allocator, .io = options.io };
        defer client.deinit();

        var extra_headers_buf: [16]std.http.Header = undefined;
        var n_extra: usize = 0;

        extra_headers_buf[n_extra] = .{ .name = "anthropic-version", .value = "2023-06-01" };
        n_extra += 1;

        const is_oauth = std.mem.indexOf(u8, api_key, "sk-ant-oat") != null;

        var auth_buf: [4096]u8 = undefined;
        if (is_oauth) {
            const auth_value = std.fmt.bufPrint(&auth_buf, "Bearer {s}", .{api_key}) catch {
                emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "API key too long for auth buffer", .{});
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

        var req = client.request(.POST, uri, .{
            .extra_headers = extra_headers_buf[0..n_extra],
            .headers = .{
                .content_type = .{ .override = "application/json" },
                .accept_encoding = .{ .override = "identity" },
            },
        }) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to open connection: {s}", .{@errorName(err)});
            return;
        };
        defer req.deinit();

        var abort_guard = AbortGuard.start(options.io, options.signal, .{
            .shutdown_fd = AbortGuard.httpRequestShutdownFd(&req),
        });
        defer abort_guard.stop();

        req.sendBodyComplete(request_payload) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to send body: {s}", .{@errorName(err)});
            return;
        };

        var redirect_buf: [4096]u8 = undefined;
        var response = req.receiveHead(&redirect_buf) catch |err| {
            emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "request failed: {s}", .{@errorName(err)});
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
                emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "failed to normalize HTTP error: {s}", .{@errorName(err)});
                return;
            };
            emitFailure(allocator, callback, callback_ctx, model.api, model.provider, model.id, normalized.failure, normalized.display_message);
            return;
        }

        var parser = sse.SseParser.init(allocator);
        defer parser.deinit();
        const reader = response.reader(&transfer_buf);

        var scratch_arena = std.heap.ArenaAllocator.init(allocator);
        defer scratch_arena.deinit();

        var state = StreamState{
            .allocator = allocator,
            .scratch = &scratch_arena,
            .content_blocks = .empty,
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
                .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
            },
            .stop_reason = null,
        };
        defer {
            for (state.content_blocks.items) |*block| {
                block.deinit(allocator);
            }
            state.content_blocks.deinit(allocator);
        }

        callback(.{ .start = .{ .partial = state.partial } }, callback_ctx);

        const StreamCtx = struct {
            state: *StreamState,
            callback: ai_provider.EventCallback,
            callback_ctx: ?*anyopaque,

            fn onEvent(evt: sse.SseEvent, ctx: ?*anyopaque) anyerror!void {
                const stream_self: *@This() = @ptrCast(@alignCast(ctx));
                handleSseEvent(evt, stream_self.state, stream_self.callback, stream_self.callback_ctx);
            }
        };

        var stream_ctx = StreamCtx{
            .state = &state,
            .callback = callback,
            .callback_ctx = callback_ctx,
        };

        sse.streamEvents(allocator, reader, &parser, 4096, .{
            .func = &StreamCtx.onEvent,
            .ctx = @ptrCast(&stream_ctx),
        }) catch |err| {
            if (options.signal.isAborted()) {
                state.partial.stop_reason = .aborted;
            } else if (err == error.EventDataTooLarge) {
                emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "stream event exceeded {d} bytes", .{sse.max_event_data_bytes});
                return;
            } else {
                emitError(allocator, callback, callback_ctx, model.api, model.provider, model.id, "stream read error: {s}", .{@errorName(err)});
                return;
            }
        };

        state.partial.content = buildFinalContent(allocator, state.content_blocks.items) catch &.{};

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
    allocator: std.mem.Allocator,
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
        const message = json_value.asObject(obj.get("message")) orelse return;
        const usage = json_value.asObject(message.get("usage")) orelse return;
        updateUsageFromObject(&state.partial.usage, usage);
    } else if (std.mem.eql(u8, event_type, "content_block_start")) {
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
        const delta_obj = json_value.asObject(obj.get("delta")) orelse return;
        const delta_type = json_value.asString(delta_obj.get("type")) orelse return;
        const index = json_value.asU64(obj.get("index")) orelse return;
        if (index >= state.content_blocks.items.len) return;
        const block = &state.content_blocks.items[index];

        if (std.mem.eql(u8, delta_type, "text_delta")) {
            const text = json_value.asString(delta_obj.get("text")) orelse return;
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
                tc.arguments = parseToolArgs(state, block.text.items);
                const json_delta = block.text.items[old_len..];
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
                    final_tc.arguments = parseToolArgs(state, block.text.items);
                    block.tool_call = final_tc;
                    callback(.{ .toolcall_end = .{ .content_index = index, .tool_call = final_tc, .partial = state.partial } }, callback_ctx);
                }
            },
        }
    } else if (std.mem.eql(u8, event_type, "message_delta")) {
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
            updateUsageFromObject(&state.partial.usage, usage);
        }
    } else if (std.mem.eql(u8, event_type, "error")) {
        const err_obj = json_value.asObject(obj.get("error")) orelse return;
        const err_type = json_value.asString(err_obj.get("type"));
        const err_msg = json_value.asString(err_obj.get("message")) orelse "unknown error";
        const failure_kind = provider_failure.classifyProviderFailure(err_type, null, err_msg);
        const failure: protocol.NormalizedFailure = .{
            .kind = failure_kind,
            .provider_type = if (err_type) |t| state.allocator.dupe(u8, t) catch null else null,
        };
        emitFailure(state.allocator, callback, callback_ctx, state.partial.api, state.partial.provider, state.partial.model, failure, err_msg);
    }
}

fn updateUsageFromObject(usage: *protocol.Usage, obj: std.json.ObjectMap) void {
    if (json_value.asU64(obj.get("input_tokens"))) |n| usage.input = n;
    if (json_value.asU64(obj.get("output_tokens"))) |n| usage.output = n;
    if (json_value.asU64(obj.get("cache_read_input_tokens"))) |n| usage.cache_read = n;
    if (json_value.asU64(obj.get("cache_creation_input_tokens"))) |n| usage.cache_write = n;
    usage.total_tokens = usage.input + usage.output + usage.cache_read + usage.cache_write;
}

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

fn supportsAdaptiveThinking(model_id: []const u8) bool {
    if (std.mem.indexOf(u8, model_id, "opus-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "opus-4.6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4-6") != null) return true;
    if (std.mem.indexOf(u8, model_id, "sonnet-4.6") != null) return true;
    return false;
}

fn mapThinkingLevelToEffort(level: protocol.ThinkingLevel, model_id: []const u8) []const u8 {
    return switch (level) {
        .minimal, .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => if (std.mem.indexOf(u8, model_id, "opus-4-6") != null or
            std.mem.indexOf(u8, model_id, "opus-4.6") != null) "max" else "high",
    };
}

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

const AnthropicMetadataContext = struct {
    metadata: ?std.json.Value,
};

fn anthropicMetadataUserId(metadata: ?std.json.Value) ?[]const u8 {
    const value = metadata orelse return null;
    if (value != .object) return null;
    const user_id = value.object.get("user_id") orelse return null;
    if (user_id != .string or user_id.string.len == 0) return null;
    return user_id.string;
}

fn addAnthropicMetadata(
    allocator: std.mem.Allocator,
    payload: *std.json.Value,
    _: *const protocol.Model,
    ctx: ?*anyopaque,
) !bool {
    const metadata_context: *const AnthropicMetadataContext = @ptrCast(@alignCast(ctx.?));
    const user_id = anthropicMetadataUserId(metadata_context.metadata) orelse return false;

    var metadata: std.json.ObjectMap = .{};
    errdefer metadata.deinit(allocator);
    try metadata.put(allocator, "user_id", .{ .string = user_id });
    try payload.object.put(allocator, "metadata", .{ .object = metadata });
    return true;
}

fn buildRequestJson(allocator: std.mem.Allocator, buf: *std.ArrayListUnmanaged(u8), model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, is_oauth: bool, reasoning: ?protocol.ThinkingLevel, thinking_budgets: ?protocol.ThinkingBudgets) !void {
    var out = std.Io.Writer.Allocating.fromArrayList(allocator, buf);
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
    var i: usize = 0;
    while (i < context.messages.len) : (i += 1) {
        const msg = context.messages[i];
        if (msg == .tool_result) {
            try jw.beginObject();
            try jw.objectField("role");
            try jw.write("user");
            try jw.objectField("content");
            try jw.beginArray();

            try writeToolResultBlock(&jw, msg.tool_result);
            while (i + 1 < context.messages.len and context.messages[i + 1] == .tool_result) : (i += 1) {
                try writeToolResultBlock(&jw, context.messages[i + 1].tool_result);
            }

            try jw.endArray();
            try jw.endObject();
            continue;
        }
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

    if (options.temperature) |temp| {
        if (reasoning == null) {
            try jw.objectField("temperature");
            try jw.print("{d}", .{temp});
        }
    }

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
            try writeToolResultBlock(jw, tr);
            try jw.endArray();
        },
    }
    try jw.endObject();
}

fn writeToolResultBlock(jw: *std.json.Stringify, tr: protocol.ToolResultMessage) !void {
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

// Anthropic rejects tool `input:null`.
fn parseToolArgs(state: *StreamState, json_str: []const u8) std.json.Value {
    _ = state.scratch.reset(.retain_capacity);
    const scratch = state.scratch.allocator();
    const parsed = partial_json.parseStreaming(scratch, json_str) catch {
        return emptyObject(state.allocator);
    };
    return json_util.cloneJsonValue(state.allocator, parsed) catch emptyObject(state.allocator);
}

fn emptyObject(allocator: std.mem.Allocator) std.json.Value {
    _ = allocator;
    return .{ .object = .{} };
}

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

fn emitError(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    ctx: ?*anyopaque,
    api: protocol.Api,
    provider: protocol.Provider,
    model_id: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) void {
    const inner = std.fmt.allocPrint(allocator, fmt, args) catch "anthropic error";
    emitFailure(allocator, callback, ctx, api, provider, model_id, .{ .kind = provider_failure.classifyTransportFailure(inner) }, inner);
}

fn emitFailure(
    allocator: std.mem.Allocator,
    callback: ai_provider.EventCallback,
    ctx: ?*anyopaque,
    api: protocol.Api,
    provider: protocol.Provider,
    model_id: []const u8,
    failure: ?protocol.NormalizedFailure,
    message: []const u8,
) void {
    const owned_message = allocator.dupe(u8, message) catch "failed to copy error";
    callback(.{ .@"error" = .{ .reason = .@"error", .@"error" = .{
        .content = &.{},
        .api = api,
        .provider = provider,
        .model = model_id,
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = owned_message,
        .failure = failure,
        .timestamp = std.Io.Timestamp.now(std.Options.debug_io, .real).toMilliseconds(),
    } } }, ctx);
}

const testing = std.testing;

fn testAnthropicModel() protocol.Model {
    return .{
        .id = "claude-test",
        .name = "claude test",
        .api = .anthropic_messages,
        .provider = .anthropic,
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &.{},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 0,
        .max_tokens = 1024,
    };
}

test "Anthropic request transform maps metadata user_id" {
    const allocator = testing.allocator;
    var payload: std.ArrayListUnmanaged(u8) = .empty;
    defer payload.deinit(allocator);

    var metadata: std.json.ObjectMap = .{};
    defer metadata.deinit(allocator);
    try metadata.put(allocator, "user_id", .{ .string = "user-123" });

    const model = testAnthropicModel();
    try buildRequestJson(allocator, &payload, model, .{ .messages = &.{} }, .{ .metadata = .{ .object = metadata } }, false, null, null);

    var metadata_context = AnthropicMetadataContext{ .metadata = .{ .object = metadata } };
    const transformed = try request_transform.transformJsonPayload(allocator, payload.items, .{
        .model = &model,
        .decorators = &.{.{ .func = addAnthropicMetadata, .ctx = @ptrCast(&metadata_context) }},
    });
    defer allocator.free(transformed.?);

    try testing.expect(std.mem.indexOf(u8, transformed.?, "\"metadata\":{\"user_id\":\"user-123\"}") != null);
}

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
    try testing.expectEqualStrings("{\"path\":\"/foo/bar.zig\",\"old_str\":\"a {b} c\"}", partial);
}

test "Anthropic SSE usage keeps cache tokens in total_tokens" {
    var turn_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer turn_arena.deinit();
    var scratch_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_arena.deinit();

    var state = StreamState{
        .allocator = turn_arena.allocator(),
        .scratch = &scratch_arena,
        .content_blocks = .empty,
        .partial = .{
            .content = &.{},
            .api = .anthropic_messages,
            .provider = .anthropic,
            .model = "claude-test",
            .usage = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total_tokens = 0,
                .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
            },
            .stop_reason = .stop,
            .timestamp = 0,
        },
        .stop_reason = null,
    };
    defer {
        for (state.content_blocks.items) |*block| block.deinit(turn_arena.allocator());
        state.content_blocks.deinit(turn_arena.allocator());
    }

    const Noop = struct {
        fn callback(_: protocol.AssistantMessageEvent, _: ?*anyopaque) void {}
    };

    handleSseEvent(.{ .data =
        \\{"type":"message_start","message":{"usage":{"input_tokens":1200,"output_tokens":10,"cache_read_input_tokens":800,"cache_creation_input_tokens":400}}}
    }, &state, &Noop.callback, null);
    try testing.expectEqual(@as(u64, 1200), state.partial.usage.input);
    try testing.expectEqual(@as(u64, 10), state.partial.usage.output);
    try testing.expectEqual(@as(u64, 800), state.partial.usage.cache_read);
    try testing.expectEqual(@as(u64, 400), state.partial.usage.cache_write);
    try testing.expectEqual(@as(u64, 2410), state.partial.usage.total_tokens);

    handleSseEvent(.{ .data =
        \\{"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":25,"cache_read_input_tokens":900}} 
    }, &state, &Noop.callback, null);
    try testing.expectEqual(@as(u64, 1200), state.partial.usage.input);
    try testing.expectEqual(@as(u64, 25), state.partial.usage.output);
    try testing.expectEqual(@as(u64, 900), state.partial.usage.cache_read);
    try testing.expectEqual(@as(u64, 400), state.partial.usage.cache_write);
    try testing.expectEqual(@as(u64, 2525), state.partial.usage.total_tokens);
}
