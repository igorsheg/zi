const std = @import("std");
const failure = @import("../failure.zig");
const message = @import("../message.zig");
const model_api = @import("../model.zig");
const model_catalog = @import("../model_catalog.zig");
const openai_responses = @import("../protocol/openai_responses.zig");
const provider_api = @import("../provider.zig");
const transport_api = @import("../transport.zig");

pub const Config = struct {
    catalog: model_catalog.Catalog,
    access_token: []const u8,
    account_id: ?[]const u8 = null,
    base_url: []const u8 = "https://chatgpt.com/backend-api",
};

pub const OpenAiCodex = struct {
    transport: transport_api.Transport,
    config: Config,

    pub fn init(transport: transport_api.Transport, config: Config) OpenAiCodex {
        return .{ .transport = transport, .config = config };
    }

    pub fn provider(self: *OpenAiCodex) provider_api.Provider {
        return provider_api.Provider.from(self, "openai-codex");
    }

    pub fn model(self: *OpenAiCodex, model_id: []const u8) ?model_api.Model {
        const resolved = self.config.catalog.resolve(.{
            .provider = "openai-codex",
            .model = model_id,
        }) orelse return null;
        return model_api.Model.from(self, resolved.entry.identity, resolved.entry.profile);
    }

    pub fn models(
        self: *OpenAiCodex,
        allocator: std.mem.Allocator,
    ) provider_api.ProviderError!provider_api.OwnedModelList {
        return provider_api.modelsFromCatalog(allocator, self.config.catalog, "openai-codex");
    }

    pub fn invoke(
        self: *OpenAiCodex,
        result_allocator: std.mem.Allocator,
        scratch_allocator: std.mem.Allocator,
        io: std.Io,
        identity: message.ModelIdentity,
        request: model_api.ModelRequest,
        delivery: model_api.Delivery,
    ) failure.ModelError!message.ResponseMessage {
        try request.validateHandoff(identity.provider, "openai-codex-responses");
        if (self.config.access_token.len == 0) return error.InvalidRequest;
        const account_id = if (self.config.account_id) |value|
            value
        else
            try accountIdFromJwt(scratch_allocator, self.config.access_token);
        defer if (self.config.account_id == null) {
            std.crypto.secureZero(u8, @constCast(account_id));
            scratch_allocator.free(account_id);
        };
        const authorization = std.fmt.allocPrint(
            scratch_allocator,
            "Bearer {s}",
            .{self.config.access_token},
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
        const url = try endpointUrl(scratch_allocator, self.config.base_url);
        defer scratch_allocator.free(url);
        const headers = [_]transport_api.Header{
            .{ .name = "content-type", .value = "application/json" },
            .{ .name = "authorization", .value = authorization },
            .{ .name = "chatgpt-account-id", .value = account_id },
            .{ .name = "originator", .value = "zi" },
            .{ .name = "openai-beta", .value = "responses=experimental" },
            .{ .name = "accept", .value = "text/event-stream" },
        };
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
        _ = self.transport.exchange(scratch_allocator, io, .{
            .method = .POST,
            .url = url,
            .headers = &headers,
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

pub fn accountIdFromJwt(
    allocator: std.mem.Allocator,
    access_token: []const u8,
) failure.ModelError![]const u8 {
    var segments = std.mem.splitScalar(u8, access_token, '.');
    _ = segments.next() orelse return error.InvalidRequest;
    const payload_segment = segments.next() orelse return error.InvalidRequest;
    if (segments.next() == null or segments.next() != null) return error.InvalidRequest;
    const decoded_size = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_segment) catch
        return error.InvalidRequest;
    const decoded = allocator.alloc(u8, decoded_size) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, decoded);
        allocator.free(decoded);
    }
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_segment) catch return error.InvalidRequest;
    const Claims = struct {
        @"https://api.openai.com/auth": struct {
            chatgpt_account_id: []const u8,
        },
    };
    var parsed = std.json.parseFromSlice(Claims, allocator, decoded, .{
        .ignore_unknown_fields = true,
    }) catch |parse_failure| switch (parse_failure) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    defer parsed.deinit();
    const account_id = parsed.value.@"https://api.openai.com/auth".chatgpt_account_id;
    if (account_id.len == 0) return error.InvalidRequest;
    defer std.crypto.secureZero(u8, @constCast(account_id));
    return allocator.dupe(u8, account_id) catch return error.OutOfMemory;
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
        error.InvalidUrl => error.InvalidRequest,
        error.ConnectionFailed => error.ConnectionFailed,
        error.InvalidResponse, error.ResponseTooLarge => error.InvalidProviderResponse,
        error.ConsumerStopped => error.StreamConsumerStopped,
    };
}
