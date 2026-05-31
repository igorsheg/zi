const vaxis = @import("vaxis");

const App = @import("App.zig");
const Transcript = @import("transcript.zig").Transcript;

pub fn render(app: *App, root: vaxis.Window) void {
    root.clear();
    root.hideCursor();
    if (root.width == 0 or root.height == 0) {
        app.markClean();
        return;
    }

    drawLine(root.child(.{ .x_off = 0, .y_off = 0, .height = 1 }), "zi", .{ .bold = true });

    const composer_row: u16 = root.height - 1;
    const status_row: u16 = if (root.height >= 2) root.height - 2 else composer_row;
    if (root.height >= 2) drawLine(
        root.child(.{ .x_off = 0, .y_off = @intCast(status_row), .height = 1 }),
        statusText(app.status),
        .{},
    );
    if (root.height >= 3) {
        const transcript_height: u16 = root.height - 2;
        const transcript_win = root.child(.{
            .x_off = 0,
            .y_off = 1,
            .height = transcript_height - 1,
        });
        drawTranscript(app, transcript_win);
    }

    const composer_win = root.child(.{ .x_off = 0, .y_off = @intCast(composer_row), .height = 1 });
    drawComposer(app, composer_win);
    app.markClean();
}

fn drawTranscript(app: *App, win: vaxis.Window) void {
    if (win.width == 0 or win.height == 0) return;
    var row: u16 = win.height;
    var index = app.transcript.count;
    while (index > 0 and row > 0) {
        index -= 1;
        const item = app.transcript.items[index];
        row -= 1;
        drawLineAt(win, row, itemPrefix(item.kind), item.text);
    }
}

fn drawComposer(app: *App, win: vaxis.Window) void {
    drawLineAt(win, 0, "> ", app.composer.bytes.items);
    const cursor_col = @min(app.composer.cursorCol(win.width) + 2, if (win.width == 0) 0 else win.width - 1);
    win.showCursor(cursor_col, 0);
}

fn drawLine(win: vaxis.Window, text: []const u8, style: vaxis.Style) void {
    const segment = [_]vaxis.Cell.Segment{.{ .text = text, .style = style }};
    _ = win.print(&segment, .{ .wrap = .none });
}

fn drawLineAt(win: vaxis.Window, row: u16, prefix: []const u8, text: []const u8) void {
    const child = win.child(.{ .x_off = 0, .y_off = @intCast(row), .height = 1 });
    const segments = [_]vaxis.Cell.Segment{
        .{ .text = prefix, .style = .{ .bold = true } },
        .{ .text = tailForWidth(text, win.width -| @as(u16, @intCast(prefix.len))), .style = .{} },
    };
    _ = child.print(&segments, .{ .wrap = .none });
}

fn statusText(status: App.Status) []const u8 {
    return switch (status) {
        .idle => "idle",
        .running => "running",
        .cancel_requested => "cancel requested",
        .failed => "failed",
    };
}

fn itemPrefix(kind: Transcript.Kind) []const u8 {
    return switch (kind) {
        .system => "* ",
        .user => "u ",
        .assistant => "a ",
        .tool => "t ",
    };
}

fn tailForWidth(text: []const u8, width: u16) []const u8 {
    if (width == 0) return "";
    if (text.len <= width) return text;
    return text[text.len - width ..];
}
