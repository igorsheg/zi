const std = @import("std");
const edit_buffer_mod = @import("tui/edit/buffer.zig");
const edit_layout_mod = @import("tui/edit/layout.zig");
const text_layout_mod = @import("tui/text/layout.zig");

const samples = 9;
const iterations = 400;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const edit_content = try buildEditContent(allocator);
    defer allocator.free(edit_content);
    const text_content = try buildTextContent(allocator);
    defer allocator.free(text_content);

    try runWorkload(allocator, edit_content, text_content);

    var values: [samples]u64 = undefined;
    for (&values) |*slot| {
        const start = std.Io.Clock.awake.now(std.Options.debug_io).toNanoseconds();
        try runWorkload(allocator, edit_content, text_content);
        const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toNanoseconds() - start;
        slot.* = @intCast(elapsed);
    }

    std.mem.sort(u64, &values, {}, comptime std.sort.asc(u64));
    const median_ns = values[values.len / 2];
    const layout_ms = @as(f64, @floatFromInt(median_ns)) / 1_000_000.0;
    const edit_lines = try measureEditLines(allocator, edit_content);
    const text_lines = try measureTextLines(allocator, text_content);

    var stdout_buf: [1024]u8 = undefined;
    const stdout_file: std.Io.File = .{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout = stdout_file.writer(std.Options.debug_io, &stdout_buf);
    const w = &stdout.interface;
    try w.print("METRIC layout_ms={d:.3}\n", .{layout_ms});
    try w.print("METRIC edit_lines={d}\n", .{edit_lines});
    try w.print("METRIC text_lines={d}\n", .{text_lines});
    try stdout.flush();
}

fn buildEditContent(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (0..240) |i| {
        try w.print(
            \\edit line {d}: ask the agent to refactor the current subsystem with enough words to wrap repeatedly in the composer input and include identifiers_like_this plus 一二三 wide chars.
            \\
        , .{i});
    }
    return try out.toOwnedSlice();
}

fn buildTextContent(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    for (0..180) |i| {
        try w.print(
            \\plain text row {d}: reusable text layout wraps content for status panels, reports, and overlays. This workload keeps ascii dominant with occasional 一二三 unicode.
            \\
        , .{i});
    }
    return try out.toOwnedSlice();
}

fn runWorkload(allocator: std.mem.Allocator, edit_content: []const u8, text_content: []const u8) !void {
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        var buffer = edit_buffer_mod.EditBuffer.init(allocator, .wcwidth);
        defer buffer.deinit();
        buffer.setText(edit_content);

        var cache = edit_layout_mod.TextAreaLayoutCache.init(allocator);
        defer cache.deinit();
        cache.ensure(&buffer, .{ .width_cols = 88, .first_line_text_col = 3, .continuation_text_col = 3 });
        std.mem.doNotOptimizeAway(cache.lines().len);

        const word = try text_layout_mod.wrapLines(text_content, 90, .word, allocator, .wcwidth);
        defer allocator.free(word);
        std.mem.doNotOptimizeAway(word.len);

        const char = try text_layout_mod.wrapLines(text_content, 90, .char, allocator, .wcwidth);
        defer allocator.free(char);
        std.mem.doNotOptimizeAway(char.len);
    }
}

fn measureEditLines(allocator: std.mem.Allocator, edit_content: []const u8) !usize {
    var buffer = edit_buffer_mod.EditBuffer.init(allocator, .wcwidth);
    defer buffer.deinit();
    buffer.setText(edit_content);
    var cache = edit_layout_mod.TextAreaLayoutCache.init(allocator);
    defer cache.deinit();
    cache.ensure(&buffer, .{ .width_cols = 88, .first_line_text_col = 3, .continuation_text_col = 3 });
    return cache.lines().len;
}

fn measureTextLines(allocator: std.mem.Allocator, text_content: []const u8) !usize {
    const lines = try text_layout_mod.wrapLines(text_content, 90, .word, allocator, .wcwidth);
    defer allocator.free(lines);
    return lines.len;
}
