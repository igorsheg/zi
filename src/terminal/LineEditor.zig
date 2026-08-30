const std = @import("std");
const LineEditor = @This();

pub const max_prompt_bytes: usize = 1024 * 1024;

allocator: std.mem.Allocator,
buffer: std.ArrayList(u8) = .empty,
cursor: usize = 0,
empty_submit: bool,
exit_armed: bool = false,
utf8_pending: [4]u8 = undefined,
utf8_pending_len: u3 = 0,
utf8_expected_len: u3 = 0,

pub const Error = error{ PromptTooLong, OutOfMemory };

pub const Outcome = enum {
    none,
    edited,
    submit,
    eof,
    exit_armed,
    paste_begin,
    history_previous,
    history_next,
    history_search,
};

pub fn init(allocator: std.mem.Allocator, empty_submit: bool) LineEditor {
    return .{ .allocator = allocator, .empty_submit = empty_submit };
}

pub fn deinit(editor: *LineEditor) void {
    editor.buffer.deinit(editor.allocator);
    editor.* = undefined;
}

/// The returned bytes are borrowed until the next mutating call or `deinit`.
pub fn bytes(editor: *const LineEditor) []const u8 {
    return editor.buffer.items;
}

pub fn setEmptySubmit(editor: *LineEditor, enabled: bool) void {
    editor.empty_submit = enabled;
}

/// Atomically replaces the complete edit buffer and puts the cursor at its end.
pub fn setBuffer(editor: *LineEditor, text: []const u8) Error!void {
    try editor.setBufferAtCursor(text, text.len);
}

pub fn cursorOffset(editor: *const LineEditor) usize {
    return editor.cursor;
}

/// Atomically replaces the complete buffer and clamps the requested byte cursor.
pub fn setBufferAtCursor(editor: *LineEditor, text: []const u8, cursor_offset: usize) Error!void {
    if (text.len > max_prompt_bytes) return error.PromptTooLong;
    try editor.buffer.ensureTotalCapacityPrecise(editor.allocator, text.len);
    editor.buffer.clearRetainingCapacity();
    editor.buffer.appendSliceAssumeCapacity(text);
    editor.cursor = @min(cursor_offset, text.len);
    editor.exit_armed = false;
    editor.clearPendingUtf8();
}

/// Atomically replaces `[start, end)` and leaves the cursor after `replacement`.
pub fn replace(editor: *LineEditor, start: usize, end: usize, replacement: []const u8) Error!void {
    if (start > end or end > editor.buffer.items.len) return;

    var owned_replacement: ?[]u8 = null;
    defer if (owned_replacement) |storage| editor.allocator.free(storage);
    const buffer_start = @intFromPtr(editor.buffer.items.ptr);
    const buffer_end = buffer_start + editor.buffer.items.len;
    const replacement_start = @intFromPtr(replacement.ptr);
    const stable_replacement = if (replacement.len != 0 and replacement_start < buffer_end and
        replacement_start + replacement.len > buffer_start)
    stable: {
        owned_replacement = try editor.allocator.dupe(u8, replacement);
        break :stable owned_replacement.?;
    } else replacement;

    const removed = end - start;
    const base_len = editor.buffer.items.len - removed;
    if (stable_replacement.len > max_prompt_bytes - base_len) return error.PromptTooLong;
    const new_len = base_len + stable_replacement.len;
    try editor.buffer.ensureTotalCapacityPrecise(editor.allocator, new_len);

    const old_len = editor.buffer.items.len;
    const tail_len = old_len - end;
    if (new_len > old_len) {
        editor.buffer.items.len = new_len;
        @memmove(
            editor.buffer.items[start + stable_replacement.len ..][0..tail_len],
            editor.buffer.items[end..][0..tail_len],
        );
    } else {
        @memmove(
            editor.buffer.items[start + stable_replacement.len ..][0..tail_len],
            editor.buffer.items[end..][0..tail_len],
        );
        editor.buffer.items.len = new_len;
    }
    @memcpy(editor.buffer.items[start..][0..stable_replacement.len], stable_replacement);
    editor.cursor = start + stable_replacement.len;
}

pub fn insert(editor: *LineEditor, text: []const u8) Error!void {
    try editor.replace(editor.cursor, editor.cursor, text);
}

pub fn lineStart(editor: *const LineEditor) usize {
    var index = editor.cursor;
    while (index > 0 and editor.buffer.items[index - 1] != '\n') index -= 1;
    return index;
}

pub fn lineEnd(editor: *const LineEditor) usize {
    var index = editor.cursor;
    while (index < editor.buffer.items.len and editor.buffer.items[index] != '\n') index += 1;
    return index;
}

pub fn moveLeft(editor: *LineEditor) void {
    editor.cursor = previousCodepoint(editor.buffer.items, editor.cursor);
}

pub fn moveRight(editor: *LineEditor) void {
    editor.cursor = nextCodepoint(editor.buffer.items, editor.cursor);
}

pub fn moveWordBack(editor: *LineEditor) void {
    var target = editor.cursor;
    while (target > 0 and !isWordByte(editor.buffer.items[target - 1])) target -= 1;
    while (target > 0 and isWordByte(editor.buffer.items[target - 1])) target -= 1;
    editor.cursor = target;
}

pub fn moveWordForward(editor: *LineEditor) void {
    var target = editor.cursor;
    while (target < editor.buffer.items.len and !isWordByte(editor.buffer.items[target])) target += 1;
    while (target < editor.buffer.items.len and isWordByte(editor.buffer.items[target])) target += 1;
    editor.cursor = target;
}

pub fn deleteWordForward(editor: *LineEditor) void {
    const start = editor.cursor;
    editor.moveWordForward();
    const end = editor.cursor;
    editor.cursor = start;
    editor.erase(start, end);
}

pub fn deleteBack(editor: *LineEditor) void {
    const start = previousCodepoint(editor.buffer.items, editor.cursor);
    editor.erase(start, editor.cursor);
}

pub fn deleteForward(editor: *LineEditor) void {
    const end = nextCodepoint(editor.buffer.items, editor.cursor);
    editor.erase(editor.cursor, end);
}

pub fn killToLineEnd(editor: *LineEditor) void {
    var end = editor.lineEnd();
    if (end == editor.cursor and end < editor.buffer.items.len) end += 1;
    editor.erase(editor.cursor, end);
}

pub fn killToLineStart(editor: *LineEditor) void {
    editor.erase(editor.lineStart(), editor.cursor);
}

pub fn killWordBack(editor: *LineEditor) void {
    var start = editor.cursor;
    while (start > 0 and std.ascii.isWhitespace(editor.buffer.items[start - 1])) start -= 1;
    while (start > 0 and !std.ascii.isWhitespace(editor.buffer.items[start - 1])) start -= 1;
    editor.erase(start, editor.cursor);
}

/// Handles one byte after terminal escape decoding. UTF-8 input is inserted only
/// after a complete valid sequence has arrived.
pub fn handleByte(editor: *LineEditor, byte: u8) Error!Outcome {
    if (byte != 0x03) editor.exit_armed = false;
    if (editor.utf8_pending_len != 0) return editor.handleUtf8Continuation(byte);

    return switch (byte) {
        0x01 => editor.moveTo(editor.lineStart()),
        0x02 => editor.moveAndReport(false),
        0x03 => editor.handleCtrlC(),
        0x04 => if (editor.buffer.items.len == 0) .eof else editor.deleteAndReport(false),
        0x05 => editor.moveTo(editor.lineEnd()),
        0x06 => editor.moveAndReport(true),
        0x08, 0x7f => editor.deleteAndReport(true),
        0x09 => editor.insertAndReport("\t"),
        0x0a => editor.insertAndReport("\n"),
        0x0b => editor.killAndReport(.line_end),
        0x0d => if (editor.buffer.items.len > 0 or editor.empty_submit) .submit else .none,
        0x0e => .history_next,
        0x10 => .history_previous,
        0x12 => .history_search,
        0x15 => editor.killAndReport(.line_start),
        0x17 => editor.killAndReport(.word_back),
        0x20...0x7e => editor.insertAndReport(&.{byte}),
        0xc2...0xf4 => editor.beginUtf8(byte),
        else => .none,
    };
}

pub fn applyAction(editor: *LineEditor, action: EscapeAction) Outcome {
    editor.exit_armed = false;
    editor.clearPendingUtf8();
    return switch (action) {
        .none => .none,
        .move_left => editor.moveAndReport(false),
        .move_right => editor.moveAndReport(true),
        .move_word_left => editor.moveWordAndReport(false),
        .move_word_right => editor.moveWordAndReport(true),
        .delete_word_forward => editor.deleteWordAndReport(false),
        .delete_word_back => editor.deleteWordAndReport(true),
        .line_start => editor.moveTo(editor.lineStart()),
        .line_end => editor.moveTo(editor.lineEnd()),
        .delete_forward => editor.deleteAndReport(false),
        .paste_begin => .paste_begin,
        .history_previous => .history_previous,
        .history_next => .history_next,
        .page_up, .page_down => .none,
    };
}

fn handleCtrlC(editor: *LineEditor) Outcome {
    if (editor.buffer.items.len != 0) {
        editor.buffer.clearRetainingCapacity();
        editor.cursor = 0;
        editor.exit_armed = false;
        return .edited;
    }
    if (editor.exit_armed) return .eof;
    editor.exit_armed = true;
    return .exit_armed;
}

fn beginUtf8(editor: *LineEditor, byte: u8) Outcome {
    const expected: u3 = if (byte <= 0xdf) 2 else if (byte <= 0xef) 3 else 4;
    editor.utf8_pending[0] = byte;
    editor.utf8_pending_len = 1;
    editor.utf8_expected_len = expected;
    return .none;
}

fn handleUtf8Continuation(editor: *LineEditor, byte: u8) Error!Outcome {
    if (byte < 0x80 or byte > 0xbf) {
        editor.clearPendingUtf8();
        return editor.handleByte(byte);
    }
    editor.utf8_pending[editor.utf8_pending_len] = byte;
    editor.utf8_pending_len += 1;
    if (editor.utf8_pending_len != editor.utf8_expected_len) return .none;
    const input = editor.utf8_pending[0..editor.utf8_pending_len];
    defer editor.clearPendingUtf8();
    if (!std.unicode.utf8ValidateSlice(input)) return .none;
    try editor.insert(input);
    return .edited;
}

fn clearPendingUtf8(editor: *LineEditor) void {
    editor.utf8_pending_len = 0;
    editor.utf8_expected_len = 0;
}

fn moveTo(editor: *LineEditor, target: usize) Outcome {
    if (target == editor.cursor) return .none;
    editor.cursor = target;
    return .edited;
}

fn moveAndReport(editor: *LineEditor, forward: bool) Outcome {
    const old = editor.cursor;
    if (forward) editor.moveRight() else editor.moveLeft();
    return if (old == editor.cursor) .none else .edited;
}

fn moveWordAndReport(editor: *LineEditor, forward: bool) Outcome {
    const old = editor.cursor;
    if (forward) editor.moveWordForward() else editor.moveWordBack();
    return if (old == editor.cursor) .none else .edited;
}

fn deleteWordAndReport(editor: *LineEditor, back: bool) Outcome {
    const old = editor.buffer.items.len;
    if (back) editor.killWordBack() else editor.deleteWordForward();
    return if (old == editor.buffer.items.len) .none else .edited;
}

fn deleteAndReport(editor: *LineEditor, back: bool) Outcome {
    const old = editor.buffer.items.len;
    if (back) editor.deleteBack() else editor.deleteForward();
    return if (old == editor.buffer.items.len) .none else .edited;
}

const Kill = enum { line_end, line_start, word_back };
fn killAndReport(editor: *LineEditor, kind: Kill) Outcome {
    const old = editor.buffer.items.len;
    switch (kind) {
        .line_end => editor.killToLineEnd(),
        .line_start => editor.killToLineStart(),
        .word_back => editor.killWordBack(),
    }
    return if (old == editor.buffer.items.len) .none else .edited;
}

fn insertAndReport(editor: *LineEditor, input: []const u8) Error!Outcome {
    try editor.insert(input);
    return .edited;
}

fn erase(editor: *LineEditor, start: usize, end: usize) void {
    if (start >= end or end > editor.buffer.items.len) return;
    const removed = end - start;
    const tail_len = editor.buffer.items.len - end;
    @memmove(editor.buffer.items[start..][0..tail_len], editor.buffer.items[end..][0..tail_len]);
    editor.buffer.items.len -= removed;
    if (editor.cursor >= end) editor.cursor -= removed else if (editor.cursor > start) editor.cursor = start;
}

fn nextCodepoint(input: []const u8, offset: usize) usize {
    if (offset >= input.len) return input.len;
    const sequence_len = std.unicode.utf8ByteSequenceLength(input[offset]) catch return offset + 1;
    const end = offset + sequence_len;
    if (end > input.len or !std.unicode.utf8ValidateSlice(input[offset..end])) return offset + 1;
    return end;
}

pub fn previousCodepoint(input: []const u8, offset: usize) usize {
    if (offset == 0) return 0;
    const floor = offset - @min(offset, 4);
    var candidate = offset - 1;
    while (true) : (candidate -= 1) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(input[candidate]) catch {
            if (candidate == floor) break;
            continue;
        };
        const end = candidate + sequence_len;
        if (end == offset and std.unicode.utf8ValidateSlice(input[candidate..end])) return candidate;
        if (candidate == floor) break;
    }
    return offset - 1;
}

pub const EscapeAction = enum {
    none,
    move_left,
    move_right,
    move_word_left,
    move_word_right,
    delete_word_forward,
    delete_word_back,
    line_start,
    line_end,
    delete_forward,
    paste_begin,
    history_previous,
    history_next,
    page_up,
    page_down,
};

pub const EscapeDecode = struct {
    action: EscapeAction,
    consumed: usize,
};

/// Decodes bytes following an already consumed ESC. A partial sequence consumes
/// nothing so the caller can wait for more input. Unknown complete sequences are drained.
pub fn decodeEscape(input: []const u8) EscapeDecode {
    if (input.len == 0) return .{ .action = .none, .consumed = 0 };
    var offset: usize = 0;
    var meta = false;
    while (offset < input.len and input[offset] == 0x1b and offset < 4) : (offset += 1) meta = true;
    if (offset == input.len) return .{ .action = .none, .consumed = 0 };
    if (input[offset] == 0x1b) return .{ .action = .none, .consumed = offset + 1 };
    const leader = input[offset];
    if (leader != '[' and leader != 'O') return .{ .action = .none, .consumed = offset + 1 };
    const sequence_start = offset + 1;
    const cap = @min(input.len, sequence_start + 64);
    var end = sequence_start;
    while (end < cap) : (end += 1) {
        const byte = input[end];
        if ((byte < 0x40 or byte > 0x7e) and byte != '$') continue;
        const sequence = input[sequence_start .. end + 1];
        const action = if (leader == '[') decodeCsi(sequence, meta) else decodeSs3(sequence, meta);
        return .{ .action = action, .consumed = end + 1 };
    }
    if (input.len >= sequence_start + 64) {
        return .{ .action = .none, .consumed = sequence_start + 64 };
    }
    return .{ .action = .none, .consumed = 0 };
}

fn decodeCsi(sequence: []const u8, meta: bool) EscapeAction {
    if (sequence.len == 1) {
        var final = sequence[0];
        if (final >= 'a' and final <= 'd') final -= 'a' - 'A';
        return arrowAction(final, meta);
    }
    if (std.mem.eql(u8, sequence, "200~")) return .paste_begin;
    const final = sequence[sequence.len - 1];
    if ((final == '~' or final == '^' or final == '$' or final == '@') and
        (sequence.len == 2 or (sequence.len >= 4 and sequence[1] == ';')))
    {
        return switch (sequence[0]) {
            '1', '7' => .line_start,
            '4', '8' => .line_end,
            '3' => .delete_forward,
            '5' => .page_up,
            '6' => .page_down,
            else => .none,
        };
    }
    if (sequence.len >= 4 and sequence[0] == '1' and sequence[1] == ';') {
        return arrowAction(final, meta or modifierImpliesWord(parseModifier(sequence)));
    }
    return .none;
}

fn decodeSs3(sequence: []const u8, meta: bool) EscapeAction {
    var final = sequence[sequence.len - 1];
    var word = modifierImpliesWord(parseModifier(sequence));
    if (final >= 'a' and final <= 'd') {
        final -= 'a' - 'A';
        word = true;
    }
    return arrowAction(final, word or meta);
}

fn arrowAction(final: u8, word: bool) EscapeAction {
    return switch (final) {
        'A' => .history_previous,
        'B' => .history_next,
        'C' => if (word) .move_word_right else .move_right,
        'D' => if (word) .move_word_left else .move_left,
        'H' => .line_start,
        'F' => .line_end,
        else => .none,
    };
}

fn parseModifier(sequence: []const u8) u16 {
    if (sequence.len < 3) return 0;
    const separator = std.mem.findScalar(u8, sequence[0 .. sequence.len - 1], ';') orelse return 0;
    if (separator + 1 >= sequence.len - 1) return 0;
    const parameter_end = std.mem.findScalarPos(
        u8,
        sequence[0 .. sequence.len - 1],
        separator + 1,
        ';',
    ) orelse sequence.len - 1;
    var value: u16 = 0;
    for (sequence[separator + 1 .. parameter_end]) |byte| {
        if (byte < '0' or byte > '9') return 0;
        value = std.math.mul(u16, value, 10) catch return 0;
        value = std.math.add(u16, value, byte - '0') catch return 0;
    }
    return value;
}

fn isWordByte(byte: u8) bool {
    return byte >= 0x80 or std.ascii.isAlphanumeric(byte);
}

fn modifierImpliesWord(modifier: u16) bool {
    return modifier >= 1 and (modifier - 1) & 0xe != 0;
}

pub const PasteCollector = struct {
    allocator: std.mem.Allocator,
    body: std.ArrayList(u8) = .empty,
    max_bytes: usize,
    marker_len: u3 = 0,
    pending_cr: bool = false,
    complete: bool = false,
    truncated: bool = false,

    pub const FeedResult = struct { consumed: usize, complete: bool };
    const marker = "\x1b[201~";

    pub fn init(allocator: std.mem.Allocator, max_bytes: usize) PasteCollector {
        return .{ .allocator = allocator, .max_bytes = @min(max_bytes, max_prompt_bytes) };
    }

    pub fn deinit(collector: *PasteCollector) void {
        collector.body.deinit(collector.allocator);
        collector.* = undefined;
    }

    pub fn bytes(collector: *const PasteCollector) []const u8 {
        return collector.body.items;
    }

    /// Consumes through the end marker even after the retained body reaches its cap.
    pub fn feed(collector: *PasteCollector, input: []const u8) error{OutOfMemory}!FeedResult {
        if (collector.complete) return .{ .consumed = 0, .complete = true };
        for (input, 0..) |byte, index| {
            if (byte == marker[collector.marker_len]) {
                collector.marker_len += 1;
                if (collector.marker_len == marker.len) {
                    try collector.flushCr();
                    collector.complete = true;
                    return .{ .consumed = index + 1, .complete = true };
                }
                continue;
            }
            if (collector.marker_len != 0) {
                const prefix_len = collector.marker_len;
                collector.marker_len = 0;
                for (marker[0..prefix_len]) |pending| try collector.appendNormalized(pending);
                if (byte == marker[0]) {
                    collector.marker_len = 1;
                    continue;
                }
            }
            try collector.appendNormalized(byte);
        }
        return .{ .consumed = input.len, .complete = false };
    }

    /// Commits an unterminated paste body. A partial end-marker prefix is
    /// retained literally and a trailing CR is normalized to LF.
    pub fn finishPartial(collector: *PasteCollector) error{OutOfMemory}!void {
        if (collector.complete) return;
        const extra = @min(
            collector.max_bytes - collector.body.items.len,
            @as(usize, collector.marker_len) + @intFromBool(collector.pending_cr),
        );
        try collector.body.ensureUnusedCapacity(collector.allocator, extra);
        const prefix_len = collector.marker_len;
        collector.marker_len = 0;
        for (marker[0..prefix_len]) |byte| try collector.appendNormalized(byte);
        try collector.flushCr();
    }

    fn appendNormalized(collector: *PasteCollector, byte: u8) error{OutOfMemory}!void {
        if (collector.pending_cr) {
            collector.pending_cr = false;
            try collector.appendBounded('\n');
            if (byte == '\n') return;
        }
        if (byte == '\r') {
            collector.pending_cr = true;
        } else {
            try collector.appendBounded(if (byte == 0) ' ' else byte);
        }
    }

    fn flushCr(collector: *PasteCollector) error{OutOfMemory}!void {
        if (!collector.pending_cr) return;
        collector.pending_cr = false;
        try collector.appendBounded('\n');
    }

    fn appendBounded(collector: *PasteCollector, byte: u8) error{OutOfMemory}!void {
        if (collector.body.items.len == collector.max_bytes) {
            collector.truncated = true;
            return;
        }
        try collector.body.append(collector.allocator, byte);
    }
};

fn allocationFailureCase(allocator: std.mem.Allocator) !void {
    var editor = init(allocator, false);
    defer editor.deinit();
    try editor.setBuffer("before");
    editor.cursor = 3;
    editor.insert(" allocated text") catch |err| {
        try std.testing.expectEqualStrings("before", editor.bytes());
        try std.testing.expectEqual(@as(usize, 3), editor.cursor);
        return err;
    };
}

test "allocation failures preserve the prior edit and do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationFailureCase, .{});
}

test "replace shrinks a middle span and supports aliased replacements" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();

    try editor.setBuffer("0123456789");
    try editor.replace(2, 8, "x");
    try std.testing.expectEqualStrings("01x89", editor.bytes());
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);

    try editor.setBuffer("abcdef");
    try editor.replace(2, 3, editor.bytes()[0..4]);
    try std.testing.expectEqualStrings("ababcddef", editor.bytes());

    try editor.setBuffer("abcdef");
    try editor.replace(1, 5, editor.bytes()[2..3]);
    try std.testing.expectEqualStrings("acf", editor.bytes());
}

test "Meta word motion uses alphanumeric boundaries" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("foo-bar");
    editor.moveWordBack();
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    editor.moveWordBack();
    try std.testing.expectEqual(@as(usize, 0), editor.cursor);
    editor.moveWordForward();
    try std.testing.expectEqual(@as(usize, 3), editor.cursor);
}

test "UTF-8 motion and deletion tolerate malformed bytes" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("a界\xffb");
    editor.cursor = 1;
    editor.moveRight();
    try std.testing.expectEqual(@as(usize, 4), editor.cursor);
    editor.deleteForward();
    try std.testing.expectEqualStrings("a界b", editor.bytes());
    editor.deleteBack();
    try std.testing.expectEqualStrings("ab", editor.bytes());
}

test "control keys edit lines and enforce empty submit and consecutive ctrl-c" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("one two\nthree");
    try std.testing.expectEqual(Outcome.edited, try editor.handleByte(0x15));
    try std.testing.expectEqualStrings("one two\n", editor.bytes());
    try std.testing.expectEqual(Outcome.submit, try editor.handleByte('\r'));
    try std.testing.expectEqual(Outcome.edited, try editor.handleByte(0x03));
    try std.testing.expectEqual(Outcome.exit_armed, try editor.handleByte(0x03));
    try std.testing.expectEqual(Outcome.eof, try editor.handleByte(0x03));
    editor.setEmptySubmit(true);
    try std.testing.expectEqual(Outcome.submit, try editor.handleByte('\r'));
}

test "alphanumeric Meta actions and whitespace Ctrl-W remain distinct" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("one  two three");
    editor.cursor = 8;
    try std.testing.expectEqual(Outcome.edited, editor.applyAction(.move_word_left));
    try std.testing.expectEqual(@as(usize, 5), editor.cursor);
    try std.testing.expectEqual(Outcome.edited, editor.applyAction(.delete_word_back));
    try std.testing.expectEqualStrings("two three", editor.bytes());
    try std.testing.expectEqual(Outcome.edited, editor.applyAction(.delete_word_forward));
    try std.testing.expectEqualStrings(" three", editor.bytes());
    editor.cursor = 0;
    try std.testing.expectEqual(Outcome.edited, editor.applyAction(.move_word_right));
    try std.testing.expectEqual(@as(usize, 6), editor.cursor);
    try editor.setBuffer("one  two");
    try std.testing.expectEqual(Outcome.edited, try editor.handleByte(0x17));
    try std.testing.expectEqualStrings("one  ", editor.bytes());
}

test "escape actions break incomplete UTF-8 sequences" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();

    try std.testing.expectEqual(Outcome.none, try editor.handleByte(0xc3));
    try std.testing.expectEqual(Outcome.none, editor.applyAction(.move_left));
    try std.testing.expectEqual(Outcome.none, try editor.handleByte(0xa9));
    try std.testing.expectEqualStrings("", editor.bytes());

    try std.testing.expectEqual(Outcome.none, try editor.handleByte(0xc3));
    try std.testing.expectEqual(Outcome.none, editor.applyAction(.none));
    try std.testing.expectEqual(Outcome.none, try editor.handleByte(0xa9));
    try std.testing.expectEqualStrings("", editor.bytes());
}

test "control history keys report navigation without editing" {
    var editor = init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");

    try std.testing.expectEqual(Outcome.history_previous, try editor.handleByte(0x10));
    try std.testing.expectEqual(Outcome.history_next, try editor.handleByte(0x0e));
    try std.testing.expectEqual(Outcome.history_search, try editor.handleByte(0x12));
    try std.testing.expectEqualStrings("draft", editor.bytes());
}

test "escape decoder recognizes editing keys and paste begin" {
    try std.testing.expectEqual(EscapeAction.move_left, decodeEscape("[D").action);
    try std.testing.expectEqual(EscapeAction.line_start, decodeEscape("[1~").action);
    try std.testing.expectEqual(EscapeAction.delete_forward, decodeEscape("[3~").action);
    try std.testing.expectEqual(EscapeAction.page_up, decodeEscape("[5;2^").action);
    try std.testing.expectEqual(EscapeAction.page_down, decodeEscape("[6~").action);
    try std.testing.expectEqual(EscapeAction.history_previous, decodeEscape("[a").action);
    try std.testing.expectEqual(EscapeAction.move_word_left, decodeEscape("O1;5D").action);
    try std.testing.expectEqual(EscapeAction.move_word_left, decodeEscape("[1;5;2D").action);
    try std.testing.expectEqual(EscapeAction.line_start, decodeEscape("[7$").action);
    try std.testing.expectEqual(EscapeAction.line_end, decodeEscape("[8$").action);
    try std.testing.expectEqual(EscapeAction.delete_forward, decodeEscape("[3$").action);
    try std.testing.expectEqual(EscapeAction.history_next, decodeEscape("\x1b\x1b[B").action);
    try std.testing.expectEqual(EscapeAction.paste_begin, decodeEscape("[200~tail").action);
    try std.testing.expectEqual(@as(usize, 0), decodeEscape("[20").consumed);
}

fn pasteAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var collector = PasteCollector.init(allocator, 64);
    defer collector.deinit();
    _ = try collector.feed("paste body\x1b[201~");
}

test "paste collector allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        pasteAllocationFailureCase,
        .{},
    );
}

test "partial paste finish retains marker prefix and normalizes CR" {
    var collector = PasteCollector.init(std.testing.allocator, 64);
    defer collector.deinit();
    _ = try collector.feed("a\r\x1b[20");
    try collector.finishPartial();
    try std.testing.expectEqualStrings("a\n\x1b[20", collector.bytes());
    try std.testing.expectEqual(@as(u3, 0), collector.marker_len);
    try std.testing.expect(!collector.pending_cr);
}

test "bounded paste normalizes and drains through its marker" {
    var collector = PasteCollector.init(std.testing.allocator, 5);
    defer collector.deinit();
    var result = try collector.feed("a\r");
    try std.testing.expect(!result.complete);
    result = try collector.feed("\nb\x00cdef\x1b[20");
    try std.testing.expect(!result.complete);
    result = try collector.feed("1~tail");
    try std.testing.expect(result.complete);
    try std.testing.expectEqual(@as(usize, 2), result.consumed);
    try std.testing.expectEqualStrings("a\nb c", collector.bytes());
    try std.testing.expect(collector.truncated);
}
