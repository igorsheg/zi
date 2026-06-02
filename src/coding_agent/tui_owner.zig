const std = @import("std");
const vaxis = @import("vaxis");

const ai = @import("../ai/root.zig");
const agent_mod = @import("../agent/root.zig");
const AgentSession = @import("AgentSession.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const frontend = @import("frontend.zig");
const runtime = @import("../runtime/root.zig");
const sdk = @import("sdk.zig");
const session_events = @import("session_events.zig");
const tui = @import("../tui/root.zig");

const terminal_event_drain_count_max = 64;
// Public events are already queued and bounded; drain a bounded batch per tick
// so terminal input and render cannot be starved by a busy model stream.
const public_event_drain_count_max = 64;

pub const OwnerLoop = struct {
    allocator: std.mem.Allocator,
    host: *AgentSessionRuntimeHost,
    terminal: *tui.substrate.terminal.Terminal,
    terminal_events: *tui.substrate.event_pump.TerminalEvents,
    app: tui.product.App.ProductApp,
    read_model: frontend.ReadModel,
    input_scratch: tui.product.input_router.Scratch = .{},
    frame_scratch: tui.product.frame.Scratch = .{},
    transcript_adapter: TranscriptAdapter = .{},
    active_run: ?*AgentSession.LivePromptRun = null,
    shutdown_requested: bool = false,

    pub fn init(
        allocator: std.mem.Allocator,
        host: *AgentSessionRuntimeHost,
        terminal: *tui.substrate.terminal.Terminal,
        terminal_events: *tui.substrate.event_pump.TerminalEvents,
    ) OwnerLoop {
        return .{
            .allocator = allocator,
            .host = host,
            .terminal = terminal,
            .terminal_events = terminal_events,
            .app = tui.product.App.ProductApp.init(.{}),
            .read_model = frontend.ReadModel.initFromSnapshot(host.statusSnapshot()),
        };
    }

    pub fn deinit(self: *OwnerLoop) void {
        if (self.active_run) |prompt_run| {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
        self.app.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn submitInitialPrompt(self: *OwnerLoop, prompt: []const u8) !void {
        try self.applyFrontendAction(.{ .submit_prompt = .{ .text = prompt } });
    }

    pub fn run(self: *OwnerLoop) !void {
        while (!self.shutdown_requested) {
            try self.waitOnce();
        }
        self.host.requestShutdown();
        try self.drainPublicEvents();
        try self.renderIfDirty();
    }

    fn waitOnce(self: *OwnerLoop) !void {
        if (self.active_run) |prompt_run| {
            var terminal_receive = self.terminal_events.asyncNext();
            const prompt_progress = self.host.promptRunProgress(prompt_run);
            const selected = try runtime.select(.{
                .terminal = &terminal_receive,
                .prompt = prompt_progress,
                .host_event = self.host.publicEventWake(),
            });
            switch (selected) {
                .terminal => |event| {
                    if (event) |terminal_event| try self.applyTerminalEvent(terminal_event);
                },
                .prompt => |progress| try self.applyPromptProgress(prompt_run, progress),
                .host_event => self.host.publicEventWake().reset(),
            }
        } else {
            var terminal_receive = self.terminal_events.asyncNext();
            const selected = try runtime.select(.{
                .terminal = &terminal_receive,
                .host_event = self.host.publicEventWake(),
            });
            switch (selected) {
                .terminal => |event| {
                    if (event) |terminal_event| {
                        try self.applyTerminalEvent(terminal_event);
                    } else {
                        self.shutdown_requested = true;
                    }
                },
                .host_event => self.host.publicEventWake().reset(),
            }
        }
        try self.drainReadyTerminalEvents();
        try self.drainPublicEvents();
        try self.renderIfDirty();
    }

    fn drainReadyTerminalEvents(self: *OwnerLoop) !void {
        for (0..terminal_event_drain_count_max) |_| {
            const event = self.terminal_events.tryNext() orelse return;
            try self.applyTerminalEvent(event);
        }
    }

    fn applyTerminalEvent(
        self: *OwnerLoop,
        event: tui.substrate.terminal.Event,
    ) !void {
        if (event == .winsize) try self.terminal.resize(event.winsize);
        if (try handleTerminalEvent(self.allocator, &self.app, &self.input_scratch, event)) |action| {
            defer deinitFrontendAction(self.allocator, action);
            try self.applyFrontendAction(action);
        }
    }

    fn applyFrontendAction(self: *OwnerLoop, action: frontend.FrontendAction) !void {
        switch (action) {
            .submit_prompt => |submit| {
                if (self.active_run != null) return error.TuiPromptRunAlreadyActive;
                self.active_run = try self.host.startPromptRun(submit.text, &.{}, .{});
                self.read_model.markRunning();
            },
            .cancel_run => {
                if (self.active_run) |_| {
                    self.host.cancel();
                    self.read_model.markCancelled();
                } else {
                    self.host.requestShutdown();
                    self.read_model.markShutdownRequested();
                    self.shutdown_requested = true;
                }
            },
            .continue_run => {
                try self.host.continueRun();
            },
            .request_shutdown => {
                self.host.requestShutdown();
                self.read_model.markShutdownRequested();
                self.shutdown_requested = true;
            },
            .invoke_command,
            .set_active_tools,
            => return error.TuiFrontendActionUnsupported,
        }
    }

    fn applyPromptProgress(
        self: *OwnerLoop,
        prompt_run: *AgentSession.LivePromptRun,
        progress: @TypeOf(AgentSession.promptRunProgress(prompt_run)).Result,
    ) !void {
        std.debug.assert(self.active_run == prompt_run);
        const still_active = try self.host.applyPromptRunProgress(prompt_run, progress);
        if (!still_active) {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }

    fn drainPublicEvents(self: *OwnerLoop) !void {
        for (0..public_event_drain_count_max) |_| {
            const event = self.host.drainPublicEvent() orelse return;
            var owned_event = event;
            defer owned_event.deinit();
            applyPublicEvent(&self.read_model, owned_event);
            try self.transcript_adapter.apply(self.allocator, &self.app, owned_event);
        }
    }

    pub fn renderIfDirty(self: *OwnerLoop) !void {
        if (!self.app.dirty) return;
        const winsize = try self.terminal.currentWinsize();
        if (winsize.cols != self.app.size.width_columns or winsize.rows != self.app.size.height_rows) {
            _ = try self.app.apply(self.allocator, .{ .resize = .{
                .width_columns = winsize.cols,
                .height_rows = winsize.rows,
            } });
        }
        try self.app.ensureTranscriptRows(self.allocator);
        const frame = try self.frame_scratch.build(&self.app);
        const win = self.terminal.vx.window();
        win.hideCursor();
        win.setCursorShape(.default);
        const result = tui.product.render.render(win, frame);
        if (result.cursor) |cursor| win.showCursor(cursor.column, cursor.row);
        try self.terminal.vx.render(self.terminal.tty.writer());
        self.app.dirty = false;
    }
};

fn actionFromEffect(effect: tui.product.App.Effect) frontend.FrontendAction {
    return switch (effect) {
        .submit_prompt => |prompt| .{ .submit_prompt = .{ .text = prompt } },
    };
}

fn actionFromInputRoute(route: tui.product.input_router.RouteResult) ?frontend.FrontendAction {
    return switch (route) {
        .command => null,
        .cancel => .cancel_run,
    };
}

fn handleTerminalEvent(
    allocator: std.mem.Allocator,
    app: *tui.product.App.ProductApp,
    scratch: *tui.product.input_router.Scratch,
    event: tui.substrate.terminal.Event,
) !?frontend.FrontendAction {
    const route = (try scratch.route(event)) orelse return null;
    switch (route) {
        .command => |command| {
            _ = try app.apply(allocator, command);
            return drainProductAction(app);
        },
        .cancel => return actionFromInputRoute(route),
    }
}

fn drainProductAction(app: *tui.product.App.ProductApp) ?frontend.FrontendAction {
    const effect = app.drainEffect() orelse return null;
    return actionFromEffect(effect);
}

fn applyPublicEvent(
    model: *frontend.ReadModel,
    event: session_events.AgentSessionEvent,
) void {
    model.apply(event);
}

const TranscriptAdapter = struct {
    active_assistant_item: ?tui.product.transcript.ItemId = null,
    active_assistant_text_size_bytes: usize = 0,

    fn apply(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        event: session_events.AgentSessionEvent,
    ) !void {
        switch (event) {
            .agent_event => |agent_event| switch (agent_event) {
                .message_start => |payload| switch (payload.message) {
                    .assistant => try self.startAssistantMessage(allocator, app),
                    .user,
                    .tool_result,
                    .custom,
                    => {},
                },
                .message_update => |payload| switch (payload.assistant_message_event) {
                    .text_delta => |delta| try self.appendAssistantDelta(allocator, app, delta.delta),
                    .text_end => |text_end| try self.appendAssistantFinalText(allocator, app, text_end.content),
                    .done => |done| try self.appendAssistantMessageFinalText(allocator, app, done.message),
                    .start,
                    .text_start,
                    .thinking_start,
                    .thinking_delta,
                    .thinking_end,
                    .toolcall_start,
                    .toolcall_delta,
                    .toolcall_end,
                    .@"error",
                    => {},
                },
                .message_end => |payload| switch (payload.message) {
                    .assistant => try self.endAssistantMessage(allocator, app),
                    .user,
                    .tool_result,
                    .custom,
                    => {},
                },
                .agent_start,
                .agent_end,
                .turn_start,
                .turn_end,
                => {},
                .tool_execution_start => |payload| try self.appendToolCall(allocator, app, payload),
                .tool_execution_update => {},
                .tool_execution_end => |payload| try self.appendToolResult(allocator, app, payload),
            },
            .queue_update,
            .prompt_command,
            .compaction_start,
            .session_info_changed,
            .compaction_end,
            .auto_retry_start,
            .auto_retry_end,
            => {},
        }
    }

    fn startAssistantMessage(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
    ) !void {
        if (self.active_assistant_item != null) return error.ActiveAssistantTranscriptAlreadyOpen;
        self.active_assistant_item = (try app.apply(allocator, .{
            .append_transcript_item = .assistant_message,
        })).?;
        self.active_assistant_text_size_bytes = 0;
    }

    fn appendAssistantDelta(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        delta: []const u8,
    ) !void {
        const item_id = self.active_assistant_item orelse return error.ActiveAssistantTranscriptMissing;
        _ = try app.apply(allocator, .{ .append_transcript_text = .{
            .item_id = item_id,
            .bytes = delta,
        } });
        self.active_assistant_text_size_bytes += delta.len;
    }

    fn appendAssistantFinalText(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        text: []const u8,
    ) !void {
        const item_id = self.active_assistant_item orelse return error.ActiveAssistantTranscriptMissing;
        if (text.len < self.active_assistant_text_size_bytes) return error.ActiveAssistantTranscriptFinalTextShrank;
        const missing = text[self.active_assistant_text_size_bytes..];
        if (missing.len == 0) return;
        _ = try app.apply(allocator, .{ .append_transcript_text = .{
            .item_id = item_id,
            .bytes = missing,
        } });
        self.active_assistant_text_size_bytes = text.len;
    }

    fn appendAssistantMessageFinalText(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        message: ai.AssistantMessage,
    ) !void {
        const text = assistantMessageFirstText(message) orelse return;
        try self.appendAssistantFinalText(allocator, app, text);
    }

    fn endAssistantMessage(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
    ) !void {
        const item_id = self.active_assistant_item orelse return error.ActiveAssistantTranscriptMissing;
        errdefer self.active_assistant_item = item_id;
        _ = try app.apply(allocator, .{ .seal_transcript_item = item_id });
        self.active_assistant_item = null;
        self.active_assistant_text_size_bytes = 0;
    }

    fn appendToolCall(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        payload: agent_mod.AgentEvent.ToolExecutionStart,
    ) !void {
        _ = self;
        const item_id = (try app.apply(allocator, .{ .append_transcript_item = .tool_call })).?;
        errdefer rollbackTailTranscriptItem(allocator, app, item_id);
        var text = std.Io.Writer.Allocating.init(allocator);
        defer text.deinit();
        try text.writer.print("tool {s} started", .{payload.tool_name});
        _ = try app.apply(allocator, .{ .append_transcript_text = .{
            .item_id = item_id,
            .bytes = text.written(),
        } });
        _ = try app.apply(allocator, .{ .seal_transcript_item = item_id });
    }

    fn appendToolResult(
        self: *TranscriptAdapter,
        allocator: std.mem.Allocator,
        app: *tui.product.App.ProductApp,
        payload: agent_mod.AgentEvent.ToolExecutionEnd,
    ) !void {
        _ = self;
        const item_id = (try app.apply(allocator, .{ .append_transcript_item = .tool_result })).?;
        errdefer rollbackTailTranscriptItem(allocator, app, item_id);
        var text = std.Io.Writer.Allocating.init(allocator);
        defer text.deinit();
        try text.writer.print("tool {s} {s}", .{ payload.tool_name, if (payload.is_error) "failed" else "finished" });
        if (firstToolResultText(payload.result)) |result_text| {
            try text.writer.writeAll("\n");
            try text.writer.writeAll(result_text);
        }
        _ = try app.apply(allocator, .{ .append_transcript_text = .{
            .item_id = item_id,
            .bytes = text.written(),
        } });
        _ = try app.apply(allocator, .{ .seal_transcript_item = item_id });
    }
};

fn assistantMessageFirstText(message: ai.AssistantMessage) ?[]const u8 {
    for (message.content) |content| {
        switch (content) {
            .text => |text| return text.text,
            else => {},
        }
    }
    return null;
}

fn firstToolResultText(result: agent_mod.AgentToolResult) ?[]const u8 {
    for (result.content) |content| {
        switch (content) {
            .text => |text| return text.text,
            .image => {},
        }
    }
    return null;
}

fn rollbackTailTranscriptItem(
    allocator: std.mem.Allocator,
    app: *tui.product.App.ProductApp,
    expected_id: tui.product.transcript.ItemId,
) void {
    if (app.transcript.items.items.len == 0) unreachable;
    const index = app.transcript.items.items.len - 1;
    if (app.transcript.items.items[index].id != expected_id) unreachable;
    const block_id = app.transcript.items.items[index].block_id;
    app.transcript.items.items.len = index;
    app.transcript.next_item_id -= 1;
    app.transcript.document.removeTailBlock(allocator, block_id) catch unreachable;
}

fn deinitFrontendAction(allocator: std.mem.Allocator, action: frontend.FrontendAction) void {
    switch (action) {
        .submit_prompt => |submit| allocator.free(submit.text),
        .cancel_run,
        .continue_run,
        .request_shutdown,
        .invoke_command,
        .set_active_tools,
        => {},
    }
}

test "tui owner maps product submit effect to frontend action" {
    var prompt = [_]u8{ 'h', 'e', 'l', 'l', 'o' };
    const effect: tui.product.App.Effect = .{ .submit_prompt = prompt[0..] };
    const action = actionFromEffect(effect);

    try std.testing.expectEqualStrings("hello", action.submit_prompt.text);
}

test "tui owner maps input cancel route to frontend cancel action" {
    const action = actionFromInputRoute(.cancel).?;

    try std.testing.expectEqual(frontend.FrontendAction.cancel_run, action);
    try std.testing.expect(actionFromInputRoute(.{ .command = .backspace_composer }) == null);
}

test "tui owner terminal text event mutates composer through product owner" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var scratch: tui.product.input_router.Scratch = .{};

    const action = try handleTerminalEvent(std.testing.allocator, &app, &scratch, .{
        .key_press = testKey('h', "h"),
    });

    try std.testing.expect(action == null);
    try std.testing.expectEqualStrings("h", app.composer.buffer.bytes.items);
}

test "tui owner terminal submit drains product submit effect" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var scratch: tui.product.input_router.Scratch = .{};
    _ = try handleTerminalEvent(std.testing.allocator, &app, &scratch, .{
        .key_press = testKey('h', "h"),
    });

    const action = (try handleTerminalEvent(std.testing.allocator, &app, &scratch, .{
        .key_press = testKey(vaxis.Key.enter, null),
    })).?;
    defer deinitFrontendAction(std.testing.allocator, action);

    try std.testing.expectEqualStrings("h", action.submit_prompt.text);
}

test "tui owner terminal cancel returns frontend cancel without mutating composer" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var scratch: tui.product.input_router.Scratch = .{};

    const action = (try handleTerminalEvent(std.testing.allocator, &app, &scratch, .{
        .key_press = testKey(vaxis.Key.escape, null),
    })).?;

    try std.testing.expectEqual(frontend.FrontendAction.cancel_run, action);
    try std.testing.expectEqualStrings("", app.composer.buffer.bytes.items);
}

fn testKey(codepoint: u21, text: ?[]const u8) tui.primitive.input.KeyPress {
    return tui.primitive.input.KeyPress.copyFromVaxis(.{ .codepoint = codepoint, .text = text }) catch unreachable;
}

test "tui owner terminal resize mutates product size" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var scratch: tui.product.input_router.Scratch = .{};

    _ = try handleTerminalEvent(std.testing.allocator, &app, &scratch, .{ .winsize = .{
        .rows = 10,
        .cols = 40,
        .x_pixel = 0,
        .y_pixel = 0,
    } });

    try std.testing.expectEqual(@as(u16, 40), app.size.width_columns);
    try std.testing.expectEqual(@as(u16, 10), app.size.height_rows);
}

test "tui owner applies public events to frontend read model only" {
    var model: frontend.ReadModel = .{};

    applyPublicEvent(&model, .{ .agent_event = .agent_start });

    try std.testing.expectEqual(frontend.ReadModel.Status.running, model.status);
}

test "tui owner transcript adapter streams assistant deltas into one sealed item" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent());
    try adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("hel"));
    try adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("lo"));
    try adapter.apply(std.testing.allocator, &app, assistantMessageEndEvent());

    try std.testing.expect(adapter.active_assistant_item == null);
    try std.testing.expectEqual(@as(usize, 1), app.transcript.items.items.len);
    const item = app.transcript.items.items[0];
    try std.testing.expectEqual(tui.product.transcript.ItemKind.assistant_message, item.kind);
    try std.testing.expectEqual(tui.product.transcript.ItemState.sealed, item.state);
    const block = app.transcript.document.block(item.block_id).?;
    try std.testing.expectEqualStrings("hello", block.bytes.items);
}

test "tui owner transcript adapter rejects assistant delta without open item" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try std.testing.expectError(
        error.ActiveAssistantTranscriptMissing,
        adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("late")),
    );
}

test "tui owner transcript adapter rejects overlapping assistant messages" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent());
    try std.testing.expectError(
        error.ActiveAssistantTranscriptAlreadyOpen,
        adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent()),
    );
}

test "tui owner transcript adapter appends missing text_end suffix" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent());
    try adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("hel"));
    try adapter.apply(std.testing.allocator, &app, assistantTextEndEvent("hello"));
    try adapter.apply(std.testing.allocator, &app, assistantMessageEndEvent());

    const item = app.transcript.items.items[0];
    const block = app.transcript.document.block(item.block_id).?;
    try std.testing.expectEqualStrings("hello", block.bytes.items);
}

test "tui owner transcript adapter rejects final assistant text shorter than deltas" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent());
    try adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("hello"));

    try std.testing.expectError(
        error.ActiveAssistantTranscriptFinalTextShrank,
        adapter.apply(std.testing.allocator, &app, assistantTextEndEvent("hel")),
    );
}

test "tui owner transcript adapter appends missing done message text" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, assistantMessageStartEvent());
    try adapter.apply(std.testing.allocator, &app, assistantTextDeltaEvent("he"));
    try adapter.apply(std.testing.allocator, &app, assistantDoneHelloEvent());
    try adapter.apply(std.testing.allocator, &app, assistantMessageEndEvent());

    const item = app.transcript.items.items[0];
    const block = app.transcript.document.block(item.block_id).?;
    try std.testing.expectEqualStrings("hello", block.bytes.items);
}

test "tui owner transcript adapter creates sealed tool call and result items" {
    var app = tui.product.App.ProductApp.init(.{});
    defer app.deinit(std.testing.allocator);
    var adapter: TranscriptAdapter = .{};

    try adapter.apply(std.testing.allocator, &app, toolStartEvent("call-1", "bash"));
    try adapter.apply(std.testing.allocator, &app, toolEndDoneEvent("call-1", "bash", false));

    try std.testing.expectEqual(@as(usize, 2), app.transcript.items.items.len);
    const call_item = app.transcript.items.items[0];
    const result_item = app.transcript.items.items[1];
    try std.testing.expectEqual(tui.product.transcript.ItemKind.tool_call, call_item.kind);
    try std.testing.expectEqual(tui.product.transcript.ItemKind.tool_result, result_item.kind);
    try std.testing.expectEqual(tui.product.transcript.ItemState.sealed, call_item.state);
    try std.testing.expectEqual(tui.product.transcript.ItemState.sealed, result_item.state);
    try std.testing.expectEqualStrings(
        "tool bash started",
        app.transcript.document.block(call_item.block_id).?.bytes.items,
    );
    try std.testing.expectEqualStrings(
        "tool bash finished\ndone",
        app.transcript.document.block(result_item.block_id).?.bytes.items,
    );
}

test "tui owner cancel without active run requests shutdown" {
    var harness = try OwnerLoopHarness.init();
    defer harness.deinit();
    var owner = harness.owner();
    defer owner.deinit();

    try owner.applyFrontendAction(.cancel_run);

    try std.testing.expect(owner.shutdown_requested);
    try std.testing.expectEqual(frontend.ReadModel.Status.shutdown_requested, owner.read_model.status);
}

test "tui owner keeps one active prompt run" {
    var harness = try OwnerLoopHarness.init();
    defer harness.deinit();
    var owner = harness.owner();
    defer owner.deinit();

    try owner.applyFrontendAction(.{ .submit_prompt = .{ .text = "first" } });
    try std.testing.expect(owner.active_run != null);
    try std.testing.expectError(
        error.TuiPromptRunAlreadyActive,
        owner.applyFrontendAction(.{ .submit_prompt = .{ .text = "second" } }),
    );
}

test "tui owner cancel with active run marks cancel requested" {
    var harness = try OwnerLoopHarness.init();
    defer harness.deinit();
    var owner = harness.owner();
    defer owner.deinit();

    try owner.applyFrontendAction(.{ .submit_prompt = .{ .text = "first" } });
    try owner.applyFrontendAction(.cancel_run);

    try std.testing.expect(owner.active_run != null);
    try std.testing.expect(!owner.shutdown_requested);
    try std.testing.expectEqual(frontend.ReadModel.Status.cancel_requested, owner.read_model.status);
}

const OwnerLoopHarness = struct {
    zio_runtime: *runtime.Runtime,
    tmp: std.testing.TmpDir,
    app_runtime: sdk.Runtime,

    fn init() !OwnerLoopHarness {
        var zio_runtime = try runtime.Runtime.init(std.testing.allocator, .{});
        errdefer zio_runtime.deinit();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDirPath(std.testing.io, "agent");
        try tmp.dir.createDirPath(std.testing.io, "repo");
        const app_runtime = try sdk.createRuntimeHost(std.testing.allocator, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .current_date = "2026-06-02",
            .session_id = "tui-test",
            .timestamp = "2026-06-02T00:00:00Z",
            .dir = tmp.dir,
            .zio_runtime = zio_runtime,
        });
        return .{
            .zio_runtime = zio_runtime,
            .tmp = tmp,
            .app_runtime = app_runtime,
        };
    }

    fn deinit(self: *OwnerLoopHarness) void {
        self.app_runtime.deinit();
        self.tmp.cleanup();
        self.zio_runtime.deinit();
        self.* = undefined;
    }

    fn owner(self: *OwnerLoopHarness) OwnerLoop {
        const terminal: *tui.substrate.terminal.Terminal = undefined;
        const terminal_events: *tui.substrate.event_pump.TerminalEvents = undefined;
        return OwnerLoop.init(std.testing.allocator, &self.app_runtime.host, terminal, terminal_events);
    }
};

fn assistantMessageStartEvent() session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .message_start = .{
        .message = .{ .assistant = emptyAssistantMessage() },
    } } };
}

fn assistantTextDeltaEvent(delta: []const u8) session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = delta,
            .partial = emptyAssistantMessage(),
        } },
    } } };
}

fn assistantTextEndEvent(text: []const u8) session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = assistantMessageWithText(text) },
        .assistant_message_event = .{ .text_end = .{
            .content_index = 0,
            .content = text,
            .partial = assistantMessageWithText(text),
        } },
    } } };
}

const hello_assistant_content = [_]ai.AssistantContent{.{ .text = .{ .text = "hello" } }};
const done_tool_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "done" } }};

fn assistantDoneHelloEvent() session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = assistantMessage(&hello_assistant_content) },
        .assistant_message_event = .{ .done = .{
            .reason = .stop,
            .message = assistantMessage(&hello_assistant_content),
        } },
    } } };
}

fn assistantMessageEndEvent() session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .message_end = .{
        .message = .{ .assistant = emptyAssistantMessage() },
    } } };
}

fn toolStartEvent(
    tool_call_id: []const u8,
    tool_name: []const u8,
) session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .tool_execution_start = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .args = .null,
    } } };
}

fn toolEndDoneEvent(
    tool_call_id: []const u8,
    tool_name: []const u8,
    is_error: bool,
) session_events.AgentSessionEvent {
    return .{ .agent_event = .{ .tool_execution_end = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .result = .{ .content = &done_tool_content },
        .is_error = is_error,
    } } };
}

fn assistantMessageWithText(text: []const u8) ai.AssistantMessage {
    return assistantMessage(&.{.{ .text = .{ .text = text } }});
}

fn emptyAssistantMessage() ai.AssistantMessage {
    return assistantMessage(&.{});
}

fn assistantMessage(content: []const ai.AssistantContent) ai.AssistantMessage {
    return .{
        .content = content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{
                .input = 0,
                .output = 0,
                .cache_read = 0,
                .cache_write = 0,
                .total = 0,
            },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}
