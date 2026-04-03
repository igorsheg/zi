const std = @import("std");

/// 24-bit RGB color for terminal rendering.
pub const Color = struct {
    r: u8,
    g: u8,
    b: u8,
    is_default: bool = false,

    /// Terminal default color — renderer emits \x1b[39m / \x1b[49m.
    pub const default: Color = .{ .r = 0, .g = 0, .b = 0, .is_default = true };

    pub fn eql(a: Color, b: Color) bool {
        if (a.is_default and b.is_default) return true;
        if (a.is_default != b.is_default) return false;
        return a.r == b.r and a.g == b.g and a.b == b.b;
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .is_default = false };
    }
};

/// Text attributes as a packed struct for compact storage.
pub const Attributes = packed struct(u8) {
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
    blink: bool = false,
    inverse: bool = false,
    hidden: bool = false,
    strikethrough: bool = false,

    pub const none: Attributes = .{};

    pub fn eql(a: Attributes, b: Attributes) bool {
        return @as(u8, @bitCast(a)) == @as(u8, @bitCast(b));
    }
};

/// Grapheme content of a cell.
/// Single codepoints (>99% of cells) are stored inline.
/// Multi-codepoint clusters (emoji ZWJ sequences, combining marks) are stored
/// as an index into a GraphemePool managed by the Buffer.
pub const Grapheme = union(enum) {
    codepoint: u21,
    pooled: u32,

    pub fn eql(a: Grapheme, b: Grapheme) bool {
        return switch (a) {
            .codepoint => |ac| switch (b) {
                .codepoint => |bc| ac == bc,
                .pooled => false,
            },
            .pooled => |ai| switch (b) {
                .pooled => |bi| ai == bi,
                .codepoint => false,
            },
        };
    }
};

/// The atomic rendering unit. Every screen position is a Cell.
pub const Cell = struct {
    grapheme: Grapheme = .{ .codepoint = ' ' },
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    /// Display width: 1 = normal, 2 = wide char (CJK), 0 = continuation cell
    /// (right half of a wide char — renderer skips these).
    width: u2 = 1,
    /// Non-zero = hyperlink. Index into per-frame link table on the Buffer.
    link_id: u16 = 0,

    pub const blank: Cell = .{};

    pub fn eql(a: Cell, b: Cell) bool {
        return a.grapheme.eql(b.grapheme) and
            a.fg.eql(b.fg) and
            a.bg.eql(b.bg) and
            a.attrs.eql(b.attrs) and
            a.width == b.width and
            a.link_id == b.link_id;
    }
};

/// Cursor style for components that want a visible cursor.
pub const CursorStyle = enum {
    block,
    underline,
    bar,
};

test "Cell equality" {
    const a = Cell.blank;
    const b = Cell.blank;
    try std.testing.expect(a.eql(b));

    var c = Cell.blank;
    c.fg = Color.rgb(255, 0, 0);
    try std.testing.expect(!a.eql(c));
}

test "Attributes packed size" {
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Attributes));
}

test "Grapheme equality" {
    const a = Grapheme{ .codepoint = 'A' };
    const b = Grapheme{ .codepoint = 'A' };
    const c = Grapheme{ .codepoint = 'B' };
    const d = Grapheme{ .pooled = 42 };
    try std.testing.expect(a.eql(b));
    try std.testing.expect(!a.eql(c));
    try std.testing.expect(!a.eql(d));
    try std.testing.expect(!d.eql(a));
}
