const std = @import("std");
const transcript_preview = @import("transcript_preview.zig");

pub const item_count_max: usize = 200;
pub const line_count_max: usize = item_count_max;
pub const total_size_bytes_max: usize = 64 * 1024;
pub const append_size_bytes_max: usize = 8 * 1024;

pub const TranscriptRole = enum { user, assistant, system, thinking };
pub const TranscriptStatusLevel = enum { info, warning, err };
pub const TranscriptToolPresentation = enum { generic, command, file, patch, search, directory };
pub const TranscriptToolStatus = enum { pending, success, err };
pub const TranscriptToolBodyMode = enum { visible, hidden_on_success };
pub const TranscriptToolCollapseMode = enum { head, tail };

/// Collapsed-view window over a tool's output body, measured in visual rows.
/// Mirrors pi-mono per-tool previews: bash keeps the tail (errors live at the
/// end), listing/search tools keep the head. Expansion shows the full retained
/// preview; the transcript byte caps still bound what is resident.
pub const TranscriptToolCollapse = struct {
    mode: TranscriptToolCollapseMode = .tail,
    rows_max: u8 = 5,
};

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
        presentation: TranscriptToolPresentation = .generic,
        status: TranscriptToolStatus = .pending,
        body_mode: TranscriptToolBodyMode = .visible,
        collapse: TranscriptToolCollapse = .{},
        title: []const u8 = "",
        call_preview: []const u8 = "",
    };
};

pub const TranscriptMessage = struct { role: TranscriptRole, text: []u8 };
pub const TranscriptStatus = struct { level: TranscriptStatusLevel, text: []u8 };
pub const TranscriptTool = struct {
    tool_call_id: []u8,
    name: []u8,
    presentation: TranscriptToolPresentation,
    status: TranscriptToolStatus,
    body_mode: TranscriptToolBodyMode,
    collapse: TranscriptToolCollapse,
    title: []u8,
    call_preview: []u8,
    output_preview: []u8,
    footer: []u8,
    output_truncated_head_bytes: usize = 0,
    output_truncated_head_lines: usize = 0,

    pub fn sizeBytes(self: TranscriptTool) usize {
        return self.tool_call_id.len +
            self.name.len +
            self.title.len +
            self.call_preview.len +
            self.output_preview.len +
            self.footer.len;
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
                allocator.free(item.call_preview);
                allocator.free(item.output_preview);
                allocator.free(item.footer);
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
    revision: u64 = 0,

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
        self.noteMutation();
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
        self.noteMutation();
    }

    /// Replace the whole output preview. Used when a tool finishes: the final
    /// result supersedes the streamed deltas instead of duplicating them.
    pub fn replaceToolOutput(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        output: []const u8,
    ) !void {
        if (output.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool_call_id) or !std.unicode.utf8ValidateSlice(output)) {
            return error.InvalidUtf8;
        }
        const index = self.findTool(tool_call_id) orelse return;
        const tool = &self.items.items[index].tool;
        const old_size = tool.sizeBytes();
        const copy = try allocator.dupe(u8, output);
        errdefer allocator.free(copy);
        allocator.free(tool.output_preview);
        tool.output_preview = copy;
        tool.output_truncated_head_bytes = 0;
        tool.output_truncated_head_lines = 0;
        const next_size = tool.sizeBytes();
        self.total_size_bytes = self.total_size_bytes - old_size + next_size;
        self.evictUntilBounded(allocator);
        self.noteMutation();
    }

    pub fn replaceToolFooter(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        footer: []const u8,
    ) !void {
        if (footer.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool_call_id) or !std.unicode.utf8ValidateSlice(footer)) {
            return error.InvalidUtf8;
        }
        const index = self.findTool(tool_call_id) orelse return;
        const tool = &self.items.items[index].tool;
        const old_size = tool.sizeBytes();
        const copy = try allocator.dupe(u8, footer);
        errdefer allocator.free(copy);
        allocator.free(tool.footer);
        tool.footer = copy;
        const next_size = tool.sizeBytes();
        self.total_size_bytes = self.total_size_bytes - old_size + next_size;
        self.evictUntilBounded(allocator);
        self.noteMutation();
    }

    pub fn replaceToolCallPreview(
        self: *TranscriptBuffer,
        allocator: std.mem.Allocator,
        tool_call_id: []const u8,
        preview: []const u8,
    ) !void {
        if (preview.len > append_size_bytes_max) return error.TranscriptAppendTooLarge;
        if (!std.unicode.utf8ValidateSlice(tool_call_id) or
            !std.unicode.utf8ValidateSlice(preview)) return error.InvalidUtf8;
        const index = self.findTool(tool_call_id) orelse return;
        const tool = &self.items.items[index].tool;
        const old_size = tool.sizeBytes();
        const copy = try allocator.dupe(u8, preview);
        errdefer allocator.free(copy);
        allocator.free(tool.call_preview);
        tool.call_preview = copy;
        const next_size = tool.sizeBytes();
        self.total_size_bytes = self.total_size_bytes - old_size + next_size;
        self.evictUntilBounded(allocator);
        self.noteMutation();
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
                old.call_preview.len +
                old.output_preview.len +
                old.footer.len;
            allocator.free(old.tool_call_id);
            allocator.free(old.name);
            allocator.free(old.title);
            old.* = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .presentation = tool.presentation,
                .status = mergeToolStatus(old.status, tool.status),
                .body_mode = tool.body_mode,
                .collapse = tool.collapse,
                .title = next_title,
                .call_preview = old.call_preview,
                .output_preview = old.output_preview,
                .footer = old.footer,
                .output_truncated_head_bytes = old.output_truncated_head_bytes,
                .output_truncated_head_lines = old.output_truncated_head_lines,
            };
            self.total_size_bytes = self.total_size_bytes - old_size + next_size;
            self.evictUntilBounded(allocator);
            return;
        }

        const call_preview = try allocator.dupe(u8, tool.call_preview);
        errdefer allocator.free(call_preview);
        const output_preview = try allocator.dupe(u8, "");
        errdefer allocator.free(output_preview);
        const footer = try allocator.dupe(u8, "");
        errdefer allocator.free(footer);
        try self.items.append(allocator, .{
            .tool = .{
                .tool_call_id = tool_call_id,
                .name = name,
                .presentation = tool.presentation,
                .status = tool.status,
                .body_mode = tool.body_mode,
                .collapse = tool.collapse,
                .title = title,
                .call_preview = call_preview,
                .output_preview = output_preview,
                .footer = footer,
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

    fn noteMutation(self: *TranscriptBuffer) void {
        self.revision +%= 1;
    }

    fn evictUntilBounded(self: *TranscriptBuffer, allocator: std.mem.Allocator) void {
        while (self.items.items.len > item_count_max or self.total_size_bytes > total_size_bytes_max) {
            var item = self.items.orderedRemove(0);
            self.total_size_bytes -= item.sizeBytes();
            item.deinit(allocator);
        }
    }
};

test "replaceToolOutput supersedes streamed preview and clears omission counters" {
    const allocator = std.testing.allocator;
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(allocator);

    try buffer.append(allocator, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });
    try buffer.appendToolOutput(allocator, "call-1", "streamed delta\n", 3, 2);
    try buffer.replaceToolOutput(allocator, "call-1", "final output");

    const tool = buffer.items.items[0].tool;
    try std.testing.expectEqualStrings("final output", tool.output_preview);
    try std.testing.expectEqual(@as(usize, 0), tool.output_truncated_head_bytes);
    try std.testing.expectEqual(@as(usize, 0), tool.output_truncated_head_lines);
    try std.testing.expectEqual(tool.sizeBytes(), buffer.total_size_bytes);
}

test "replaceToolFooter stores footer and keeps byte accounting" {
    const allocator = std.testing.allocator;
    var buffer: TranscriptBuffer = .{};
    defer buffer.deinit(allocator);

    try buffer.append(allocator, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });
    try buffer.replaceToolFooter(allocator, "call-1", "Took 1.2s");
    try buffer.replaceToolFooter(allocator, "call-1", "Took 2.4s");

    const tool = buffer.items.items[0].tool;
    try std.testing.expectEqualStrings("Took 2.4s", tool.footer);
    try std.testing.expectEqual(tool.sizeBytes(), buffer.total_size_bytes);
}
