const std = @import("std");

pub const Color = union(enum) {
    default,
    indexed: u8,
    rgb: struct { r: u8, g: u8, b: u8 },
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
};

pub const Style = struct {
    foreground: Color = .default,
    background: Color = .default,
    attributes: Attributes = .{},

    pub fn eql(a: Style, b: Style) bool {
        return std.meta.eql(a, b);
    }
};
