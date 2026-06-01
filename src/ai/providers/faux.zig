const std = @import("std");
const mem = @import("../../runtime/root.zig");
const owned = @import("../owned.zig");
const protocol = @import("../protocol.zig");
const provider_registry = @import("../provider_registry.zig");

pub const default_api = "faux";
pub const default_provider = "faux";
pub const default_model_id = "faux-1";
pub const default_model_name = "Faux Model";
pub const default_base_url = "http://localhost:0";

const default_min_token_size = 3;
const default_max_token_size = 5;

pub const ModelDefinition = struct {
    id: []const u8,
    name: ?[]const u8 = null,
    reasoning: bool = false,
    input: []const protocol.Model.Input = &.{ .text, .image },
    cost: protocol.Model.Cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    context_window: u64 = 128_000,
    max_tokens: u64 = 16_384,
};

const default_model_definitions = [_]ModelDefinition{.{ .id = default_model_id, .name = default_model_name }};

pub const Options = struct {
    api: []const u8 = default_api,
    provider: []const u8 = default_provider,
    models: []const ModelDefinition = &default_model_definitions,
    min_token_size: usize = default_min_token_size,
    max_token_size: usize = default_max_token_size,
    delay_per_delta_ms: u32 = 0,
};

pub const State = struct {
    call_count: usize,
};

pub const FactoryError = error{ OutOfMemory, Boom };

pub const ResponseFactory = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, protocol.StreamRequest, *const State) FactoryError!protocol.AssistantMessage,

    fn call(
        self: ResponseFactory,
        request: protocol.StreamRequest,
        state: *const State,
    ) FactoryError!protocol.AssistantMessage {
        return self.call_fn(self.context, request, state);
    }
};

const ResponseStep = union(enum) {
    message: owned.RetainedAssistantMessage,
    factory: ResponseFactory,

    fn deinit(self: *ResponseStep) void {
        switch (self.*) {
            .message => |*message| message.deinit(),
            .factory => {},
        }
        self.* = undefined;
    }
};

const PromptCacheEntry = struct {
    key: []u8,
    prompt: []u8,
};

pub const Provider = struct {
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    source_id: []const u8,
    models: []protocol.Model,
    min_token_size: usize,
    max_token_size: usize,
    delay_per_delta_ms: u32,
    responses: std.ArrayList(ResponseStep) = .empty,
    next_response: usize = 0,
    call_count: usize = 0,
    prompt_cache: std.StringHashMapUnmanaged(PromptCacheEntry) = .empty,

    pub fn init(allocator: std.mem.Allocator, options: Options) !Provider {
        const api = try allocator.dupe(u8, options.api);
        errdefer allocator.free(api);
        const provider = try allocator.dupe(u8, options.provider);
        errdefer allocator.free(provider);
        const source_id = try std.fmt.allocPrint(allocator, "faux-provider:{s}:{s}", .{ provider, api });
        errdefer allocator.free(source_id);
        const models = try copyModels(allocator, api, provider, options.models);
        errdefer deinitModels(allocator, models);

        return .{
            .allocator = allocator,
            .api = api,
            .provider = provider,
            .source_id = source_id,
            .models = models,
            .min_token_size = @max(1, @min(options.min_token_size, options.max_token_size)),
            .max_token_size = @max(options.min_token_size, options.max_token_size),
            .delay_per_delta_ms = options.delay_per_delta_ms,
        };
    }

    pub fn deinit(self: *Provider) void {
        self.clearResponses();
        self.responses.deinit(self.allocator);
        self.clearPromptCache();
        self.prompt_cache.deinit(self.allocator);
        deinitModels(self.allocator, self.models);
        self.allocator.free(self.source_id);
        self.allocator.free(self.provider);
        self.allocator.free(self.api);
        self.* = undefined;
    }

    pub fn register(self: *Provider, registry: *provider_registry.ProviderRegistry) !void {
        try registry.register(self.apiProvider(), self.source_id);
    }

    pub fn unregister(self: *Provider, registry: *provider_registry.ProviderRegistry) void {
        registry.unregisterSource(self.source_id);
    }

    pub fn apiProvider(self: *Provider) provider_registry.ApiProvider {
        return .{
            .api = self.api,
            .stream = .{ .context = self, .call_fn = streamFunction },
            .stream_simple = .{ .context = self, .call_fn = streamFunction },
        };
    }

    pub fn getModel(self: *const Provider) protocol.Model {
        return self.models[0];
    }

    pub fn findModel(self: *const Provider, model_id: []const u8) ?protocol.Model {
        for (self.models) |model| {
            if (std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }

    pub fn setResponses(self: *Provider, responses: []const protocol.AssistantMessage) !void {
        self.clearResponses();
        try self.appendResponses(responses);
    }

    pub fn appendResponses(self: *Provider, responses: []const protocol.AssistantMessage) !void {
        for (responses) |response| {
            var normalized = response;
            normalized.api = self.api;
            normalized.provider = self.provider;
            normalized.model = self.getModel().id;
            var cloned = try owned.RetainedAssistantMessage.copy(self.allocator, normalized);
            errdefer cloned.deinit();
            try self.responses.append(self.allocator, .{ .message = cloned });
        }
    }

    pub fn appendFactory(self: *Provider, factory: ResponseFactory) !void {
        try self.responses.append(self.allocator, .{ .factory = factory });
    }

    pub fn pendingResponseCount(self: *const Provider) usize {
        return self.responses.items.len - self.next_response;
    }

    fn clearResponses(self: *Provider) void {
        for (self.responses.items) |*response| response.deinit();
        self.responses.clearRetainingCapacity();
        self.next_response = 0;
    }

    fn nextResponse(self: *Provider) ?*ResponseStep {
        if (self.next_response >= self.responses.items.len) return null;
        const response = &self.responses.items[self.next_response];
        self.next_response += 1;
        return response;
    }

    fn clearPromptCache(self: *Provider) void {
        var iterator = self.prompt_cache.iterator();
        while (iterator.next()) |entry| {
            self.allocator.free(entry.value_ptr.key);
            self.allocator.free(entry.value_ptr.prompt);
        }
        self.prompt_cache.clearRetainingCapacity();
    }
};

fn copyModels(
    allocator: std.mem.Allocator,
    api: []const u8,
    provider: []const u8,
    definitions: []const ModelDefinition,
) ![]protocol.Model {
    const source = if (definitions.len > 0) definitions else &default_model_definitions;
    const models = try allocator.alloc(protocol.Model, source.len);
    errdefer allocator.free(models);
    for (source, models) |definition, *model| {
        const id = try allocator.dupe(u8, definition.id);
        errdefer allocator.free(id);
        const name = try allocator.dupe(u8, definition.name orelse definition.id);
        errdefer allocator.free(name);
        model.* = .{
            .id = id,
            .name = name,
            .api = api,
            .provider = provider,
            .base_url = default_base_url,
            .reasoning = definition.reasoning,
            .input = definition.input,
            .cost = definition.cost,
            .context_window = definition.context_window,
            .max_tokens = definition.max_tokens,
        };
    }
    return models;
}

fn deinitModels(allocator: std.mem.Allocator, models: []protocol.Model) void {
    for (models) |model| {
        allocator.free(model.id);
        allocator.free(model.name);
    }
    allocator.free(models);
}

pub fn text(value: []const u8) protocol.AssistantContent {
    return .{ .text = .{ .text = value } };
}

pub fn thinking(value: []const u8) protocol.AssistantContent {
    return .{ .thinking = .{ .thinking = value } };
}

pub fn toolCall(id: []const u8, name: []const u8, arguments: std.json.Value) protocol.AssistantContent {
    return .{ .tool_call = .{ .id = id, .name = name, .arguments = arguments } };
}

pub fn assistantMessage(
    content: []const protocol.AssistantContent,
    options: AssistantMessageOptions,
) protocol.AssistantMessage {
    return .{
        .content = content,
        .api = default_api,
        .provider = default_provider,
        .model = default_model_id,
        .response_id = options.response_id,
        .usage = protocol.emptyUsage(),
        .stop_reason = options.stop_reason,
        .error_message = options.error_message,
        .timestamp = options.timestamp,
    };
}

pub const AssistantMessageOptions = struct {
    stop_reason: protocol.StopReason = .stop,
    error_message: ?[]const u8 = null,
    response_id: ?[]const u8 = null,
    timestamp: protocol.Timestamp = 0,
};

fn streamFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const self: *Provider = @ptrCast(@alignCast(context.?));
    self.call_count += 1;

    var stream = protocol.AssistantMessageEventStream.initBuffered();
    const sink = stream.sink();

    const step = self.nextResponse() orelse {
        var message = protocol.emptyAssistantMessageFromRequest(request, .error_, "No more faux responses queued");
        message.usage = estimateUsage(self, request.context, message, request.options) catch unreachable;
        sink.endError(request.io, .error_, message) catch unreachable;
        return stream;
    };

    switch (step.*) {
        .message => |*response| {
            response.value.usage = estimateUsage(
                self,
                request.context,
                response.value,
                request.options,
            ) catch unreachable;
            emitDeltas(
                request,
                sink,
                response,
                self.min_token_size,
                self.max_token_size,
                self.delay_per_delta_ms,
            ) catch |err| {
                if (err == error.OperationCancelled or err == error.Canceled) {
                    const message = protocol.emptyAssistantMessageFromRequest(
                        request,
                        .aborted,
                        "Request was aborted",
                    );
                    sink.endAborted(request.io, message) catch unreachable;
                    return stream;
                }
                unreachable;
            };
        },
        .factory => |factory| {
            var message = factory.call(request, &.{ .call_count = self.call_count }) catch |err| {
                var error_message = protocol.emptyAssistantMessageFromRequest(request, .error_, @errorName(err));
                error_message.usage = estimateUsage(
                    self,
                    request.context,
                    error_message,
                    request.options,
                ) catch unreachable;
                sink.endError(request.io, .error_, error_message) catch unreachable;
                return stream;
            };
            message.api = self.api;
            message.provider = self.provider;
            message.model = request.model.id;
            message.usage = estimateUsage(self, request.context, message, request.options) catch unreachable;
            const owned_message = owned.RetainedAssistantMessage.copy(self.allocator, message) catch unreachable;
            step.deinit();
            step.* = .{ .message = owned_message };
            emitDeltas(
                request,
                sink,
                &step.message,
                self.min_token_size,
                self.max_token_size,
                self.delay_per_delta_ms,
            ) catch |err| {
                if (err == error.OperationCancelled or err == error.Canceled) {
                    const aborted_message = protocol.emptyAssistantMessageFromRequest(
                        request,
                        .aborted,
                        "Request was aborted",
                    );
                    sink.endAborted(request.io, aborted_message) catch unreachable;
                    return stream;
                }
                unreachable;
            };
        },
    }
    return stream;
}

const PartialBuilder = struct {
    allocator: std.mem.Allocator,
    final_message: protocol.AssistantMessage,
    content: std.ArrayList(protocol.AssistantContent),
    partial: protocol.AssistantMessage,
    text_bytes: mem.ByteBuilder,
    thinking_bytes: mem.ByteBuilder,
    active: ActiveBlock = .none,

    const ActiveBlock = enum { none, text, thinking };

    fn init(response: *owned.RetainedAssistantMessage) PartialBuilder {
        const allocator = response.arena.allocator();
        return .{
            .allocator = allocator,
            .final_message = response.value,
            .content = .empty,
            .text_bytes = mem.ByteBuilder.initBounded(allocator, maxTextBlockBytes(response.value.content)),
            .thinking_bytes = mem.ByteBuilder.initBounded(allocator, maxThinkingBlockBytes(response.value.content)),
            .partial = .{
                .content = &.{},
                .api = response.value.api,
                .provider = response.value.provider,
                .model = response.value.model,
                .response_id = response.value.response_id,
                .usage = response.value.usage,
                .stop_reason = response.value.stop_reason,
                .error_message = response.value.error_message,
                .timestamp = response.value.timestamp,
            },
        };
    }

    fn message(self: *PartialBuilder) !protocol.AssistantMessage {
        const content = try self.allocator.dupe(protocol.AssistantContent, self.content.items);
        var snapshot = self.partial;
        snapshot.content = content;
        return snapshot;
    }

    fn startText(self: *PartialBuilder) !void {
        try self.freezeActive();
        self.text_bytes.clearRetainingCapacity();
        try self.content.append(self.allocator, .{ .text = .{ .text = "" } });
        self.active = .text;
    }

    fn appendText(self: *PartialBuilder, delta: []const u8) !void {
        try self.text_bytes.append(delta);
        const text_block = &self.content.items[self.content.items.len - 1].text;
        text_block.text = self.text_bytes.items();
    }

    fn startThinking(self: *PartialBuilder) !void {
        try self.freezeActive();
        self.thinking_bytes.clearRetainingCapacity();
        try self.content.append(self.allocator, .{ .thinking = .{ .thinking = "" } });
        self.active = .thinking;
    }

    fn appendThinking(self: *PartialBuilder, delta: []const u8) !void {
        try self.thinking_bytes.append(delta);
        const thinking_block = &self.content.items[self.content.items.len - 1].thinking;
        thinking_block.thinking = self.thinking_bytes.items();
    }

    fn startToolCall(self: *PartialBuilder, call: protocol.ToolCall) !void {
        try self.freezeActive();
        const empty_object: std.json.ObjectMap = .empty;
        const empty_args: std.json.Value = .{ .object = empty_object };
        try self.content.append(self.allocator, .{ .tool_call = .{
            .id = call.id,
            .name = call.name,
            .arguments = empty_args,
            .thought_signature = call.thought_signature,
        } });
    }

    fn endToolCall(self: *PartialBuilder, call: protocol.ToolCall) void {
        self.content.items[self.content.items.len - 1] = .{ .tool_call = call };
    }

    fn freezeActive(self: *PartialBuilder) !void {
        switch (self.active) {
            .none => {},
            .text => {
                const block = &self.content.items[self.content.items.len - 1].text;
                block.text = try self.allocator.dupe(u8, self.text_bytes.items());
            },
            .thinking => {
                const block = &self.content.items[self.content.items.len - 1].thinking;
                block.thinking = try self.allocator.dupe(u8, self.thinking_bytes.items());
            },
        }
        self.active = .none;
    }
};

fn maxTextBlockBytes(content: []const protocol.AssistantContent) usize {
    var max: usize = 0;
    for (content) |block| switch (block) {
        .text => |block_text| max = @max(max, block_text.text.len),
        else => {},
    };
    return max;
}

fn maxThinkingBlockBytes(content: []const protocol.AssistantContent) usize {
    var max: usize = 0;
    for (content) |block| switch (block) {
        .thinking => |block_thinking| max = @max(max, block_thinking.thinking.len),
        else => {},
    };
    return max;
}

fn emitDeltas(
    request: protocol.StreamRequest,
    sink: protocol.AssistantMessageEventSink,
    response: *owned.RetainedAssistantMessage,
    min_token_size: usize,
    max_token_size: usize,
    delay_per_delta_ms: u32,
) (protocol.AssistantMessageEventSinkEmitError || mem.ByteBuilder.Error || std.Io.Writer.Error || error{
    OperationCancelled,
    Canceled,
})!void {
    const io = request.io;
    const message = response.value;
    var partial = PartialBuilder.init(response);
    try sink.emit(io, .{ .start = .{ .partial = try partial.message() } });

    for (message.content, 0..) |block, index| {
        switch (block) {
            .text => |content| {
                try partial.startText();
                try sink.emit(io, .{ .text_start = .{ .content_index = index, .partial = try partial.message() } });
                try emitTextDeltas(
                    request,
                    sink,
                    index,
                    content.text,
                    &partial,
                    min_token_size,
                    max_token_size,
                    delay_per_delta_ms,
                    .text,
                );
                try sink.emit(io, .{ .text_end = .{
                    .content_index = index,
                    .content = content.text,
                    .partial = try partial.message(),
                } });
            },
            .thinking => |content| {
                try partial.startThinking();
                try sink.emit(io, .{ .thinking_start = .{ .content_index = index, .partial = try partial.message() } });
                try emitTextDeltas(
                    request,
                    sink,
                    index,
                    content.thinking,
                    &partial,
                    min_token_size,
                    max_token_size,
                    delay_per_delta_ms,
                    .thinking,
                );
                try sink.emit(io, .{ .thinking_end = .{
                    .content_index = index,
                    .content = content.thinking,
                    .partial = try partial.message(),
                } });
            },
            .tool_call => |call| {
                try partial.startToolCall(call);
                try sink.emit(io, .{ .toolcall_start = .{ .content_index = index, .partial = try partial.message() } });
                const arguments_json = try stringifyJsonValue(partial.allocator, call.arguments);
                try emitToolCallDeltas(
                    request,
                    sink,
                    index,
                    arguments_json,
                    try partial.message(),
                    min_token_size,
                    max_token_size,
                    delay_per_delta_ms,
                );
                partial.endToolCall(call);
                try sink.emit(io, .{ .toolcall_end = .{
                    .content_index = index,
                    .tool_call = call,
                    .partial = try partial.message(),
                } });
            },
        }
    }

    switch (message.stop_reason) {
        .error_ => try sink.endError(io, .error_, message),
        .aborted => try sink.endAborted(io, message),
        .stop => try sink.endDone(io, .stop, message),
        .length => try sink.endDone(io, .length, message),
        .tool_use => try sink.endDone(io, .tool_use, message),
    }
}

const DeltaKind = enum { text, thinking };

fn emitTextDeltas(
    request: protocol.StreamRequest,
    sink: protocol.AssistantMessageEventSink,
    content_index: usize,
    value: []const u8,
    partial: *PartialBuilder,
    min_token_size: usize,
    max_token_size: usize,
    delay_per_delta_ms: u32,
    kind: DeltaKind,
) (protocol.AssistantMessageEventSinkEmitError || mem.ByteBuilder.Error || error{
    OperationCancelled,
    Canceled,
})!void {
    const io = request.io;
    var index: usize = 0;
    while (index < value.len) {
        try waitBeforeDelta(request, delay_per_delta_ms);
        const char_size = @max(@as(usize, 1), nextTokenSize(min_token_size, max_token_size) * 4);
        const end = @min(value.len, index + char_size);
        const delta = value[index..end];
        switch (kind) {
            .text => {
                try partial.appendText(delta);
                try sink.emit(io, .{ .text_delta = .{
                    .content_index = content_index,
                    .delta = delta,
                    .partial = try partial.message(),
                } });
            },
            .thinking => {
                try partial.appendThinking(delta);
                try sink.emit(io, .{ .thinking_delta = .{
                    .content_index = content_index,
                    .delta = delta,
                    .partial = try partial.message(),
                } });
            },
        }
        index = end;
    }
    if (value.len == 0) switch (kind) {
        .text => try sink.emit(io, .{ .text_delta = .{
            .content_index = content_index,
            .delta = "",
            .partial = try partial.message(),
        } }),
        .thinking => try sink.emit(io, .{ .thinking_delta = .{
            .content_index = content_index,
            .delta = "",
            .partial = try partial.message(),
        } }),
    };
}

fn emitToolCallDeltas(
    request: protocol.StreamRequest,
    sink: protocol.AssistantMessageEventSink,
    content_index: usize,
    value: []const u8,
    partial: protocol.AssistantMessage,
    min_token_size: usize,
    max_token_size: usize,
    delay_per_delta_ms: u32,
) (protocol.AssistantMessageEventSinkEmitError || error{ OperationCancelled, Canceled })!void {
    const io = request.io;
    var index: usize = 0;
    while (index < value.len) {
        try waitBeforeDelta(request, delay_per_delta_ms);
        const char_size = @max(@as(usize, 1), nextTokenSize(min_token_size, max_token_size) * 4);
        const end = @min(value.len, index + char_size);
        try sink.emit(io, .{ .toolcall_delta = .{
            .content_index = content_index,
            .delta = value[index..end],
            .partial = partial,
        } });
        index = end;
    }
}

fn waitBeforeDelta(
    request: protocol.StreamRequest,
    delay_per_delta_ms: u32,
) error{ OperationCancelled, Canceled }!void {
    if (request.cancel_token) |token| try token.throwIfRequested();
    if (delay_per_delta_ms == 0) return;
    try mem.sleepUntilCancel(
        request.zio_runtime,
        .fromMilliseconds(delay_per_delta_ms),
        request.cancel_token,
    );
}

fn concat(allocator: std.mem.Allocator, a: []const u8, b: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, a.len + b.len);
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len..], b);
    return out;
}

fn stringifyJsonValue(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.print("{f}", .{std.json.fmt(value, .{})});
    return writer.toOwnedSlice();
}

fn nextTokenSize(min_token_size: usize, max_token_size: usize) usize {
    return @max(min_token_size, max_token_size);
}

fn estimateUsage(
    self: *Provider,
    context: protocol.Context,
    message: protocol.AssistantMessage,
    options: protocol.StreamOptions,
) !protocol.Usage {
    const prompt = try serializeContext(self.allocator, context);
    defer self.allocator.free(prompt);
    const prompt_tokens = estimateTokens(prompt.len);
    var input = prompt_tokens;
    var cache_read: u64 = 0;
    var cache_write: u64 = 0;
    const output_text = try serializeAssistantContent(self.allocator, message.content);
    defer self.allocator.free(output_text);
    const output = estimateTokens(output_text.len);

    if (options.session_id) |session_id| {
        if (options.cache_retention != .none) {
            if (self.prompt_cache.getPtr(session_id)) |entry| {
                const prefix = commonPrefixLength(entry.prompt, prompt);
                cache_read = estimateTokens(prefix);
                cache_write = estimateTokens(prompt.len - prefix);
                input = prompt_tokens - @min(prompt_tokens, cache_read);
                self.allocator.free(entry.prompt);
                entry.prompt = try self.allocator.dupe(u8, prompt);
            } else {
                const key = try self.allocator.dupe(u8, session_id);
                errdefer self.allocator.free(key);
                const stored_prompt = try self.allocator.dupe(u8, prompt);
                errdefer self.allocator.free(stored_prompt);
                try self.prompt_cache.put(self.allocator, key, .{ .key = key, .prompt = stored_prompt });
                cache_write = prompt_tokens;
            }
        }
    }

    return .{
        .input = input,
        .output = output,
        .cache_read = cache_read,
        .cache_write = cache_write,
        .total_tokens = input + output + cache_read + cache_write,
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
    };
}

fn serializeContext(allocator: std.mem.Allocator, context: protocol.Context) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var needs_separator = false;
    if (context.system_prompt) |prompt| {
        try writer.writer.print("system:{s}", .{prompt});
        needs_separator = true;
    }
    for (context.messages) |message| {
        if (needs_separator) try writer.writer.writeAll("\n\n");
        needs_separator = true;
        switch (message) {
            .user => |user| {
                try writer.writer.writeAll("user:");
                try writeUserContent(&writer.writer, user.content);
            },
            .assistant => |assistant| {
                try writer.writer.writeAll("assistant:");
                try writeAssistantContent(&writer.writer, assistant.content);
            },
            .tool_result => |tool| {
                try writer.writer.print("toolResult:{s}", .{tool.tool_name});
                for (tool.content) |content| {
                    try writer.writer.writeAll("\n");
                    try writeToolResultContent(&writer.writer, content);
                }
            },
        }
    }
    if (context.tools) |tools| {
        if (tools.len > 0) {
            if (needs_separator) try writer.writer.writeAll("\n\n");
            try writer.writer.writeAll("tools:");
            try writeToolsJson(allocator, &writer.writer, tools);
        }
    }
    return writer.toOwnedSlice();
}

fn serializeAssistantContent(
    allocator: std.mem.Allocator,
    content: []const protocol.AssistantContent,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writeAssistantContent(&writer.writer, content);
    return writer.toOwnedSlice();
}

fn writeUserContent(writer: *std.Io.Writer, content: protocol.UserMessage.Content) !void {
    switch (content) {
        .string => |value| try writer.writeAll(value),
        .blocks => |blocks| for (blocks, 0..) |block, index| {
            if (index > 0) try writer.writeAll("\n");
            switch (block) {
                .text => |text_content| try writer.writeAll(text_content.text),
                .image => |image| try writer.print("[image:{s}:{d}]", .{ image.mime_type, image.data.len }),
            }
        },
    }
}

fn writeAssistantContent(writer: *std.Io.Writer, content: []const protocol.AssistantContent) !void {
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll("\n");
        switch (block) {
            .text => |text_content| try writer.writeAll(text_content.text),
            .thinking => |thinking_content| try writer.writeAll(thinking_content.thinking),
            .tool_call => |call| {
                try writer.print("{s}:", .{call.name});
                try writer.print("{f}", .{std.json.fmt(call.arguments, .{})});
            },
        }
    }
}

fn writeToolResultContent(writer: *std.Io.Writer, content: protocol.ToolResultContent) !void {
    switch (content) {
        .text => |text_content| try writer.writeAll(text_content.text),
        .image => |image| try writer.print("[image:{s}:{d}]", .{ image.mime_type, image.data.len }),
    }
}

fn writeToolsJson(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    tools: []const protocol.Tool,
) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();
    var array: std.json.Array = .init(arena_allocator);
    for (tools) |tool| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena_allocator, "name", .{ .string = tool.name });
        try object.put(arena_allocator, "description", .{ .string = tool.description });
        try object.put(arena_allocator, "parameters", tool.parameters);
        try array.append(.{ .object = object });
    }
    const value: std.json.Value = .{ .array = array };
    try writer.print("{f}", .{std.json.fmt(value, .{})});
}

fn commonPrefixLength(a: []const u8, b: []const u8) usize {
    const len = @min(a.len, b.len);
    var index: usize = 0;
    while (index < len and a[index] == b[index]) index += 1;
    return index;
}

fn estimateContextTokens(context: protocol.Context) u64 {
    var chars: usize = 0;
    if (context.system_prompt) |prompt| chars += prompt.len;
    for (context.messages) |message| chars += estimateMessageChars(message);
    if (context.tools) |tools| chars += tools.len * 16;
    return estimateTokens(chars);
}

fn estimateMessageChars(message: protocol.Message) usize {
    return switch (message) {
        .user => |user| switch (user.content) {
            .string => |value| value.len,
            .blocks => |blocks| blocks.len * 16,
        },
        .assistant => |assistant| estimateAssistantChars(assistant),
        .tool_result => |tool_result| tool_result.tool_name.len + tool_result.content.len * 16,
    };
}

fn estimateAssistantTokens(message: protocol.AssistantMessage) u64 {
    return estimateTokens(estimateAssistantChars(message));
}

fn estimateAssistantChars(message: protocol.AssistantMessage) usize {
    var chars: usize = 0;
    for (message.content) |block| switch (block) {
        .text => |content| chars += content.text.len,
        .thinking => |content| chars += content.thinking.len,
        .tool_call => |call| chars += call.name.len + 8,
    };
    return chars;
}

fn estimateTokens(chars: usize) u64 {
    return @intCast((chars + 3) / 4);
}

test "faux provider streams queued text response" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    const message = assistantMessage(&.{text("hello world")}, .{});
    try provider.setResponses(&.{message});
    var stream = registry.get(provider.api).?.stream.call(testRequest(zio_runtime, provider.getModel()));

    try std.testing.expectEqual(@as(usize, 1), provider.call_count);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
    const start_event = (try stream.next(std.Io.failing)).?.start;
    try std.testing.expectEqual(@as(usize, 0), start_event.partial.content.len);
    const text_start_event = (try stream.next(std.Io.failing)).?.text_start;
    try std.testing.expectEqualStrings("", text_start_event.partial.content[0].text.text);
    const text_delta_event = (try stream.next(std.Io.failing)).?.text_delta;
    try std.testing.expectEqualStrings("hello world", text_delta_event.partial.content[0].text.text);
    try std.testing.expect((try stream.next(std.Io.failing)).? == .text_end);
    const done = (try stream.next(std.Io.failing)).?.done;
    try std.testing.expectEqual(protocol.StopReason.stop, done.message.stop_reason);
}

test "faux provider streams tool call argument deltas" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    const message = assistantMessage(&.{toolCall("tool-1", "echo", .{ .object = .empty })}, .{});
    try provider.setResponses(&.{message});
    var stream = registry.get(provider.api).?.stream.call(testRequest(zio_runtime, provider.getModel()));

    _ = try stream.next(std.Io.failing);
    const start = (try stream.next(std.Io.failing)).?.toolcall_start;
    try std.testing.expect(start.partial.content[0].tool_call.arguments == .object);
    try std.testing.expectEqual(@as(usize, 0), start.partial.content[0].tool_call.arguments.object.count());
    const delta = (try stream.next(std.Io.failing)).?.toolcall_delta;
    try std.testing.expectEqualStrings("{}", delta.delta);
    const end = (try stream.next(std.Io.failing)).?.toolcall_end;
    try std.testing.expectEqualStrings("echo", end.partial.content[0].tool_call.name);
}

test "faux provider returns terminal error when queue is empty" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    var stream = registry.get(provider.api).?.stream.call(testRequest(zio_runtime, provider.getModel()));

    const event = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.ErrorReason.error_, event.reason);
    try std.testing.expectEqual(protocol.StopReason.error_, stream.result().?.stop_reason);
}

test "faux provider supports custom model definitions" {
    var provider = try Provider.init(std.testing.allocator, .{ .models = &.{.{ .id = "faux-custom" }} });
    defer provider.deinit();

    try std.testing.expectEqualStrings("faux-custom", provider.getModel().id);
    try std.testing.expect(provider.findModel("faux-custom") != null);
}

test "faux provider response factory receives call state" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    try provider.appendFactory(.{ .call_fn = testFactory });
    var stream = registry.get(provider.api).?.stream.call(testRequest(zio_runtime, provider.getModel()));

    _ = try stream.next(std.Io.failing);
    _ = try stream.next(std.Io.failing);
    const delta = (try stream.next(std.Io.failing)).?.text_delta;
    try std.testing.expectEqualStrings("call:1", delta.delta);
}

test "faux provider prompt cache accounts common prefix" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);
    const message = assistantMessage(&.{text("ok")}, .{});
    try provider.setResponses(&.{ message, message });
    const first_request = testRequestWithSession(zio_runtime, provider.getModel(), "s1");
    var first = registry.get(provider.api).?.stream.call(first_request);
    while (try first.next(std.Io.failing)) |_| {}
    const second_request = testRequestWithSession(zio_runtime, provider.getModel(), "s1");
    var second = registry.get(provider.api).?.stream.call(second_request);
    while (try second.next(std.Io.failing)) |_| {}

    try std.testing.expect(first.result().?.usage.cache_write > 0);
    try std.testing.expect(second.result().?.usage.cache_read > 0);
}

test "faux provider supports helper blocks for text thinking and tool calls" {
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    var arguments = try jsonObjectWithString(std.testing.allocator, "text", "hi");
    defer arguments.deinit(std.testing.allocator);
    const content = [_]protocol.AssistantContent{
        thinking("think"),
        toolCall("tool-1", "echo", .{ .object = arguments }),
        text("done"),
    };
    const message = assistantMessage(&content, .{ .stop_reason = .tool_use });
    try provider.setResponses(&.{message});
    const response = try completeProvider(&provider, provider.getModel());

    try std.testing.expectEqual(protocol.StopReason.tool_use, response.stop_reason);
    try std.testing.expectEqualStrings("think", response.content[0].thinking.thinking);
    try std.testing.expectEqualStrings("echo", response.content[1].tool_call.name);
    try std.testing.expectEqualStrings("hi", response.content[1].tool_call.arguments.object.get("text").?.string);
    try std.testing.expectEqualStrings("done", response.content[2].text.text);
}

test "faux provider supports multiple models and model-aware factories" {
    var provider = try Provider.init(std.testing.allocator, .{ .models = &.{
        .{ .id = "faux-fast", .name = "Faux Fast", .reasoning = false },
        .{ .id = "faux-thinker", .name = "Faux Thinker", .reasoning = true },
    } });
    defer provider.deinit();
    try provider.appendFactory(.{ .call_fn = modelAwareFactory });
    try provider.appendFactory(.{ .call_fn = modelAwareFactory });
    const fast = try completeProvider(&provider, provider.findModel("faux-fast").?);
    const thinker = try completeProvider(&provider, provider.findModel("faux-thinker").?);

    try std.testing.expectEqualStrings("faux-fast:false", fast.content[0].text.text);
    try std.testing.expectEqualStrings("faux-thinker:true", thinker.content[0].text.text);
}

test "faux provider rewrites api provider and model on returned messages" {
    var provider = try Provider.init(std.testing.allocator, .{
        .api = "faux:test",
        .provider = "faux-provider",
        .models = &.{.{ .id = "faux-model" }},
    });
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{text("hello")}, .{})});
    const response = try completeProvider(&provider, provider.getModel());

    try std.testing.expectEqualStrings("faux:test", response.api);
    try std.testing.expectEqualStrings("faux-provider", response.provider);
    try std.testing.expectEqualStrings("faux-model", response.model);
}

test "faux provider consumes queued responses in order and errors when exhausted" {
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{
        assistantMessage(&.{text("first")}, .{}),
        assistantMessage(&.{text("second")}, .{}),
    });
    const first = try completeProvider(&provider, provider.getModel());
    const second = try completeProvider(&provider, provider.getModel());
    const exhausted = try completeProvider(&provider, provider.getModel());

    try std.testing.expectEqualStrings("first", first.content[0].text.text);
    try std.testing.expectEqualStrings("second", second.content[0].text.text);
    try std.testing.expectEqual(protocol.StopReason.error_, exhausted.stop_reason);
    try std.testing.expectEqualStrings("No more faux responses queued", exhausted.error_message.?);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
    try std.testing.expectEqual(@as(usize, 3), provider.call_count);
}

test "faux provider can replace and append queued responses" {
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{text("first")}, .{})});
    const first = try completeProvider(&provider, provider.getModel());
    try std.testing.expectEqualStrings("first", first.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());

    try provider.setResponses(&.{assistantMessage(&.{text("second")}, .{})});
    try std.testing.expectEqual(@as(usize, 1), provider.pendingResponseCount());
    const second = try completeProvider(&provider, provider.getModel());
    try std.testing.expectEqualStrings("second", second.content[0].text.text);

    try provider.appendResponses(&.{
        assistantMessage(&.{text("third")}, .{}),
        assistantMessage(&.{text("fourth")}, .{}),
    });
    try std.testing.expectEqual(@as(usize, 2), provider.pendingResponseCount());
    const third = try completeProvider(&provider, provider.getModel());
    const fourth = try completeProvider(&provider, provider.getModel());
    try std.testing.expectEqualStrings("third", third.content[0].text.text);
    try std.testing.expectEqualStrings("fourth", fourth.content[0].text.text);
    try std.testing.expectEqual(@as(usize, 0), provider.pendingResponseCount());
}

test "faux provider emits an error when a response factory fails" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.appendFactory(.{ .call_fn = failingFactory });
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, provider.getModel()));

    const event = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.ErrorReason.error_, event.reason);
    try std.testing.expectEqual(protocol.StopReason.error_, event.@"error".stop_reason);
    try std.testing.expectEqualStrings("Boom", event.@"error".error_message.?);
}

test "faux provider estimates prompt and output tokens from serialized context" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{text("done")}, .{})});
    const prior = assistantMessage(&.{text("prior")}, .{});
    const tool_content = [_]protocol.ToolResultContent{.{ .text = .{ .text = "tool out" } }};
    const messages = [_]protocol.Message{
        .{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 1 } },
        .{ .assistant = prior },
        .{ .tool_result = .{
            .tool_call_id = "tool-1",
            .tool_name = "echo",
            .content = &tool_content,
            .is_error = false,
            .timestamp = 2,
        } },
    };
    var request = testRequest(zio_runtime, provider.getModel());
    request.context = .{ .system_prompt = "sys", .messages = &messages };

    var stream = provider.apiProvider().stream.call(request);
    while (try stream.next(std.Io.failing)) |_| {}
    const response = stream.result().?;

    const prompt_text = "system:sys\n\nuser:hello\n\nassistant:prior\n\ntoolResult:echo\ntool out";
    try std.testing.expectEqual(estimateTokens(prompt_text.len), response.usage.input);
    try std.testing.expectEqual(estimateTokens("done".len), response.usage.output);
    try std.testing.expectEqual(@as(u64, 0), response.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 0), response.usage.cache_write);
    try std.testing.expectEqual(response.usage.input + response.usage.output, response.usage.total_tokens);
}

test "faux provider does not share cache across sessions or requests without session id" {
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{
        assistantMessage(&.{text("first")}, .{}),
        assistantMessage(&.{text("second")}, .{}),
        assistantMessage(&.{text("third")}, .{}),
    });
    const first = try completeWithSession(&provider, "session-1", .short);
    const second = try completeWithSession(&provider, "session-2", .short);
    const third = try completeProvider(&provider, provider.getModel());

    try std.testing.expect(first.usage.cache_write > 0);
    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_read);
    try std.testing.expect(second.usage.cache_write > 0);
    try std.testing.expectEqual(@as(u64, 0), third.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 0), third.usage.cache_write);
}

test "faux provider does not simulate caching when cache retention is none" {
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{
        assistantMessage(&.{text("first")}, .{}),
        assistantMessage(&.{text("second")}, .{}),
    });
    _ = try completeWithSession(&provider, "session-1", .none);
    const second = try completeWithSession(&provider, "session-1", .none);

    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_read);
    try std.testing.expectEqual(@as(u64, 0), second.usage.cache_write);
}

test "faux provider streams exact event order for fixed-size chunks" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{ .min_token_size = 1, .max_token_size = 1 });
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{
        thinking("go"),
        text("ok"),
        toolCall("tool-1", "echo", .{ .object = .empty }),
    }, .{ .stop_reason = .tool_use })});
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, provider.getModel()));

    const expected = [_]std.meta.Tag(protocol.AssistantMessageEvent){
        .start,
        .thinking_start,
        .thinking_delta,
        .thinking_end,
        .text_start,
        .text_delta,
        .text_end,
        .toolcall_start,
        .toolcall_delta,
        .toolcall_end,
        .done,
    };
    for (expected) |tag| try std.testing.expectEqual(tag, std.meta.activeTag((try stream.next(std.Io.failing)).?));
    try std.testing.expectEqual(@as(?protocol.AssistantMessageEvent, null), try stream.next(std.Io.failing));
}

test "faux provider streams multiple tool calls in one message" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{
        toolCall("tool-1", "echo", .{ .object = .empty }),
        toolCall("tool-2", "echo", .{ .object = .empty }),
    }, .{ .stop_reason = .tool_use })});
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, provider.getModel()));
    var start_count: usize = 0;
    var end_count: usize = 0;

    while (try stream.next(std.Io.failing)) |event| switch (event) {
        .toolcall_start => start_count += 1,
        .toolcall_end => end_count += 1,
        else => {},
    };

    try std.testing.expectEqual(@as(usize, 2), start_count);
    try std.testing.expectEqual(@as(usize, 2), end_count);
}

test "faux provider streams explicit assistant error as terminal error" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{text("partial")}, .{
        .stop_reason = .error_,
        .error_message = "upstream failed",
    })});
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, provider.getModel()));

    while (try stream.next(std.Io.failing)) |event| {
        if (event == .@"error") {
            try std.testing.expectEqual(protocol.ErrorReason.error_, event.@"error".reason);
            try std.testing.expectEqual(protocol.StopReason.error_, event.@"error".@"error".stop_reason);
            try std.testing.expectEqualStrings("upstream failed", event.@"error".@"error".error_message.?);
            return;
        }
    }
    return error.MissingResult;
}

test "faux provider streams explicit assistant aborted as terminal error" {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.setResponses(&.{assistantMessage(&.{text("partial")}, .{
        .stop_reason = .aborted,
        .error_message = "Request was aborted",
    })});
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, provider.getModel()));

    while (try stream.next(std.Io.failing)) |event| {
        if (event == .@"error") {
            try std.testing.expectEqual(protocol.ErrorReason.aborted, event.@"error".reason);
            try std.testing.expectEqual(protocol.StopReason.aborted, event.@"error".@"error".stop_reason);
            try std.testing.expectEqualStrings("Request was aborted", event.@"error".@"error".error_message.?);
            return;
        }
    }
    return error.MissingResult;
}

test "faux provider unregister removes provider from registry" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = try Provider.init(std.testing.allocator, .{});
    defer provider.deinit();
    try provider.register(&registry);

    provider.unregister(&registry);

    try std.testing.expectEqual(@as(?provider_registry.ApiProvider, null), registry.get(provider.api));
}

const factory_first_content = [_]protocol.AssistantContent{text("call:1")};
const factory_later_content = [_]protocol.AssistantContent{text("call:many")};

fn testFactory(_: ?*anyopaque, _: protocol.StreamRequest, state: *const State) FactoryError!protocol.AssistantMessage {
    const content = if (state.call_count == 1) &factory_first_content else &factory_later_content;
    return assistantMessage(content, .{});
}

fn modelAwareFactory(
    _: ?*anyopaque,
    request: protocol.StreamRequest,
    _: *const State,
) FactoryError!protocol.AssistantMessage {
    const content = if (request.model.reasoning) &model_thinker_content else &model_fast_content;
    return assistantMessage(content, .{});
}

fn failingFactory(
    _: ?*anyopaque,
    _: protocol.StreamRequest,
    _: *const State,
) FactoryError!protocol.AssistantMessage {
    return error.Boom;
}

const model_fast_content = [_]protocol.AssistantContent{text("faux-fast:false")};
const model_thinker_content = [_]protocol.AssistantContent{text("faux-thinker:true")};

fn completeProvider(
    provider: *Provider,
    model: protocol.Model,
) !protocol.AssistantMessage {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var stream = provider.apiProvider().stream.call(testRequest(zio_runtime, model));
    while (try stream.next(std.Io.failing)) |_| {}
    return stream.result() orelse error.MissingResult;
}

fn completeWithSession(
    provider: *Provider,
    session_id: []const u8,
    cache_retention: protocol.CacheRetention,
) !protocol.AssistantMessage {
    var zio_runtime = try mem.Runtime.init(std.testing.allocator, .{});
    defer zio_runtime.deinit();
    var request = testRequestWithSession(zio_runtime, provider.getModel(), session_id);
    request.options.cache_retention = cache_retention;
    var stream = provider.apiProvider().stream.call(request);
    while (try stream.next(std.Io.failing)) |_| {}
    return stream.result() orelse error.MissingResult;
}

fn jsonObjectWithString(
    allocator: std.mem.Allocator,
    key: []const u8,
    value: []const u8,
) !std.json.ObjectMap {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    try object.put(allocator, key, .{ .string = value });
    return object;
}

fn testRequest(zio_runtime: *mem.Runtime, model: protocol.Model) protocol.StreamRequest {
    return .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .zio_runtime = zio_runtime,
        .model = model,
        .context = .{ .messages = &.{.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }} },
    };
}

fn testRequestWithSession(
    zio_runtime: *mem.Runtime,
    model: protocol.Model,
    session_id: []const u8,
) protocol.StreamRequest {
    var request = testRequest(zio_runtime, model);
    request.options.session_id = session_id;
    return request;
}
