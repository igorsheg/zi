const std = @import("std");
const vaxis = @import("vaxis");

const composer_mod = @import("composer.zig");
const text = @import("../primitive/text.zig");

pub const line_count_max = 8;

pub const Line = struct {
    text: []const u8,
};

pub const ReadModel = struct {
    lines: []const Line,
    cursor_row: u16,
    cursor_column: u16,
    is_empty: bool,
};

pub const Scratch = struct {
    lines: [line_count_max]Line = undefined,

    pub fn project(self: *Scratch, composer: *const composer_mod.Composer, width_columns: u16) !ReadModel {
        const bytes = composer.buffer.bytes.items;
        const is_empty = bytes.len == 0;
        if (width_columns == 0) {
            return .{
                .lines = self.lines[0..0],
                .cursor_row = 0,
                .cursor_column = 0,
                .is_empty = is_empty,
            };
        }

        var line_count: usize = 0;
        var cursor_row: u16 = 0;
        var cursor_column: u16 = 0;

        if (is_empty) {
            self.lines[0] = .{ .text = "" };
            return .{
                .lines = self.lines[0..1],
                .cursor_row = 0,
                .cursor_column = 0,
                .is_empty = true,
            };
        }

        var line_start: usize = 0;
        var column: u16 = 0;
        var iter = vaxis.unicode.graphemeIterator(bytes);
        while (iter.next()) |grapheme| {
            const grapheme_bytes = bytes[grapheme.start..][0..grapheme.len];
            const grapheme_width = text.displayWidth(grapheme_bytes);
            if (grapheme_width != 0 and column != 0 and column + grapheme_width > width_columns) {
                if (line_count == self.lines.len) return error.ComposerViewLineLimitReached;
                self.lines[line_count] = .{ .text = bytes[line_start..grapheme.start] };
                line_count += 1;
                line_start = grapheme.start;
                column = 0;
            }

            if (composer.buffer.cursor_byte_index == grapheme.start) {
                cursor_row = @intCast(line_count);
                cursor_column = column;
            }

            column = @min(width_columns, column + grapheme_width);
        }

        if (line_count == self.lines.len) return error.ComposerViewLineLimitReached;
        self.lines[line_count] = .{ .text = bytes[line_start..] };
        line_count += 1;
        if (composer.buffer.cursor_byte_index == bytes.len) {
            cursor_row = @intCast(line_count - 1);
            cursor_column = column;
        }

        return .{
            .lines = self.lines[0..line_count],
            .cursor_row = cursor_row,
            .cursor_column = cursor_column,
            .is_empty = false,
        };
    }
};

test "composer view projects empty input as one empty line" {
    var composer: composer_mod.Composer = .{};
    defer composer.deinit(std.testing.allocator);
    var scratch: Scratch = .{};

    const model = try scratch.project(&composer, 10);

    try std.testing.expectEqual(@as(usize, 1), model.lines.len);
    try std.testing.expectEqualStrings("", model.lines[0].text);
    try std.testing.expectEqual(@as(u16, 0), model.cursor_row);
    try std.testing.expectEqual(@as(u16, 0), model.cursor_column);
    try std.testing.expect(model.is_empty);
}

test "composer view wraps text and maps cursor" {
    var composer: composer_mod.Composer = .{};
    defer composer.deinit(std.testing.allocator);
    try composer.apply(std.testing.allocator, .{ .insert_text = "abcdef" });
    try composer.apply(std.testing.allocator, .move_left);
    try composer.apply(std.testing.allocator, .move_left);
    var scratch: Scratch = .{};

    const model = try scratch.project(&composer, 3);

    try std.testing.expectEqual(@as(usize, 2), model.lines.len);
    try std.testing.expectEqualStrings("abc", model.lines[0].text);
    try std.testing.expectEqualStrings("def", model.lines[1].text);
    try std.testing.expectEqual(@as(u16, 1), model.cursor_row);
    try std.testing.expectEqual(@as(u16, 1), model.cursor_column);
}

test "composer view does not mutate composer" {
    var composer: composer_mod.Composer = .{};
    defer composer.deinit(std.testing.allocator);
    try composer.apply(std.testing.allocator, .{ .insert_text = "hello" });
    const cursor_before = composer.buffer.cursor_byte_index;
    var scratch: Scratch = .{};

    _ = try scratch.project(&composer, 2);
    _ = try scratch.project(&composer, 4);

    try std.testing.expectEqualStrings("hello", composer.buffer.bytes.items);
    try std.testing.expectEqual(cursor_before, composer.buffer.cursor_byte_index);
}
