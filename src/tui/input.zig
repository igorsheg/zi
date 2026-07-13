const std = @import("std");
const vaxis = @import("vaxis");

pub const EditorOp = enum {
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    move_up,
    move_down,
    backspace,
    delete_forward,
    home,
    end,
    clear,
    kill_to_end,
    kill_to_start,
    kill_word_back,
    yank,
    undo,
    tab,
};

pub const Action = union(enum) {
    insert: []const u8,
    paste: []const u8,
    paste_begin,
    paste_chunk: []const u8,
    paste_end,
    key_editor: EditorOp,
    submit,
    newline,
    steer_submit,
    follow_up_submit,
    cancel,
    clear_or_quit,
    quit_eof,
    expand_toggle,
    dequeue_all,
    paste_image,
    scroll: i32,
    page_up,
    page_down,
    force_redraw,
    none,
};

pub fn fromKey(key: vaxis.Key) Action {
    if (key.matches(vaxis.Key.escape, .{})) return .cancel;
    if (key.matches(vaxis.Key.enter, .{ .alt = true }) or key.matches(vaxis.Key.kp_enter, .{ .alt = true })) return .follow_up_submit;
    if (key.matches(vaxis.Key.enter, .{ .shift = true }) or key.matches(vaxis.Key.kp_enter, .{ .shift = true })) return .newline;
    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.kp_enter, .{})) return .submit;
    if (key.matches(vaxis.Key.tab, .{})) return .{ .key_editor = .tab };
    if (key.matches(vaxis.Key.backspace, .{})) return .{ .key_editor = .backspace };
    if (key.matches(vaxis.Key.delete, .{})) return .{ .key_editor = .delete_forward };
    if (key.matches(vaxis.Key.left, .{ .alt = true })) return .{ .key_editor = .move_word_left };
    if (key.matches(vaxis.Key.right, .{ .alt = true })) return .{ .key_editor = .move_word_right };
    if (key.matches(vaxis.Key.left, .{})) return .{ .key_editor = .move_left };
    if (key.matches(vaxis.Key.right, .{})) return .{ .key_editor = .move_right };
    if (key.matches(vaxis.Key.up, .{})) return .{ .key_editor = .move_up };
    if (key.matches(vaxis.Key.down, .{})) return .{ .key_editor = .move_down };
    if (key.matches(vaxis.Key.home, .{})) return .{ .key_editor = .home };
    if (key.matches(vaxis.Key.end, .{})) return .{ .key_editor = .end };
    if (key.matches(vaxis.Key.page_up, .{})) return .page_up;
    if (key.matches(vaxis.Key.page_down, .{})) return .page_down;

    if (key.codepoint == 0x03) return .clear_or_quit;
    if (key.codepoint == 0x09) return .{ .key_editor = .tab };
    if (key.codepoint == 0x04) return .quit_eof;
    if (key.codepoint == 0x15) return .{ .key_editor = .kill_to_start };
    if (key.codepoint == 0x0b) return .{ .key_editor = .kill_to_end };
    if (key.codepoint == 0x17) return .{ .key_editor = .kill_word_back };
    if (key.codepoint == 0x19) return .{ .key_editor = .yank };
    if (key.codepoint == 0x1f) return .{ .key_editor = .undo };
    if (key.matches('c', .{ .ctrl = true })) return .clear_or_quit;
    if (key.matches('d', .{ .ctrl = true })) return .quit_eof;
    if (key.matches('a', .{ .ctrl = true })) return .{ .key_editor = .home };
    if (key.matches('e', .{ .ctrl = true })) return .{ .key_editor = .end };
    if (key.matches('u', .{ .ctrl = true })) return .{ .key_editor = .kill_to_start };
    if (key.matches('k', .{ .ctrl = true })) return .{ .key_editor = .kill_to_end };
    if (key.matches('w', .{ .ctrl = true })) return .{ .key_editor = .kill_word_back };
    if (key.matches('y', .{ .ctrl = true })) return .{ .key_editor = .yank };
    if (key.matches('z', .{ .ctrl = true })) return .{ .key_editor = .undo };
    if (key.matches('b', .{ .alt = true })) return .{ .key_editor = .move_word_left };
    if (key.matches('f', .{ .alt = true })) return .{ .key_editor = .move_word_right };
    if (key.matches('o', .{ .ctrl = true })) return .expand_toggle;
    if (key.matches('q', .{ .alt = true })) return .dequeue_all;
    if (key.matches('v', .{ .alt = true })) return .paste_image;
    if (key.matches('l', .{ .ctrl = true })) return .force_redraw;

    if (key.text) |text| {
        if (isPrintableText(key, text)) return .{ .insert = text };
    }
    return .none;
}

pub fn fromMouse(mouse: vaxis.Mouse) Action {
    if (mouse.type != .press) return .none;
    return switch (mouse.button) {
        .wheel_up => .{ .scroll = -3 },
        .wheel_down => .{ .scroll = 3 },
        else => .none,
    };
}

fn isPrintableText(key: vaxis.Key, text: []const u8) bool {
    if (text.len == 0) return false;
    if (key.mods.ctrl or key.mods.alt or key.mods.super or key.mods.hyper or key.mods.meta) return false;
    for (text) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
    }
    return std.unicode.utf8ValidateSlice(text);
}

test "action carries inserted text" {
    const action: Action = .{ .insert = "hello" };
    try std.testing.expectEqualStrings("hello", action.insert);
}

test "key mapping handles editor/navigation/control keys" {
    try std.testing.expect(fromKey(.{ .codepoint = vaxis.Key.left }) == .key_editor);
    try std.testing.expectEqual(EditorOp.move_left, fromKey(.{ .codepoint = vaxis.Key.left }).key_editor);
    try std.testing.expectEqual(EditorOp.backspace, fromKey(.{ .codepoint = vaxis.Key.backspace }).key_editor);
    try std.testing.expect(fromKey(.{ .codepoint = vaxis.Key.enter }) == .submit);
    try std.testing.expect(fromKey(.{ .codepoint = 'c', .mods = .{ .ctrl = true } }) == .clear_or_quit);
    try std.testing.expect(fromKey(.{ .codepoint = 'd', .mods = .{ .ctrl = true } }) == .quit_eof);
}

test "key mapping handles P2 editor bindings" {
    try std.testing.expectEqual(EditorOp.kill_to_end, fromKey(.{ .codepoint = 'k', .mods = .{ .ctrl = true } }).key_editor);
    try std.testing.expectEqual(EditorOp.kill_word_back, fromKey(.{ .codepoint = 'w', .mods = .{ .ctrl = true } }).key_editor);
    try std.testing.expectEqual(EditorOp.yank, fromKey(.{ .codepoint = 'y', .mods = .{ .ctrl = true } }).key_editor);
    try std.testing.expectEqual(EditorOp.undo, fromKey(.{ .codepoint = 0x1f }).key_editor);
    try std.testing.expectEqual(EditorOp.move_word_left, fromKey(.{ .codepoint = 'b', .mods = .{ .alt = true } }).key_editor);
}

test "key mapping handles chrome bindings" {
    try std.testing.expect(fromKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .alt = true } }) == .follow_up_submit);
    try std.testing.expect(fromKey(.{ .codepoint = vaxis.Key.enter, .mods = .{ .shift = true } }) == .newline);
    try std.testing.expect(fromKey(.{ .codepoint = 'o', .mods = .{ .ctrl = true } }) == .expand_toggle);
    try std.testing.expect(fromKey(.{ .codepoint = 'q', .mods = .{ .alt = true } }) == .dequeue_all);
    try std.testing.expect(fromKey(.{ .codepoint = 'v', .mods = .{ .alt = true } }) == .paste_image);
    try std.testing.expect(fromKey(.{ .codepoint = 'l', .mods = .{ .ctrl = true } }) == .force_redraw);
}

test "key mapping inserts printable text only" {
    const insert = fromKey(.{ .codepoint = 'é', .text = "é" });
    try std.testing.expect(insert == .insert);
    try std.testing.expectEqualStrings("é", insert.insert);
    try std.testing.expect(fromKey(.{ .codepoint = 'x', .text = "x", .mods = .{ .alt = true } }) == .none);
}

test "mouse mapping handles wheel and drops other mouse events" {
    try std.testing.expectEqual(@as(i32, -3), fromMouse(.{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    }).scroll);
    try std.testing.expectEqual(@as(i32, 3), fromMouse(.{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    }).scroll);
    try std.testing.expect(fromMouse(.{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    }) == .none);
    try std.testing.expect(fromMouse(.{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .release,
    }) == .none);
}
