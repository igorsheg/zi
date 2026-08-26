const std = @import("std");
const EscapeClassifier = @This();

pub const escape_timeout_ms: u64 = 50;

/// An unterminated CSI sequence may discard at most this many bytes after
/// its introducer. The next byte is classified from the idle state.
pub const max_sequence_bytes: u8 = 64;

pub const Sample = enum {
    none,
    pause,
    abort,
};

const State = enum {
    idle,
    escape_pending,
    csi,
    ss3,
};

state: State = .idle,
pending_elapsed_ms: u64 = 0,
sequence_bytes: u8 = 0,
request: Sample = .none,

pub fn init() EscapeClassifier {
    return .{};
}

/// Clears both byte classification and latched requests.
pub fn reset(classifier: *EscapeClassifier) void {
    classifier.* = .{};
}

/// Returns the strongest request confirmed since initialization or reset.
/// Sampling does not clear a request.
pub fn sample(classifier: *const EscapeClassifier) Sample {
    return classifier.request;
}

/// Reports whether a bare Esc is still inside its classification window.
pub fn isEscapePending(classifier: *const EscapeClassifier) bool {
    return classifier.state == .escape_pending;
}

/// Classifies one input byte. Input that belongs to a terminal escape
/// sequence is consumed and never becomes a request.
pub fn feed(classifier: *EscapeClassifier, byte: u8) void {
    switch (classifier.state) {
        .idle => {
            if (byte == 0x1b) classifier.startCandidate();
        },
        .escape_pending => classifier.feedPending(byte),
        .csi => classifier.feedCsi(byte),
        .ss3 => classifier.finishSequence(),
    }
}

/// Advances only the caller-owned bare-Esc timer. No clock is read here.
/// A candidate is confirmed exactly when its accumulated age reaches 50 ms.
pub fn advance(classifier: *EscapeClassifier, elapsed_ms: u64) void {
    if (classifier.state != .escape_pending) return;

    const remaining_ms = escape_timeout_ms - classifier.pending_elapsed_ms;
    if (elapsed_ms < remaining_ms) {
        classifier.pending_elapsed_ms += elapsed_ms;
        return;
    }

    classifier.confirmCandidate();
    classifier.finishSequence();
}

fn feedPending(classifier: *EscapeClassifier, byte: u8) void {
    if (byte == 0x1b) {
        // Two Esc bytes cannot be one terminal escape sequence. The first
        // is bare and the second starts a fresh timeout window.
        classifier.confirmCandidate();
        classifier.startCandidate();
    } else if (byte == '[') {
        classifier.startSequence(.csi);
    } else if (byte == 'O') {
        classifier.startSequence(.ss3);
    } else {
        // Match the generation watcher: only CSI and SS3 suppress a pending
        // Esc. Every other following byte confirms it and is then ignored.
        classifier.confirmCandidate();
        classifier.finishSequence();
    }
}

fn feedCsi(classifier: *EscapeClassifier, byte: u8) void {
    if (!classifier.reserveSequenceByte(byte)) return;

    // ECMA-48 parameter and intermediate bytes precede one final byte.
    if (byte >= 0x40 and byte <= 0x7e) {
        classifier.finishSequence();
    } else if (byte < 0x20 or byte > 0x3f) {
        classifier.finishSequence();
    }
}

fn reserveSequenceByte(classifier: *EscapeClassifier, byte: u8) bool {
    if (classifier.sequence_bytes < max_sequence_bytes) {
        classifier.sequence_bytes += 1;
        return true;
    }

    // Do not let an unterminated sequence hide arbitrary future input. The
    // overflow byte starts a new candidate when it is itself Esc.
    classifier.finishSequence();
    if (byte == 0x1b) classifier.startCandidate();
    return false;
}

fn startCandidate(classifier: *EscapeClassifier) void {
    classifier.state = .escape_pending;
    classifier.pending_elapsed_ms = 0;
    classifier.sequence_bytes = 0;
}

fn startSequence(classifier: *EscapeClassifier, state: State) void {
    classifier.state = state;
    classifier.pending_elapsed_ms = 0;
    classifier.sequence_bytes = 1;
}

fn finishSequence(classifier: *EscapeClassifier) void {
    classifier.state = .idle;
    classifier.pending_elapsed_ms = 0;
    classifier.sequence_bytes = 0;
}

fn confirmCandidate(classifier: *EscapeClassifier) void {
    classifier.request = switch (classifier.request) {
        .none => .pause,
        .pause, .abort => .abort,
    };
}

fn feedAll(classifier: *EscapeClassifier, bytes: []const u8) void {
    for (bytes) |byte| classifier.feed(byte);
}

test "split CSI and SS3 sequences are discarded" {
    var classifier = init();

    classifier.feed(0x1b);
    classifier.advance(49);
    classifier.feed('[');
    classifier.advance(50);
    feedAll(&classifier, "12;5H");
    try std.testing.expectEqual(Sample.none, classifier.sample());

    classifier.feed(0x1b);
    classifier.feed('O');
    classifier.advance(50);
    classifier.feed('P');
    try std.testing.expectEqual(Sample.none, classifier.sample());
}

test "all non-CSI and non-SS3 followers confirm pending Esc" {
    const followers = [_]u8{ 'c', '(', 0x01, 0x7f, 0xff };
    for (followers) |follower| {
        var classifier = init();
        classifier.feed(0x1b);
        classifier.feed(follower);
        try std.testing.expectEqual(Sample.pause, classifier.sample());
    }
}

test "lone Esc confirms only at the timeout boundary" {
    var classifier = init();

    classifier.feed(0x1b);
    classifier.advance(0);
    classifier.advance(49);
    try std.testing.expectEqual(Sample.none, classifier.sample());

    classifier.advance(1);
    try std.testing.expectEqual(Sample.pause, classifier.sample());
    classifier.advance(std.math.maxInt(u64));
    try std.testing.expectEqual(Sample.pause, classifier.sample());
}

test "Esc Esc confirms pause then timeout confirms abort" {
    var classifier = init();

    classifier.feed(0x1b);
    classifier.advance(49);
    classifier.feed(0x1b);
    try std.testing.expectEqual(Sample.pause, classifier.sample());

    classifier.advance(49);
    try std.testing.expectEqual(Sample.pause, classifier.sample());
    classifier.advance(1);
    try std.testing.expectEqual(Sample.abort, classifier.sample());
}

test "abort dominates later input and samples" {
    var classifier = init();

    classifier.feed(0x1b);
    classifier.advance(50);
    classifier.feed(0x1b);
    classifier.advance(50);
    feedAll(&classifier, "plain\x1b[A");
    classifier.advance(50);
    try std.testing.expectEqual(Sample.abort, classifier.sample());
    try std.testing.expectEqual(Sample.abort, classifier.sample());
}

test "malformed sequences stop consuming and overflow is bounded" {
    var classifier = init();

    // A control byte invalidates CSI without confirming its introducer.
    feedAll(&classifier, "\x1b[12\x01");
    classifier.advance(50);
    try std.testing.expectEqual(Sample.none, classifier.sample());

    classifier.feed(0x1b);
    classifier.feed('[');
    for (0..max_sequence_bytes) |_| classifier.feed('1');
    // This Esc is the first byte after the bound and must be a new candidate.
    classifier.feed(0x1b);
    classifier.advance(49);
    try std.testing.expectEqual(Sample.none, classifier.sample());
    classifier.advance(1);
    try std.testing.expectEqual(Sample.pause, classifier.sample());
}

test "reset clears pending classification and latched requests" {
    var classifier = init();

    classifier.feed(0x1b);
    classifier.advance(50);
    try std.testing.expectEqual(Sample.pause, classifier.sample());

    classifier.feed(0x1b);
    classifier.reset();
    classifier.advance(50);
    try std.testing.expectEqual(Sample.none, classifier.sample());

    classifier.feed(0x1b);
    classifier.advance(50);
    try std.testing.expectEqual(Sample.pause, classifier.sample());
}
