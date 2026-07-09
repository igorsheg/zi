const std = @import("std");

const ai = @import("../ai/root.zig");

pub const notice_bytes_max: usize = 1024;

pub const Tone = enum { info, warn, err };

pub const View = struct {
    title: []const u8,
    message: []const u8,
    detail: ?[]const u8 = null,
    action_hint: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    category: ai.OperationalFailure.Category = .unknown,
    retryable: ai.OperationalFailure.Retryable = .unknown,
    tone: Tone = .err,
};

const Defaults = struct {
    title: []const u8,
    message: []const u8,
    action_hint: ?[]const u8,
    tone: Tone,
};

pub fn fromAssistant(message: ai.AssistantMessage) ?View {
    switch (message.stop_reason) {
        .error_ => return fromOperationalFailure(message.operational_failure, message.error_message),
        .aborted => {
            if (message.operational_failure) |failure| return fromOperationalFailure(failure, message.error_message);
            return .{
                .title = "Request canceled",
                .message = nonEmpty(message.error_message) orelse "The request was canceled.",
                .category = .canceled,
                .retryable = .no,
                .tone = .info,
            };
        },
        else => return null,
    }
}

pub fn fromOperationalFailure(maybe_failure: ?ai.OperationalFailure, fallback_message: ?[]const u8) View {
    const failure = maybe_failure orelse return .{
        .title = "Request failed",
        .message = nonEmpty(fallback_message) orelse "The assistant request failed.",
        .action_hint = "Check the transcript detail and retry when ready.",
        .tone = .err,
    };

    const defaults = categoryDefaults(failure.category);
    return .{
        .title = defaults.title,
        .message = nonEmpty(failure.message) orelse nonEmpty(fallback_message) orelse defaults.message,
        .detail = failure.detail,
        .action_hint = defaults.action_hint,
        .provider = failure.provider,
        .model = failure.model,
        .category = failure.category,
        .retryable = failure.retryable,
        .tone = defaults.tone,
    };
}

pub fn fromCompactionError(error_name: []const u8) View {
    if (std.mem.eql(u8, error_name, "OperationCancelled") or
        std.mem.eql(u8, error_name, "Canceled"))
    {
        return .{
            .title = "Compaction canceled",
            .message = "The compaction run was canceled.",
            .detail = error_name,
            .tone = .info,
        };
    }

    return .{
        .title = "Compaction failed",
        .message = error_name,
        .detail = error_name,
        .action_hint = "Continue without compaction or retry /compact after reducing the session.",
        .tone = .err,
    };
}

pub fn fromSessionOpenError(error_name: []const u8) View {
    if (std.mem.eql(u8, error_name, "SessionNotFound")) return .{
        .title = "Session not found",
        .message = "The requested session could not be found.",
        .detail = error_name,
        .action_hint = "Use /resume to pick an available session or /new to start a new one.",
        .tone = .err,
    };

    return .{
        .title = "Session could not be opened",
        .message = error_name,
        .detail = error_name,
        .action_hint = "Check the session file and permissions, then retry.",
        .tone = .err,
    };
}

pub fn formatNotice(buffer: []u8, view: View) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    appendBounded(&writer, buffer.len, view.title);
    appendBounded(&writer, buffer.len, ": ");
    appendBounded(&writer, buffer.len, view.message);
    appendSource(&writer, buffer.len, view.provider, view.model);
    if (view.action_hint) |hint| {
        appendBounded(&writer, buffer.len, "\n");
        appendBounded(&writer, buffer.len, hint);
    }
    return writer.buffered();
}

fn categoryDefaults(category: ai.OperationalFailure.Category) Defaults {
    return switch (category) {
        .auth_missing => .{
            .title = "Authentication required",
            .message = "Provider credentials are missing.",
            .action_hint = "Set the provider API key in the environment, then retry.",
            .tone = .err,
        },
        .auth_rejected => .{
            .title = "Authentication failed",
            .message = "The provider rejected the configured credentials.",
            .action_hint = "Check the credentials and provider account access, then retry.",
            .tone = .err,
        },
        .rate_limited => .{
            .title = "Rate limited",
            .message = "The provider is rate limiting requests.",
            .action_hint = "Wait before retrying, or switch to another model/provider.",
            .tone = .warn,
        },
        .context_overflow => .{
            .title = "Context too large",
            .message = "The request exceeded the model context window.",
            .action_hint = "Compact the session or start a smaller/new session, then retry.",
            .tone = .err,
        },
        .provider_unavailable => .{
            .title = "Provider unavailable",
            .message = "The provider is temporarily unavailable.",
            .action_hint = "Retry later or switch to another model/provider.",
            .tone = .warn,
        },
        .transport => .{
            .title = "Network error",
            .message = "The request could not reach the provider.",
            .action_hint = "Check network connectivity and retry.",
            .tone = .warn,
        },
        .malformed_response => .{
            .title = "Malformed provider response",
            .message = "The provider returned a response Zi could not parse.",
            .action_hint = "Retry; if it persists, switch provider/model.",
            .tone = .err,
        },
        .canceled => .{
            .title = "Request canceled",
            .message = "The request was canceled.",
            .action_hint = null,
            .tone = .info,
        },
        .unknown => .{
            .title = "Request failed",
            .message = "The assistant request failed.",
            .action_hint = "Check the transcript detail and retry when ready.",
            .tone = .err,
        },
    };
}

fn appendSource(writer: *std.Io.Writer, capacity: usize, provider: ?[]const u8, model: ?[]const u8) void {
    if (provider == null and model == null) return;
    appendBounded(writer, capacity, "\nsource: ");
    if (provider) |value| appendBounded(writer, capacity, value);
    if (provider != null and model != null) appendBounded(writer, capacity, "/");
    if (model) |value| appendBounded(writer, capacity, value);
}

fn appendBounded(writer: *std.Io.Writer, capacity: usize, text: []const u8) void {
    const remaining = capacity -| writer.buffered().len;
    if (remaining == 0) return;
    writer.writeAll(utf8Prefix(text, remaining)) catch {};
}

fn utf8Prefix(text: []const u8, max_bytes: usize) []const u8 {
    if (text.len <= max_bytes) return text;
    var end = max_bytes;
    while (end > 0 and !std.unicode.utf8ValidateSlice(text[0..end])) end -= 1;
    return text[0..end];
}

fn nonEmpty(maybe_text: ?[]const u8) ?[]const u8 {
    const text = maybe_text orelse return null;
    return if (text.len == 0) null else text;
}

test "failure display maps auth failure to actionable notice" {
    const view = fromOperationalFailure(.{
        .category = .auth_missing,
        .message = "Missing provider API key",
        .retryable = .no,
        .provider = "openai",
        .model = "gpt-5",
    }, "MissingApiKey");

    try std.testing.expectEqual(Tone.err, view.tone);
    try std.testing.expectEqualStrings("Authentication required", view.title);

    var buffer: [notice_bytes_max]u8 = undefined;
    const text = formatNotice(&buffer, view);
    try std.testing.expect(std.mem.indexOf(u8, text, "Authentication required: Missing provider API key") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "source: openai/gpt-5") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Set the provider API key") != null);
}

test "failure display marks transient provider failures as warnings" {
    const view = fromOperationalFailure(.{
        .category = .rate_limited,
        .message = "too many requests",
        .retryable = .yes,
    }, null);

    try std.testing.expectEqual(Tone.warn, view.tone);
    try std.testing.expectEqualStrings("Rate limited", view.title);
    try std.testing.expect(view.action_hint != null);
}

test "failure display maps compaction errors" {
    const view = fromCompactionError("MissingCompactionSummary");

    try std.testing.expectEqual(Tone.err, view.tone);
    try std.testing.expectEqualStrings("Compaction failed", view.title);
    var buffer: [notice_bytes_max]u8 = undefined;
    const text = formatNotice(&buffer, view);
    try std.testing.expect(std.mem.indexOf(u8, text, "/compact") != null);
}

test "failure display maps session-open errors" {
    const view = fromSessionOpenError("SessionNotFound");

    try std.testing.expectEqual(Tone.err, view.tone);
    try std.testing.expectEqualStrings("Session not found", view.title);
    var buffer: [notice_bytes_max]u8 = undefined;
    const text = formatNotice(&buffer, view);
    try std.testing.expect(std.mem.indexOf(u8, text, "/resume") != null);
}
