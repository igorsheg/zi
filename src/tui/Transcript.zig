const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const blocks = @import("blocks.zig");
const layout = @import("layout.zig");
const screen = @import("screen.zig");
const theme = @import("theme.zig");

pub const append_chunk_bytes_max: usize = 8 * 1024;
pub const per_item_text_bytes_max: usize = 256 * 1024;
pub const transcript_items_max: usize = 2000;
pub const transcript_bytes_max: usize = 8 * 1024 * 1024;
const output_truncated_text = "[output truncated]";

pub const Transcript = @This();

gpa: std.mem.Allocator,
items: std.ArrayList(*Item) = .empty,
live_tools: std.StringArrayHashMapUnmanaged(*Item) = .empty,
streaming_item: ?*Item = null,
total_bytes: usize = 0,
next_seq: u64 = 0,
evicted_seqs: u64 = 0,
run_active: bool = false,

pub const PartTag = enum { text, thinking };

pub const Part = union(PartTag) {
    text: std.ArrayList(u8),
    thinking: std.ArrayList(u8),

    fn list(self: *Part) *std.ArrayList(u8) {
        return switch (self.*) {
            .text => |*value| value,
            .thinking => |*value| value,
        };
    }

    fn bytes(self: *const Part) []const u8 {
        return switch (self.*) {
            .text => |value| value.items,
            .thinking => |value| value.items,
        };
    }

    fn tag(self: Part) PartTag {
        return switch (self) {
            .text => .text,
            .thinking => .thinking,
        };
    }
};

pub const Stop = enum { ok, aborted, errored };
pub const NoticeLevel = enum { info, warn, err };

pub const Item = struct {
    arena: std.heap.ArenaAllocator,
    layout_arena: std.heap.ArenaAllocator,
    seq: u64,
    dirty: bool = true,
    cached_width: u16 = 0,
    cached_epoch: u64 = 0,
    lines: []layout.Line = &.{},
    wrap: layout.WrapState = .{},
    kind: Kind,

    pub const Kind = union(enum) {
        user: struct { text: std.ArrayList(u8), truncated: bool = false },
        assistant: struct {
            parts: std.ArrayList(Part),
            streaming: bool,
            stop: Stop = .ok,
            error_text: ?[]const u8 = null,
            truncated: bool = false,
        },
        tool: struct {
            call_id: []const u8,
            name: []const u8,
            title: []const u8,
            args_preview: std.ArrayList(u8),
            status: blocks.Status,
            started_ns: ?u64 = null,
            duration_ms: ?u64 = null,
            tail: blocks.TailBuffer = .{},
            body: std.ArrayList(u8),
            body_truncated: bool = false,
        },
        notice: struct { level: NoticeLevel, text: []const u8 },
        compaction: struct { summary_first_line: []const u8, tokens_before: u64 },
    };

    fn allocator(self: *Item) std.mem.Allocator {
        return self.arena.allocator();
    }

    fn layoutAllocator(self: *Item) std.mem.Allocator {
        return self.layout_arena.allocator();
    }
};

pub fn init(gpa: std.mem.Allocator) Transcript {
    return .{ .gpa = gpa };
}

pub fn deinit(self: *Transcript) void {
    for (self.items.items) |item| self.destroyItem(item);
    self.items.deinit(self.gpa);
    self.live_tools.deinit(self.gpa);
    self.* = undefined;
}

pub fn applyListener(io: std.Io, context: ?*anyopaque, event: agent_mod.AgentEvent, _: runtime.CancelToken) anyerror!void {
    const self: *Transcript = @ptrCast(@alignCast(context.?));
    try self.apply(io, event);
}

pub fn apply(self: *Transcript, io: std.Io, event: agent_mod.AgentEvent) !void {
    switch (event) {
        .agent_start => self.run_active = true,
        .agent_end => {
            self.run_active = false;
            self.live_tools.clearRetainingCapacity();
        },
        .turn_start, .turn_end => {},
        .message_start => |payload| try self.applyMessageStart(payload.message),
        .message_update => |payload| try self.applyMessageUpdate(payload.assistant_message_event),
        .message_end => |payload| try self.applyMessageEnd(payload.message),
        .tool_execution_start => |payload| try self.applyToolStart(io, payload),
        .tool_execution_update => |payload| try self.applyToolUpdate(payload),
        .tool_execution_end => |payload| try self.applyToolEnd(io, payload),
    }
    try self.enforceCaps();
}

pub fn appendNotice(self: *Transcript, level: NoticeLevel, text: []const u8) !void {
    const item = try self.createItem(.{ .notice = .{
        .level = level,
        .text = undefined,
    } });
    item.kind.notice.text = try item.allocator().dupe(u8, text);
    self.total_bytes += item.kind.notice.text.len;
    try self.appendItem(item);
    try self.enforceCaps();
}

pub fn appendCompaction(self: *Transcript, summary: []const u8, tokens_before: u64) !void {
    const first = firstLine(summary);
    const item = try self.createItem(.{ .compaction = .{
        .summary_first_line = undefined,
        .tokens_before = tokens_before,
    } });
    item.kind.compaction.summary_first_line = try item.allocator().dupe(u8, first);
    self.total_bytes += item.kind.compaction.summary_first_line.len;
    try self.appendItem(item);
    try self.enforceCaps();
}

pub fn markRunningToolsDirty(self: *Transcript) bool {
    var changed = false;
    for (self.live_tools.values()) |item| {
        if (item.kind == .tool and item.kind.tool.status == .running) {
            item.dirty = true;
            changed = true;
        }
    }
    return changed;
}

pub fn markAllDirty(self: *Transcript) void {
    for (self.items.items) |item| item.dirty = true;
}

pub fn itemLines(self: *Transcript, item: *Item, width: u16, epoch: theme.LayoutEpoch) ![]const layout.Line {
    _ = self;
    const epoch_value = epoch.revision;
    if (!item.dirty and item.cached_width == width and item.cached_epoch == epoch_value) return item.lines;
    _ = item.layout_arena.reset(.retain_capacity);
    item.lines = &.{};
    const allocator = item.layoutAllocator();
    item.lines = switch (item.kind) {
        .user => |*user| try layout.wrapPlain(allocator, user.text.items, width, screen.styles.normal),
        .assistant => |*assistant| try layoutAssistant(allocator, assistant, width, epoch),
        .tool => |*tool| try layoutTool(allocator, tool, width, epoch.expanded),
        .notice => |notice| try layout.wrapPlain(allocator, notice.text, width, noticeStyle(notice.level)),
        .compaction => |compaction| blk: {
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "context compacted: {s}", .{compaction.summary_first_line}) catch "context compacted";
            const owned = try allocator.dupe(u8, text);
            break :blk try layout.wrapPlain(allocator, owned, width, screen.styles.muted);
        },
    };
    item.cached_width = width;
    item.cached_epoch = epoch_value;
    item.dirty = false;
    return item.lines;
}

fn layoutAssistant(allocator: std.mem.Allocator, assistant: anytype, width: u16, epoch: theme.LayoutEpoch) ![]layout.Line {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    var hidden_thinking_shown = false;
    for (assistant.parts.items) |part| {
        switch (part) {
            .text => |value| try text.writer.writeAll(value.items),
            .thinking => |value| {
                if (epoch.hide_thinking) {
                    if (assistant.streaming and value.items.len > 0 and !hidden_thinking_shown) {
                        try text.writer.writeAll("Thinking…\n");
                        hidden_thinking_shown = true;
                    }
                } else {
                    try text.writer.writeAll(value.items);
                }
            },
        }
    }
    if (assistant.stop == .aborted) try text.writer.writeAll("\naborted");
    if (assistant.stop == .errored) {
        try text.writer.writeAll("\nerror: ");
        if (assistant.error_text) |err| try text.writer.writeAll(err);
    }
    if (text.written().len == 0) return &.{};
    const style = if (assistant.stop == .ok) screen.styles.normal else screen.styles.error_;
    var wrap_state: layout.WrapState = .{};
    return layout.wrapMarkdown(allocator, text.written(), width, style, &wrap_state);
}

fn layoutTool(allocator: std.mem.Allocator, tool: anytype, width: u16, expanded: bool) ![]layout.Line {
    const style = blocks.statusStyle(tool.status);
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, 8);

    const title = try toolTitleLine(allocator, tool);
    try layout.appendPlainLine(allocator, &out, title, width, style);

    if (tool.status == .running and !tool.tail.isEmpty()) {
        for (0..tool.tail.count) |index| try layout.appendPlainLine(allocator, &out, tool.tail.line(index), width, style);
    } else if (tool.body.items.len > 0) {
        if (expanded) {
            try appendToolBodyLines(allocator, &out, tool.body.items, width, style);
        } else {
            const preview = collapsedBodyPreview(tool.body.items);
            try appendToolBodyLines(allocator, &out, preview.text, width, style);
            if (preview.more_lines > 0) {
                const marker = try std.fmt.allocPrint(allocator, "… {d} more lines (ctrl+o)", .{preview.more_lines});
                try layout.appendPlainLine(allocator, &out, marker, width, style);
            }
        }
        if (tool.body_truncated) try layout.appendPlainLine(allocator, &out, output_truncated_text, width, style);
    }
    return out.toOwnedSlice(allocator);
}

fn toolTitleLine(allocator: std.mem.Allocator, tool: anytype) ![]const u8 {
    if (tool.status == .running) {
        return std.fmt.allocPrint(allocator, "[{s}] {s} — {s}", .{ blocks.statusText(tool.status), tool.title, elapsedText(allocator, tool, true) });
    }
    if (tool.duration_ms) |_| {
        return std.fmt.allocPrint(allocator, "[{s}] {s} — {s}", .{ blocks.statusText(tool.status), tool.title, elapsedText(allocator, tool, false) });
    }
    return std.fmt.allocPrint(allocator, "[{s}] {s}", .{ blocks.statusText(tool.status), tool.title });
}

fn appendToolBodyLines(allocator: std.mem.Allocator, out: *std.ArrayList(layout.Line), text: []const u8, width: u16, style: screen.Style) !void {
    var start: usize = 0;
    if (text.len == 0) return;
    while (start < text.len) {
        const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
        try layout.appendPlainLine(allocator, out, text[start..end], width, style);
        if (end == text.len) break;
        start = end + 1;
    }
}

const BodyPreview = struct { text: []const u8, more_lines: usize };

fn collapsedBodyPreview(text: []const u8) BodyPreview {
    const byte_limit = blocks.tail_line_count * blocks.tail_line_bytes_max;
    var lines: usize = 0;
    var index: usize = 0;
    while (index < text.len and index < byte_limit) : (index += 1) {
        if (text[index] == '\n') {
            lines += 1;
            if (lines == blocks.tail_line_count) {
                index += 1;
                break;
            }
        }
    }
    const end = agent_mod.utf8Prefix(text, @min(index, text.len)).len;
    if (end >= text.len) return .{ .text = text, .more_lines = 0 };
    const remaining = text[end..];
    var more_lines: usize = if (remaining.len == 0) 0 else 1;
    for (remaining, 0..) |byte, offset| {
        if (byte == '\n' and offset + 1 < remaining.len) more_lines += 1;
    }
    return .{ .text = text[0..end], .more_lines = more_lines };
}

fn elapsedText(allocator: std.mem.Allocator, tool: anytype, running: bool) []const u8 {
    const seconds: u64 = if (tool.duration_ms) |ms| ms / 1000 else 0;
    return std.fmt.allocPrint(allocator, "{s} {d}s", .{ if (running) "Elapsed" else "Took", seconds }) catch if (running) "Elapsed 0s" else "Took 0s";
}

fn noticeStyle(level: NoticeLevel) screen.Style {
    return switch (level) {
        .info => screen.styles.muted,
        .warn => screen.styles.warn,
        .err => screen.styles.error_,
    };
}

fn applyMessageStart(self: *Transcript, message: agent_mod.AgentMessage) !void {
    switch (message) {
        .user => |user| {
            const item = try self.createUserItem(userText(user));
            try self.appendItem(item);
        },
        .assistant => {
            const item = try self.createAssistantItem(true);
            self.streaming_item = item;
            try self.appendItem(item);
        },
        .tool_result, .custom => {},
    }
}

fn applyMessageUpdate(self: *Transcript, event: ai.AssistantMessageEvent) !void {
    switch (event) {
        .start, .done, .@"error" => {},
        .text_start => |payload| _ = try self.ensurePart(payload.content_index, .text),
        .thinking_start => |payload| _ = try self.ensurePart(payload.content_index, .thinking),
        .text_delta => |payload| {
            const part = try self.ensurePart(payload.content_index, .text);
            try self.appendAssistantPart(part, payload.delta);
        },
        .thinking_delta => |payload| {
            const part = try self.ensurePart(payload.content_index, .thinking);
            try self.appendAssistantPart(part, payload.delta);
        },
        .text_end => |payload| {
            const part = try self.ensurePart(payload.content_index, .text);
            try self.replaceAssistantPart(part, payload.content);
        },
        .thinking_end => |payload| {
            const part = try self.ensurePart(payload.content_index, .thinking);
            try self.replaceAssistantPart(part, payload.content);
        },
        .toolcall_start => |payload| {
            if (toolCallAt(payload.partial, payload.content_index)) |call| _ = try self.ensureToolItem(call.id, call.name, call.arguments);
        },
        .toolcall_delta => |payload| {
            const call = toolCallAt(payload.partial, payload.content_index) orelse return;
            const item = try self.ensureToolItem(call.id, call.name, call.arguments);
            try self.appendToolArgs(item, payload.delta);
        },
        .toolcall_end => |payload| {
            const item = try self.ensureToolItem(payload.tool_call.id, payload.tool_call.name, payload.tool_call.arguments);
            try self.setToolTitleFromValue(item, payload.tool_call.arguments);
        },
    }
}

fn applyMessageEnd(self: *Transcript, message: agent_mod.AgentMessage) !void {
    switch (message) {
        .assistant => |assistant| {
            const item = self.streaming_item orelse blk: {
                const created = try self.createAssistantItem(false);
                try self.appendItem(created);
                break :blk created;
            };
            self.streaming_item = null;
            std.debug.assert(item.kind == .assistant);
            item.kind.assistant.streaming = false;
            try self.reconcileAssistant(item, assistant);
            switch (assistant.stop_reason) {
                .aborted => {
                    item.kind.assistant.stop = .aborted;
                    try self.abortLiveTools();
                },
                .error_ => {
                    item.kind.assistant.stop = .errored;
                    item.kind.assistant.error_text = if (assistant.error_message) |err| try item.allocator().dupe(u8, err) else null;
                    try self.abortLiveTools();
                },
                else => item.kind.assistant.stop = .ok,
            }
            item.dirty = true;
        },
        .user, .tool_result, .custom => {},
    }
}

fn applyToolStart(self: *Transcript, io: std.Io, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args);
    std.debug.assert(item.kind == .tool);
    item.kind.tool.status = .running;
    item.kind.tool.started_ns = nowNs(io);
    item.dirty = true;
}

fn applyToolUpdate(self: *Transcript, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args);
    std.debug.assert(item.kind == .tool);
    for (payload.partial_result.content) |content| switch (content) {
        .text => |text| item.kind.tool.tail.update(text.text),
        .image => {},
    };
    item.dirty = true;
}

fn applyToolEnd(self: *Transcript, io: std.Io, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, .null);
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    tool.status = if (payload.is_error) .failed else .done;
    if (tool.started_ns) |started| tool.duration_ms = (nowNs(io) -| started) / std.time.ns_per_ms;
    try self.replaceToolBody(item, payload.result.content);
    _ = self.live_tools.orderedRemove(tool.call_id);
    item.dirty = true;
}

fn ensurePart(self: *Transcript, index: usize, tag: PartTag) !*Part {
    const item = self.streaming_item orelse blk: {
        const created = try self.createAssistantItem(true);
        self.streaming_item = created;
        try self.appendItem(created);
        break :blk created;
    };
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    var changed = false;
    while (assistant.parts.items.len <= index) {
        try assistant.parts.append(item.allocator(), .{ .text = .empty });
        changed = true;
    }
    const part = &assistant.parts.items[index];
    if (part.tag() != tag) {
        self.total_bytes -|= part.bytes().len;
        part.* = switch (tag) {
            .text => .{ .text = .empty },
            .thinking => .{ .thinking = .empty },
        };
        changed = true;
    }
    if (changed) item.dirty = true;
    return part;
}

fn appendAssistantPart(self: *Transcript, part: *Part, text: []const u8) !void {
    const item = self.streaming_item.?;
    const assistant = &item.kind.assistant;
    try self.appendListBounded(item, part.list(), text, per_item_text_bytes_max, &assistant.truncated, true);
}

fn replaceAssistantPart(self: *Transcript, part: *Part, text: []const u8) !void {
    if (std.mem.eql(u8, part.bytes(), text)) return;
    const item = self.streaming_item.?;
    const assistant = &item.kind.assistant;
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    try self.appendListBounded(item, part.list(), text, per_item_text_bytes_max, &assistant.truncated, true);
}

fn appendToolArgs(self: *Transcript, item: *Item, delta: []const u8) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    var truncated = false;
    try self.appendListBounded(item, &tool.args_preview, delta, blocks.args_preview_bytes_max, &truncated, false);
    tool.title = try blocks.titleFor(item.allocator(), tool.name, tool.args_preview.items);
    item.dirty = true;
}

fn setToolTitleFromValue(self: *Transcript, item: *Item, value: std.json.Value) !void {
    _ = self;
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    tool.title = try blocks.titleForValue(item.allocator(), tool.name, value);
    item.dirty = true;
}

fn replaceToolBody(self: *Transcript, item: *Item, content: []const ai.ToolResultContent) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    self.total_bytes -|= tool.body.items.len;
    tool.body.clearRetainingCapacity();
    var writer = std.Io.Writer.Allocating.init(item.allocator());
    errdefer writer.deinit();
    var truncated = false;
    try blocks.appendTextContent(&writer, content, blocks.tool_body_bytes_max, &truncated);
    try self.appendListBounded(item, &tool.body, writer.written(), blocks.tool_body_bytes_max, &tool.body_truncated, true);
    tool.body_truncated = tool.body_truncated or truncated;
}

fn reconcileAssistant(self: *Transcript, item: *Item, assistant_message: ai.AssistantMessage) !void {
    std.debug.assert(item.kind == .assistant);
    for (assistant_message.content, 0..) |content, index| switch (content) {
        .text => |text| {
            const part = try self.ensureFinalPart(item, index, .text);
            try self.replaceFinalPart(item, part, text.text);
        },
        .thinking => |thinking| {
            const part = try self.ensureFinalPart(item, index, .thinking);
            try self.replaceFinalPart(item, part, thinking.thinking);
        },
        .tool_call => |call| {
            const tool = try self.ensureToolItem(call.id, call.name, call.arguments);
            try self.setToolTitleFromValue(tool, call.arguments);
        },
    };
}

fn ensureFinalPart(self: *Transcript, item: *Item, index: usize, tag: PartTag) !*Part {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    while (assistant.parts.items.len <= index) {
        try assistant.parts.append(item.allocator(), .{ .text = .empty });
    }
    const part = &assistant.parts.items[index];
    if (part.tag() != tag) {
        self.total_bytes -|= part.bytes().len;
        part.* = switch (tag) {
            .text => .{ .text = .empty },
            .thinking => .{ .thinking = .empty },
        };
    }
    return part;
}

fn replaceFinalPart(self: *Transcript, item: *Item, part: *Part, text: []const u8) !void {
    if (std.mem.eql(u8, part.bytes(), text)) return;
    const assistant = &item.kind.assistant;
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    try self.appendListBounded(item, part.list(), text, per_item_text_bytes_max, &assistant.truncated, true);
}

fn findToolItem(self: *Transcript, call_id: []const u8) ?*Item {
    for (self.items.items) |item| {
        if (item.kind != .tool) continue;
        if (std.mem.eql(u8, item.kind.tool.call_id, call_id)) return item;
    }
    return null;
}
fn ensureToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value) !*Item {
    if (self.live_tools.get(call_id)) |item| return item;
    if (self.findToolItem(call_id)) |item| return item;
    const item = try self.createToolItem(call_id, name, args);
    try self.appendItem(item);
    try self.live_tools.put(self.gpa, item.kind.tool.call_id, item);
    return item;
}

fn createUserItem(self: *Transcript, text: []const u8) !*Item {
    const item = try self.createItem(.{ .user = .{ .text = .empty } });
    try self.appendListBounded(item, &item.kind.user.text, text, per_item_text_bytes_max, &item.kind.user.truncated, true);
    return item;
}

fn createAssistantItem(self: *Transcript, streaming: bool) !*Item {
    return self.createItem(.{ .assistant = .{ .parts = .empty, .streaming = streaming } });
}

fn createToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value) !*Item {
    const item = try self.createItem(.{ .tool = .{
        .call_id = undefined,
        .name = undefined,
        .title = undefined,
        .args_preview = .empty,
        .status = .pending,
        .body = .empty,
    } });
    const allocator = item.allocator();
    item.kind.tool.call_id = try allocator.dupe(u8, call_id);
    item.kind.tool.name = try allocator.dupe(u8, name);
    item.kind.tool.title = try blocks.titleForValue(allocator, name, args);
    return item;
}

fn createItem(self: *Transcript, kind: Item.Kind) !*Item {
    const item = try self.gpa.create(Item);
    errdefer self.gpa.destroy(item);
    item.* = .{
        .arena = std.heap.ArenaAllocator.init(self.gpa),
        .layout_arena = std.heap.ArenaAllocator.init(self.gpa),
        .seq = self.next_seq,
        .kind = kind,
    };
    self.next_seq +%= 1;
    return item;
}

fn appendItem(self: *Transcript, item: *Item) !void {
    try self.items.append(self.gpa, item);
}

fn appendListBounded(
    self: *Transcript,
    item: *Item,
    list: *std.ArrayList(u8),
    text: []const u8,
    max_bytes: usize,
    truncated: *bool,
    count_total: bool,
) !void {
    var remaining = text;
    while (remaining.len > 0) {
        if (list.items.len >= max_bytes) {
            try self.appendTruncationMarker(item, list, truncated, count_total);
            return;
        }
        const room = max_bytes - list.items.len;
        const chunk_len = @min(room, append_chunk_bytes_max, remaining.len);
        const chunk = agent_mod.utf8Prefix(remaining, chunk_len);
        if (chunk.len == 0) return;
        try list.appendSlice(item.allocator(), chunk);
        if (count_total) self.total_bytes += chunk.len;
        remaining = remaining[chunk.len..];
        if (chunk.len < chunk_len or chunk_len == room) {
            if (remaining.len > 0) try self.appendTruncationMarker(item, list, truncated, count_total);
            return;
        }
    }
    item.dirty = true;
}

fn appendTruncationMarker(self: *Transcript, item: *Item, list: *std.ArrayList(u8), truncated: *bool, count_total: bool) !void {
    if (truncated.*) return;
    truncated.* = true;
    const room = per_item_text_bytes_max -| list.items.len;
    if (list.items.len != 0 and list.items[list.items.len - 1] != '\n' and room > 0) {
        try list.append(item.allocator(), '\n');
        if (count_total) self.total_bytes += 1;
    }
    const remaining_room = per_item_text_bytes_max -| list.items.len;
    item.dirty = true;
    const chunk = agent_mod.utf8Prefix(output_truncated_text, remaining_room);
    try list.appendSlice(item.allocator(), chunk);
    if (count_total) self.total_bytes += chunk.len;
}

fn abortLiveTools(self: *Transcript) !void {
    for (self.live_tools.values()) |item| {
        if (item.kind != .tool) continue;
        switch (item.kind.tool.status) {
            .pending, .running => {
                item.kind.tool.status = .aborted;
                item.dirty = true;
            },
            else => {},
        }
    }
}

fn enforceCaps(self: *Transcript) !void {
    while (self.items.items.len > transcript_items_max or self.total_bytes > transcript_bytes_max) {
        if (self.items.items.len == 0) break;
        const item = self.items.orderedRemove(0);
        if (item.kind == .tool) _ = self.live_tools.orderedRemove(item.kind.tool.call_id);
        if (self.streaming_item == item) self.streaming_item = null;
        self.total_bytes -|= itemBytes(item);
        self.evicted_seqs += 1;
        self.destroyItem(item);
    }
}

fn destroyItem(self: *Transcript, item: *Item) void {
    item.layout_arena.deinit();
    item.arena.deinit();
    self.gpa.destroy(item);
}

fn itemBytes(item: *const Item) usize {
    return switch (item.kind) {
        .user => |user| user.text.items.len,
        .assistant => |assistant| blk: {
            var total: usize = 0;
            for (assistant.parts.items) |part| total += part.bytes().len;
            if (assistant.error_text) |err| total += err.len;
            break :blk total;
        },
        .tool => |tool| tool.args_preview.items.len + tool.body.items.len + tool.title.len + tool.call_id.len + tool.name.len,
        .notice => |notice| notice.text.len,
        .compaction => |compaction| compaction.summary_first_line.len,
    };
}

fn userText(user: ai.UserMessage) []const u8 {
    return switch (user.content) {
        .string => |text| text,
        .blocks => |blocks_slice| blk: {
            for (blocks_slice) |block| if (block == .text) break :blk block.text.text;
            break :blk "";
        },
    };
}

fn toolCallAt(message: ai.AssistantMessage, index: usize) ?ai.ToolCall {
    if (index >= message.content.len) return null;
    return switch (message.content[index]) {
        .tool_call => |call| call,
        else => null,
    };
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return text[0..end];
}

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn emptyAssistantMessage(content: []const ai.AssistantContent, stop_reason: ai.StopReason) ai.AssistantMessage {
    return .{
        .content = content,
        .api = ai.KnownApi.faux,
        .provider = ai.KnownProvider.faux,
        .model = "faux",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = stop_reason,
        .timestamp = 0,
    };
}

test "transcript applies streamed assistant text by delta" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .agent_start);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&content, .stop) } } });
    try transcript.apply(std.testing.io, .agent_end);

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    try std.testing.expect(!transcript.run_active);
    const item = transcript.items.items[0];
    try std.testing.expectEqualStrings("hello", item.kind.assistant.parts.items[0].text.items);
    try std.testing.expect(!item.kind.assistant.streaming);
}

test "transcript creates tool before execution and records output" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    var args_object: std.json.ObjectMap = .empty;
    defer args_object.deinit(std.testing.allocator);
    try args_object.put(std.testing.allocator, "path", .{ .string = "src/main.zig" });
    const call = ai.ToolCall{ .id = "call-1", .name = "read", .arguments = .{ .object = args_object } };
    const content = [_]ai.AssistantContent{.{ .tool_call = call }};
    const partial = emptyAssistantMessage(&content, .tool_use);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .tool_use) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .toolcall_start = .{
        .content_index = 0,
        .partial = partial,
    } } } });
    try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    const tool = transcript.items.items[1];
    try std.testing.expectEqualStrings("read src/main.zig", tool.kind.tool.title);

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "read", .args = .null } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "file body" } }};
    try transcript.apply(std.testing.io, .{ .tool_execution_update = .{ .tool_call_id = "call-1", .tool_name = "read", .args = .null, .partial_result = .{ .content = &result_content } } });
    try transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "call-1", .tool_name = "read", .result = .{ .content = &result_content }, .is_error = false } });

    try std.testing.expectEqual(blocks.Status.done, tool.kind.tool.status);
    try std.testing.expectEqualStrings("file body", tool.kind.tool.body.items);
    try std.testing.expect(transcript.live_tools.get("call-1") == null);
}

test "transcript aborts running tools on aborted assistant end" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .aborted) } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .aborted) } } });

    try std.testing.expectEqual(blocks.Status.aborted, transcript.items.items[0].kind.tool.status);
}

test "transcript evicts oldest items past item cap" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    for (0..transcript_items_max + 1) |index| {
        var buffer: [32]u8 = undefined;
        const text = try std.fmt.bufPrint(&buffer, "msg-{d}", .{index});
        try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } } } });
    }

    try std.testing.expectEqual(@as(usize, transcript_items_max), transcript.items.items.len);
    try std.testing.expectEqual(@as(u64, 1), transcript.evicted_seqs);
    try std.testing.expectEqualStrings("msg-1", transcript.items.items[0].kind.user.text.items);
}

test {
    std.testing.refAllDecls(@This());
}
