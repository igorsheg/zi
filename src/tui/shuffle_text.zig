const std = @import("std");

/// Small reusable text-shuffle animation for TUI strings.
///
/// The component owns its PRNG, rate-limits itself, and only reports `true` from
/// `tick` when the caller should copy/use `rendered()` and invalidate the UI.
pub const ShuffleText = struct {
    allocator: std.mem.Allocator,
    options: Options,
    prng: std.Random.DefaultPrng,

    original: []const u8 = "",
    original_spans: std.ArrayList(Span) = .empty,
    random_spans: std.ArrayList(Span) = .empty,
    reveal_at: std.ArrayList(u16) = .empty,
    output: std.ArrayList(u8) = .empty,

    running: bool = false,
    start_ms: u64 = 0,
    next_frame_ms: u64 = 0,

    pub const Options = struct {
        /// Total animation duration.
        duration_ms: u64 = 600,

        /// Minimum time between generated frames. 33ms is roughly 30fps.
        frame_ms: u64 = 33,

        /// UTF-8 characters used during the shuffle phase.
        random_chars: []const u8 = "ABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890",

        /// UTF-8 character/string shown before the shuffle phase begins.
        empty_char: []const u8 = "-",

        /// I/O backend used to seed the component when `seed` is null.
        io: std.Io = std.Options.debug_io,

        /// Optional deterministic seed for tests/demos. When null, the component
        /// seeds itself from `io.randomSecure`, falling back to `io.random`.
        seed: ?u64 = null,
    };

    pub const Error = error{
        EmptyRandomCharacterSet,
        InvalidUtf8,
        DurationIsZero,
    } || std.mem.Allocator.Error;

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!ShuffleText {
        if (options.duration_ms == 0) return error.DurationIsZero;

        var self = ShuffleText{
            .allocator = allocator,
            .options = options,
            .prng = std.Random.DefaultPrng.init(options.seed orelse randomSeed(options.io)),
        };
        errdefer self.deinit();

        try self.setRandomChars(options.random_chars);
        try validateUtf8(options.empty_char);

        return self;
    }

    pub fn deinit(self: *ShuffleText) void {
        self.original_spans.deinit(self.allocator);
        self.random_spans.deinit(self.allocator);
        self.reveal_at.deinit(self.allocator);
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    /// The caller owns `text`; keep it alive while this component may render it.
    pub fn setText(self: *ShuffleText, text: []const u8) Error!void {
        self.original = text;
        self.original_spans.clearRetainingCapacity();
        try appendUtf8Spans(self.allocator, &self.original_spans, text);
        try self.reveal_at.resize(self.allocator, self.original_spans.items.len);

        self.output.clearRetainingCapacity();
        try self.output.appendSlice(self.allocator, text);
    }

    pub fn setRandomChars(self: *ShuffleText, chars: []const u8) Error!void {
        self.random_spans.clearRetainingCapacity();
        try appendUtf8Spans(self.allocator, &self.random_spans, chars);
        if (self.random_spans.items.len == 0) return error.EmptyRandomCharacterSet;
        self.options.random_chars = chars;
    }

    pub fn start(self: *ShuffleText, now_ms: u64) Error!void {
        self.running = true;
        self.start_ms = now_ms;
        self.next_frame_ms = now_ms;

        const len = self.original_spans.items.len;
        try self.reveal_at.resize(self.allocator, len);
        if (len == 0) {
            self.running = false;
            return;
        }

        const random = self.prng.random();
        const max = std.math.maxInt(u16);
        for (self.reveal_at.items, 0..) |*slot, i| {
            const rate: u32 = @intCast((i * max) / len);
            const remaining: u32 = max - rate;
            const jitter = random.intRangeLessThan(u32, 0, remaining + 1);
            slot.* = @intCast(rate + jitter);
        }

        self.output.clearRetainingCapacity();
        for (0..len) |_| try self.output.appendSlice(self.allocator, self.options.empty_char);
    }

    pub fn stop(self: *ShuffleText) void {
        self.running = false;
    }

    pub fn isRunning(self: ShuffleText) bool {
        return self.running;
    }

    pub fn rendered(self: ShuffleText) []const u8 {
        return self.output.items;
    }

    /// Advances the animation. Returns true only when `rendered()` changed.
    pub fn tick(self: *ShuffleText, now_ms: u64) Error!bool {
        if (!self.running) return false;
        if (now_ms < self.next_frame_ms) return false;

        self.next_frame_ms = now_ms + self.options.frame_ms;

        const elapsed = now_ms - self.start_ms;
        if (elapsed >= self.options.duration_ms) {
            self.running = false;
            self.output.clearRetainingCapacity();
            try self.output.appendSlice(self.allocator, self.original);
            return true;
        }

        const max = std.math.maxInt(u16);
        const percent: u32 = @intCast((elapsed * max) / self.options.duration_ms);
        const random = self.prng.random();

        self.output.clearRetainingCapacity();
        for (self.original_spans.items, 0..) |span, i| {
            const reveal = self.reveal_at.items[i];
            if (percent >= reveal) {
                try self.output.appendSlice(self.allocator, span.bytes(self.original));
            } else if (percent < reveal / 3) {
                try self.output.appendSlice(self.allocator, self.options.empty_char);
            } else {
                const random_span = self.random_spans.items[random.uintLessThan(usize, self.random_spans.items.len)];
                try self.output.appendSlice(self.allocator, random_span.bytes(self.options.random_chars));
            }
        }

        return true;
    }
};

const Span = struct {
    start: usize,
    len: usize,

    fn bytes(self: Span, source: []const u8) []const u8 {
        return source[self.start .. self.start + self.len];
    }
};

fn randomSeed(io: std.Io) u64 {
    var bytes: [8]u8 = undefined;
    io.randomSecure(&bytes) catch io.random(&bytes);
    return std.mem.readInt(u64, &bytes, .little);
}

fn appendUtf8Spans(allocator: std.mem.Allocator, spans: *std.ArrayList(Span), text: []const u8) ShuffleText.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const len = try utf8SequenceLength(text[i]);
        if (i + len > text.len) return error.InvalidUtf8;
        for (text[i + 1 .. i + len]) |byte| {
            if ((byte & 0b1100_0000) != 0b1000_0000) return error.InvalidUtf8;
        }
        try spans.append(allocator, .{ .start = i, .len = len });
        i += len;
    }
}

fn validateUtf8(text: []const u8) ShuffleText.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const len = try utf8SequenceLength(text[i]);
        if (i + len > text.len) return error.InvalidUtf8;
        for (text[i + 1 .. i + len]) |byte| {
            if ((byte & 0b1100_0000) != 0b1000_0000) return error.InvalidUtf8;
        }
        i += len;
    }
}

fn utf8SequenceLength(byte: u8) error{InvalidUtf8}!usize {
    if (byte < 0x80) return 1;
    if ((byte & 0b1110_0000) == 0b1100_0000) return 2;
    if ((byte & 0b1111_0000) == 0b1110_0000) return 3;
    if ((byte & 0b1111_1000) == 0b1111_0000) return 4;
    return error.InvalidUtf8;
}

test "shuffle text owns randomness and rate limits frames" {
    const testing = std.testing;
    var shuffle = try ShuffleText.init(testing.allocator, .{ .seed = 1 });
    defer shuffle.deinit();

    try shuffle.setText("TEXT");
    try shuffle.start(1000);

    try testing.expectEqualStrings("----", shuffle.rendered());
    try testing.expect(try shuffle.tick(1000));
    try testing.expect(!try shuffle.tick(1001));
    try testing.expect(try shuffle.tick(1033));
    try testing.expect(try shuffle.tick(1600));
    try testing.expectEqualStrings("TEXT", shuffle.rendered());
    try testing.expect(!shuffle.isRunning());
}

test "shuffle text keeps utf8 random characters intact" {
    const testing = std.testing;
    var shuffle = try ShuffleText.init(testing.allocator, .{ .seed = 2, .duration_ms = 1000, .random_chars = "░▒▓█" });
    defer shuffle.deinit();

    try shuffle.setText("abcd");
    try shuffle.start(0);
    _ = try shuffle.tick(400);

    try testing.expect(std.unicode.utf8ValidateSlice(shuffle.rendered()));
}
