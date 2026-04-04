const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");
const grapheme_mod = @import("../grapheme.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Measurement = component_mod.Measurement;
const Component = component_mod.Component;

/// Minimal footer displaying cwd and model name.
/// Full token/cost/context stats deferred until session persistence ships (zi-6j3).
pub const Footer = struct {
    theme: *const theme_mod.Theme = &theme_mod.Theme.dark,
    cwd: []const u8 = "",
    model_name: []const u8 = "",

    pub fn render(self: *Footer, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        var cwd_display: [1024]u8 = undefined;
        const cwd_text = self.abbreviateCwd(&cwd_display);
        _ = region.writeStr(0, 0, cwd_text, self.theme.fg(.dim), Color.default, .{});

        if (h >= 2 and self.model_name.len > 0) {
            const model_w: u32 = @intCast(grapheme_mod.strWidth(self.model_name));
            const x = if (w > model_w) w - model_w else 0;
            _ = region.writeStr(x, 1, self.model_name, self.theme.fg(.dim), Color.default, .{});
        }
    }

    pub fn measure(self: *Footer, width: u32) Measurement {
        _ = width;
        if (self.cwd.len == 0 and self.model_name.len == 0) {
            return .{ .min_height = 0, .preferred_height = 0 };
        }
        return .{ .min_height = 1, .preferred_height = 2 };
    }

    pub fn component(self: *Footer) Component {
        return Component.init(Footer, self);
    }

    fn abbreviateCwd(self: *const Footer, buf: *[1024]u8) []const u8 {
        const home = std.posix.getenv("HOME") orelse return self.cwd;
        if (self.cwd.len == 0) return self.cwd;
        if (std.mem.startsWith(u8, self.cwd, home)) {
            const rest = self.cwd[home.len..];
            if (rest.len + 1 <= buf.len) {
                buf[0] = '~';
                @memcpy(buf[1..][0..rest.len], rest);
                return buf[0 .. rest.len + 1];
            }
        }
        return self.cwd;
    }
};

test "footer measure returns 0 when empty" {
    var f = Footer{};
    const m = f.measure(80);
    try std.testing.expectEqual(@as(u32, 0), m.min_height);
    try std.testing.expectEqual(@as(u32, 0), m.preferred_height);
}

test "footer measure returns 2 lines when populated" {
    var f = Footer{ .cwd = "/tmp", .model_name = "claude-4" };
    const m = f.measure(80);
    try std.testing.expectEqual(@as(u32, 1), m.min_height);
    try std.testing.expectEqual(@as(u32, 2), m.preferred_height);
}
