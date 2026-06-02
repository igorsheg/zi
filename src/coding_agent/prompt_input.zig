const std = @import("std");

const ai = @import("../ai/root.zig");

pub const StreamingBehavior = enum {
    steer,
    follow_up,
};

pub const Options = struct {
    streaming_behavior: ?StreamingBehavior = null,
};

pub const PreparedPromptInput = struct {
    text: []const u8,
    images: []const ai.ImageContent,
    streaming_behavior: ?StreamingBehavior,

    pub fn init(
        allocator: std.mem.Allocator,
        text: []const u8,
        images: []const ai.ImageContent,
        options: Options,
    ) !PreparedPromptInput {
        _ = allocator;
        return .{
            .text = text,
            .images = images,
            .streaming_behavior = options.streaming_behavior,
        };
    }
};

pub const Preflight = PreparedPromptInput;

test "prepared prompt input borrows text and carries options" {
    const text = "hello";
    const prepared = try PreparedPromptInput.init(std.testing.allocator, text, &.{}, .{
        .streaming_behavior = .follow_up,
    });
    try std.testing.expectEqualStrings(text, prepared.text);
    try std.testing.expectEqual(StreamingBehavior.follow_up, prepared.streaming_behavior.?);
}
