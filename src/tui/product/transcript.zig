const std = @import("std");

pub const item_count_max: usize = 200;
pub const line_count_max: usize = item_count_max;
pub const total_size_bytes_max: usize = 64 * 1024;
pub const append_size_bytes_max: usize = 8 * 1024;

pub const TranscriptRole = enum { user, assistant, system };
pub const TranscriptStatusLevel = enum { info, warning, err };
pub const TranscriptToolStatus = enum { started, completed, failed };

pub const TranscriptAppendMode = enum { new_item, extend_previous_assistant_message };

pub const TranscriptAppend = union(enum) {
    message: MessageAppend,
    status: StatusAppend,
    tool: ToolAppend,

    pub const MessageAppend = struct {
        role: TranscriptRole,
        text: []const u8,
        mode: TranscriptAppendMode = .new_item,
    };
    pub const StatusAppend = struct {
        level: TranscriptStatusLevel,
        text: []const u8,
    };
    pub const ToolAppend = struct {
        name: []const u8,
        status: TranscriptToolStatus,
        summary: []const u8 = "",
    };
};

pub const TranscriptMessage = struct { role: TranscriptRole, text: []u8 };
pub const TranscriptStatus = struct { level: TranscriptStatusLevel, text: []u8 };
pub const TranscriptTool = struct { name: []u8, status: TranscriptToolStatus, summary: []u8 };

pub const TranscriptItem = union(enum) {
    message: TranscriptMessage,
    status: TranscriptStatus,
    tool: TranscriptTool,

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message => |item| allocator.free(item.text),
            .status => |item| allocator.free(item.text),
            .tool => |item| {
                allocator.free(item.name);
                allocator.free(item.summary);
            },
        }
        self.* = undefined;
    }

    pub fn sizeBytes(self: TranscriptItem) usize {
        return switch (self) {
            .message => |item| item.text.len,
            .status => |item| item.text.len,
            .tool => |item| item.name.len + item.summary.len,
        };
    }
};

pub const TranscriptBuffer = struct {
    items: std.ArrayListUnmanaged(TranscriptItem) = .empty,
    total_size_bytes: usize = 0,

    pub fn deinit(self: *TranscriptBuffer, allocator: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn append(self: *TranscriptBuffer, allocator: std.mem.Allocator, append_item: TranscriptAppend) !void {
        switch (append_item) {
            .message => |message| try self.appendMessage(allocator, message),
            .status => |status| try self.appendStatus(allocator, status),
            .tool => |tool| try self.appendTool(allocator, tool),
        }
    }

    pub fn latest(self: TranscriptBuffer, count: usize) []const TranscriptItem {
        if (count >= self.items.items.len) return self.items.items;
        return self.items.items[self.items.items.len - count ..];
    }

    fn appendMessage(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        message: TranscriptAppend.MessageAppend,
    ) !void {
        if (message.text.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(message.text)) return error.InvalidUtf8;

        if (message.mode == .extend_previous_assistant_message and
            message.role == .assistant and
            self.items.items.len > 0)
        {
            const last = &self.items.items[self.items.items.len - 1];
            if (last.* == .message and last.message.role == .assistant) {
                last.message.text = try allocator.realloc(
                    last.message.text,
                    last.message.text.len + message.text.len,
                );
                @memcpy(last.message.text[last.message.text.len - message.text.len ..], message.text);
                self.total_size_bytes += message.text.len;
                self.evictUntilBounded(allocator);
                return;
            }
        }

        const copy = try allocator.dupe(u8, message.text);
        errdefer allocator.free(copy);
        try self.items.append(allocator, .{ .message = .{ .role = message.role, .text = copy } });
        self.total_size_bytes += copy.len;
        self.evictUntilBounded(allocator);
    }

    fn appendStatus(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        status: TranscriptAppend.StatusAppend,
    ) !void {
        if (status.text.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(status.text)) return error.InvalidUtf8;
        const copy = try allocator.dupe(u8, status.text);
        errdefer allocator.free(copy);
        try self.items.append(allocator, .{ .status = .{ .level = status.level, .text = copy } });
        self.total_size_bytes += copy.len;
        self.evictUntilBounded(allocator);
    }

    fn appendTool(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        tool: TranscriptAppend.ToolAppend,
    ) !void {
        if (tool.name.len + tool.summary.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool.name) or
            !std.unicode.utf8ValidateSlice(tool.summary))
        {
            return error.InvalidUtf8;
        }
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const summary = try allocator.dupe(u8, tool.summary);
        errdefer allocator.free(summary);
        try self.items.append(allocator, .{
            .tool = .{ .name = name, .status = tool.status, .summary = summary },
        });
        self.total_size_bytes += name.len + summary.len;
        self.evictUntilBounded(allocator);
    }

    fn evictUntilBounded(self: *TranscriptBuffer, allocator: std.mem.Allocator) void {
        while (self.items.items.len > item_count_max or self.total_size_bytes > total_size_bytes_max) {
            var item = self.items.orderedRemove(0);
            self.total_size_bytes -= item.sizeBytes();
            item.deinit(allocator);
        }
    }
};

test "transcript owns copied message text and accepts empty append" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    var source = [_]u8{ 'h', 'i' };
    try buffer.append(std.testing.allocator, .{ .message = .{ .role = .user, .text = &source } });
    source[0] = 'b';
    try buffer.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = "" } });

    try std.testing.expectEqual(@as(usize, 2), buffer.items.items.len);
    try std.testing.expectEqualStrings("hi", buffer.items.items[0].message.text);
    try std.testing.expectEqualStrings("", buffer.items.items[1].message.text);
}

test "transcript can extend previous assistant message" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .message = .{ .role = .assistant, .text = "hel" } });
    try buffer.append(std.testing.allocator, .{ .message = .{
        .role = .assistant,
        .text = "lo",
        .mode = .extend_previous_assistant_message,
    } });
    try buffer.append(std.testing.allocator, .{ .message = .{
        .role = .user,
        .text = "stop",
        .mode = .extend_previous_assistant_message,
    } });

    try std.testing.expectEqual(@as(usize, 2), buffer.items.items.len);
    try std.testing.expectEqualStrings("hello", buffer.items.items[0].message.text);
    try std.testing.expectEqualStrings("stop", buffer.items.items[1].message.text);
}

test "transcript owns status and tool items" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    var name = [_]u8{ 'b', 'a', 's', 'h' };
    try buffer.append(std.testing.allocator, .{ .status = .{ .level = .warning, .text = "careful" } });
    try buffer.append(std.testing.allocator, .{ .tool = .{
        .name = &name,
        .status = .started,
        .summary = "running",
    } });
    name[0] = 'x';

    try std.testing.expectEqual(.warning, buffer.items.items[0].status.level);
    try std.testing.expectEqualStrings("bash", buffer.items.items[1].tool.name);
    try std.testing.expectEqualStrings("running", buffer.items.items[1].tool.summary);
}

test "transcript rejects invalid utf8 and oversized single append before allocation" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try std.testing.expectError(error.InvalidUtf8, buffer.append(std.testing.allocator, .{ .message = .{
        .role = .assistant,
        .text = "\xff",
    } }));

    const too_large = try std.testing.allocator.alloc(u8, append_size_bytes_max + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'a');
    try std.testing.expectError(error.TranscriptAppendTooLarge, buffer.append(std.testing.allocator, .{ .message = .{
        .role = .assistant,
        .text = too_large,
    } }));
    try std.testing.expectEqual(@as(usize, 0), buffer.items.items.len);
}

test "transcript accepts exact append limit" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const exact = try std.testing.allocator.alloc(u8, append_size_bytes_max);
    defer std.testing.allocator.free(exact);
    @memset(exact, 'a');
    try buffer.append(std.testing.allocator, .{ .message = .{ .role = .assistant, .text = exact } });
    try std.testing.expectEqual(@as(usize, append_size_bytes_max), buffer.total_size_bytes);
}

test "transcript evicts oldest by item count and total bytes" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    for (0..item_count_max + 1) |index| {
        const text = if (index == 0) "old" else "new";
        try buffer.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = text } });
    }
    try std.testing.expectEqual(@as(usize, item_count_max), buffer.items.items.len);
    try std.testing.expectEqualStrings("new", buffer.items.items[0].message.text);

    const chunk = try std.testing.allocator.alloc(u8, append_size_bytes_max);
    defer std.testing.allocator.free(chunk);
    @memset(chunk, 'b');
    for (0..9) |_| try buffer.append(std.testing.allocator, .{ .message = .{ .role = .assistant, .text = chunk } });
    try std.testing.expect(buffer.total_size_bytes <= total_size_bytes_max);
    try std.testing.expect(buffer.items.items.len <= item_count_max);
}
