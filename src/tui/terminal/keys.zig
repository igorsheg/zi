const std = @import("std");

pub const KeyCode = enum {
    char,
    enter,
    escape,
    tab,
    backspace,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    delete,
    insert,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = struct {
    code: KeyCode,
    char: ?u21 = null,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,

    pub fn eql(a: Key, b: Key) bool {
        return a.code == b.code and a.char == b.char and
            a.ctrl == b.ctrl and a.alt == b.alt and a.shift == b.shift;
    }
};

pub const ParseResult = struct {
    key: Key,
    len: usize,
};

pub const KeySpecParseError = error{InvalidKeySpec};

pub fn parseKeySpec(text: []const u8) KeySpecParseError!Key {
    var key_text = text;
    var key: Key = .{ .code = .char };
    var it = std.mem.splitScalar(u8, text, '+');
    while (it.next()) |part_raw| {
        const part = std.mem.trim(u8, part_raw, " \t\r\n");
        if (part.len == 0) return error.InvalidKeySpec;
        if (std.ascii.eqlIgnoreCase(part, "ctrl") or std.ascii.eqlIgnoreCase(part, "control")) {
            key.ctrl = true;
        } else if (std.ascii.eqlIgnoreCase(part, "alt") or std.ascii.eqlIgnoreCase(part, "meta")) {
            key.alt = true;
        } else if (std.ascii.eqlIgnoreCase(part, "shift")) {
            key.shift = true;
        } else {
            key_text = part;
        }
    }

    if (std.ascii.eqlIgnoreCase(key_text, "enter") or std.ascii.eqlIgnoreCase(key_text, "return")) key.code = .enter else if (std.ascii.eqlIgnoreCase(key_text, "esc") or std.ascii.eqlIgnoreCase(key_text, "escape")) key.code = .escape else if (std.ascii.eqlIgnoreCase(key_text, "tab")) key.code = .tab else if (std.ascii.eqlIgnoreCase(key_text, "backspace") or std.ascii.eqlIgnoreCase(key_text, "bs")) key.code = .backspace else if (std.ascii.eqlIgnoreCase(key_text, "up")) key.code = .up else if (std.ascii.eqlIgnoreCase(key_text, "down")) key.code = .down else if (std.ascii.eqlIgnoreCase(key_text, "left")) key.code = .left else if (std.ascii.eqlIgnoreCase(key_text, "right")) key.code = .right else if (std.ascii.eqlIgnoreCase(key_text, "home")) key.code = .home else if (std.ascii.eqlIgnoreCase(key_text, "end")) key.code = .end else if (std.ascii.eqlIgnoreCase(key_text, "pageup") or std.ascii.eqlIgnoreCase(key_text, "page_up") or std.ascii.eqlIgnoreCase(key_text, "page up")) key.code = .page_up else if (std.ascii.eqlIgnoreCase(key_text, "pagedown") or std.ascii.eqlIgnoreCase(key_text, "page_down") or std.ascii.eqlIgnoreCase(key_text, "page down")) key.code = .page_down else if (std.ascii.eqlIgnoreCase(key_text, "delete") or std.ascii.eqlIgnoreCase(key_text, "del")) key.code = .delete else if (std.ascii.eqlIgnoreCase(key_text, "insert") or std.ascii.eqlIgnoreCase(key_text, "ins")) key.code = .insert else if (key_text.len >= 2 and (key_text[0] == 'f' or key_text[0] == 'F')) {
        const n = std.fmt.parseInt(u8, key_text[1..], 10) catch return error.InvalidKeySpec;
        key.code = switch (n) {
            1 => .f1,
            2 => .f2,
            3 => .f3,
            4 => .f4,
            5 => .f5,
            6 => .f6,
            7 => .f7,
            8 => .f8,
            9 => .f9,
            10 => .f10,
            11 => .f11,
            12 => .f12,
            else => return error.InvalidKeySpec,
        };
    } else if (key_text.len == 1) {
        key.code = .char;
        key.char = std.ascii.toLower(key_text[0]);
    } else return error.InvalidKeySpec;

    return key;
}

pub const MouseEventKind = enum {
    down,
    up,
    move,
    drag,
    scroll,
};

pub const MouseButton = enum {
    left,
    middle,
    right,
    scroll_up,
    scroll_down,
    none,
};

pub const MouseEvent = struct {
    kind: MouseEventKind,
    button: MouseButton,
    x: u16,
    y: u16,
    ctrl: bool = false,
    alt: bool = false,
    shift: bool = false,
};

pub const MouseResult = struct {
    event: MouseEvent,
    len: usize,
};

pub const InputEvent = union(enum) {
    key: ParseResult,
    mouse: MouseResult,
};

/// Parse a terminal input sequence into a Key event.
/// Returns null if the input is not a recognized sequence or is incomplete.
pub fn parseKey(data: []const u8, kitty_active: bool) ?ParseResult {
    if (data.len == 0) return null;

    if (data[0] == 0x1B) return parseEscape(data, kitty_active);
    if (data[0] == 0x7F) return .{ .key = .{ .code = .backspace }, .len = 1 };
    if (data[0] == 0x09) return .{ .key = .{ .code = .tab }, .len = 1 };
    if (data[0] == 0x0D) return .{ .key = .{ .code = .enter }, .len = 1 };

    // ctrl+a through ctrl+z (0x01-0x1A, excluding tab/enter/escape)
    if (data[0] >= 0x01 and data[0] <= 0x1A) {
        const ch: u21 = @as(u21, data[0]) + 0x60; // 0x01 -> 'a', etc.
        return .{ .key = .{ .code = .char, .char = ch, .ctrl = true }, .len = 1 };
    }

    if (data[0] >= 0x20) return parseUtf8Char(data);

    return null;
}

/// Parse terminal input as either a key or mouse event.
/// Returns null if unrecognized or incomplete.
pub fn parseInput(data: []const u8, kitty_active: bool) ?InputEvent {
    if (data.len == 0) return null;

    // Try SGR mouse first: ESC[<...M or ESC[<...m
    if (data.len >= 3 and data[0] == 0x1B and data[1] == '[' and data[2] == '<') {
        if (parseSgrMouse(data)) |m| return .{ .mouse = m };
    }

    if (parseKey(data, kitty_active)) |k| return .{ .key = k };

    return null;
}

fn parseEscape(data: []const u8, kitty_active: bool) ?ParseResult {
    if (data.len == 1) return .{ .key = .{ .code = .escape }, .len = 1 };

    if (data[1] == '[') return parseCsi(data, kitty_active);
    if (data[1] == 'O') return parseSs3(data);

    // alt+char: ESC followed by printable ASCII
    if (data[1] >= 0x20 and data[1] <= 0x7E) {
        return .{
            .key = .{ .code = .char, .char = @as(u21, data[1]), .alt = true },
            .len = 2,
        };
    }

    return .{ .key = .{ .code = .escape }, .len = 1 };
}

fn parseSs3(data: []const u8) ?ParseResult {
    if (data.len < 3) return .{ .key = .{ .code = .escape }, .len = 1 };
    const key: ?KeyCode = switch (data[2]) {
        'A' => .up,
        'B' => .down,
        'C' => .right,
        'D' => .left,
        'H' => .home,
        'F' => .end,
        'P' => .f1,
        'Q' => .f2,
        'R' => .f3,
        'S' => .f4,
        else => null,
    };
    if (key) |k| return .{ .key = .{ .code = k }, .len = 3 };
    return .{ .key = .{ .code = .escape }, .len = 1 };
}

/// Parse CSI sequences: \x1b[ ...
fn parseCsi(data: []const u8, kitty_active: bool) ?ParseResult {
    if (data.len < 3) return .{ .key = .{ .code = .escape }, .len = 1 };

    var i: usize = 2;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if ((c >= 'A' and c <= 'Z') or (c >= 'a' and c <= 'z') or c == '~') {
            break;
        }
    }
    if (i >= data.len) return .{ .key = .{ .code = .escape }, .len = 1 };

    const terminator = data[i];
    const seq_len = i + 1;
    const params_slice = data[2..i];

    if (params_slice.len == 0) {
        const key: ?KeyCode = switch (terminator) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => null,
        };
        if (key) |k| return .{ .key = .{ .code = k }, .len = seq_len };
    }

    var params: [4]u16 = .{ 0, 0, 0, 0 };
    var param_count: usize = 0;
    {
        var start: usize = 0;
        for (params_slice, 0..) |c, j| {
            if (c == ';') {
                if (param_count < params.len) {
                    params[param_count] = parseNum(params_slice[start..j]);
                    param_count += 1;
                }
                start = j + 1;
            }
        }
        if (param_count < params.len) {
            params[param_count] = parseNum(params_slice[start..]);
            param_count += 1;
        }
    }

    // kitty CSI u format: \x1b[<codepoint>u or \x1b[<codepoint>;<modifier>u
    if (terminator == 'u' and kitty_active) {
        // Filter release events (event type 3, encoded as :<event> after modifier)
        if (param_count > 1) {
            const event_type = extractEventType(params_slice);
            if (event_type == 3) return null;
        }
        return parseKittyU(params[0], if (param_count > 1) params[1] else 0, seq_len);
    }

    // xterm modifyOtherKeys: \x1b[27;<modifier>;<keycode>~
    // Sent when modifyOtherKeys mode 2 is active and kitty protocol is not.
    if (terminator == '~' and param_count >= 3 and params[0] == 27) {
        const mods = decodeModifier(params[1]);
        const keycode = params[2];
        const mok_key: ?KeyCode = switch (keycode) {
            13 => .enter,
            9 => .tab,
            127 => .backspace,
            27 => .escape,
            else => if (keycode >= 32 and keycode < 128) .char else null,
        };
        if (mok_key) |k| return .{
            .key = .{
                .code = k,
                .char = if (k == .char) @as(?u21, @intCast(keycode)) else null,
                .ctrl = mods.ctrl,
                .alt = mods.alt,
                .shift = mods.shift,
            },
            .len = seq_len,
        };
    }
    // tilde-style: \x1b[<num>~ or \x1b[<num>;<modifier>~
    if (terminator == '~') {
        const modifier = if (param_count > 1) params[1] else @as(u16, 0);
        const mods = decodeModifier(modifier);
        const key: ?KeyCode = switch (params[0]) {
            2 => .insert,
            3 => .delete,
            5 => .page_up,
            6 => .page_down,
            1, 7 => .home,
            4, 8 => .end,
            11 => .f1,
            12 => .f2,
            13 => .f3,
            14 => .f4,
            15 => .f5,
            17 => .f6,
            18 => .f7,
            19 => .f8,
            20 => .f9,
            21 => .f10,
            23 => .f11,
            24 => .f12,
            else => null,
        };
        if (key) |k| return .{
            .key = .{ .code = k, .ctrl = mods.ctrl, .alt = mods.alt, .shift = mods.shift },
            .len = seq_len,
        };
    }

    // letter-terminated with params: \x1b[1;5A = ctrl+up, etc.
    if (terminator >= 'A' and terminator <= 'Z') {
        const modifier = if (param_count > 1) params[1] else @as(u16, 0);
        const mods = decodeModifier(modifier);
        const key: ?KeyCode = switch (terminator) {
            'A' => .up,
            'B' => .down,
            'C' => .right,
            'D' => .left,
            'H' => .home,
            'F' => .end,
            else => null,
        };
        if (key) |k| return .{
            .key = .{ .code = k, .ctrl = mods.ctrl, .alt = mods.alt, .shift = mods.shift },
            .len = seq_len,
        };
    }

    return null;
}

const Modifiers = struct { ctrl: bool, alt: bool, shift: bool };

/// Decode xterm/kitty modifier value. Value = 1 + (shift?1:0) + (alt?2:0) + (ctrl?4:0).
/// A value of 0 (absent) means no modifiers.
fn decodeModifier(value: u16) Modifiers {
    if (value <= 1) return .{ .ctrl = false, .alt = false, .shift = false };
    const v = value - 1;
    return .{
        .shift = (v & 1) != 0,
        .alt = (v & 2) != 0,
        .ctrl = (v & 4) != 0,
    };
}

fn parseKittyU(codepoint: u16, modifier_raw: u16, seq_len: usize) ?ParseResult {
    const mods = decodeModifier(modifier_raw);

    // special kitty codepoints
    const key: ?struct { code: KeyCode, ch: ?u21 } = switch (codepoint) {
        27 => .{ .code = .escape, .ch = null },
        9 => .{ .code = .tab, .ch = null },
        13 => .{ .code = .enter, .ch = null },
        127 => .{ .code = .backspace, .ch = null },
        // Kitty functional codepoints (Private Use Area)
        57399...57408 => .{ .code = .char, .ch = @as(u21, codepoint - 57399) + '0' }, // KP_0-KP_9
        57409 => .{ .code = .char, .ch = '.' }, // KP_DECIMAL
        57410 => .{ .code = .char, .ch = '/' }, // KP_DIVIDE
        57411 => .{ .code = .char, .ch = '*' }, // KP_MULTIPLY
        57412 => .{ .code = .char, .ch = '-' }, // KP_SUBTRACT
        57413 => .{ .code = .char, .ch = '+' }, // KP_ADD
        57414 => .{ .code = .enter, .ch = null }, // KP_ENTER
        57415 => .{ .code = .char, .ch = '=' }, // KP_EQUAL
        57417 => .{ .code = .left, .ch = null }, // KP_LEFT
        57418 => .{ .code = .right, .ch = null }, // KP_RIGHT
        57419 => .{ .code = .up, .ch = null }, // KP_UP
        57420 => .{ .code = .down, .ch = null }, // KP_DOWN
        57421 => .{ .code = .page_up, .ch = null }, // KP_PAGE_UP
        57422 => .{ .code = .page_down, .ch = null }, // KP_PAGE_DOWN
        57423 => .{ .code = .home, .ch = null }, // KP_HOME
        57424 => .{ .code = .end, .ch = null }, // KP_END
        57425 => .{ .code = .insert, .ch = null }, // KP_INSERT
        57426 => .{ .code = .delete, .ch = null }, // KP_DELETE
        else => if (codepoint >= 32) .{ .code = .char, .ch = @as(u21, codepoint) } else null,
    };

    if (key) |k| return .{
        .key = .{
            .code = k.code,
            .char = k.ch,
            .ctrl = mods.ctrl,
            .alt = mods.alt,
            .shift = mods.shift,
        },
        .len = seq_len,
    };

    return null;
}

/// Extract the kitty event type from the raw params slice.
/// Format: \"<codepoint>;<modifier>:<event>\" — event type is after the
/// LAST colon in the second (modifier) param. Returns 0 if absent.
fn extractEventType(params_slice: []const u8) u8 {
    const semi = std.mem.indexOfScalar(u8, params_slice, ';') orelse return 0;
    const mod_part = params_slice[semi + 1 ..];
    const colon = std.mem.indexOfScalar(u8, mod_part, ':') orelse return 0;
    const event_str = mod_part[colon + 1 ..];
    if (event_str.len == 0) return 0;
    return std.fmt.parseInt(u8, event_str, 10) catch 0;
}

/// Parse a decimal number from a slice, stopping at first ':' (colon sub-params).
/// Returns 0 for empty slices.
fn parseNum(s: []const u8) u16 {
    var result: u16 = 0;
    for (s) |c| {
        if (c == ':') break; // ignore colon sub-parameters (kitty event type)
        if (c < '0' or c > '9') return 0;
        result = result *| 10 +| (c - '0');
    }
    return result;
}

/// Parse SGR mouse sequence: ESC[<button;x;yM or ESC[<button;x;ym
fn parseSgrMouse(data: []const u8) ?MouseResult {
    var i: usize = 3;
    while (i < data.len) : (i += 1) {
        if (data[i] == 'M' or data[i] == 'm') break;
    }
    if (i >= data.len) return null;

    const is_release = data[i] == 'm';
    const seq_len = i + 1;
    const params = data[3..i];

    // Parse three semicolon-separated numbers: button;x;y
    var nums: [3]u16 = .{ 0, 0, 0 };
    var num_idx: usize = 0;
    var start: usize = 0;
    for (params, 0..) |c, j| {
        if (c == ';') {
            if (num_idx < 3) {
                nums[num_idx] = parseNum(params[start..j]);
                num_idx += 1;
            }
            start = j + 1;
        }
    }
    if (num_idx < 3) {
        nums[num_idx] = parseNum(params[start..]);
        num_idx += 1;
    }
    if (num_idx < 3) return null;

    const button_code = nums[0];
    const x = if (nums[1] > 0) nums[1] - 1 else 0;
    const y = if (nums[2] > 0) nums[2] - 1 else 0;

    const is_scroll = (button_code & 64) != 0;
    const is_motion = (button_code & 32) != 0;

    const ctrl = (button_code & 16) != 0;
    const alt_mod = (button_code & 8) != 0;
    const shift_mod = (button_code & 4) != 0;
    const button = if (is_scroll)
        switch (button_code & 3) {
            0 => MouseButton.scroll_up,
            1 => .scroll_down,
            else => .none,
        }
    else switch (button_code & 3) {
        0 => MouseButton.left,
        1 => .middle,
        2 => .right,
        else => .none,
    };

    const kind: MouseEventKind = if (is_motion)
        if ((button_code & 3) == 3) .move else .drag
    else if (is_scroll and !is_release)
        .scroll
    else if (is_release)
        .up
    else
        .down;

    return .{
        .event = .{
            .kind = kind,
            .button = if (kind == .up and !is_scroll) .none else button,
            .x = x,
            .y = y,
            .ctrl = ctrl,
            .alt = alt_mod,
            .shift = shift_mod,
        },
        .len = seq_len,
    };
}

fn parseUtf8Char(data: []const u8) ?ParseResult {
    const len = std.unicode.utf8ByteSequenceLength(data[0]) catch return null;
    if (data.len < len) return null;
    const cp = std.unicode.utf8Decode(data[0..len]) catch return null;
    return .{
        .key = .{ .code = .char, .char = cp },
        .len = len,
    };
}

test "parseKeySpec normalizes modifiers and named keys" {
    try std.testing.expect(Key.eql(try parseKeySpec("ctrl+f"), .{ .code = .char, .char = 'f', .ctrl = true }));
    try std.testing.expect(Key.eql(try parseKeySpec("shift+enter"), .{ .code = .enter, .shift = true }));
    try std.testing.expectError(error.InvalidKeySpec, parseKeySpec("ctrl+"));
}

test "parseKey handles printable, control, and single-byte special keys" {
    const printable = parseKey("a", false).?;
    try std.testing.expectEqual(KeyCode.char, printable.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), printable.key.char);

    const ctrl_c = parseKey("\x03", false).?;
    try std.testing.expectEqual(KeyCode.char, ctrl_c.key.code);
    try std.testing.expectEqual(@as(?u21, 'c'), ctrl_c.key.char);
    try std.testing.expect(ctrl_c.key.ctrl);

    try std.testing.expectEqual(KeyCode.enter, parseKey("\r", false).?.key.code);
    try std.testing.expectEqual(KeyCode.tab, parseKey("\t", false).?.key.code);
    try std.testing.expectEqual(KeyCode.backspace, parseKey("\x7f", false).?.key.code);
    try std.testing.expectEqual(KeyCode.escape, parseKey("\x1b", false).?.key.code);
}

test "parseKey handles CSI and SS3 terminal sequences" {
    try std.testing.expectEqual(KeyCode.up, parseKey("\x1b[A", false).?.key.code);
    try std.testing.expectEqual(KeyCode.home, parseKey("\x1b[H", false).?.key.code);
    try std.testing.expectEqual(KeyCode.f1, parseKey("\x1bOP", false).?.key.code);
    try std.testing.expectEqual(KeyCode.end, parseKey("\x1bOF", false).?.key.code);
    try std.testing.expectEqual(KeyCode.delete, parseKey("\x1b[3~", false).?.key.code);
    try std.testing.expectEqual(KeyCode.f12, parseKey("\x1b[24~", false).?.key.code);
}

test "parseKey decodes terminal modifiers" {
    const ctrl_shift_up = parseKey("\x1b[1;6A", false).?;
    try std.testing.expectEqual(KeyCode.up, ctrl_shift_up.key.code);
    try std.testing.expect(ctrl_shift_up.key.ctrl);
    try std.testing.expect(ctrl_shift_up.key.shift);
    try std.testing.expect(!ctrl_shift_up.key.alt);

    const alt_a = parseKey("\x1ba", false).?;
    try std.testing.expectEqual(KeyCode.char, alt_a.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), alt_a.key.char);
    try std.testing.expect(alt_a.key.alt);

    const modify_other_enter = parseKey("\x1b[27;5;13~", false).?;
    try std.testing.expectEqual(KeyCode.enter, modify_other_enter.key.code);
    try std.testing.expect(modify_other_enter.key.ctrl);

    const modify_other_char = parseKey("\x1b[27;2;97~", false).?;
    try std.testing.expectEqual(KeyCode.char, modify_other_char.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), modify_other_char.key.char);
    try std.testing.expect(modify_other_char.key.shift);
}

test "kitty CSI-u parses codepoints, modifiers, special keys, and releases" {
    const char = parseKey("\x1b[97u", true).?;
    try std.testing.expectEqual(KeyCode.char, char.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), char.key.char);

    const alt_v = parseKey("\x1b[118;3u", true).?;
    try std.testing.expectEqual(KeyCode.char, alt_v.key.code);
    try std.testing.expectEqual(@as(?u21, 'v'), alt_v.key.char);
    try std.testing.expect(alt_v.key.alt);

    const shift_enter = parseKey("\x1b[13;2u", true).?;
    try std.testing.expectEqual(KeyCode.enter, shift_enter.key.code);
    try std.testing.expect(shift_enter.key.shift);

    try std.testing.expectEqual(KeyCode.left, parseKey("\x1b[57417u", true).?.key.code);
    try std.testing.expect(parseKey("\x1b[97;1:3u", true) == null);
}

test "parseKey handles multi-byte UTF-8 characters" {
    const result = parseKey("é", false).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 0xE9), result.key.char);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "SGR mouse sequences decode events, coordinates, and modifiers" {
    const scroll_up = parseSgrMouse("\x1b[<64;10;20M").?;
    try std.testing.expectEqual(MouseEventKind.scroll, scroll_up.event.kind);
    try std.testing.expectEqual(MouseButton.scroll_up, scroll_up.event.button);
    try std.testing.expectEqual(@as(u16, 9), scroll_up.event.x);
    try std.testing.expectEqual(@as(u16, 19), scroll_up.event.y);

    const modified_drag = parseSgrMouse("\x1b[<60;11;21M").?;
    try std.testing.expectEqual(MouseEventKind.drag, modified_drag.event.kind);
    try std.testing.expectEqual(MouseButton.left, modified_drag.event.button);
    try std.testing.expect(modified_drag.event.ctrl);
    try std.testing.expect(modified_drag.event.alt);
    try std.testing.expect(modified_drag.event.shift);

    const release = parseSgrMouse("\x1b[<0;11;21m").?;
    try std.testing.expectEqual(MouseEventKind.up, release.event.kind);
    try std.testing.expectEqual(MouseButton.none, release.event.button);
}

test "parseInput prioritizes SGR mouse sequences and falls back to keys" {
    switch (parseInput("\x1b[<64;1;1M", false).?) {
        .mouse => |m| try std.testing.expectEqual(MouseButton.scroll_up, m.event.button),
        .key => try std.testing.expect(false),
    }

    switch (parseInput("a", false).?) {
        .key => |k| try std.testing.expectEqual(KeyCode.char, k.key.code),
        .mouse => try std.testing.expect(false),
    }
}
