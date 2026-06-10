//! Atomic file replacement shared by the edit and write tools: write to a
//! unique temp file next to the target, stream bounded utf8-safe chunks to the
//! tool update callback, then rename over the target.

const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");

pub const update_chunk_bytes = 16 * 1024;

var temp_file_counter: std.atomic.Value(u64) = .init(0);

pub fn atomicWriteFileStreamingUpdates(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    content: []const u8,
    on_update: ?agent.AgentToolUpdateCallback,
) !void {
    const stamp = std.Io.Clock.awake.now(io).nanoseconds;
    const counter = temp_file_counter.fetchAdd(1, .monotonic);
    const temp_path = try std.fmt.allocPrint(allocator, "{s}.zi-tmp-{d}-{d}", .{ path, stamp, counter });
    defer allocator.free(temp_path);
    errdefer std.Io.Dir.deleteFile(.cwd(), io, temp_path) catch {};

    const file = try std.Io.Dir.createFile(.cwd(), io, temp_path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var writer = file.writer(io, &buffer);
    var offset: usize = 0;
    while (offset < content.len) {
        const end = utf8ChunkEnd(content, offset, @min(content.len, offset + update_chunk_bytes));
        const chunk = content[offset..end];
        try writer.interface.writeAll(chunk);
        try emitUpdate(allocator, on_update, chunk);
        offset = end;
    }
    try writer.flush();
    try std.Io.Dir.rename(.cwd(), temp_path, .cwd(), path, io);
}

fn emitUpdate(
    allocator: std.mem.Allocator,
    on_update: ?agent.AgentToolUpdateCallback,
    chunk: []const u8,
) !void {
    const callback = on_update orelse return;
    const text = try allocator.dupe(u8, chunk);
    defer allocator.free(text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    defer allocator.free(content);
    content[0] = .{ .text = .{ .text = text } };
    try callback.call(.{ .content = content });
}

fn utf8ChunkEnd(content: []const u8, start: usize, proposed_end: usize) usize {
    std.debug.assert(start < proposed_end);
    std.debug.assert(proposed_end <= content.len);
    if (proposed_end == content.len) return proposed_end;
    var end = proposed_end;
    while (end > start and (content[end] & 0xc0) == 0x80) : (end -= 1) {}
    if (end == start) return proposed_end;
    return end;
}

test "utf8 chunk end never splits a codepoint" {
    const text = "ab" ++ "中"; // 0x4e2d is 3 bytes
    try std.testing.expectEqual(@as(usize, 2), utf8ChunkEnd(text, 0, 3));
    try std.testing.expectEqual(@as(usize, 2), utf8ChunkEnd(text, 0, 4));
    try std.testing.expectEqual(text.len, utf8ChunkEnd(text, 0, text.len));
}
