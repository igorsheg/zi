const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;
const Theme = theme_mod.Theme;

pub const Greeter = struct {
    theme: *const Theme = &Theme.dark,
    app_name: []const u8 = "zi",
    version: []const u8 = "",

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

        var row: u32 = top_pad;
        for (logo_lines) |line| {
            if (row >= h) break;
            _ = region.writeStr(left_pad, row, line, self.theme.fg(.accent), Color.default, .{});
            row += 1;
        }

        if (text_y >= h) return;
        var col: u32 = text_x;
        col += region.writeStr(col, text_y, self.app_name, self.theme.fg(.accent), Color.default, .{ .bold = true });
        if (self.version.len > 0) {
            col += region.writeStr(col, text_y, " v", self.theme.fg(.dim), Color.default, .{});
            _ = region.writeStr(col, text_y, self.version, self.theme.fg(.dim), Color.default, .{});
        }
        if (text_y + 1 >= h) return;
        _ = region.writeStr(text_x, text_y + 1, "Gets out of the way. Gets things done.", self.theme.fg(.muted), Color.default, .{});
        if (text_y + 2 >= h) return;
        _ = region.writeStr(text_x, text_y + 2, "Type / for commands. Ask zi about zi if you get lost.", self.theme.fg(.dim), Color.default, .{});
    }

    pub fn measure(_: *Greeter, _: u32) Measurement {
        return .{ .min_height = 5, .preferred_height = 5 };
    }

    pub fn component(self: *Greeter) Component {
        return Component.init(Greeter, self);
    }
};

test "greeter has stable fixed height" {
    var greeter = Greeter{};
    try std.testing.expectEqual(@as(u32, 5), greeter.measure(70).preferred_height);
    try std.testing.expectEqual(@as(u32, 5), greeter.measure(100).preferred_height);
}
