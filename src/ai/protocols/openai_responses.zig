const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model_api = @import("../model.zig");
const openai_responses = @import("../protocol/openai_responses.zig");
const protocol_api = @import("../protocol.zig");
const settings = @import("../settings.zig");
const transport_api = @import("../transport.zig");

pub const id = "openai-responses";

pub const OpenAiResponses = struct {
    pub fn profile(_: *const OpenAiResponses, hints: protocol_api.ProfileHints) settings.ModelProfile {
        var value: settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls });
        value.settings = .initOne(.max_output_tokens);
        if (hints.reasoning) {
            value.capabilities.insert(.thinking);
            value.settings.insert(.reasoning_effort);
            value.reasoning_efforts = hints.reasoning_efforts;
        }
        return value;
    }

    pub fn protocol(self: *const OpenAiResponses) protocol_api.Protocol {
        return protocol_api.Protocol.from(self, id);
    }

    pub fn invoke(
        _: *const OpenAiResponses,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        invocation: protocol_api.Invocation,
        identity: message.ModelIdentity,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) failure.ModelError!message.ResponseMessage {
        try request.validateHandoff(identity.provider, "openai-responses");
        const body = try openai_responses.encodeRequest(scratch_allocator, identity, request);
        defer {
            std.crypto.secureZero(u8, @constCast(body));
            scratch_allocator.free(body);
        }
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
        headers.append(scratch_allocator, .{ .name = "content-type", .value = "application/json" }) catch
            return error.OutOfMemory;
        headers.append(scratch_allocator, .{ .name = "accept", .value = "text/event-stream" }) catch
            return error.OutOfMemory;
        if (authorization) |value| headers.append(scratch_allocator, .{
            .name = "authorization",
            .value = value,
        }) catch return error.OutOfMemory;
        headers.appendSlice(scratch_allocator, invocation.headers) catch return error.OutOfMemory;
        headers.appendSlice(scratch_allocator, invocation.auth.headers) catch return error.OutOfMemory;

        const application_sink = switch (delivery) {
            .buffered => null,
            .streaming => |sink| sink,
        };
        var decoder = openai_responses.StreamDecoder.init(
            result_allocator,
            scratch_allocator,
            identity,
            "openai-responses",
            application_sink,
        );
        defer decoder.deinit();
        _ = invocation.transport.exchange(scratch_allocator, io, .{
            .method = .POST,
            .url = url,
            .headers = headers.items,
            .body = body,
            .deadline = request.deadline,
            .cancellation = request.cancellation,
        }, .{ .streaming = decoder.bodySink() }) catch |transport_failure| {
            if (decoder.failure_value) |decode_failure| return decode_failure;
            if (!decoder.terminal) return mapTransportError(transport_failure);
        };
        if (decoder.status < 200 or decoder.status >= 300) {
            observeFailure(request.failure_sink, identity, decoder.status, decoder.error_body.items);
        }
        return decoder.result();
    }
};

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) failure.ModelError![]const u8 {
    const base = std.mem.trim(u8, base_url, " \t\r\n/");
    if (base.len == 0) return error.InvalidRequest;
    if (std.mem.endsWith(u8, base, "/responses")) {
        return allocator.dupe(u8, base) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}/responses", .{base}) catch return error.OutOfMemory;
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

fn mapTransportError(transport_failure: transport_api.Error) failure.ModelError {
    return switch (transport_failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.TimedOut => error.TimedOut,
        error.InvalidUrl => error.InvalidRequest,
        error.ConnectionFailed => error.ConnectionFailed,
        error.InvalidResponse, error.ResponseTooLarge => error.InvalidProviderResponse,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}
