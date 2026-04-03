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

    // regular printable or UTF-8 character
    if (data[0] >= 0x20) return parseUtf8Char(data);

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
    // minimum: \x1b[X (3 bytes)
    if (data.len < 3) return .{ .key = .{ .code = .escape }, .len = 1 };

    // find the terminating byte (letter or ~ or u)
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

    // simple arrow/home/end with no params
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

    // parse semicolon-separated numeric params (with colon sub-params)
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
        return parseKittyU(params[0], if (param_count > 1) params[1] else 0, seq_len);
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
    // strip colon-suffixed event type from modifier (handled in parseNum)
    const mods = decodeModifier(modifier_raw);

    // special kitty codepoints
    const key: ?struct { code: KeyCode, ch: ?u21 } = switch (codepoint) {
        27 => .{ .code = .escape, .ch = null },
        9 => .{ .code = .tab, .ch = null },
        13 => .{ .code = .enter, .ch = null },
        127 => .{ .code = .backspace, .ch = null },
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

fn parseUtf8Char(data: []const u8) ?ParseResult {
    const len = std.unicode.utf8ByteSequenceLength(data[0]) catch return null;
    if (data.len < len) return null;
    const cp = std.unicode.utf8Decode(data[0..len]) catch return null;
    return .{
        .key = .{ .code = .char, .char = cp },
        .len = len,
    };
}

// =============================================================================
// Tests
// =============================================================================

test "parse regular character" {
    const result = parseKey("a", false).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), result.key.char);
    try std.testing.expectEqual(@as(usize, 1), result.len);
}

test "parse enter" {
    const result = parseKey("\r", false).?;
    try std.testing.expectEqual(KeyCode.enter, result.key.code);
}

test "parse ctrl+c" {
    const result = parseKey("\x03", false).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 'c'), result.key.char);
    try std.testing.expect(result.key.ctrl);
}

test "parse escape" {
    const result = parseKey("\x1b", false).?;
    try std.testing.expectEqual(KeyCode.escape, result.key.code);
}

test "parse arrow keys" {
    try std.testing.expectEqual(KeyCode.up, parseKey("\x1b[A", false).?.key.code);
    try std.testing.expectEqual(KeyCode.down, parseKey("\x1b[B", false).?.key.code);
    try std.testing.expectEqual(KeyCode.right, parseKey("\x1b[C", false).?.key.code);
    try std.testing.expectEqual(KeyCode.left, parseKey("\x1b[D", false).?.key.code);
}

test "parse SS3 arrows" {
    try std.testing.expectEqual(KeyCode.up, parseKey("\x1bOA", false).?.key.code);
    try std.testing.expectEqual(KeyCode.down, parseKey("\x1bOB", false).?.key.code);
}

test "parse function keys" {
    try std.testing.expectEqual(KeyCode.f1, parseKey("\x1bOP", false).?.key.code);
    try std.testing.expectEqual(KeyCode.f5, parseKey("\x1b[15~", false).?.key.code);
    try std.testing.expectEqual(KeyCode.f12, parseKey("\x1b[24~", false).?.key.code);
}

test "parse modified arrow" {
    const result = parseKey("\x1b[1;5A", false).?;
    try std.testing.expectEqual(KeyCode.up, result.key.code);
    try std.testing.expect(result.key.ctrl);
    try std.testing.expect(!result.key.shift);
}

test "parse shift+ctrl arrow" {
    const result = parseKey("\x1b[1;6A", false).?;
    try std.testing.expectEqual(KeyCode.up, result.key.code);
    try std.testing.expect(result.key.ctrl);
    try std.testing.expect(result.key.shift);
}

test "parse alt+char" {
    const result = parseKey("\x1ba", false).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), result.key.char);
    try std.testing.expect(result.key.alt);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}

test "parse home/end" {
    try std.testing.expectEqual(KeyCode.home, parseKey("\x1b[H", false).?.key.code);
    try std.testing.expectEqual(KeyCode.end, parseKey("\x1b[F", false).?.key.code);
    try std.testing.expectEqual(KeyCode.home, parseKey("\x1bOH", false).?.key.code);
    try std.testing.expectEqual(KeyCode.end, parseKey("\x1bOF", false).?.key.code);
}

test "parse delete/insert/pageup/pagedown" {
    try std.testing.expectEqual(KeyCode.insert, parseKey("\x1b[2~", false).?.key.code);
    try std.testing.expectEqual(KeyCode.delete, parseKey("\x1b[3~", false).?.key.code);
    try std.testing.expectEqual(KeyCode.page_up, parseKey("\x1b[5~", false).?.key.code);
    try std.testing.expectEqual(KeyCode.page_down, parseKey("\x1b[6~", false).?.key.code);
}

test "parse backspace" {
    const result = parseKey("\x7f", false).?;
    try std.testing.expectEqual(KeyCode.backspace, result.key.code);
}

test "parse tab" {
    const result = parseKey("\t", false).?;
    try std.testing.expectEqual(KeyCode.tab, result.key.code);
}

test "kitty protocol basic" {
    const result = parseKey("\x1b[97u", true).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), result.key.char);
}

test "kitty protocol with modifier" {
    const result = parseKey("\x1b[97;5u", true).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 'a'), result.key.char);
    try std.testing.expect(result.key.ctrl);
}

test "kitty enter" {
    const result = parseKey("\x1b[13u", true).?;
    try std.testing.expectEqual(KeyCode.enter, result.key.code);
}

test "UTF-8 character" {
    const result = parseKey("é", false).?;
    try std.testing.expectEqual(KeyCode.char, result.key.code);
    try std.testing.expectEqual(@as(?u21, 0xE9), result.key.char);
    try std.testing.expectEqual(@as(usize, 2), result.len);
}
