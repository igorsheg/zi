const std = @import("std");
const buffer_mod = @import("surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Buffer = buffer_mod.Buffer;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Theme = theme_mod.Theme;

pub const SelectableRow = struct {
    label: []const u8,
    description: ?[]const u8 = null,
    selected: bool = false,
    /// Display width of the widest visible label. Used to align descriptions.
    label_width: u32 = 0,
    /// Match SelectList's historical behavior: descriptions appear only when
    /// the containing region is wider than this threshold.
    description_min_width: u32 = 40,
    description_gap: u32 = 2,

    pub fn render(self: SelectableRow, region: Region, row: u32, theme: *const Theme) void {
        if (row >= region.height) return;

        const label_fg = if (self.selected) theme.fg(.accent) else theme.fg(.text);
        const prefix_fg = if (self.selected) theme.fg(.accent) else label_fg;
        const prefix: []const u8 = if (self.selected) "\xe2\x86\x92 " else "  ";

        var col = region.writeStr(0, row, prefix, prefix_fg, Color.default, .{});
        col += region.writeStr(col, row, self.label, label_fg, Color.default, .{});

        if (self.description) |desc| {
            if (region.width > self.description_min_width) {
                const current_label_w = region.textWidth(self.label);
                const label_pad = self.label_width -| current_label_w;
                col += label_pad + self.description_gap;
                _ = region.writeStr(col, row, desc, theme.fg(.muted), Color.default, .{ .dim = true });
            }
        }
    }
};

pub fn renderSelectableRow(row: SelectableRow, region: Region, row_index: u32, theme: *const Theme) void {
    row.render(region, row_index, theme);
}

fn firstCodepointColumn(buf: *const Buffer, row: u32, cp: u21) ?u32 {
    var x: u32 = 0;
    while (x < buf.width) : (x += 1) {
        const cell = buf.get(x, row);
        if (cell.width == 0) continue;
        switch (cell.grapheme) {
            .codepoint => |c| if (c == cp) return x,
            .pooled => {},
        }
    }
    return null;
}

test "SelectableRow renders selected prefix and colors" {
    const theme = themes_builtin.dark();
    var buf = try Buffer.init(std.testing.allocator, 20, 1, .wcwidth);
    defer buf.deinit();

    (SelectableRow{ .label = "Alpha", .selected = true }).render(buf.region(), 0, theme);

    const arrow = buf.get(0, 0);
    try std.testing.expect(arrow.grapheme.eql(.{ .codepoint = '→' }));
    try std.testing.expect(arrow.fg.eql(theme.fg(.accent)));

    const label = buf.get(2, 0);
    try std.testing.expect(label.grapheme.eql(.{ .codepoint = 'A' }));
    try std.testing.expect(label.fg.eql(theme.fg(.accent)));
}

test "SelectableRow aligns and dims descriptions only when wide" {
    const theme = themes_builtin.dark();

    var wide = try Buffer.init(std.testing.allocator, 50, 1, .wcwidth);
    defer wide.deinit();
    (SelectableRow{ .label = "A", .description = "desc", .label_width = 5 }).render(wide.region(), 0, theme);
    try std.testing.expectEqual(@as(?u32, 8), firstCodepointColumn(&wide, 0, 'd'));
    const desc = wide.get(8, 0);
    try std.testing.expect(desc.fg.eql(theme.fg(.muted)));
    try std.testing.expect(desc.attrs.dim);

    var narrow = try Buffer.init(std.testing.allocator, 40, 1, .wcwidth);
    defer narrow.deinit();
    (SelectableRow{ .label = "A", .description = "desc", .label_width = 5 }).render(narrow.region(), 0, theme);
    try std.testing.expectEqual(@as(?u32, null), firstCodepointColumn(&narrow, 0, 'd'));
}
