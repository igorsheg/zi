const vaxis = @import("vaxis");

const surface = @import("../primitive/surface.zig");

pub fn renderText(surf: *surface.Surface, win: vaxis.Window, text: []const u8) void {
    const child = win.child(.{
        .x_off = @intCast(surf.rect.x),
        .y_off = @intCast(surf.rect.y),
        .width = surf.rect.width,
        .height = surf.rect.height,
    });
    child.clear();
    _ = child.print(&.{.{ .text = text }}, .{ .wrap = .word });
    surf.markClean();
}

pub fn renderTextTail(surf: *surface.Surface, win: vaxis.Window, text: []const u8) void {
    const tail = text[tailStartForLineCount(text, surf.rect.height)..];
    renderText(surf, win, tail);
}

fn tailStartForLineCount(text: []const u8, line_count: u16) usize {
    if (line_count == 0 or text.len == 0) return text.len;

    var lines_seen: u16 = 1;
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (text[index] != '\n') continue;
        if (lines_seen == line_count) return index + 1;
        lines_seen += 1;
    }
    return 0;
}
