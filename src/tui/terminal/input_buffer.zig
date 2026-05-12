const std = @import("std");
const keys_mod = @import("keys.zig");

pub const InputBuffer = struct {
    buf: std.ArrayListUnmanaged(u8) = .empty,
    allocator: std.mem.Allocator,

    flush_deadline_ns: ?i128 = null,
    timeout_ns: i128 = 10_000_000,

    in_paste: bool = false,
    paste_buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn init(allocator: std.mem.Allocator) InputBuffer {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *InputBuffer) void {
        self.buf.deinit(self.allocator);
        self.paste_buf.deinit(self.allocator);
    }

    pub fn feed(
        self: *InputBuffer,
        data: []const u8,
        on_seq: *const fn (seq: []const u8, ctx: *anyopaque) void,
        on_paste: *const fn (content: []const u8, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        self.buf.appendSlice(self.allocator, data) catch return;
        self.flush_deadline_ns = null;
        self.drain(on_seq, on_paste, ctx);
    }

    pub fn checkTimeout(
        self: *InputBuffer,
        on_seq: *const fn (seq: []const u8, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (self.flush_deadline_ns) |deadline| {
            if (@as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) >= deadline) {
                self.flush_deadline_ns = null;
                if (self.buf.items.len > 0) {
                    self.flushRaw(on_seq, ctx);
                }
            }
        }
    }

    pub fn drain(
        self: *InputBuffer,
        on_seq: *const fn (seq: []const u8, ctx: *anyopaque) void,
        on_paste: *const fn (content: []const u8, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        while (self.buf.items.len > 0) {
            if (self.in_paste) {
                if (std.mem.indexOf(u8, self.buf.items, "\x1b[201~")) |end_pos| {
                    self.paste_buf.appendSlice(self.allocator, self.buf.items[0..end_pos]) catch {};
                    on_paste(self.paste_buf.items, ctx);
                    self.paste_buf.items.len = 0;
                    self.in_paste = false;
                    const after = end_pos + 6;
                    if (after < self.buf.items.len) {
                        std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[after..]);
                        self.buf.items.len -= after;
                    } else {
                        self.buf.items.len = 0;
                    }
                    continue;
                } else {
                    self.paste_buf.appendSlice(self.allocator, self.buf.items) catch {};
                    self.buf.items.len = 0;
                    return;
                }
            }

            if (self.buf.items.len >= 6 and std.mem.eql(u8, self.buf.items[0..6], "\x1b[200~")) {
                self.in_paste = true;
                self.paste_buf.items.len = 0;
                if (self.buf.items.len > 6) {
                    std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[6..]);
                    self.buf.items.len -= 6;
                } else {
                    self.buf.items.len = 0;
                }
                continue;
            }
            if (self.buf.items[0] == 0x1b and self.buf.items.len < 6) {
                if (std.mem.startsWith(u8, "\x1b[200~", self.buf.items)) {
                    self.flush_deadline_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + self.timeout_ns;
                    return;
                }
            }

            if (self.buf.items[0] == 0x1b) {
                const status = classifyEscapeSequence(self.buf.items);
                switch (status) {
                    .complete => |len| {
                        on_seq(self.buf.items[0..len], ctx);
                        self.consume(len);
                    },
                    .incomplete => {
                        self.flush_deadline_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds())) + self.timeout_ns;
                        return;
                    },
                }
            } else {
                on_seq(self.buf.items[0..1], ctx);
                self.consume(1);
            }
        }
    }

    fn flushRaw(
        self: *InputBuffer,
        on_seq: *const fn (seq: []const u8, ctx: *anyopaque) void,
        ctx: *anyopaque,
    ) void {
        if (self.buf.items.len == 1 and self.buf.items[0] == 0x1b) {
            on_seq(self.buf.items[0..1], ctx);
            self.buf.items.len = 0;
            return;
        }
        while (self.buf.items.len > 0) {
            on_seq(self.buf.items[0..1], ctx);
            self.consume(1);
        }
    }

    fn consume(self: *InputBuffer, n: usize) void {
        if (n >= self.buf.items.len) {
            self.buf.items.len = 0;
        } else {
            std.mem.copyForwards(u8, self.buf.items[0..], self.buf.items[n..]);
            self.buf.items.len -= n;
        }
    }

    pub fn consumeKittyResponse(self: *InputBuffer) bool {
        const prefix = "\x1b[?";
        const start = std.mem.indexOf(u8, self.buf.items, prefix) orelse return false;
        const after_prefix = start + prefix.len;
        if (after_prefix >= self.buf.items.len) return false;

        var i = after_prefix;
        while (i < self.buf.items.len and self.buf.items[i] >= '0' and self.buf.items[i] <= '9') : (i += 1) {}
        if (i >= self.buf.items.len or self.buf.items[i] != 'u') return false;

        const response_end = i + 1;
        if (response_end < self.buf.items.len) {
            std.mem.copyForwards(u8, self.buf.items[start..], self.buf.items[response_end..]);
            self.buf.items.len -= (response_end - start);
        } else {
            self.buf.items.len = start;
        }
        return true;
    }
};

const SeqStatus = union(enum) {
    complete: usize,
    incomplete,
};

fn classifyEscapeSequence(data: []const u8) SeqStatus {
    if (data.len < 2) return .incomplete;

    switch (data[1]) {
        '[' => return classifyCsi(data),
        'O' => {
            if (data.len < 3) return .incomplete;
            return .{ .complete = 3 };
        },
        ']' => {
            return classifyStringTerminated(data, 2, true);
        },
        'P' => {
            return classifyStringTerminated(data, 2, false);
        },
        '_' => {
            return classifyStringTerminated(data, 2, false);
        },
        else => {
            return .{ .complete = 2 };
        },
    }
}

fn classifyCsi(data: []const u8) SeqStatus {
    if (data.len < 3) return .incomplete;

    if (data.len >= 3 and data[2] == 'M') {
        if (data.len < 6) return .incomplete;
        return .{ .complete = 6 };
    }

    var i: usize = 2;
    while (i < data.len) : (i += 1) {
        const c = data[i];
        if (c >= 0x40 and c <= 0x7E) {
            return .{ .complete = i + 1 };
        }
        if (c < 0x20 or c > 0x7E) {
            return .{ .complete = i + 1 };
        }
    }
    return .incomplete;
}

fn classifyStringTerminated(data: []const u8, start: usize, allow_bel: bool) SeqStatus {
    var i = start;
    while (i < data.len) : (i += 1) {
        if (allow_bel and data[i] == 0x07) {
            return .{ .complete = i + 1 };
        }
        if (data[i] == 0x1b and i + 1 < data.len and data[i + 1] == '\\') {
            return .{ .complete = i + 2 };
        }
    }
    return .incomplete;
}

const testing = std.testing;

const TestCtx = struct {
    sequences: std.ArrayListUnmanaged([]u8) = .empty,
    pastes: std.ArrayListUnmanaged([]u8) = .empty,
    allocator: std.mem.Allocator,

    fn onSeq(seq: []const u8, raw_ctx: *anyopaque) void {
        const ctx: *TestCtx = @ptrCast(@alignCast(raw_ctx));
        const copy = ctx.allocator.dupe(u8, seq) catch return;
        ctx.sequences.append(ctx.allocator, copy) catch {};
    }

    fn onPaste(content: []const u8, raw_ctx: *anyopaque) void {
        const ctx: *TestCtx = @ptrCast(@alignCast(raw_ctx));
        const copy = ctx.allocator.dupe(u8, content) catch return;
        ctx.pastes.append(ctx.allocator, copy) catch {};
    }

    fn deinit(self: *TestCtx) void {
        for (self.sequences.items) |s| self.allocator.free(s);
        self.sequences.deinit(self.allocator);
        for (self.pastes.items) |p| self.allocator.free(p);
        self.pastes.deinit(self.allocator);
    }

    fn feed(self: *TestCtx, buf: *InputBuffer, data: []const u8) void {
        buf.feed(data, &TestCtx.onSeq, &TestCtx.onPaste, @ptrCast(self));
    }

    fn drain(self: *TestCtx, buf: *InputBuffer) void {
        buf.drain(&TestCtx.onSeq, &TestCtx.onPaste, @ptrCast(self));
    }

    fn checkTimeout(self: *TestCtx, buf: *InputBuffer) void {
        buf.checkTimeout(&TestCtx.onSeq, @ptrCast(self));
    }

    fn expectSequences(self: *const TestCtx, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.sequences.items.len);
        for (expected, 0..) |seq, i| try testing.expectEqualStrings(seq, self.sequences.items[i]);
    }

    fn expectPastes(self: *const TestCtx, expected: []const []const u8) !void {
        try testing.expectEqual(expected.len, self.pastes.items.len);
        for (expected, 0..) |paste, i| try testing.expectEqualStrings(paste, self.pastes.items[i]);
    }
};

test "InputBuffer preserves key sequence boundaries within a feed" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    ctx.feed(&buf, "a\x1b[13;2ub\x1bOA\x1ba");

    try ctx.expectSequences(&.{ "a", "\x1b[13;2u", "b", "\x1bOA", "\x1ba" });
    try ctx.expectPastes(&.{});
}

test "InputBuffer waits for partial escape sequences across feeds" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    ctx.feed(&buf, "\x1b[13");
    try ctx.expectSequences(&.{});

    ctx.feed(&buf, ";2u");
    try ctx.expectSequences(&.{"\x1b[13;2u"});

    ctx.feed(&buf, "\x1b]0;title");
    try ctx.expectSequences(&.{"\x1b[13;2u"});

    ctx.feed(&buf, "\x07");
    try ctx.expectSequences(&.{ "\x1b[13;2u", "\x1b]0;title\x07" });
}

test "InputBuffer keeps mouse report boundaries" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    ctx.feed(&buf, "\x1b[M");
    try ctx.expectSequences(&.{});

    ctx.feed(&buf, " !!x\x1b[<0;10");
    try ctx.expectSequences(&.{ "\x1b[M !!", "x" });

    ctx.feed(&buf, ";20M");
    try ctx.expectSequences(&.{ "\x1b[M !!", "x", "\x1b[<0;10;20M" });
}

test "InputBuffer emits lone ESC after timeout" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    buf.timeout_ns = 0;
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    ctx.feed(&buf, "\x1b");
    try ctx.expectSequences(&.{});
    try testing.expect(buf.flush_deadline_ns != null);

    buf.flush_deadline_ns = 0;
    ctx.checkTimeout(&buf);
    try ctx.expectSequences(&.{"\x1b"});
}

test "InputBuffer handles bracketed paste split across key boundaries" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    ctx.feed(&buf, "a\x1b[200~hello");
    try ctx.expectSequences(&.{"a"});
    try ctx.expectPastes(&.{});

    ctx.feed(&buf, " world\x1b[201~\x1b[13;2u");
    try ctx.expectSequences(&.{ "a", "\x1b[13;2u" });
    try ctx.expectPastes(&.{"hello world"});
}

test "InputBuffer consumes kitty response without taking surrounding input" {
    var buf = InputBuffer.init(testing.allocator);
    defer buf.deinit();
    var ctx = TestCtx{ .allocator = testing.allocator };
    defer ctx.deinit();

    try buf.buf.appendSlice(testing.allocator, "a\x1b[?0ub");
    try testing.expect(buf.consumeKittyResponse());

    ctx.drain(&buf);
    try ctx.expectSequences(&.{ "a", "b" });
}
