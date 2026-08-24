const std = @import("std");

pub const default_max_file_bytes: usize = 8 * 1024 * 1024;
pub const default_max_line_bytes: usize = 8 * 1024 * 1024;
pub const default_max_tokens: usize = 262_144;
pub const default_max_nesting: usize = 64;
pub const default_max_turns: usize = 4096;

pub const Limits = struct {
    max_file_bytes: usize = default_max_file_bytes,
    max_line_bytes: usize = default_max_line_bytes,
    max_tokens: usize = default_max_tokens,
    max_nesting: usize = default_max_nesting,
    max_turns: usize = default_max_turns,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    FileTooLarge,
    LineTooLarge,
    TooManyTokens,
    TooDeep,
    TooManyTurns,
};

const LineKind = enum {
    other,
    boundary,
    typed_prompt,
};

/// Returns the byte offset at which a session should be cut to retain
/// `keep_turns` typed turns. The returned offset always refers to `jsonl`.
/// Malformed JSON records are ignored. Resource-limit failures are reported.
pub fn findCut(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
    keep_turns: usize,
    limits: Limits,
) Error!usize {
    try validateLimits(limits);
    if (jsonl.len > limits.max_file_bytes) return error.FileTooLarge;

    var cursor: usize = 0;
    var previous_offset: ?usize = null;
    var previous_was_boundary = false;
    var cut_offset: ?usize = null;
    var turn_count: usize = 0;

    while (cursor < jsonl.len) {
        const line_offset = cursor;
        const relative_end = std.mem.findScalar(u8, jsonl[cursor..], '\n');
        const line_end = if (relative_end) |index| cursor + index else jsonl.len;
        const line = jsonl[cursor..line_end];
        cursor = if (relative_end != null) line_end + 1 else jsonl.len;
        if (line.len > limits.max_line_bytes) return error.LineTooLarge;

        const kind = try classifyLine(allocator, line, limits);
        if (kind == .typed_prompt) {
            if (turn_count >= limits.max_turns) return error.TooManyTurns;
            if (turn_count == keep_turns and cut_offset == null) {
                cut_offset = if (previous_was_boundary) previous_offset.? else line_offset;
            }
            turn_count += 1;
        }
        previous_offset = line_offset;
        previous_was_boundary = kind == .boundary;
    }
    return cut_offset orelse jsonl.len;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_file_bytes == 0 or limits.max_file_bytes > default_max_file_bytes or
        limits.max_line_bytes == 0 or limits.max_line_bytes > default_max_line_bytes or
        limits.max_line_bytes > limits.max_file_bytes or
        limits.max_tokens == 0 or limits.max_tokens > default_max_tokens or
        limits.max_nesting == 0 or limits.max_nesting > default_max_nesting or
        limits.max_turns == 0 or limits.max_turns > default_max_turns)
    {
        return error.InvalidLimits;
    }
}

fn classifyLine(allocator: std.mem.Allocator, line: []const u8, limits: Limits) Error!LineKind {
    if (line.len == 0 or !std.unicode.utf8ValidateSlice(line)) return .other;
    if (!try jsonWithinBounds(allocator, line, limits)) return .other;

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .other,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .other;
    const object = parsed.value.object;
    const kind_value = object.get("kind") orelse return .other;
    if (kind_value == .string and std.mem.eql(u8, kind_value.string, "turn_boundary")) {
        return .boundary;
    }
    if (kind_value != .string or !std.mem.eql(u8, kind_value.string, "user")) return .other;

    const origin = object.get("origin") orelse return .typed_prompt;
    if (origin != .string) return .typed_prompt;
    const text = origin.string;
    const synthetic = std.mem.eql(u8, text, "compact_seed") or
        std.mem.eql(u8, text, "continuation") or
        std.mem.eql(u8, text, "interrupted") or
        std.mem.eql(u8, text, "skipped") or
        std.mem.eql(u8, text, "refused") or
        std.mem.eql(u8, text, "summarized") or
        std.mem.eql(u8, text, "task_note");
    return if (synthetic) .other else .typed_prompt;
}

fn jsonWithinBounds(allocator: std.mem.Allocator, line: []const u8, limits: Limits) Error!bool {
    var scanner = std.json.Scanner.initCompleteInput(allocator, line);
    defer scanner.deinit();
    var depth: usize = 0;
    var tokens: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.max_line_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        defer if (token == .allocated_string) allocator.free(token.allocated_string);
        tokens += 1;
        if (tokens > limits.max_tokens) return error.TooManyTokens;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_nesting) return error.TooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return false;
                depth -= 1;
            },
            .end_of_document => return depth == 0,
            else => {},
        }
    }
}

const header = "{\"type\":\"session\"}\n";
const boundary = "{\"kind\":\"turn_boundary\"}\n";
const user = "{\"kind\":\"user\",\"text\":\"u\"}\n";
const assistant = "{\"kind\":\"assistant\",\"text\":\"a\"}\n";

fn offsetOf(haystack: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, haystack, needle).?;
}

test "three turns retain responses and cut before adjacent boundary" {
    const data = header ++ user ++ assistant ++ boundary ++ user ++ assistant ++ boundary ++ user ++ assistant;
    try std.testing.expectEqual(header.len, try findCut(std.testing.allocator, data, 0, .{}));
    const third_boundary = offsetOf(data, boundary ++ user ++ assistant ++ boundary) +
        boundary.len + user.len + assistant.len;
    try std.testing.expectEqual(third_boundary, try findCut(std.testing.allocator, data, 2, .{}));
    try std.testing.expectEqual(data.len, try findCut(std.testing.allocator, data, 3, .{}));
    try std.testing.expectEqual(data.len, try findCut(std.testing.allocator, data, 20, .{}));
}

test "only an immediately adjacent boundary moves the cut" {
    const adjacent = header ++ user ++ assistant ++ boundary ++ user;
    try std.testing.expectEqual(offsetOf(adjacent, boundary), try findCut(std.testing.allocator, adjacent, 1, .{}));

    const separated = header ++ user ++ assistant ++ boundary ++ "not json\n" ++ user;
    const expected = offsetOf(separated, user) + user.len + assistant.len + boundary.len + "not json\n".len;
    try std.testing.expectEqual(
        expected,
        try findCut(std.testing.allocator, separated, 1, .{}),
    );
}

test "invalid JSON and recognized synthetic users do not count while unknown origins do" {
    const synthetic_unknown = "{\"kind\":\"user\",\"origin\":\"synthetic\"}\n";
    const data = header ++
        "{broken\n" ++
        "{\"kind\":\"user\",\"origin\":\"steering\"}\n" ++
        "{\"kind\":\"user\",\"origin\":\"compact_seed\"}\n" ++
        synthetic_unknown ++ user;
    try std.testing.expectEqual(
        offsetOf(data, synthetic_unknown),
        try findCut(std.testing.allocator, data, 1, .{}),
    );
}

test "CRLF and a valid torn final record preserve byte offsets" {
    const data = "{\"type\":\"session\"}\r\n{\"kind\":\"user\"}\r\n{\"kind\":\"assistant\"}\r\n{\"kind\":\"user\"}";
    const second = std.mem.lastIndexOf(u8, data, "{\"kind\":\"user\"}").?;
    try std.testing.expectEqual(second, try findCut(std.testing.allocator, data, 1, .{}));
    try std.testing.expectEqual(data.len, try findCut(std.testing.allocator, data, 2, .{}));
}

test "duplicate fields use last and null origin is ordinary" {
    const data = header ++
        "{\"kind\":\"assistant\",\"kind\":\"user\",\"origin\":\"synthetic\",\"origin\":null}\n" ++
        "{\"kind\":\"user\",\"origin\":\"none\"}\n" ++
        "{\"kind\":\"user\",\"origin\":null,\"origin\":\"synthetic\"}\n" ++ user;
    const unknown_origin = std.mem.indexOf(u8, data, "{\"kind\":\"user\",\"origin\":null,\"origin\":\"synthetic\"}").?;
    try std.testing.expectEqual(unknown_origin, try findCut(std.testing.allocator, data, 2, .{}));
}

test "file line JSON and turn limits are explicit" {
    try std.testing.expectError(error.FileTooLarge, findCut(std.testing.allocator, "12345", 0, .{
        .max_file_bytes = 4,
        .max_line_bytes = 4,
    }));
    try std.testing.expectError(error.LineTooLarge, findCut(std.testing.allocator, "12345", 0, .{
        .max_file_bytes = 5,
        .max_line_bytes = 4,
    }));
    try std.testing.expectError(error.TooDeep, findCut(std.testing.allocator, "[[1]]", 0, .{
        .max_file_bytes = 5,
        .max_line_bytes = 5,
        .max_nesting = 1,
    }));
    try std.testing.expectError(error.TooManyTokens, findCut(std.testing.allocator, "[1,2]", 0, .{
        .max_file_bytes = 5,
        .max_line_bytes = 5,
        .max_tokens = 2,
    }));
    try std.testing.expectError(error.TooManyTurns, findCut(std.testing.allocator, user ++ user, 10, .{
        .max_file_bytes = (user ++ user).len,
        .max_line_bytes = user.len,
        .max_turns = 1,
    }));
    try std.testing.expectError(error.InvalidLimits, findCut(std.testing.allocator, "", 0, .{ .max_turns = 0 }));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const data = header ++ "{\"kind\":\"user\",\"unused\":[\"a\\nb\"]}\n" ++ user;
    _ = try findCut(allocator, data, 1, .{});
}

test "allocation failures are returned without leaks" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
