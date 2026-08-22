const std = @import("std");
const ai = @import("../ai/root.zig");
const interactive = @import("../coding_agent/root.zig").interactive;
const RenderRequest = @import("RenderRequest.zig");
const SafeText = @import("SafeText.zig");
const TranscriptPresenter = @import("TranscriptPresenter.zig");
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
    masked: bool = false,
};

pub const FrameView = struct {
    composer: ComposerView,
    phase: interactive.Phase,
    queued_count: usize,
};

const StagingCheckpoint = struct {
    byte_len: usize,
    presenter: TranscriptPresenter,
};

output: *std.Io.Writer,
staged: std.Io.Writer.Allocating,
requests: RenderRequest.State = .{},
terminal_renderer: render.TerminalRenderer,
max_staged_bytes: usize,
presenter: TranscriptPresenter = .{},
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

pub fn apply(self: *Screen, fact: interactive.HostFact) !void {
    const checkpoint = self.stagingCheckpoint();
    errdefer self.restoreStaging(checkpoint);
    switch (fact) {
        .turn => |turn| try self.renderTurnFact(turn),
        .auth_started => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logging in to {s}", .{value.provider});
            try self.renderNotice(label);
        },
        .auth_interaction => |interaction| switch (interaction) {
            .auth_url => |value| {
                try self.renderNotice(value.instructions);
                try self.renderNotice(value.url);
            },
            .device_code => |value| {
                try self.renderNotice(value.verification_uri);
                var buffer: [1024]u8 = undefined;
                const label = try std.fmt.bufPrint(&buffer, "Device code: {s}", .{value.user_code});
                try self.renderNotice(label);
            },
            .prompt => |value| try self.renderNotice(value.message),
        },
        .auth_cancelled => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Login cancelled for {s}", .{value.provider});
            try self.renderNotice(label);
        },
        .login_succeeded => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Logged in to {s}", .{value.provider});
            try self.renderNotice(label);
        },
        .login_failed => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Login failed for {s}: {s}",
                .{ value.provider, @tagName(value.failure) },
            );
            try self.renderNotice(label);
        },
        .model_changed => |selection| try self.renderModel(selection),
        .model_less => try self.renderNotice("No model is available"),
        .model_switch_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} failed: {s}",
                .{ value.requested.provider, value.requested.model, value.reason },
            );
            try self.renderNotice(label);
        },
        .model_switch_commit_indeterminate => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model switch to {s}/{s} had an indeterminate journal commit",
                .{ value.provider, value.model },
            );
            try self.renderNotice(label);
        },
        .settings_failed => |value| {
            var buffer: [1200]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &buffer,
                "Model changed, but saving the default failed: {s}",
                .{value.reason},
            );
            try self.renderNotice(label);
        },
        .settings_commit_indeterminate => try self.renderNotice(
            "Model changed, but saving the default was indeterminate",
        ),
        .session_unavailable => |value| {
            var buffer: [1024]u8 = undefined;
            const label = try std.fmt.bufPrint(&buffer, "Session unavailable: {s}", .{value.reason});
            try self.renderNotice(label);
        },
    }
    try self.ensureStagedBound();
    self.requests.request(.transcript);
}

fn applyEventFact(self: *Screen, event: interactive.Event) !void {
    try self.apply(.{ .turn = .{ .event = event } });
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
        .presenter = self.presenter,
    };
}

fn restoreStaging(self: *Screen, checkpoint: StagingCheckpoint) void {
    self.staged.shrinkRetainingCapacity(checkpoint.byte_len);
    self.presenter = checkpoint.presenter;
}

fn ensureStagedBound(self: *Screen) !void {
    if (self.staged.written().len > self.max_staged_bytes) return error.StagedFrameTooLarge;
}

fn renderWelcome(self: *Screen) !void {
    try self.presenter.renderWelcome(&self.staged);
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
        .failure => |failure| {
            var label_buffer: [128]u8 = undefined;
            const label = try std.fmt.bufPrint(
                &label_buffer,
                "turn failed: {s}",
                .{@tagName(failure.category)},
            );
            try self.renderNotice(label);
        },
        .cancelled => try self.renderNotice("turn cancelled"),
        .interrupted => try self.renderNotice("turn interrupted"),
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
            .response => try self.presenter.startResponse(),
        },
        .message_update => |update| switch (update.update) {
            .part_end => |ended| try self.presenter.renderPartEnd(
                &self.staged,
                ended,
                self.max_staged_bytes,
            ),
            .part_start, .part_delta, .usage => {},
        },
        .message_end => |ended| switch (ended.message) {
            .published => |message| switch (message) {
                .request => {},
                .response => |response| try self.presenter.finishResponse(
                    &self.staged,
                    response,
                    self.max_staged_bytes,
                ),
            },
            .discarded_response => |discarded| {
                try self.presenter.finishDiscardedResponse(
                    &self.staged,
                    discarded.response,
                    self.max_staged_bytes,
                );
                var label_buffer: [128]u8 = undefined;
                const label = try std.fmt.bufPrint(
                    &label_buffer,
                    "response discarded: {s}",
                    .{@tagName(discarded.outcome)},
                );
                try self.renderNotice(label);
            },
        },
        .tool_execution_start => |started| try self.presenter.startTool(
            started.call_id,
            started.name,
        ),
        .tool_execution_end => |ended| try self.presenter.finishTool(
            &self.staged,
            ended.call_id,
            ended.name,
            ended.result,
        ),
        .agent_end => |ended| switch (ended.outcome) {
            .completed => {},
            .cancelled => try self.renderNotice("turn cancelled"),
            .interrupted => try self.renderNotice("turn interrupted"),
            .failed => |failure| {
                var label_buffer: [128]u8 = undefined;
                const label = try std.fmt.bufPrint(
                    &label_buffer,
                    "turn failed: {s}",
                    .{@tagName(failure)},
                );
                try self.renderNotice(label);
            },
        },
        .agent_settled => |settled| if (settled.availability == .poisoned) {
            try self.renderNotice("session unavailable, reopen the durable session");
        },
    }
}

fn renderTurnFact(self: *Screen, fact: interactive.TurnFact) !void {
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
}

fn renderNotice(self: *Screen, label: []const u8) !void {
    try self.presenter.renderNotice(&self.staged, label);
}

fn buildFrame(self: *Screen, view: FrameView) !terminal_render.Surface {
    const terminal_size = self.size orelse TerminalSession.Size{ .rows = 24, .columns = 80 };
    const prompt = "❯ ";
    const masked_text = if (view.composer.masked) try self.staged.allocator.alloc(u8, view.composer.text.len) else null;
    defer if (masked_text) |text| self.staged.allocator.free(text);
    if (masked_text) |text| @memset(text, '*');
    const composer_text: []const u8 = masked_text orelse view.composer.text;
    var layout = try render.FooterLayout.init(
        self.staged.allocator,
        terminal_size.rows,
        terminal_size.columns,
        composer_text,
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
        var status_buffer: [128]u8 = undefined;
        const label = switch (view.phase) {
            .model_less => "No model selected",
            .authenticating => "Authenticating",
            .transitioning => "Changing session backend",
            .unavailable => "Session unavailable",
            .turn => |turn_phase| switch (turn_phase) {
                .idle => "Ready",
                .awaiting_start => "Working",
                .running => if (self.presenter.activeToolLabel()) |tool_name|
                    try std.fmt.bufPrint(&status_buffer, "Working · {s}", .{tool_name})
                else
                    "Working",
                .cancel_pending, .cancelling => "Cancelling",
                .dispatching_follow_up => "Starting queued prompt",
                .poisoned => "Session unavailable",
            },
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
            composer_text[line.start_byte..line.end_byte],
            .{},
        );
    }
    try surface.setCursor(layout.cursor);
    return surface;
}

fn renderModel(self: *Screen, identity: ai.message.ModelIdentity) !void {
    try self.presenter.renderModel(&self.staged, identity);
}

fn renderUser(self: *Screen, parts: []const ai.message.UserContent) !void {
    const columns = if (self.size) |size| size.columns else 80;
    try self.presenter.renderUser(self.staged.allocator, &self.staged, parts, columns);
}

fn renderResponse(self: *Screen, response: ai.message.ResponseMessage) !void {
    try self.presenter.renderRestoredResponse(&self.staged, response, self.max_staged_bytes);
}

fn renderToolResult(self: *Screen, result: ai.message.ToolResult) !void {
    try self.presenter.renderToolResult(&self.staged, result);
}

fn writeSafeText(writer: *std.Io.Writer, text: []const u8, allow_newlines: bool) !void {
    try SafeText.write(writer, text, allow_newlines);
}

test "screen stages facts and publishes one status composer frame" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.applyEventFact(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "hello" } }} } },
    } });
    try std.testing.expectEqual(@as(usize, 0), output.written().len);
    try screen.commit(.{
        .composer = .{ .text = "next", .cursor_byte = 4 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 2,
    });

    try std.testing.expect(std.mem.find(u8, output.written(), "┃ hello") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "Working") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "2 queued") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "next") != null);
}

test "screen renders Markdown thinking and prose once in response order" {
    const parts = [_]ai.message.ResponsePart{
        .{ .thinking = .{ .text = "**inspect** state" } },
        .{ .text = .{ .text = "Use `ready`." } },
    };
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.applyEventFact(.{ .message_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .response = .{
            .parts = &.{},
            .identity = .{ .provider = "test", .model = "model" },
        } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{.{ .thinking = "**inspect** state" }},
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_end = .{ .index = 0, .part = parts[0] } },
    } });
    try screen.applyEventFact(.{ .message_update = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{
            .parts = &.{
                .{ .thinking = "**inspect** state" },
                .{ .text = "Use `ready`." },
            },
            .identity = .{ .provider = "test", .model = "model" },
        },
        .update = .{ .part_end = .{ .index = 1, .part = parts[1] } },
    } });
    try screen.applyEventFact(.{ .message_end = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .message = .{ .published = .{ .response = .{
            .parts = &parts,
            .identity = .{ .provider = "test", .model = "model" },
        } } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });

    const rendered = output.written();
    const thinking = std.mem.find(u8, rendered, "Thinking").?;
    const inspect = std.mem.find(u8, rendered, "inspect").?;
    const answer = std.mem.find(u8, rendered, "Use ").?;
    try std.testing.expect(thinking < inspect);
    try std.testing.expect(inspect < answer);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "inspect"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, rendered, "ready"));
    try std.testing.expect(std.mem.find(u8, rendered, "**") == null);
}

test "screen keeps running tool details in footer and appends one compact result" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    try screen.applyEventFact(.{ .tool_execution_start = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .call_id = "call-1",
        .name = "read",
        .arguments_json = "{\"path\":\"secret\"}",
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "Working · read") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "secret") == null);

    try screen.applyEventFact(.{ .tool_execution_end = .{
        .run_id = @enumFromInt(1),
        .turn_index = 1,
        .call_id = "call-1",
        .name = "read",
        .result = .{ .published = .{
            .call_id = "call-1",
            .name = "read",
            .content = &.{.{ .text = "private file contents" }},
            .outcome = .success,
        } },
    } });
    try screen.commit(.{
        .composer = .{ .text = "", .cursor_byte = 0 },
        .phase = .{ .turn = .{ .running = @enumFromInt(1) } },
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "• read") != null);
    try std.testing.expect(std.mem.find(u8, output.written(), "private file contents") == null);
}

test "screen masks OAuth answer composer bytes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();
    screen.resized(.{ .rows = 3, .columns = 40 });
    screen.editorChanged();
    try screen.commit(.{
        .composer = .{ .text = "oauth-secret", .cursor_byte = 12, .masked = true },
        .phase = .authenticating,
        .queued_count = 0,
    });
    try std.testing.expect(std.mem.find(u8, output.written(), "oauth-secret") == null);
    try std.testing.expect(std.mem.find(u8, output.written(), "************") != null);
}

test "screen reflows the composer across terminal resize" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    var screen = try Screen.init(std.testing.allocator, &output.writer, .{});
    defer screen.deinit();

    screen.resized(.{ .rows = 3, .columns = 6 });
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    });
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.rows);
    try std.testing.expectEqual(@as(u16, 6), screen.terminal_renderer.previous.?.columns);
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.cursor.row);
    try std.testing.expectEqual(@as(u16, 3), screen.terminal_renderer.previous.?.cursor.column);

    screen.resized(.{ .rows = 3, .columns = 10 });
    try screen.commit(.{
        .composer = .{ .text = "abcdefghijkl", .cursor_byte = 12 },
        .phase = .{ .turn = .idle },
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
        .phase = .{ .turn = .idle },
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
        .phase = .{ .turn = .idle },
        .queued_count = 0,
    }));
    try std.testing.expect(screen.requests.hasPending());
    try std.testing.expect(screen.terminal_renderer.previous == null);
}
