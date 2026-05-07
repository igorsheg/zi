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
//! Transport: `null`, `auto`, and `sse` use the SSE `/codex/responses`
//! endpoint. `websocket` fails explicitly; the ChatGPT websocket beta is not
//! implemented in this provider.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const env = @import("env");
const ai_models = @import("models.zig");
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
        if (!acceptCodexTransport(allocator, model, options.transport, callback, callback_ctx)) return;

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
            .event_mapper = .{ .map = core.codexEventMapper },
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
        if (!acceptCodexTransport(allocator, model, options.base.transport, callback, callback_ctx)) return;

        var scratch = std.heap.ArenaAllocator.init(allocator);
        defer scratch.deinit();

        var extra_hdrs: [6]protocol.Header = undefined;
        const account_id = requireAccountId(allocator, model, options.base.api_key, callback, callback_ctx) orelse return;
        const user_agent = buildUserAgent(scratch.allocator()) catch "pi (zig)";
        const n_hdrs = fillCodexHeaders(&extra_hdrs, account_id, user_agent, options.base.session_id);

        const clamped = ai_models.clampReasoning(options.reasoning, model);
        const effort: ?[]const u8 = if (clamped) |l|
            clampCodexReasoningEffort(model.id, protocol.thinkingLevelToString(l))
        else
            null;

        core.streamCore(allocator, model, context, options.base, .{
            .base_url = if (model.base_url.len > 0) null else "https://chatgpt.com/backend-api",
            .path = "/codex/responses",
            .auth = .{ .build = buildBearerAuth },
            .extra_headers = extra_hdrs[0..n_hdrs],
            .provider_label = "openai-codex-responses",
            .event_mapper = .{ .map = core.codexEventMapper },
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

fn acceptCodexTransport(
    allocator: std.mem.Allocator,
    model: protocol.Model,
    transport: ?protocol.Transport,
    callback: ai_provider.EventCallback,
    callback_ctx: ?*anyopaque,
) bool {
    switch (transport orelse .auto) {
        .auto, .sse => return true,
        .websocket => {
            core.emitFailure(
                allocator,
                callback,
                callback_ctx,
                model,
                "openai-codex-responses",
                .{ .kind = .invalid_request },
                "websocket transport is not supported by openai-codex-responses; use sse or auto",
            );
            return false;
        },
    }
}

/// Codex-specific request body builder. Passed to `CoreOptions.build_request`
/// so the shared core uses it instead of `buildRequestJson`.
///
/// pi-mono: openai-codex-responses.ts:296-334
///
/// Key differences from the standard responses body:
///   - `instructions` is a top-level field (system prompt excluded from `input`)
///   - `text.verbosity: "medium"` (`"low"` when Codex fast mode is enabled)
///   - `include: ["reasoning.encrypted_content"]`
///   - `tool_choice: "auto"`, `parallel_tool_calls: true`
///   - reasoning defaults to `effort: "low"`, `summary: "auto"`
fn buildCodexRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    reasoning_effort: ?[]const u8,
    reasoning_summary: ?[]const u8,
) anyerror!void {
    return buildCodexRequestJsonWithFastMode(
        allocator,
        out,
        model,
        context,
        options,
        reasoning_effort,
        reasoning_summary,
        codexFastModeEnabledForModel(model.id),
    );
}

fn buildCodexRequestJsonWithFastMode(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8),
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    reasoning_effort: ?[]const u8,
    reasoning_summary: ?[]const u8,
    use_codex_fast_mode: bool,
) anyerror!void {
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    var jw = std.json.Stringify{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try core.writeBaseFields(&jw, model);

    if (context.system_prompt) |sys| {
        try jw.objectField("instructions");
        try jw.write(sys);
    }

    try jw.objectField("input");
    try jw.beginArray();
    try core.writeInputOpts(allocator, &jw, model, context, false);
    try jw.endArray();

    try jw.objectField("text");
    try jw.beginObject();
    try jw.objectField("verbosity");
    try jw.write(codexVerbosity(use_codex_fast_mode));
    try jw.endObject();

    try jw.objectField("include");
    try jw.beginArray();
    try jw.write("reasoning.encrypted_content");
    try jw.endArray();

    if (options.session_id) |sid| {
        try jw.objectField("prompt_cache_key");
        try jw.write(sid);
    }

    if (options.temperature) |temperature| {
        try jw.objectField("temperature");
        try jw.write(temperature);
    }

    try jw.objectField("tool_choice");
    try jw.write("auto");

    try jw.objectField("parallel_tool_calls");
    try jw.write(true);

    if (context.tools) |tools| {
        try core.writeTools(&jw, tools, .null_value);
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

    if (use_codex_fast_mode) {
        try jw.objectField("service_tier");
        try jw.write("priority");
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

/// Extract chatgpt_account_id from a JWT access token.
/// pi-mono: openai-codex-responses.ts:282-287
fn extractAccountId(allocator: std.mem.Allocator, token: []const u8) ![]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const arena = scratch.allocator();

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

    return try allocator.dupe(u8, id_val.string);
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

const CODEX_FAST_MODE_ENV = "ZI_CODEX_FAST_MODE";

fn codexModelLeaf(model_id: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, model_id, '/')) |idx| model_id[idx + 1 ..] else model_id;
}

fn isCodexFastModeSupportedModel(model_id: []const u8) bool {
    const id = codexModelLeaf(model_id);
    return std.mem.eql(u8, id, "gpt-5.4") or std.mem.eql(u8, id, "gpt-5.5");
}

fn codexFastModeEnabledForModel(model_id: []const u8) bool {
    return isCodexFastModeSupportedModel(model_id) and envFlagEnabled(env.get(CODEX_FAST_MODE_ENV));
}

fn envFlagEnabled(value: ?[]const u8) bool {
    const raw = value orelse return false;
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    return std.mem.eql(u8, trimmed, "1") or
        std.ascii.eqlIgnoreCase(trimmed, "true") or
        std.ascii.eqlIgnoreCase(trimmed, "on") or
        std.ascii.eqlIgnoreCase(trimmed, "yes");
}

fn codexVerbosity(use_codex_fast_mode: bool) []const u8 {
    return if (use_codex_fast_mode) "low" else "medium";
}

fn clampCodexReasoningEffort(model_id: []const u8, effort: []const u8) []const u8 {
    const id = codexModelLeaf(model_id);
    if ((std.mem.startsWith(u8, id, "gpt-5.2") or
        std.mem.startsWith(u8, id, "gpt-5.3") or
        std.mem.startsWith(u8, id, "gpt-5.4") or
        std.mem.startsWith(u8, id, "gpt-5.5")) and
        std.mem.eql(u8, effort, "minimal"))
    {
        return "low";
    }
    if (std.mem.eql(u8, id, "gpt-5.1") and std.mem.eql(u8, effort, "xhigh")) {
        return "high";
    }
    if (std.mem.eql(u8, id, "gpt-5.1-codex-mini")) {
        if (std.mem.eql(u8, effort, "high") or std.mem.eql(u8, effort, "xhigh")) return "high";
        return "medium";
    }
    return effort;
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

const codex_account_token = "eyJhbGciOiJub25lIn0.eyJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9hY2NvdW50X2lkIjoiYWNjdF8xMjMifX0.";

fn expectHeader(header: protocol.Header, key: []const u8, value: []const u8) !void {
    try testing.expectEqualStrings(key, header.key);
    try testing.expectEqualStrings(value, header.value);
}

test "auth helpers extract ChatGPT account and build Codex headers" {
    const allocator = testing.allocator;
    const account_id = try extractAccountId(allocator, codex_account_token);
    defer allocator.free(account_id);
    try testing.expectEqualStrings("acct_123", account_id);

    var auth_buf: [256]u8 = undefined;
    const auth = try buildBearerAuth(null, &auth_buf, codex_account_token);
    try testing.expectEqualStrings("Bearer " ++ codex_account_token, auth);
    try testing.expectError(error.NoApiKey, buildBearerAuth(null, &auth_buf, null));

    var headers: [6]protocol.Header = undefined;
    const count = fillCodexHeaders(&headers, account_id, "pi (darwin darwin; aarch64)", "session-abc");
    try testing.expectEqual(@as(usize, 6), count);
    try expectHeader(headers[0], "chatgpt-account-id", "acct_123");
    try expectHeader(headers[1], "originator", "pi");
    try testing.expectEqualStrings("user-agent", headers[2].key);
    try expectHeader(headers[3], "OpenAI-Beta", "responses=experimental");
    try expectHeader(headers[4], "accept", "text/event-stream");
    try expectHeader(headers[5], "session_id", "session-abc");
}

test "clampCodexReasoningEffort matches codex model/API boundaries" {
    try testing.expectEqualStrings("low", clampCodexReasoningEffort("gpt-5.4", "minimal"));
    try testing.expectEqualStrings("low", clampCodexReasoningEffort("openai/gpt-5.2-codex", "minimal"));
    try testing.expectEqualStrings("high", clampCodexReasoningEffort("gpt-5.1", "xhigh"));
    try testing.expectEqualStrings("medium", clampCodexReasoningEffort("gpt-5.1-codex-mini", "low"));
    try testing.expectEqualStrings("high", clampCodexReasoningEffort("gpt-5.1-codex-mini", "xhigh"));
    try testing.expectEqualStrings("high", clampCodexReasoningEffort("gpt-5.4", "high"));
    try testing.expectEqualStrings("low", clampCodexReasoningEffort("gpt-5.5", "minimal"));
}

test "Codex fast mode env helpers are explicit and model-scoped" {
    try testing.expect(envFlagEnabled("1"));
    try testing.expect(envFlagEnabled("true"));
    try testing.expect(envFlagEnabled("ON"));
    try testing.expect(envFlagEnabled(" yes "));
    try testing.expect(!envFlagEnabled(null));
    try testing.expect(!envFlagEnabled("0"));
    try testing.expect(!envFlagEnabled("false"));

    try testing.expect(isCodexFastModeSupportedModel("gpt-5.4"));
    try testing.expect(isCodexFastModeSupportedModel("openai/gpt-5.5"));
    try testing.expect(!isCodexFastModeSupportedModel("gpt-5.3-codex"));
    try testing.expectEqualStrings("low", codexVerbosity(true));
    try testing.expectEqualStrings("medium", codexVerbosity(false));
}

test "Codex provider rejects websocket transport before auth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const msg = protocol.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } };
    const ctx = protocol.Context{ .messages = &.{msg} };
    var provider = OpenAICodexProvider.init(alloc);
    var captured = ErrorCapture{};

    provider.provider().stream(
        alloc,
        codexTestModel(),
        ctx,
        .{ .transport = .websocket },
        ErrorCapture.callback,
        &captured,
    );

    try testing.expect(captured.seen);
    try testing.expectEqual(protocol.NormalizedFailure.Kind.invalid_request, captured.failure_kind.?);
    try testing.expect(std.mem.indexOf(u8, captured.message.?, "websocket transport is not supported") != null);
}

const ErrorCapture = struct {
    seen: bool = false,
    failure_kind: ?protocol.NormalizedFailure.Kind = null,
    message: ?[]const u8 = null,

    fn callback(event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void {
        const self: *ErrorCapture = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .@"error" => |err| {
                self.seen = true;
                self.failure_kind = if (err.@"error".failure) |failure| failure.kind else null;
                self.message = err.@"error".error_message;
            },
            else => {},
        }
    }
};

test "buildCodexRequestJson preserves Codex request contract" {
    const alloc = testing.allocator;
    var params = std.json.Value{ .object = .{} };
    defer params.object.deinit(alloc);
    const tool = protocol.Tool{
        .name = "bash",
        .description = "run shell",
        .parameters = params,
    };
    const msg = protocol.Message{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } };
    const ctx = protocol.Context{
        .system_prompt = "be precise",
        .messages = &.{msg},
        .tools = &.{tool},
    };
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(alloc);

    try buildCodexRequestJsonWithFastMode(alloc, &out, codexTestModel(), ctx, .{
        .session_id = "session-abc",
        .temperature = 0.25,
    }, "low", "auto", false);

    const parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    try testing.expectEqualStrings("gpt-5.4", root.get("model").?.string);
    try testing.expectEqualStrings("be precise", root.get("instructions").?.string);
    try testing.expectEqual(@as(usize, 1), root.get("input").?.array.items.len);
    try testing.expectEqualStrings("medium", root.get("text").?.object.get("verbosity").?.string);
    try testing.expectEqualStrings("reasoning.encrypted_content", root.get("include").?.array.items[0].string);
    try testing.expectEqualStrings("session-abc", root.get("prompt_cache_key").?.string);
    try testing.expectEqualStrings("auto", root.get("tool_choice").?.string);
    try testing.expect(root.get("parallel_tool_calls").?.bool);
    try testing.expectEqualStrings("low", root.get("reasoning").?.object.get("effort").?.string);
    try testing.expectEqualStrings("auto", root.get("reasoning").?.object.get("summary").?.string);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"temperature\":0.25") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"strict\":null") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"service_tier\"") == null);

    out.clearRetainingCapacity();
    try buildCodexRequestJsonWithFastMode(alloc, &out, codexTestModel(), ctx, .{}, null, null, false);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"reasoning\"") == null);

    out.clearRetainingCapacity();
    var fast_model = codexTestModel();
    fast_model.id = "gpt-5.5";
    try buildCodexRequestJsonWithFastMode(alloc, &out, fast_model, ctx, .{}, null, null, true);
    const fast_parsed = try std.json.parseFromSlice(std.json.Value, alloc, out.items, .{});
    defer fast_parsed.deinit();
    const fast_root = fast_parsed.value.object;
    try testing.expectEqualStrings("gpt-5.5", fast_root.get("model").?.string);
    try testing.expectEqualStrings("low", fast_root.get("text").?.object.get("verbosity").?.string);
    try testing.expectEqualStrings("priority", fast_root.get("service_tier").?.string);
}

fn codexTestModel() protocol.Model {
    return .{
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
