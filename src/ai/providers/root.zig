const std = @import("std");
const provider_api = @import("../provider.zig");

pub const openai_codex = @import("openai_codex.zig");

const codex_oauth: openai_codex.OAuth = .{};

pub const builtin = [_]provider_api.Definition{
    .{
        .id = "openai",
        .name = "OpenAI",
        .base_url = "https://api.openai.com/v1",
        .auth = .{ .api_key = .{ .environment_names = &.{"OPENAI_API_KEY"} } },
    },
    .{
        .id = "openai-codex",
        .name = "OpenAI Codex",
        .base_url = "https://chatgpt.com/backend-api",
        .auth = .{ .oauth = .{
            .authenticator = codex_oauth.authenticator(),
            .refresher = codex_oauth.refresher(),
        } },
    },
};

test "built-in providers have distinct identities" {
    for (builtin, 0..) |provider, index| {
        try std.testing.expect(provider.id.len > 0);
        for (builtin[0..index]) |previous| {
            try std.testing.expect(!std.mem.eql(u8, previous.id, provider.id));
        }
    }
}
