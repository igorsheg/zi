const std = @import("std");
const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const theme_mod = @import("../theme.zig");
const text_layout = @import("../text/layout.zig");
const grapheme = @import("../grapheme.zig");
const themes_builtin = @import("../../themes/builtin.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const measurement = component_mod.measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Theme = theme_mod.Theme;

pub const Kind = enum {
    info,
    loading,
    @"error",
};

pub const StatusText = struct {
    allocator: std.mem.Allocator,
    theme: *const Theme,
    text: []const u8 = "",
    kind: Kind = .info,
    width_method: grapheme.WidthMethod,

    pub fn init(allocator: std.mem.Allocator, theme: *const Theme, width_method: grapheme.WidthMethod) StatusText {
        return .{ .allocator = allocator, .theme = theme, .width_method = width_method };
    }

    pub fn set(self: *StatusText, text: []const u8, kind: Kind) void {
        self.text = text;
        self.kind = kind;
    }

    pub fn clear(self: *StatusText) void {
        self.text = "";
        self.kind = .info;
    }

    pub fn render(self: *StatusText, region: Region) void {
        if (self.text.len == 0 or region.width == 0 or region.height == 0) return;

        const lines = text_layout.wrapLines(self.text, region.width, .word, self.allocator, self.width_method) catch return;
        defer self.allocator.free(lines);

        const fg = self.color();
        const attrs: cell_mod.Attributes = .{ .dim = self.kind == .info };
        var row: u32 = 0;
        while (row < region.height and row < lines.len) : (row += 1) {
            _ = region.writeStr(0, row, lines[row].text(self.text), fg, Color.default, attrs);
        }
    }

    pub fn measure(self: *StatusText, width: u32) Measurement {
        if (self.text.len == 0) return measurement(0, 0);
        if (width == 0) return measurement(1, 1);
        const lines = text_layout.wrapLines(self.text, width, .word, self.allocator, self.width_method) catch
            return measurement(1, 1);
        defer self.allocator.free(lines);
        const h: u32 = @intCast(lines.len);
        return measurement(1, h);
    }

    pub fn component(self: *StatusText) Component {
        return Component.init(StatusText, self);
    }

    fn color(self: *const StatusText) Color {
        return switch (self.kind) {
            .info => self.theme.fg(.muted),
            .loading => self.theme.fg(.accent),
            .@"error" => self.theme.fg(.@"error"),
        };
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "StatusText wraps when region offers multiple rows" {
    var buf = try Buffer.init(testing.allocator, 7, 2, .wcwidth);
    defer buf.deinit();

    var status = StatusText.init(testing.allocator, themes_builtin.dark(), .wcwidth);
    status.set("loading sessions", .loading);

    try testing.expectEqual(@as(u32, 2), status.measure(7).preferred_height);
    status.render(buf.region());

    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 's'), buf.get(0, 1).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).fg.eql(themes_builtin.dark().fg(.accent)));
}

test "StatusText keeps one-row callers clipped by region height" {
    var buf = try Buffer.init(testing.allocator, 7, 1, .wcwidth);
    defer buf.deinit();

    var status = StatusText.init(testing.allocator, themes_builtin.dark(), .wcwidth);
    status.set("loading sessions", .info);
    status.render(buf.region());

    try testing.expectEqual(@as(u21, 'l'), buf.get(0, 0).grapheme.codepoint);
    try testing.expect(buf.get(0, 0).attrs.dim);
}

test "StatusText measure uses configured width method" {
    var status = StatusText.init(testing.allocator, themes_builtin.dark(), .unicode);
    status.set("☕☕", .info);

    try testing.expectEqual(@as(u32, 2), status.measure(3).preferred_height);
}
