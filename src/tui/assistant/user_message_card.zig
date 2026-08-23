// Adapted from vercel-labs/fx src/ui/assistant/user_message_card.zig.
// Licensed under Apache-2.0 and adapted to Zi's semantic transcript rows.
const std = @import("std");
const terminal_render = @import("../../terminal_render/root.zig");

const marker_style = "\x1b[38;5;255m";
const reset_style = "\x1b[0m";
const prompt_text_style = "\x1b[1m";
const rail = "┃";

pub const Card = struct {
    rows: []const []const u8,
};

const WrapCut = struct {
    keep_bytes: usize,
    skip_bytes: usize,
};

/// Builds a width-specific user turn. Every physical row repeats the rail, so
/// wrapped prompts remain one connected visual object after terminal reflow.
pub fn build(allocator: std.mem.Allocator, text: []const u8, columns: u16) !Card {
    var rows: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (rows.items) |row| allocator.free(row);
        rows.deinit(allocator);
    }
    if (text.len == 0 or columns <= 2) return .{ .rows = try rows.toOwnedSlice(allocator) };

    const row_budget: usize = columns - 2;
    var logical_lines = std.mem.splitScalar(u8, text, '\n');
    while (logical_lines.next()) |line| {
        if (line.len == 0) {
            try appendRow(allocator, &rows, "");
            continue;
        }

        var remaining = line;
        while (remaining.len != 0) {
            const cut = wrapCut(remaining, row_budget);
            try appendRow(allocator, &rows, remaining[0..cut.keep_bytes]);
            remaining = remaining[cut.skip_bytes..];
        }
    }
    return .{ .rows = try rows.toOwnedSlice(allocator) };
}

fn appendRow(
    allocator: std.mem.Allocator,
    rows: *std.ArrayList([]const u8),
    content: []const u8,
) !void {
    var row: std.Io.Writer.Allocating = .init(allocator);
    errdefer row.deinit();
    try row.writer.writeAll(marker_style);
    try row.writer.writeAll(rail);
    try row.writer.writeAll(reset_style);
    try row.writer.writeByte(' ');
    try row.writer.writeAll(prompt_text_style);
    try row.writer.writeAll(content);
    try row.writer.writeAll(reset_style);
    const owned = try row.toOwnedSlice();
    errdefer allocator.free(owned);
    try rows.append(allocator, owned);
}

fn wrapCut(text: []const u8, row_budget: usize) WrapCut {
    if (row_budget == 0) return .{ .keep_bytes = 0, .skip_bytes = text.len };
    const prefix_len = prefixByWidth(text, row_budget);
    if (prefix_len == text.len) return .{ .keep_bytes = prefix_len, .skip_bytes = prefix_len };

    if (lastSpaceIn(text[0..prefix_len])) |space| {
        return .{ .keep_bytes = space, .skip_bytes = space + 1 };
    }
    if (prefix_len != 0) return .{ .keep_bytes = prefix_len, .skip_bytes = prefix_len };

    var iterator = terminal_render.Text.Iterator.init(text);
    const first = iterator.next() orelse return .{ .keep_bytes = 0, .skip_bytes = text.len };
    return .{ .keep_bytes = first.endByte(), .skip_bytes = first.endByte() };
}

fn prefixByWidth(text: []const u8, maximum_width: usize) usize {
    var iterator = terminal_render.Text.Iterator.init(text);
    var width: usize = 0;
    var end: usize = 0;
    while (iterator.next()) |grapheme| {
        if (grapheme.kind == .line_break) break;
        if (grapheme.width != 0 and width + grapheme.width > maximum_width) break;
        width += grapheme.width;
        end = grapheme.endByte();
    }
    return end;
}

fn lastSpaceIn(text: []const u8) ?usize {
    var index = text.len;
    while (index != 0) {
        index -= 1;
        if (text[index] == ' ' or text[index] == '\t') return index;
    }
    return null;
}

test "user card repeats its connected rail across logical and wrapped rows" {
    const card = try build(std.testing.allocator, "line one\nabcdefgh", 7);
    defer {
        for (card.rows) |row| std.testing.allocator.free(row);
        std.testing.allocator.free(card.rows);
    }

    try std.testing.expectEqual(@as(usize, 4), card.rows.len);
    for (card.rows) |row| {
        try std.testing.expect(std.mem.startsWith(
            u8,
            row,
            marker_style ++ rail ++ reset_style ++ " " ++ prompt_text_style,
        ));
        try std.testing.expect(std.mem.endsWith(u8, row, reset_style));
    }
    try std.testing.expect(std.mem.find(u8, card.rows[0], "line") != null);
    try std.testing.expect(std.mem.find(u8, card.rows[1], "one") != null);
    try std.testing.expect(std.mem.find(u8, card.rows[2], "abcde") != null);
    try std.testing.expect(std.mem.find(u8, card.rows[3], "fgh") != null);
}

test "user card wraps without splitting a wide grapheme" {
    const card = try build(std.testing.allocator, "a界b", 4);
    defer {
        for (card.rows) |row| std.testing.allocator.free(row);
        std.testing.allocator.free(card.rows);
    }

    try std.testing.expectEqual(@as(usize, 3), card.rows.len);
    try std.testing.expect(std.mem.find(u8, card.rows[1], "界") != null);
}

test "user card yields no rows when a rail and content cannot fit" {
    const card = try build(std.testing.allocator, "hidden", 2);
    defer std.testing.allocator.free(card.rows);
    try std.testing.expectEqual(@as(usize, 0), card.rows.len);
}
