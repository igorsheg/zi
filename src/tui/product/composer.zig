const std = @import("std");

const primitive = @import("../primitive/root.zig");

pub const Command = union(enum) {
    insert_text: []const u8,
    backspace,
    move_left,
    move_right,
    clear,
};

pub const Composer = struct {
    buffer: primitive.input_buffer.InputBuffer = .{},

    pub fn deinit(self: *Composer, allocator: std.mem.Allocator) void {
        self.buffer.deinit(allocator);
        self.* = undefined;
    }

    pub fn apply(self: *Composer, allocator: std.mem.Allocator, command: Command) !void {
        switch (command) {
            .insert_text => |bytes| try self.buffer.insert(allocator, bytes),
            .backspace => self.buffer.backspace(),
            .move_left => self.buffer.moveLeft(),
            .move_right => self.buffer.moveRight(),
            .clear => self.buffer.clearRetainingCapacity(),
        }
    }

    pub fn submit(self: *Composer, allocator: std.mem.Allocator) ![]u8 {
        const prompt = try allocator.dupe(u8, self.buffer.bytes.items);
        self.buffer.clearRetainingCapacity();
        return prompt;
    }
};

test "composer mutates through commands and submits owned prompt" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.apply(std.testing.allocator, .{ .insert_text = "hello" });
    try composer.apply(std.testing.allocator, .move_left);
    try composer.apply(std.testing.allocator, .{ .insert_text = "!" });

    const prompt = try composer.submit(std.testing.allocator);
    defer std.testing.allocator.free(prompt);

    try std.testing.expectEqualStrings("hell!o", prompt);
    try std.testing.expectEqualStrings("", composer.buffer.bytes.items);
}
