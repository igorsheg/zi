const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;

pub const Header = struct {
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    app_name: []const u8 = "zi",
    version: []const u8 = "",

    const hints = [_]struct { key: []const u8, desc: []const u8 }{
        .{ .key = "esc", .desc = "interrupt" },
        .{ .key = "ctrl+c", .desc = "exit" },
        .{ .key = "ctrl+d", .desc = "exit (empty)" },
        .{ .key = "shift+enter", .desc = "newline" },
        .{ .key = "pg up/dn", .desc = "scroll" },
    };

    pub fn render(self: *Header, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 4 or h == 0) return;

        var row: u32 = 0;
        const pad: u32 = 1;

        // Blank spacer row
        row += 1;
        if (row >= h) return;

        // Logo line: "zi v0.1.0"
        var col: u32 = pad;
        col += region.writeStr(col, row, self.app_name, self.theme.fg(.accent), Color.default, .{ .bold = true });
        if (self.version.len > 0) {
            col += region.writeStr(col, row, " v", self.theme.fg(.dim), Color.default, .{});
            _ = region.writeStr(col, row, self.version, self.theme.fg(.dim), Color.default, .{});
        }
        row += 1;
        if (row >= h) return;

        // Keybinding hints
        for (hints) |hint| {
            if (row >= h) break;
            col = pad;
            col += region.writeStr(col, row, hint.key, self.theme.fg(.dim), Color.default, .{});
            col += region.writeStr(col, row, " ", Color.default, Color.default, .{});
            _ = region.writeStr(col, row, hint.desc, self.theme.fg(.muted), Color.default, .{});
            row += 1;
        }
    }

    pub fn measure(self: *Header, width: u32) Measurement {
        _ = width;
        _ = self;
        // 1 spacer + 1 logo + N hints + 1 spacer
        const total: u32 = 1 + 1 + hints.len + 1;
        return .{ .min_height = 0, .preferred_height = total };
    }

    pub fn component(self: *Header) Component {
        return Component.init(Header, self);
    }
};
