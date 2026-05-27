const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");

pub const AuthManager = struct {
    environ: ?*const std.process.Environ.Map = null,

    pub const Options = struct {
        environ: ?*const std.process.Environ.Map = null,
    };

    pub fn init(options: Options) AuthManager {
        return .{ .environ = options.environ };
    }

    pub fn hook(self: *const AuthManager) agent_mod.GetApiKeyHook {
        return .{ .context = @constCast(self), .call_fn = getApiKey };
    }

    pub fn findApiKey(self: *const AuthManager, provider: ai.Provider) ?ai.EnvApiKey {
        const environ = self.environ orelse return null;
        return ai.getEnvApiKey(environ, provider);
    }

    pub fn hasAuth(self: *const AuthManager, provider: ai.Provider) bool {
        return self.findApiKey(provider) != null;
    }

    fn getApiKey(
        allocator: std.mem.Allocator,
        context: ?*anyopaque,
        provider: ai.Provider,
    ) std.mem.Allocator.Error!?[]const u8 {
        const self: *const AuthManager = @ptrCast(@alignCast(context.?));
        const key = self.findApiKey(provider) orelse return null;
        const owned = try allocator.dupe(u8, key.value);
        return owned;
    }
};

test "auth manager returns configured env api key" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("OPENAI_API_KEY", "secret");

    var auth = AuthManager.init(.{ .environ = &environ });
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai);
    defer std.testing.allocator.free(key.?);

    try std.testing.expectEqualStrings("secret", key.?);
}

test "auth manager treats missing env as absent auth" {
    var auth = AuthManager.init(.{});
    const key = try agent_mod.GetApiKeyHook.call(std.testing.allocator, auth.hook(), ai.KnownProvider.openai);

    try std.testing.expectEqual(@as(?[]const u8, null), key);
}
