const std = @import("std");

pub const Env = struct {
    map: ?*const std.process.Environ.Map = null,

    pub const empty: Env = .{};

    pub fn from(map: *const std.process.Environ.Map) Env {
        return .{ .map = map };
    }

    pub fn get(self: Env, name: []const u8) ?[]const u8 {
        const environ_map = self.map orelse return null;
        return environ_map.get(name);
    }
};
