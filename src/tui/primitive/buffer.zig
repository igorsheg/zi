const std = @import("std");

pub const BufferId = enum(u32) {
    chat = 1,
    input = 2,
    diagnostics = 3,
    header = 4,
    status = 5,
    _,
};

pub const Kind = enum {
    chat,
    input,
    tool_output,
    diagnostics,
    status,
    scratch,
};

pub const Buffer = struct {
    pub const max_bytes_default = 1024 * 1024;
    pub const append_bytes_max = 16 * 1024;

    id: BufferId,
    kind: Kind,
    name: []const u8,
    revision: u64 = 0,
    bytes: std.ArrayList(u8) = .empty,
    max_bytes: usize = max_bytes_default,
    dropped_prefix_byte_count: usize = 0,

    pub fn init(id: BufferId, kind: Kind, name: []const u8) Buffer {
        std.debug.assert(name.len > 0);
        return .{
            .id = id,
            .kind = kind,
            .name = name,
        };
    }

    pub fn deinit(self: *Buffer, allocator: std.mem.Allocator) void {
        self.bytes.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(self: *Buffer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes.len > append_bytes_max) return error.BufferAppendTooLarge;
        try self.trimForAppend(bytes.len);

        try self.bytes.appendSlice(allocator, bytes);
        self.revision += 1;
    }

    fn trimForAppend(self: *Buffer, append_byte_count: usize) !void {
        std.debug.assert(append_byte_count <= append_bytes_max);
        if (append_byte_count > self.max_bytes) return error.BufferFull;
        if (self.bytes.items.len + append_byte_count <= self.max_bytes) return;

        const overflow_byte_count = self.bytes.items.len + append_byte_count - self.max_bytes;
        const trim_byte_count = @min(self.bytes.items.len, overflow_byte_count);
        const kept_byte_count = self.bytes.items.len - trim_byte_count;
        // Left-shift the surviving suffix over the dropped prefix; the ranges
        // overlap, so @memmove (not @memcpy) is required.
        @memmove(self.bytes.items[0..kept_byte_count], self.bytes.items[trim_byte_count..]);
        self.bytes.shrinkRetainingCapacity(kept_byte_count);
        self.dropped_prefix_byte_count += trim_byte_count;
    }

    pub fn clear(self: *Buffer, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.bytes.clearRetainingCapacity();
        self.revision += 1;
    }

    pub fn text(self: *const Buffer) []const u8 {
        return self.bytes.items;
    }
};

test "buffer revisions advance only on mutation" {
    var buf = Buffer.init(.chat, .chat, "chat");
    defer buf.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u64, 0), buf.revision);
    try buf.append(std.testing.allocator, "hi");
    try std.testing.expectEqual(@as(u64, 1), buf.revision);
    try std.testing.expectEqualStrings("hi", buf.text());
}

test "buffer trims old content instead of failing when full" {
    var buf = Buffer.init(.chat, .chat, "chat");
    defer buf.deinit(std.testing.allocator);
    buf.max_bytes = 5;

    try buf.append(std.testing.allocator, "hello");
    try buf.append(std.testing.allocator, "!");
    try std.testing.expectEqualStrings("ello!", buf.text());
    try std.testing.expectEqual(@as(usize, 1), buf.dropped_prefix_byte_count);
}
