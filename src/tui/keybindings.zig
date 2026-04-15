const std = @import("std");
const keys_mod = @import("keys.zig");

const Key = keys_mod.Key;

pub const Action = enum {
    input_submit,
    input_new_line,
    input_tab,
    editor_undo,
    editor_backspace,
    editor_delete,
    editor_move_left,
    editor_move_right,
    editor_move_up,
    editor_move_down,
    editor_move_home,
    editor_move_end,
    select_up,
    select_down,
    select_page_up,
    select_page_down,
    select_home,
    select_end,
    select_confirm,
    select_cancel,
    app_interrupt,
    app_clear,
    app_exit,
    app_toggle_tools,
    app_toggle_thinking,
    app_queue_follow_up,
    app_restore_queued,
    app_scroll_page_up,
    app_scroll_page_down,
    app_scroll_line_up,
    app_scroll_line_down,
};

pub const Section = enum {
    editor,
    picker,
    app,
};

pub const KeySpec = struct {
    key: Key,
    display: []const u8,
};

pub const Definition = struct {
    action: Action,
    section: Section,
    description: []const u8,
    bindings: []const KeySpec,
    footer_label: ?[]const u8 = null,
    show_in_help: bool = true,
};

pub const EditorCommand = union(enum) {
    unhandled,
    action: Action,
    insert_codepoint: u21,
};

const key_enter = KeySpec{ .key = .{ .code = .enter }, .display = "enter" };
const key_shift_enter = KeySpec{ .key = .{ .code = .enter, .shift = true }, .display = "shift+enter" };
const key_tab = KeySpec{ .key = .{ .code = .tab }, .display = "tab" };
const key_backspace = KeySpec{ .key = .{ .code = .backspace }, .display = "backspace" };
const key_delete = KeySpec{ .key = .{ .code = .delete }, .display = "delete" };
const key_left = KeySpec{ .key = .{ .code = .left }, .display = "left" };
const key_right = KeySpec{ .key = .{ .code = .right }, .display = "right" };
const key_ctrl_dash = KeySpec{ .key = .{ .code = .char, .char = '-', .ctrl = true }, .display = "ctrl+-" };
const key_up = KeySpec{ .key = .{ .code = .up }, .display = "up" };
const key_down = KeySpec{ .key = .{ .code = .down }, .display = "down" };
const key_escape = KeySpec{ .key = .{ .code = .escape }, .display = "esc" };
const key_ctrl_c = KeySpec{ .key = .{ .code = .char, .char = 'c', .ctrl = true }, .display = "ctrl+c" };
const key_ctrl_d = KeySpec{ .key = .{ .code = .char, .char = 'd', .ctrl = true }, .display = "ctrl+d" };
const key_ctrl_o = KeySpec{ .key = .{ .code = .char, .char = 'o', .ctrl = true }, .display = "ctrl+o" };
const key_ctrl_t = KeySpec{ .key = .{ .code = .char, .char = 't', .ctrl = true }, .display = "ctrl+t" };
const key_alt_enter = KeySpec{ .key = .{ .code = .enter, .alt = true }, .display = "alt+enter" };
const key_alt_up = KeySpec{ .key = .{ .code = .up, .alt = true }, .display = "alt+up" };
const key_page_up = KeySpec{ .key = .{ .code = .page_up }, .display = "page up" };
const key_page_down = KeySpec{ .key = .{ .code = .page_down }, .display = "page down" };
const key_home = KeySpec{ .key = .{ .code = .home }, .display = "home" };
const key_end = KeySpec{ .key = .{ .code = .end }, .display = "end" };
const key_shift_up = KeySpec{ .key = .{ .code = .up, .shift = true }, .display = "shift+up" };
const key_shift_down = KeySpec{ .key = .{ .code = .down, .shift = true }, .display = "shift+down" };

const input_submit_bindings = [_]KeySpec{key_enter};
const input_new_line_bindings = [_]KeySpec{key_shift_enter};
const input_tab_bindings = [_]KeySpec{key_tab};
const editor_undo_bindings = [_]KeySpec{key_ctrl_dash};
const editor_backspace_bindings = [_]KeySpec{key_backspace};
const editor_delete_bindings = [_]KeySpec{key_delete};
const editor_move_left_bindings = [_]KeySpec{key_left};
const editor_move_right_bindings = [_]KeySpec{key_right};
const editor_move_up_bindings = [_]KeySpec{key_up};
const editor_move_down_bindings = [_]KeySpec{key_down};
const editor_move_home_bindings = [_]KeySpec{key_home};
const editor_move_end_bindings = [_]KeySpec{key_end};
const select_up_bindings = [_]KeySpec{key_up};
const select_down_bindings = [_]KeySpec{key_down};
const select_page_up_bindings = [_]KeySpec{key_page_up};
const select_page_down_bindings = [_]KeySpec{key_page_down};
const select_home_bindings = [_]KeySpec{key_home};
const select_end_bindings = [_]KeySpec{key_end};
const select_confirm_bindings = [_]KeySpec{key_enter};
const select_cancel_bindings = [_]KeySpec{ key_escape, key_ctrl_c };
const app_interrupt_bindings = [_]KeySpec{key_escape};
const app_clear_bindings = [_]KeySpec{key_ctrl_c};
const app_exit_bindings = [_]KeySpec{key_ctrl_d};
const app_toggle_tools_bindings = [_]KeySpec{key_ctrl_o};
const app_toggle_thinking_bindings = [_]KeySpec{key_ctrl_t};
const app_queue_follow_up_bindings = [_]KeySpec{key_alt_enter};
const app_restore_queued_bindings = [_]KeySpec{key_alt_up};
const app_scroll_page_up_bindings = [_]KeySpec{key_page_up};
const app_scroll_page_down_bindings = [_]KeySpec{key_page_down};
const app_scroll_line_up_bindings = [_]KeySpec{key_shift_up};
const app_scroll_line_down_bindings = [_]KeySpec{key_shift_down};

const definitions = [_]Definition{
    .{
        .action = .input_submit,
        .section = .editor,
        .description = "Submit input",
        .bindings = &input_submit_bindings,
    },
    .{
        .action = .input_new_line,
        .section = .editor,
        .description = "Insert newline",
        .bindings = &input_new_line_bindings,
    },
    .{
        .action = .input_tab,
        .section = .editor,
        .description = "Accept autocomplete / tab completion",
        .bindings = &input_tab_bindings,
    },
    .{
        .action = .editor_undo,
        .section = .editor,
        .description = "Undo",
        .bindings = &editor_undo_bindings,
    },
    .{
        .action = .editor_backspace,
        .section = .editor,
        .description = "Delete backward",
        .bindings = &editor_backspace_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_delete,
        .section = .editor,
        .description = "Delete forward",
        .bindings = &editor_delete_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_left,
        .section = .editor,
        .description = "Move cursor left",
        .bindings = &editor_move_left_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_right,
        .section = .editor,
        .description = "Move cursor right",
        .bindings = &editor_move_right_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_up,
        .section = .editor,
        .description = "Move cursor up / previous history entry",
        .bindings = &editor_move_up_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_down,
        .section = .editor,
        .description = "Move cursor down / next history entry",
        .bindings = &editor_move_down_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_home,
        .section = .editor,
        .description = "Move to line start",
        .bindings = &editor_move_home_bindings,
        .show_in_help = false,
    },
    .{
        .action = .editor_move_end,
        .section = .editor,
        .description = "Move to line end",
        .bindings = &editor_move_end_bindings,
        .show_in_help = false,
    },
    .{
        .action = .select_up,
        .section = .picker,
        .description = "Move selection up",
        .bindings = &select_up_bindings,
    },
    .{
        .action = .select_down,
        .section = .picker,
        .description = "Move selection down",
        .bindings = &select_down_bindings,
    },
    .{
        .action = .select_page_up,
        .section = .picker,
        .description = "Move selection up by page",
        .bindings = &select_page_up_bindings,
    },
    .{
        .action = .select_page_down,
        .section = .picker,
        .description = "Move selection down by page",
        .bindings = &select_page_down_bindings,
    },
    .{
        .action = .select_home,
        .section = .picker,
        .description = "Move selection to first item",
        .bindings = &select_home_bindings,
    },
    .{
        .action = .select_end,
        .section = .picker,
        .description = "Move selection to last item",
        .bindings = &select_end_bindings,
    },
    .{
        .action = .select_confirm,
        .section = .picker,
        .description = "Confirm selection",
        .bindings = &select_confirm_bindings,
    },
    .{
        .action = .select_cancel,
        .section = .picker,
        .description = "Cancel picker / dismiss overlay",
        .bindings = &select_cancel_bindings,
    },
    .{
        .action = .app_interrupt,
        .section = .app,
        .description = "Abort streaming / stop retry wait",
        .bindings = &app_interrupt_bindings,
        .footer_label = "abort",
    },
    .{
        .action = .app_clear,
        .section = .app,
        .description = "Clear editor / exit on double tap",
        .bindings = &app_clear_bindings,
        .footer_label = "clear/quit",
    },
    .{
        .action = .app_exit,
        .section = .app,
        .description = "Exit when editor is empty",
        .bindings = &app_exit_bindings,
    },
    .{
        .action = .app_toggle_tools,
        .section = .app,
        .description = "Toggle tool output expansion",
        .bindings = &app_toggle_tools_bindings,
        .footer_label = "tools",
    },
    .{
        .action = .app_toggle_thinking,
        .section = .app,
        .description = "Toggle thinking block visibility",
        .bindings = &app_toggle_thinking_bindings,
        .footer_label = "thinking",
    },
    .{
        .action = .app_queue_follow_up,
        .section = .app,
        .description = "Queue follow-up message",
        .bindings = &app_queue_follow_up_bindings,
    },
    .{
        .action = .app_restore_queued,
        .section = .app,
        .description = "Restore queued messages to editor",
        .bindings = &app_restore_queued_bindings,
    },
    .{
        .action = .app_scroll_page_up,
        .section = .app,
        .description = "Scroll transcript up by page",
        .bindings = &app_scroll_page_up_bindings,
    },
    .{
        .action = .app_scroll_page_down,
        .section = .app,
        .description = "Scroll transcript down by page",
        .bindings = &app_scroll_page_down_bindings,
    },
    .{
        .action = .app_scroll_line_up,
        .section = .app,
        .description = "Scroll transcript up",
        .bindings = &app_scroll_line_up_bindings,
    },
    .{
        .action = .app_scroll_line_down,
        .section = .app,
        .description = "Scroll transcript down",
        .bindings = &app_scroll_line_down_bindings,
    },
};

pub fn all() []const Definition {
    return &definitions;
}

pub fn definition(action: Action) *const Definition {
    for (&definitions) |*def| {
        if (def.action == action) return def;
    }
    unreachable;
}

pub fn matches(action: Action, key: Key) bool {
    for (definition(action).bindings) |binding| {
        if (Key.eql(binding.key, key)) return true;
    }
    return false;
}

pub fn resolveEditorCommand(key: Key) EditorCommand {
    if (matches(.editor_undo, key)) return .{ .action = .editor_undo };
    if (matches(.input_new_line, key)) return .{ .action = .input_new_line };
    if (matches(.input_submit, key)) return .{ .action = .input_submit };

    switch (key.code) {
        .backspace => return .{ .action = .editor_backspace },
        .delete => return .{ .action = .editor_delete },
        .left => return .{ .action = .editor_move_left },
        .right => return .{ .action = .editor_move_right },
        .up => return .{ .action = .editor_move_up },
        .down => return .{ .action = .editor_move_down },
        .home => return .{ .action = .editor_move_home },
        .end => return .{ .action = .editor_move_end },
        .char => {
            if (key.ctrl) return .unhandled;
            if (key.char) |cp| return .{ .insert_codepoint = cp };
            return .unhandled;
        },
        else => return .unhandled,
    }
}

pub fn isEditorAutocompleteAccept(key: Key) bool {
    return matches(.input_tab, key) or matches(.select_confirm, key);
}

pub fn formatBindings(action: Action, separator: []const u8, buf: []u8) []const u8 {
    var pos: usize = 0;
    for (definition(action).bindings, 0..) |binding, idx| {
        if (idx > 0) append(buf, &pos, separator);
        append(buf, &pos, binding.display);
    }
    return buf[0..pos];
}

pub fn formatFooter(buf: []u8) []const u8 {
    var pos: usize = 0;
    var first = true;
    for (definitions) |def| {
        const label = def.footer_label orelse continue;
        if (!first) append(buf, &pos, " · ");
        var binding_buf: [32]u8 = undefined;
        append(buf, &pos, formatBindings(def.action, " / ", &binding_buf));
        append(buf, &pos, " ");
        append(buf, &pos, label);
        first = false;
    }
    return buf[0..pos];
}

pub fn sectionTitle(section: Section) []const u8 {
    return switch (section) {
        .editor => "Editor",
        .picker => "Picker",
        .app => "App",
    };
}

fn append(buf: []u8, pos: *usize, text: []const u8) void {
    if (pos.* >= buf.len) return;
    const copy_len = @min(buf.len - pos.*, text.len);
    @memcpy(buf[pos.*..][0..copy_len], text[0..copy_len]);
    pos.* += copy_len;
}

const testing = std.testing;

test "keybindings match defaults across editor picker and app actions" {
    try testing.expect(matches(.input_submit, .{ .code = .enter }));
    try testing.expect(matches(.input_new_line, .{ .code = .enter, .shift = true }));
    try testing.expect(matches(.editor_undo, .{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expect(matches(.editor_backspace, .{ .code = .backspace }));
    try testing.expect(matches(.editor_move_left, .{ .code = .left }));
    try testing.expect(matches(.select_page_down, .{ .code = .page_down }));
    try testing.expect(matches(.select_end, .{ .code = .end }));
    try testing.expect(matches(.select_cancel, .{ .code = .char, .char = 'c', .ctrl = true }));
    try testing.expect(matches(.app_toggle_tools, .{ .code = .char, .char = 'o', .ctrl = true }));
    try testing.expect(matches(.app_queue_follow_up, .{ .code = .enter, .alt = true }));
    try testing.expect(matches(.app_restore_queued, .{ .code = .up, .alt = true }));
    try testing.expect(!matches(.app_toggle_tools, .{ .code = .char, .char = 'o' }));
}

test "keybindings resolve editor commands with current editor semantics" {
    try testing.expectEqual(EditorCommand{ .action = .input_submit }, resolveEditorCommand(.{ .code = .enter }));
    try testing.expectEqual(EditorCommand{ .action = .input_new_line }, resolveEditorCommand(.{ .code = .enter, .shift = true }));
    try testing.expectEqual(EditorCommand{ .action = .editor_move_left }, resolveEditorCommand(.{ .code = .left, .ctrl = true }));
    try testing.expectEqual(EditorCommand{ .action = .editor_backspace }, resolveEditorCommand(.{ .code = .backspace, .alt = true }));
    try testing.expectEqual(EditorCommand{ .insert_codepoint = 'x' }, resolveEditorCommand(.{ .code = .char, .char = 'x', .alt = true }));
    try testing.expectEqual(EditorCommand.unhandled, resolveEditorCommand(.{ .code = .char, .char = 'x', .ctrl = true }));
    try testing.expect(isEditorAutocompleteAccept(.{ .code = .tab }));
    try testing.expect(isEditorAutocompleteAccept(.{ .code = .enter }));
    try testing.expect(!isEditorAutocompleteAccept(.{ .code = .enter, .shift = true }));
}

test "keybindings format footer from shared definitions" {
    var buf: [128]u8 = undefined;
    const text = formatFooter(&buf);
    try testing.expectEqualStrings(
        "esc abort · ctrl+c clear/quit · ctrl+o tools · ctrl+t thinking",
        text,
    );
}

test "keybindings format multi-binding action for help views" {
    var buf: [32]u8 = undefined;
    const text = formatBindings(.select_cancel, " / ", &buf);
    try testing.expectEqualStrings("esc / ctrl+c", text);
}
