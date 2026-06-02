const std = @import("std");

const ai = @import("../ai/root.zig");

pub const StreamingBehavior = enum {
    steer,
    follow_up,
};

pub const Options = struct {
    streaming_behavior: ?StreamingBehavior = null,
};

pub const Preflight = struct {
    text: []const u8,
    images: []const ai.ImageContent,
    streaming_behavior: ?StreamingBehavior,

    pub fn init(
        allocator: std.mem.Allocator,
        text: []const u8,
        images: []const ai.ImageContent,
        options: Options,
    ) !Preflight {
        return .{
            .text = try allocator.dupe(u8, text),
            .images = images,
            .streaming_behavior = options.streaming_behavior,
        };
    }

    pub fn deinit(self: *Preflight, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};
