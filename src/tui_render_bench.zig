const std = @import("std");
const Markdown = @import("tui/transcript/markdown.zig").Markdown;
const Buffer = @import("tui/primitives/surface.zig").Buffer;

const samples = 9;
const iterations = 40;

pub fn main() !void {
    var debug_allocator = std.heap.DebugAllocator(.{}){};
    defer _ = debug_allocator.deinit();
    const allocator = debug_allocator.allocator();

    const content = try buildContent(allocator);
    defer allocator.free(content);

    // Warm compiler/runtime caches and retained Markdown layout cache behavior.
    try runWorkload(allocator, content);

    var values: [samples]u64 = undefined;
    for (&values) |*slot| {
        const start = std.Io.Clock.awake.now(std.Options.debug_io).toNanoseconds();
        try runWorkload(allocator, content);
        const elapsed = std.Io.Clock.awake.now(std.Options.debug_io).toNanoseconds() - start;
        slot.* = @intCast(elapsed);
    }

    std.mem.sort(u64, &values, {}, comptime std.sort.asc(u64));
    const median_ns = values[values.len / 2];
    const render_ms = @as(f64, @floatFromInt(median_ns)) / 1_000_000.0;
    const rows = try measureRows(allocator, content);

    var stdout_buf: [1024]u8 = undefined;
    const stdout_file: std.Io.File = .{ .handle = std.posix.STDOUT_FILENO, .flags = .{ .nonblocking = false } };
    var stdout = stdout_file.writer(std.Options.debug_io, &stdout_buf);
    const w = &stdout.interface;
    try w.print("METRIC render_ms={d:.3}\n", .{render_ms});
    try w.print("METRIC rows={d}\n", .{rows});
    try stdout.flush();
}

fn buildContent(allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const writer = &out.writer;
    for (0..180) |i| {
        try writer.print(
            \\## Section {d}
            \\
            \\This is a long assistant response paragraph with enough words to force wrapping across many terminal columns. It includes `inline code`, punctuation, identifiers_like_this, and repeated structure for stable benchmark behavior.
            \\
            \\- bullet item one has normal prose and trailing context for wrapping decisions
            \\- bullet item two contains 一二三 wide characters mixed with ascii text and more words
            \\
            \\```zig
            \\const value_{d} = try computeSomething(allocator, input);
            \\defer value_{d}.deinit();
            \\```
            \\
            \\
        , .{ i, i, i });
    }
    return try out.toOwnedSlice();
}

fn runWorkload(allocator: std.mem.Allocator, content: []const u8) !void {
    var md = Markdown.init(allocator, .wcwidth);
    defer md.deinit();
    md.setContent(content);
    md.padding_x = 1;

    var buf = try Buffer.init(allocator, 100, 38, .wcwidth);
    defer buf.deinit();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        md.invalidate();
        _ = md.measure(100);
        md.render(buf.region());
    }
}

fn measureRows(allocator: std.mem.Allocator, content: []const u8) !u32 {
    var md = Markdown.init(allocator, .wcwidth);
    defer md.deinit();
    md.setContent(content);
    md.padding_x = 1;
    return md.measure(100).preferred_height;
}
