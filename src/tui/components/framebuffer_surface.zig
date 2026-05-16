const std = @import("std");

const buffer_mod = @import("../primitives/surface.zig");
const cell_mod = @import("../cell.zig");
const component_mod = @import("../primitives/view.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");

const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const measurement = component_mod.measurement;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;

pub const FramebufferSurface = struct {
    allocator: std.mem.Allocator,
    frame: ?extension_ui.UiFrame = null,
    focused: bool = false,

    pub fn init(allocator: std.mem.Allocator) FramebufferSurface {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FramebufferSurface) void {
        self.clearFrame();
    }

    pub fn component(self: *FramebufferSurface) Component {
        return Component.init(FramebufferSurface, self);
    }

    pub fn setFocused(self: *FramebufferSurface, focused: bool) void {
        self.focused = focused;
    }

    pub fn handleInput(_: *FramebufferSurface, _: @import("../terminal/keys.zig").Key) bool {
        return false;
    }

    pub fn applyFrame(self: *FramebufferSurface, frame: extension_ui.UiFrame) void {
        frame.validate() catch return;
        self.clearFrame();
        self.frame = extension_ui.UiFrame.clone(self.allocator, frame) catch null;
    }

    fn clearFrame(self: *FramebufferSurface) void {
        if (self.frame) |*frame| frame.deinit(self.allocator);
        self.frame = null;
    }

    pub fn measure(self: *FramebufferSurface, width: u32) Measurement {
        const frame = self.frame orelse return measurement(0, 0);
        if (width == 0 or frame.width == 0 or frame.height == 0) return measurement(0, 0);
        const rows = switch (frame.format) {
            .rgba8888 => scaledRows(frame.width, frame.height, width),
            .halfblock_rgb => frame.height,
        };
        return measurement(@min(rows, 1), rows);
    }

    pub fn render(self: *FramebufferSurface, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *FramebufferSurface, region: Region, first_row: u32) void {
        const frame = self.frame orelse return;
        renderFrame(region, frame, first_row);
    }
};

pub fn renderFrame(region: Region, frame: extension_ui.UiFrame, first_row: u32) void {
    if (frame.format == .halfblock_rgb) return renderHalfblockFrame(region, frame, first_row);
    if (region.width == 0 or region.height == 0) return;
    if (expectedFrameBytes(frame.width, frame.height, frame.format)) |needed| {
        if (frame.data.len < needed) return;
    } else return;

    const rows_total = scaledRows(frame.width, frame.height, region.width);
    var y: u32 = 0;
    while (y < region.height and first_row + y < rows_total) : (y += 1) {
        var x: u32 = 0;
        while (x < region.width) : (x += 1) {
            const src_x = @min(frame.width - 1, (x * frame.width) / region.width);
            const upper_y = @min(frame.height - 1, (((first_row + y) * 2) * frame.height) / (rows_total * 2));
            const lower_y = @min(frame.height - 1, ((((first_row + y) * 2) + 1) * frame.height) / (rows_total * 2));
            const upper = rgbaAt(frame.data, frame.width, src_x, upper_y);
            const lower = rgbaAt(frame.data, frame.width, src_x, lower_y);
            region.set(x, y, .{
                .grapheme = .{ .codepoint = '▀' },
                .fg = Color.rgb(upper.r, upper.g, upper.b),
                .bg = Color.rgb(lower.r, lower.g, lower.b),
                .attrs = Attributes.none,
            });
        }
    }
}

const Rgb = struct { r: u8, g: u8, b: u8 };

fn expectedFrameBytes(width: u32, height: u32, format: extension_ui.FrameFormat) ?usize {
    return format.expectedBytes(width, height);
}

fn renderHalfblockFrame(region: Region, frame: extension_ui.UiFrame, first_row: u32) void {
    if (region.width == 0 or region.height == 0 or frame.width == 0 or frame.height == 0) return;
    const expected = expectedFrameBytes(frame.width, frame.height, frame.format) orelse return;
    if (frame.data.len < expected) return;
    var y: u32 = 0;
    while (y < region.height and first_row + y < frame.height) : (y += 1) {
        const src_y = first_row + y;
        var x: u32 = 0;
        while (x < region.width) : (x += 1) {
            const src_x = @min(frame.width - 1, (x * frame.width) / region.width);
            const off: usize = (@as(usize, src_y) * @as(usize, frame.width) + @as(usize, src_x)) * 6;
            region.set(x, y, .{
                .grapheme = .{ .codepoint = '▀' },
                .fg = Color.rgb(frame.data[off], frame.data[off + 1], frame.data[off + 2]),
                .bg = Color.rgb(frame.data[off + 3], frame.data[off + 4], frame.data[off + 5]),
                .attrs = Attributes.none,
            });
        }
    }
}

fn scaledRows(src_width: u32, src_height: u32, target_cols: u32) u32 {
    if (src_width == 0 or src_height == 0 or target_cols == 0) return 0;
    const pixel_rows = std.math.divCeil(u64, @as(u64, target_cols) * src_height, src_width) catch 1;
    const terminal_rows = std.math.divCeil(u64, pixel_rows, 2) catch 1;
    return @intCast(@max(terminal_rows, 1));
}

fn rgbaAt(data: []const u8, width: u32, x: u32, y: u32) Rgb {
    const offset: usize = (@as(usize, y) * @as(usize, width) + @as(usize, x)) * 4;
    return .{ .r = data[offset], .g = data[offset + 1], .b = data[offset + 2] };
}

test "framebuffer surface measures half-block rows" {
    var surface = FramebufferSurface.init(std.testing.allocator);
    defer surface.deinit();
    try std.testing.expectEqual(@as(u32, 0), surface.measure(80).preferred_height);
}
