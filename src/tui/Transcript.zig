//! Bounded resident transcript. This is a *view window*, not history:
//! durable truth lives in the session store. Live-tail appends evict oldest;
//! history-page prepends evict newest so the resident window can slide back.
//!
//! Bounds:
//!   - item_count_max items, total_size_bytes_max resident text bytes
//!   - one append is capped at append_size_bytes_max (callers chunk)
//!   - one tool's retained output preview is capped at tool_preview_bytes_max,
//!     deliberately 1/8 of the total so a single chatty tool cannot evict the
//!     whole visible conversation
//!
//! All ingest is operational-input total: invalid UTF-8 is replaced with
//! U+FFFD, a codepoint split across streamed deltas is carried in a 3-byte
//! pending tail per streamed item, oversize appends truncate and report.
//! Stored text is therefore always valid UTF-8.
const std = @import("std");
const text_mod = @import("text.zig");

const Transcript = @This();

pub const item_count_max: usize = 200;
pub const total_size_bytes_max: usize = 256 * 1024;
pub const append_size_bytes_max: usize = 8 * 1024;
pub const source_id_bytes_max: usize = 256;
pub const tool_preview_bytes_max: usize = total_size_bytes_max / 8;
pub const tool_preview_lines_max: usize = 1024;

items: std.ArrayList(Item) = .empty,
total_size_bytes: usize = 0,
revision: u64 = 0,

pub const Role = enum { user, assistant, system, thinking };
pub const StatusLevel = enum { info, warning, err };
pub const ToolPresentation = enum { generic, command, file, patch };
pub const ToolStatus = enum { pending, success, err, canceled };
pub const ToolBodyMode = enum { visible, hidden_on_success };
pub const ToolCollapseMode = enum { head, tail };

/// Collapsed-view window over a tool's output, measured in physical
/// newline-delimited lines like pi-mono. Rendering wraps the selected lines
/// after collapse. Bash keeps the tail (errors live at the end); file/patch
/// tools keep the head. Expansion (ctrl+o) shows the full retained preview.
pub const ToolCollapse = struct {
    mode: ToolCollapseMode = .tail,
    lines_max: u8 = 5,
};

pub const AppendMode = enum { new_item, extend_previous_assistant_message, extend_previous_same_role };

pub const CustomFormat = enum { plain, markdown };

pub const Append = union(enum) {
    message: MessageAppend,
    thinking: ThinkingAppend,
    status: StatusAppend,
    tool: ToolAppend,
    custom: CustomAppend,

    pub const MessageAppend = struct {
        role: Role,
        text: []const u8,
        mode: AppendMode = .new_item,
        source_id: ?[]const u8 = null,
    };
    pub const ThinkingAppend = struct {
        text: []const u8,
        hidden: bool = true,
        mode: AppendMode = .extend_previous_same_role,
        source_id: ?[]const u8 = null,
    };
    pub const StatusAppend = struct {
        level: StatusLevel,
        text: []const u8,
    };
    pub const CustomAppend = struct {
        title: []const u8 = "",
        text: []const u8,
        format: CustomFormat = .plain,
    };
    pub const ToolAppend = struct {
        tool_call_id: []const u8,
        name: []const u8,
        source_id: ?[]const u8 = null,
        presentation: ToolPresentation = .generic,
        status: ToolStatus = .pending,
        body_mode: ToolBodyMode = .visible,
        collapse: ToolCollapse = .{},
        title: []const u8 = "",
        compact_title: []const u8 = "",
        output: []const u8 = "",
        footer: []const u8 = "",
    };
};

pub const Prepend = struct {
    thinking: ?Append.ThinkingAppend = null,
    message: ?Append.MessageAppend = null,
    tools: []const Append.ToolAppend = &.{},
};

/// Degradations the caller may want to surface; never an error.
pub const Outcome = struct {
    truncated: bool = false,
};

/// Per-item wrapped-row memo, owned by render. Valid when `version` matches
/// the item's version and (width, expanded) match the current viewport, so
/// scroll accounting is O(items), not O(resident bytes), per frame.
pub const Layout = struct {
    rows: u32 = 0,
    width: u16 = 0,
    expanded: bool = false,
    version: u32 = 0, // 0 never matches a live item version
    markdown_width: u16 = 0,
    markdown_stable_end: usize = 0,
    markdown_stable_rows: u32 = 0,
    markdown_fence: MarkdownFence = .none,
};

pub const MarkdownFence = enum { none, backtick, tilde };

pub const Item = struct {
    version: u32 = 1,
    layout: Layout = .{},
    source_id: ?[]u8 = null,
    body: Body,

    pub const Body = union(enum) {
        message: Message,
        thinking: Thinking,
        status: Status,
        tool: Tool,
        custom: Custom,
    };

    fn deinitBody(self: *Item, gpa: std.mem.Allocator) void {
        if (self.source_id) |source_id| gpa.free(source_id);
        switch (self.body) {
            .message => |*message| message.text.deinit(gpa),
            .thinking => |*thinking| thinking.text.deinit(gpa),
            .status => |status| gpa.free(status.text),
            .custom => |*custom| {
                gpa.free(custom.title);
                gpa.free(custom.text);
            },
            .tool => |*tool| {
                gpa.free(tool.id);
                gpa.free(tool.name);
                gpa.free(tool.title);
                gpa.free(tool.compact_title);
                tool.output.deinit(gpa);
                gpa.free(tool.footer);
            },
        }
        self.* = undefined;
    }

    pub fn sizeBytes(self: *const Item) usize {
        return switch (self.body) {
            .message => |message| message.text.items.len,
            .thinking => |thinking| thinking.text.items.len,
            .status => |status| status.text.len,
            .custom => |custom| custom.title.len + custom.text.len,
            .tool => |tool| tool.sizeBytes(),
        };
    }
};

pub const Message = struct {
    role: Role,
    text: std.ArrayList(u8) = .empty,
    pending: PendingUtf8 = .{},
};

pub const Thinking = struct {
    text: std.ArrayList(u8) = .empty,
    pending: PendingUtf8 = .{},
    hidden: bool = true,
};

pub const Status = struct {
    level: StatusLevel,
    text: []u8,
};

pub const Custom = struct {
    title: []u8,
    text: []u8,
    format: CustomFormat,
};

pub const Tool = struct {
    id: []u8,
    name: []u8,
    presentation: ToolPresentation,
    status: ToolStatus,
    body_mode: ToolBodyMode,
    collapse: ToolCollapse,
    title: []u8,
    compact_title: []u8,
    output: std.ArrayList(u8) = .empty,
    footer: []u8,
    pending: PendingUtf8 = .{},
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,

    pub fn sizeBytes(self: *const Tool) usize {
        return self.id.len +
            self.name.len +
            self.title.len +
            self.compact_title.len +
            self.output.items.len +
            self.footer.len;
    }
};

pub fn deinit(self: *Transcript, gpa: std.mem.Allocator) void {
    for (self.items.items) |*item| item.deinitBody(gpa);
    self.items.deinit(gpa);
    self.* = undefined;
}

pub fn clear(self: *Transcript, gpa: std.mem.Allocator) void {
    for (self.items.items) |*item| item.deinitBody(gpa);
    self.items.clearRetainingCapacity();
    self.total_size_bytes = 0;
    self.revision +%= 1;
}

pub fn oldestSourceId(self: *const Transcript) ?[]const u8 {
    for (self.items.items) |*item| {
        if (item.source_id) |source_id| return source_id;
    }
    return null;
}

pub fn newestSourceId(self: *const Transcript) ?[]const u8 {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        if (self.items.items[index].source_id) |source_id| return source_id;
    }
    return null;
}

pub const SourceTag = union(enum) {
    latest_message: SourceMessage,
    latest_assistant_run: []const u8,
    latest_tool: SourceTool,

    pub const SourceMessage = struct {
        role: Role,
        source_id: []const u8,
    };
    pub const SourceTool = struct {
        tool_call_id: []const u8,
        source_id: []const u8,
    };
};

pub fn tagSource(self: *Transcript, gpa: std.mem.Allocator, tag: SourceTag) error{OutOfMemory}!void {
    switch (tag) {
        .latest_message => |message| try self.tagLatestMessage(gpa, message.role, message.source_id),
        .latest_assistant_run => |source_id| try self.tagLatestAssistantRun(gpa, source_id),
        .latest_tool => |tool| try self.tagLatestTool(gpa, tool.tool_call_id, tool.source_id),
    }
}

pub fn append(self: *Transcript, gpa: std.mem.Allocator, entry: Append) error{OutOfMemory}!Outcome {
    defer self.revision +%= 1;
    return switch (entry) {
        .message => |message| self.appendMessage(gpa, message),
        .thinking => |thinking| self.appendThinking(gpa, thinking),
        .status => |status| self.appendStatus(gpa, status),
        .tool => |tool| self.appendTool(gpa, tool),
        .custom => |custom| self.appendCustom(gpa, custom),
    };
}

pub fn prepend(self: *Transcript, gpa: std.mem.Allocator, rows: Prepend) error{OutOfMemory}!Outcome {
    defer self.revision +%= 1;
    var outcome: Outcome = .{};
    var insertion_index: usize = 0;

    if (rows.thinking) |thinking| {
        const thinking_outcome = try self.insertThinkingAt(gpa, insertion_index, thinking);
        outcome.truncated = outcome.truncated or thinking_outcome.truncated;
        insertion_index += 1;
    }

    if (rows.message) |message| {
        const message_outcome = try self.insertMessageAt(gpa, insertion_index, message);
        outcome.truncated = outcome.truncated or message_outcome.truncated;
        insertion_index += 1;
    }

    for (rows.tools) |tool| {
        const tool_outcome = try self.prependToolAt(gpa, &insertion_index, tool);
        outcome.truncated = outcome.truncated or tool_outcome.truncated;
    }

    self.evictNewestUntilBounded(gpa);
    return outcome;
}

/// Stream more output into a tool's tail-windowed preview. Unknown ids are
/// a no-op: the tool may have been evicted, which is not an error.
pub fn appendToolOutput(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    delta: []const u8,
    dropped_head_bytes: usize,
    dropped_head_lines: usize,
) error{OutOfMemory}!Outcome {
    const index = self.findTool(tool_call_id) orelse return .{};
    const outcome = try self.appendToolOutputAt(gpa, index, delta, dropped_head_bytes, dropped_head_lines);
    self.evictUntilBounded(gpa);
    return outcome;
}

pub fn appendFrontToolOutput(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    delta: []const u8,
    dropped_head_bytes: usize,
    dropped_head_lines: usize,
) error{OutOfMemory}!Outcome {
    const index = self.findToolFromFront(tool_call_id) orelse return .{};
    const outcome = try self.appendToolOutputAt(gpa, index, delta, dropped_head_bytes, dropped_head_lines);
    self.evictNewestUntilBounded(gpa);
    return outcome;
}

/// Replace the streamed preview with the final result (the final output
/// supersedes deltas instead of duplicating them).
pub fn replaceToolOutput(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    output: []const u8,
) error{OutOfMemory}!Outcome {
    const index = self.findTool(tool_call_id) orelse return .{};
    const outcome = try self.replaceToolOutputAt(gpa, index, output);
    self.evictUntilBounded(gpa);
    return outcome;
}

pub fn replaceFrontToolOutput(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    output: []const u8,
) error{OutOfMemory}!Outcome {
    const index = self.findToolFromFront(tool_call_id) orelse return .{};
    const outcome = try self.replaceToolOutputAt(gpa, index, output);
    self.evictNewestUntilBounded(gpa);
    return outcome;
}

pub fn replaceFrontToolFooter(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    footer: []const u8,
) error{OutOfMemory}!Outcome {
    const index = self.findToolFromFront(tool_call_id) orelse return .{};
    const outcome = try self.replaceToolFooterAt(gpa, index, footer);
    self.evictNewestUntilBounded(gpa);
    return outcome;
}

pub fn replaceToolFooter(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    footer: []const u8,
) error{OutOfMemory}!Outcome {
    const index = self.findTool(tool_call_id) orelse return .{};
    const outcome = try self.replaceToolFooterAt(gpa, index, footer);
    self.evictUntilBounded(gpa);
    return outcome;
}

fn replaceToolFooterAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    footer: []const u8,
) error{OutOfMemory}!Outcome {
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(footer, append_size_bytes_max);
    const copy = try sanitizedCopy(gpa, bounded);
    gpa.free(tool.footer);
    tool.footer = copy;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    return .{ .truncated = bounded.len < footer.len };
}

pub fn markPendingToolsCanceled(self: *Transcript) bool {
    var changed = false;
    for (self.items.items) |*item| {
        if (item.body != .tool) continue;
        if (item.body.tool.status != .pending) continue;
        item.body.tool.status = .canceled;
        item.version +%= 1;
        if (item.version == 0) item.version = 1;
        changed = true;
    }
    if (changed) self.revision +%= 1;
    return changed;
}

fn copySourceId(gpa: std.mem.Allocator, source_id: ?[]const u8) error{OutOfMemory}!?[]u8 {
    const id = source_id orelse return null;
    const bounded = text_mod.utf8Prefix(id, source_id_bytes_max);
    return try sanitizedCopy(gpa, bounded);
}

fn sameSourceId(existing: ?[]const u8, incoming: ?[]const u8) bool {
    if (existing == null and incoming == null) return true;
    if (existing) |a| if (incoming) |b| return std.mem.eql(u8, a, b);
    return false;
}

fn setItemSourceId(
    self: *Transcript,
    gpa: std.mem.Allocator,
    item: *Item,
    source_id: []const u8,
) error{OutOfMemory}!void {
    _ = self;
    if (item.source_id != null) return;
    item.source_id = try copySourceId(gpa, source_id);
    item.version +%= 1;
    if (item.version == 0) item.version = 1;
}

fn tagLatestMessage(
    self: *Transcript,
    gpa: std.mem.Allocator,
    role: Role,
    source_id: []const u8,
) error{OutOfMemory}!void {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = &self.items.items[index];
        if (item.source_id != null) continue;
        if (item.body == .message and item.body.message.role == role) {
            try self.setItemSourceId(gpa, item, source_id);
            self.revision +%= 1;
            return;
        }
    }
}

fn tagLatestAssistantRun(
    self: *Transcript,
    gpa: std.mem.Allocator,
    source_id: []const u8,
) error{OutOfMemory}!void {
    var changed = false;
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = &self.items.items[index];
        if (item.source_id != null) break;
        switch (item.body) {
            .message => |message| if (message.role != .assistant) break,
            .thinking, .tool => {},
            .status, .custom => break,
        }
        try self.setItemSourceId(gpa, item, source_id);
        changed = true;
    }
    if (changed) self.revision +%= 1;
}

fn tagLatestTool(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    source_id: []const u8,
) error{OutOfMemory}!void {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = &self.items.items[index];
        if (item.body != .tool) continue;
        if (!std.mem.eql(u8, item.body.tool.id, tool_call_id)) continue;
        try self.setItemSourceId(gpa, item, source_id);
        self.revision +%= 1;
        return;
    }
}

fn insertMessageAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    message: Append.MessageAppend,
) error{OutOfMemory}!Outcome {
    const bounded = text_mod.utf8Prefix(message.text, append_size_bytes_max);
    const truncated = bounded.len < message.text.len;

    var source_id = try copySourceId(gpa, message.source_id);
    errdefer if (source_id) |id| gpa.free(id);
    var body: Message = .{ .role = message.role };
    errdefer body.text.deinit(gpa);
    try appendStreamBytes(gpa, &body.text, &body.pending, bounded);

    try self.insertOwnedItem(gpa, index, .{ .source_id = source_id, .body = .{ .message = body } });
    source_id = null;
    return .{ .truncated = truncated };
}

fn appendMessage(
    self: *Transcript,
    gpa: std.mem.Allocator,
    message: Append.MessageAppend,
) error{OutOfMemory}!Outcome {
    const bounded = text_mod.utf8Prefix(message.text, append_size_bytes_max);
    const truncated = bounded.len < message.text.len;

    if (message.mode != .new_item and self.items.items.len > 0) {
        const last = &self.items.items[self.items.items.len - 1];
        const matches = last.body == .message and sameSourceId(last.source_id, message.source_id) and switch (message.mode) {
            .new_item => false,
            .extend_previous_assistant_message => last.body.message.role == .assistant and message.role == .assistant,
            .extend_previous_same_role => last.body.message.role == message.role,
        };
        if (matches) {
            const old_size = last.sizeBytes();
            try appendStreamBytes(gpa, &last.body.message.text, &last.body.message.pending, bounded);
            self.noteItemMutation(last, old_size, last.sizeBytes());
            self.evictUntilBounded(gpa);
            return .{ .truncated = truncated };
        }
    }

    var source_id = try copySourceId(gpa, message.source_id);
    errdefer if (source_id) |id| gpa.free(id);
    var body: Message = .{ .role = message.role };
    errdefer body.text.deinit(gpa);
    try appendStreamBytes(gpa, &body.text, &body.pending, bounded);
    try self.items.append(gpa, .{ .source_id = source_id, .body = .{ .message = body } });
    source_id = null;
    self.total_size_bytes += body.text.items.len;
    self.evictUntilBounded(gpa);
    return .{ .truncated = truncated };
}

fn insertThinkingAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    thinking: Append.ThinkingAppend,
) error{OutOfMemory}!Outcome {
    const bounded = text_mod.utf8Prefix(thinking.text, append_size_bytes_max);
    const truncated = bounded.len < thinking.text.len;

    var source_id = try copySourceId(gpa, thinking.source_id);
    errdefer if (source_id) |id| gpa.free(id);
    var body: Thinking = .{ .hidden = thinking.hidden };
    errdefer body.text.deinit(gpa);
    if (bounded.len > 0) try appendStreamBytes(gpa, &body.text, &body.pending, bounded);

    try self.insertOwnedItem(gpa, index, .{ .source_id = source_id, .body = .{ .thinking = body } });
    source_id = null;
    return .{ .truncated = truncated };
}

fn appendThinking(
    self: *Transcript,
    gpa: std.mem.Allocator,
    thinking: Append.ThinkingAppend,
) error{OutOfMemory}!Outcome {
    const bounded = text_mod.utf8Prefix(thinking.text, append_size_bytes_max);
    const truncated = bounded.len < thinking.text.len;

    if (thinking.mode != .new_item and self.items.items.len > 0) {
        const last = &self.items.items[self.items.items.len - 1];
        if (last.body == .thinking and
            last.body.thinking.hidden == thinking.hidden and
            sameSourceId(last.source_id, thinking.source_id))
        {
            const old_size = last.sizeBytes();
            try appendStreamBytes(gpa, &last.body.thinking.text, &last.body.thinking.pending, bounded);
            self.noteItemMutation(last, old_size, last.sizeBytes());
            self.evictUntilBounded(gpa);
            return .{ .truncated = truncated };
        }
    }

    var source_id = try copySourceId(gpa, thinking.source_id);
    errdefer if (source_id) |id| gpa.free(id);
    var body: Thinking = .{ .hidden = thinking.hidden };
    errdefer body.text.deinit(gpa);
    if (bounded.len > 0) try appendStreamBytes(gpa, &body.text, &body.pending, bounded);
    try self.items.append(gpa, .{ .source_id = source_id, .body = .{ .thinking = body } });
    source_id = null;
    self.total_size_bytes += body.text.items.len;
    self.evictUntilBounded(gpa);
    return .{ .truncated = truncated };
}

fn appendStatus(
    self: *Transcript,
    gpa: std.mem.Allocator,
    status: Append.StatusAppend,
) error{OutOfMemory}!Outcome {
    const bounded = text_mod.utf8Prefix(status.text, append_size_bytes_max);
    const copy = try sanitizedCopy(gpa, bounded);
    errdefer gpa.free(copy);
    try self.items.append(gpa, .{ .body = .{ .status = .{ .level = status.level, .text = copy } } });
    self.total_size_bytes += copy.len;
    self.evictUntilBounded(gpa);
    return .{ .truncated = bounded.len < status.text.len };
}

fn appendCustom(
    self: *Transcript,
    gpa: std.mem.Allocator,
    custom: Append.CustomAppend,
) error{OutOfMemory}!Outcome {
    const title_bounded = text_mod.utf8Prefix(custom.title, append_size_bytes_max);
    const text_bounded = text_mod.utf8Prefix(custom.text, append_size_bytes_max);
    const title = try sanitizedCopy(gpa, title_bounded);
    errdefer gpa.free(title);
    const text = try sanitizedCopy(gpa, text_bounded);
    errdefer gpa.free(text);
    try self.items.append(gpa, .{ .body = .{ .custom = .{
        .title = title,
        .text = text,
        .format = custom.format,
    } } });
    self.total_size_bytes += title.len + text.len;
    self.evictUntilBounded(gpa);
    return .{ .truncated = title_bounded.len < custom.title.len or text_bounded.len < custom.text.len };
}

/// Append a tool item, or update it in place when the id already exists
/// (start -> end transitions reuse one item). Status merges so a terminal
/// success/err is never downgraded back to pending by a late start event.
fn appendTool(self: *Transcript, gpa: std.mem.Allocator, tool: Append.ToolAppend) error{OutOfMemory}!Outcome {
    const id_bounded = text_mod.utf8Prefix(tool.tool_call_id, append_size_bytes_max);
    const title_bounded = text_mod.utf8Prefix(tool.title, append_size_bytes_max);
    const compact_title_bounded = text_mod.utf8Prefix(tool.compact_title, append_size_bytes_max);

    if (self.findTool(id_bounded)) |index| {
        const existing = &self.items.items[index].body.tool;
        // Provider/tool ids are only reliable for the live call. Some providers
        // reuse short ids across turns; a titled pending start after a terminal
        // item is a new transcript fact, not a mutation of old output.
        const starts_new_reused_id = tool.status == .pending and
            existing.status != .pending and
            (title_bounded.len > 0 or compact_title_bounded.len > 0);
        if (!starts_new_reused_id) {
            const outcome = try self.updateToolAt(gpa, index, tool);
            self.evictUntilBounded(gpa);
            return outcome;
        }
    }

    const outcome = try self.insertToolAt(gpa, self.items.items.len, tool);
    self.evictUntilBounded(gpa);
    return outcome;
}

fn prependToolAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    insertion_index: *usize,
    tool: Append.ToolAppend,
) error{OutOfMemory}!Outcome {
    const id_bounded = text_mod.utf8Prefix(tool.tool_call_id, append_size_bytes_max);
    if (tool.status == .pending) {
        if (self.findToolInFrontRun(id_bounded, insertion_index.*)) |index| {
            const outcome = try self.updateToolAt(gpa, index, tool);
            insertion_index.* = index + 1;
            return outcome;
        }
    }

    const outcome = try self.insertToolAt(gpa, insertion_index.*, tool);
    insertion_index.* += 1;
    return outcome;
}

fn insertToolAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    tool: Append.ToolAppend,
) error{OutOfMemory}!Outcome {
    const id_bounded = text_mod.utf8Prefix(tool.tool_call_id, append_size_bytes_max);
    const name_bounded = text_mod.utf8Prefix(tool.name, append_size_bytes_max);
    const title_bounded = text_mod.utf8Prefix(tool.title, append_size_bytes_max);
    const compact_title_bounded = text_mod.utf8Prefix(tool.compact_title, append_size_bytes_max);
    const output_bounded = text_mod.utf8Prefix(tool.output, tool_preview_bytes_max);
    const footer_bounded = text_mod.utf8Prefix(tool.footer, append_size_bytes_max);
    const truncated = id_bounded.len < tool.tool_call_id.len or
        name_bounded.len < tool.name.len or
        title_bounded.len < tool.title.len or
        compact_title_bounded.len < tool.compact_title.len or
        output_bounded.len < tool.output.len or
        footer_bounded.len < tool.footer.len;

    const id = try sanitizedCopy(gpa, id_bounded);
    var id_owned = true;
    errdefer if (id_owned) gpa.free(id);
    const name = try sanitizedCopy(gpa, name_bounded);
    var name_owned = true;
    errdefer if (name_owned) gpa.free(name);
    const title = try sanitizedCopy(gpa, title_bounded);
    var title_owned = true;
    errdefer if (title_owned) gpa.free(title);
    const compact_title = try sanitizedCopy(gpa, compact_title_bounded);
    var compact_title_owned = true;
    errdefer if (compact_title_owned) gpa.free(compact_title);
    var output = try settledToolOutput(gpa, output_bounded);
    const output_trim = trimToTailWindow(&output, tool_preview_bytes_max, tool_preview_lines_max);
    var output_owned = true;
    errdefer if (output_owned) output.deinit(gpa);
    const footer = try sanitizedCopy(gpa, footer_bounded);
    var footer_owned = true;
    errdefer if (footer_owned) gpa.free(footer);
    var source_id = try copySourceId(gpa, tool.source_id);
    errdefer if (source_id) |id_value| gpa.free(id_value);

    id_owned = false;
    name_owned = false;
    title_owned = false;
    compact_title_owned = false;
    output_owned = false;
    footer_owned = false;
    try self.insertOwnedItem(gpa, index, .{ .source_id = source_id, .body = .{ .tool = .{
        .id = id,
        .name = name,
        .presentation = tool.presentation,
        .status = tool.status,
        .body_mode = tool.body_mode,
        .collapse = tool.collapse,
        .title = title,
        .compact_title = compact_title,
        .output = output,
        .footer = footer,
        .dropped_head_bytes = output_trim.dropped_bytes,
        .dropped_head_lines = output_trim.dropped_lines,
    } } });
    source_id = null;
    return .{ .truncated = truncated or output_trim.dropped_bytes > 0 };
}

fn updateToolAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    tool: Append.ToolAppend,
) error{OutOfMemory}!Outcome {
    const id_bounded = text_mod.utf8Prefix(tool.tool_call_id, append_size_bytes_max);
    const name_bounded = text_mod.utf8Prefix(tool.name, append_size_bytes_max);
    const title_bounded = text_mod.utf8Prefix(tool.title, append_size_bytes_max);
    const compact_title_bounded = text_mod.utf8Prefix(tool.compact_title, append_size_bytes_max);
    const output_bounded = text_mod.utf8Prefix(tool.output, tool_preview_bytes_max);
    const footer_bounded = text_mod.utf8Prefix(tool.footer, append_size_bytes_max);
    const truncated = id_bounded.len < tool.tool_call_id.len or
        name_bounded.len < tool.name.len or
        title_bounded.len < tool.title.len or
        compact_title_bounded.len < tool.compact_title.len or
        output_bounded.len < tool.output.len or
        footer_bounded.len < tool.footer.len;

    const title = if (title_bounded.len > 0) try sanitizedCopy(gpa, title_bounded) else null;
    errdefer if (title) |value| gpa.free(value);
    const compact_title = if (compact_title_bounded.len > 0) try sanitizedCopy(gpa, compact_title_bounded) else null;
    errdefer if (compact_title) |value| gpa.free(value);
    var output = if (tool.output.len > 0) try settledToolOutput(gpa, output_bounded) else null;
    const output_trim: TailTrim = if (output) |*value|
        trimToTailWindow(value, tool_preview_bytes_max, tool_preview_lines_max)
    else
        .{};
    errdefer if (output) |*value| value.deinit(gpa);
    const footer = if (tool.footer.len > 0) try sanitizedCopy(gpa, footer_bounded) else null;
    errdefer if (footer) |value| gpa.free(value);

    const item = &self.items.items[index];
    var source_id = if (item.source_id == null) try copySourceId(gpa, tool.source_id) else null;
    errdefer if (source_id) |id_value| gpa.free(id_value);
    const existing = &item.body.tool;
    const old_size = existing.sizeBytes();
    if (title) |value| {
        gpa.free(existing.title);
        existing.title = value;
    }
    if (compact_title) |value| {
        gpa.free(existing.compact_title);
        existing.compact_title = value;
    }
    if (output) |value| {
        existing.output.deinit(gpa);
        existing.output = value;
        existing.pending = .{};
        existing.dropped_head_bytes = output_trim.dropped_bytes;
        existing.dropped_head_lines = output_trim.dropped_lines;
        output = null;
    }
    if (footer) |value| {
        gpa.free(existing.footer);
        existing.footer = value;
    }
    if (item.source_id == null) {
        item.source_id = source_id;
        source_id = null;
    }
    existing.presentation = tool.presentation;
    existing.status = mergeToolStatus(existing.status, tool.status);
    existing.body_mode = tool.body_mode;
    existing.collapse = tool.collapse;
    self.noteItemMutation(item, old_size, existing.sizeBytes());
    return .{ .truncated = truncated or output_trim.dropped_bytes > 0 };
}

fn settledToolOutput(gpa: std.mem.Allocator, output: []const u8) error{OutOfMemory}!std.ArrayList(u8) {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try text_mod.appendSanitized(gpa, &list, output);
    return list;
}

fn appendToolOutputAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    delta: []const u8,
    dropped_head_bytes: usize,
    dropped_head_lines: usize,
) error{OutOfMemory}!Outcome {
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(delta, append_size_bytes_max);
    try appendStreamBytes(gpa, &tool.output, &tool.pending, bounded);
    const trim = trimToTailWindow(&tool.output, tool_preview_bytes_max, tool_preview_lines_max);
    tool.dropped_head_bytes += dropped_head_bytes + trim.dropped_bytes;
    tool.dropped_head_lines += dropped_head_lines + trim.dropped_lines;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    return .{ .truncated = bounded.len < delta.len };
}

fn replaceToolOutputAt(
    self: *Transcript,
    gpa: std.mem.Allocator,
    index: usize,
    output: []const u8,
) error{OutOfMemory}!Outcome {
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(output, append_size_bytes_max);
    tool.output.clearRetainingCapacity();
    tool.pending = .{};
    try text_mod.appendSanitized(gpa, &tool.output, bounded);
    tool.dropped_head_bytes = 0;
    tool.dropped_head_lines = 0;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    return .{ .truncated = bounded.len < output.len };
}

fn insertOwnedItem(self: *Transcript, gpa: std.mem.Allocator, index: usize, item: Item) error{OutOfMemory}!void {
    std.debug.assert(index <= self.items.items.len);
    var owned = item;
    errdefer owned.deinitBody(gpa);

    try self.items.append(gpa, undefined);
    const last_index = self.items.items.len - 1;
    if (index < last_index) {
        @memmove(self.items.items[index + 1 .. last_index + 1], self.items.items[index..last_index]);
    }
    self.items.items[index] = owned;
    self.total_size_bytes += self.items.items[index].sizeBytes();
}

fn mergeToolStatus(old: ToolStatus, new: ToolStatus) ToolStatus {
    return switch (new) {
        .pending => if (old == .pending) .pending else old,
        .canceled => if (old == .success or old == .err) old else .canceled,
        .success, .err => if (old == .canceled) old else new,
    };
}

pub fn findTool(self: *const Transcript, tool_call_id: []const u8) ?usize {
    var index = self.items.items.len;
    while (index > 0) {
        index -= 1;
        const item = &self.items.items[index];
        if (item.body == .tool and std.mem.eql(u8, item.body.tool.id, tool_call_id)) return index;
    }
    return null;
}

pub fn findToolFromFront(self: *const Transcript, tool_call_id: []const u8) ?usize {
    for (self.items.items, 0..) |*item, index| {
        if (item.body == .tool and std.mem.eql(u8, item.body.tool.id, tool_call_id)) return index;
    }
    return null;
}

fn findToolInFrontRun(self: *const Transcript, tool_call_id: []const u8, start_index: usize) ?usize {
    var index = start_index;
    while (index < self.items.items.len) : (index += 1) {
        const item = &self.items.items[index];
        if (item.body != .tool) return null;
        if (std.mem.eql(u8, item.body.tool.id, tool_call_id)) return index;
    }
    return null;
}

fn noteItemMutation(self: *Transcript, item: *Item, old_size: usize, new_size: usize) void {
    item.version +%= 1;
    if (item.version == 0) item.version = 1; // 0 is the never-valid layout sentinel
    self.total_size_bytes = self.total_size_bytes - old_size + new_size;
}

fn evictUntilBounded(self: *Transcript, gpa: std.mem.Allocator) void {
    while (self.items.items.len > item_count_max or self.total_size_bytes > total_size_bytes_max) {
        var item = self.items.orderedRemove(0);
        self.total_size_bytes -= item.sizeBytes();
        item.deinitBody(gpa);
    }
}

fn evictNewestUntilBounded(self: *Transcript, gpa: std.mem.Allocator) void {
    while (self.items.items.len > item_count_max or self.total_size_bytes > total_size_bytes_max) {
        var item = self.items.orderedRemove(self.items.items.len - 1);
        self.total_size_bytes -= item.sizeBytes();
        item.deinitBody(gpa);
    }
}

/// Carry for a multibyte codepoint split across streamed deltas. Holds a
/// valid sequence prefix only; bytes that can never become valid are
/// replaced immediately. An abandoned tail (stream ends mid-codepoint) is
/// dropped, which is correct sanitization of a torn final codepoint.
pub const PendingUtf8 = struct {
    bytes: [3]u8 = undefined,
    len: u2 = 0,
};

fn appendStreamBytes(
    gpa: std.mem.Allocator,
    list: *std.ArrayList(u8),
    pending: *PendingUtf8,
    delta: []const u8,
) error{OutOfMemory}!void {
    var rest = delta;
    if (pending.len > 0) {
        const sequence_len = std.unicode.utf8ByteSequenceLength(pending.bytes[0]) catch unreachable;
        const needed: usize = sequence_len - pending.len;
        var take: usize = 0;
        while (take < rest.len and take < needed and rest[take] & 0xc0 == 0x80) : (take += 1) {}
        if (take == needed) {
            var candidate: [4]u8 = undefined;
            @memcpy(candidate[0..pending.len], pending.bytes[0..pending.len]);
            @memcpy(candidate[pending.len..][0..take], rest[0..take]);
            const joined = candidate[0 .. @as(usize, pending.len) + take];
            if (std.unicode.utf8ValidateSlice(joined)) {
                try list.appendSlice(gpa, joined);
            } else {
                try list.appendSlice(gpa, text_mod.replacement);
            }
            pending.len = 0;
            rest = rest[take..];
        } else if (take == rest.len) {
            @memcpy(pending.bytes[pending.len..][0..take], rest[0..take]);
            pending.len += @intCast(take);
            return;
        } else {
            // Hit a non-continuation byte before the sequence completed: the
            // carried prefix can never become valid.
            try list.appendSlice(gpa, text_mod.replacement);
            pending.len = 0;
            rest = rest[take..];
        }
    }
    const split = text_mod.splitIncompleteTail(rest);
    try text_mod.appendSanitized(gpa, list, split.complete);
    @memcpy(pending.bytes[0..split.tail.len], split.tail);
    pending.len = @intCast(split.tail.len);
}

fn sanitizedCopy(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(gpa);
    try text_mod.appendSanitized(gpa, &list, bytes);
    return list.toOwnedSlice(gpa);
}

const TailTrim = struct {
    dropped_bytes: usize = 0,
    dropped_lines: usize = 0,
};

/// In-place tail window over a preview buffer: keep complete trailing lines
/// under both caps. The only partial-line case is one huge final line, where
/// a UTF-8-safe suffix beats an empty preview.
fn trimToTailWindow(list: *std.ArrayList(u8), max_bytes: usize, max_lines: usize) TailTrim {
    const window = tailWindow(list.items, max_bytes, max_lines);
    if (window.start == 0 and window.end == list.items.len) return .{};
    const dropped_bytes = window.start;
    const dropped_lines = countPhysicalLines(list.items[0..window.start]);
    const kept = window.end - window.start;
    @memmove(list.items[0..kept], list.items[window.start..window.end]);
    list.shrinkRetainingCapacity(kept);
    return .{ .dropped_bytes = dropped_bytes, .dropped_lines = dropped_lines };
}

const TailWindow = struct {
    start: usize,
    end: usize,
};

fn tailWindow(bytes: []const u8, max_bytes: usize, max_lines: usize) TailWindow {
    if (bytes.len == 0 or max_bytes == 0 or max_lines == 0) return .{ .start = bytes.len, .end = bytes.len };
    const total_lines = countPhysicalLines(bytes);
    if (total_lines <= max_lines and bytes.len <= max_bytes) return .{ .start = 0, .end = bytes.len };

    var end = bytes.len;
    if (end > 0 and bytes[end - 1] == '\n') end -= 1;

    var output_lines: usize = 0;
    var output_bytes: usize = 0;
    var start = end;
    while (end > 0 and output_lines < max_lines) {
        var line_start = end;
        while (line_start > 0 and bytes[line_start - 1] != '\n') line_start -= 1;
        const line_bytes = end - line_start;
        const separator_bytes: usize = if (output_lines > 0) 1 else 0;
        if (output_bytes + separator_bytes + line_bytes > max_bytes) {
            if (output_lines == 0) {
                return .{ .start = utf8SuffixStart(bytes[0..end], max_bytes), .end = end };
            }
            break;
        }
        start = line_start;
        output_bytes += separator_bytes + line_bytes;
        output_lines += 1;
        if (line_start == 0) break;
        end = line_start - 1;
    }
    return .{
        .start = start,
        .end = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len,
    };
}

fn utf8SuffixStart(bytes: []const u8, max_bytes: usize) usize {
    if (bytes.len <= max_bytes) return 0;
    var start = bytes.len - max_bytes;
    while (start < bytes.len and (bytes[start] & 0xc0) == 0x80) : (start += 1) {}
    return start;
}

pub fn countPhysicalLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] == '\n') count -= 1;
    return count;
}

test "message extend joins a codepoint split across deltas" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const heart = "❤"; // e2 9d a4
    _ = try transcript.append(gpa, .{ .message = .{ .role = .assistant, .text = "a" ++ heart[0..1] } });
    _ = try transcript.append(gpa, .{ .message = .{
        .role = .assistant,
        .text = heart[1..],
        .mode = .extend_previous_assistant_message,
    } });

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    try std.testing.expectEqualStrings("a" ++ heart, transcript.items.items[0].body.message.text.items);
    try std.testing.expectEqual(transcript.items.items[0].sizeBytes(), transcript.total_size_bytes);
}

test "invalid bytes are replaced, never stored" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .message = .{ .role = .assistant, .text = "ok\xff!" } });
    try std.testing.expectEqualStrings("ok\u{fffd}!", transcript.items.items[0].body.message.text.items);
}

test "oversize append truncates and reports" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    const big = try gpa.alloc(u8, append_size_bytes_max + 10);
    defer gpa.free(big);
    @memset(big, 'x');
    const outcome = try transcript.append(gpa, .{ .message = .{ .role = .user, .text = big } });
    try std.testing.expect(outcome.truncated);
    try std.testing.expectEqual(append_size_bytes_max, transcript.items.items[0].sizeBytes());
}

test "custom entries are distinct transcript items" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .custom = .{
        .title = "Session Info",
        .text = "**Messages**\nTotal: 0",
        .format = .markdown,
    } });

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    try std.testing.expect(transcript.items.items[0].body == .custom);
    try std.testing.expectEqualStrings("Session Info", transcript.items.items[0].body.custom.title);
    try std.testing.expectEqualStrings("**Messages**\nTotal: 0", transcript.items.items[0].body.custom.text);
}

test "eviction keeps item and byte caps with exact accounting" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    var index: usize = 0;
    while (index < item_count_max + 10) : (index += 1) {
        _ = try transcript.append(gpa, .{ .status = .{ .level = .info, .text = "entry" } });
    }
    try std.testing.expectEqual(item_count_max, transcript.items.items.len);

    var expected: usize = 0;
    for (transcript.items.items) |*item| expected += item.sizeBytes();
    try std.testing.expectEqual(expected, transcript.total_size_bytes);
}

test "tool output is tail-windowed with drop accounting" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });

    // Feed far more than the preview cap in append-cap-sized chunks.
    const chunk = try gpa.alloc(u8, append_size_bytes_max);
    defer gpa.free(chunk);
    @memset(chunk, 'a');
    chunk[chunk.len - 1] = '\n';
    var fed: usize = 0;
    while (fed < tool_preview_bytes_max * 2) : (fed += chunk.len) {
        _ = try transcript.appendToolOutput(gpa, "call-1", chunk, 0, 0);
    }

    const tool = transcript.items.items[0].body.tool;
    try std.testing.expect(tool.output.items.len <= tool_preview_bytes_max);
    try std.testing.expect(tool.dropped_head_bytes > 0);
    try std.testing.expectEqual(transcript.items.items[0].sizeBytes(), transcript.total_size_bytes);
}

test "settled tool append stores result output and footer atomically" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "read",
        .status = .success,
        .title = "read file",
        .output = "file contents",
        .footer = "10 lines",
    } });

    const tool = transcript.items.items[0].body.tool;
    try std.testing.expectEqual(ToolStatus.success, tool.status);
    try std.testing.expectEqualStrings("file contents", tool.output.items);
    try std.testing.expectEqualStrings("10 lines", tool.footer);
}

test "replaceToolOutput supersedes the stream and clears drop counters" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });
    _ = try transcript.appendToolOutput(gpa, "call-1", "streamed delta\n", 3, 2);
    _ = try transcript.replaceToolOutput(gpa, "call-1", "final output");

    const tool = transcript.items.items[0].body.tool;
    try std.testing.expectEqualStrings("final output", tool.output.items);
    try std.testing.expectEqual(@as(usize, 0), tool.dropped_head_bytes);
    try std.testing.expectEqual(@as(usize, 0), tool.dropped_head_lines);
    try std.testing.expectEqual(transcript.items.items[0].sizeBytes(), transcript.total_size_bytes);
}

test "tool end reuses the start item and never downgrades a terminal status" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .title = "$ pwd" } });
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .status = .success } });
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .status = .pending } });

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const tool = transcript.items.items[0].body.tool;
    try std.testing.expectEqual(ToolStatus.success, tool.status);
    try std.testing.expectEqualStrings("$ pwd", tool.title); // empty update keeps the old title
}

test "pending tools can be marked canceled without changing completed cards" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "pending", .name = "bash" } });
    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "done",
        .name = "read",
        .status = .success,
    } });
    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "failed",
        .name = "edit",
        .status = .err,
    } });

    try std.testing.expect(transcript.markPendingToolsCanceled());
    try std.testing.expect(!transcript.markPendingToolsCanceled());
    try std.testing.expectEqual(ToolStatus.canceled, transcript.items.items[0].body.tool.status);
    try std.testing.expectEqual(ToolStatus.success, transcript.items.items[1].body.tool.status);
    try std.testing.expectEqual(ToolStatus.err, transcript.items.items[2].body.tool.status);
}

test "reused terminal tool id starts a new item and updates newest" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "tool-1",
        .name = "custom",
        .title = "custom src/agent",
    } });
    _ = try transcript.replaceToolOutput(gpa, "tool-1", "Agent.zig\nroot.zig");
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "tool-1", .name = "custom", .status = .success } });

    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "tool-1",
        .name = "custom",
        .title = "custom src/frontends",
    } });
    _ = try transcript.replaceToolOutput(gpa, "tool-1", "print/\nrpc/\ntui/");
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "tool-1", .name = "custom", .status = .success } });

    try std.testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    const first = transcript.items.items[0].body.tool;
    const second = transcript.items.items[1].body.tool;
    try std.testing.expectEqualStrings("custom src/agent", first.title);
    try std.testing.expectEqualStrings("Agent.zig\nroot.zig", first.output.items);
    try std.testing.expectEqual(ToolStatus.success, first.status);
    try std.testing.expectEqualStrings("custom src/frontends", second.title);
    try std.testing.expectEqualStrings("print/\nrpc/\ntui/", second.output.items);
    try std.testing.expectEqual(ToolStatus.success, second.status);
}

test "unknown tool ids are a no-op, not an error" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);
    _ = try transcript.appendToolOutput(gpa, "missing", "data", 0, 0);
    _ = try transcript.replaceToolFooter(gpa, "missing", "Took 1s");
    try std.testing.expectEqual(@as(usize, 0), transcript.items.items.len);
}

test "source ids are owned, bounded, and queryable" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .message = .{
        .role = .user,
        .text = "hello",
        .source_id = "entry-1",
    } });
    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .source_id = "entry-2",
    } });

    try std.testing.expectEqualStrings("entry-1", transcript.oldestSourceId().?);
    try std.testing.expectEqualStrings("entry-2", transcript.newestSourceId().?);
}

test "tool updates do not leak unused source ids" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .source_id = "entry-1",
    } });
    _ = try transcript.append(gpa, .{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .source_id = "entry-2",
        .status = .success,
    } });

    try std.testing.expectEqualStrings("entry-1", transcript.items.items[0].source_id.?);
}

test "committed source tags attach to recent live items" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .message = .{ .role = .user, .text = "hello" } });
    try transcript.tagSource(gpa, .{ .latest_message = .{ .role = .user, .source_id = "user-entry" } });
    try std.testing.expectEqualStrings("user-entry", transcript.items.items[0].source_id.?);

    _ = try transcript.append(gpa, .{ .thinking = .{ .text = "", .hidden = true, .mode = .new_item } });
    _ = try transcript.append(gpa, .{ .message = .{ .role = .assistant, .text = "ok" } });
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash" } });
    try transcript.tagSource(gpa, .{ .latest_assistant_run = "assistant-entry" });
    try std.testing.expectEqualStrings("assistant-entry", transcript.items.items[1].source_id.?);
    try std.testing.expectEqualStrings("assistant-entry", transcript.items.items[2].source_id.?);
    try std.testing.expectEqualStrings("assistant-entry", transcript.items.items[3].source_id.?);
}

test "mutation bumps item version so layout memos invalidate" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);

    _ = try transcript.append(gpa, .{ .message = .{ .role = .assistant, .text = "a" } });
    const before = transcript.items.items[0].version;
    _ = try transcript.append(gpa, .{ .message = .{
        .role = .assistant,
        .text = "b",
        .mode = .extend_previous_assistant_message,
    } });
    try std.testing.expect(transcript.items.items[0].version != before);
}
