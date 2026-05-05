const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;
const Theme = theme_mod.Theme;

pub const Greeter = struct {
    theme: ?*const Theme = null,
    app_name: []const u8 = "zi",
    version: []const u8 = "",

    fn activeTheme(self: *const Greeter) *const Theme {
        return self.theme orelse themes_builtin.dark();
    }

    const logo_lines = [_][]const u8{
        "░▀▀█░▀█▀",
        "░▄▀░░░█░",
        "░▀▀▀░▀▀▀",
    };

    pub fn render(self: *Greeter, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 20 or h == 0) return;

        const left_pad: u32 = 2;
        const top_pad: u32 = 1;
        const logo_w: u32 = 8;
        const gap: u32 = 3;
        const text_x = left_pad + logo_w + gap;
        const text_y = top_pad;

        const theme = self.activeTheme();
        var row: u32 = top_pad;
        for (logo_lines) |line| {
            if (row >= h) break;
            _ = region.writeStr(left_pad, row, line, theme.fg(.accent), Color.default, .{});
            row += 1;
        }

        if (text_y >= h) return;
        var col: u32 = text_x;
        col += region.writeStr(col, text_y, self.app_name, theme.fg(.accent), Color.default, .{ .bold = true });
        if (self.version.len > 0) {
            col += region.writeStr(col, text_y, " v", theme.fg(.dim), Color.default, .{});
            _ = region.writeStr(col, text_y, self.version, theme.fg(.dim), Color.default, .{});
        }
        if (text_y + 1 >= h) return;
        _ = region.writeStr(text_x, text_y + 1, "Type / for commands. Ask zi about zi if you get lost.", theme.fg(.dim), Color.default, .{});
    }

    pub fn measure(_: *Greeter, _: u32) Measurement {
        return .{ .min_height = 5, .preferred_height = 5 };
    }

    pub fn component(self: *Greeter) Component {
        return Component.init(Greeter, self);
    }
};
