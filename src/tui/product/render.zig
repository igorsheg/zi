const std = @import("std");
const vaxis = @import("vaxis");

const app_mod = @import("App.zig");
const frame_mod = @import("frame.zig");

pub const CursorTarget = struct {
    column: u16,
    row: u16,
};

pub const Result = struct {
    cursor: ?CursorTarget,
};

pub fn render(win: vaxis.Window, frame: frame_mod.Frame) Result {
    win.clear();
    renderTranscript(win, frame);
    return .{ .cursor = renderComposer(win, frame) };
}

fn renderTranscript(win: vaxis.Window, frame: frame_mod.Frame) void {
    const transcript_height = transcriptHeight(win);
    for (frame.transcript_rows, 0..) |row, row_index| {
        if (row_index == transcript_height) break;
        printLine(win, @intCast(row_index), row.text);
    }
}

fn renderComposer(win: vaxis.Window, frame: frame_mod.Frame) ?CursorTarget {
    if (win.height == 0 or win.width == 0) return null;
    const composer_height = composerHeight(frame);
    const composer_row_start = win.height - composer_height;
    for (frame.composer.lines, 0..) |line, row_index| {
        if (row_index == composer_height) break;
        printLine(win, composer_row_start + @as(u16, @intCast(row_index)), line.text);
    }
    return .{
        .column = @min(frame.composer.cursor_column, win.width - 1),
        .row = @min(composer_row_start + frame.composer.cursor_row, win.height - 1),
    };
}

fn printLine(win: vaxis.Window, row: u16, line: []const u8) void {
    _ = win.print(&.{.{ .text = line }}, .{
        .col_offset = 0,
        .row_offset = row,
        .commit = true,
        .wrap = .grapheme,
    });
}

fn transcriptHeight(win: vaxis.Window) usize {
    if (win.height == 0) return 0;
    return win.height - 1;
}

fn composerHeight(frame: frame_mod.Frame) u16 {
    return @max(1, @as(u16, @intCast(frame.composer.lines.len)));
}

fn testWindow(screen: *vaxis.Screen, width: u16, height: u16) vaxis.Window {
    screen.* = vaxis.Screen.init(std.testing.allocator, .{
        .rows = height,
        .cols = width,
        .x_pixel = 0,
        .y_pixel = 0,
    }) catch unreachable;
    screen.width_method = .unicode;
    return .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = width,
        .height = height,
        .screen = screen,
    };
}

test "renderer draws transcript rows and composer at bottom" {
    var app = app_mod.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .resize = .{ .width_columns = 6, .height_rows = 4 } });
    const item_id = (try app.apply(std.testing.allocator, .{ .append_transcript_item = .assistant_message })).?;
    _ = try app.apply(std.testing.allocator, .{
        .append_transcript_text = .{ .item_id = item_id, .bytes = "hello" },
    });
    try app.ensureTranscriptRows(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .insert_composer_text = "ask" });
    var frame_scratch: frame_mod.Scratch = .{};
    const model = try frame_scratch.build(&app);
    var screen: vaxis.Screen = undefined;
    defer screen.deinit(std.testing.allocator);
    const win = testWindow(&screen, 6, 4);

    const result = render(win, model);

    try std.testing.expectEqualStrings("h", win.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("a", win.readCell(0, 3).?.char.grapheme);
    try std.testing.expectEqual(@as(u16, 3), result.cursor.?.column);
    try std.testing.expectEqual(@as(u16, 3), result.cursor.?.row);
}

test "renderer clips narrow windows without mutating app" {
    var app = app_mod.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .resize = .{ .width_columns = 2, .height_rows = 2 } });
    _ = try app.apply(std.testing.allocator, .{ .insert_composer_text = "abcd" });
    const cursor_before = app.composer.buffer.cursor_byte_index;
    var frame_scratch: frame_mod.Scratch = .{};
    const model = try frame_scratch.build(&app);
    var screen: vaxis.Screen = undefined;
    defer screen.deinit(std.testing.allocator);
    const win = testWindow(&screen, 2, 2);

    const result = render(win, model);

    try std.testing.expectEqualStrings("a", win.readCell(0, 0).?.char.grapheme);
    try std.testing.expectEqualStrings("c", win.readCell(0, 1).?.char.grapheme);
    try std.testing.expectEqual(@as(u16, 1), result.cursor.?.row);
    try std.testing.expectEqualStrings("abcd", app.composer.buffer.bytes.items);
    try std.testing.expectEqual(cursor_before, app.composer.buffer.cursor_byte_index);
}
