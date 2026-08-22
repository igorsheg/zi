const std = @import("std");
const BoundedJson = @import("../../BoundedJson.zig");
const failure = @import("../failure.zig");
const transport = @import("../transport.zig");

const max_error_body_bytes = 16 * 1024;
const max_message_bytes = failure.ProviderFailure.max_message_bytes;
const max_code_bytes = failure.ProviderFailure.max_code_bytes;
const fallback_message = "OpenAI rejected the request.";

pub fn observe(
    allocator: std.mem.Allocator,
    sink: ?failure.FailureSink,
    provider: []const u8,
    status: u16,
    body: []const u8,
    metadata: transport.ResponseMetadata,
    headers: []const transport.Header,
) void {
    const observer = sink orelse return;
    var parsed = parseDetail(allocator, body) orelse {
        observer.observe(.{
            .provider = provider,
            .status = status,
            .message = fallback_message,
            .request_id = if (metadata.request_id) |*value| value.slice() else null,
            .retry_after_ms = metadata.retry_after_ms,
        });
        return;
    };
    defer parsed.value.deinit();
    const sensitive_data_redacted = containsSensitive(parsed.message, headers) or
        containsSensitive(parsed.code orelse "", headers);
    observer.observe(.{
        .provider = provider,
        .status = status,
        .code = if (sensitive_data_redacted) null else parsed.code,
        .message = if (sensitive_data_redacted) fallback_message else parsed.message,
        .request_id = if (metadata.request_id) |*value| value.slice() else null,
        .retry_after_ms = metadata.retry_after_ms,
        .sensitive_data_redacted = sensitive_data_redacted,
    });
}

const ParsedDetail = struct {
    value: std.json.Parsed(std.json.Value),
    message: []const u8,
    code: ?[]const u8,
};

fn parseDetail(allocator: std.mem.Allocator, body: []const u8) ?ParsedDetail {
    if (body.len == 0 or body.len > max_error_body_bytes) return null;
    BoundedJson.validate(allocator, body, .{
        .document_bytes = max_error_body_bytes,
        .value_bytes = max_message_bytes,
        .depth = 4,
        .collection_items = 32,
    }) catch return null;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, body, .{
        .max_value_len = max_error_body_bytes,
    }) catch return null;
    var retained = false;
    defer if (!retained) parsed.deinit();
    if (parsed.value != .object) return null;
    const object = parsed.value.object;
    var message: ?[]const u8 = stringField(object, "detail") orelse stringField(object, "message");
    var code: ?[]const u8 = stringField(object, "code");
    if (object.get("error")) |error_value| if (error_value == .object) {
        message = stringField(error_value.object, "message") orelse message;
        code = stringField(error_value.object, "code") orelse
            stringField(error_value.object, "type") orelse code;
    };
    const resolved_message = message orelse return null;
    if (resolved_message.len == 0 or resolved_message.len > max_message_bytes or
        !safeDiagnosticText(resolved_message)) return null;
    if (code) |value| {
        if (value.len == 0 or value.len > max_code_bytes or !safeDiagnosticText(value)) code = null;
    }
    retained = true;
    return .{ .value = parsed, .message = resolved_message, .code = code };
}

fn stringField(object: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const value = object.get(name) orelse return null;
    return if (value == .string) value.string else null;
}

fn safeDiagnosticText(value: []const u8) bool {
    if (!std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return false;
    return true;
}

fn containsSensitive(value: []const u8, headers: []const transport.Header) bool {
    for (headers) |header| {
        if (header.isSensitive() and
            header.value.len > 0 and
            std.mem.find(u8, value, header.value) != null) return true;
    }
    return false;
}

test "OpenAI error observation extracts bounded details and redacts credentials" {
    const Capture = struct {
        const Self = @This();

        status: u16 = 0,
        code_buffer: [64]u8 = undefined,
        code_length: usize = 0,
        message_buffer: [128]u8 = undefined,
        message_length: usize = 0,
        sensitive_data_redacted: bool = false,

        fn observe(context: *anyopaque, provider_failure: failure.ProviderFailure) void {
            const self: *Self = @ptrCast(@alignCast(context));
            self.status = provider_failure.status;
            self.code_length = if (provider_failure.code) |captured_code|
                @min(captured_code.len, self.code_buffer.len)
            else
                0;
            if (provider_failure.code) |captured_code| {
                @memcpy(self.code_buffer[0..self.code_length], captured_code[0..self.code_length]);
            }
            self.message_length = @min(provider_failure.message.len, self.message_buffer.len);
            @memcpy(self.message_buffer[0..self.message_length], provider_failure.message[0..self.message_length]);
            self.sensitive_data_redacted = provider_failure.sensitive_data_redacted;
        }

        fn code(self: *const Self) []const u8 {
            return self.code_buffer[0..self.code_length];
        }

        fn message(self: *const Self) []const u8 {
            return self.message_buffer[0..self.message_length];
        }
    };
    var capture: Capture = .{};
    const sink: failure.FailureSink = .{ .context = &capture, .observeFn = Capture.observe };
    observe(
        std.testing.allocator,
        sink,
        "openai",
        400,
        "{\"error\":{\"message\":\"Unsupported content type\",\"code\":\"bad_request\"}}",
        .{},
        &.{.{ .name = "authorization", .value = "secret" }},
    );
    try std.testing.expectEqual(@as(u16, 400), capture.status);
    try std.testing.expectEqualStrings("bad_request", capture.code());
    try std.testing.expectEqualStrings("Unsupported content type", capture.message());
    try std.testing.expect(!capture.sensitive_data_redacted);

    observe(
        std.testing.allocator,
        sink,
        "openai",
        401,
        "{\"detail\":\"credential secret was rejected\"}",
        .{},
        &.{.{ .name = "x-api-key", .value = "secret" }},
    );
    try std.testing.expectEqualStrings(fallback_message, capture.message());
    try std.testing.expect(capture.sensitive_data_redacted);

    observe(
        std.testing.allocator,
        sink,
        "openai",
        400,
        "{\"error\":{\"message\":\"Safe message\",\"code\":\"unsafe\\ncode\"}}",
        .{},
        &.{},
    );
    try std.testing.expectEqualStrings("Safe message", capture.message());
    try std.testing.expectEqualStrings("", capture.code());
}
