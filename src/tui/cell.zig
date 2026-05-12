const std = @import("std");

pub const Color = union(enum) {
    default_color,
    rgb24: struct {
        r: u8,
        g: u8,
        b: u8,
    },
    index: u8,

    pub const default: Color = .default_color;

    pub fn eql(a: Color, b: Color) bool {
        return switch (a) {
            .default_color => b == .default_color,
            .rgb24 => |a_rgb| switch (b) {
                .rgb24 => |b_rgb| a_rgb.r == b_rgb.r and a_rgb.g == b_rgb.g and a_rgb.b == b_rgb.b,
                else => false,
            },
            .index => |a_index| switch (b) {
                .index => |b_index| a_index == b_index,
                else => false,
            },
        };
    }

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .rgb24 = .{ .r = r, .g = g, .b = b } };
    }

    pub fn indexed(value: u8) Color {
        return .{ .index = value };
    }
};

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

pub const Cell = struct {
    grapheme: Grapheme = .{ .codepoint = ' ' },
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},

    width: u2 = 1,

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

pub const CursorStyle = enum {
    block,
    underline,
    bar,
};

test "Cell equality distinguishes all fields" {
    const a = Cell.blank;
    try std.testing.expect(a.eql(Cell.blank));

    try std.testing.expect(!a.eql(Cell{ .fg = Color.rgb(255, 0, 0) }));
    try std.testing.expect(!a.eql(Cell{ .fg = Color.indexed(42) }));
    try std.testing.expect(!a.eql(Cell{ .grapheme = .{ .codepoint = 'X' } }));
    const pooled = Grapheme{ .pooled = 42 };
    try std.testing.expect(!pooled.eql(Grapheme{ .codepoint = 'A' }));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Attributes));
}
