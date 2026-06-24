const std = @import("std");

const tui = @import("../../tui/root.zig");

pub const assistant_reveal_interval_ms: i64 = 16;
pub const tool_output_interval_ms: i64 = 200;
pub const animation_frame_interval_ms: i64 = 16;
pub const background_pending_work_interval_ms: i64 = 100;

const count_max: usize = 512;
const bytes_max: usize = 256 * 1024;
const assistant_coalesce_bytes_max: usize = 4 * 1024;
const tool_output_coalesce_bytes_max: usize = 8 * 1024;

pub const Work = union(enum) {
    append_message: MessageText,
    append_thinking: ThinkingText,
    append_tool: ToolAppend,
    replace_tool_footer: ToolText,
    set_status: StatusSet,
    clear_status: StatusClear,
    tool_output_delta: ToolText,
    replace_tool_output: ToolText,

    const MessageText = struct {
        role: tui.Transcript.Role,
        mode: tui.Transcript.AppendMode,
        text: []u8,
        queued_ns: i96,

        fn sizeBytes(self: *const MessageText) usize {
            return self.text.len;
        }

        fn deinit(self: *MessageText, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            self.* = undefined;
        }
    };

    const ThinkingText = struct {
        hidden: bool,
        mode: tui.Transcript.AppendMode,
        text: []u8,
        queued_ns: i96,

        fn sizeBytes(self: *const ThinkingText) usize {
            return self.text.len;
        }

        fn deinit(self: *ThinkingText, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            self.* = undefined;
        }
    };

    const ToolAppend = struct {
        tool_call_id: []u8,
        name: []u8,
        presentation: tui.Transcript.ToolPresentation,
        status: tui.Transcript.ToolStatus,
        body_mode: tui.Transcript.ToolBodyMode,
        collapse: tui.Transcript.ToolCollapse,
        title: []u8,
        compact_title: []u8,

        fn sizeBytes(self: *const ToolAppend) usize {
            return self.tool_call_id.len + self.name.len + self.title.len + self.compact_title.len;
        }

        fn deinit(self: *ToolAppend, allocator: std.mem.Allocator) void {
            allocator.free(self.tool_call_id);
            allocator.free(self.name);
            allocator.free(self.title);
            allocator.free(self.compact_title);
            self.* = undefined;
        }

        pub fn append(self: *const ToolAppend) tui.Transcript.Append.ToolAppend {
            return .{
                .tool_call_id = self.tool_call_id,
                .name = self.name,
                .presentation = self.presentation,
                .status = self.status,
                .body_mode = self.body_mode,
                .collapse = self.collapse,
                .title = self.title,
                .compact_title = self.compact_title,
            };
        }
    };

    const StatusSet = struct {
        slot: tui.status.Slot,
        id: tui.status.ContributionId,
        priority: i16,
        text: []u8,
        effect: tui.status.Effect,
        tone: tui.status.Tone,

        fn sizeBytes(self: *const StatusSet) usize {
            return self.text.len;
        }

        fn deinit(self: *StatusSet, allocator: std.mem.Allocator) void {
            allocator.free(self.text);
            self.* = undefined;
        }
    };

    const StatusClear = struct {
        slot: tui.status.Slot,
        id: tui.status.ContributionId,

        fn sizeBytes(_: *const StatusClear) usize {
            return 0;
        }

        fn deinit(self: *StatusClear, _: std.mem.Allocator) void {
            self.* = undefined;
        }
    };

    const ToolText = struct {
        tool_call_id: []u8,
        text: []u8,

        fn sizeBytes(self: *const ToolText) usize {
            return self.tool_call_id.len + self.text.len;
        }

        fn deinit(self: *ToolText, allocator: std.mem.Allocator) void {
            allocator.free(self.tool_call_id);
            allocator.free(self.text);
            self.* = undefined;
        }
    };

    pub fn sizeBytes(self: *const Work) usize {
        return switch (self.*) {
            .append_message => |*text| text.sizeBytes(),
            .append_thinking => |*text| text.sizeBytes(),
            .append_tool => |*tool| tool.sizeBytes(),
            .replace_tool_footer => |*text| text.sizeBytes(),
            .set_status => |*status| status.sizeBytes(),
            .clear_status => |*status| status.sizeBytes(),
            .tool_output_delta, .replace_tool_output => |*text| text.sizeBytes(),
        };
    }

    pub fn deinit(self: *Work, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .append_message => |*text| text.deinit(allocator),
            .append_thinking => |*text| text.deinit(allocator),
            .append_tool => |*tool| tool.deinit(allocator),
            .replace_tool_footer => |*text| text.deinit(allocator),
            .set_status => |*status| status.deinit(allocator),
            .clear_status => |*status| status.deinit(allocator),
            .tool_output_delta, .replace_tool_output => |*text| text.deinit(allocator),
        }
        self.* = undefined;
    }

    fn presentationIntervalMs(self: *const Work) i64 {
        return switch (self.*) {
            .append_message, .append_thinking => assistant_reveal_interval_ms,
            .tool_output_delta, .replace_tool_output => tool_output_interval_ms,
            .append_tool,
            .replace_tool_footer,
            .set_status,
            .clear_status,
            => background_pending_work_interval_ms,
        };
    }
};

pub const Queue = struct {
    items: std.ArrayList(Work) = .empty,
    bytes: usize = 0,
    drop_noticed: bool = false,

    pub fn deinit(self: *Queue, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.items.deinit(allocator);
        self.* = undefined;
    }

    pub fn clear(self: *Queue, allocator: std.mem.Allocator) void {
        for (self.items.items) |*work| work.deinit(allocator);
        self.items.clearRetainingCapacity();
        self.bytes = 0;
        self.drop_noticed = false;
    }

    pub fn push(self: *Queue, allocator: std.mem.Allocator, work: Work) !enum { queued, dropped_first } {
        if (try self.tryCoalesce(allocator, work)) return .queued;

        const size = work.sizeBytes();
        if (self.items.items.len >= count_max or size > bytes_max -| self.bytes) {
            var owned = work;
            owned.deinit(allocator);
            if (!self.drop_noticed) {
                self.drop_noticed = true;
                return .dropped_first;
            }
            return .queued;
        }

        try self.items.append(allocator, work);
        self.bytes += size;
        return .queued;
    }

    pub fn nextIntervalMs(self: *const Queue) i64 {
        if (self.items.items.len == 0) return animation_frame_interval_ms;
        return self.items.items[0].presentationIntervalMs();
    }

    pub fn popFirstDue(self: *Queue, due_interval_ms: i64) ?struct { work: Work, bytes: usize } {
        if (self.items.items.len == 0) return null;
        if (self.items.items[0].presentationIntervalMs() > due_interval_ms) return null;
        const size = self.items.items[0].sizeBytes();
        const work = self.items.orderedRemove(0);
        self.bytes -= size;
        return .{ .work = work, .bytes = size };
    }

    pub fn pushFront(self: *Queue, work: Work, size: usize) void {
        std.debug.assert(self.items.items.len < self.items.capacity);
        std.debug.assert(size <= bytes_max - self.bytes);
        self.items.insertAssumeCapacity(0, work);
        self.bytes += size;
    }

    fn tryCoalesce(self: *Queue, allocator: std.mem.Allocator, work: Work) !bool {
        if (self.items.items.len == 0) return false;
        const last = &self.items.items[self.items.items.len - 1];
        switch (work) {
            .tool_output_delta => |incoming| {
                if (last.* != .tool_output_delta) return false;
                var existing = &last.tool_output_delta;
                if (!std.mem.eql(u8, existing.tool_call_id, incoming.tool_call_id)) return false;
                if (incoming.text.len > bytes_max - self.bytes) return false;
                if (existing.text.len + incoming.text.len > tool_output_coalesce_bytes_max) return false;
                const old_len = existing.text.len;
                existing.text = try allocator.realloc(existing.text, old_len + incoming.text.len);
                @memcpy(existing.text[old_len..], incoming.text);
                self.bytes += incoming.text.len;
                var owned = work;
                owned.deinit(allocator);
                return true;
            },
            .append_message => |incoming| {
                if (last.* != .append_message) return false;
                var existing = &last.append_message;
                if (existing.role != incoming.role or existing.mode != incoming.mode) return false;
                if (incoming.text.len > bytes_max - self.bytes) return false;
                if (existing.text.len + incoming.text.len > assistant_coalesce_bytes_max) return false;
                const old_len = existing.text.len;
                existing.text = try allocator.realloc(existing.text, old_len + incoming.text.len);
                @memcpy(existing.text[old_len..], incoming.text);
                self.bytes += incoming.text.len;
                var owned = work;
                owned.deinit(allocator);
                return true;
            },
            .append_thinking => |incoming| {
                if (last.* != .append_thinking) return false;
                var existing = &last.append_thinking;
                if (existing.hidden != incoming.hidden or existing.mode != incoming.mode) return false;
                if (incoming.text.len > bytes_max - self.bytes) return false;
                if (existing.text.len + incoming.text.len > assistant_coalesce_bytes_max) return false;
                const old_len = existing.text.len;
                existing.text = try allocator.realloc(existing.text, old_len + incoming.text.len);
                @memcpy(existing.text[old_len..], incoming.text);
                self.bytes += incoming.text.len;
                var owned = work;
                owned.deinit(allocator);
                return true;
            },
            else => return false,
        }
    }
};

test "presentation queue coalescing keeps exact message byte accounting" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);

    try std.testing.expectEqual(.queued, try queue.push(allocator, .{ .append_message = .{
        .role = .assistant,
        .mode = .extend_previous_assistant_message,
        .text = try allocator.dupe(u8, "ab"),
        .queued_ns = 0,
    } }));
    try std.testing.expectEqual(.queued, try queue.push(allocator, .{ .append_message = .{
        .role = .assistant,
        .mode = .extend_previous_assistant_message,
        .text = try allocator.dupe(u8, "cd"),
        .queued_ns = 0,
    } }));

    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqual(@as(usize, 4), queue.bytes);

    var popped = queue.popFirstDue(assistant_reveal_interval_ms).?;
    defer popped.work.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), popped.bytes);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    try std.testing.expectEqualStrings("abcd", popped.work.append_message.text);
}

test "presentation queue coalescing counts shared tool id once" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);

    try std.testing.expectEqual(.queued, try queue.push(allocator, .{ .tool_output_delta = .{
        .tool_call_id = try allocator.dupe(u8, "tool"),
        .text = try allocator.dupe(u8, "a"),
    } }));
    try std.testing.expectEqual(.queued, try queue.push(allocator, .{ .tool_output_delta = .{
        .tool_call_id = try allocator.dupe(u8, "tool"),
        .text = try allocator.dupe(u8, "bc"),
    } }));

    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqual(@as(usize, 7), queue.bytes);

    var popped = queue.popFirstDue(tool_output_interval_ms).?;
    defer popped.work.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 7), popped.bytes);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
    try std.testing.expectEqualStrings("tool", popped.work.tool_output_delta.tool_call_id);
    try std.testing.expectEqualStrings("abc", popped.work.tool_output_delta.text);
}

test "presentation queue drops oversize work and records notice once" {
    const allocator = std.testing.allocator;
    var queue: Queue = .{};
    defer queue.deinit(allocator);

    try std.testing.expectEqual(.dropped_first, try queue.push(allocator, .{ .append_message = .{
        .role = .assistant,
        .mode = .extend_previous_assistant_message,
        .text = try allocator.alloc(u8, bytes_max + 1),
        .queued_ns = 0,
    } }));
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);

    try std.testing.expectEqual(.queued, try queue.push(allocator, .{ .append_message = .{
        .role = .assistant,
        .mode = .extend_previous_assistant_message,
        .text = try allocator.alloc(u8, bytes_max + 1),
        .queued_ns = 0,
    } }));
    try std.testing.expectEqual(@as(usize, 0), queue.items.items.len);
    try std.testing.expectEqual(@as(usize, 0), queue.bytes);
}
