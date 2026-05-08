const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");
const chrome = @import("../primitives/chrome.zig");

const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Theme = theme_mod.Theme;

/// Reusable bordered panel chrome.
///
/// Panel owns only the frame drawing contract. Callers compose the body by
/// rendering into the returned `body` region. This keeps modal/list/content
/// components from each carrying their own border math.
pub const Panel = struct {
    title: ?[]const u8 = null,
    border: Color,
    theme: *const Theme,

    pub const Layout = struct {
        body: Region,
    };

    pub fn themed(theme: *const Theme, title: ?[]const u8) Panel {
        return .{
            .title = title,
            .border = theme.fg(.border_muted),
            .theme = theme,
        };
    }

    pub fn render(self: Panel, region: Region) ?Layout {
        const frame = chrome.Frame{ .title = self.title, .border = .rounded, .tone = .muted, .color = self.border };
        const layout = frame.render(region, self.theme) orelse return null;
        return .{ .body = layout.body };
    }
};
