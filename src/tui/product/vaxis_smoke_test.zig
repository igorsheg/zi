const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");

// First new test after dropping the hand-rolled renderer tests: render Zi product
// state into Vaxis' native screen and assert through Vaxis cells.
test "vaxis screen receives zi frame" {
    var env = std.process.Environ.Map.init(std.testing.allocator);
    defer env.deinit();

    var vx = try vaxis.init(std.testing.io, std.testing.allocator, &env, .{});
    var output_storage: [4096]u8 = undefined;
    var writer = std.Io.Writer.fixed(&output_storage);
    defer vx.deinit(std.testing.allocator, &writer);

    try vx.resize(std.testing.allocator, &writer, .{ .cols = 30, .rows = 6, .x_pixel = 0, .y_pixel = 0 });

    var app = try app_mod.ProductApp.init(30, 6);
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .append_transcript = .{ .message = .{
        .role = .assistant,
        .text = "hello vaxis",
    } } });

    try frame_mod.Frame.build(&app, &vx);

    try expectText(vx.window(), 0, 0, "zi");
    try expectText(vx.window(), 1, 1, "hello vaxis");
}

fn expectText(window: vaxis.Window, x: u16, y: u16, text: []const u8) !void {
    var col = x;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        const cell = window.readCell(col, y) orelse return error.MissingCell;
        try std.testing.expectEqualStrings(text[index .. index + 1], cell.char.grapheme);
        col += 1;
    }
}
