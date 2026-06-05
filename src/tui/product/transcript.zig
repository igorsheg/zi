const std = @import("std");
const transcript_preview = @import("transcript_preview.zig");

pub const item_count_max: usize = 200;
pub const line_count_max: usize = item_count_max;
pub const total_size_bytes_max: usize = 64 * 1024;
pub const append_size_bytes_max: usize = 8 * 1024;

pub const TranscriptRole = enum { user, assistant, system, thinking };
pub const TranscriptStatusLevel = enum { info, warning, err };
pub const TranscriptToolKind = enum { generic, bash, read, edit };
pub const TranscriptToolStatus = enum { pending, success, err };
pub const TranscriptToolBodyMode = enum { visible, hidden_on_success };

pub const TranscriptAppendMode = enum { new_item, extend_previous_assistant_message, extend_previous_same_role };

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
        tool_call_id: []const u8,
        name: []const u8,
        kind: TranscriptToolKind = .generic,
        status: TranscriptToolStatus = .pending,
        body_mode: TranscriptToolBodyMode = .visible,
        title: []const u8 = "",
    };
};

pub const TranscriptMessage = struct { role: TranscriptRole, text: []u8 };
pub const TranscriptStatus = struct { level: TranscriptStatusLevel, text: []u8 };
pub const TranscriptTool = struct {
    tool_call_id: []u8,
    name: []u8,
    kind: TranscriptToolKind,
    status: TranscriptToolStatus,
    body_mode: TranscriptToolBodyMode,
    title: []u8,
    output_preview: []u8,
    output_truncated_head_bytes: usize = 0,
    output_truncated_head_lines: usize = 0,

    pub fn sizeBytes(self: TranscriptTool) usize {
        return self.tool_call_id.len +
            self.name.len +
            self.title.len +
            self.output_preview.len;
    }
};

pub const TranscriptItem = union(enum) {
    message: TranscriptMessage,
    status: TranscriptStatus,
    tool: TranscriptTool,

    pub fn deinit(self: *TranscriptItem, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .message => |item| allocator.free(item.text),
            .status => |item| allocator.free(item.text),
            .tool => |item| {
                allocator.free(item.tool_call_id);
                allocator.free(item.name);
                allocator.free(item.title);
                allocator.free(item.output_preview);
            },
        }
        self.* = undefined;
    }

    pub fn sizeBytes(self: TranscriptItem) usize {
        return switch (self) {
            .message => |item| item.text.len,
            .status => |item| item.text.len,
            .tool => |item| item.sizeBytes(),
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

    pub fn appendToolOutput(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        output_delta: []const u8,
        dropped_head_bytes: usize,
        dropped_head_lines: usize,
    ) !void {
        if (output_delta.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool_call_id) or !std.unicode.utf8ValidateSlice(output_delta)) {
            return error.InvalidUtf8;
        }
        const index = self.findTool(tool_call_id) orelse return;
        const tool = &self.items.items[index].tool;
        const old_size = tool.sizeBytes();
        const next = try transcript_preview.appendTail(allocator, tool.output_preview, output_delta);
        errdefer allocator.free(next.bytes);
        allocator.free(tool.output_preview);
        tool.output_preview = next.bytes;
        tool.output_truncated_head_bytes += dropped_head_bytes + next.dropped_bytes;
        tool.output_truncated_head_lines += dropped_head_lines + next.dropped_lines;
        const next_size = tool.sizeBytes();
        self.total_size_bytes = self.total_size_bytes - old_size + next_size;
        self.evictUntilBounded(allocator);
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

        if (message.mode != .new_item and self.items.items.len > 0) {
            const last = &self.items.items[self.items.items.len - 1];
            const role_matches = last.* == .message and switch (message.mode) {
                .new_item => false,
                .extend_previous_assistant_message => last.message.role == .assistant and message.role == .assistant,
                .extend_previous_same_role => last.message.role == message.role,
            };
            if (role_matches) {
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
        const append_size = tool.tool_call_id.len + tool.name.len + tool.title.len;
        if (append_size > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool.tool_call_id) or
            !std.unicode.utf8ValidateSlice(tool.name) or
            !std.unicode.utf8ValidateSlice(tool.title))
        {
            return error.InvalidUtf8;
        }

        const tool_call_id = try allocator.dupe(u8, tool.tool_call_id);
        errdefer allocator.free(tool_call_id);
        const name = try allocator.dupe(u8, tool.name);
        errdefer allocator.free(name);
        const title = try allocator.dupe(u8, tool.title);
        errdefer allocator.free(title);

        if (self.findTool(tool.tool_call_id)) |index| {
            const old = &self.items.items[index].tool;
            const old_size = old.sizeBytes();
            const next_title = if (tool.title.len == 0) blk: {
                allocator.free(title);
                break :blk try allocator.dupe(u8, old.title);
            } else title;
            errdefer if (tool.title.len == 0) allocator.free(next_title);
            const next_size = tool_call_id.len +
                name.len +
                next_title.len +
                old.output_preview.len;
            allocator.free(old.tool_call_id);
            allocator.free(old.name);
            allocator.free(old.title);
            old.* = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .kind = tool.kind,
                .status = mergeToolStatus(old.status, tool.status),
                .body_mode = tool.body_mode,
                .title = next_title,
                .output_preview = old.output_preview,
                .output_truncated_head_bytes = old.output_truncated_head_bytes,
                .output_truncated_head_lines = old.output_truncated_head_lines,
            };
            self.total_size_bytes = self.total_size_bytes - old_size + next_size;
            self.evictUntilBounded(allocator);
            return;
        }

        const output_preview = try allocator.dupe(u8, "");
        errdefer allocator.free(output_preview);
        try self.items.append(allocator, .{
            .tool = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .kind = tool.kind,
                .status = tool.status,
                .body_mode = tool.body_mode,
                .title = title,
                .output_preview = output_preview,
            },
        });
        self.total_size_bytes += append_size;
        self.evictUntilBounded(allocator);
    }

    fn mergeToolStatus(old: TranscriptToolStatus, new: TranscriptToolStatus) TranscriptToolStatus {
        return switch (new) {
            .pending => if (old == .success or old == .err) old else .pending,
            .success, .err => new,
        };
    }

    fn findTool(self: TranscriptBuffer, tool_call_id: []const u8) ?usize {
        for (self.items.items, 0..) |item, index| {
            if (item == .tool and std.mem.eql(u8, item.tool.tool_call_id, tool_call_id)) return index;
        }
        return null;
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
        .tool_call_id = "call-1",
        .name = &name,
        .status = .pending,
    } });
    name[0] = 'x';

    try std.testing.expectEqual(.warning, buffer.items.items[0].status.level);
    try std.testing.expectEqualStrings("call-1", buffer.items.items[1].tool.tool_call_id);
    try std.testing.expectEqualStrings("bash", buffer.items.items[1].tool.name);
}

test "transcript updates existing tool by call id" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .success,
    } });

    try std.testing.expectEqual(@as(usize, 1), buffer.items.items.len);
    try std.testing.expectEqual(.success, buffer.items.items[0].tool.status);
}

test "transcript preserves tool display text when completion updates status" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
        .title = "zig build test",
    } });
    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .success,
    } });

    try std.testing.expectEqual(@as(usize, 1), buffer.items.items.len);
    try std.testing.expectEqual(.success, buffer.items.items[0].tool.status);
    try std.testing.expectEqualStrings("zig build test", buffer.items.items[0].tool.title);
}

test "transcript accounts dropped tool output before transcript preview" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try buffer.appendToolOutput(std.testing.allocator, "call-1", "tail", 10, 2);

    try std.testing.expectEqual(@as(usize, 10), buffer.items.items[0].tool.output_truncated_head_bytes);
    try std.testing.expectEqual(@as(usize, 2), buffer.items.items[0].tool.output_truncated_head_lines);
    try std.testing.expectEqualStrings("tail", buffer.items.items[0].tool.output_preview);
}

test "transcript evicts after existing tool metadata grows" {
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(std.testing.allocator);

    const filler = try std.testing.allocator.alloc(u8, append_size_bytes_max - 32);
    defer std.testing.allocator.free(filler);
    @memset(filler, 'a');
    for (0..8) |_| try buffer.append(std.testing.allocator, .{ .message = .{ .role = .system, .text = filler } });
    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
    } });
    try buffer.append(std.testing.allocator, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .status = .pending,
        .title = filler,
    } });

    try std.testing.expect(buffer.total_size_bytes <= total_size_bytes_max);
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
