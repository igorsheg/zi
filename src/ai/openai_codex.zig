//! OpenAI Codex Responses provider — ChatGPT backend endpoint at
//! `https://chatgpt.com/backend-api/codex/responses`. Thin wrapper over
//! `openai_responses_core`, identical in shape to `openai_responses.zig`;
//! the only differences are the hard-coded base URL and the path.
//!
//! pi-mono source: `packages/ai/src/providers/openai-codex-responses.ts`
//!
//! ## Phase 3c scope
//!
//! Registered as `"openai-codex-responses"` in `Bundle.init`. Auth is a
//! bearer token passed through `StreamOptions.api_key` — phase 4 will
//! actually populate that field from `AuthStorage` oauth credentials
//! (PKCE login + refresh). Until then, invoking this provider without an
//! api_key set returns a clean `NoApiKey` error rather than a silent
//! no-op (the zi-yjc failure mode the Bundle exists to prevent).
//!
//! Intentionally NOT ported in phase 3c:
//!   - websocket transport (`responses_websockets=2026-02-06` beta)
//!   - `chatgpt-account-id` JWT claim extraction
//!   - custom SSE `response.done`/`response.failed` → `response.completed`
//!     remapping (the shared core already handles `response.completed`;
//!     codex-specific event remapping is phase 4 territory once we can
//!     live-exercise the endpoint)
//!   - `prompt_cache_key` / `parallel_tool_calls` / reasoning effort
//!     clamping (same deferrals as phase 3b)

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
        core.streamCore(allocator, model, context, options, .{
            // Honor `model.base_url` when set (models_generated.zig pins it
            // to `https://chatgpt.com/backend-api`); fall back to the same
            // literal if a model somehow arrives without one.
            .base_url = if (model.base_url.len > 0) null else "https://chatgpt.com/backend-api",
            .path = "/codex/responses",
            .auth = .{ .build = buildBearerAuth },
            .provider_label = "openai-codex-responses",
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
        streamWrap(ptr, allocator, model, context, options.base, callback, callback_ctx);
    }

    fn getName(_: *anyopaque) []const u8 {
        return "openai-codex-responses";
    }

    fn deinitImpl(_: *anyopaque) void {}
};

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
