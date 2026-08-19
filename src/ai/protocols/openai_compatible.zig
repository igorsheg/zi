const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model_api = @import("../model.zig");
const openai_chat = @import("../protocol/openai_chat.zig");
const protocol_api = @import("../protocol.zig");
const settings = @import("../settings.zig");
const transport_api = @import("../transport.zig");

pub const id = "openai-completions";

pub const OpenAiCompatible = struct {
    pub fn profile(_: *const OpenAiCompatible, _: protocol_api.ProfileHints) settings.ModelProfile {
        var value: settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls });
        value.settings = .initMany(&.{ .temperature, .top_p, .max_output_tokens, .stop_sequences, .seed });
        return value;
    }

    pub fn protocol(self: *const OpenAiCompatible) protocol_api.Protocol {
        return protocol_api.Protocol.from(self, id);
    }

    pub fn invoke(
        _: *const OpenAiCompatible,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        invocation: protocol_api.Invocation,
        identity: message.ModelIdentity,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) failure.ModelError!message.ResponseMessage {
        try request.validateHandoff(identity.provider, null);
        const streaming = switch (delivery) {
            .buffered => false,
            .streaming => true,
        };
        const body = try openai_chat.encodeRequest(scratch_allocator, identity.model, request, streaming);
        defer scratch_allocator.free(body);
        const url = try endpointUrl(scratch_allocator, invocation.base_url);
        defer scratch_allocator.free(url);
        const authorization = if (invocation.auth.api_key) |key|
            std.fmt.allocPrint(scratch_allocator, "Bearer {s}", .{key}) catch return error.OutOfMemory
        else
            null;
        defer if (authorization) |value| {
            std.crypto.secureZero(u8, value);
            scratch_allocator.free(value);
        };
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
        headers.appendSlice(scratch_allocator, invocation.headers) catch return error.OutOfMemory;
        headers.appendSlice(scratch_allocator, invocation.auth.headers) catch return error.OutOfMemory;

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
                const response = invocation.transport.exchange(
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
                _ = invocation.transport.exchange(
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
