const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const theme_mod = @import("../theme.zig");
const text_mod = @import("text.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const measurement = component_mod.measurement;
const Component = component_mod.Component;
const Theme = theme_mod.Theme;

pub const Greeter = struct {
    allocator: std.mem.Allocator = std.heap.page_allocator,
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
        if (text_x >= w) return;
        const text_width = w - text_x;
        var title = text_mod.Text.init(self.allocator, region.buf.width_method);
        defer title.deinit();
        title.wrap_mode = .none;
        title.overflow = .ellipsis;
        title.max_lines = 1;
        if (self.version.len > 0) {
            const runs = [_]text_mod.TextRun{
                .{ .text = self.app_name, .fg = theme.fg(.accent), .attrs = .{ .bold = true } },
                .{ .text = " v", .fg = theme.fg(.dim) },
                .{ .text = self.version, .fg = theme.fg(.dim) },
            };
            title.setRuns(&runs);
        } else {
            title.content = self.app_name;
            title.fg = theme.fg(.accent);
            title.attrs = .{ .bold = true };
        }
        title.render(region.sub(text_x, text_y, text_width, 1));
        if (text_y + 1 >= h) return;
        var help = text_mod.Text.init(self.allocator, region.buf.width_method);
        defer help.deinit();
        help.content = "Type / for commands. Ask zi about zi if you get lost.";
        help.fg = theme.fg(.dim);
        help.wrap_mode = .word;
        help.max_lines = @min(@as(u32, 2), h - text_y - 1);
        help.render(region.sub(text_x, text_y + 1, text_width, help.max_lines.?));
    }

    pub fn measure(_: *Greeter, _: u32) Measurement {
        return measurement(5, 5);
    }

    pub fn component(self: *Greeter) Component {
        return Component.init(Greeter, self);
    }
};
