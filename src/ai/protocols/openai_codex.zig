const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model_api = @import("../model.zig");
const openai_responses = @import("../protocol/openai_responses.zig");
const openai_codex_provider = @import("../providers/openai_codex.zig");
const protocol_api = @import("../protocol.zig");
const settings = @import("../settings.zig");
const transport_api = @import("../transport.zig");

pub const id = "openai-codex-responses";

pub const OpenAiCodex = struct {
    pub fn profile(_: *const OpenAiCodex, hints: protocol_api.ProfileHints) settings.ModelProfile {
        var value: settings.ModelProfile = .{};
        value.capabilities = .initMany(&.{ .streaming, .tools, .parallel_tool_calls });
        if (hints.reasoning) {
            value.capabilities.insert(.thinking);
            value.settings.insert(.reasoning_effort);
            value.reasoning_efforts = hints.reasoning_efforts;
        }
        return value;
    }

    pub fn protocol(self: *const OpenAiCodex) protocol_api.Protocol {
        return protocol_api.Protocol.from(self, id);
    }

    pub fn invoke(
        _: *const OpenAiCodex,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        invocation: protocol_api.Invocation,
        identity: message.ModelIdentity,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) failure.ModelError!message.ResponseMessage {
        try request.validateHandoff(identity.provider, id);
        const access_token = invocation.auth.api_key orelse return error.InvalidRequest;
        if (access_token.len == 0) return error.InvalidRequest;
        const account_id = if (invocation.auth.account_id) |value|
            value
        else
            try accountIdFromJwt(scratch_allocator, access_token);
        defer if (invocation.auth.account_id == null) {
            std.crypto.secureZero(u8, @constCast(account_id));
            scratch_allocator.free(account_id);
        };
        const authorization = std.fmt.allocPrint(
            scratch_allocator,
            "Bearer {s}",
            .{access_token},
        ) catch return error.OutOfMemory;
        defer {
            std.crypto.secureZero(u8, authorization);
            scratch_allocator.free(authorization);
        }
        const body = try openai_responses.encodeCodexRequest(scratch_allocator, identity, request);
        defer {
            std.crypto.secureZero(u8, @constCast(body));
            scratch_allocator.free(body);
        }
        const url = try endpointUrl(scratch_allocator, invocation.base_url);
        defer scratch_allocator.free(url);
        var headers = transport_api.HeaderList.init(scratch_allocator);
        defer headers.deinit();
        headers.appendSlice(&.{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = authorization, .sensitive = true },
            .{ .name = "chatgpt-account-id", .value = account_id, .sensitive = true },
            .{ .name = "originator", .value = "zi" },
            .{ .name = "openai-beta", .value = "responses=experimental" },
            .{ .name = "accept", .value = "text/event-stream" },
        }) catch |failure_value| return headerError(failure_value);
        headers.appendSlice(invocation.headers) catch |failure_value| return headerError(failure_value);
        headers.appendSlice(invocation.auth.headers) catch |failure_value| return headerError(failure_value);
        const application_sink = switch (delivery) {
            .buffered => null,
            .streaming => |sink| sink,
        };
        var decoder = openai_responses.StreamDecoder.init(
            result_allocator,
            scratch_allocator,
            identity,
            "openai-codex-responses",
            application_sink,
        );
        defer decoder.deinit();
        _ = invocation.transport.exchange(scratch_allocator, io, .{
            .method = .POST,
            .url = url,
            .headers = headers.items(),
            .body = body,
            .deadline = request.deadline,
            .cancellation = request.cancellation,
        }, .{ .streaming = decoder.bodySink() }) catch |transport_failure| {
            if (decoder.failure_value) |decode_failure| return decode_failure;
            if (!decoder.terminal) return mapTransportError(transport_failure);
        };
        if (decoder.status < 200 or decoder.status >= 300) {
            observeFailure(request.failure_sink, decoder.status, decoder.error_body.items);
        }
        return decoder.result();
    }
};

fn headerError(failure_value: anyerror) failure.ModelError {
    return if (failure_value == error.OutOfMemory) error.OutOfMemory else error.InvalidRequest;
}

pub fn accountIdFromJwt(
    allocator: std.mem.Allocator,
    access_token: []const u8,
) failure.ModelError![]const u8 {
    return openai_codex_provider.accountIdFromJwt(
        allocator,
        access_token,
    ) catch |failure_value| switch (failure_value) {
        error.OutOfMemory => error.OutOfMemory,
        error.InvalidToken => error.InvalidRequest,
    };
}

fn endpointUrl(allocator: std.mem.Allocator, base_url: []const u8) failure.ModelError![]const u8 {
    const base = std.mem.trim(u8, base_url, " \t\r\n/");
    if (base.len == 0) return error.InvalidRequest;
    if (std.mem.endsWith(u8, base, "/codex/responses")) {
        return allocator.dupe(u8, base) catch return error.OutOfMemory;
    }
    if (std.mem.endsWith(u8, base, "/codex")) {
        return std.fmt.allocPrint(allocator, "{s}/responses", .{base}) catch return error.OutOfMemory;
    }
    return std.fmt.allocPrint(allocator, "{s}/codex/responses", .{base}) catch return error.OutOfMemory;
}

fn observeFailure(sink: ?failure.FailureSink, status: u16, body: []const u8) void {
    const observer = sink orelse return;
    observer.observe(.{
        .provider = "openai-codex",
        .status = status,
        .message = body[0..@min(body.len, 2048)],
    });
}

fn mapTransportError(value: transport_api.Error) failure.ModelError {
    return switch (value) {
        error.OutOfMemory => error.OutOfMemory,
        error.Cancelled => error.Cancelled,
        error.TimedOut => error.TimedOut,
        error.InvalidUrl, error.InvalidRequest => error.InvalidRequest,
        error.ConnectionFailed => error.ConnectionFailed,
        error.InvalidResponse, error.ResponseTooLarge => error.InvalidProviderResponse,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}
