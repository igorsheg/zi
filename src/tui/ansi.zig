//! ANSI color palette translated to vaxis Color values. vaxis does not emit
//! raw ANSI SGR codes (30-37), so the closest representation is the 256-color
//! index form (0-15), which most terminals map back to the ANSI palette.
const vaxis = @import("vaxis");

pub const Color = vaxis.Color;

pub const black: Color = .{ .index = 0 };
pub const red: Color = .{ .index = 1 };
pub const green: Color = .{ .index = 2 };
pub const yellow: Color = .{ .index = 3 };
pub const blue: Color = .{ .index = 4 };
pub const magenta: Color = .{ .index = 5 };
pub const cyan: Color = .{ .index = 6 };
pub const white: Color = .{ .index = 7 };

// Bright variants are rendered by adding `.bold` to the base color. This is
// how most terminals expose the bright ANSI palette (90-97) when the SGR bold
// attribute is combined with a base color.
