const std = @import("std");

pub const OutputBuffer = struct {
    bytes: []u8,
    len: usize = 0,

    pub fn init(storage: []u8) OutputBuffer { return .{ .bytes = storage }; }
    pub fn reset(self: *OutputBuffer) void { self.len = 0; }
    pub fn slice(self: OutputBuffer) []const u8 { return self.bytes[0..self.len]; }
    pub fn append(self: *OutputBuffer, data: []const u8) error{NoSpaceLeft}!void {
        if (data.len > self.bytes.len - self.len) return error.NoSpaceLeft;
        @memcpy(self.bytes[self.len..][0..data.len], data);
        self.len += data.len;
    }
};

test "output buffer capacity and reset" {
    var storage: [3]u8 = undefined;
    var b = OutputBuffer.init(&storage);
    try b.append("abc");
    try std.testing.expectError(error.NoSpaceLeft, b.append("d"));
    b.reset();
    try b.append("d");
    try std.testing.expectEqualStrings("d", b.slice());
}
