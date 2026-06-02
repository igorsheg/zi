const std = @import("std");

const primitive = @import("../primitive/root.zig");
const app_mod = @import("App.zig");
const composer_view = @import("composer_view.zig");

pub const Frame = struct {
    size: app_mod.Size,
    transcript_rows: []const primitive.render_list.Row,
    composer: composer_view.ReadModel,
};

pub const Scratch = struct {
    composer: composer_view.Scratch = .{},

    pub fn build(self: *Scratch, app: *const app_mod.ProductApp) !Frame {
        return .{
            .size = app.size,
            .transcript_rows = app.visibleTranscriptRows(),
            .composer = try self.composer.project(&app.composer, app.size.width_columns),
        };
    }
};

test "frame borrows transcript rows and composer projection" {
    var app = app_mod.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .resize = .{ .width_columns = 4, .height_rows = 3 } });
    _ = try app.apply(std.testing.allocator, .{ .insert_composer_text = "draft" });
    const item_id = (try app.apply(std.testing.allocator, .{ .append_transcript_item = .assistant_message })).?;
    _ = try app.apply(std.testing.allocator, .{
        .append_transcript_text = .{ .item_id = item_id, .bytes = "abcdefgh" },
    });
    try app.ensureTranscriptRows(std.testing.allocator);
    var scratch: Scratch = .{};

    const model = try scratch.build(&app);

    try std.testing.expectEqual(@as(u16, 4), model.size.width_columns);
    try std.testing.expectEqual(@as(usize, 2), model.transcript_rows.len);
    try std.testing.expectEqual(@as(usize, 2), model.composer.lines.len);
    try std.testing.expectEqualStrings("draf", model.composer.lines[0].text);
    try std.testing.expectEqualStrings("t", model.composer.lines[1].text);
}

test "frame build is read-only" {
    var app = app_mod.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    _ = try app.apply(std.testing.allocator, .{ .insert_composer_text = "hello" });
    const cursor_before = app.composer.buffer.cursor_byte_index;
    const row_count_before = app.transcript_render_rows.rows.items.len;
    const dirty_before = app.dirty;
    var scratch: Scratch = .{};

    _ = try scratch.build(&app);
    _ = try scratch.build(&app);

    try std.testing.expectEqualStrings("hello", app.composer.buffer.bytes.items);
    try std.testing.expectEqual(cursor_before, app.composer.buffer.cursor_byte_index);
    try std.testing.expectEqual(row_count_before, app.transcript_render_rows.rows.items.len);
    try std.testing.expectEqual(dirty_before, app.dirty);
}
