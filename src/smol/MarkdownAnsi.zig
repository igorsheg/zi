const std = @import("std");
const md4x = @import("md4x");
const SafeText = @import("SafeText.zig");

pub const RenderError = error{
    WriteFailed,
    MarkdownTooLarge,
    MarkdownOutputTooLarge,
    MarkdownRenderFailed,
};

const Sink = struct {
    writer: *std.Io.Writer,
    remaining: usize,
    written: usize = 0,
    failure: ?std.Io.Writer.Error = null,
    output_too_large: bool = false,

    fn append(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
        const self: *Sink = @ptrCast(@alignCast(userdata.?));
        if (self.failure != null or self.output_too_large) return;
        const bytes = text[0..@as(usize, @intCast(size))];
        if (bytes.len > self.remaining) {
            self.output_too_large = true;
            return;
        }
        self.writer.writeAll(bytes) catch |failure| {
            self.failure = failure;
            return;
        };
        self.remaining -= bytes.len;
        self.written += bytes.len;
    }
};

/// Renders one complete Markdown block. Source controls are neutralized before
/// the trusted ANSI renderer runs.
pub fn render(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    markdown: []const u8,
    max_output_bytes: usize,
) RenderError!usize {
    return renderWithFlags(allocator, writer, markdown, max_output_bytes, 0);
}

/// Renders one incomplete Markdown prefix for live streaming display. The
/// renderer heals unterminated constructs (open fences, emphasis spans) so a
/// growing block shows its visible prefix instead of parser fallback garbage.
pub fn renderPartial(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    markdown: []const u8,
    max_output_bytes: usize,
) RenderError!usize {
    return renderWithFlags(allocator, writer, markdown, max_output_bytes, md4x.MD_ANSI_FLAG_HEAL);
}

fn renderWithFlags(
    allocator: std.mem.Allocator,
    writer: *std.Io.Writer,
    markdown: []const u8,
    max_output_bytes: usize,
    renderer_flags: c_uint,
) RenderError!usize {
    var safe: std.Io.Writer.Allocating = .init(allocator);
    defer safe.deinit();
    try SafeText.write(&safe.writer, markdown, true);
    const source = safe.written();
    if (source.len > std.math.maxInt(c_uint)) return error.MarkdownTooLarge;

    var sink: Sink = .{
        .writer = writer,
        .remaining = max_output_bytes,
    };
    const result = md4x.md_ansi_ex(
        @ptrCast(source.ptr),
        @intCast(source.len),
        Sink.append,
        &sink,
        renderer_flags,
        null,
    );
    if (sink.failure) |failure| return failure;
    if (sink.output_too_large) return error.MarkdownOutputTooLarge;
    if (result != 0) return error.MarkdownRenderFailed;
    return sink.written;
}

test "markdown renders formatting once through md4x" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(std.testing.allocator, &output.writer, "Hello, **world**.", 1024);
    try std.testing.expect(std.mem.find(u8, output.written(), "Hello, ") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "world") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "**") == null);
}

test "markdown neutralizes source controls before trusted ANSI rendering" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        std.testing.allocator,
        &output.writer,
        "safe\x1b[2J\rtext\u{009b}tail\x9b",
        1024,
    );
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "safe") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "tail") != null);
}

test "markdown neutralizes encoded controls and hostile link destinations" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try render(
        std.testing.allocator,
        &output.writer,
        "entity &#27;[2J [link](https://example.test/\x07\x1b]8;;bad)",
        4096,
    );
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b]8;;bad") == null);
}

test "markdown enforces its output bound" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.MarkdownOutputTooLarge,
        render(std.testing.allocator, &output.writer, "long output", 4),
    );
}

test "partial rendering heals an unterminated code fence" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try renderPartial(
        std.testing.allocator,
        &output.writer,
        "Counting:\n\n```zig\nconst x = 1;",
        4096,
    );
    try std.testing.expect(std.mem.find(u8, output.written(), "Counting:") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "const x = 1;") != null);
}

test "partial rendering heals an unterminated emphasis span" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try renderPartial(std.testing.allocator, &output.writer, "working on **this", 1024);
    const rendered = output.written();
    try std.testing.expect(std.mem.find(u8, rendered, "this") != null);
    try std.testing.expect(std.mem.find(u8, rendered, "**") == null);
}

test "partial rendering neutralizes source controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    _ = try renderPartial(
        std.testing.allocator,
        &output.writer,
        "```\nsafe\x1b[2Jtail",
        1024,
    );
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b[2J") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "safe") != null);
}

test "partial rendering enforces its output bound" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try std.testing.expectError(
        error.MarkdownOutputTooLarge,
        renderPartial(std.testing.allocator, &output.writer, "long output", 4),
    );
}
