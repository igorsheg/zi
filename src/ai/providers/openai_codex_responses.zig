const std = @import("std");
const http_utils = @import("../utils/http.zig");
const oauth_openai_codex = @import("../utils/oauth/openai_codex.zig");
const protocol = @import("../protocol.zig");
const provider_registry = @import("../provider_registry.zig");
const runtime = @import("../../zistd/root.zig");
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
    _ = self;
    const state = createCodexResponseStream(request) catch |err| return shared.errorStream(request, err);
    return state.stream();
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

const CodexResponseOwner = struct {
    account_id: []const u8,
    authorization: []const u8,
    body: []const u8,
    url: []const u8,

    pub fn deinit(self: *CodexResponseOwner, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.body);
        allocator.free(self.authorization);
        allocator.free(self.account_id);
        self.* = undefined;
    }
};

const CodexResponseStream = shared.SsePullStream(CodexResponseOwner, .{
    .read_buffer_len = read_buffer_len,
    .redirect_buffer_len = redirect_buffer_len,
});

fn createCodexResponseStream(request: protocol.StreamRequest) !*CodexResponseStream {
    const allocator = request.allocator;
    const api_key = request.options.api_key orelse resolveApiKey(request) orelse return error.MissingApiKey;
    const account_id = try oauth_openai_codex.getAccountId(allocator, api_key) orelse return error.MissingAccountId;
    errdefer allocator.free(account_id);
    const authorization = try http_utils.bearerHeader(allocator, api_key);
    errdefer allocator.free(authorization);
    const body = try buildRequestBody(allocator, request);
    errdefer allocator.free(body);
    const url = try endpointUrl(allocator, request.model.base_url);
    errdefer allocator.free(url);

    const state = try allocator.create(CodexResponseStream);
    state.* = CodexResponseStream.init(allocator, request, .{
        .account_id = account_id,
        .authorization = authorization,
        .body = body,
        .url = url,
    });
    errdefer state.deinit();

    try openWithRetries(state);
    return state;
}

fn openWithRetries(state: *CodexResponseStream) !void {
    const retry_count_max = boundedRetryCount(state.request.options.max_retries);
    var attempt: u32 = 0;
    var last_error: ?anyerror = null;
    while (attempt <= retry_count_max) : (attempt += 1) {
        openOnce(state) catch |err| switch (err) {
            error.RetryableRequestFailed => {
                last_error = err;
                if (attempt == retry_count_max) return err;
                try runtime.sleep(state.request.io, retryDelay(attempt, state.request.options.max_retry_delay_ms), state.request.cancel_token);
                continue;
            },
            else => |other| {
                last_error = other;
                if (attempt == retry_count_max or !isRetryableTransportError(other)) return other;
                try runtime.sleep(state.request.io, retryDelay(attempt, state.request.options.max_retry_delay_ms), state.request.cancel_token);
                continue;
            },
        };
        return;
    }
    return last_error orelse error.RetryableRequestFailed;
}

fn openOnce(state: *CodexResponseStream) !void {
    const uri = try std.Uri.parse(state.owner.url);
    var headers: [7]std.http.Header = undefined;
    var header_count: usize = 0;
    headers[header_count] = .{ .name = "Authorization", .value = state.owner.authorization };
    header_count += 1;
    headers[header_count] = .{ .name = "chatgpt-account-id", .value = state.owner.account_id };
    header_count += 1;
    headers[header_count] = .{ .name = "originator", .value = "zi" };
    header_count += 1;
    headers[header_count] = .{ .name = "OpenAI-Beta", .value = "responses=experimental" };
    header_count += 1;
    headers[header_count] = .{ .name = "Accept", .value = "text/event-stream" };
    header_count += 1;
    if (state.request.options.session_id) |session_id| {
        headers[header_count] = .{ .name = "session_id", .value = session_id };
        header_count += 1;
        headers[header_count] = .{ .name = "x-client-request-id", .value = session_id };
        header_count += 1;
    }

    try state.openRequest(uri, headers[0..header_count], state.owner.body);
    if (state.response.head.status != .ok) {
        const detail = readErrorBody(state.allocator, state.reader.?) catch try std.fmt.allocPrint(
            state.allocator,
            "HTTP {s}",
            .{@tagName(state.response.head.status)},
        );
        if (isRetryableStatus(state.response.head.status) or isRetryableErrorText(detail)) {
            state.allocator.free(detail);
            return error.RetryableRequestFailed;
        }
        try state.emitError(detail);
    }
}

fn readErrorBody(allocator: std.mem.Allocator, reader: anytype) ![]const u8 {
    const body = try http_utils.readBoundedBody(allocator, reader, max_error_body_bytes);
    if (body.len > 0) return body;
    allocator.free(body);
    return allocator.dupe(u8, "HTTP request failed");
}

fn resolveApiKey(request: protocol.StreamRequest) ?[]const u8 {
    if (request.options.api_key) |api_key| if (api_key.len > 0) return api_key;
    return null;
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

test "provider registers openai codex responses api" {
    var registry = provider_registry.ProviderRegistry.init(std.testing.allocator);
    defer registry.deinit();
    var provider = Provider.init(.{});

    try provider.register(&registry);

    try std.testing.expect(registry.get(protocol.KnownApi.openai_codex_responses) != null);
}

test "provider stream without auth emits missing api key error" {
    var provider = Provider.init(.{});
    var stream = provider.apiProvider().stream.call(testRequest());

    const err = (try stream.next(std.Io.failing)).?.@"error";
    try std.testing.expectEqual(protocol.ErrorReason.error_, err.reason);
    try std.testing.expectEqualStrings("MissingApiKey", err.@"error".error_message.?);
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

test "request body follows codex contract and omits max output tokens" {
    var request = testRequest();
    request.options.max_tokens = 32_000;
    request.options.session_id = "session-123";

    const body = try buildRequestBody(std.testing.allocator, request);
    defer std.testing.allocator.free(body);

    try std.testing.expect(std.mem.indexOf(u8, body, "\"max_output_tokens\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"prompt_cache_key\":\"session-123\"") != null);
}

fn testRequest() protocol.StreamRequest {
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
    };
}
