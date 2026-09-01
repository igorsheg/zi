const std = @import("std");
const text_module = @import("../text/root.zig");
const DisplayWidth = text_module.DisplayWidth;
const Theme = @import("Theme.zig");

const minimum_columns = 20;
const first_indent = 2;
const continuation_indent = 4;
const max_segment_bytes = 4096;
const bold: Theme.Style = .{ .open = "\x1b[1m", .close = "\x1b[22m" };
const dim: Theme.Style = .{ .open = "\x1b[2m", .close = "\x1b[22m" };

/// Borrowed values used by the startup banner. Production startup validates
/// provider and model separately; optional fields keep this library renderer
/// safe for diagnostics and partial startup states.
pub const Identity = struct {
    preset: ?[]const u8 = null,
    provider: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
};

pub const Error = error{ WriteFailed, IdentityTooLong };

/// Render the identity and honest interaction tips into the normal buffer.
/// No allocation is performed. Dynamic segments are bounded to
/// `max_segment_bytes` sanitized bytes on the stack.
pub fn render(writer: *std.Io.Writer, theme: Theme, columns: usize, identity: Identity) Error!void {
    return renderInternal(writer, theme, columns, identity, true);
}

/// Renders the same bounded banner without terminal control sequences.
pub fn renderPlain(writer: *std.Io.Writer, theme: Theme, columns: usize, identity: Identity) Error!void {
    return renderInternal(writer, theme, columns, identity, false);
}

fn renderInternal(
    writer: *std.Io.Writer,
    theme: Theme,
    columns: usize,
    identity: Identity,
    styled: bool,
) Error!void {
    errdefer if (styled) {
        writer.writeAll("\x1b[0m") catch {};
        writer.flush() catch {};
    };
    var renderer: Renderer = .{
        .writer = writer,
        .theme = theme,
        .columns = @max(columns, minimum_columns),
        .styled = styled,
    };

    try renderer.openRow();
    try renderer.put("", bold, "zi");

    var preset_buffer: [max_segment_bytes]u8 = undefined;
    if (nonEmpty(identity.preset)) |preset| {
        const stance = try compose(&preset_buffer, &.{ "[", preset, "]" });
        try renderer.put(" ", theme.stance, stance);
    }

    var provider_buffer: [max_segment_bytes]u8 = undefined;
    const provider = nonEmpty(identity.provider) orelse "no provider";
    const provider_text = try compose(&provider_buffer, &.{ "› ", provider });
    try renderer.put(" ", dim, provider_text);

    var tail_buffer: [max_segment_bytes]u8 = undefined;
    const model = nonEmpty(identity.model);
    const model_text = if (model) |value| nonEmpty(identity.model_label) orelse value else "no model";
    const effort = nonEmpty(identity.effort);
    const tail = if (model != null and effort != null)
        try compose(&tail_buffer, &.{ model_text, " · ", effort.? })
    else
        try compose(&tail_buffer, &.{model_text});
    try renderer.put(" · ", dim, tail);
    try renderer.closeRow();

    try renderer.openRow();
    try renderer.put("", dim, "ctrl-d quit");
    try renderer.put(" · ", dim, "esc pause");
    try renderer.put(" · ", dim, "esc esc abort");
    try renderer.closeRow();
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

fn compose(buffer: []u8, pieces: []const []const u8) error{IdentityTooLong}![]const u8 {
    var length: usize = 0;
    for (pieces) |piece| {
        var glyphs = DisplayWidth.iterator(piece);
        while (glyphs.next()) |glyph| {
            if (glyph.bytes.len > buffer.len - length) return error.IdentityTooLong;
            @memcpy(buffer[length..][0..glyph.bytes.len], glyph.bytes);
            length += glyph.bytes.len;
        }
    }
    return buffer[0..length];
}

const Renderer = struct {
    writer: *std.Io.Writer,
    theme: Theme,
    columns: usize,
    col: usize = first_indent,
    fresh: bool = true,
    style: ?Theme.Style = null,
    styled: bool = true,

    fn openRow(self: *Renderer) std.Io.Writer.Error!void {
        try self.writeGutter(first_indent);
        self.col = first_indent;
        self.fresh = true;
    }

    fn closeRow(self: *Renderer) std.Io.Writer.Error!void {
        try self.setStyle(null);
        try self.writer.writeByte('\n');
    }

    fn rowBreak(self: *Renderer) std.Io.Writer.Error!void {
        try self.setStyle(null);
        try self.writer.writeByte('\n');
        try self.writeGutter(continuation_indent);
        self.col = continuation_indent;
        self.fresh = true;
    }

    fn writeGutter(self: *Renderer, indent: usize) std.Io.Writer.Error!void {
        if (self.styled) try self.writer.writeAll(self.theme.chrome.open);
        try self.writer.writeAll("▌");
        if (self.styled) try self.writer.writeAll(self.theme.chrome.close);
        try self.writer.splatByteAll(' ', indent - 1);
    }

    fn setStyle(self: *Renderer, next: ?Theme.Style) std.Io.Writer.Error!void {
        if (!self.styled) return;
        if (stylesEqual(self.style, next)) return;
        if (self.style) |current| try self.writer.writeAll(current.close);
        if (next) |new| try self.writer.writeAll(new.open);
        self.style = next;
    }

    fn put(self: *Renderer, separator: []const u8, style: Theme.Style, text: []const u8) std.Io.Writer.Error!void {
        var offset: usize = 0;
        var cells = DisplayWidth.visibleWidth(text, std.math.maxInt(usize));
        if (!self.fresh) {
            const separator_cells = DisplayWidth.visibleWidth(separator, std.math.maxInt(usize));
            if (self.col +| separator_cells +| cells > self.columns) {
                try self.rowBreak();
            } else {
                try self.setStyle(style);
                try self.writer.writeAll(separator);
                self.col += separator_cells;
            }
        }

        try self.setStyle(style);
        while (cells > self.columns - self.col) {
            const split = breakPosition(text[offset..], self.columns - self.col);
            if (split.row_bytes != 0)
                try self.writer.writeAll(text[offset..][0..split.row_bytes]);
            offset += split.next_bytes;
            try self.rowBreak();
            try self.setStyle(style);
            cells = DisplayWidth.visibleWidth(text[offset..], std.math.maxInt(usize));
        }
        try self.writer.writeAll(text[offset..]);
        self.col += cells;
        self.fresh = false;
    }
};

const Break = struct {
    row_bytes: usize,
    next_bytes: usize,
};

/// Prefer the last ASCII space that fits. Otherwise hard-break at a decoded
/// glyph boundary. If no glyph fits, the caller starts a continuation row.
fn breakPosition(text: []const u8, maximum_cells: usize) Break {
    std.debug.assert(text.len != 0);
    std.debug.assert(maximum_cells != 0);

    var offset: usize = 0;
    var cells: usize = 0;
    var last_space: ?usize = null;
    while (offset < text.len) {
        const glyph = DisplayWidth.next(text, offset).?;
        if (cells + glyph.width > maximum_cells) {
            if (glyph.is_ascii_space and cells == maximum_cells) last_space = offset;
            break;
        }
        if (glyph.is_ascii_space) last_space = offset;
        cells += glyph.width;
        offset += glyph.consumed;
    }
    if (offset == text.len) return .{ .row_bytes = offset, .next_bytes = offset };
    if (last_space) |space| {
        var row_end = space;
        while (row_end != 0 and text[row_end - 1] == ' ') row_end -= 1;
        return .{ .row_bytes = row_end, .next_bytes = space + 1 };
    }
    if (offset != 0) return .{ .row_bytes = offset, .next_bytes = offset };

    // Nothing fits in the remainder. Start a continuation row before writing
    // the first wide glyph so the terminal does not auto-wrap ahead of us.
    return .{ .row_bytes = 0, .next_bytes = 0 };
}

fn stylesEqual(a: ?Theme.Style, b: ?Theme.Style) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?.open, b.?.open) and std.mem.eql(u8, a.?.close, b.?.close);
}

fn offTheme() Theme {
    return Theme.resolve(.{ .configured_theme = "off", .configured_tint = "teal" }) catch unreachable;
}

fn renderAlloc(columns: usize, identity: Identity) ![]u8 {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    errdefer output.deinit();
    try render(&output.writer, offTheme(), columns, identity);
    return output.toOwnedSlice();
}

test "visible banner at 100 40 and 20 columns" {
    const identity: Identity = .{
        .preset = "focused",
        .provider = "anthropic",
        .model = "claude-sonnet-4",
        .effort = "high",
    };
    const wide = try renderAlloc(100, identity);
    defer std.testing.allocator.free(wide);
    try std.testing.expectEqualStrings(
        "▌ \x1b[1mzi\x1b[22m [focused]\x1b[2m › anthropic · claude-sonnet-4 · high\x1b[22m\n" ++
            "▌ \x1b[2mctrl-d quit · esc pause · esc esc abort\x1b[22m\n",
        wide,
    );

    const medium = try renderAlloc(40, identity);
    defer std.testing.allocator.free(medium);
    try std.testing.expectEqualStrings(
        "▌ \x1b[1mzi\x1b[22m [focused]\x1b[2m › anthropic\x1b[22m\n" ++
            "▌   \x1b[2mclaude-sonnet-4 · high\x1b[22m\n" ++
            "▌ \x1b[2mctrl-d quit · esc pause\x1b[22m\n" ++
            "▌   \x1b[2mesc esc abort\x1b[22m\n",
        medium,
    );

    const narrow = try renderAlloc(20, identity);
    defer std.testing.allocator.free(narrow);
    try std.testing.expectEqualStrings(
        "▌ \x1b[1mzi\x1b[22m [focused]\n" ++
            "▌   \x1b[2m› anthropic\x1b[22m\n" ++
            "▌   \x1b[2mclaude-sonnet-4\x1b[22m\n" ++
            "▌   \x1b[2m· high\x1b[22m\n" ++
            "▌ \x1b[2mctrl-d quit\x1b[22m\n" ++
            "▌   \x1b[2mesc pause\x1b[22m\n" ++
            "▌   \x1b[2mesc esc abort\x1b[22m\n",
        narrow,
    );
}

test "plain banner emits no terminal controls" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try renderPlain(&output.writer, offTheme(), 80, .{
        .preset = "review",
        .provider = "mock",
        .model = "mock-model",
    });
    try std.testing.expect(std.mem.indexOfScalar(u8, output.written(), 0x1b) == null);
    try std.testing.expectEqualStrings(
        "▌ zi [review] › mock · mock-model\n" ++
            "▌ ctrl-d quit · esc pause · esc esc abort\n",
        output.written(),
    );
}

test "label selection fallbacks and separator edge" {
    const label = try renderAlloc(100, .{ .provider = "openai", .model_label = "friendly", .model = "raw" });
    defer std.testing.allocator.free(label);
    try std.testing.expect(std.mem.indexOf(u8, label, "› openai · friendly") != null);

    const fallback = try renderAlloc(100, .{});
    defer std.testing.allocator.free(fallback);
    try std.testing.expect(std.mem.indexOf(u8, fallback, "› no provider · no model") != null);

    const edge = try renderAlloc(20, .{ .provider = "123456789012", .model = "m" });
    defer std.testing.allocator.free(edge);
    try std.testing.expect(std.mem.indexOf(u8, edge, "123456789012\x1b[22m\n▌   \x1b[2mm") != null);
    try std.testing.expect(std.mem.indexOf(u8, edge, "▌   \x1b[2m · m") == null);
}

test "wide glyph moves before a one-cell row remainder" {
    const output = try renderAlloc(20, .{
        .provider = "x",
        .model = "123456789012345界",
    });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(
        u8,
        output,
        "123456789012345\x1b[22m\n▌   \x1b[2m界",
    ) != null);
}

test "long wide combining and unsafe identity text wraps safely" {
    const output = try renderAlloc(20, .{
        .preset = "abcdefghijabcdefghij",
        .provider = "界界e\xcc\x81\x1b",
        .model = "supercalifragilisticexpialidocious",
    });
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "界界e\xcc\x81?") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\x1b\x1b") == null);
}

test "bounded composition and writer failure are reported" {
    var oversized: [max_segment_bytes + 1]u8 = @splat('x');
    var output_buffer: [0]u8 = .{};
    var output: std.Io.Writer.Discarding = .init(&output_buffer);
    try std.testing.expectError(error.IdentityTooLong, render(&output.writer, offTheme(), 100, .{
        .provider = &oversized,
    }));

    var storage: [1]u8 = undefined;
    var failed = std.Io.Writer.fixed(&storage);
    try std.testing.expectError(error.WriteFailed, render(&failed, offTheme(), 100, .{}));
}
