const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const keybindings = @import("../keybindings.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;

/// Footer displaying keybinding hints.
pub const Footer = struct {
    theme: ?*const theme_mod.Theme = null,

    fn activeTheme(self: *const Footer) *const theme_mod.Theme {
        return self.theme orelse themes_builtin.dark();
    }

    pub fn render(self: *Footer, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var buf: [128]u8 = undefined;
        const hints = keybindings.formatFooter(&buf);
        _ = region.writeStr(0, 0, hints, self.activeTheme().fg(.dim), Color.default, .{});
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
