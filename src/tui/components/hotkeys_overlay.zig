const std = @import("std");
const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const cell_mod = @import("../cell.zig");
const box_chrome = @import("../box_chrome.zig");
const grapheme_mod = @import("../grapheme.zig");
const keybindings = @import("../keybindings.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Region = buffer_mod.Region;
const Theme = theme_mod.Theme;
const Color = cell_mod.Color;
const Key = @import("../terminal/keys.zig").Key;

pub const HotkeysOverlay = struct {
    theme: ?*const Theme = null,
    focused: bool = false,

    fn activeTheme(self: *const HotkeysOverlay) *const Theme {
        return self.theme orelse themes_builtin.dark();
    }

    pub fn render(self: *HotkeysOverlay, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 8 or h < 4) return;

        const theme = self.activeTheme();
        const border_color = theme.fg(.border);
        const style = box_chrome.Style{ .chrome = border_color, .fg = border_color, .dim = border_color };
        const frame = box_chrome.closedFrame(region);
        _ = frame.drawTop("Hotkeys", null, style);
        _ = frame.drawBottom(style);

        const inner = frame.inner;
        var row: u32 = 0;
        while (row < inner.height) : (row += 1) {
            _ = frame.drawBodyRow(row, style);
        }

        if (inner.width == 0 or inner.height == 0) return;
        const key_width = maxKeyWidth();
        var content_row: u32 = 0;
        var last_section: ?keybindings.Section = null;

        for (keybindings.all()) |def| {
            if (!def.show_in_help) continue;
            if (last_section == null or last_section.? != def.section) {
                if (content_row >= inner.height) break;
                if (last_section != null) {
                    if (content_row >= inner.height) break;
                    content_row += 1;
                    if (content_row >= inner.height) break;
                }
                _ = inner.writeStr(0, content_row, keybindings.sectionTitle(def.section), theme.fg(.accent), Color.default, .{});
                content_row += 1;
                last_section = def.section;
                if (content_row >= inner.height) break;
            }

            var binding_buf: [64]u8 = undefined;
            const binding_text = keybindings.formatBindings(def.action, " / ", &binding_buf);
            const binding_width = grapheme_mod.strWidth(binding_text);
            _ = inner.writeStr(0, content_row, binding_text, theme.fg(.text), Color.default, .{});

            const desc_col: u32 = @intCast(@min(inner.width, key_width + 2));
            if (desc_col < inner.width) {
                var col = desc_col;
                if (binding_width < key_width) {
                    col = @intCast(@min(inner.width, binding_width + (key_width - binding_width) + 2));
                }
                _ = inner.writeStr(col, content_row, def.description, theme.fg(.muted), Color.default, .{ .dim = true });
            }
            content_row += 1;
            if (content_row >= inner.height) break;
        }
    }

    pub fn handleInput(self: *HotkeysOverlay, _: Key) bool {
        _ = self;
        return false;
    }

    pub fn measure(self: *const HotkeysOverlay, width: u32) Measurement {
        _ = self;
        const content_width = if (width > 2) width - 2 else 1;
        _ = content_width;

        var rows: u32 = 0;
        var last_section: ?keybindings.Section = null;
        for (keybindings.all()) |def| {
            if (!def.show_in_help) continue;
            if (last_section == null or last_section.? != def.section) {
                if (last_section != null) rows += 1;
                rows += 1;
                last_section = def.section;
            }
            rows += 1;
        }

        return .{
            .min_height = 4,
            .preferred_height = rows + 2,
        };
    }

    pub fn cursorState(self: *HotkeysOverlay) ?CursorState {
        _ = self;
        return null;
    }

    pub fn setFocused(self: *HotkeysOverlay, focused: bool) void {
        self.focused = focused;
    }

    pub fn component(self: *HotkeysOverlay) Component {
        return Component.init(HotkeysOverlay, self);
    }

    fn maxKeyWidth() u32 {
        var max_width: usize = 0;
        for (keybindings.all()) |def| {
            if (!def.show_in_help) continue;
            var binding_buf: [64]u8 = undefined;
            const width = grapheme_mod.strWidth(keybindings.formatBindings(def.action, " / ", &binding_buf));
            if (width > max_width) max_width = width;
        }
        return @intCast(max_width);
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn bufferContainsText(buf: *const Buffer, needle: []const u8) bool {
    if (needle.len == 0) return true;

    var row_buf: [256]u8 = undefined;
    for (0..buf.height) |y| {
        @memset(&row_buf, ' ');
        for (0..@min(buf.width, row_buf.len)) |x| {
            const cell = buf.get(@intCast(x), @intCast(y));
            const cp = switch (cell.grapheme) {
                .codepoint => |c| c,
                .pooled => ' ',
            };
            row_buf[x] = if (cp < 128) @intCast(cp) else ' ';
        }
        if (std.mem.indexOf(u8, row_buf[0..@min(buf.width, row_buf.len)], needle) != null) return true;
    }
    return false;
}

test "HotkeysOverlay renders shared keybinding sections" {
    var overlay = HotkeysOverlay{};
    var buf = try Buffer.init(testing.allocator, 80, 20);
    defer buf.deinit();

    overlay.render(buf.region());

    try testing.expect(bufferContainsText(&buf, "Hotkeys"));
    try testing.expect(bufferContainsText(&buf, "Editor"));
    try testing.expect(bufferContainsText(&buf, "Picker"));
    try testing.expect(bufferContainsText(&buf, "App"));
}
