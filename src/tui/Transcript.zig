const std = @import("std");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const runtime = @import("../runtime/root.zig");
const blocks = @import("blocks.zig");
const glyphs = @import("glyphs.zig");
const layout = @import("layout.zig");
const screen = @import("screen.zig");
const theme = @import("theme.zig");

pub const append_chunk_bytes_max: usize = 8 * 1024;
pub const per_item_text_bytes_max: usize = 256 * 1024;
pub const transcript_items_max: usize = 2000;
pub const transcript_bytes_max: usize = 8 * 1024 * 1024;
const output_truncated_text = "[output truncated]";
const transcript_padding_x: usize = 1;
const user_padding_y: usize = 1;
const item_margin_bottom: usize = 1;
const padding_spaces = " " ** 16;

pub const Transcript = @This();

gpa: std.mem.Allocator,
items: std.ArrayList(*Item) = .empty,
live_tools: std.StringArrayHashMapUnmanaged(*Item) = .empty,
streaming_item: ?*Item = null,
total_bytes: usize = 0,
next_seq: u64 = 0,
evicted_seqs: u64 = 0,
run_active: bool = false,
tool_resolver: ToolResolver = .{},

pub const ToolArgs = union(enum) {
    value: std.json.Value,
    json_prefix: []const u8,
};

pub const ToolBodyUpdate = union(enum) {
    unchanged,
    clear,
    replace: struct {
        body: []const u8,
        footer: []const u8 = "",
    },
};

pub const ToolUi = struct {
    title: ?[]const u8 = null,
    compact_title: ?[]const u8 = null,
    display: blocks.ToolDisplay = blocks.default_tool_display,
    body_update: ToolBodyUpdate = .unchanged,
};

pub const ToolResultUi = struct {
    body: ?[]const u8 = null,
    footer: ?[]const u8 = null,
};

pub const ToolResolver = struct {
    context: ?*anyopaque = null,
    call_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, ToolArgs) anyerror!ToolUi = defaultToolResolver,
    result_fn: *const fn (?*anyopaque, std.mem.Allocator, []const u8, bool, []const ai.ToolResultContent, ?std.json.Value) anyerror!ToolResultUi = defaultToolResultResolver,

    fn resolve(self: ToolResolver, allocator: std.mem.Allocator, name: []const u8, args: ToolArgs) !ToolUi {
        return self.call_fn(self.context, allocator, name, args);
    }

    fn resolveResult(self: ToolResolver, allocator: std.mem.Allocator, name: []const u8, is_error: bool, content: []const ai.ToolResultContent, details: ?std.json.Value) !ToolResultUi {
        return self.result_fn(self.context, allocator, name, is_error, content, details);
    }
};

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
            compact_title: []const u8,
            display: blocks.ToolDisplay,
            args_preview: std.ArrayList(u8),
            args_truncated: bool = false,
            status: blocks.Status,
            started_ns: ?u64 = null,
            elapsed_ms: ?u64 = null,
            duration_ms: ?u64 = null,
            tail: blocks.TailBuffer = .{},
            body: std.ArrayList(u8),
            body_truncated: bool = false,
            details_present: bool = false,
            footer: []const u8,
        },
        notice: struct { level: NoticeLevel, text: []const u8 },
        compaction: struct { summary_first_line: []const u8, tokens_before: u64 },
        custom: struct { title: []const u8, text: []const u8 },
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

pub fn initWithToolResolver(gpa: std.mem.Allocator, tool_resolver: ToolResolver) Transcript {
    return .{ .gpa = gpa, .tool_resolver = tool_resolver };
}

pub fn deinit(self: *Transcript) void {
    for (self.items.items) |item| self.destroyItem(item);
    self.items.deinit(self.gpa);
    self.live_tools.deinit(self.gpa);
    self.* = undefined;
}

pub fn clear(self: *Transcript) void {
    for (self.items.items) |item| self.destroyItem(item);
    self.items.clearRetainingCapacity();
    self.live_tools.clearRetainingCapacity();
    self.streaming_item = null;
    self.total_bytes = 0;
    self.next_seq = 0;
    self.evicted_seqs = 0;
    self.run_active = false;
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

pub fn markRunningToolsDirty(self: *Transcript, now_ns: u64) bool {
    var changed = false;
    for (self.live_tools.values()) |item| {
        if (item.kind == .tool and item.kind.tool.status == .running) {
            if (item.kind.tool.started_ns) |started| item.kind.tool.elapsed_ms = (now_ns -| started) / std.time.ns_per_ms;
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
    const content_lines = switch (item.kind) {
        .user => |*user| blk: {
            const lines = try layout.wrapPlain(allocator, user.text.items, transcriptInnerWidth(width), screen.styles.panel);
            for (lines) |*line| line.row_style = screen.styles.panel;
            break :blk lines;
        },
        .assistant => |*assistant| try layoutAssistant(allocator, assistant, transcriptInnerWidth(width), epoch),
        .tool => |*tool| try blocks.layoutTool(allocator, tool, transcriptInnerWidth(width), epoch.expanded),
        .notice => |notice| try layout.wrapPlain(allocator, notice.text, transcriptInnerWidth(width), noticeStyle(notice.level)),
        .compaction => |compaction| blk: {
            var buffer: [256]u8 = undefined;
            const text = std.fmt.bufPrint(&buffer, "context compacted: {s}", .{compaction.summary_first_line}) catch "context compacted";
            const owned = try allocator.dupe(u8, text);
            break :blk try layout.wrapPlain(allocator, owned, transcriptInnerWidth(width), screen.styles.muted);
        },
        .custom => |custom| try layoutCustom(allocator, custom, transcriptInnerWidth(width)),
    };
    item.lines = try applyItemRhythm(allocator, item.kind, content_lines);
    item.cached_width = width;
    item.cached_epoch = epoch_value;
    item.dirty = false;
    return item.lines;
}

fn layoutAssistant(allocator: std.mem.Allocator, assistant: anytype, width: u16, epoch: theme.LayoutEpoch) ![]layout.Line {
    var text: std.Io.Writer.Allocating = .init(allocator);
    errdefer text.deinit();
    var hidden_thinking_shown = false;
    var wrote_text = false;
    var wrote_thinking = false;
    for (assistant.parts.items) |part| {
        switch (part) {
            .text => |value| {
                if (value.items.len > 0 and hidden_thinking_shown and text.written().len > 0 and text.written()[text.written().len - 1] != '\n') try text.writer.writeAll("\n");
                if (value.items.len > 0) wrote_text = true;
                try text.writer.writeAll(value.items);
            },
            .thinking => |value| {
                if (epoch.hide_thinking) {
                    if (assistant.streaming and value.items.len > 0 and !hidden_thinking_shown) {
                        try text.writer.writeAll("Thinking...");
                        hidden_thinking_shown = true;
                        wrote_thinking = true;
                    }
                } else {
                    const visible = trimTrailingNewlines(value.items);
                    if (visible.len > 0) wrote_thinking = true;
                    try text.writer.writeAll(visible);
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
    const style = if (assistant.stop != .ok) screen.styles.error_ else if (!wrote_text and wrote_thinking) thinkingStyle() else screen.styles.normal;
    var wrap_state: layout.WrapState = .{};
    return layout.wrapMarkdown(allocator, text.written(), width, style, &wrap_state);
}

fn thinkingStyle() screen.Style {
    var style = screen.styles.muted;
    style.italic = true;
    return style;
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
        .custom => |custom| try self.appendCustom(custom),
        .tool_result => {},
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
            if (toolCallAt(payload.partial, payload.content_index)) |call| _ = try self.ensureToolItem(call.id, call.name, call.arguments, true);
        },
        .toolcall_delta => |payload| {
            const call = toolCallAt(payload.partial, payload.content_index) orelse return;
            const item = try self.ensureToolItem(call.id, call.name, call.arguments, true);
            try self.appendToolArgs(item, payload.delta);
            try self.applyToolArgsPreview(item, call.arguments);
        },
        .toolcall_end => |payload| {
            const item = try self.ensureToolItem(payload.tool_call.id, payload.tool_call.name, payload.tool_call.arguments, true);
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
                    if (assistant.error_message) |err| {
                        item.kind.assistant.error_text = try item.allocator().dupe(u8, err);
                        self.total_bytes += item.kind.assistant.error_text.?.len;
                    } else {
                        item.kind.assistant.error_text = null;
                    }
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
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args, true);
    std.debug.assert(item.kind == .tool);
    item.kind.tool.status = mergeToolStatus(item.kind.tool.status, .running);
    item.kind.tool.started_ns = nowNs(io);
    item.kind.tool.elapsed_ms = 0;
    item.dirty = true;
}

fn applyToolUpdate(self: *Transcript, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, payload.args, false);
    std.debug.assert(item.kind == .tool);
    for (payload.partial_result.content) |content| switch (content) {
        .text => |text| if (item.kind.tool.display.live_updates == .show_tail) item.kind.tool.tail.update(text.text),
        .image => {},
    };
    item.dirty = true;
}

fn applyToolEnd(self: *Transcript, io: std.Io, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
    const item = try self.ensureToolItem(payload.tool_call_id, payload.tool_name, .null, false);
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    const result_status: blocks.Status = if (payload.is_error) .failed else .done;
    tool.status = mergeToolStatus(tool.status, result_status);
    if (tool.started_ns) |started| tool.duration_ms = (nowNs(io) -| started) / std.time.ns_per_ms;
    tool.elapsed_ms = null;
    tool.details_present = payload.result.details != null;
    const result_ui = try self.tool_resolver.resolveResult(item.allocator(), payload.tool_name, payload.is_error, payload.result.content, payload.result.details);
    if (result_ui.body) |body| try self.replaceToolBody(item, body);
    if (result_ui.footer) |footer| try self.replaceToolFooter(item, footer);
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
    const preview_len = tool.args_preview.items.len;
    const was_truncated = tool.args_truncated;
    try self.appendListBounded(item, &tool.args_preview, delta, blocks.args_preview_bytes_max, &tool.args_truncated, false);
    if (tool.args_preview.items.len == preview_len and tool.args_truncated == was_truncated) return;
    const ui = try self.tool_resolver.resolve(item.allocator(), tool.name, .{ .json_prefix = tool.args_preview.items });
    try self.applyToolUi(item, ui);
}

fn applyToolArgsPreview(self: *Transcript, item: *Item, value: std.json.Value) !void {
    if (!hasToolArgsPreview(value)) return;
    try self.setToolTitleFromValue(item, value);
}

fn hasToolArgsPreview(value: std.json.Value) bool {
    if (value != .object) return false;
    return value.object.count() != 0;
}

fn setToolTitleFromValue(self: *Transcript, item: *Item, value: std.json.Value) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    const ui = try self.tool_resolver.resolve(item.allocator(), tool.name, .{ .value = value });
    try self.applyToolUi(item, ui);
}

fn applyToolUi(self: *Transcript, item: *Item, ui: ToolUi) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    if (ui.title) |title| tool.title = title;
    if (ui.compact_title) |compact_title| tool.compact_title = compact_title;
    tool.display = ui.display;
    try self.applyToolBodyUpdate(item, ui.body_update);
    item.dirty = true;
}

fn applyToolBodyUpdate(self: *Transcript, item: *Item, update: ToolBodyUpdate) !void {
    switch (update) {
        .unchanged => {},
        .clear => {
            try self.replaceToolBody(item, "");
            try self.replaceToolFooter(item, "");
        },
        .replace => |replace| {
            try self.replaceToolBody(item, replace.body);
            try self.replaceToolFooter(item, replace.footer);
        },
    }
}

fn replaceToolBody(self: *Transcript, item: *Item, body: ?[]const u8) !void {
    std.debug.assert(item.kind == .tool);
    const tool = &item.kind.tool;
    self.total_bytes -|= tool.body.items.len;
    tool.body.clearRetainingCapacity();
    tool.body_truncated = false;
    const text = body orelse {
        item.dirty = true;
        return;
    };
    try self.appendListBounded(item, &tool.body, text, blocks.tool_body_bytes_max, &tool.body_truncated, true);
}

fn replaceToolFooter(_: *Transcript, item: *Item, footer: ?[]const u8) !void {
    std.debug.assert(item.kind == .tool);
    item.kind.tool.footer = if (footer) |value| value else "";
    item.dirty = true;
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
            self.clearFinalPart(item, index);
            const tool = try self.ensureToolItem(call.id, call.name, call.arguments, true);
            try self.setToolTitleFromValue(tool, call.arguments);
        },
    };
    self.truncateFinalParts(item, assistant_message.content.len);
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

fn clearFinalPart(self: *Transcript, item: *Item, index: usize) void {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    if (index >= assistant.parts.items.len) return;
    const part = &assistant.parts.items[index];
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    part.* = .{ .text = .empty };
    item.dirty = true;
}

fn truncateFinalParts(self: *Transcript, item: *Item, len: usize) void {
    std.debug.assert(item.kind == .assistant);
    const assistant = &item.kind.assistant;
    if (assistant.parts.items.len <= len) return;
    for (assistant.parts.items[len..]) |part| self.total_bytes -|= part.bytes().len;
    assistant.parts.items.len = len;
    item.dirty = true;
}

fn replaceFinalPart(self: *Transcript, item: *Item, part: *Part, text: []const u8) !void {
    if (std.mem.eql(u8, part.bytes(), text)) return;
    const assistant = &item.kind.assistant;
    self.total_bytes -|= part.bytes().len;
    part.list().clearRetainingCapacity();
    try self.appendListBounded(item, part.list(), text, per_item_text_bytes_max, &assistant.truncated, true);
}

fn findToolItem(self: *Transcript, call_id: []const u8) ?*Item {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = self.items.items[index];
        if (item.kind != .tool) continue;
        if (std.mem.eql(u8, item.kind.tool.call_id, call_id)) return item;
    }
    return null;
}

fn ensureToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value, create_new_if_terminal: bool) !*Item {
    if (self.live_tools.get(call_id)) |item| return item;
    if (self.findToolItem(call_id)) |item| {
        if (!create_new_if_terminal or !isTerminalToolStatus(item.kind.tool.status)) return item;
    }
    const item = try self.createToolItem(call_id, name, args);
    try self.appendItem(item);
    try self.live_tools.put(self.gpa, item.kind.tool.call_id, item);
    return item;
}

fn isTerminalToolStatus(status: blocks.Status) bool {
    return switch (status) {
        .done, .failed, .aborted => true,
        .pending, .running => false,
    };
}

fn mergeToolStatus(old: blocks.Status, new: blocks.Status) blocks.Status {
    return switch (old) {
        .aborted => .aborted,
        .done, .failed => if (new == .running or new == .pending) old else new,
        .pending, .running => new,
    };
}

fn appendCustom(self: *Transcript, custom: agent_mod.CustomAgentMessage) !void {
    const item = try self.createCustomItem(custom);
    try self.appendItem(item);
    try self.enforceCaps();
}

fn createUserItem(self: *Transcript, text: []const u8) !*Item {
    const item = try self.createItem(.{ .user = .{ .text = .empty } });
    try self.appendListBounded(item, &item.kind.user.text, text, per_item_text_bytes_max, &item.kind.user.truncated, true);
    return item;
}

fn createAssistantItem(self: *Transcript, streaming: bool) !*Item {
    return self.createItem(.{ .assistant = .{ .parts = .empty, .streaming = streaming } });
}

fn createCustomItem(self: *Transcript, custom: agent_mod.CustomAgentMessage) !*Item {
    const item = try self.createItem(.{ .custom = .{ .title = undefined, .text = undefined } });
    const allocator = item.allocator();
    item.kind.custom.title = try allocator.dupe(u8, custom.kind);
    item.kind.custom.text = try jsonValueString(allocator, custom.payload);
    self.total_bytes += item.kind.custom.title.len + item.kind.custom.text.len;
    return item;
}

fn createToolItem(self: *Transcript, call_id: []const u8, name: []const u8, args: std.json.Value) !*Item {
    const item = try self.createItem(.{ .tool = .{
        .call_id = undefined,
        .name = undefined,
        .title = undefined,
        .compact_title = undefined,
        .display = blocks.default_tool_display,
        .args_preview = .empty,
        .body = .empty,
        .status = .pending,
        .footer = "",
    } });
    const allocator = item.allocator();
    item.kind.tool.call_id = try allocator.dupe(u8, call_id);
    item.kind.tool.name = try allocator.dupe(u8, name);
    const ui = try self.tool_resolver.resolve(allocator, name, .{ .value = args });
    item.kind.tool.title = ui.title orelse try allocator.dupe(u8, name);
    item.kind.tool.compact_title = ui.compact_title orelse "";
    item.kind.tool.display = ui.display;
    try self.applyToolBodyUpdate(item, ui.body_update);
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
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
        const room = max_bytes - list.items.len;
        const chunk_len = @min(room, append_chunk_bytes_max, remaining.len);
        const chunk = agent_mod.utf8Prefix(remaining, chunk_len);
        if (chunk.len == 0) {
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
        try list.appendSlice(item.allocator(), chunk);
        if (count_total) self.total_bytes += chunk.len;
        remaining = remaining[chunk.len..];
        if (remaining.len == 0) {
            item.dirty = true;
            return;
        }
        if (chunk_len == room) {
            try self.appendTruncationMarker(item, list, max_bytes, truncated, count_total);
            return;
        }
    }
    item.dirty = true;
}

fn appendTruncationMarker(self: *Transcript, item: *Item, list: *std.ArrayList(u8), max_bytes: usize, truncated: *bool, count_total: bool) !void {
    if (truncated.*) return;
    truncated.* = true;
    const room = max_bytes -| list.items.len;
    if (list.items.len != 0 and list.items[list.items.len - 1] != '\n' and room > 0) {
        try list.append(item.allocator(), '\n');
        if (count_total) self.total_bytes += 1;
    }
    const remaining_room = max_bytes -| list.items.len;
    item.dirty = true;
    const chunk = agent_mod.utf8Prefix(blocks.output_truncated_text, remaining_room);
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
        .tool => |tool| tool.body.items.len,
        .notice => |notice| notice.text.len,
        .compaction => |compaction| compaction.summary_first_line.len,
        .custom => |custom| custom.title.len + custom.text.len,
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

test "transcript user block has panel padding and item margin" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } } } });
    const epoch = theme.LayoutEpoch{ .width = 40, .height = 10 };
    const lines = try transcript.itemLines(transcript.items.items[0], 40, epoch);

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings("", lines[0].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[0].row_style.bg, screen.styles.panel.bg));
    try std.testing.expectEqualStrings(" hello", lines[1].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[1].row_style.bg, screen.styles.panel.bg));
    try std.testing.expectEqualStrings("", lines[2].copyText(&buffer));
    try std.testing.expect(std.meta.eql(lines[2].row_style.bg, screen.styles.panel.bg));
    try std.testing.expectEqualStrings("", lines[3].copyText(&buffer));
    try std.testing.expect(screen.Style.eql(lines[3].row_style, screen.styles.normal));
}

test "transcript visible thinking trims trailing blank rows" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const content = [_]ai.AssistantContent{.{ .thinking = .{ .thinking = "**plan** first\n\n" } }};
    const assistant = emptyAssistantMessage(&content, .stop);
    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = assistant } } });
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = assistant } } });
    const epoch = theme.LayoutEpoch{ .width = 60, .height = 10, .hide_thinking = false };
    const lines = try transcript.itemLines(transcript.items.items[0], 60, epoch);

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings(" plan first", lines[0].copyText(&buffer));
    try std.testing.expect(lines[0].spans()[1].style.italic);
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
}

test "transcript custom message renders title body and margin" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .custom = .{ .kind = "Session Info", .payload = .{ .string = "ok" }, .timestamp = 0 } } } });
    const epoch = theme.LayoutEpoch{ .width = 40, .height = 10 };
    const lines = try transcript.itemLines(transcript.items.items[0], 40, epoch);

    var buffer: [64]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), lines.len);
    try std.testing.expectEqualStrings(" Session Info", lines[0].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[1].copyText(&buffer));
    try std.testing.expectEqualStrings(" \"ok\"", lines[2].copyText(&buffer));
    try std.testing.expectEqualStrings("", lines[3].copyText(&buffer));
}

fn toolCallAt(message: ai.AssistantMessage, index: usize) ?ai.ToolCall {
    if (index >= message.content.len) return null;
    return switch (message.content[index]) {
        .tool_call => |call| call,
        else => null,
    };
}

fn transcriptInnerWidth(width: u16) u16 {
    const padding = transcript_padding_x * 2;
    return if (width <= padding) 0 else @intCast(@as(usize, width) - padding);
}

fn applyItemRhythm(allocator: std.mem.Allocator, kind: Item.Kind, content: []layout.Line) ![]layout.Line {
    if (content.len == 0) return &.{};
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    const style = itemStyle(kind);
    const padding_y = itemPaddingY(kind);
    try out.ensureTotalCapacity(allocator, content.len + padding_y * 2 + item_margin_bottom);

    for (0..padding_y) |_| try out.append(allocator, .{ .row_style = style });
    for (content) |source| {
        var line = source;
        if (line.spans().len > 0) try insetTranscriptLine(&line, lineInsetStyle(kind, line));
        try out.append(allocator, line);
    }
    for (0..padding_y) |_| try out.append(allocator, .{ .row_style = style });
    for (0..item_margin_bottom) |_| try out.append(allocator, .{});
    return out.toOwnedSlice(allocator);
}

fn itemPaddingY(kind: Item.Kind) usize {
    return switch (kind) {
        .user => user_padding_y,
        else => 0,
    };
}

fn itemStyle(kind: Item.Kind) screen.Style {
    return switch (kind) {
        .user => screen.styles.panel,
        .assistant => screen.styles.normal,
        .tool => screen.styles.muted,
        .notice => |notice| noticeStyle(notice.level),
        .compaction => screen.styles.muted,
        .custom => screen.styles.normal,
    };
}

fn lineInsetStyle(kind: Item.Kind, line: layout.Line) screen.Style {
    if (line.spans().len > 0) return line.spans()[0].style;
    return itemStyle(kind);
}

fn insetTranscriptLine(line: *layout.Line, style: screen.Style) error{LineFull}!void {
    if (transcript_padding_x == 0) return;
    try line.prepend(.{ .text = padding_spaces[0..transcript_padding_x], .style = style });
}

fn layoutCustom(allocator: std.mem.Allocator, custom: anytype, width: u16) ![]layout.Line {
    var out = std.ArrayList(layout.Line).empty;
    errdefer out.deinit(allocator);
    if (custom.title.len > 0) {
        try layout.appendPlainLine(allocator, &out, custom.title, width, screen.styles.accent);
        try out.append(allocator, .{});
    }
    var state: layout.WrapState = .{};
    const body = try layout.wrapMarkdown(allocator, custom.text, width, screen.styles.normal, &state);
    try out.appendSlice(allocator, body);
    return out.toOwnedSlice(allocator);
}

fn trimTrailingNewlines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and (text[end - 1] == '\n' or text[end - 1] == '\r')) : (end -= 1) {}
    return text[0..end];
}

fn jsonValueString(allocator: std.mem.Allocator, value: std.json.Value) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var stringify: std.json.Stringify = .{ .writer = &writer.writer };
    try stringify.write(value);
    return writer.toOwnedSlice();
}

fn firstLine(text: []const u8) []const u8 {
    const end = std.mem.indexOfAny(u8, text, "\r\n") orelse text.len;
    return text[0..end];
}

fn nowNs(io: std.Io) u64 {
    const raw = std.Io.Timestamp.now(io, .awake).toNanoseconds();
    return if (raw <= 0) 0 else @intCast(raw);
}

fn defaultToolResolver(_: ?*anyopaque, allocator: std.mem.Allocator, name: []const u8, _: ToolArgs) anyerror!ToolUi {
    return .{ .title = try allocator.dupe(u8, name), .display = blocks.default_tool_display };
}

fn defaultToolResultResolver(_: ?*anyopaque, allocator: std.mem.Allocator, _: []const u8, _: bool, content: []const ai.ToolResultContent, _: ?std.json.Value) anyerror!ToolResultUi {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var truncated = false;
    try blocks.appendTextContent(&writer, content, blocks.tool_body_bytes_max, &truncated);
    return .{ .body = try writer.toOwnedSlice() };
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

test "transcript final assistant message removes stale streamed parts" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .assistant = emptyAssistantMessage(&.{}, .stop) } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 0,
        .delta = "hello",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    try transcript.apply(std.testing.io, .{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
        .content_index = 1,
        .delta = "stale",
        .partial = emptyAssistantMessage(&.{}, .stop),
    } } } });
    const content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
    try transcript.apply(std.testing.io, .{ .message_end = .{ .message = .{ .assistant = emptyAssistantMessage(&content, .stop) } } });

    const assistant = &transcript.items.items[0].kind.assistant;
    try std.testing.expectEqual(@as(usize, 1), assistant.parts.items.len);
    try std.testing.expectEqualStrings("hello", assistant.parts.items[0].text.items);
}

test "transcript bounds streamed tool args preview once" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "args-1", .tool_name = "bash", .args = .null } });
    const item = transcript.items.items[0];
    const delta = try std.testing.allocator.alloc(u8, blocks.args_preview_bytes_max + 100);
    defer std.testing.allocator.free(delta);
    @memset(delta, 'a');

    try transcript.appendToolArgs(item, delta);
    try std.testing.expect(item.kind.tool.args_truncated);
    try std.testing.expect(item.kind.tool.args_preview.items.len <= blocks.args_preview_bytes_max);
    const len_after_truncation = item.kind.tool.args_preview.items.len;
    try transcript.appendToolArgs(item, "extra");
    try std.testing.expectEqual(len_after_truncation, item.kind.tool.args_preview.items.len);
}

test "transcript bounded append continues across UTF-8 chunk boundary" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    const text = try std.testing.allocator.alloc(u8, append_chunk_bytes_max + 2);
    defer std.testing.allocator.free(text);
    @memset(text[0 .. append_chunk_bytes_max - 1], 'a');
    text[append_chunk_bytes_max - 1] = 0xc3;
    text[append_chunk_bytes_max] = 0xa9;
    text[append_chunk_bytes_max + 1] = 'b';

    try transcript.apply(std.testing.io, .{ .message_start = .{ .message = .{ .user = .{ .content = .{ .string = text }, .timestamp = 0 } } } });

    const user = transcript.items.items[0].kind.user;
    try std.testing.expect(!user.truncated);
    try std.testing.expectEqualStrings(text, user.text.items);
    try std.testing.expect(std.mem.indexOf(u8, user.text.items, output_truncated_text) == null);
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
    try std.testing.expectEqualStrings("read", tool.kind.tool.title);

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

test "transcript reused terminal tool id starts a new live item" {
    var transcript = Transcript.init(std.testing.allocator);
    defer transcript.deinit();

    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "done" } }};
    try transcript.apply(std.testing.io, .{ .tool_execution_end = .{ .tool_call_id = "call-1", .tool_name = "bash", .result = .{ .content = &result_content }, .is_error = false } });
    try transcript.apply(std.testing.io, .{ .tool_execution_start = .{ .tool_call_id = "call-1", .tool_name = "bash", .args = .null } });

    try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    try std.testing.expectEqual(blocks.Status.done, transcript.items.items[0].kind.tool.status);
    try std.testing.expectEqual(blocks.Status.running, transcript.items.items[1].kind.tool.status);
    try std.testing.expect(transcript.live_tools.get("call-1").? == transcript.items.items[1]);
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
