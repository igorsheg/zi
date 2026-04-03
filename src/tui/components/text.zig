const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const grapheme = @import("../grapheme.zig");

pub const Text = struct {
    content: []const u8 = "",
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},

    pub fn setContent(self: *Text, text: []const u8) void {
        self.content = text;
    }

    pub fn render(self: *Text, region: Region) void {
        if (self.content.len == 0) return;
        _ = region.writeStr(0, 0, self.content, self.fg, self.bg, self.attrs);
    }

    pub fn measure(self: *Text, width: u32) Measurement {
        if (self.content.len == 0) return .{ .min_height = 0, .preferred_height = 0 };
        const w = grapheme.strWidth(self.content);
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };
        const lines: u32 = @intCast(@max(1, (w + width - 1) / width));
        return .{ .min_height = 1, .preferred_height = lines };
    }

    pub fn component(self: *Text) Component {
        return Component.init(Text, self);
    }
};

test "Text renders content to buffer" {
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 5);
    defer buf.deinit();

    var text = Text{ .content = "hello", .fg = Color.rgb(255, 255, 255) };
    text.render(buf.region());

    try std.testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'o'), buf.get(4, 0).grapheme.codepoint);
    try std.testing.expect(buf.get(0, 0).fg.eql(Color.rgb(255, 255, 255)));
}

test "Text measure returns line count" {
    var text = Text{ .content = "hello world" };
    const m = text.measure(5);
    try std.testing.expectEqual(@as(u32, 3), m.preferred_height);
}

test "Text empty content" {
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 10, 5);
    defer buf.deinit();

    var text = Text{};
    text.render(buf.region());
    try std.testing.expect(buf.get(0, 0).eql(cell_mod.Cell.blank));
}
