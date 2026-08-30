const std = @import("std");

const TokenKind = enum {
    version,
    id_end,
    date,
    word,
};

const Token = struct {
    kind: TokenKind,
    text: []const u8,
};

/// Orders model IDs by family, newest numeric version, and variant kind.
/// The comparison borrows both IDs, allocates nothing, and runs in time bounded
/// by their lengths before applying a deterministic bytewise tie-break.
pub fn lessThan(_: void, left: []const u8, right: []const u8) bool {
    return compare(left, right) == .lt;
}

fn compare(left: []const u8, right: []const u8) std.math.Order {
    var left_cursor: usize = 0;
    var right_cursor: usize = 0;
    while (true) {
        const left_token = nextToken(left, &left_cursor);
        const right_token = nextToken(right, &right_cursor);

        if (left_token.kind != right_token.kind) {
            return std.math.order(@intFromEnum(left_token.kind), @intFromEnum(right_token.kind));
        }
        if (left_token.kind == .id_end) return std.mem.order(u8, left, right);

        const token_order = switch (left_token.kind) {
            .version, .date => compareDigitsNewestFirst(left_token.text, right_token.text),
            .word => compareWords(left_token.text, right_token.text),
            .id_end => unreachable,
        };
        if (token_order != .eq) return token_order;
    }
}

fn nextToken(id: []const u8, cursor: *usize) Token {
    var start = cursor.*;
    while (start < id.len and !isAsciiAlphanumeric(id[start])) start += 1;

    var end = start;
    const kind: TokenKind = if (start == id.len)
        .id_end
    else if (isAsciiDigit(id[start])) kind: {
        while (end < id.len and isAsciiDigit(id[end])) end += 1;
        break :kind if (end - start >= 4) .date else .version;
    } else kind: {
        while (end < id.len and isAsciiLetter(id[end])) end += 1;
        break :kind .word;
    };

    cursor.* = end;
    return .{ .kind = kind, .text = id[start..end] };
}

fn compareDigitsNewestFirst(left: []const u8, right: []const u8) std.math.Order {
    const normalized_left = trimLeadingZeros(left);
    const normalized_right = trimLeadingZeros(right);
    if (normalized_left.len != normalized_right.len) {
        return if (normalized_left.len > normalized_right.len) .lt else .gt;
    }
    return switch (std.mem.order(u8, normalized_left, normalized_right)) {
        .lt => .gt,
        .eq => .eq,
        .gt => .lt,
    };
}

fn trimLeadingZeros(digits: []const u8) []const u8 {
    var start: usize = 0;
    while (digits.len - start > 1 and digits[start] == '0') start += 1;
    return digits[start..];
}

fn compareWords(left: []const u8, right: []const u8) std.math.Order {
    const common_len = @min(left.len, right.len);
    for (left[0..common_len], right[0..common_len]) |left_byte, right_byte| {
        const folded_left = foldAsciiCase(left_byte);
        const folded_right = foldAsciiCase(right_byte);
        if (folded_left != folded_right) return std.math.order(folded_left, folded_right);
    }
    return std.math.order(left.len, right.len);
}

fn isAsciiDigit(byte: u8) bool {
    return byte >= '0' and byte <= '9';
}

fn isAsciiLetter(byte: u8) bool {
    return (byte >= 'a' and byte <= 'z') or (byte >= 'A' and byte <= 'Z');
}

fn isAsciiAlphanumeric(byte: u8) bool {
    return isAsciiDigit(byte) or isAsciiLetter(byte);
}

fn foldAsciiCase(byte: u8) u8 {
    return if (byte >= 'A' and byte <= 'Z') byte + ('a' - 'A') else byte;
}

fn expectOrder(first: []const u8, second: []const u8) !void {
    try std.testing.expect(lessThan({}, first, second));
    try std.testing.expect(!lessThan({}, second, first));
}

const IndexedModel = struct {
    id: []const u8,
    insertion_index: u8,
};

fn lessIndexedModel(_: void, left: IndexedModel, right: IndexedModel) bool {
    return lessThan({}, left.id, right.id);
}

fn expectSorted(scrambled: []const []const u8, expected: []const []const u8) !void {
    var storage: [32][]const u8 = undefined;
    try std.testing.expect(scrambled.len <= storage.len);
    const sorted = storage[0..scrambled.len];
    @memcpy(sorted, scrambled);
    std.mem.sort([]const u8, sorted, {}, lessThan);
    try std.testing.expectEqualSlices([]const u8, expected, sorted);
}

test "version precedes base, snapshot, and named variant" {
    try expectOrder("gpt-5.6", "gpt-5");
    try expectOrder("gpt-5", "gpt-5-2025-08-07");
    try expectOrder("gpt-5-2025-08-07", "gpt-5-mini");
    try expectOrder("gpt-5.6", "gpt-5.6-2026-10-20");
    try expectOrder("gpt-5-mini", "gpt-5-mini-2025-08-07");
}

test "version schemas order alike" {
    try expectOrder("claude-opus-4-8", "claude-opus-4-7");
    try expectOrder("claude-opus-5", "claude-opus-4-8");
    try expectOrder("claude-opus-4-5", "claude-opus-4");
    try expectOrder("kimi-k2.7-code", "kimi-k2.6");
    try expectOrder("qwen3.6-plus", "qwen3.5-plus");
    try expectOrder("minimax-m3", "minimax-m2.7");
}

test "numeric runs do not order lexicographically" {
    try expectOrder("gpt-5.10", "gpt-5.9");
    try expectOrder("babbage-002", "babbage-001");
    try expectOrder("gpt-4o-2024-11-20", "gpt-4o-2024-08-06");
}

test "versions precede words and dates" {
    try expectOrder("grok-4.6", "grok-build-0.1");
    try expectOrder("text-embedding-3-large", "text-embedding-ada-002");
    try expectOrder("gpt-5.4", "gpt-5-2025-08-07");
    try expectOrder("tts-1", "tts-1-1106");
    try expectOrder("tts-1-1106", "tts-1-hd");
    try expectOrder("claude-opus-4-5", "claude-opus-4-5-20251101");
}

test "families group case insensitively" {
    try expectOrder("GLM-5", "glm-4.6");
    try expectOrder("deepseek-v4-pro", "GPT-5");
}

test "raw bytes break equivalent token stream ties" {
    try std.testing.expect(!lessThan({}, "gpt-4.1", "gpt-4.1"));
    try expectOrder("gpt-4-1", "gpt-4.1");
    try std.testing.expect(!lessThan({}, "", ""));
    try expectOrder("", "gpt-5");
    try expectOrder("GLM-5", "glm-5");
}

test "OpenAI-style model list" {
    const scrambled = [_][]const u8{
        "gpt-4",       "o3-mini",     "gpt-5-mini",   "gpt-4.1", "gpt-5.4",          "gpt-4o",
        "gpt-5",       "gpt-4-turbo", "gpt-5.4-pro",  "o4-mini", "gpt-5-2025-08-07", "gpt-4o-mini",
        "gpt-5-codex", "o3",          "gpt-4.1-nano",
    };
    const expected = [_][]const u8{
        "gpt-5.4", "gpt-5.4-pro",  "gpt-5",   "gpt-5-2025-08-07", "gpt-5-codex", "gpt-5-mini",
        "gpt-4.1", "gpt-4.1-nano", "gpt-4",   "gpt-4o",           "gpt-4o-mini", "gpt-4-turbo",
        "o4-mini", "o3",           "o3-mini",
    };
    try expectSorted(&scrambled, &expected);
}

test "Anthropic-style model list" {
    const scrambled = [_][]const u8{
        "claude-opus-5",
        "claude-sonnet-5",
        "claude-fable-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-sonnet-4-6",
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-haiku-4-5-20251001",
        "claude-sonnet-4-5-20250929",
    };
    const expected = [_][]const u8{
        "claude-fable-5",
        "claude-haiku-4-5-20251001",
        "claude-opus-5",
        "claude-opus-4-8",
        "claude-opus-4-7",
        "claude-opus-4-6",
        "claude-opus-4-5-20251101",
        "claude-sonnet-5",
        "claude-sonnet-4-6",
        "claude-sonnet-4-5-20250929",
    };
    try expectSorted(&scrambled, &expected);
}

test "gateway-style model list" {
    const scrambled = [_][]const u8{
        "qwen3.5-plus",
        "minimax-m2.7",
        "glm-5",
        "deepseek-v4-flash-free",
        "kimi-k3",
        "glm-5.2",
        "deepseek-v4-pro",
        "minimax-m3",
        "qwen3.6-plus",
        "kimi-k2.7-code",
        "deepseek-v4-flash",
        "glm-5.1",
        "hy3-preview",
        "hy3",
        "grok-build-0.1",
        "grok-4.6",
    };
    const expected = [_][]const u8{
        "deepseek-v4-flash",
        "deepseek-v4-flash-free",
        "deepseek-v4-pro",
        "glm-5.2",
        "glm-5.1",
        "glm-5",
        "grok-4.6",
        "grok-build-0.1",
        "hy3",
        "hy3-preview",
        "kimi-k3",
        "kimi-k2.7-code",
        "minimax-m3",
        "minimax-m2.7",
        "qwen3.6-plus",
        "qwen3.5-plus",
    };
    try expectSorted(&scrambled, &expected);
}

const order_samples = [_][]const u8{
    "",                         "gpt-5.10",              "gpt-5.9",
    "gpt-5.6",                  "gpt-5",                 "gpt-5-2025-08-07",
    "gpt-5-mini",               "gpt-5-mini-2025-08-07", "gpt-4-1",
    "gpt-4.1",                  "GLM-5",                 "glm-5",
    "glm-4.6",                  "deepseek-v4-pro",       "GPT-5",
    "claude-opus-5",            "claude-opus-4-8",       "claude-opus-4-7",
    "claude-opus-4-5-20251101", "qwen3.6-plus",          "qwen3.5-plus",
    "minimax-m3",               "minimax-m2.7",          "tts-1",
    "tts-1-1106",               "tts-1-hd",              "babbage-002",
    "babbage-001",              "hy3",                   "hy3-preview",
};

test "comparator is a strict total order over representative IDs" {
    for (order_samples) |left| {
        for (order_samples) |right| {
            const left_before_right = lessThan({}, left, right);
            const right_before_left = lessThan({}, right, left);
            try std.testing.expect(!(left_before_right and right_before_left));
            if (std.mem.eql(u8, left, right)) {
                try std.testing.expect(!left_before_right);
                try std.testing.expect(!right_before_left);
            } else {
                try std.testing.expect(left_before_right != right_before_left);
            }
        }
    }

    for (order_samples) |first| {
        for (order_samples) |second| {
            if (!lessThan({}, first, second)) continue;
            for (order_samples) |third| {
                if (lessThan({}, second, third)) {
                    try std.testing.expect(lessThan({}, first, third));
                }
            }
        }
    }
}

test "stable sort preserves equivalent model IDs" {
    var models = [_]IndexedModel{
        .{ .id = "gpt-5", .insertion_index = 0 },
        .{ .id = "gpt-5.4", .insertion_index = 1 },
        .{ .id = "gpt-5", .insertion_index = 2 },
        .{ .id = "gpt-4", .insertion_index = 3 },
        .{ .id = "gpt-5", .insertion_index = 4 },
    };
    std.mem.sort(IndexedModel, &models, {}, lessIndexedModel);

    const expected_indices = [_]u8{ 1, 0, 2, 4, 3 };
    for (models, expected_indices) |model, expected_index| {
        try std.testing.expectEqual(expected_index, model.insertion_index);
    }
}
