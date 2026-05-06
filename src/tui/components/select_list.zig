const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../primitives/surface.zig");
const keys_mod = @import("../terminal/keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const component_mod = @import("../primitives/view.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const keybindings = @import("../keybindings.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Key = keys_mod.Key;
const Measurement = component_mod.Measurement;
const Theme = theme_mod.Theme;

pub const SelectItem = struct {
    value: []const u8,
    label: []const u8,
    description: ?[]const u8 = null,
};

pub const InputResult = enum {
    consumed,
    selected,
    cancelled,
    unhandled,
};

pub const SelectList = struct {
    items: []const SelectItem = &.{},
    selected_index: u32 = 0,
    max_visible: u32 = 5,
    wrap_navigation: bool = true,
    empty_text: []const u8 = "No matching commands",
    theme: *const Theme,

    pub fn setItems(self: *SelectList, items: []const SelectItem) void {
        const previous_value = self.selectedValue();
        const previous_index = self.selected_index;
        self.items = items;
        if (previous_value) |value| {
            if (self.setSelectedByValue(value)) return;
        }
        self.setSelectedIndexClamped(previous_index);
    }

    pub fn setSelectedIndexClamped(self: *SelectList, index: usize) void {
        if (self.items.len == 0) {
            self.selected_index = 0;
            return;
        }
        self.selected_index = @intCast(@min(index, self.items.len - 1));
    }

    pub fn setSelectedByValue(self: *SelectList, value: []const u8) bool {
        for (self.items, 0..) |item, idx| {
            if (std.mem.eql(u8, item.value, value)) {
                self.selected_index = @intCast(idx);
                return true;
            }
        }
        return false;
    }

    pub fn selectedValue(self: *const SelectList) ?[]const u8 {
        const item = self.getSelectedItem() orelse return null;
        return item.value;
    }

    pub fn processInput(self: *SelectList, key: Key) InputResult {
        if (keybindings.matches(.select_confirm, key)) {
            return if (self.items.len > 0) .selected else .consumed;
        }
        if (keybindings.matches(.select_cancel, key)) return .cancelled;

        if (keybindings.matches(.select_up, key)) {
            if (self.items.len == 0) return .consumed;
            self.moveBy(-1, self.wrap_navigation);
            return .consumed;
        }

        if (keybindings.matches(.select_down, key)) {
            if (self.items.len == 0) return .consumed;
            self.moveBy(1, self.wrap_navigation);
            return .consumed;
        }

        if (keybindings.matches(.select_page_up, key)) {
            if (self.items.len == 0) return .consumed;
            self.moveBy(-@as(i64, @intCast(@max(self.max_visible, @as(u32, 1)))), false);
            return .consumed;
        }

        if (keybindings.matches(.select_page_down, key)) {
            if (self.items.len == 0) return .consumed;
            self.moveBy(@as(i64, @intCast(@max(self.max_visible, @as(u32, 1)))), false);
            return .consumed;
        }

        if (keybindings.matches(.select_home, key)) {
            if (self.items.len == 0) return .consumed;
            self.selected_index = 0;
            return .consumed;
        }

        if (keybindings.matches(.select_end, key)) {
            if (self.items.len == 0) return .consumed;
            self.selected_index = @intCast(self.items.len - 1);
            return .consumed;
        }

        return .unhandled;
    }

    pub fn render(self: *const SelectList, region: Region) void {
        const muted = self.theme.fg(.muted);
        const accent = self.theme.fg(.accent);
        const text_color = self.theme.fg(.text);

        if (self.items.len == 0) {
            _ = region.writeStr(0, 0, "  ", muted, Color.default, .{});
            _ = region.writeStr(2, 0, self.empty_text, muted, Color.default, .{});
            return;
        }

        const len: u32 = @intCast(self.items.len);
        const visible = @min(self.max_visible, len);

        const half = visible / 2;
        const max_start = len -| visible;
        const start = @min(if (self.selected_index > half) self.selected_index - half else 0, max_start);
        const end = @min(start + visible, len);

        var label_w: usize = 0;
        for (start..end) |i| {
            const w = grapheme_mod.strWidth(self.items[i].label);
            if (w > label_w) label_w = w;
        }
        const desc_threshold: u32 = 40;

        var row: u32 = 0;
        for (start..end) |i| {
            const item = &self.items[i];
            const is_selected = (i == self.selected_index);

            const fg = if (is_selected) accent else text_color;
            const prefix: []const u8 = if (is_selected) "\xe2\x86\x92 " else "  ";
            var col = region.writeStr(0, row, prefix, fg, Color.default, .{});
            col += region.writeStr(col, row, item.label, fg, Color.default, .{});

            if (item.description) |desc| {
                if (region.width > desc_threshold) {
                    const current_label_w = grapheme_mod.strWidth(item.label);
                    const pad: u32 = @intCast(label_w - current_label_w + 2);
                    col += pad;
                    _ = region.writeStr(col, row, desc, muted, Color.default, .{ .dim = true });
                }
            }
            row += 1;
        }

        if (len > self.max_visible) {
            var indicator_buf: [32]u8 = undefined;
            const indicator = std.fmt.bufPrint(&indicator_buf, "  ({d}/{d})", .{ self.selected_index + 1, len }) catch return;
            _ = region.writeStr(0, row, indicator, muted, Color.default, .{});
        }
    }

    pub fn measure(self: *const SelectList, _: u32) Measurement {
        if (self.items.len == 0) return .{ .min_height = 1, .preferred_height = 1 };
        const len: u32 = @intCast(self.items.len);
        const visible = @min(len, self.max_visible);
        const scroll_indicator: u32 = if (len > self.max_visible) 1 else 0;
        return .{
            .min_height = 1,
            .preferred_height = visible + scroll_indicator,
        };
    }

    pub fn getSelectedItem(self: *const SelectList) ?*const SelectItem {
        if (self.items.len == 0) return null;
        return &self.items[self.selected_index];
    }

    fn moveBy(self: *SelectList, delta: i64, wrap: bool) void {
        if (self.items.len == 0) return;

        const len: i64 = @intCast(self.items.len);
        const current: i64 = @intCast(self.selected_index);
        var next = current + delta;

        if (wrap) {
            next = @mod(next, len);
        } else {
            next = std.math.clamp(next, 0, len - 1);
        }

        self.selected_index = @intCast(next);
    }
};

const testing = std.testing;
fn testTheme() Theme {
    return themes_builtin.dark().*;
}

fn makeItems() [3]SelectItem {
    return .{
        .{ .value = "a", .label = "Alpha", .description = "first letter" },
        .{ .value = "b", .label = "Beta", .description = "second letter" },
        .{ .value = "c", .label = "Gamma", .description = null },
    };
}

fn listWithItems(theme: *const Theme, items: []const SelectItem) SelectList {
    var list = SelectList{ .theme = theme };
    list.setItems(items);
    return list;
}

test "SelectList up/down wraps around" {
    const theme = testTheme();
    var items = makeItems();
    var sl = listWithItems(&theme, &items);

    const r1 = sl.processInput(.{ .code = .up });
    try testing.expectEqual(InputResult.consumed, r1);
    try testing.expectEqual(@as(u32, 2), sl.selected_index);

    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 0), sl.selected_index);

    _ = sl.processInput(.{ .code = .down });
    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 2), sl.selected_index);
    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 0), sl.selected_index);
}

test "SelectList page home and end navigation clamp within items" {
    const theme = testTheme();
    const many = [_]SelectItem{
        .{ .value = "a", .label = "Item" },
        .{ .value = "b", .label = "Item" },
        .{ .value = "c", .label = "Item" },
        .{ .value = "d", .label = "Item" },
        .{ .value = "e", .label = "Item" },
        .{ .value = "f", .label = "Item" },
        .{ .value = "g", .label = "Item" },
        .{ .value = "h", .label = "Item" },
    };

    var sl = listWithItems(&theme, &many);
    sl.max_visible = 3;

    _ = sl.processInput(.{ .code = .page_down });
    try testing.expectEqual(@as(u32, 3), sl.selected_index);
    _ = sl.processInput(.{ .code = .page_down });
    try testing.expectEqual(@as(u32, 6), sl.selected_index);
    _ = sl.processInput(.{ .code = .page_down });
    try testing.expectEqual(@as(u32, 7), sl.selected_index);

    _ = sl.processInput(.{ .code = .home });
    try testing.expectEqual(@as(u32, 0), sl.selected_index);
    _ = sl.processInput(.{ .code = .end });
    try testing.expectEqual(@as(u32, 7), sl.selected_index);
    _ = sl.processInput(.{ .code = .page_up });
    try testing.expectEqual(@as(u32, 4), sl.selected_index);
}

test "SelectList preserves selection by value across setItems" {
    const theme = testTheme();
    const before = [_]SelectItem{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };
    const after = [_]SelectItem{
        .{ .value = "gamma", .label = "Gamma" },
        .{ .value = "beta", .label = "Beta" },
    };

    var sl = listWithItems(&theme, &before);
    try testing.expect(sl.setSelectedByValue("beta"));
    sl.setItems(&after);

    try testing.expectEqualStrings("beta", sl.selectedValue().?);
    try testing.expectEqual(@as(u32, 1), sl.selected_index);
}

test "SelectList empty items have no selection and consume list actions" {
    const theme = testTheme();

    var sl = SelectList{ .theme = &theme };

    try testing.expectEqual(@as(?*const SelectItem, null), sl.getSelectedItem());
    try testing.expectEqual(@as(?[]const u8, null), sl.selectedValue());
    try testing.expectEqual(InputResult.consumed, sl.processInput(.{ .code = .enter }));
    try testing.expectEqual(InputResult.consumed, sl.processInput(.{ .code = .down }));
    try testing.expectEqual(@as(u32, 0), sl.selected_index);
}
