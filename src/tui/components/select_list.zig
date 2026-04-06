const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const keys_mod = @import("../keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const component_mod = @import("../component.zig");
const theme_mod = @import("../theme.zig");

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
    theme: *const Theme,

    pub fn setItems(self: *SelectList, items: []const SelectItem) void {
        self.items = items;
        self.selected_index = 0;
    }

    pub fn processInput(self: *SelectList, key: Key) InputResult {
        if (key.code == .enter and !key.ctrl and !key.alt) {
            return if (self.items.len > 0) .selected else .consumed;
        }
        if (key.code == .escape and !key.ctrl and !key.alt) return .cancelled;

        if (key.code == .up and !key.ctrl and !key.alt) {
            if (self.items.len == 0) return .consumed;
            if (self.selected_index == 0) {
                self.selected_index = @intCast(self.items.len - 1);
            } else {
                self.selected_index -= 1;
            }
            return .consumed;
        }

        if (key.code == .down and !key.ctrl and !key.alt) {
            if (self.items.len == 0) return .consumed;
            if (self.selected_index >= self.items.len - 1) {
                self.selected_index = 0;
            } else {
                self.selected_index += 1;
            }
            return .consumed;
        }

        return .unhandled;
    }

    pub fn render(self: *const SelectList, region: Region) void {
        const muted = self.theme.fg(.muted);
        const accent = self.theme.fg(.accent);
        const text_color = self.theme.fg(.text);

        if (self.items.len == 0) {
            _ = region.writeStr(0, 0, "  No matching commands", muted, Color.default, .{});
            return;
        }

        const len: u32 = @intCast(self.items.len);
        const visible = @min(self.max_visible, len);

        // scroll window: center selection in visible area
        const half = visible / 2;
        const max_start = len -| visible;
        const start = @min(if (self.selected_index > half) self.selected_index - half else 0, max_start);
        const end = @min(start + visible, len);

        // label column width for two-column layout
        var label_w: usize = 0;
        for (start..end) |i| {
            const w = grapheme_mod.strWidth(self.items[i].label);
            if (w > label_w) label_w = w;
        }
        // +4 for prefix "→ " or "  " (2) + gap (2)
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
                    // pad to align descriptions
                    const current_label_w = grapheme_mod.strWidth(item.label);
                    const pad: u32 = @intCast(label_w - current_label_w + 2);
                    col += pad;
                    _ = region.writeStr(col, row, desc, muted, Color.default, .{ .dim = true });
                }
            }
            row += 1;
        }

        // scroll indicator
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
};

// ── Tests ──────────────────────────────────────────────────────────

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

fn testTheme() Theme {
    return Theme.dark;
}

fn makeItems() [3]SelectItem {
    return .{
        .{ .value = "a", .label = "Alpha", .description = "first letter" },
        .{ .value = "b", .label = "Beta", .description = "second letter" },
        .{ .value = "c", .label = "Gamma", .description = null },
    };
}

/// Helper: read a row of rendered cells as ASCII text.
fn readRow(buf: *const Buffer, row: u32) [80]u8 {
    var out: [80]u8 = .{' '} ** 80;
    for (0..@min(buf.width, 80)) |x| {
        const cell = buf.get(@intCast(x), row);
        const cp = switch (cell.grapheme) {
            .codepoint => |c| c,
            .pooled => ' ',
        };
        if (cp < 128) {
            out[x] = @intCast(cp);
        }
    }
    return out;
}

test "SelectList renders items with selection indicator" {
    const theme = testTheme();
    var items = makeItems();

    var sl = SelectList{
        .theme = &theme,
    };
    sl.setItems(&items);

    var buf = try Buffer.init(testing.allocator, 60, 10);
    defer buf.deinit();

    sl.render(buf.region());

    // row 0 should have the arrow prefix for the selected item (index 0)
    const row0 = readRow(&buf, 0);
    // "→ " is 3 bytes (e2 86 92 + space) but → is a non-ASCII char
    // The arrow codepoint is U+2192 which has charWidth=1, so col 0 = →, col 1 = ' '
    const cell0 = buf.get(0, 0);
    try testing.expectEqual(@as(u21, 0x2192), cell0.grapheme.codepoint);

    // row 1 should have space prefix (unselected)
    const cell1_0 = buf.get(0, 1);
    try testing.expectEqual(@as(u21, ' '), cell1_0.grapheme.codepoint);
    _ = row0;
}

test "SelectList up/down wraps around" {
    const theme = testTheme();
    var items = makeItems();

    var sl = SelectList{
        .theme = &theme,
    };
    sl.setItems(&items);

    // start at 0, go up -> wrap to 2
    const r1 = sl.processInput(.{ .code = .up });
    try testing.expectEqual(InputResult.consumed, r1);
    try testing.expectEqual(@as(u32, 2), sl.selected_index);

    // go down -> wrap to 0
    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 0), sl.selected_index);

    // go down twice -> index 2, then down -> wrap to 0
    _ = sl.processInput(.{ .code = .down });
    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 2), sl.selected_index);
    _ = sl.processInput(.{ .code = .down });
    try testing.expectEqual(@as(u32, 0), sl.selected_index);
}

test "SelectList enter returns selected" {
    const theme = testTheme();
    var items = makeItems();

    var sl = SelectList{
        .theme = &theme,
    };
    sl.setItems(&items);
    _ = sl.processInput(.{ .code = .down }); // select "Beta"

    const r = sl.processInput(.{ .code = .enter });
    try testing.expectEqual(InputResult.selected, r);

    const item = sl.getSelectedItem().?;
    try testing.expectEqualStrings("Beta", item.label);
}

test "SelectList escape returns cancelled" {
    const theme = testTheme();

    var sl = SelectList{
        .theme = &theme,
    };

    const r = sl.processInput(.{ .code = .escape });
    try testing.expectEqual(InputResult.cancelled, r);
}

test "SelectList empty items shows no match message" {
    const theme = testTheme();

    var sl = SelectList{
        .theme = &theme,
    };

    var buf = try Buffer.init(testing.allocator, 40, 5);
    defer buf.deinit();

    sl.render(buf.region());

    // "  No matching commands" starts at col 2
    try testing.expectEqual(@as(u21, 'N'), buf.get(2, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'o'), buf.get(3, 0).grapheme.codepoint);

    // getSelectedItem returns null
    try testing.expectEqual(@as(?*const SelectItem, null), sl.getSelectedItem());
}

test "SelectList measure reports correct height" {
    const theme = testTheme();

    var sl = SelectList{
        .theme = &theme,
        .max_visible = 5,
    };

    // empty
    const m0 = sl.measure(80);
    try testing.expectEqual(@as(u32, 1), m0.preferred_height);

    // 3 items (< max_visible) -> no scroll indicator
    var items = makeItems();
    sl.setItems(&items);
    const m1 = sl.measure(80);
    try testing.expectEqual(@as(u32, 3), m1.preferred_height);

    // 7 items (> max_visible=5) -> 5 + 1 scroll indicator = 6
    var many: [7]SelectItem = undefined;
    for (&many, 0..) |*item, i| {
        item.* = .{
            .value = "v",
            .label = if (i < 3) "A" else "B",
            .description = null,
        };
    }
    sl.setItems(&many);
    const m2 = sl.measure(80);
    try testing.expectEqual(@as(u32, 6), m2.preferred_height);
}
