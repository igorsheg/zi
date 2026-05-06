const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");
const box_chrome = @import("../box_chrome.zig");

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

    pub const Layout = struct {
        body: Region,
    };

    pub fn themed(theme: *const Theme, title: ?[]const u8) Panel {
        return .{
            .title = title,
            .border = theme.fg(.border_muted),
        };
    }

    pub fn render(self: Panel, region: Region) ?Layout {
        if (region.width < 2 or region.height < 2) return null;
        const style = box_chrome.Style{ .chrome = self.border, .fg = self.border, .dim = self.border };
        const frame = box_chrome.closedFrame(region);
        _ = frame.drawTop(self.title, null, style);
        _ = frame.drawBottom(style);

        var row: u32 = 0;
        while (row < frame.inner.height) : (row += 1) {
            _ = frame.drawBodyRow(row, style);
        }
        return .{ .body = frame.inner };
    }
};
