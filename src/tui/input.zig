//! Input vocabulary and keymap. `fromVaxis` reduces vaxis events to the
//! small product vocabulary; `resolve` maps that vocabulary to key actions.
//! Both are pure: paste-mode and modal decisions belong to App.
const std = @import("std");
const vaxis = @import("vaxis");
const text_mod = @import("text.zig");

pub const inline_text_bytes_max: usize = 64;

/// Inline copy of one key event's text. A single key's text is tiny;
/// large pasted runs arrive as many events between paste_begin/paste_end.
pub const InlineBytes = struct {
    len: u8 = 0,
    bytes: [inline_text_bytes_max]u8 = undefined,

    pub fn from(data: []const u8) InlineBytes {
        var value: InlineBytes = .{};
        const prefix = if (std.unicode.utf8ValidateSlice(data))
            text_mod.utf8Prefix(data, value.bytes.len)
        else
            data[0..@min(data.len, value.bytes.len)];
        @memcpy(value.bytes[0..prefix.len], prefix);
        value.len = @intCast(prefix.len);
        return value;
    }

    pub fn slice(self: *const InlineBytes) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const Key = enum {
    escape,
    enter,
    newline, // alt+enter / ctrl+j: insert a line break instead of submitting
    tab,
    backspace,
    delete,
    arrow_left,
    arrow_right,
    arrow_up,
    arrow_down,
    home,
    end,
    ctrl_end,
    page_up,
    page_down,
    ctrl_c,
    ctrl_d,
    ctrl_g,
    ctrl_o,
    ctrl_u,
};

pub const Input = union(enum) {
    key: Key,
    text: InlineBytes,
    paste_begin,
    paste_end,
    wheel_up,
    wheel_down,
    focus_in,
    focus_out,
    ignored,
};

pub fn fromVaxis(event: vaxis.Event) Input {
    return switch (event) {
        .key_press => |key| fromVaxisKey(key),
        .paste_start => .paste_begin,
        .paste_end => .paste_end,
        .mouse => |mouse| fromVaxisMouse(mouse),
        .focus_in => .focus_in,
        .focus_out => .focus_out,
        else => .ignored,
    };
}

fn fromVaxisMouse(mouse: vaxis.Mouse) Input {
    if (mouse.type != .press) return .ignored;
    return switch (mouse.button) {
        .wheel_up => .wheel_up,
        .wheel_down => .wheel_down,
        else => .ignored,
    };
}

fn fromVaxisKey(key: vaxis.Key) Input {
    // Modified matches must run before their unmodified forms.
    if (key.matches(vaxis.Key.enter, .{ .alt = true })) return .{ .key = .newline };
    if (key.matches('j', .{ .ctrl = true })) return .{ .key = .newline };
    if (key.matches(vaxis.Key.escape, .{})) return .{ .key = .escape };
    if (key.matches(vaxis.Key.enter, .{})) return .{ .key = .enter };
    if (key.matches(vaxis.Key.kp_enter, .{})) return .{ .key = .enter };
    if (key.matches(vaxis.Key.tab, .{})) return .{ .key = .tab };
    if (key.matches(vaxis.Key.backspace, .{})) return .{ .key = .backspace };
    if (key.matches(vaxis.Key.delete, .{})) return .{ .key = .delete };
    if (key.matches(vaxis.Key.left, .{})) return .{ .key = .arrow_left };
    if (key.matches(vaxis.Key.right, .{})) return .{ .key = .arrow_right };
    if (key.matches(vaxis.Key.up, .{})) return .{ .key = .arrow_up };
    if (key.matches(vaxis.Key.down, .{})) return .{ .key = .arrow_down };
    if (key.matches(vaxis.Key.home, .{})) return .{ .key = .home };
    if (key.matches(vaxis.Key.end, .{ .ctrl = true })) return .{ .key = .ctrl_end };
    if (key.matches(vaxis.Key.end, .{})) return .{ .key = .end };
    if (key.matches(vaxis.Key.page_up, .{})) return .{ .key = .page_up };
    if (key.matches(vaxis.Key.page_down, .{})) return .{ .key = .page_down };
    if (key.matches('c', .{ .ctrl = true })) return .{ .key = .ctrl_c };
    if (key.matches('d', .{ .ctrl = true })) return .{ .key = .ctrl_d };
    if (key.matches('g', .{ .ctrl = true })) return .{ .key = .ctrl_g };
    if (key.matches('o', .{ .ctrl = true })) return .{ .key = .ctrl_o };
    if (key.matches('u', .{ .ctrl = true })) return .{ .key = .ctrl_u };
    if (key.text) |text| {
        const plain_text = !key.mods.ctrl and !key.mods.alt;
        const alt_gr_text = key.mods.ctrl and key.mods.alt;
        if (text.len > 0 and !key.mods.super and (plain_text or alt_gr_text)) {
            return .{ .text = InlineBytes.from(text) };
        }
    }
    return .ignored;
}

pub const KeyAction = union(enum) {
    composer_insert: InlineBytes,
    composer_newline,
    composer_backspace,
    composer_delete_forward,
    composer_left,
    composer_right,
    composer_up,
    composer_down,
    composer_start,
    composer_end,
    composer_submit,
    transcript_page_up,
    transcript_page_down,
    transcript_scroll_up,
    transcript_scroll_down,
    transcript_follow_tail,
    toggle_tool_expansion,
    interrupt,
    clear_or_exit,
    exit_if_composer_empty,
    open_external_editor,
    none,
};

pub fn resolve(event: Input) KeyAction {
    return switch (event) {
        .text => |bytes| .{ .composer_insert = bytes },
        .key => |key| resolveKey(key),
        .wheel_up => .transcript_scroll_up,
        .wheel_down => .transcript_scroll_down,
        else => .none,
    };
}

fn resolveKey(key: Key) KeyAction {
    return switch (key) {
        .backspace => .composer_backspace,
        .delete => .composer_delete_forward,
        .arrow_left => .composer_left,
        .arrow_right => .composer_right,
        .arrow_up => .composer_up,
        .arrow_down => .composer_down,
        .home => .composer_start,
        .end => .composer_end,
        .enter => .composer_submit,
        .newline => .composer_newline,
        .page_up => .transcript_page_up,
        .page_down => .transcript_page_down,
        .ctrl_end => .transcript_follow_tail,
        .escape => .interrupt,
        .ctrl_c => .clear_or_exit,
        .ctrl_g => .open_external_editor,
        .ctrl_o => .toggle_tool_expansion,
        .ctrl_u => .transcript_page_up,
        .ctrl_d => .exit_if_composer_empty,
        // No completion UI yet; mapped explicitly so the gap is a decision,
        // not an accident.
        .tab => .none,
    };
}

fn parseInput(bytes: []const u8) !Input {
    var parser: vaxis.Parser = .{};
    const parsed = try parser.parse(bytes, null);
    try std.testing.expectEqual(bytes.len, parsed.n);
    return fromVaxis(parsed.event.?);
}

test "raw parser bytes map paste markers and mouse wheel" {
    try std.testing.expectEqual(Input.paste_begin, try parseInput("\x1b[200~"));
    try std.testing.expectEqual(Input.paste_end, try parseInput("\x1b[201~"));
    try std.testing.expectEqual(Input.wheel_up, try parseInput("\x1b[<64;10;5M"));
    try std.testing.expectEqual(Input.wheel_down, try parseInput("\x1b[<65;10;5M"));
}

test "fromVaxis maps only mouse wheel presses" {
    try std.testing.expectEqual(Input.wheel_up, fromVaxis(.{ .mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_up,
        .mods = .{},
        .type = .press,
    } }));
    try std.testing.expectEqual(Input.wheel_down, fromVaxis(.{ .mouse = .{
        .col = 0,
        .row = 0,
        .button = .wheel_down,
        .mods = .{},
        .type = .press,
    } }));
    try std.testing.expectEqual(Input.ignored, fromVaxis(.{ .mouse = .{
        .col = 0,
        .row = 0,
        .button = .left,
        .mods = .{},
        .type = .press,
    } }));
}

test "resolve maps editing keys" {
    try std.testing.expectEqual(KeyAction.composer_delete_forward, resolve(.{ .key = .delete }));
    try std.testing.expectEqual(KeyAction.composer_up, resolve(.{ .key = .arrow_up }));
    try std.testing.expectEqual(KeyAction.composer_down, resolve(.{ .key = .arrow_down }));
    try std.testing.expectEqual(KeyAction.transcript_scroll_up, resolve(.wheel_up));
    try std.testing.expectEqual(KeyAction.transcript_scroll_down, resolve(.wheel_down));
    try std.testing.expectEqual(KeyAction.transcript_follow_tail, resolve(.{ .key = .ctrl_end }));
    try std.testing.expectEqual(KeyAction.composer_newline, resolve(.{ .key = .newline }));
    try std.testing.expectEqual(KeyAction.composer_submit, resolve(.{ .key = .enter }));
    try std.testing.expectEqual(KeyAction.open_external_editor, resolve(.{ .key = .ctrl_g }));
}

test "ctrl alt printable text passes through for AltGr" {
    const input = fromVaxis(.{ .key_press = .{
        .codepoint = '@',
        .text = "@",
        .mods = .{ .ctrl = true, .alt = true },
    } });
    try std.testing.expect(input == .text);
    try std.testing.expectEqualStrings("@", input.text.slice());
}

test "inline text truncates on utf8 boundaries" {
    const bytes = InlineBytes.from("x" ** inline_text_bytes_max ++ "é");
    try std.testing.expectEqual(@as(usize, inline_text_bytes_max), bytes.slice().len);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bytes.slice()));
}
