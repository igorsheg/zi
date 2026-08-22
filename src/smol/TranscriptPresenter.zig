const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const terminal_render = @import("../terminal_render/root.zig");
const MarkdownAnsi = @import("MarkdownAnsi.zig");
const SafeText = @import("SafeText.zig");

const TranscriptPresenter = @This();

const BlockKind = enum {
    welcome,
    model,
    user,
    thinking,
    assistant,
    tool,
    notice,
};

const ResponseProgress = union(enum) {
    idle,
    active: usize,
};

const ToolKind = enum {
    read,
    write,
    edit,
    bash,
    other,

    fn fromName(name: []const u8) ToolKind {
        inline for (.{ .read, .write, .edit, .bash }) |kind| {
            if (std.mem.eql(u8, name, @tagName(kind))) return kind;
        }
        return .other;
    }

    fn label(self: ToolKind) []const u8 {
        return if (self == .other) "tool" else @tagName(self);
    }
};

const ActiveTool = struct {
    call_hash: u64,
    kind: ToolKind,
};

pub const max_open_part_bytes = 8 * 1024;

pub const OpenPartKind = enum { text, thinking };

/// One in-flight streaming part. Its bytes never enter staged transcript
/// output; they are re-rendered per frame into the live band until the part
/// seals. The buffer is a sliding window: when full, oldest bytes drop so the
/// newest provider output stays visible.
pub const OpenPart = struct {
    index: usize,
    kind: OpenPartKind,
    text: [max_open_part_bytes]u8,
    len: usize = 0,
    truncated: bool = false,

    fn append(self: *OpenPart, bytes: []const u8) void {
        if (bytes.len >= self.text.len) {
            const tail = bytes[bytes.len - self.text.len ..];
            @memcpy(&self.text, tail);
            self.len = self.text.len;
            self.truncated = true;
            return;
        }
        const overflow = (self.len + bytes.len) -| self.text.len;
        if (overflow > 0) {
            std.mem.copyForwards(u8, self.text[0 .. self.len - overflow], self.text[overflow..self.len]);
            self.len -= overflow;
            self.truncated = true;
        }
        @memcpy(self.text[self.len..][0..bytes.len], bytes);
        self.len += bytes.len;
    }
};

last_block: ?BlockKind = null,
response: ResponseProgress = .idle,
active_tool: ?ActiveTool = null,
open_part: ?OpenPart = null,

/// Opens the live region for one streaming part.
pub fn streamPartStart(self: *TranscriptPresenter, started: ai.stream.PartStart) void {
    switch (started.part) {
        .text => self.open_part = .{ .index = started.index, .kind = .text, .text = undefined },
        .thinking => self.open_part = .{ .index = started.index, .kind = .thinking, .text = undefined },
        .tool_call => {},
    }
}

/// Appends one incremental chunk to the live region.
pub fn streamPartDelta(self: *TranscriptPresenter, delta: ai.stream.PartDelta) void {
    // Mutate the stored part in place; a plain capture would copy the buffer.
    const open = &(self.open_part orelse return);
    if (delta.index != open.index) return;
    switch (delta.delta) {
        .text => |text| open.append(text),
        .thinking => |thinking| open.append(thinking),
        .tool_call => {},
    }
}

/// Drops any live region without sealing, for turns that end abnormally
/// between part events (failure, cancellation, interruption).
pub fn discardLivePart(self: *TranscriptPresenter) void {
    self.open_part = null;
}

fn closeOpenPart(self: *TranscriptPresenter, index: usize) void {
    if (self.open_part) |open| {
        if (open.index == index) self.open_part = null;
    }
}

pub const LiveBlock = struct {
    kind: OpenPartKind,
    truncated: bool,
    text: []const u8,
};

/// Borrows the live region for per-frame rendering, or null while nothing
/// streams or the part has no displayable bytes yet.
pub fn liveBlock(self: *const TranscriptPresenter) ?LiveBlock {
    // Borrow the stored part in place; capturing by value would copy the
    // 8 KiB buffer and hand back a slice into dead stack space.
    const open = &(self.open_part orelse return null);
    if (open.len == 0) return null;
    return .{
        .kind = open.kind,
        .truncated = open.truncated,
        .text = open.text[0..open.len],
    };
}

/// Renders the live region with healed Markdown into one frame band. Callers
/// own the output lifetime; this writes no sealed transcript state.
pub fn renderLiveBlock(
    self: *const TranscriptPresenter,
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    max_output_bytes: usize,
) !void {
    const block = self.liveBlock() orelse return;
    var encoder = terminal_render.Ansi.Encoder.init(&output.writer);
    if (block.kind == .thinking) {
        try encoder.setStyle(.{ .attributes = .{ .dim = true } });
        try output.writer.writeAll("Thinking");
        try encoder.setStyle(.{});
        try output.writer.writeByte('\n');
    }
    _ = try MarkdownAnsi.renderPartial(allocator, &output.writer, block.text, max_output_bytes);
    if (block.truncated) {
        try encoder.setStyle(.{ .attributes = .{ .dim = true } });
        try output.writer.writeAll("[live view trimmed, full text on completion]");
        try encoder.setStyle(.{});
        try output.writer.writeByte('\n');
    }
}

pub fn renderWelcome(self: *TranscriptPresenter, output: *std.Io.Writer.Allocating) !void {
    try output.writer.writeAll(
        "Zi\n" ++
            "  Enter submits. Enter while busy queues the next prompt.\n" ++
            "  /login PROVIDER [--device] logs in. /model PROVIDER/MODEL switches while idle.\n" ++
            "  Escape cancels. Ctrl-D exits when idle.\n\n",
    );
    self.last_block = .welcome;
}

pub fn startResponse(self: *TranscriptPresenter) !void {
    if (self.response != .idle) return error.ResponseAlreadyActive;
    self.response = .{ .active = 0 };
}

pub fn renderPartEnd(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    ended: ai.stream.PartEnd,
    max_output_bytes: usize,
) !void {
    const next = switch (self.response) {
        .idle => 0,
        .active => |index| index,
    };
    if (ended.index != next) return error.InvalidResponsePartOrder;
    self.closeOpenPart(ended.index);
    try self.renderResponsePart(output, ended.part, max_output_bytes);
    self.response = .{ .active = next + 1 };
}

pub fn finishResponse(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    response: ai.message.ResponseMessage,
    max_output_bytes: usize,
) !void {
    self.open_part = null;
    const next = switch (self.response) {
        .idle => 0,
        .active => |index| index,
    };
    if (next > response.parts.len) return error.InvalidResponsePartOrder;
    for (response.parts[next..]) |part| try self.renderResponsePart(output, part, max_output_bytes);
    self.response = .idle;
}

pub fn finishDiscardedResponse(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    response: ai.stream.ResponseSnapshot,
    max_output_bytes: usize,
) !void {
    self.open_part = null;
    const next = switch (self.response) {
        .idle => 0,
        .active => |index| index,
    };
    if (next > response.parts.len) return error.InvalidResponsePartOrder;
    for (response.parts[next..]) |part| try self.renderSnapshotPart(output, part, max_output_bytes);
    self.response = .idle;
}

pub fn renderRestoredResponse(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    response: ai.message.ResponseMessage,
    max_output_bytes: usize,
) !void {
    for (response.parts) |part| try self.renderResponsePart(output, part, max_output_bytes);
}

pub fn renderUser(
    self: *TranscriptPresenter,
    allocator: std.mem.Allocator,
    output: *std.Io.Writer.Allocating,
    parts: []const ai.message.UserContent,
    columns: u16,
) !void {
    try self.beginBlock(output, .user);
    var safe: std.Io.Writer.Allocating = .init(allocator);
    defer safe.deinit();
    for (parts, 0..) |part, index| {
        if (index != 0) try safe.writer.writeByte(' ');
        switch (part) {
            .text => |text| try SafeText.write(&safe.writer, text, true),
            .image => |image| {
                try safe.writer.writeAll("[image ");
                try SafeText.write(&safe.writer, image.media_type, false);
                try safe.writer.writeByte(']');
            },
        }
    }

    const prefix = "┃ ";
    const prefix_width = terminal_render.Text.displayWidth(prefix);
    const content_width = @max(@as(usize, columns), prefix_width + 1) - prefix_width;
    var encoder = terminal_render.Ansi.Encoder.init(&output.writer);
    try encoder.setStyle(.{ .attributes = .{ .bold = true } });
    try output.writer.writeAll(prefix);
    var line_width: usize = 0;
    var iterator = terminal_render.Text.Iterator.init(safe.written());
    while (iterator.next()) |grapheme| {
        if (grapheme.kind == .line_break) {
            try output.writer.writeByte('\n');
            try output.writer.writeAll(prefix);
            line_width = 0;
            continue;
        }
        if (line_width != 0 and line_width + grapheme.width > content_width) {
            try output.writer.writeByte('\n');
            try output.writer.writeAll(prefix);
            line_width = 0;
        }
        if (grapheme.kind == .tab) {
            try output.writer.splatByteAll(' ', grapheme.width);
        } else {
            try output.writer.writeAll(grapheme.bytes);
        }
        line_width += grapheme.width;
    }
    try encoder.setStyle(.{});
    try output.writer.writeByte('\n');
    self.last_block = .user;
}

pub fn renderModel(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    identity: ai.message.ModelIdentity,
) !void {
    try self.beginBlock(output, .model);
    try output.writer.writeAll("[model ");
    try SafeText.write(&output.writer, identity.provider, false);
    try output.writer.writeByte('/');
    try SafeText.write(&output.writer, identity.model, false);
    try output.writer.writeAll("]\n");
    self.last_block = .model;
}

pub fn renderToolResult(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    result: ai.message.ToolResult,
) !void {
    try self.beginBlock(output, .tool);
    try output.writer.writeAll("• ");
    try SafeText.write(&output.writer, result.name, false);
    if (result.outcome == .failure) try output.writer.writeAll(" failed");
    try output.writer.writeByte('\n');
    self.last_block = .tool;
}

pub fn startTool(self: *TranscriptPresenter, call_id: []const u8, name: []const u8) !void {
    if (self.active_tool != null) return error.ToolAlreadyRunning;
    self.active_tool = .{
        .call_hash = std.hash.Wyhash.hash(0, call_id),
        .kind = ToolKind.fromName(name),
    };
}

pub fn finishTool(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    call_id: []const u8,
    name: []const u8,
    result: agent.event.ToolExecutionResult,
) !void {
    const active = self.active_tool orelse return error.ToolNotRunning;
    if (active.call_hash != std.hash.Wyhash.hash(0, call_id)) return error.ToolLifecycleMismatch;
    self.active_tool = null;
    switch (result) {
        .published => |published| try self.renderToolResult(output, published),
        .discarded => |outcome| {
            try self.beginBlock(output, .tool);
            try output.writer.writeAll("• ");
            try SafeText.write(&output.writer, name, false);
            try output.writer.print(" discarded: {s}\n", .{@tagName(outcome)});
            self.last_block = .tool;
        },
    }
}

pub fn activeToolLabel(self: *const TranscriptPresenter) ?[]const u8 {
    const active = self.active_tool orelse return null;
    return active.kind.label();
}

pub fn renderNotice(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    label: []const u8,
) !void {
    try self.beginBlock(output, .notice);
    try output.writer.writeByte('[');
    try SafeText.write(&output.writer, label, false);
    try output.writer.writeAll("]\n");
    self.last_block = .notice;
}

fn renderResponsePart(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    part: ai.message.ResponsePart,
    max_output_bytes: usize,
) !void {
    switch (part) {
        .text => |text| try self.renderMarkdown(output, .assistant, null, text.text, max_output_bytes),
        .thinking => |thinking| try self.renderMarkdown(output, .thinking, "Thinking", thinking.text, max_output_bytes),
        .tool_call => {},
    }
}

fn renderSnapshotPart(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    part: ai.stream.ResponsePartSnapshot,
    max_output_bytes: usize,
) !void {
    switch (part) {
        .text => |text| try self.renderMarkdown(output, .assistant, null, text, max_output_bytes),
        .thinking => |thinking| try self.renderMarkdown(output, .thinking, "Thinking", thinking, max_output_bytes),
        .tool_call => {},
    }
}

fn renderMarkdown(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    kind: BlockKind,
    label: ?[]const u8,
    markdown: []const u8,
    max_output_bytes: usize,
) !void {
    if (std.mem.trim(u8, markdown, " \t\r\n").len == 0) return;
    try self.beginBlock(output, kind);
    if (label) |text| {
        var encoder = terminal_render.Ansi.Encoder.init(&output.writer);
        try encoder.setStyle(.{ .attributes = .{ .dim = true } });
        try output.writer.writeAll(text);
        try encoder.setStyle(.{});
        try output.writer.writeByte('\n');
    }
    if (output.written().len > max_output_bytes) return error.StagedFrameTooLarge;
    const before = output.written().len;
    _ = try MarkdownAnsi.render(
        output.allocator,
        &output.writer,
        markdown,
        max_output_bytes - output.written().len,
    );
    if (output.written().len == before or output.written()[output.written().len - 1] != '\n') {
        try output.writer.writeByte('\n');
    }
    self.last_block = kind;
}

fn beginBlock(
    self: *TranscriptPresenter,
    output: *std.Io.Writer.Allocating,
    next: BlockKind,
) !void {
    const previous = self.last_block orelse return;
    const gap_rows: usize = switch (previous) {
        .welcome => 0,
        .tool => if (next == .tool) 0 else 1,
        else => 1,
    };
    try output.writer.splatByteAll('\n', gap_rows);
}

test "presenter keeps text thinking and text parts chronological" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var presenter: TranscriptPresenter = .{};
    try presenter.startResponse();
    try presenter.renderPartEnd(&output, .{
        .index = 0,
        .part = .{ .text = .{ .text = "before" } },
    }, 4096);
    try presenter.renderPartEnd(&output, .{
        .index = 1,
        .part = .{ .thinking = .{ .text = "**reason**" } },
    }, 4096);
    try presenter.renderPartEnd(&output, .{
        .index = 2,
        .part = .{ .text = .{ .text = "after" } },
    }, 4096);
    const rendered = output.written();
    const before = std.mem.find(u8, rendered, "before").?;
    const thinking = std.mem.find(u8, rendered, "Thinking").?;
    const reason = std.mem.find(u8, rendered, "reason").?;
    const after = std.mem.find(u8, rendered, "after").?;
    try std.testing.expect(before < thinking);
    try std.testing.expect(thinking < reason);
    try std.testing.expect(reason < after);
    try std.testing.expect(std.mem.find(u8, rendered, "**") == null);
}

test "presenter skips thinking blocks without displayable text" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var presenter: TranscriptPresenter = .{};
    try presenter.startResponse();
    try presenter.renderPartEnd(&output, .{
        .index = 0,
        .part = .{ .thinking = .{ .text = "  \n" } },
    }, 4096);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
}

test "presenter does not duplicate ended response parts" {
    const parts = [_]ai.message.ResponsePart{
        .{ .text = .{ .text = "first" } },
        .{ .thinking = .{ .text = "second" } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var presenter: TranscriptPresenter = .{};
    try presenter.startResponse();
    try presenter.renderPartEnd(&output, .{ .index = 0, .part = parts[0] }, 4096);
    try presenter.finishResponse(&output, .{ .parts = &parts, .identity = .{ .provider = "p", .model = "m" } }, 4096);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "first"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, output.written(), "second"));
}

test "presenter wraps user rails and summarizes tools without payloads" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var presenter: TranscriptPresenter = .{};
    try presenter.renderUser(std.testing.allocator, &output, &.{.{ .text = "abcdef" }}, 5);
    try std.testing.expect(std.mem.count(u8, output.written(), "┃ ") >= 2);

    try presenter.startTool("call-1", "read");
    try std.testing.expectEqualStrings("read", presenter.activeToolLabel().?);
    try presenter.finishTool(&output, "call-1", "read", .{ .published = .{
        .call_id = "call-1",
        .name = "read",
        .content = &.{.{ .text = "secret contents" }},
        .outcome = .success,
    } });
    try std.testing.expect(std.mem.find(u8, output.written(), "• read") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "secret contents") == null);
}

test "presenter streams a healed open part without staging until seal" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var live_output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer live_output.deinit();
    var presenter: TranscriptPresenter = .{};

    try presenter.startResponse();
    presenter.streamPartStart(.{ .index = 0, .part = .text });
    presenter.streamPartDelta(.{ .index = 0, .delta = .{ .text = "counting:\n\n```zig\nconst x" } });

    const live = presenter.liveBlock().?;
    try std.testing.expectEqual(OpenPartKind.text, live.kind);
    try presenter.renderLiveBlock(std.testing.allocator, &live_output, 4096);
    try std.testing.expect(std.mem.find(u8, live_output.written(), "const x") != null);
    try std.testing.expectEqual(@as(usize, 0), output.written().len);

    try presenter.renderPartEnd(&output, .{
        .index = 0,
        .part = .{ .text = .{ .text = "counting:\n\n```zig\nconst x = 1;\n```" } },
    }, 4096);
    try std.testing.expect(presenter.liveBlock() == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "const x = 1;") != null);
}

test "open part keeps newest bytes in its sliding window" {
    var presenter: TranscriptPresenter = .{};
    try presenter.startResponse();
    presenter.streamPartStart(.{ .index = 0, .part = .text });

    const filler = [_]u8{'a'} ** max_open_part_bytes;
    presenter.streamPartDelta(.{ .index = 0, .delta = .{ .text = &filler } });
    presenter.streamPartDelta(.{ .index = 0, .delta = .{ .text = "-tail" } });

    const live = presenter.liveBlock().?;
    try std.testing.expect(live.truncated);
    try std.testing.expectEqual(max_open_part_bytes, live.text.len);
    try std.testing.expect(std.mem.endsWith(u8, live.text, "aa-tail"));
}

test "ignored stream parts never open a live region" {
    var output_unused: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_unused.deinit();
    var presenter: TranscriptPresenter = .{};
    try presenter.startResponse();
    presenter.streamPartStart(.{ .index = 0, .part = .{ .tool_call = .{ .id = "c1", .name = "read" } } });
    presenter.streamPartDelta(.{ .index = 0, .delta = .{ .tool_call = .{
        .id = "c1",
        .name = "read",
        .arguments_delta = "{}",
    } } });
    try std.testing.expect(presenter.liveBlock() == null);

    try presenter.renderPartEnd(&output_unused, .{
        .index = 0,
        .part = .{ .tool_call = .{ .id = "c1", .name = "read", .arguments_json = "{}" } },
    }, 4096);
    try std.testing.expect(presenter.liveBlock() == null);
}
