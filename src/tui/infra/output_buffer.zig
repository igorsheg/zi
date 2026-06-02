const std = @import("std");

pub const frame_output_size_default: usize = 2 * 1024 * 1024;
pub const frame_output_size_min: usize = 64 * 1024;

pub const FrameOutput = struct {
    storage: []u8,
    len_value: usize = 0,

    pub fn init(storage: []u8) FrameOutput {
        return .{ .storage = storage };
    }
    pub fn capacity(self: FrameOutput) usize {
        return self.storage.len;
    }
    pub fn len(self: FrameOutput) usize {
        return self.len_value;
    }
    pub fn reset(self: *FrameOutput) void {
        self.len_value = 0;
    }
    pub fn mark(self: FrameOutput) usize {
        return self.len_value;
    }
    pub fn rollback(self: *FrameOutput, m: usize) void {
        std.debug.assert(m <= self.len_value);
        self.len_value = m;
    }
    pub fn bytes(self: FrameOutput) []const u8 {
        return self.storage[0..self.len_value];
    }
    pub fn writtenSince(self: FrameOutput, m: usize) []const u8 {
        std.debug.assert(m <= self.len_value);
        return self.storage[m..self.len_value];
    }
    pub fn append(self: *FrameOutput, data: []const u8) error{NoSpaceLeft}!void {
        if (data.len > self.storage.len - self.len_value) return error.NoSpaceLeft;
        @memcpy(self.storage[self.len_value..][0..data.len], data);
        self.len_value += data.len;
    }
    pub fn putByte(self: *FrameOutput, byte: u8) error{NoSpaceLeft}!void {
        try self.append(&.{byte});
    }
};

pub const OutputBuffer = FrameOutput;

test "frame output mark rollback capacity" {
    var storage: [3]u8 = undefined;
    var b = FrameOutput.init(&storage);
    try b.append("ab");
    const m = b.mark();
    try b.append("c");
    try std.testing.expectError(error.NoSpaceLeft, b.append("d"));
    b.rollback(m);
    try std.testing.expectEqualStrings("ab", b.bytes());
    try std.testing.expectEqual(@as(usize, 3), b.capacity());
}
