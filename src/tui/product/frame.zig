const std = @import("std");
const infra = @import("../infra/root.zig");
const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const transcript_mod = @import("transcript.zig");

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
    if (app.height > 0) {
        const composer_y = app.height - 1;
        const available_rows: usize = if (composer_y > 1) composer_y - 1 else 0;
        for (app.transcript.latest(available_rows), 0..) |line, index| {
            const y: u16 = @intCast(index + 1);
            const prefix = rolePrefix(line.role);
            try renderer.writeText(0, y, prefix, transcript_style);
            try renderer.writeText(@intCast(primitive.text.displayWidth(prefix)), y, line.text, transcript_style);
        }
    }
    if (app.height > 0) {
        const composer_y = app.height - 1;
        try renderer.writeText(0, composer_y, "> ", label_style);
        if (app.width > 2) try renderer.writeText(2, composer_y, app.composer.text(), composer_style);
    }
}

fn rolePrefix(role: transcript_mod.TranscriptRole) []const u8 {
    return switch (role) {
        .user => "user: ",
        .assistant => "assistant: ",
        .system => "system: ",
    };
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

fn expectCellText(buffer: anytype, x: u16, y: u16, text: []const u8) !void {
    for (text, 0..) |byte, index| {
        const cell = try buffer.get(@intCast(@as(usize, x) + index), y);
        try std.testing.expectEqual(@as(?u21, byte), cell.renderScalar());
    }
}

test "frame renders newest transcript lines and preserves composer row" {
    var app = try app_mod.ProductApp.init(40, 5);
    defer app.deinit(std.testing.allocator);

    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "old" });
    try app.transcript.append(std.testing.allocator, .{ .role = .user, .text = "one" });
    try app.transcript.append(std.testing.allocator, .{ .role = .assistant, .text = "two" });
    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "three" });
    try app.composer.insertUtf8(std.testing.allocator, "draft");

    var renderer = try infra.Renderer.init(std.testing.allocator, 40, 5, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);

    try expectCellText(renderer.next, 0, 0, "zi");
    try expectCellText(renderer.next, 0, 1, "user: one");
    try expectCellText(renderer.next, 0, 2, "assistant: two");
    try expectCellText(renderer.next, 0, 3, "system: three");
    try expectCellText(renderer.next, 0, 4, "> draft");

    const absent = try renderer.next.get(0, 1);
    try std.testing.expect(absent.renderScalar() != 'o');
}

test "frame keeps transcript out of tiny heights" {
    var app = try app_mod.ProductApp.init(20, 1);
    defer app.deinit(std.testing.allocator);
    try app.transcript.append(std.testing.allocator, .{ .role = .system, .text = "hidden" });

    var renderer = try infra.Renderer.init(std.testing.allocator, 20, 1, size_cells_max);
    defer renderer.deinit();
    try Frame.build(app, &renderer);
    try expectCellText(renderer.next, 0, 0, "> ");
}
