const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;

/// Footer displaying keybinding hints.
pub const Footer = struct {
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,

    pub fn render(self: *Footer, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const hints = "esc abort \xC2\xB7 ctrl+c quit \xC2\xB7 ctrl+o expand tools \xC2\xB7 ctrl+t thinking";
        _ = region.writeStr(0, 0, hints, self.theme.fg(.dim), Color.default, .{});
    }

    pub fn measure(self: *Footer, width: u32) Measurement {
        _ = self;
        _ = width;
        return .{ .min_height = 1, .preferred_height = 1 };
    }

    pub fn component(self: *Footer) Component {
        return Component.init(Footer, self);
    }
};

test "footer measure returns 1 for keybinding hints" {
    var f = Footer{};
    const m = f.measure(80);
    try std.testing.expectEqual(@as(u32, 1), m.min_height);
    try std.testing.expectEqual(@as(u32, 1), m.preferred_height);
}
