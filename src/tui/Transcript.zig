//! Bounded resident transcript. This is a *view window*, not history:
//! durable truth lives in the session store; when the caps below are hit the
//! oldest items are evicted and scrollback simply ends.
//!
//! Bounds (policy: evict oldest):
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
pub const tool_preview_bytes_max: usize = total_size_bytes_max / 8;
pub const tool_preview_lines_max: usize = 1024;

items: std.ArrayListUnmanaged(Item) = .empty,
total_size_bytes: usize = 0,
revision: u64 = 0,

pub const Role = enum { user, assistant, system, thinking };
pub const StatusLevel = enum { info, warning, err };
pub const ToolPresentation = enum { generic, command, file, patch, search, directory };
pub const ToolStatus = enum { pending, success, err };
pub const ToolBodyMode = enum { visible, hidden_on_success };
pub const ToolCollapseMode = enum { head, tail };

/// Collapsed-view window over a tool's output, measured in visual rows.
/// Bash keeps the tail (errors live at the end); listing/search tools keep
/// the head. Expansion (ctrl+o) shows the full retained preview.
pub const ToolCollapse = struct {
    mode: ToolCollapseMode = .tail,
    rows_max: u8 = 5,
};

pub const AppendMode = enum { new_item, extend_previous_assistant_message, extend_previous_same_role };

pub const Append = union(enum) {
    message: MessageAppend,
    status: StatusAppend,
    tool: ToolAppend,

    pub const MessageAppend = struct {
        role: Role,
        text: []const u8,
        mode: AppendMode = .new_item,
    };
    pub const StatusAppend = struct {
        level: StatusLevel,
        text: []const u8,
    };
    pub const ToolAppend = struct {
        tool_call_id: []const u8,
        name: []const u8,
        presentation: ToolPresentation = .generic,
        status: ToolStatus = .pending,
        body_mode: ToolBodyMode = .visible,
        collapse: ToolCollapse = .{},
        title: []const u8 = "",
    };
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
};

pub const Item = struct {
    version: u32 = 1,
    layout: Layout = .{},
    body: Body,

    pub const Body = union(enum) {
        message: Message,
        status: Status,
        tool: Tool,
    };

    fn deinitBody(self: *Item, gpa: std.mem.Allocator) void {
        switch (self.body) {
            .message => |*message| message.text.deinit(gpa),
            .status => |status| gpa.free(status.text),
            .tool => |*tool| {
                gpa.free(tool.id);
                gpa.free(tool.name);
                gpa.free(tool.title);
                tool.output.deinit(gpa);
                gpa.free(tool.footer);
            },
        }
        self.* = undefined;
    }

    pub fn sizeBytes(self: *const Item) usize {
        return switch (self.body) {
            .message => |message| message.text.items.len,
            .status => |status| status.text.len,
            .tool => |tool| tool.sizeBytes(),
        };
    }
};

pub const Message = struct {
    role: Role,
    text: std.ArrayListUnmanaged(u8) = .empty,
    pending: PendingUtf8 = .{},
};

pub const Status = struct {
    level: StatusLevel,
    text: []u8,
};

pub const Tool = struct {
    id: []u8,
    name: []u8,
    presentation: ToolPresentation,
    status: ToolStatus,
    body_mode: ToolBodyMode,
    collapse: ToolCollapse,
    title: []u8,
    output: std.ArrayListUnmanaged(u8) = .empty,
    footer: []u8,
    pending: PendingUtf8 = .{},
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,

    pub fn sizeBytes(self: *const Tool) usize {
        return self.id.len + self.name.len + self.title.len + self.output.items.len + self.footer.len;
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

pub fn append(self: *Transcript, gpa: std.mem.Allocator, entry: Append) error{OutOfMemory}!Outcome {
    defer self.revision +%= 1;
    return switch (entry) {
        .message => |message| self.appendMessage(gpa, message),
        .status => |status| self.appendStatus(gpa, status),
        .tool => |tool| self.appendTool(gpa, tool),
    };
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
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(delta, append_size_bytes_max);
    try appendStreamBytes(&tool.output, &tool.pending, gpa, bounded);
    const trim = trimToTailWindow(&tool.output, tool_preview_bytes_max, tool_preview_lines_max);
    tool.dropped_head_bytes += dropped_head_bytes + trim.dropped_bytes;
    tool.dropped_head_lines += dropped_head_lines + trim.dropped_lines;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    self.evictUntilBounded(gpa);
    return .{ .truncated = bounded.len < delta.len };
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
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(output, append_size_bytes_max);
    tool.output.clearRetainingCapacity();
    tool.pending = .{};
    try text_mod.appendSanitized(&tool.output, gpa, bounded);
    tool.dropped_head_bytes = 0;
    tool.dropped_head_lines = 0;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    self.evictUntilBounded(gpa);
    return .{ .truncated = bounded.len < output.len };
}

pub fn replaceToolFooter(
    self: *Transcript,
    gpa: std.mem.Allocator,
    tool_call_id: []const u8,
    footer: []const u8,
) error{OutOfMemory}!Outcome {
    const index = self.findTool(tool_call_id) orelse return .{};
    const item = &self.items.items[index];
    const tool = &item.body.tool;
    const old_size = tool.sizeBytes();

    const bounded = text_mod.utf8Prefix(footer, append_size_bytes_max);
    const copy = try sanitizedCopy(gpa, bounded);
    gpa.free(tool.footer);
    tool.footer = copy;

    self.noteItemMutation(item, old_size, tool.sizeBytes());
    self.evictUntilBounded(gpa);
    return .{ .truncated = bounded.len < footer.len };
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
        const matches = last.body == .message and switch (message.mode) {
            .new_item => false,
            .extend_previous_assistant_message => last.body.message.role == .assistant and message.role == .assistant,
            .extend_previous_same_role => last.body.message.role == message.role,
        };
        if (matches) {
            const old_size = last.sizeBytes();
            try appendStreamBytes(&last.body.message.text, &last.body.message.pending, gpa, bounded);
            self.noteItemMutation(last, old_size, last.sizeBytes());
            self.evictUntilBounded(gpa);
            return .{ .truncated = truncated };
        }
    }

    var body: Message = .{ .role = message.role };
    errdefer body.text.deinit(gpa);
    try appendStreamBytes(&body.text, &body.pending, gpa, bounded);
    try self.items.append(gpa, .{ .body = .{ .message = body } });
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

/// Append a tool item, or update it in place when the id already exists
/// (start -> end transitions reuse one item). Status merges so a terminal
/// success/err is never downgraded back to pending by a late start event.
fn appendTool(self: *Transcript, gpa: std.mem.Allocator, tool: Append.ToolAppend) error{OutOfMemory}!Outcome {
    const id_bounded = text_mod.utf8Prefix(tool.tool_call_id, append_size_bytes_max);
    const name_bounded = text_mod.utf8Prefix(tool.name, append_size_bytes_max);
    const title_bounded = text_mod.utf8Prefix(tool.title, append_size_bytes_max);
    const truncated = id_bounded.len < tool.tool_call_id.len or
        name_bounded.len < tool.name.len or
        title_bounded.len < tool.title.len;

    if (self.findTool(id_bounded)) |index| {
        const item = &self.items.items[index];
        const existing = &item.body.tool;
        const old_size = existing.sizeBytes();
        if (title_bounded.len > 0) {
            const title = try sanitizedCopy(gpa, title_bounded);
            gpa.free(existing.title);
            existing.title = title;
        }
        existing.presentation = tool.presentation;
        existing.status = mergeToolStatus(existing.status, tool.status);
        existing.body_mode = tool.body_mode;
        existing.collapse = tool.collapse;
        self.noteItemMutation(item, old_size, existing.sizeBytes());
        self.evictUntilBounded(gpa);
        return .{ .truncated = truncated };
    }

    const id = try sanitizedCopy(gpa, id_bounded);
    errdefer gpa.free(id);
    const name = try sanitizedCopy(gpa, name_bounded);
    errdefer gpa.free(name);
    const title = try sanitizedCopy(gpa, title_bounded);
    errdefer gpa.free(title);
    const footer = try gpa.dupe(u8, "");
    errdefer gpa.free(footer);
    try self.items.append(gpa, .{ .body = .{ .tool = .{
        .id = id,
        .name = name,
        .presentation = tool.presentation,
        .status = tool.status,
        .body_mode = tool.body_mode,
        .collapse = tool.collapse,
        .title = title,
        .footer = footer,
    } } });
    self.total_size_bytes += self.items.items[self.items.items.len - 1].sizeBytes();
    self.evictUntilBounded(gpa);
    return .{ .truncated = truncated };
}

fn mergeToolStatus(old: ToolStatus, new: ToolStatus) ToolStatus {
    return switch (new) {
        .pending => if (old == .success or old == .err) old else .pending,
        .success, .err => new,
    };
}

pub fn findTool(self: *const Transcript, tool_call_id: []const u8) ?usize {
    for (self.items.items, 0..) |*item, index| {
        if (item.body == .tool and std.mem.eql(u8, item.body.tool.id, tool_call_id)) return index;
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

/// Carry for a multibyte codepoint split across streamed deltas. Holds a
/// valid sequence prefix only; bytes that can never become valid are
/// replaced immediately. An abandoned tail (stream ends mid-codepoint) is
/// dropped, which is correct sanitization of a torn final codepoint.
pub const PendingUtf8 = struct {
    bytes: [3]u8 = undefined,
    len: u2 = 0,
};

fn appendStreamBytes(
    list: *std.ArrayListUnmanaged(u8),
    pending: *PendingUtf8,
    gpa: std.mem.Allocator,
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
    try text_mod.appendSanitized(list, gpa, split.complete);
    @memcpy(pending.bytes[0..split.tail.len], split.tail);
    pending.len = @intCast(split.tail.len);
}

fn sanitizedCopy(gpa: std.mem.Allocator, bytes: []const u8) error{OutOfMemory}![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return gpa.dupe(u8, bytes);
    var list: std.ArrayListUnmanaged(u8) = .empty;
    errdefer list.deinit(gpa);
    try text_mod.appendSanitized(&list, gpa, bytes);
    return list.toOwnedSlice(gpa);
}

const TailTrim = struct {
    dropped_bytes: usize = 0,
    dropped_lines: usize = 0,
};

/// In-place tail window over a preview buffer: keep complete trailing lines
/// under both caps. The only partial-line case is one huge final line, where
/// a UTF-8-safe suffix beats an empty preview.
fn trimToTailWindow(list: *std.ArrayListUnmanaged(u8), max_bytes: usize, max_lines: usize) TailTrim {
    const window = tailWindow(list.items, max_bytes, max_lines);
    if (window.start == 0 and window.end == list.items.len) return .{};
    const dropped_bytes = window.start;
    const dropped_lines = countLines(list.items[0..window.start]);
    const kept = window.end - window.start;
    std.mem.copyForwards(u8, list.items[0..kept], list.items[window.start..window.end]);
    list.shrinkRetainingCapacity(kept);
    return .{ .dropped_bytes = dropped_bytes, .dropped_lines = dropped_lines };
}

const TailWindow = struct {
    start: usize,
    end: usize,
};

fn tailWindow(bytes: []const u8, max_bytes: usize, max_lines: usize) TailWindow {
    if (bytes.len == 0 or max_bytes == 0 or max_lines == 0) return .{ .start = bytes.len, .end = bytes.len };
    const total_lines = countLines(bytes);
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

fn countLines(bytes: []const u8) usize {
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

    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .title = "$ ls" } });
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .status = .success } });
    _ = try transcript.append(gpa, .{ .tool = .{ .tool_call_id = "call-1", .name = "bash", .status = .pending } });

    try std.testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const tool = transcript.items.items[0].body.tool;
    try std.testing.expectEqual(ToolStatus.success, tool.status);
    try std.testing.expectEqualStrings("$ ls", tool.title); // empty update keeps the old title
}

test "unknown tool ids are a no-op, not an error" {
    const gpa = std.testing.allocator;
    var transcript: Transcript = .{};
    defer transcript.deinit(gpa);
    _ = try transcript.appendToolOutput(gpa, "missing", "data", 0, 0);
    _ = try transcript.replaceToolFooter(gpa, "missing", "Took 1s");
    try std.testing.expectEqual(@as(usize, 0), transcript.items.items.len);
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
