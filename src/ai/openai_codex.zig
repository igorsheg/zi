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
//! Also sends `originator: zi` and `OpenAI-Beta: responses=experimental`.
//!
//! Intentionally NOT ported:
//!   - websocket transport (`responses_websockets=2026-02-06` beta)
//!   - `prompt_cache_key` / `parallel_tool_calls` / reasoning effort
//!     clamping (tracked as zi-imj)

const std = @import("std");
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

        var extra_hdrs: [3]protocol.Header = undefined;
        var n_hdrs: usize = 0;

        // Extract chatgpt_account_id from access token JWT
        if (options.api_key) |key| {
            if (extractAccountId(scratch.allocator(), key)) |id| {
                extra_hdrs[n_hdrs] = .{ .key = "chatgpt-account-id", .value = id };
                n_hdrs += 1;
            }
        }
        extra_hdrs[n_hdrs] = .{ .key = "originator", .value = "zi" };
        n_hdrs += 1;
        extra_hdrs[n_hdrs] = .{ .key = "OpenAI-Beta", .value = "responses=experimental" };
        n_hdrs += 1;

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

        var extra_hdrs: [3]protocol.Header = undefined;
        var n_hdrs: usize = 0;
        if (options.base.api_key) |key| {
            if (extractAccountId(scratch.allocator(), key)) |id| {
                extra_hdrs[n_hdrs] = .{ .key = "chatgpt-account-id", .value = id };
                n_hdrs += 1;
            }
        }
        extra_hdrs[n_hdrs] = .{ .key = "originator", .value = "zi" };
        n_hdrs += 1;
        extra_hdrs[n_hdrs] = .{ .key = "OpenAI-Beta", .value = "responses=experimental" };
        n_hdrs += 1;

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
) anyerror!void {
    var allocating: std.io.Writer.Allocating = .init(allocator);
    defer allocating.deinit();
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

    try jw.objectField("tool_choice");
    try jw.write("auto");

    try jw.objectField("parallel_tool_calls");
    try jw.write(true);

    if (context.tools) |tools| {
        try core.writeTools(&jw, tools, false);
    }

    if (model.reasoning) {
        try jw.objectField("reasoning");
        try jw.beginObject();
        try jw.objectField("effort");
        try jw.write(reasoning_effort orelse "low");
        try jw.objectField("summary");
        try jw.write(reasoning_summary orelse "auto");
        try jw.endObject();
    }

    try jw.endObject();
    try out.appendSlice(allocator, allocating.written());
}

/// Extract chatgpt_account_id from a JWT access token.
/// pi-mono: openai-codex-responses.ts:282-287
fn extractAccountId(arena: std.mem.Allocator, token: []const u8) ?[]const u8 {
    // JWT = header.payload.signature
    var parts = std.mem.splitScalar(u8, token, '.');
    _ = parts.next() orelse return null;
    const payload_b64 = parts.next() orelse return null;

    const decoded_len = std.base64.url_safe_no_pad.Decoder.calcSizeForSlice(payload_b64) catch return null;
    const decoded = arena.alloc(u8, decoded_len) catch return null;
    std.base64.url_safe_no_pad.Decoder.decode(decoded, payload_b64) catch return null;

    const parsed = std.json.parseFromSlice(std.json.Value, arena, decoded, .{}) catch return null;
    if (parsed.value != .object) return null;

    const auth_claim = parsed.value.object.get("https://api.openai.com/auth") orelse return null;
    if (auth_claim != .object) return null;
    const id_val = auth_claim.object.get("chatgpt_account_id") orelse return null;
    if (id_val != .string or id_val.string.len == 0) return null;

    return id_val.string; // arena-owned, outlives streamCore call
}

/// Bearer auth factory. Reads the access token from `StreamOptions.api_key`;
/// phase 4 will populate that field from `AuthStorage` oauth credentials
/// (PKCE access_token, refreshed on expiry). If absent, return `NoApiKey`
/// so `streamCore` emits a clean error event instead of a silent no-op.
fn buildBearerAuth(
    _: ?*anyopaque,
    buf: []u8,
    api_key: ?[]const u8,
) error{ NoApiKey, BufferTooSmall }![]u8 {
    const key = api_key orelse return error.NoApiKey;
    if (key.len == 0) return error.NoApiKey;
    return std.fmt.bufPrint(buf, "Bearer {s}", .{key}) catch return error.BufferTooSmall;
}
