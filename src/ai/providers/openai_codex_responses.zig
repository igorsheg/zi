const std = @import("std");
const oauth_openai_codex = @import("../utils/oauth/openai_codex.zig");
const protocol = @import("../protocol.zig");
const provider_registry = @import("../provider_registry.zig");
const runtime = @import("../../runtime/root.zig");
const sse = @import("../sse.zig");
const shared = @import("openai_responses_shared.zig");
const simple_options = @import("simple_options.zig");
const transform_messages = @import("transform_messages.zig");

pub const source_id = "openai-codex-responses-provider";

const default_codex_base_url = "https://chatgpt.com/backend-api";
const read_buffer_len = 8192;
const redirect_buffer_len = 0;
const max_error_body_bytes = 16 * 1024;
const default_retry_count_max: u32 = 3;
const hard_retry_count_max: u32 = 5;
const default_retry_delay_ms: u64 = 1000;
const hard_retry_delay_ms: u64 = 8000;

pub const Options = struct {};

pub const Provider = struct {
    options: Options = .{},

    pub fn init(options: Options) Provider {
        return .{ .options = options };
    }

    pub fn register(self: *Provider, registry: *provider_registry.ProviderRegistry) !void {
        try registry.register(self.apiProvider(), source_id);
    }

    pub fn unregister(_: *Provider, registry: *provider_registry.ProviderRegistry) void {
        registry.unregisterSource(source_id);
    }

    pub fn apiProvider(self: *Provider) provider_registry.ApiProvider {
        return .{
            .api = protocol.KnownApi.openai_codex_responses,
            .stream = .{ .context = self, .call_fn = streamFunction },
            .stream_simple = .{ .context = self, .call_fn = streamSimpleFunction },
        };
    }
};

fn streamSimpleFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const self: *Provider = @ptrCast(@alignCast(context.?));
    var normalized = request;
    normalized.options = simple_options.buildBaseOptions(
        request.model,
        .{ .stream = request.options },
        resolveApiKey(request),
    );
    return streamFunction(self, normalized);
}

fn streamFunction(context: ?*anyopaque, request: protocol.StreamRequest) protocol.AssistantMessageEventStream {
    const self: *Provider = @ptrCast(@alignCast(context.?));
    var stream = protocol.AssistantMessageEventStream.init(request.event_buffer);
    const sink = stream.sink();

    run(self, request, sink) catch |err| {
        if (err == error.ErrorEmitted) return stream;
        if (err == error.OperationCancelled or err == error.Canceled) {
            const message = protocol.emptyAssistantMessageFromRequest(request, .aborted, "Request was aborted");
            sink.endAborted(request.io, message) catch return stream;
            return stream;
        }
        const message = protocol.emptyAssistantMessageFromRequest(request, .error_, @errorName(err));
        sink.endError(request.io, .error_, message) catch return stream;
    };

    return stream;
}

fn run(self: *Provider, request: protocol.StreamRequest, sink: protocol.AssistantMessageEventSink) !void {
    _ = self;
    const api_key = request.options.api_key orelse resolveApiKey(request) orelse return error.MissingApiKey;
    const account_id = try oauth_openai_codex.getAccountId(
        request.allocator,
        api_key,
    ) orelse return error.MissingAccountId;
    defer request.allocator.free(account_id);
    const body = try buildRequestBody(request.allocator, request);
    defer request.allocator.free(body);

    try requestWithRetries(request, sink, api_key, account_id, body);
}

fn requestWithRetries(
    request: protocol.StreamRequest,
    sink: protocol.AssistantMessageEventSink,
    api_key: []const u8,
    account_id: []const u8,
    body: []const u8,
) !void {
    const retry_count_max = boundedRetryCount(request.options.max_retries);
    var attempt: u32 = 0;
    var last_error: ?anyerror = null;
    while (attempt <= retry_count_max) : (attempt += 1) {
        requestOnce(request, sink, api_key, account_id, body) catch |err| switch (err) {
            error.ErrorEmitted => return error.ErrorEmitted,
            error.RetryableRequestFailed => {
                last_error = err;
                if (attempt == retry_count_max) return err;
                try runtime.sleep(
                    request.io,
                    retryDelay(attempt, request.options.max_retry_delay_ms),
                    request.cancel_token,
                );
                continue;
            },
            else => |other| {
                last_error = other;
                if (attempt == retry_count_max or !isRetryableTransportError(other)) return other;
                try runtime.sleep(
                    request.io,
                    retryDelay(attempt, request.options.max_retry_delay_ms),
                    request.cancel_token,
                );
                continue;
            },
        };
        return;
    }
    return last_error orelse error.RetryableRequestFailed;
}

fn requestOnce(
    request: protocol.StreamRequest,
    sink: protocol.AssistantMessageEventSink,
    api_key: []const u8,
    account_id: []const u8,
    body: []const u8,
) !void {
    var reducer = shared.ResponseStreamReducer.init(request.allocator, request.model, 0);
    defer reducer.deinit();

    var client: std.http.Client = .{ .allocator = request.allocator };
    defer client.deinit();
    const url = try endpointUrl(request.allocator, request.model.base_url);
    defer request.allocator.free(url);
    const uri = try std.Uri.parse(url);
    const headers = [_]std.http.Header{
        .{ .name = "Authorization", .value = try authorizationHeader(request.allocator, api_key) },
        .{ .name = "chatgpt-account-id", .value = account_id },
        .{ .name = "originator", .value = "zi" },
        .{ .name = "OpenAI-Beta", .value = "responses=experimental" },
        .{ .name = "Accept", .value = "text/event-stream" },
    };
    defer request.allocator.free(headers[0].value);

    var req = try client.request(.POST, uri, .{
        .extra_headers = &headers,
        .headers = .{ .content_type = .{ .override = "application/json" }, .accept_encoding = .omit },
        .redirect_behavior = .unhandled,
        .keep_alive = false,
    });
    defer req.deinit();

    req.transfer_encoding = .{ .content_length = body.len };
    var body_writer = try req.sendBodyUnflushed(&.{});
    try body_writer.writer.writeAll(body);
    try body_writer.end();
    try req.connection.?.flush();

    var redirects: [redirect_buffer_len]u8 = .{};
    var response = try req.receiveHead(&redirects);
    var transfer_buffer: [read_buffer_len]u8 = undefined;
    const reader = response.reader(&transfer_buffer);
    if (response.head.status != .ok) {
        const detail = readErrorBody(request.allocator, reader) catch try std.fmt.allocPrint(
            request.allocator,
            "HTTP {s}",
            .{@tagName(response.head.status)},
        );
        defer request.allocator.free(detail);
        if (isRetryableStatus(response.head.status) or isRetryableErrorText(detail)) {
            return error.RetryableRequestFailed;
        }
        var message = protocol.emptyAssistantMessageFromRequest(request, .error_, detail);
        message.stop_reason = .error_;
        try sink.endError(request.io, .error_, message);
        return error.ErrorEmitted;
    }

    try sink.emit(request.io, .{ .start = .{ .partial = try reducer.partial() } });
    var parser = sse.Parser.init(request.allocator, .{});
    defer parser.deinit();
    var parser_sink: ReducerSseSink = .{ .io = request.io, .assistant_sink = sink, .reducer = &reducer };

    while (true) {
        var chunk: [read_buffer_len]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&chunk);
        const n = reader.stream(&writer, .limited(chunk.len)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try parser.feed(chunk[0..n], &parser_sink);
    }

    try parser.finish(&parser_sink);
    try reducer.finish(request.io, sink);
}

fn boundedRetryCount(value: ?u32) u32 {
    return @min(value orelse default_retry_count_max, hard_retry_count_max);
}

fn retryDelay(attempt: u32, max_delay_ms: ?u64) std.Io.Duration {
    const ceiling = @min(max_delay_ms orelse hard_retry_delay_ms, hard_retry_delay_ms);
    const multiplier = std.math.shl(u64, 1, @min(attempt, 8));
    const delay_ms = @min(default_retry_delay_ms *| multiplier, ceiling);
    return .fromMilliseconds(delay_ms);
}

fn isRetryableStatus(status: std.http.Status) bool {
    return status == .too_many_requests or status == .internal_server_error or status == .bad_gateway or
        status == .service_unavailable or status == .gateway_timeout;
}

fn isRetryableErrorText(text: []const u8) bool {
    return containsIgnoreCase(text, "rate limit") or containsIgnoreCase(text, "ratelimit") or
        containsIgnoreCase(text, "overloaded") or containsIgnoreCase(text, "service unavailable") or
        containsIgnoreCase(text, "upstream connect") or containsIgnoreCase(text, "connection refused");
}

fn isRetryableTransportError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionResetByPeer,
        error.ConnectionTimedOut,
        error.TemporaryNameServerFailure,
        error.NetworkUnreachable,
        error.HostLacksNetworkAddresses,
        => true,
        else => false,
    };
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

const ReducerSseSink = struct {
    io: std.Io,
    assistant_sink: protocol.AssistantMessageEventSink,
    reducer: *shared.ResponseStreamReducer,

    fn emit(self: *ReducerSseSink, event: sse.Event) !void {
        try self.reducer.applySseData(self.io, self.assistant_sink, event.data);
    }
};

fn readErrorBody(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    var body = std.Io.Writer.Allocating.init(allocator);
    errdefer body.deinit();
    while (body.written().len < max_error_body_bytes) {
        var chunk: [1024]u8 = undefined;
        var writer: std.Io.Writer = .fixed(&chunk);
        const remaining = @min(chunk.len, max_error_body_bytes - body.written().len);
        const n = reader.stream(&writer, .limited(remaining)) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) continue;
        try body.writer.writeAll(chunk[0..n]);
    }
    if (body.written().len == 0) return allocator.dupe(u8, "HTTP request failed");
    return body.toOwnedSlice();
}

fn resolveApiKey(request: protocol.StreamRequest) ?[]const u8 {
    if (request.options.api_key) |api_key| if (api_key.len > 0) return api_key;
    return null;
}

fn authorizationHeader(allocator: std.mem.Allocator, api_key: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "Bearer {s}", .{api_key});
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    const raw = std.mem.trim(u8, if (base_url.len > 0) base_url else default_codex_base_url, " \t\r\n/");
    if (std.mem.endsWith(u8, raw, "/codex/responses")) return allocator.dupe(u8, raw);
    if (std.mem.endsWith(u8, raw, "/codex")) return std.fmt.allocPrint(allocator, "{s}/responses", .{raw});
    return std.fmt.allocPrint(allocator, "{s}/codex/responses", .{raw});
}

fn buildRequestBody(allocator: std.mem.Allocator, request: protocol.StreamRequest) ![]const u8 {
    var transformed = try transform_messages.transformMessages(
        allocator,
        request.context.messages,
        request.model,
        null,
    );
    defer transformed.deinit();
    const transformed_context: protocol.Context = .{
        .system_prompt = request.context.system_prompt,
        .messages = transformed.messages,
        .tools = request.context.tools,
    };

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("{\"model\":");
    try std.json.Stringify.value(request.model.id, .{}, writer);
    try writer.writeAll(",\"stream\":true,\"store\":false");
    if (transformed_context.system_prompt) |system_prompt| {
        try writer.writeAll(",\"instructions\":");
        try std.json.Stringify.value(system_prompt, .{}, writer);
    }
    try writer.writeAll(",\"input\":[");
    try writeInputMessages(allocator, writer, transformed_context);
    try writer.writeByte(']');
    try writer.writeAll(",\"text\":{\"verbosity\":\"low\"}");
    try writer.writeAll(",\"include\":[\"reasoning.encrypted_content\"]");
    try writer.writeAll(",\"tool_choice\":\"auto\",\"parallel_tool_calls\":true");
    if (request.options.max_tokens) |max_tokens| try writer.print(",\"max_output_tokens\":{}", .{max_tokens});
    if (request.options.temperature) |temperature| try writer.print(",\"temperature\":{d}", .{temperature});
    if (request.options.session_id) |session_id| {
        if (request.options.cache_retention != .none) {
            try writer.writeAll(",\"prompt_cache_key\":");
            try std.json.Stringify.value(session_id, .{}, writer);
        }
    }
    if (request.context.tools) |tools| if (tools.len > 0) {
        try writer.writeAll(",\"tools\":[");
        for (tools, 0..) |tool, index| {
            if (index > 0) try writer.writeByte(',');
            try writer.writeAll("{\"type\":\"function\",\"name\":");
            try std.json.Stringify.value(tool.name, .{}, writer);
            try writer.writeAll(",\"description\":");
            try std.json.Stringify.value(tool.description, .{}, writer);
            try writer.writeAll(",\"parameters\":");
            try std.json.Stringify.value(tool.parameters, .{}, writer);
            try writer.writeByte('}');
        }
        try writer.writeByte(']');
    };
    try writer.writeByte('}');
    return out.toOwnedSlice();
}

fn writeInputMessages(allocator: std.mem.Allocator, writer: *std.Io.Writer, context: protocol.Context) !void {
    var wrote = false;
    for (context.messages) |message| {
        switch (message) {
            .user => |user| switch (user.content) {
                .string => |text| try writeRoleTextMessage(writer, "user", text, &wrote),
                .blocks => |blocks| for (blocks) |block| switch (block) {
                    .text => |text| try writeRoleTextMessage(writer, "user", text.text, &wrote),
                    .image => |image| try writeRoleImageMessage(writer, "user", image, &wrote),
                },
            },
            .assistant => |assistant| for (assistant.content) |block| switch (block) {
                .text => |text| try writeAssistantOutputText(writer, text.text, &wrote),
                .thinking => |thinking| if (thinking.thinking.len > 0) {
                    try writeAssistantOutputText(writer, thinking.thinking, &wrote);
                },
                .tool_call => |tool_call| try writeAssistantToolCall(allocator, writer, tool_call, &wrote),
            },
            .tool_result => |tool_result| try writeToolResult(allocator, writer, tool_result, &wrote),
        }
    }
}

fn writeRoleTextMessage(writer: *std.Io.Writer, role: []const u8, text: []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[{\"type\":\"input_text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll("}]}");
}

fn writeRoleImageMessage(
    writer: *std.Io.Writer,
    role: []const u8,
    image: protocol.ImageContent,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"role\":");
    try std.json.Stringify.value(role, .{}, writer);
    try writer.writeAll(",\"content\":[{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
    try writer.print("\"data:{s};base64,{s}\"", .{ image.mime_type, image.data });
    try writer.writeAll("}]}");
}

fn writeAssistantOutputText(writer: *std.Io.Writer, text: []const u8, wrote: *bool) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    try writer.writeAll("{\"type\":\"message\",\"role\":\"assistant\",\"status\":\"completed\",");
    try writer.writeAll("\"content\":[{\"type\":\"output_text\",\"text\":");
    try std.json.Stringify.value(text, .{}, writer);
    try writer.writeAll(",\"annotations\":[]}]}");
}

fn writeAssistantToolCall(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    call: protocol.ToolCall,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    const separator = std.mem.findScalar(u8, call.id, '|');
    const call_id = if (separator) |index| call.id[0..index] else call.id;
    const item_id = if (separator) |index| call.id[index + 1 ..] else null;
    try writer.writeAll("{\"type\":\"function_call\",");
    if (item_id) |id| {
        try writer.writeAll("\"id\":");
        try std.json.Stringify.value(id, .{}, writer);
        try writer.writeByte(',');
    }
    try writer.writeAll("\"call_id\":");
    try std.json.Stringify.value(call_id, .{}, writer);
    try writer.writeAll(",\"name\":");
    try std.json.Stringify.value(call.name, .{}, writer);
    try writer.writeAll(",\"arguments\":");
    var arguments = std.Io.Writer.Allocating.init(allocator);
    defer arguments.deinit();
    try std.json.Stringify.value(call.arguments, .{}, &arguments.writer);
    try std.json.Stringify.value(arguments.written(), .{}, writer);
    try writer.writeByte('}');
}

fn writeToolResult(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    result: protocol.ToolResultMessage,
    wrote: *bool,
) !void {
    if (wrote.*) try writer.writeByte(',');
    wrote.* = true;
    var text = std.Io.Writer.Allocating.init(allocator);
    defer text.deinit();
    var has_image = false;
    for (result.content) |block| switch (block) {
        .text => |text_block| {
            if (text.written().len > 0) try text.writer.writeByte('\n');
            try text.writer.writeAll(text_block.text);
        },
        .image => has_image = true,
    };
    try writer.writeAll("{\"type\":\"function_call_output\",\"call_id\":");
    try std.json.Stringify.value(result.tool_call_id, .{}, writer);
    try writer.writeAll(",\"output\":");
    if (!has_image) {
        try std.json.Stringify.value(text.written(), .{}, writer);
    } else {
        try writer.writeByte('[');
        var wrote_part = false;
        if (text.written().len > 0) {
            try writer.writeAll("{\"type\":\"input_text\",\"text\":");
            try std.json.Stringify.value(text.written(), .{}, writer);
            try writer.writeByte('}');
            wrote_part = true;
        }
        for (result.content) |block| if (block == .image) {
            if (wrote_part) try writer.writeByte(',');
            wrote_part = true;
            try writer.writeAll("{\"type\":\"input_image\",\"detail\":\"auto\",\"image_url\":");
            try writer.print("\"data:{s};base64,{s}\"", .{ block.image.mime_type, block.image.data });
            try writer.writeByte('}');
        };
        try writer.writeByte(']');
    }
    try writer.writeByte('}');
}

test "endpoint url appends codex responses path" {
    const url = try endpointUrl(std.testing.allocator, "https://chatgpt.com/backend-api");
    defer std.testing.allocator.free(url);

    try std.testing.expectEqualStrings("https://chatgpt.com/backend-api/codex/responses", url);
}

test "request body includes model stream input and tools" {
    const request = testRequest();
    const body = try buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"model\":\"gpt-test\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"stream\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"instructions\":\"system\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"input_text\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"reasoning.encrypted_content\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parallel_tool_calls\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tools\"") != null);
}

fn testRequest() protocol.StreamRequest {
    var event_buffer: [1]protocol.AssistantMessageEvent = undefined;
    _ = &event_buffer;
    return .{
        .allocator = std.testing.allocator,
        .io = std.Io.failing,
        .model = .{
            .id = "gpt-test",
            .name = "GPT Test",
            .api = protocol.KnownApi.openai_codex_responses,
            .provider = protocol.KnownProvider.openai_codex,
            .base_url = "https://chatgpt.com/backend-api",
            .reasoning = true,
            .input = &.{.text},
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
            .context_window = 1,
            .max_tokens = 1,
        },
        .context = .{
            .system_prompt = "system",
            .messages = &.{.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }},
            .tools = &.{.{ .name = "echo", .description = "Echo", .parameters = .{ .object = .empty } }},
        },
        .event_buffer = &event_buffer,
    };
}
