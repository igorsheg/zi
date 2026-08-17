const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model_api = @import("../model.zig");
const openai_chat = @import("../protocol/openai_chat.zig");
const provider_api = @import("../provider.zig");
const settings = @import("../settings.zig");
const transport_api = @import("../transport.zig");

pub const Config = struct {
    provider_id: []const u8 = "openai-compatible",
    model_id: []const u8,
    display_name: ?[]const u8 = null,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    headers: []const transport_api.Header = &.{},
    profile: settings.ModelProfile = defaultProfile(),
};

pub const OpenAiCompatible = struct {
    transport: transport_api.Transport,
    config: Config,

    pub fn init(transport: transport_api.Transport, config: Config) OpenAiCompatible {
        return .{ .transport = transport, .config = config };
    }

    pub fn provider(self: *OpenAiCompatible) provider_api.Provider {
        return provider_api.Provider.from(self, self.config.provider_id);
    }

    pub fn model(self: *OpenAiCompatible, model_id: []const u8) ?model_api.Model {
        if (!std.mem.eql(u8, model_id, self.config.model_id)) return null;
        return self.modelView();
    }

    pub fn modelView(self: *OpenAiCompatible) model_api.Model {
        return model_api.Model.from(self, .{
            .provider = self.config.provider_id,
            .model = self.config.model_id,
        }, self.config.profile);
    }

    pub fn models(
        self: *OpenAiCompatible,
        allocator: std.mem.Allocator,
    ) provider_api.ProviderError!provider_api.OwnedModelList {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const items = arena.allocator().alloc(provider_api.ModelDescriptor, 1) catch return error.OutOfMemory;
        items[0] = .{
            .id = arena.allocator().dupe(u8, self.config.model_id) catch return error.OutOfMemory,
            .display_name = if (self.config.display_name) |name|
                arena.allocator().dupe(u8, name) catch return error.OutOfMemory
            else
                null,
            .profile = self.config.profile,
        };
        return .{ .arena = arena, .items = items };
    }

    pub fn invoke(
        self: *OpenAiCompatible,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) failure.ModelError!message.ResponseMessage {
        try request.validateHandoff(self.config.provider_id, null);
        const streaming = switch (delivery) {
            .buffered => false,
            .streaming => true,
        };
        const body = try openai_chat.encodeRequest(scratch_allocator, self.config.model_id, request, streaming);
        defer scratch_allocator.free(body);
        const url = try endpointUrl(scratch_allocator, self.config.base_url);
        defer scratch_allocator.free(url);
        const authorization = if (self.config.api_key) |key|
            std.fmt.allocPrint(scratch_allocator, "Bearer {s}", .{key}) catch return error.OutOfMemory
        else
            null;
        defer if (authorization) |value| scratch_allocator.free(value);
        var headers: std.ArrayList(transport_api.Header) = .empty;
        defer headers.deinit(scratch_allocator);
        headers.append(scratch_allocator, .{
            .name = "accept",
            .value = if (streaming) "text/event-stream" else "application/json",
        }) catch return error.OutOfMemory;
        if (authorization) |value| headers.append(scratch_allocator, .{
            .name = "authorization",
            .value = value,
        }) catch return error.OutOfMemory;
        headers.appendSlice(scratch_allocator, self.config.headers) catch return error.OutOfMemory;

        const identity: message.ModelIdentity = .{
            .provider = self.config.provider_id,
            .model = self.config.model_id,
        };
        const transport_request: transport_api.Request = .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .deadline = request.deadline,
            .cancellation = request.cancellation,
        };

        return switch (delivery) {
            .buffered => complete: {
                const response = self.transport.exchange(
                    scratch_allocator,
                    io,
                    transport_request,
                    .buffered,
                ) catch |transport_failure| {
                    return mapTransportError(transport_failure);
                };
                defer if (response.body.len > 0) scratch_allocator.free(response.body);
                if (response.status < 200 or response.status >= 300) {
                    observeFailure(request.failure_sink, identity, response.status, response.body);
                    return statusError(response.status);
                }
                break :complete openai_chat.decodeResponse(result_allocator, identity, response.body);
            },
            .streaming => |sink| streaming_response: {
                var decoder = openai_chat.StreamDecoder.init(
                    result_allocator,
                    scratch_allocator,
                    identity,
                    sink,
                );
                defer decoder.deinit();
                _ = self.transport.exchange(
                    scratch_allocator,
                    io,
                    transport_request,
                    .{ .streaming = decoder.bodySink() },
                ) catch |transport_failure| {
                    if (decoder.failure_value) |decode_failure| return decode_failure;
                    return mapTransportError(transport_failure);
                };
                if (decoder.status < 200 or decoder.status >= 300) {
                    observeFailure(request.failure_sink, identity, decoder.status, decoder.error_body.items);
                }
                break :streaming_response decoder.result();
            },
        };
    }
};

pub fn defaultProfile() settings.ModelProfile {
    var profile: settings.ModelProfile = .{};
    profile.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls, .thinking });
    profile.settings = .initMany(&.{ .temperature, .top_p, .max_output_tokens, .stop_sequences, .seed });
    return profile;
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) failure.ModelError![]const u8 {
    const base = std.mem.trim(u8, base_url, " \t\r\n/");
    if (base.len == 0) return error.InvalidRequest;
    if (std.mem.endsWith(u8, base, "/chat/completions")) {
        return allocator.dupe(u8, base) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base}) catch return error.OutOfMemory;
}

fn observeFailure(
    sink: ?failure.FailureSink,
    identity: message.ModelIdentity,
    status: u16,
    body: []const u8,
) void {
    const observer = sink orelse return;
    observer.observe(.{
        .provider = identity.provider,
        .status = status,
        .message = body[0..@min(body.len, 2048)],
    });
}

fn statusError(status: u16) failure.ModelError {
    return switch (status) {
        401, 403 => error.ProviderRejectedRequest,
        429 => error.RateLimited,
        500, 502, 503, 504 => error.ProviderUnavailable,
        else => error.ProviderRejectedRequest,
    };
}

fn mapTransportError(value: transport_api.Error) failure.ModelError {
    return switch (value) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.TimedOut => error.TimedOut,
        error.InvalidUrl => error.InvalidRequest,
        error.ConnectionFailed => error.ConnectionFailed,
        error.InvalidResponse, error.ResponseTooLarge => error.InvalidProviderResponse,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}
