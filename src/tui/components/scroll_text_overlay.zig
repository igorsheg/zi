const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const component_mod = @import("../primitives/view.zig");
const keys_mod = @import("../terminal/keys.zig");
const text_mod = @import("text.zig");
const panel_mod = @import("panel.zig");
const theme_mod = @import("../theme.zig");
const grapheme_mod = @import("../grapheme.zig");
const chrome = @import("../primitives/chrome.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Key = keys_mod.Key;

/// Focusable, scrollable text panel intended for modal overlays.
/// Owns its content and renders a compact title/header plus help footer.
pub const ScrollTextOverlay = struct {
    allocator: std.mem.Allocator,
    theme: *const theme_mod.Theme,
    title: []u8 = &.{},
    subtitle: []u8 = &.{},
    text: text_mod.Text,
    focused: bool = false,
    last_body_width: u32 = 80,
    last_body_height: u32 = 1,

    pub fn init(allocator: std.mem.Allocator, theme: *const theme_mod.Theme, width_method: grapheme_mod.WidthMethod) ScrollTextOverlay {
        var text = text_mod.Text.init(allocator, width_method);
        text.setPadding(1, 0);
        return .{
            .allocator = allocator,
            .theme = theme,
            .text = text,
        };
    }

    pub fn deinit(self: *ScrollTextOverlay) void {
        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.subtitle.len > 0) self.allocator.free(self.subtitle);
        self.text.deinit();
    }

    pub fn setTheme(self: *ScrollTextOverlay, theme: *const theme_mod.Theme) void {
        self.theme = theme;
    }

    pub fn setContent(self: *ScrollTextOverlay, title: []const u8, subtitle: []const u8, content: []const u8) !void {
        const title_copy = try self.allocator.dupe(u8, title);
        errdefer self.allocator.free(title_copy);
        const subtitle_copy = try self.allocator.dupe(u8, subtitle);
        errdefer self.allocator.free(subtitle_copy);

        if (self.title.len > 0) self.allocator.free(self.title);
        if (self.subtitle.len > 0) self.allocator.free(self.subtitle);
        self.title = title_copy;
        self.subtitle = subtitle_copy;
        self.text.setContent(content);
        self.text.scroll_offset = 0;
    }

    pub fn component(self: *ScrollTextOverlay) Component {
        return Component.init(ScrollTextOverlay, self);
    }

    pub fn measure(self: *ScrollTextOverlay, width: u32) Measurement {
        const inner_width = if (width > 2) width - 2 else 1;
        const body = self.text.measure(inner_width);
        return .{ .min_height = 5, .preferred_height = body.preferred_height + 4 };
    }

    pub fn setFocused(self: *ScrollTextOverlay, focused: bool) void {
        self.focused = focused;
    }

    pub fn handleInput(self: *ScrollTextOverlay, key: Key) bool {
        switch (key.code) {
            .up => self.scrollUp(1),
            .down => self.scrollDown(1, self.last_body_height),
            .page_up => self.scrollUp(self.pageStep()),
            .page_down => self.scrollDown(self.pageStep(), self.last_body_height),
            .home => self.text.scroll_offset = 0,
            .end => self.scrollToBottom(self.last_body_height),
            .char => if (key.char) |ch| switch (ch) {
                'k' => self.scrollUp(1),
                'j' => self.scrollDown(1, self.last_body_height),
                'u' => self.scrollUp(self.pageStep()),
                'd' => self.scrollDown(self.pageStep(), self.last_body_height),
                'g' => self.text.scroll_offset = 0,
                'G' => self.scrollToBottom(self.last_body_height),
                else => return false,
            } else return false,
            else => return false,
        }
        return true;
    }

    pub fn render(self: *ScrollTextOverlay, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const fg = self.theme.fg(.text);
        const muted = self.theme.fg(.muted);

        const panel = panel_mod.Panel.themed(self.theme, if (self.title.len > 0) self.title else null);
        const panel_layout = panel.render(region) orelse return;
        const inner = panel_layout.body;
        if (inner.width == 0 or inner.height == 0) return;

        var row: u32 = 0;
        if (self.subtitle.len > 0 and inner.height > 0) {
            _ = inner.writeStr(0, row, self.subtitle, muted, Color.default, .{});
            row += 1;
        }

        if (inner.height > row) {
            (chrome.Separator{}).render(inner.sub(0, row, inner.width, 1), self.theme);
            row += 1;
        }

        if (inner.height <= row) return;
        const footer_y = inner.height - 1;
        const body_h = footer_y -| row;
        self.last_body_width = inner.width;
        self.last_body_height = @max(@as(u32, 1), body_h);
        if (body_h > 0) {
            const body_region = inner.sub(0, row, inner.width, body_h);
            self.text.fg = fg;
            self.text.bg = Color.default;
            self.text.render(body_region);
        }

        const total = self.text.totalLines(inner.width);
        const max_offset = if (total > body_h) total - body_h else 0;
        if (self.text.scroll_offset > max_offset) self.text.scroll_offset = max_offset;

        var footer_buf: [160]u8 = undefined;
        const footer = std.fmt.bufPrint(&footer_buf, "↑/↓ j/k scroll  PgUp/PgDn page  g/G top/bottom  Esc close  {d}/{d}", .{ self.text.scroll_offset, max_offset }) catch "↑/↓ scroll  Esc close";
        _ = inner.writeStr(0, footer_y, footer, muted, Color.default, .{});
    }

    fn scrollUp(self: *ScrollTextOverlay, n: u32) void {
        self.text.scroll_offset -|= n;
    }

    fn scrollDown(self: *ScrollTextOverlay, n: u32, visible_height: u32) void {
        const total = self.text.totalLines(self.last_body_width);
        const max_offset = if (total > visible_height) total - visible_height else 0;
        self.text.scroll_offset = @min(self.text.scroll_offset +| n, max_offset);
    }

    fn scrollToBottom(self: *ScrollTextOverlay, visible_height: u32) void {
        self.text.scrollToBottom(visible_height);
    }

    fn pageStep(self: *const ScrollTextOverlay) u32 {
        return @max(@as(u32, 1), self.last_body_height -| 1);
    }
};
