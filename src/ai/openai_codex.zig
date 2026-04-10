//! OpenAI Codex Responses provider — ChatGPT backend endpoint at
//! `https://chatgpt.com/backend-api/codex/responses`. Thin wrapper over
//! `openai_responses_core`, identical in shape to `openai_responses.zig`;
//! the only differences are the hard-coded base URL and the path.
//!
//! pi-mono source: `packages/ai/src/providers/openai-codex-responses.ts`
//!
//! ## Status (phase 4)
//!
//! Registered as `"openai-codex-responses"` in `Bundle.init`. Auth is a
//! bearer token passed through `StreamOptions.api_key`, populated by
//! `AuthStorage.getApiKey("openai-codex")` which auto-refreshes expired
//! OAuth tokens. Extracts `chatgpt_account_id` from the JWT access
//! token and sends it as the `chatgpt-account-id` request header.
//! Also sends `originator: pi` and `OpenAI-Beta: responses=experimental`.
//!
//! Intentionally NOT ported:
//!   - websocket transport (`responses_websockets=2026-02-06` beta)
//!   - reasoning effort clamping (tracked as zi-imj)

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const ai_provider = @import("provider.zig");
const core = @import("openai_responses_core.zig");

pub const OpenAICodexProvider = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAICodexProvider {
        return .{ .allocator = allocator };
    }

    pub fn provider(self: *OpenAICodexProvider) ai_provider.Provider {
        return .{
            .ptr = self,
            .vtable = &.{
                .stream = streamWrap,
                .stream_simple = streamSimpleWrap,
                .get_name = getName,
                .deinit = deinitImpl,
            },
        };
    }

    fn streamWrap(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        _ = ptr;
        // Scratch arena for JWT decode; outlives streamCore (synchronous).
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        var extra_hdrs: [6]protocol.Header = undefined;
        const account_id = requireAccountId(allocator, model, options.api_key, callback, callback_ctx) orelse return;
        const user_agent = buildUserAgent(scratch.allocator()) catch "pi (zig)";
        const n_hdrs = fillCodexHeaders(&extra_hdrs, account_id, user_agent, options.session_id);

        core.streamCore(allocator, model, context, options, .{
            .base_url = if (model.base_url.len > 0) null else "https://chatgpt.com/backend-api",
            .path = "/codex/responses",
            .auth = .{ .build = buildBearerAuth },
            .extra_headers = extra_hdrs[0..n_hdrs],
            .provider_label = "openai-codex-responses",
            .build_request = &buildCodexRequestJson,
        }, callback, callback_ctx);
    }

    fn streamSimpleWrap(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        callback: ai_provider.EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        _ = ptr;
        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        var extra_hdrs: [6]protocol.Header = undefined;
        const account_id = requireAccountId(allocator, model, options.base.api_key, callback, callback_ctx) orelse return;
        const user_agent = buildUserAgent(scratch.allocator()) catch "pi (zig)";
        const n_hdrs = fillCodexHeaders(&extra_hdrs, account_id, user_agent, options.base.session_id);

        const clamped = protocol.clampReasoning(options.reasoning, model);
        const effort: ?[]const u8 = if (clamped) |l| protocol.thinkingLevelToString(l) else null;

        core.streamCore(allocator, model, context, options.base, .{
            .base_url = if (model.base_url.len > 0) null else "https://chatgpt.com/backend-api",
            .path = "/codex/responses",
            .auth = .{ .build = buildBearerAuth },
            .extra_headers = extra_hdrs[0..n_hdrs],
            .provider_label = "openai-codex-responses",
            .build_request = &buildCodexRequestJson,
            .reasoning_effort = effort,
            .reasoning_summary = if (effort != null) "auto" else null,
        }, callback, callback_ctx);
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openai-codex-responses";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

/// Codex-specific request body builder. Passed to `CoreOptions.build_request`
/// so the shared core uses it instead of `buildRequestJson`.
///
/// pi-mono: openai-codex-responses.ts:296-334
///
/// Key differences from the standard responses body:
///   - `instructions` is a top-level field (system prompt excluded from `input`)
///   - `text.verbosity: "medium"`
///   - `include: ["reasoning.encrypted_content"]`
///   - `tool_choice: "auto"`, `parallel_tool_calls: true`
///   - reasoning defaults to `effort: "low"`, `summary: "auto"`
fn buildCodexRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
    reasoning_effort: ?[]const u8,
    reasoning_summary: ?[]const u8,
    session_id: ?[]const u8,
) anyerror!void {
    var allocating = std.io.Writer.Allocating.fromArrayList(allocator, out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try core.writeBaseFields(&jw, model);

    // System prompt as top-level `instructions` (NOT in input)
    if (context.system_prompt) |sys| {
        try jw.objectField("instructions");
        try jw.write(sys);
    }

    // Messages WITHOUT system prompt
    try jw.objectField("input");
    try jw.beginArray();
    try core.writeInputOpts(allocator, &jw, model, context, false);
    try jw.endArray();

    try jw.objectField("text");
    try jw.beginObject();
    try jw.objectField("verbosity");
    try jw.write("medium");
    try jw.endObject();

    try jw.objectField("include");
    try jw.beginArray();
    try jw.write("reasoning.encrypted_content");
    try jw.endArray();

    if (session_id) |sid| {
        try jw.objectField("prompt_cache_key");
        try jw.write(sid);
    }

    try jw.objectField("tool_choice");
    try jw.write("auto");

    try jw.objectField("parallel_tool_calls");
    try jw.write(true);

    if (context.tools) |tools| {
        try core.writeTools(&jw, tools, false);
    }

    if (model.reasoning and reasoning_effort != null) {
        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write(reasoning_effort.?);
        try jw.objectField("summary");
        try jw.write(reasoning_summary orelse "auto");
        try jw.endObject();
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

/// Extract chatgpt_account_id from a JWT access token.
/// pi-mono: openai-codex-responses.ts:282-287
fn extractAccountId(arena: std.mem.Allocator, token: []const u8) ![]const u8 {
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return error.InvalidAccessToken;
    const payload_b64 = parts.next() orelse return error.InvalidAccessToken;

    const decoded_len = try std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64);
    const decoded = try arena.alloc(u8, decoded_len);
    try std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_b64);

    const parsed = try std.json.parseFromSlice(std.json.Value, arena, decoded, .{});
    if (parsed.value != .object) return error.InvalidAccessToken;

    const auth_claim = parsed.value.object.get("https://api.openai.com/auth") orelse return error.MissingAccountId;
    if (auth_claim != .object) return error.MissingAccountId;
    const id_val = auth_claim.object.get("chatgpt_account_id") orelse return error.MissingAccountId;
    if (id_val != .string or id_val.string.len == 0) return error.MissingAccountId;

    return id_val.string;
}

fn requireAccountId(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    api_key: ?[]const u8,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) ?[]const u8 {
    const key = api_key orelse {
        core.emitFailure(allocator, callback, callback_ctx, model, "openai-codex-responses", .{ .kind = .auth }, "no API key provided");
        return null;
    };
    const account_id = extractAccountId(allocator, key) catch |err| {
        const msg = switch (err) {
            error.MissingAccountId => "failed to extract accountId from token: no account ID in token",
            else => "failed to extract accountId from token",
        };
        core.emitFailure(allocator, callback, callback_ctx, model, "openai-codex-responses", .{ .kind = .auth }, msg);
        return null;
    };
    return account_id;
}

fn fillCodexHeaders(buf: *[6]protocol.Header, account_id: []const u8, user_agent: []const u8, session_id: ?[]const u8) usize {
    buf[0] = .{ .key = "chatgpt-account-id", .value = account_id };
    buf[1] = .{ .key = "originator", .value = "pi" };
    buf[2] = .{ .key = "user-agent", .value = user_agent };
    buf[3] = .{ .key = "OpenAI-Beta", .value = "responses=experimental" };
    buf[4] = .{ .key = "accept", .value = "text/event-stream" };
    if (session_id) |sid| {
        buf[5] = .{ .key = "session_id", .value = sid };
        return 6;
    }
    return 5;
}

fn buildUserAgent(allocator: std.mem.Allocator) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "pi ({s} {s}; {s})",
        .{ @tagName(builtin.os.tag), osRelease(), @tagName(builtin.cpu.arch) },
    );
}

fn osRelease() []const u8 {
    return switch (builtin.os.tag) {
        .macos => "darwin",
        else => @tagName(builtin.os.tag),
    };
}

/// Bearer auth factory. Reads the access token from `StreamOptions.api_key`;
/// phase 4 will populate that field from `AuthStorage` oauth credentials
/// (PKCE access_token, refreshed on expiry). If absent, return `NoApiKey`
/// so `streamCore` emits a clean error event instead of a silent no-op.
const testing = std.testing;

test "extractAccountId returns the chatgpt account claim from oauth tokens" {
    const allocator = testing.allocator;
    const token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF8xMjMifX0.";
    const account_id = try extractAccountId(allocator, token);
    try testing.expectEqualStrings("acct_123", account_id);
}

test "fillCodexHeaders matches the codex-required header set" {
    var headers: [6]protocol.Header = undefined;
    const count = fillCodexHeaders(&headers, "acct_123", "pi (darwin darwin; aarch64)", "session-abc");
    try testing.expectEqual(@as(usize, 6), count);
    try testing.expectEqualStrings("chatgpt-account-id", headers[0].key);
    try testing.expectEqualStrings("acct_123", headers[0].value);
    try testing.expectEqualStrings("originator", headers[1].key);
    try testing.expectEqualStrings("pi", headers[1].value);
    try testing.expectEqualStrings("user-agent", headers[2].key);
    try testing.expectEqualStrings("OpenAI-Beta", headers[3].key);
    try testing.expectEqualStrings("accept", headers[4].key);
    try testing.expectEqualStrings("text/event-stream", headers[4].value);
    try testing.expectEqualStrings("session_id", headers[5].key);
    try testing.expectEqualStrings("session-abc", headers[5].value);
}

test "buildCodexRequestJson includes prompt_cache_key when session_id is set" {
    const alloc = testing.allocator;
    const model = protocol.Model{
        .id = "gpt-5.4",
        .name = "GPT-5.4",
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };
    const msg = protocol.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } };
    const ctx = protocol.Context{ .messages = &.{msg} };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    try buildCodexRequestJson(alloc, &out, model, ctx, null, null, "session-abc");
    try testing.expect(std.mem.indexOf(u8, out.items, "\"prompt_cache_key\":\"session-abc\"") != null);
}

test "buildCodexRequestJson omits reasoning when no reasoning effort is requested" {
    const alloc = testing.allocator;
    const model = protocol.Model{
        .id = "gpt-5.4",
        .name = "GPT-5.4",
        .api = .openai_codex_responses,
        .provider = .openai_codex,
        .base_url = "https://chatgpt.com/backend-api",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 128000,
        .max_tokens = 4096,
    };
    const msg = protocol.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } };
    const ctx = protocol.Context{ .messages = &.{msg} };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    try buildCodexRequestJson(alloc, &out, model, ctx, null, null, null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning\"") == null);
}

fn buildBearerAuth(
    _: ?*anyopaque,
    buf: []u8,
    api_key: ?[]const u8,
) error{ NoApiKey, BufferTooSmall }![]u8 {
    const key = api_key orelse return error.NoApiKey;
    if (key.len == 0) return error.NoApiKey;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{key}) catch return error.BufferTooSmall;
}
