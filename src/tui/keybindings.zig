const std = @import("std");
const keys_mod = @import("keys.zig");

const Key = keys_mod.Key;

pub const Action = enum {
    input_submit,
    input_new_line,
    input_tab,
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
};

const key_enter = KeySpec{ .key = .{ .code = .enter }, .display = "enter" };
const key_shift_enter = KeySpec{ .key = .{ .code = .enter, .shift = true }, .display = "shift+enter" };
const key_tab = KeySpec{ .key = .{ .code = .tab }, .display = "tab" };
const key_up = KeySpec{ .key = .{ .code = .up }, .display = "up" };
const key_down = KeySpec{ .key = .{ .code = .down }, .display = "down" };
const key_escape = KeySpec{ .key = .{ .code = .escape }, .display = "esc" };
const key_ctrl_c = KeySpec{ .key = .{ .code = .char, .char = 'c', .ctrl = true }, .display = "ctrl+c" };
const key_ctrl_d = KeySpec{ .key = .{ .code = .char, .char = 'd', .ctrl = true }, .display = "ctrl+d" };
const key_ctrl_o = KeySpec{ .key = .{ .code = .char, .char = 'o', .ctrl = true }, .display = "ctrl+o" };
const key_ctrl_t = KeySpec{ .key = .{ .code = .char, .char = 't', .ctrl = true }, .display = "ctrl+t" };
const key_page_up = KeySpec{ .key = .{ .code = .page_up }, .display = "page up" };
const key_page_down = KeySpec{ .key = .{ .code = .page_down }, .display = "page down" };
const key_home = KeySpec{ .key = .{ .code = .home }, .display = "home" };
const key_end = KeySpec{ .key = .{ .code = .end }, .display = "end" };
const key_shift_up = KeySpec{ .key = .{ .code = .up, .shift = true }, .display = "shift+up" };
const key_shift_down = KeySpec{ .key = .{ .code = .down, .shift = true }, .display = "shift+down" };

const input_submit_bindings = [_]KeySpec{key_enter};
const input_new_line_bindings = [_]KeySpec{key_shift_enter};
const input_tab_bindings = [_]KeySpec{key_tab};
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
    try testing.expect(matches(.select_page_down, .{ .code = .page_down }));
    try testing.expect(matches(.select_end, .{ .code = .end }));
    try testing.expect(matches(.select_cancel, .{ .code = .char, .char = 'c', .ctrl = true }));
    try testing.expect(matches(.app_toggle_tools, .{ .code = .char, .char = 'o', .ctrl = true }));
    try testing.expect(!matches(.app_toggle_tools, .{ .code = .char, .char = 'o' }));
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
