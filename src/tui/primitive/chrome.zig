const std = @import("std");
const cell_buffer = @import("../infra/cell_buffer.zig");
const CellBuffer = cell_buffer.CellBuffer;
const CellBufferError = cell_buffer.Error;
const Rect = @import("rect.zig").Rect;
const Style = @import("style.zig").Style;

pub const BorderSides = packed struct {
    top: bool = true,
    right: bool = true,
    bottom: bool = true,
    left: bool = true,

    pub const none: BorderSides = .{ .top = false, .right = false, .bottom = false, .left = false };
    pub const all: BorderSides = .{};
};

pub const BorderGlyphs = struct {
    top_left: []const u8,
    top_right: []const u8,
    bottom_left: []const u8,
    bottom_right: []const u8,
    horizontal: []const u8,
    vertical: []const u8,

    pub const rounded: BorderGlyphs = .{
        .top_left = "╭",
        .top_right = "╮",
        .bottom_left = "╰",
        .bottom_right = "╯",
        .horizontal = "─",
        .vertical = "│",
    };

    pub const square: BorderGlyphs = .{
        .top_left = "┌",
        .top_right = "┐",
        .bottom_left = "└",
        .bottom_right = "┘",
        .horizontal = "─",
        .vertical = "│",
    };
};

pub const BorderSpec = struct {
    sides: BorderSides = .all,
    glyphs: BorderGlyphs = .rounded,
    style: Style = .{},
};

pub const BoxVariant = enum { open, closed };

pub const MeasuredText = struct {
    text: []const u8,
    width: usize,
};

pub const BorderLabelPair = struct {
    left: ?MeasuredText = null,
    right: ?MeasuredText = null,
};

pub fn innerRect(rect: Rect, sides: BorderSides) Rect {
    if (rect.isEmpty()) return Rect.empty();
    const left_inset: u16 = if (sides.left and rect.width > 0) 1 else 0;
    const right_inset: u16 = if (sides.right and rect.width > left_inset) 1 else 0;
    const top_inset: u16 = if (sides.top and rect.height > 0) 1 else 0;
    const bottom_inset: u16 = if (sides.bottom and rect.height > top_inset) 1 else 0;
    if (rect.width <= left_inset + right_inset or rect.height <= top_inset + bottom_inset) return Rect.empty();
    return .{
        .x = rect.x + left_inset,
        .y = rect.y + top_inset,
        .width = rect.width - left_inset - right_inset,
        .height = rect.height - top_inset - bottom_inset,
    };
}

pub fn drawBorder(buffer: *CellBuffer, rect: Rect, spec: BorderSpec) CellBufferError!Rect {
    if (rect.isEmpty()) return Rect.empty();
    const clipped = rect.clip(.{ .x = 0, .y = 0, .width = buffer.width, .height = buffer.height });
    if (clipped.isEmpty()) {
        return innerRect(rect, spec.sides).clip(.{
            .x = 0,
            .y = 0,
            .width = buffer.width,
            .height = buffer.height,
        });
    }

    const x0 = rect.x;
    const y0 = rect.y;
    const x1: u16 = @intCast(@as(u32, rect.x) + rect.width - 1);
    const y1: u16 = @intCast(@as(u32, rect.y) + rect.height - 1);

    if (spec.sides.top and y0 < buffer.height) {
        if (spec.sides.left and x0 < buffer.width) {
            try buffer.writeText(x0, y0, spec.glyphs.top_left, spec.style);
        }
        if (rect.width > 1 and spec.sides.right and x1 < buffer.width) {
            try buffer.writeText(x1, y0, spec.glyphs.top_right, spec.style);
        }
        if (rect.width > 2) {
            try drawHorizontalLine(buffer, x0 + 1, y0, rect.width - 2, spec.glyphs.horizontal, spec.style);
        }
    }
    if (rect.height > 1 and spec.sides.bottom and y1 < buffer.height) {
        if (spec.sides.left and x0 < buffer.width) {
            try buffer.writeText(x0, y1, spec.glyphs.bottom_left, spec.style);
        }
        if (rect.width > 1 and spec.sides.right and x1 < buffer.width) {
            try buffer.writeText(x1, y1, spec.glyphs.bottom_right, spec.style);
        }
        if (rect.width > 2) {
            try drawHorizontalLine(buffer, x0 + 1, y1, rect.width - 2, spec.glyphs.horizontal, spec.style);
        }
    }
    if (rect.height > 2) {
        if (spec.sides.left and x0 < buffer.width) {
            try drawVerticalLine(buffer, x0, y0 + 1, rect.height - 2, spec.glyphs.vertical, spec.style);
        }
        if (rect.width > 1 and spec.sides.right and x1 < buffer.width) {
            try drawVerticalLine(buffer, x1, y0 + 1, rect.height - 2, spec.glyphs.vertical, spec.style);
        }
    }
    return innerRect(rect, spec.sides);
}

pub fn drawHorizontalLine(
    buffer: *CellBuffer,
    x: u16,
    y: u16,
    width: u16,
    glyph: []const u8,
    style: Style,
) CellBufferError!void {
    if (width == 0 or y >= buffer.height or x >= buffer.width) return;
    const end = @min(@as(u32, x) + width, buffer.width);
    var xx: u16 = x;
    while (xx < end) : (xx += 1) try buffer.writeText(xx, y, glyph, style);
}

pub fn drawVerticalLine(
    buffer: *CellBuffer,
    x: u16,
    y: u16,
    height: u16,
    glyph: []const u8,
    style: Style,
) CellBufferError!void {
    if (height == 0 or x >= buffer.width or y >= buffer.height) return;
    const end = @min(@as(u32, y) + height, buffer.height);
    var yy: u16 = y;
    while (yy < end) : (yy += 1) try buffer.writeText(x, yy, glyph, style);
}

pub fn boxTopLine(
    buffer: []u8,
    glyphs: BorderGlyphs,
    variant: BoxVariant,
    inner_width: usize,
    header: ?MeasuredText,
) ![]const u8 {
    return switch (variant) {
        .open => openTopLine(buffer, glyphs, header),
        .closed => closedTopLine(buffer, glyphs, inner_width, header),
    };
}

pub fn openTopLine(buffer: []u8, glyphs: BorderGlyphs, header: ?MeasuredText) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    try stream.writeAll(glyphs.top_left);
    try stream.writeAll(glyphs.horizontal);
    if (header) |text| {
        try stream.writeByte('[');
        try stream.writeAll(text.text);
        try stream.writeByte(']');
    }
    return stream.buffered();
}

pub fn closedTopLine(
    buffer: []u8,
    glyphs: BorderGlyphs,
    inner_width: usize,
    header: ?MeasuredText,
) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    try stream.writeAll(glyphs.top_left);
    if (header) |text| {
        try stream.writeAll(glyphs.horizontal);
        try stream.writeAll(text.text);
        const fill = if (inner_width > text.width + 1) inner_width - text.width - 1 else 0;
        for (0..fill) |_| try stream.writeAll(glyphs.horizontal);
    } else {
        for (0..inner_width) |_| try stream.writeAll(glyphs.horizontal);
    }
    try stream.writeAll(glyphs.top_right);
    return stream.buffered();
}

pub const OpenBlock = struct {
    glyphs: BorderGlyphs = .rounded,
    bottom_width: usize = 5,

    pub fn bodyPrefix(self: OpenBlock) []const u8 {
        _ = self;
        return "│ ";
    }

    pub fn bottomLine(self: OpenBlock, buffer: []u8) ![]const u8 {
        return openBottomLine(buffer, self.glyphs, self.bottom_width);
    }
};

pub fn boxBottomLine(
    buffer: []u8,
    glyphs: BorderGlyphs,
    variant: BoxVariant,
    inner_width: usize,
    footer: ?MeasuredText,
) ![]const u8 {
    return switch (variant) {
        .open => openBottomLine(buffer, glyphs, 5),
        .closed => closedBottomLine(buffer, glyphs, inner_width, footer),
    };
}

pub fn openBottomLine(buffer: []u8, glyphs: BorderGlyphs, width: usize) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    try stream.writeAll(glyphs.bottom_left);
    const count = if (width > 1) width - 1 else 0;
    for (0..count) |_| try stream.writeAll(glyphs.horizontal);
    return stream.buffered();
}

pub fn closedBottomLine(
    buffer: []u8,
    glyphs: BorderGlyphs,
    inner_width: usize,
    footer: ?MeasuredText,
) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    try stream.writeAll(glyphs.bottom_left);
    if (footer) |text| {
        const left = if (inner_width > text.width) (inner_width - text.width) / 2 else 0;
        const right = if (inner_width > text.width + left) inner_width - text.width - left else 0;
        for (0..left) |_| try stream.writeAll(glyphs.horizontal);
        try stream.writeAll(text.text);
        for (0..right) |_| try stream.writeAll(glyphs.horizontal);
    } else {
        for (0..inner_width) |_| try stream.writeAll(glyphs.horizontal);
    }
    try stream.writeAll(glyphs.bottom_right);
    return stream.buffered();
}

pub fn borderLineLr(
    buffer: []u8,
    glyphs: BorderGlyphs,
    top: bool,
    inner_width: usize,
    labels: BorderLabelPair,
) ![]const u8 {
    var stream = std.Io.Writer.fixed(buffer);
    const left_corner = if (top) glyphs.top_left else glyphs.bottom_left;
    const right_corner = if (top) glyphs.top_right else glyphs.bottom_right;
    const left_width = if (labels.left) |label| label.width else 0;
    const right_width = if (labels.right) |label| label.width else 0;
    const fill = if (inner_width >= 2 + left_width + right_width)
        inner_width - 2 - left_width - right_width
    else
        null;

    try stream.writeAll(left_corner);
    if (fill) |fill_count| {
        try stream.writeAll(glyphs.horizontal);
        if (labels.left) |label| try stream.writeAll(label.text);
        for (0..fill_count) |_| try stream.writeAll(glyphs.horizontal);
        if (labels.right) |label| try stream.writeAll(label.text);
        try stream.writeAll(glyphs.horizontal);
    } else {
        for (0..inner_width) |_| try stream.writeAll(glyphs.horizontal);
    }
    try stream.writeAll(right_corner);
    return stream.buffered();
}

pub fn elisionLine(buffer: []u8, omitted_lines: usize, omitted_bytes: usize) !?[]const u8 {
    if (omitted_lines > 0) {
        const text = try std.fmt.bufPrint(buffer, "· ··· {d} earlier lines", .{omitted_lines});
        return text;
    }
    if (omitted_bytes > 0) {
        const text = try std.fmt.bufPrint(buffer, "· ··· {d} earlier bytes", .{omitted_bytes});
        return text;
    }
    return null;
}

fn expectText(buffer: CellBuffer, x: u16, y: u16, bytes: []const u8) !void {
    const cell = try buffer.get(x, y);
    const rendered = cell.renderText() orelse return error.MissingCell;
    try std.testing.expectEqualStrings(bytes, rendered.slice());
}

test "chrome draws rounded border and returns inner rect" {
    var buffer = try CellBuffer.init(std.testing.allocator, 6, 4, 24);
    defer buffer.deinit();
    const inner = try drawBorder(&buffer, .{ .x = 1, .y = 0, .width = 4, .height = 3 }, .{});
    try std.testing.expectEqual(@as(Rect, .{ .x = 2, .y = 1, .width = 2, .height = 1 }), inner);
    try expectText(buffer, 1, 0, "╭");
    try expectText(buffer, 4, 0, "╮");
    try expectText(buffer, 1, 2, "╰");
    try expectText(buffer, 4, 2, "╯");
    try expectText(buffer, 2, 0, "─");
    try expectText(buffer, 1, 1, "│");
}

test "chrome supports square border glyphs" {
    var buffer = try CellBuffer.init(std.testing.allocator, 3, 3, 9);
    defer buffer.deinit();
    _ = try drawBorder(&buffer, .{ .x = 0, .y = 0, .width = 3, .height = 3 }, .{ .glyphs = .square });
    try expectText(buffer, 0, 0, "┌");
    try expectText(buffer, 2, 0, "┐");
    try expectText(buffer, 0, 2, "└");
    try expectText(buffer, 2, 2, "┘");
}

test "chrome inner rect respects disabled sides" {
    const inner = innerRect(
        .{ .x = 2, .y = 3, .width = 10, .height = 5 },
        .{ .top = true, .right = false, .bottom = false, .left = true },
    );
    try std.testing.expectEqual(@as(Rect, .{ .x = 3, .y = 4, .width = 9, .height = 4 }), inner);
}

test "chrome clips border writes to buffer bounds" {
    var buffer = try CellBuffer.init(std.testing.allocator, 3, 2, 6);
    defer buffer.deinit();
    _ = try drawBorder(&buffer, .{ .x = 2, .y = 1, .width = 4, .height = 3 }, .{});
    try expectText(buffer, 2, 1, "╭");
}

test "chrome builds open transcript lines" {
    var top_buffer: [32]u8 = undefined;
    var bottom_buffer: [32]u8 = undefined;
    var elision_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings(
        "╭─[tool]",
        try openTopLine(&top_buffer, .rounded, .{ .text = "tool", .width = 4 }),
    );
    const block: OpenBlock = .{};
    try std.testing.expectEqualStrings("│ ", block.bodyPrefix());
    try std.testing.expectEqualStrings("╰────", try block.bottomLine(&bottom_buffer));
    try std.testing.expectEqualStrings("╰────", try openBottomLine(&bottom_buffer, .rounded, 5));
    try std.testing.expectEqualStrings(
        "╭─tool─╮",
        try closedTopLine(&top_buffer, .rounded, 6, .{ .text = "tool", .width = 4 }),
    );
    try std.testing.expectEqualStrings(
        "╰──ok──╯",
        try closedBottomLine(&bottom_buffer, .rounded, 6, .{ .text = "ok", .width = 2 }),
    );
    try std.testing.expectEqualStrings("· ··· 8 earlier lines", (try elisionLine(&elision_buffer, 8, 0)).?);
}
