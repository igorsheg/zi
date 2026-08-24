// Layout-independent slash picker state, adapted from fx's picker_state.zig.
const std = @import("std");
const interactive = @import("../../coding_agent/root.zig").interactive;
const LineEditor = @import("LineEditor.zig");

const SlashMenu = @This();

selected_index: usize = 0,
window_start: usize = 0,
dismissed: bool = false,

pub const Projection = struct {
    prefix: []const u8,
    selected_index: usize,
    window_start: usize,
    count: usize,
};

pub fn projection(self: *const SlashMenu, editor: *const LineEditor) ?Projection {
    if (self.dismissed) return null;
    const prefix = interactive.slashCommandCompletionPrefix(editor.text(), editor.cursorByte()) orelse return null;
    const count = interactive.slashCommandCompletionCount(prefix);
    return .{
        .prefix = prefix,
        .selected_index = if (count == 0) 0 else self.selected_index % count,
        .window_start = self.window_start,
        .count = count,
    };
}

/// Resets ranking after every edit and ends a dismissed episode only once the
/// composer no longer contains a leading slash-command token at the cursor.
pub fn reconcileAfterEdit(self: *SlashMenu, editor: *const LineEditor) void {
    self.selected_index = 0;
    self.window_start = 0;
    if (interactive.slashCommandCompletionPrefix(editor.text(), editor.cursorByte()) == null) {
        self.dismissed = false;
    }
}

pub fn dismiss(self: *SlashMenu, editor: *const LineEditor) bool {
    if (self.projection(editor) == null) return false;
    self.dismissed = true;
    self.selected_index = 0;
    self.window_start = 0;
    return true;
}

pub fn move(self: *SlashMenu, editor: *const LineEditor, delta: i32) bool {
    const view = self.projection(editor) orelse return false;
    if (view.count == 0) return false;
    const current: i32 = @intCast(view.selected_index);
    const count: i32 = @intCast(view.count);
    var next = current + delta;
    if (next < 0) next = count - 1;
    if (next >= count) next = 0;
    self.selected_index = @intCast(next);
    return true;
}

pub fn complete(self: *SlashMenu, editor: *LineEditor) LineEditor.Error!bool {
    const view = self.projection(editor) orelse return false;
    const spec = interactive.slashCommandCompletionAt(view.prefix, view.selected_index) orelse return false;
    const token_start = editor.cursorByte() - view.prefix.len;
    try editor.replaceRangeWithSuffix(
        token_start,
        editor.cursorByte(),
        spec.command,
        if (spec.requires_args) " " else "",
    );
    self.reconcileAfterEdit(editor);
    return true;
}

test "slash menu triggers after whitespace and resets selection after edits" {
    var editor = LineEditor.init(std.testing.allocator, 64);
    defer editor.deinit();
    var menu: SlashMenu = .{};
    try editor.replace("  /");
    try std.testing.expectEqual(@as(usize, 3), menu.projection(&editor).?.count);
    try std.testing.expect(menu.move(&editor, 1));
    try std.testing.expectEqual(@as(usize, 1), menu.projection(&editor).?.selected_index);
    try editor.insertByte('m');
    menu.reconcileAfterEdit(&editor);
    try std.testing.expectEqual(@as(usize, 0), menu.projection(&editor).?.selected_index);
    try std.testing.expectEqualStrings("/model", interactive.slashCommandCompletionAt("/m", 0).?.command);
}

test "slash menu navigation wraps and completion edits instead of submitting" {
    var editor = LineEditor.init(std.testing.allocator, 64);
    defer editor.deinit();
    var menu: SlashMenu = .{};
    try editor.replace("/");
    try std.testing.expect(menu.move(&editor, -1));
    try std.testing.expectEqual(@as(usize, 2), menu.projection(&editor).?.selected_index);
    try std.testing.expect(try menu.complete(&editor));
    try std.testing.expectEqualStrings("/thinking ", editor.text());
    try std.testing.expect(menu.projection(&editor) == null);
}

test "slash completion preserves leading whitespace and trailing text transactionally" {
    var editor = LineEditor.init(std.testing.allocator, 64);
    defer editor.deinit();
    var menu: SlashMenu = .{};
    try editor.replace("  /mo tail");
    editor.moveHome();
    for (0..5) |_| editor.moveRight();
    try std.testing.expect(try menu.complete(&editor));
    try std.testing.expectEqualStrings("  /model  tail", editor.text());

    var bounded = LineEditor.init(std.testing.allocator, 6);
    defer bounded.deinit();
    try bounded.replace("/model");
    try std.testing.expectError(error.InputTooLarge, menu.complete(&bounded));
    try std.testing.expectEqualStrings("/model", bounded.text());
}

test "slash menu dismissal lasts until the trigger episode ends" {
    var editor = LineEditor.init(std.testing.allocator, 64);
    defer editor.deinit();
    var menu: SlashMenu = .{};
    try editor.replace("/");
    try std.testing.expect(menu.dismiss(&editor));
    try editor.insertByte('m');
    menu.reconcileAfterEdit(&editor);
    try std.testing.expect(menu.projection(&editor) == null);
    editor.clear();
    menu.reconcileAfterEdit(&editor);
    try editor.replace("/");
    menu.reconcileAfterEdit(&editor);
    try std.testing.expect(menu.projection(&editor) != null);
}
