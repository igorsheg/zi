const std = @import("std");
const ai = @import("../ai/root.zig");
const interactive = @import("../coding_agent/root.zig").interactive;
const RenderRequest = @import("RenderRequest.zig");
const terminal_render = @import("../terminal_render/root.zig");
const render = @import("render/root.zig");
const TerminalSession = @import("terminal/Session.zig");

const Screen = @This();

pub const default_max_staged_bytes = 32 * 1024 * 1024;

pub const InitOptions = struct {
    max_staged_bytes: usize = default_max_staged_bytes,
};

pub const ComposerView = struct {
    text: []const u8,
    cursor_byte: usize,
};

pub const FrameView = struct {
    composer: ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
};

const StreamLine = enum {
    closed,
    assistant,
    thinking,
};

const StagingCheckpoint = struct {
    byte_len: usize,
    stream_line: StreamLine,
};

output: *std.Io.Writer,
staged: std.Io.Writer.Allocating,
requests: RenderRequest.State = .{},
terminal_renderer: render.TerminalRenderer,
max_staged_bytes: usize,
stream_line: StreamLine = .closed,
size: ?TerminalSession.Size = null,

pub fn init(
    allocator: std.mem.Allocator,
    output: *std.Io.Writer,
    options: InitOptions,
) !Screen {
    if (options.max_staged_bytes == 0) return error.InvalidStagedByteLimit;
    return .{
        .output = output,
        .staged = .init(allocator),
        .terminal_renderer = .init(allocator),
        .max_staged_bytes = options.max_staged_bytes,
    };
}

pub fn deinit(self: *Screen) void {
    self.terminal_renderer.deinit();
    self.staged.deinit();
    self.* = undefined;
}

pub fn start(
    self: *Screen,
    transcript: ?*const interactive.SessionTranscript,
) !void {
    const checkpoint = self.stagingCheckpoint();
    errdefer self.restoreStaging(checkpoint);
    try self.renderWelcome();
    if (transcript) |restored| try self.renderTranscript(restored);
    try self.ensureStagedBound();
    self.requests.request(.first_frame);
}

pub fn apply(self: *Screen, fact: interactive.ControllerFact) !void {
    const checkpoint = self.stagingCheckpoint();
    errdefer self.restoreStaging(checkpoint);
    switch (fact) {
        .event => |event| try self.renderEvent(event),
        .completion => |completion| {
            if (!completion.agent_end_observed) switch (completion.value.outcome) {
                .completed => {},
                .failed => |failure| try self.renderNotice(@errorName(failure)),
            };
        },
        .fault => |fault| switch (fault) {
            .follow_up_submission => |failure| try self.renderNotice(@errorName(failure)),
            .draft_restore => |failure| try self.renderNotice(@errorName(failure)),
        },
    }
    try self.ensureStagedBound();
    self.requests.request(.transcript);
}

pub fn notice(self: *Screen, text: []const u8) !void {
    const checkpoint = self.stagingCheckpoint();
    errdefer self.restoreStaging(checkpoint);
    try self.renderNotice(text);
    try self.ensureStagedBound();
    self.requests.request(.notice);
}

pub fn editorChanged(self: *Screen) void {
    self.requests.request(.footer);
}

pub fn resized(self: *Screen, size: TerminalSession.Size) void {
    if (self.size != null and std.meta.eql(self.size.?, size)) return;
    self.size = size;
    self.requests.request(.resize);
}

/// Publishes one coalesced normal-buffer frame. Facts and input only stage
/// presentation state; this is the sole live frame write path.
pub fn commit(self: *Screen, view: FrameView) !void {
    var attempt = (try self.requests.beginAttempt()) orelse return;
    defer attempt.deinit();

    const checkpoint = self.stagingCheckpoint();
    errdefer self.restoreStaging(checkpoint);
    try self.finishAssistant();
    try self.ensureStagedBound();
    var surface = try self.buildFrame(view);
    defer surface.deinit();
    _ = try self.terminal_renderer.commit(
        self.output,
        &surface,
        self.staged.written(),
    );
    self.staged.clearRetainingCapacity();
    attempt.commit();
}

pub fn finish(self: *Screen, view: FrameView) !void {
    if (self.terminal_renderer.isPublicationIndeterminate()) return;
    try self.commit(view);
    try self.terminal_renderer.finish(self.output);
}

fn stagingCheckpoint(self: *Screen) StagingCheckpoint {
    return .{
        .byte_len = self.staged.written().len,
        .stream_line = self.stream_line,
    };
}

fn restoreStaging(self: *Screen, checkpoint: StagingCheckpoint) void {
    self.staged.shrinkRetainingCapacity(checkpoint.byte_len);
    self.stream_line = checkpoint.stream_line;
}

fn ensureStagedBound(self: *Screen) !void {
    if (self.staged.written().len > self.max_staged_bytes) return error.StagedFrameTooLarge;
}

fn renderWelcome(self: *Screen) !void {
    try self.staged.writer.writeAll(
        "Zi\n" ++
            "  Enter submits. Enter while busy queues the next prompt.\n" ++
            "  Escape cancels. Ctrl-D exits when idle.\n\n",
    );
}

fn renderTranscript(
    self: *Screen,
    transcript: *const interactive.SessionTranscript,
) !void {
    for (transcript.items) |item| switch (item.content) {
        .model_change => |identity| try self.renderModel(identity),
        .user => |user| try self.renderUser(user.parts),
        .assistant => |response| try self.renderResponse(response),
        .tool_results => |results| for (results.results) |result| try self.renderToolResult(result),
        .failure => |failure| try self.staged.writer.print(
            "[turn failed: {s}]\n",
            .{@tagName(failure.category)},
        ),
        .cancelled => try self.staged.writer.writeAll("[turn cancelled]\n"),
        .interrupted => try self.staged.writer.writeAll("[turn interrupted]\n"),
    };
}

fn renderEvent(self: *Screen, event: interactive.Event) !void {
    switch (event) {
        .agent_start, .turn_start, .turn_end => {},
        .message_start => |started| switch (started.message) {
            .request => |request| for (request.parts) |part| switch (part) {
                .user => |user| try self.renderUser(&.{user}),
                .tool_result, .retry_prompt => {},
            },
            .response => {},
        },
        .message_update => |update| switch (update.update) {
            .part_start => |started_part| switch (started_part.part) {
                .thinking => try self.beginThinking(),
                .text, .tool_call => {},
            },
            .part_delta => |delta| switch (delta.delta) {
                .text => |text| {
                    try self.beginAssistant();
                    try writeSafeText(&self.staged.writer, text, true);
                },
                .thinking => |thinking| {
                    try self.beginThinking();
                    try writeSafeText(&self.staged.writer, thinking, true);
                },
                .tool_call => {},
            },
            .part_end, .usage => {},
        },
        .message_end => |ended| switch (ended.message) {
            .published => |message| switch (message) {
                .request => {},
                .response => try self.finishAssistant(),
            },
            .discarded_response => |discarded| {
                try self.finishAssistant();
                try self.staged.writer.print("[response discarded: {s}]\n", .{@tagName(discarded.outcome)});
            },
        },
        .tool_execution_start => |started| {
            try self.finishAssistant();
            try self.staged.writer.writeAll("[tool ");
            try writeSafeText(&self.staged.writer, started.name, false);
            try self.staged.writer.writeAll("] ");
            try writeSafeText(&self.staged.writer, started.arguments_json, false);
            try self.staged.writer.writeByte('\n');
        },
        .tool_execution_end => |ended| switch (ended.result) {
            .published => |result| try self.renderToolResult(result),
            .discarded => |outcome| try self.staged.writer.print(
                "[tool result discarded: {s}]\n",
                .{@tagName(outcome)},
            ),
        },
        .agent_end => |ended| switch (ended.outcome) {
            .completed => {},
            .cancelled => try self.staged.writer.writeAll("[turn cancelled]\n"),
            .interrupted => try self.staged.writer.writeAll("[turn interrupted]\n"),
            .failed => |failure| try self.staged.writer.print("[turn failed: {s}]\n", .{@tagName(failure)}),
        },
        .agent_settled => |settled| if (settled.availability == .poisoned) {
            try self.staged.writer.writeAll("[session unavailable, reopen the durable session]\n");
        },
    }
}

fn renderNotice(self: *Screen, label: []const u8) !void {
    try self.finishAssistant();
    try self.staged.writer.writeByte('[');
    try writeSafeText(&self.staged.writer, label, false);
    try self.staged.writer.writeAll("]\n");
}

fn buildFrame(self: *Screen, view: FrameView) !terminal_render.Surface {
    const terminal_size = self.size orelse TerminalSession.Size{ .rows = 24, .columns = 80 };
    const prompt = "❯ ";
    var layout = try render.FooterLayout.init(
        self.staged.allocator,
        terminal_size.rows,
        terminal_size.columns,
        view.composer.text,
        view.composer.cursor_byte,
        @intCast(terminal_render.Text.displayWidth(prompt)),
    );
    defer layout.deinit();

    var surface = try terminal_render.Surface.init(
        self.staged.allocator,
        layout.surface_rows,
        layout.columns,
    );
    errdefer surface.deinit();

    if (layout.status) |status| {
        const label = switch (view.phase) {
            .idle => "Ready",
            .awaiting_start, .running => "Working",
            .cancel_pending, .cancelling => "Cancelling",
            .dispatching_follow_up => "Starting queued prompt",
            .poisoned => "Session unavailable",
        };
        _ = try surface.writeText(status.first_row, 1, label, .{
            .attributes = .{ .dim = true },
        });
        if (view.queued_count != 0) {
            var queue_buffer: [64]u8 = undefined;
            const queue_text = try std.fmt.bufPrint(
                &queue_buffer,
                " · {d} queued",
                .{view.queued_count},
            );
            const status_column = @min(
                terminal_render.Text.displayWidth(label) + 1,
                @as(usize, layout.columns),
            );
            _ = try surface.writeText(
                status.first_row,
                @intCast(status_column),
                queue_text,
                .{ .attributes = .{ .dim = true } },
            );
        }
    }

    for (layout.visibleLines(), 0..) |line, visible_index| {
        const row = layout.composer.first_row + @as(u16, @intCast(visible_index));
        if (layout.sourceLineIndex(visible_index) == 0 and line.start_column > 1) {
            _ = try surface.writeText(row, 1, prompt, .{
                .attributes = .{ .bold = true },
            });
        }
        _ = try surface.writeText(
            row,
            line.start_column,
            view.composer.text[line.start_byte..line.end_byte],
            .{},
        );
    }
    try surface.setCursor(layout.cursor);
    return surface;
}

fn beginAssistant(self: *Screen) !void {
    switch (self.stream_line) {
        .closed, .assistant => {},
        .thinking => try self.staged.writer.writeByte('\n'),
    }
    self.stream_line = .assistant;
}

fn beginThinking(self: *Screen) !void {
    switch (self.stream_line) {
        .thinking => return,
        .closed => {},
        .assistant => try self.staged.writer.writeByte('\n'),
    }
    try self.staged.writer.writeAll("[thinking] ");
    self.stream_line = .thinking;
}

fn finishAssistant(self: *Screen) !void {
    if (self.stream_line == .closed) return;
    try self.staged.writer.writeByte('\n');
    self.stream_line = .closed;
}

fn renderModel(self: *Screen, identity: ai.message.ModelIdentity) !void {
    try self.staged.writer.writeAll("[model ");
    try writeSafeText(&self.staged.writer, identity.provider, false);
    try self.staged.writer.writeByte('/');
    try writeSafeText(&self.staged.writer, identity.model, false);
    try self.staged.writer.writeAll("]\n");
}

fn renderUser(self: *Screen, parts: []const ai.message.UserContent) !void {
    try self.finishAssistant();
    try self.staged.writer.writeAll("❯ ");
    for (parts, 0..) |part, index| {
        if (index != 0) try self.staged.writer.writeByte(' ');
        switch (part) {
            .text => |text| try writeSafeText(&self.staged.writer, text, true),
            .image => |image| {
                try self.staged.writer.writeAll("[image ");
                try writeSafeText(&self.staged.writer, image.media_type, false);
                try self.staged.writer.writeByte(']');
            },
        }
    }
    try self.staged.writer.writeByte('\n');
}

fn renderResponse(self: *Screen, response: ai.message.ResponseMessage) !void {
    try self.finishAssistant();
    for (response.parts) |part| switch (part) {
        .text => |text| {
            try writeSafeText(&self.staged.writer, text.text, true);
            try self.staged.writer.writeByte('\n');
        },
        .thinking => |thinking| {
            try self.staged.writer.writeAll("[thinking] ");
            try writeSafeText(&self.staged.writer, thinking.text, true);
            try self.staged.writer.writeByte('\n');
        },
        .tool_call => |call| {
            try self.staged.writer.writeAll("[tool call ");
            try writeSafeText(&self.staged.writer, call.name, false);
            try self.staged.writer.writeAll("] ");
            try writeSafeText(&self.staged.writer, call.arguments_json, false);
            try self.staged.writer.writeByte('\n');
        },
    };
}

fn renderToolResult(self: *Screen, result: ai.message.ToolResult) !void {
    try self.finishAssistant();
    try self.staged.writer.writeAll("[tool result ");
    try writeSafeText(&self.staged.writer, result.name, false);
    try self.staged.writer.print(" {s}]\n", .{@tagName(result.outcome)});
    for (result.content) |content| switch (content) {
        .text => |text| {
            try writeSafeText(&self.staged.writer, text, true);
            if (!std.mem.endsWith(u8, text, "\n")) try self.staged.writer.writeByte('\n');
        },
        .image => |image| {
            try self.staged.writer.writeAll("[image ");
            try writeSafeText(&self.staged.writer, image.media_type, false);
            try self.staged.writer.writeAll("]\n");
        },
    };
}

fn writeSafeText(writer: *std.Io.Writer, text: []const u8, allow_newlines: bool) !void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        for (text) |byte| {
            if (byte >= 0x20 and byte < 0x7f) {
                try writer.writeByte(byte);
            } else if (allow_newlines and byte == '\n') {
                try writer.writeByte('\n');
            } else if (byte == '\t') {
                try writer.writeByte('\t');
            } else {
                try writer.writeAll("�");
            }
        }
        return;
    }

    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.peek(1).len != 0) {
        const scalar_start = iterator.i;
        const scalar = iterator.nextCodepoint().?;
        const codepoint = text[scalar_start..iterator.i];
        if (allow_newlines and scalar == '\n') {
            try writer.writeByte('\n');
        } else if (scalar == '\t') {
            try writer.writeByte('\t');
        } else if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f)) {
            try writer.writeAll("�");
        } else {
            try writer.writeAll(codepoint);
        }
    }
}

test "screen stages facts and publishes one status composer frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.apply(.{ .event = .{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } } });
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try screen.commit(.{
        .composer = .{ .text = "next", .cursor_byte = 4 },
        .phase = .{ .running = @enumFromInt(1) },
        .queued_count = 2,
    });

    try std.testing.expect(std.mem.find(u8, output.written(), "❯ hello") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "Working") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "2 queued") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "next") != null);
}

test "screen reflows the composer across terminal resize" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    screen.resized(.{ .rows = 3, .columns = 6 });
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .idle,
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.rows);
    try std.testing.expectEqual(@as(u16, 6), screen.terminal_renderer.previous.?.columns);
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.cursor.column);

    screen.resized(.{ .rows = 3, .columns = 10 });
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .idle,
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(u16, 10), screen.terminal_renderer.previous.?.columns);
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), screen.terminal_renderer.previous.?.cursor.column);
}

test "screen paints one ZWJ grapheme and places the composer cursor by cells" {
    const family = "👨‍👩‍👧‍👦";
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    screen.resized(.{ .rows = 3, .columns = 8 });
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = family, .cursor_byte = family.len },
        .phase = .idle,
        .queued_count = 0,
    });

    try std.testing.expect(std.mem.find(u8, output.written(), family) != null);
    const previous = &screen.terminal_renderer.previous.?;
    try std.testing.expectEqual(@as(u16, 2), previous.cursor.row);
    try std.testing.expectEqual(@as(u16, 5), previous.cursor.column);
    const composer_cells = previous.rowCells(2).?;
    try std.testing.expectEqual(@as(u8, 2), composer_cells[2].width);
    try std.testing.expectEqual(@as(u8, 1), composer_cells[3].lead_offset);
}

test "screen prevents provider terminal escape injection" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try writeSafeText(&output.writer, "safe\x1b[2J\rtext\u{009b}tail", true);
    try std.testing.expectEqualStrings("safe�[2J�text�tail", output.written());
    try std.testing.expect(std.mem.find(u8, output.written(), "\x1b") == null);
}

test "screen rejects oversized staged presentation transactionally" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(
        std.testing.allocator,
        &output.writer,
        .{ .max_staged_bytes = 4 },
    );
    defer screen.deinit();

    try std.testing.expectError(error.StagedFrameTooLarge, screen.notice("long"));
    try std.testing.expectEqual(@as(usize, 0), screen.staged.written().len);
    try std.testing.expect(!screen.requests.hasPending());
}

test "screen restores an uncommitted frame request after output failure" {
    const Failing = struct {
        fn drain(_: *std.Io.Writer, _: []const []const u8, _: usize) std.Io.Writer.Error!usize {
            return error.WriteFailed;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain };
    };
    var failing: std.Io.Writer = .{ .vtable = &Failing.vtable, .buffer = &.{} };
    var screen = try Screen.init(std.testing.allocator, &failing, .{});
    defer screen.deinit();
    screen.editorChanged();
    try std.testing.expectError(error.WriteFailed, screen.commit(.{
        .composer = .{ .text = "draft", .cursor_byte = 5 },
        .phase = .idle,
        .queued_count = 0,
    }));
    try std.testing.expect(screen.requests.hasPending());
    try std.testing.expect(screen.terminal_renderer.previous == null);
}
