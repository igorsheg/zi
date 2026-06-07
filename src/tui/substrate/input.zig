const std = @import("std");

pub const input_read_size_max = events_per_feed_max;
pub const escape_sequence_size_max = 64;
pub const events_per_feed_max = 128;

pub const FeedStatus = struct { count: usize, overflow: bool = false, truncated: bool = false };
pub const Key = union(enum) {
    escape,
    enter,
    tab,
    backtab,
    backspace,
    delete,
    arrow_up,
    arrow_down,
    arrow_left,
    arrow_right,
    home,
    end,
    page_up,
    page_down,
    function: u8,
    ctrl: u8,
    alt: u21,
};
pub const InputEvent = union(enum) {
    key: Key,
    text: InlineBytes,
    paste_begin,
    paste_end,
    focus_in,
    focus_out,
    mouse: InlineBytes,
    unknown: InlineBytes,
    malformed: InlineBytes,
    truncated: InlineBytes,
};
pub const InlineBytes = struct {
    len: u8 = 0,
    bytes: [escape_sequence_size_max]u8 = undefined,
    pub fn from(data: []const u8) InlineBytes {
        var v: InlineBytes = .{};
        const n = @min(data.len, v.bytes.len);
        @memcpy(v.bytes[0..n], data[0..n]);
        v.len = @intCast(n);
        return v;
    }
    pub fn slice(self: *const InlineBytes) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const InputDecoder = struct {
    seq: [escape_sequence_size_max]u8 = undefined,
    len: usize = 0,
    utf8: [4]u8 = undefined,
    utf8_len: usize = 0,
    utf8_expected: usize = 0,

    pub fn feed(self: *InputDecoder, bytes: []const u8, out: []InputEvent) FeedStatus {
        var st: FeedStatus = .{ .count = 0 };
        var i: usize = 0;
        while (i < bytes.len) {
            if (st.count >= out.len) {
                st.overflow = true;
                break;
            }
            if (self.utf8_len > 0) {
                const result = self.appendPendingUtf8(bytes[i]);
                if (result.event) |event| {
                    out[st.count] = event;
                    st.count += 1;
                }
                if (result.consumed) i += 1;
                continue;
            }

            const b = bytes[i];
            if (self.len > 0 or b == 0x1b) {
                if (self.len == self.seq.len) {
                    out[st.count] = .{ .truncated = InlineBytes.from(self.seq[0..self.len]) };
                    st.count += 1;
                    self.len = 0;
                    st.truncated = true;
                    continue;
                }
                self.seq[self.len] = b;
                self.len += 1;
                i += 1;
                if (self.tryComplete()) |event| {
                    out[st.count] = event;
                    st.count += 1;
                    self.len = 0;
                }
                continue;
            }
            if (tryStartPendingUtf8(b)) |expected| {
                self.utf8[0] = b;
                self.utf8_len = 1;
                self.utf8_expected = expected;
                i += 1;
                continue;
            }
            out[st.count] = parseGround(bytes[i .. i + 1]);
            i += 1;
            st.count += 1;
        }
        return st;
    }

    pub fn flushIncomplete(self: *InputDecoder, out: []InputEvent) usize {
        if (out.len == 0) return 0;
        if (self.utf8_len > 0) {
            out[0] = .{ .malformed = InlineBytes.from(self.utf8[0..self.utf8_len]) };
            self.utf8_len = 0;
            self.utf8_expected = 0;
            return 1;
        }
        if (self.len == 0) return 0;
        out[0] = if (self.len == 1 and self.seq[0] == 0x1b)
            .{ .key = .escape }
        else
            .{ .unknown = InlineBytes.from(self.seq[0..self.len]) };
        self.len = 0;
        return 1;
    }

    fn appendPendingUtf8(self: *InputDecoder, byte: u8) Utf8AppendResult {
        if (!isUtf8Continuation(byte)) {
            const event: InputEvent = .{ .malformed = InlineBytes.from(self.utf8[0..self.utf8_len]) };
            self.utf8_len = 0;
            self.utf8_expected = 0;
            return .{ .event = event, .consumed = false };
        }

        self.utf8[self.utf8_len] = byte;
        self.utf8_len += 1;
        if (self.utf8_len < self.utf8_expected) return .{ .event = null, .consumed = true };

        const slice = self.utf8[0..self.utf8_len];
        const event: InputEvent = if (std.unicode.utf8ValidateSlice(slice))
            .{ .text = InlineBytes.from(slice) }
        else
            .{ .malformed = InlineBytes.from(slice) };
        self.utf8_len = 0;
        self.utf8_expected = 0;
        return .{ .event = event, .consumed = true };
    }

    fn tryComplete(self: *InputDecoder) ?InputEvent {
        const s = self.seq[0..self.len];
        if (s.len == 1) return null;
        if (s[0] != 0x1b) return .{ .unknown = InlineBytes.from(s) };
        if (s.len == 2 and s[1] != '[' and s[1] != 'O' and s[1] != ']') {
            return if (s[1] < 0x80)
                .{ .key = .{ .alt = s[1] } }
            else
                .{ .unknown = InlineBytes.from(s) };
        }
        if (s[1] == 'O' and s.len == 3) return .{ .key = .{ .function = switch (s[2]) {
            'P' => 1,
            'Q' => 2,
            'R' => 3,
            'S' => 4,
            else => 0,
        } } };
        if (s[1] == ']') return if (s[s.len - 1] == 0x07) .{ .unknown = InlineBytes.from(s) } else null;
        if (s[1] != '[') return null;
        const last = s[s.len - 1];
        if (!std.ascii.isAlphabetic(last) and last != '~') return null;
        return parseCsi(s);
    }
};

const Utf8AppendResult = struct {
    event: ?InputEvent,
    consumed: bool,
};

fn isUtf8Continuation(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

fn tryStartPendingUtf8(first: u8) ?usize {
    if (first < 0x80) return null;
    if ((first & 0xe0) == 0xc0) return 2;
    if ((first & 0xf0) == 0xe0) return 3;
    if ((first & 0xf8) == 0xf0) return 4;
    return null;
}

fn parseGround(b: []const u8) InputEvent {
    const c = b[0];
    if (c == '\r' or c == '\n') return .{ .key = .enter };
    if (c == '\t') return .{ .key = .tab };
    if (c == 0x7f) return .{ .key = .backspace };
    if (c > 0 and c < 0x20) return .{ .key = .{ .ctrl = c } };
    if (c < 0x80 or b.len > 1) return .{ .text = InlineBytes.from(b) };
    return .{ .malformed = InlineBytes.from(b) };
}
fn parseCsi(s: []const u8) InputEvent {
    if (std.mem.eql(u8, s, "\x1b[A")) return .{ .key = .arrow_up };
    if (std.mem.eql(u8, s, "\x1b[B")) return .{ .key = .arrow_down };
    if (std.mem.eql(u8, s, "\x1b[C")) return .{ .key = .arrow_right };
    if (std.mem.eql(u8, s, "\x1b[D")) return .{ .key = .arrow_left };
    if (std.mem.eql(u8, s, "\x1b[Z")) return .{ .key = .backtab };
    if (std.mem.eql(u8, s, "\x1b[I")) return .focus_in;
    if (std.mem.eql(u8, s, "\x1b[O")) return .focus_out;
    if (std.mem.eql(u8, s, "\x1b[200~")) return .paste_begin;
    if (std.mem.eql(u8, s, "\x1b[201~")) return .paste_end;
    if (std.mem.eql(u8, s, "\x1b[3~")) return .{ .key = .delete };
    if (std.mem.eql(u8, s, "\x1b[5~")) return .{ .key = .page_up };
    if (std.mem.eql(u8, s, "\x1b[6~")) return .{ .key = .page_down };
    return .{ .unknown = InlineBytes.from(s) };
}

test "input decoder split csi focus paste alt trunc flush" {
    var d: InputDecoder = .{};
    var ev: [4]InputEvent = undefined;
    try std.testing.expectEqual(@as(usize, 0), d.feed("\x1b[", &ev).count);
    try std.testing.expectEqual(@as(usize, 1), d.feed("A", &ev).count);
    try std.testing.expect(ev[0].key == .arrow_up);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b[200~", &ev).count);
    try std.testing.expect(ev[0] == .paste_begin);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1ba", &ev).count);
    try std.testing.expect(ev[0].key == .alt);
    try std.testing.expectEqual(@as(usize, 1), d.feed("中", &ev).count);
    try std.testing.expectEqualStrings("中", ev[0].text.slice());
    try std.testing.expectEqual(@as(usize, 1), d.feed("\xff", &ev).count);
    try std.testing.expect(ev[0] == .malformed);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b[O", &ev).count);
    try std.testing.expect(ev[0] == .focus_out);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b", &ev).count + d.flushIncomplete(&ev));
    try std.testing.expect(ev[0].key == .escape);
}

test "input decoder maps page keys" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b[5~", &ev).count);
    try std.testing.expect(ev[0].key == .page_up);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b[6~", &ev).count);
    try std.testing.expect(ev[0].key == .page_down);
}

test "input decoder maps ctrl-c byte" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 1), d.feed("\x03", &ev).count);
    try std.testing.expectEqual(@as(u8, 0x03), ev[0].key.ctrl);
}

test "input decoder buffers utf8 scalar across feeds" {
    var d: InputDecoder = .{};
    var ev: [2]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 0), d.feed("\xe4", &ev).count);
    try std.testing.expectEqual(@as(usize, 0), d.feed("\xb8", &ev).count);
    try std.testing.expectEqual(@as(usize, 1), d.feed("\xad", &ev).count);
    try std.testing.expectEqualStrings("中", ev[0].text.slice());
}

test "input decoder flushes incomplete utf8 as malformed" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 0), d.feed("\xe4\xb8", &ev).count);
    try std.testing.expectEqual(@as(usize, 1), d.flushIncomplete(&ev));
    try std.testing.expect(ev[0] == .malformed);
    try std.testing.expectEqualStrings("\xe4\xb8", ev[0].malformed.slice());
}

test "input decoder reprocesses byte after invalid utf8 continuation" {
    var d: InputDecoder = .{};
    var ev: [2]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 0), d.feed("\xe4", &ev).count);
    try std.testing.expectEqual(@as(usize, 2), d.feed("a", &ev).count);
    try std.testing.expect(ev[0] == .malformed);
    try std.testing.expectEqualStrings("a", ev[1].text.slice());
}

test "input decoder keeps incomplete csi buffered until final byte" {
    var d: InputDecoder = .{};
    var ev: [2]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 0), d.feed("\x1b[3", &ev).count);
    try std.testing.expectEqual(@as(usize, 1), d.feed("~", &ev).count);
    try std.testing.expect(ev[0].key == .delete);
}

test "input decoder consumes unknown complete csi" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 1), d.feed("\x1b[?25h", &ev).count);
    try std.testing.expect(ev[0] == .unknown);
    try std.testing.expectEqualStrings("\x1b[?25h", ev[0].unknown.slice());

    try std.testing.expectEqual(@as(usize, 1), d.feed("a", &ev).count);
    try std.testing.expectEqualStrings("a", ev[0].text.slice());
}

test "input decoder reports output overflow without dropping decoder state" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;

    const status = d.feed("ab", &ev);
    try std.testing.expectEqual(@as(usize, 1), status.count);
    try std.testing.expect(status.overflow);
    try std.testing.expectEqualStrings("a", ev[0].text.slice());

    try std.testing.expectEqual(@as(usize, 1), d.feed("c", &ev).count);
    try std.testing.expectEqualStrings("c", ev[0].text.slice());
}

test "input decoder reports oversized escape as truncated" {
    var d: InputDecoder = .{};
    var ev: [1]InputEvent = undefined;
    var bytes: [escape_sequence_size_max + 1]u8 = undefined;
    @memset(&bytes, '0');
    bytes[0] = 0x1b;
    bytes[1] = '[';

    const status = d.feed(&bytes, &ev);
    try std.testing.expectEqual(@as(usize, 1), status.count);
    try std.testing.expect(status.truncated);
    try std.testing.expect(ev[0] == .truncated);
    try std.testing.expectEqual(@as(usize, escape_sequence_size_max), ev[0].truncated.slice().len);
}

test "input decoder maps bracketed paste boundaries" {
    var d: InputDecoder = .{};
    var ev: [2]InputEvent = undefined;

    try std.testing.expectEqual(@as(usize, 2), d.feed("\x1b[200~\x1b[201~", &ev).count);
    try std.testing.expect(ev[0] == .paste_begin);
    try std.testing.expect(ev[1] == .paste_end);
}
