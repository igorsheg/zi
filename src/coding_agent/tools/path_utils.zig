//! Tool result/output helpers. Tool operand path policy lives in
//! `src/coding_agent/paths.zig` under `ToolPaths`.
const std = @import("std");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const runtime = @import("../../runtime/root.zig");

const utf8_replacement = "\u{fffd}";

/// Wrap owned text (ownership transfers) into a single-content tool result.
/// Tool result text is model/runtime data, so invalid process/file bytes are
/// replaced before they can enter the transcript or public protocol.
pub fn ownedTextResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    details: ?std.json.Value,
) !agent.ToolExecutionResult {
    var owned_text: []const u8 = text;
    errdefer allocator.free(owned_text);
    owned_text = try sanitizeOwnedUtf8(allocator, owned_text);
    const content = try allocator.alloc(ai.ToolResultContent, 1);
    content[0] = .{ .text = .{ .text = owned_text } };
    return .{ .allocator = allocator, .result = .{ .content = content, .details = details } };
}

pub fn dupSanitizedUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    return sanitizeOwnedUtf8(allocator, try allocator.dupe(u8, text));
}

fn sanitizeOwnedUtf8(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text)) return text;

    var sanitized: std.ArrayList(u8) = .empty;
    errdefer sanitized.deinit(allocator);
    var index: usize = 0;
    while (index < text.len) {
        const byte = text[index];
        if (byte < 0x80) {
            try sanitized.append(allocator, byte);
            index += 1;
            continue;
        }
        const sequence_len = std.unicode.utf8ByteSequenceLength(byte) catch {
            try sanitized.appendSlice(allocator, utf8_replacement);
            index += 1;
            continue;
        };
        if (index + sequence_len > text.len or
            !std.unicode.utf8ValidateSlice(text[index .. index + sequence_len]))
        {
            try sanitized.appendSlice(allocator, utf8_replacement);
            index += 1;
            continue;
        }
        try sanitized.appendSlice(allocator, text[index .. index + sequence_len]);
        index += sequence_len;
    }

    const owned = try sanitized.toOwnedSlice(allocator);
    allocator.free(text);
    return owned;
}

pub fn textResult(
    allocator: std.mem.Allocator,
    text: []const u8,
    details: ?std.json.Value,
) !agent.ToolExecutionResult {
    return ownedTextResult(allocator, try allocator.dupe(u8, text), details);
}

pub fn errorResult(
    allocator: std.mem.Allocator,
    reason: []const u8,
    message: []const u8,
) !agent.ToolExecutionResult {
    const details = try jsonDetails(allocator, .{
        .isError = true,
        .reason = reason,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    return textResult(allocator, message, details);
}

pub fn errorResultFmt(
    allocator: std.mem.Allocator,
    comptime fmt: []const u8,
    reason: []const u8,
    args: anytype,
) !agent.ToolExecutionResult {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    var message_owned = true;
    errdefer if (message_owned) allocator.free(message);
    const details = try jsonDetails(allocator, .{
        .isError = true,
        .reason = reason,
    });
    errdefer runtime.freeJsonValue(allocator, details);
    message_owned = false;
    return ownedTextResult(allocator, message, details);
}

/// Build an owned `std.json.Value` object from an anonymous struct literal.
/// Field types: bool, integers, string slices/literals (duped), an already
/// owned `std.json.Value` (adopted), and optionals of those (null omitted).
pub fn jsonDetails(allocator: std.mem.Allocator, fields: anytype) error{OutOfMemory}!std.json.Value {
    var object: std.json.ObjectMap = .empty;
    errdefer object.deinit(allocator);
    inline for (@typeInfo(@TypeOf(fields)).@"struct".fields) |field| {
        try putJsonValue(allocator, &object, field.name, @field(fields, field.name));
    }
    return .{ .object = object };
}

fn putJsonValue(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: anytype,
) error{OutOfMemory}!void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => if (value) |resolved| try putJsonValue(allocator, object, key, resolved),
        .bool => try putJsonField(allocator, object, key, .{ .bool = value }),
        .int, .comptime_int => try putJsonField(allocator, object, key, .{ .integer = @intCast(value) }),
        else => if (T == std.json.Value)
            try putJsonField(allocator, object, key, value)
        else
            try putJsonStringField(allocator, object, key, value),
    }
}

pub fn putJsonField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) !void {
    const owned_key = try allocator.dupe(u8, key);
    errdefer allocator.free(owned_key);
    try object.put(allocator, owned_key, value);
}

pub fn putJsonStringField(
    allocator: std.mem.Allocator,
    object: *std.json.ObjectMap,
    key: []const u8,
    value: []const u8,
) !void {
    const owned_value = try allocator.dupe(u8, value);
    errdefer allocator.free(owned_value);
    try putJsonField(allocator, object, key, .{ .string = owned_value });
}

test "owned text result sanitizes invalid utf8" {
    const text = try std.testing.allocator.dupe(u8, "ok\xffgo");
    var result = try ownedTextResult(std.testing.allocator, text, null);
    defer result.deinit();

    try std.testing.expect(std.unicode.utf8ValidateSlice(result.result.content[0].text.text));
    try std.testing.expectEqualStrings("ok�go", result.result.content[0].text.text);
}

test "json details builds typed object and omits null optionals" {
    const nested = try jsonDetails(std.testing.allocator, .{ .truncated = true });
    const details = try jsonDetails(std.testing.allocator, .{
        .count = @as(usize, 3),
        .kind = "bytes",
        .skipped = @as(?usize, null),
        .present = @as(?usize, 7),
        .truncation = nested,
    });
    var owned: agent.ToolExecutionResult = try textResult(std.testing.allocator, "x", details);
    defer owned.deinit();

    const object = owned.result.details.?.object;
    try std.testing.expectEqual(@as(i64, 3), object.get("count").?.integer);
    try std.testing.expectEqualStrings("bytes", object.get("kind").?.string);
    try std.testing.expect(object.get("skipped") == null);
    try std.testing.expectEqual(@as(i64, 7), object.get("present").?.integer);
    try std.testing.expect(object.get("truncation").?.object.get("truncated").?.bool);
}
