const std = @import("std");

const max_initial_message_bytes = 8 * 1024 * 1024;
const max_messages = 64;

pub const Error = error{
    OutOfMemory,
    MessageTooLarge,
    TooManyMessages,
    InvalidUtf8,
};

pub const InitialMessage = struct {
    allocator: std.mem.Allocator,
    text: ?[]const u8,
    remaining_messages: []const []const u8,

    pub fn deinit(self: *InitialMessage) void {
        if (self.text) |text| self.allocator.free(text);
        self.* = undefined;
    }
};

pub fn buildInitialMessage(
    allocator: std.mem.Allocator,
    messages: []const []const u8,
    stdin_content: ?[]const u8,
    file_text: ?[]const u8,
) Error!InitialMessage {
    if (messages.len > max_messages) return error.TooManyMessages;
    const first_message = if (messages.len > 0) messages[0] else null;
    const remaining_messages = if (messages.len > 0) messages[1..] else messages;
    if (stdin_content) |text| if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (file_text) |text| if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (messages) |text| {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (text.len > max_initial_message_bytes) return error.MessageTooLarge;
    }
    var length: usize = 0;
    if (stdin_content) |text| length = try addLength(length, text.len);
    if (file_text) |text| {
        if (text.len > 0) length = try addLength(length, text.len);
    }
    if (first_message) |text| length = try addLength(length, text.len);

    if (stdin_content == null and (file_text == null or file_text.?.len == 0) and first_message == null) {
        return .{ .allocator = allocator, .text = null, .remaining_messages = remaining_messages };
    }

    const combined = allocator.alloc(u8, length) catch return error.OutOfMemory;
    var offset: usize = 0;
    if (stdin_content) |text| appendPart(combined, &offset, text);
    if (file_text) |text| {
        if (text.len > 0) appendPart(combined, &offset, text);
    }
    if (first_message) |text| appendPart(combined, &offset, text);
    return .{ .allocator = allocator, .text = combined, .remaining_messages = remaining_messages };
}

fn addLength(current: usize, additional: usize) error{MessageTooLarge}!usize {
    if (additional > max_initial_message_bytes - current) return error.MessageTooLarge;
    return current + additional;
}

fn appendPart(output: []u8, offset: *usize, part: []const u8) void {
    @memcpy(output[offset.*..][0..part.len], part);
    offset.* += part.len;
}

test "buildInitialMessage combines pi inputs without inventing separators" {
    const messages = [_][]const u8{ "Explain it", "Second message" };
    var initial = try buildInitialMessage(
        std.testing.allocator,
        &messages,
        "stdin\n",
        "file\n",
    );
    defer initial.deinit();

    try std.testing.expectEqualStrings("stdin\nfile\nExplain it", initial.text.?);
    try std.testing.expectEqual(@as(usize, 1), initial.remaining_messages.len);
    try std.testing.expectEqualStrings("Second message", initial.remaining_messages[0]);
}

test "buildInitialMessage distinguishes absent and empty stdin" {
    var absent = try buildInitialMessage(std.testing.allocator, &.{}, null, null);
    defer absent.deinit();
    try std.testing.expect(absent.text == null);

    var empty = try buildInitialMessage(std.testing.allocator, &.{}, "", null);
    defer empty.deinit();
    try std.testing.expect(empty.text != null);
    try std.testing.expectEqualStrings("", empty.text.?);
}

test "buildInitialMessage rejects invalid UTF-8 input" {
    try std.testing.expectError(
        error.InvalidUtf8,
        buildInitialMessage(std.testing.allocator, &.{}, "\xff", null),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        buildInitialMessage(std.testing.allocator, &.{ "valid", "\xff" }, null, null),
    );
}

test "buildInitialMessage bounds message count and bytes" {
    var messages: [max_messages + 1][]const u8 = undefined;
    @memset(&messages, "");
    try std.testing.expectError(
        error.TooManyMessages,
        buildInitialMessage(std.testing.allocator, &messages, null, null),
    );

    const oversized = try std.testing.allocator.alloc(u8, max_initial_message_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.MessageTooLarge,
        buildInitialMessage(std.testing.allocator, &.{oversized}, null, null),
    );
    try std.testing.expectError(
        error.MessageTooLarge,
        buildInitialMessage(std.testing.allocator, &.{ "valid", oversized }, null, null),
    );
}
