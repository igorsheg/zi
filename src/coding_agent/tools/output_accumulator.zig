const std = @import("std");
const output_tail = @import("output_tail.zig");

pub const Snapshot = struct {
    content: []const u8,
    dropped_bytes: usize,
    dropped_lines: usize,
    last_line_partial: bool,
    total_bytes: usize,
    total_lines: usize,
    truncated: bool,
    full_output_path: ?[]const u8 = null,
};

pub const Options = struct {
    max_bytes: usize,
    max_lines: usize,
};

pub const OutputAccumulator = struct {
    allocator: std.mem.Allocator,
    options: Options,
    tail: []u8 = &.{},
    dropped_bytes: usize = 0,
    dropped_lines: usize = 0,
    last_line_partial: bool = false,
    total_bytes: usize = 0,
    completed_lines: usize = 0,
    current_line_has_bytes: bool = false,

    pub fn init(allocator: std.mem.Allocator, options: Options) OutputAccumulator {
        std.debug.assert(options.max_bytes > 0);
        std.debug.assert(options.max_lines > 0);
        return .{ .allocator = allocator, .options = options };
    }

    pub fn deinit(self: *OutputAccumulator) void {
        self.allocator.free(self.tail);
        self.* = undefined;
    }

    pub fn append(self: *OutputAccumulator, bytes: []const u8) !void {
        self.total_bytes += bytes.len;
        for (bytes) |byte| {
            if (byte == '\n') {
                self.completed_lines += 1;
                self.current_line_has_bytes = false;
            } else {
                self.current_line_has_bytes = true;
            }
        }
        const next = try output_tail.appendTail(self.allocator, self.tail, bytes, .{
            .max_bytes = self.options.max_bytes,
            .max_lines = self.options.max_lines,
        });
        errdefer self.allocator.free(next.bytes);
        self.allocator.free(self.tail);
        self.tail = next.bytes;
        self.dropped_bytes += next.dropped_bytes;
        self.dropped_lines += next.dropped_lines;
        self.last_line_partial = next.last_line_partial;
    }

    pub fn snapshot(self: OutputAccumulator) Snapshot {
        return .{
            .content = self.tail,
            .dropped_bytes = self.dropped_bytes,
            .dropped_lines = self.dropped_lines,
            .last_line_partial = self.last_line_partial,
            .total_bytes = self.total_bytes,
            .total_lines = self.totalLines(),
            .truncated = self.dropped_bytes > 0 or self.dropped_lines > 0,
        };
    }

    pub fn totalLines(self: OutputAccumulator) usize {
        return self.completed_lines + @intFromBool(self.current_line_has_bytes);
    }
};

test "output accumulator keeps bounded tail and totals" {
    var acc = OutputAccumulator.init(std.testing.allocator, .{ .max_bytes = 20, .max_lines = 2 });
    defer acc.deinit();
    try acc.append("one\ntwo\nthree\nfour");
    const snap = acc.snapshot();
    try std.testing.expectEqualStrings("three\nfour", snap.content);
    try std.testing.expect(snap.truncated);
    try std.testing.expectEqual(@as(usize, 4), snap.total_lines);
}
