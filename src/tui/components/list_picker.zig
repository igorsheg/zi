const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const keys_mod = @import("../keys.zig");
const select_list_mod = @import("select_list.zig");
const theme_mod = @import("../theme.zig");
const box_chrome = @import("../box_chrome.zig");
const grapheme_mod = @import("../grapheme.zig");
const cell_mod = @import("../cell.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Key = keys_mod.Key;
const SelectList = select_list_mod.SelectList;
const SelectItem = select_list_mod.SelectItem;
const InputResult = select_list_mod.InputResult;
const Theme = theme_mod.Theme;
const Color = cell_mod.Color;

/// Modal list picker — wraps SelectList as a Component for use in the overlay stack.
/// Renders a bordered box with a title and the select list inside.
/// Reports selection/cancellation via callbacks.
pub const ListPicker = struct {
    list: SelectList,
    title: []const u8 = "",
    theme: *const Theme,
    on_select: ?*const fn (item: *const SelectItem, ctx: ?*anyopaque) void = null,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,

    pub fn init(theme: *const Theme) ListPicker {
        return .{
            .list = .{ .theme = theme },
            .theme = theme,
        };
    }

    // ── Component interface ──────────────────────────────────────

    pub fn render(self: *ListPicker, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 4 or h < 3) return;

        const border_color = self.theme.fg(.border);
        const style = box_chrome.Style{ .chrome = border_color, .fg = border_color, .dim = border_color };

        // Top border with title
        _ = box_chrome.drawClosedTop(region, 0, if (self.title.len > 0) self.title else null, null, style);
        // Bottom border
        _ = box_chrome.drawClosedBottom(region, h - 1, style);

        // Side borders + content area
        const content_h = h -| 2;
        if (content_h > 0) {
            var row: u32 = 0;
            while (row < content_h) : (row += 1) {
                _ = box_chrome.drawClosedContentPrefix(region, row + 1, style);
                // Right border
                if (w > 1) {
                    region.set(w - 1, row + 1, .{ .grapheme = .{ .codepoint = 0x2502 }, .fg = border_color }); // │
                }
            }
        }

        // Render list inside borders
        if (content_h > 0 and w > 3) {
            const inner = region.sub(1, 1, w - 2, content_h);
            self.list.render(inner);
        }
    }

    pub fn handleInput(self: *ListPicker, key: Key) bool {
        const result = self.list.processInput(key);
        switch (result) {
            .selected => {
                if (self.list.getSelectedItem()) |item| {
                    if (self.on_select) |cb| cb(item, self.callback_ctx);
                }
                return true;
            },
            .cancelled => {
                if (self.on_cancel) |cb| cb(self.callback_ctx);
                return true;
            },
            .consumed => return true,
            .unhandled => return false,
        }
    }

    pub fn measure(self: *ListPicker, width: u32) Measurement {
        const inner_m = self.list.measure(if (width > 2) width - 2 else 1);
        return .{
            .min_height = 3,
            .preferred_height = inner_m.preferred_height + 2, // +2 for borders
        };
    }

    pub fn component(self: *ListPicker) Component {
        return Component.init(ListPicker, self);
    }
};
