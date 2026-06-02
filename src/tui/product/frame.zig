const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");

pub const size_cells_max: usize = 500_000;

pub const Frame = struct {
    width: u16,
    height: u16,

    pub fn build(app: anytype, renderer: *infra.Renderer) !void {
        if (renderer.next.width != app.width or renderer.next.height != app.height) {
            try renderer.resize(app.width, app.height);
        }
        renderer.next.clear();
        try drawShell(app, renderer);
    }
};

fn drawShell(app: anytype, renderer: *infra.Renderer) !void {
    const label_style: primitive.Style = .{ .fg = .{ .indexed = 8 }, .bold = true };
    const composer_style: primitive.Style = .{};
    const transcript_style: primitive.Style = .{ .fg = .{ .indexed = 7 } };

    if (app.height > 0) try renderer.writeText(0, 0, "zi", label_style);
    if (app.height > 2) try renderer.writeText(0, 1, "ready", transcript_style);
    if (app.height > 0) {
        const composer_y = app.height - 1;
        try renderer.writeText(0, composer_y, "> ", label_style);
        if (app.width > 2) try renderer.writeText(2, composer_y, app.composer.text(), composer_style);
    }
}

pub fn checkSize(width: u16, height: u16) !void {
    const count = @as(usize, width) * height;
    if (count == 0) return error.EmptyFrame;
    if (count > size_cells_max) return error.FrameTooLarge;
}

test "frame rejects impossible sizes" {
    try std.testing.expectError(error.EmptyFrame, checkSize(0, 24));
    try std.testing.expectError(error.FrameTooLarge, checkSize(1000, 1000));
}
