const std = @import("std");
const vaxis = @import("vaxis");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const AgentSession = @import("../coding_agent/AgentSession.zig");

const buffer_mod = @import("buffer.zig");
const command_mod = @import("command.zig");
const composer_mod = @import("composer.zig");
const event_mod = @import("event.zig");
const slot_mod = @import("slot.zig");
const surface_mod = @import("surface.zig");
const transcript_mod = @import("transcript.zig");
const view_mod = @import("view.zig");

pub const App = struct {
    pub const buffer_count_max = 64;
    pub const view_count_max = 64;
    pub const surface_count_max = 64;
    pub const event_count_max = 256;

    allocator: std.mem.Allocator,
    buffers: [buffer_count_max]buffer_mod.Buffer = undefined,
    buffer_count: usize = 0,
    views: [view_count_max]view_mod.View = undefined,
    view_count: usize = 0,
    surfaces: [surface_count_max]surface_mod.Surface = undefined,
    surface_count: usize = 0,
    next_surface_insertion_index: u64 = 1,
    active_view_id: ?view_mod.ViewId = null,
    active_assistant_item_id: ?transcript_mod.TranscriptItemId = null,
    transcript: transcript_mod.Store,
    slots: slot_mod.Registry = .{},
    composer: composer_mod.Composer = .{},
    events: [event_count_max]event_mod.TuiEvent = undefined,
    event_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !App {
        var app: App = .{
            .allocator = allocator,
            .transcript = .init(allocator),
        };
        try app.createBuffer(.chat, .chat, "chat");
        try app.createView(.chat, .chat, .init(0, 0, width, height));
        try app.createSurface(.chat, .chat, .init(0, 0, width, height), .base);
        app.active_view_id = .chat;
        return app;
    }

    pub fn deinit(self: *App) void {
        var index: usize = 0;
        while (index < self.buffer_count) : (index += 1) {
            self.buffers[index].deinit(self.allocator);
        }
        self.transcript.deinit();
        self.slots.deinit(self.allocator);
        self.composer.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn drainEvents(self: *App) []const event_mod.TuiEvent {
        const drained = self.events[0..self.event_count];
        self.event_count = 0;
        return drained;
    }

    pub fn applyAgentSessionEvent(self: *App, event: AgentSession.AgentSessionEvent) !void {
        switch (event) {
            .agent_event => |agent_event| try self.applyAgentEvent(agent_event),
            else => {},
        }
    }

    pub fn dispatch(self: *App, command: command_mod.TuiCommand) !void {
        switch (command) {
            .append_transcript_text => |payload| try self.dispatchAppendTranscriptText(payload),
            .append_custom_transcript_item => |payload| try self.dispatchAppendCustomTranscriptItem(payload),
            .buffer_append => |payload| try self.appendBuffer(payload.id, payload.bytes),
            .slot_set_text => |payload| try self.dispatchSlotSetText(payload),
            .slot_clear => |payload| try self.dispatchSlotClear(payload),
            .composer_insert => |bytes| try self.dispatchComposerInsert(bytes),
            .composer_clear => try self.dispatchComposerClear(),
            .open_surface => |payload| try self.dispatchOpenSurface(payload),
            .close_surface => |id| try self.dispatchCloseSurface(id),
        }
    }

    pub fn render(self: *App, win: vaxis.Window) void {
        var ordered: [surface_count_max]usize = undefined;
        var count: usize = 0;
        while (count < self.surface_count) : (count += 1) ordered[count] = count;
        std.sort.insertion(usize, ordered[0..self.surface_count], self, surfaceLessThan);

        var order_index: usize = 0;
        while (order_index < self.surface_count) : (order_index += 1) {
            var surf = &self.surfaces[ordered[order_index]];
            const view = self.getView(surf.view_id).?;
            const buf = self.getBuffer(view.buffer_id).?;
            surf.renderText(win, buf.text());
        }
    }

    fn surfaceLessThan(self: *App, lhs_index: usize, rhs_index: usize) bool {
        const lhs = self.surfaces[lhs_index];
        const rhs = self.surfaces[rhs_index];
        const lhs_layer: u8 = @intFromEnum(lhs.layer);
        const rhs_layer: u8 = @intFromEnum(rhs.layer);
        if (lhs_layer != rhs_layer) return lhs_layer < rhs_layer;
        return lhs.insertion_index < rhs.insertion_index;
    }

    fn createBuffer(self: *App, id: buffer_mod.BufferId, kind: buffer_mod.Kind, name: []const u8) !void {
        if (self.buffer_count == self.buffers.len) return error.BufferStoreFull;
        std.debug.assert(self.getBuffer(id) == null);
        self.buffers[self.buffer_count] = .init(id, kind, name);
        self.buffer_count += 1;
    }

    fn createView(self: *App, id: view_mod.ViewId, buffer_id: buffer_mod.BufferId, rect: view_mod.Rect) !void {
        if (self.view_count == self.views.len) return error.ViewStoreFull;
        std.debug.assert(self.getView(id) == null);
        std.debug.assert(self.getBuffer(buffer_id) != null);
        self.views[self.view_count] = .init(id, buffer_id, rect);
        self.view_count += 1;
    }

    fn createSurface(
        self: *App,
        id: surface_mod.SurfaceId,
        view_id: view_mod.ViewId,
        rect: view_mod.Rect,
        layer: surface_mod.Layer,
    ) !void {
        if (self.surface_count == self.surfaces.len) return error.SurfaceStoreFull;
        std.debug.assert(self.getSurface(id) == null);
        std.debug.assert(self.getView(view_id) != null);
        self.surfaces[self.surface_count] = .init(id, view_id, rect, layer);
        self.surfaces[self.surface_count].insertion_index = self.next_surface_insertion_index;
        self.next_surface_insertion_index += 1;
        self.surface_count += 1;
    }

    fn dispatchAppendTranscriptText(self: *App, payload: command_mod.TuiCommand.AppendTranscriptText) !void {
        const item_id = try self.transcript.appendText(payload.kind, payload.durability, payload.text, 0);
        try self.emitTranscriptAppended(item_id, payload.durability);

        switch (payload.kind) {
            .user_message => {
                try self.appendChatText("\n> ");
                try self.appendChatText(payload.text);
                try self.appendChatText("\n");
            },
            .assistant_message, .system => try self.appendChatText(payload.text),
            .tool_call, .custom => {},
        }
    }

    fn dispatchAppendCustomTranscriptItem(self: *App, payload: command_mod.TuiCommand.AppendCustomTranscriptItem) !void {
        const item_id = try self.transcript.appendCustom(payload.durability, payload.custom_type, payload.data_json, 0);
        try self.emitTranscriptAppended(item_id, payload.durability);
    }

    fn dispatchSlotSetText(self: *App, payload: command_mod.TuiCommand.SlotSetText) !void {
        const s = self.slots.get(payload.slot_id);
        try s.setText(self.allocator, payload.contribution_id, payload.owner, payload.priority, payload.lifetime, payload.text);
        try self.emit(.{ .slot_changed = .{ .id = payload.slot_id, .revision = s.revision } });
    }

    fn dispatchSlotClear(self: *App, payload: command_mod.TuiCommand.SlotClear) !void {
        const s = self.slots.get(payload.slot_id);
        s.clear(self.allocator, payload.contribution_id);
        try self.emit(.{ .slot_changed = .{ .id = payload.slot_id, .revision = s.revision } });
    }

    fn dispatchComposerInsert(self: *App, bytes: []const u8) !void {
        const was_open = self.composer.completion != .closed;
        try self.composer.insert(self.allocator, bytes);
        try self.emit(.composer_changed);
        try self.emitCompletionTransition(was_open);
    }

    fn dispatchComposerClear(self: *App) !void {
        const was_open = self.composer.completion != .closed;
        self.composer.clear(self.allocator);
        try self.emit(.composer_changed);
        if (was_open) try self.emit(.completion_closed);
    }

    fn dispatchOpenSurface(self: *App, payload: command_mod.TuiCommand.OpenSurface) !void {
        try self.createSurface(payload.id, payload.view_id, payload.rect, payload.layer);
        const surf = self.getSurface(payload.id).?;
        surf.modality = payload.modality;
        surf.dismiss_policy = payload.dismiss_policy;
        try self.emit(.{ .surface_opened = .{ .id = payload.id } });
    }

    fn dispatchCloseSurface(self: *App, id: surface_mod.SurfaceId) !void {
        if (!self.closeSurface(id)) return;
        try self.emit(.{ .surface_closed = .{ .id = id } });
    }

    fn applyAgentEvent(self: *App, event: agent_mod.AgentEvent) !void {
        switch (event) {
            .message_end => |payload| try self.appendMessage(payload.message),
            .message_update => |payload| try self.appendAssistantEvent(payload.assistant_message_event),
            .tool_execution_start => |payload| {
                try self.dispatch(.{ .append_transcript_text = .{
                    .kind = .tool_call,
                    .durability = .ephemeral,
                    .text = payload.tool_name,
                } });
                try self.appendChatText("\n[tool] ");
                try self.appendChatText(payload.tool_name);
                try self.appendChatText("\n");
            },
            else => {},
        }
    }

    fn appendMessage(self: *App, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| switch (user.content) {
                .string => |text| {
                    try self.dispatch(.{ .append_transcript_text = .{
                        .kind = .user_message,
                        .durability = .persistent,
                        .text = text,
                    } });
                },
                .blocks => {},
            },
            else => {},
        }
    }

    fn appendAssistantEvent(self: *App, event: ai.AssistantMessageEvent) !void {
        switch (event) {
            .text_delta => |payload| {
                try self.appendAssistantDelta(payload.delta);
            },
            .text_end => {
                try self.appendChatText("\n");
                self.active_assistant_item_id = null;
            },
            else => {},
        }
    }

    fn appendAssistantDelta(self: *App, delta: []const u8) !void {
        if (self.active_assistant_item_id) |id| {
            try self.transcript.appendTextToItem(id, delta);
        } else {
            const id = try self.transcript.appendText(.assistant_message, .ephemeral, delta, 0);
            self.active_assistant_item_id = id;
            try self.emitTranscriptAppended(id, .ephemeral);
        }
        try self.appendChatText(delta);
    }

    fn appendChatText(self: *App, bytes: []const u8) !void {
        try self.appendBuffer(.chat, bytes);
    }

    fn appendBuffer(self: *App, id: buffer_mod.BufferId, bytes: []const u8) !void {
        var buf = self.getBuffer(id).?;
        try buf.append(self.allocator, bytes);
        self.markBufferSurfacesDirty(id);
        try self.emit(.{ .buffer_changed = .{ .id = id, .revision = buf.revision } });
    }

    fn markBufferSurfacesDirty(self: *App, buffer_id: buffer_mod.BufferId) void {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            const surf = &self.surfaces[index];
            const view = self.getView(surf.view_id).?;
            if (view.buffer_id == buffer_id) self.surfaces[index].markDirty();
        }
    }

    pub fn getBuffer(self: *App, id: buffer_mod.BufferId) ?*buffer_mod.Buffer {
        var index: usize = 0;
        while (index < self.buffer_count) : (index += 1) {
            if (self.buffers[index].id == id) return &self.buffers[index];
        }
        return null;
    }

    pub fn getView(self: *App, id: view_mod.ViewId) ?*view_mod.View {
        var index: usize = 0;
        while (index < self.view_count) : (index += 1) {
            if (self.views[index].id == id) return &self.views[index];
        }
        return null;
    }

    pub fn getSurface(self: *App, id: surface_mod.SurfaceId) ?*surface_mod.Surface {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            if (self.surfaces[index].id == id) return &self.surfaces[index];
        }
        return null;
    }

    fn closeSurface(self: *App, id: surface_mod.SurfaceId) bool {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            if (self.surfaces[index].id != id) continue;
            const last_index = self.surface_count - 1;
            if (index != last_index) self.surfaces[index] = self.surfaces[last_index];
            self.surface_count -= 1;
            return true;
        }
        return false;
    }

    fn emitTranscriptAppended(self: *App, id: transcript_mod.TranscriptItemId, durability: transcript_mod.Durability) !void {
        try self.emit(.{ .transcript_item_appended = .{
            .id = id,
            .durability = durability,
        } });
    }

    fn emitCompletionTransition(self: *App, was_open: bool) !void {
        const is_open = self.composer.completion != .closed;
        if (is_open and !was_open) try self.emit(.completion_opened);
        if (!is_open and was_open) try self.emit(.completion_closed);
    }

    fn emit(self: *App, event: event_mod.TuiEvent) !void {
        if (self.event_count == self.events.len) return error.TuiEventQueueFull;
        self.events[self.event_count] = event;
        self.event_count += 1;
    }
};

test "agent events append to chat buffer and render through the tui world" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .user = .{
            .content = .{ .string = "hello" },
            .timestamp = 0,
        } },
    } } });
    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = "hi",
            .partial = emptyAssistantMessage(),
        } },
    } } });

    const chat = app.getBuffer(.chat).?;
    try std.testing.expectEqualStrings("\n> hello\nhi", chat.text());
    try std.testing.expectEqual(@as(usize, 2), app.transcript.item_count);

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 32,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);
    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    app.render(root);

    try @import("testing.zig").expectScreenAscii(
        \\                                
        \\> hello                         
        \\hi                              
        \\                                
    , &screen, 32, 4);
}

test "tui commands own custom transcript slots and composer mutation" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .append_custom_transcript_item = .{
        .durability = .persistent,
        .custom_type = "todo",
        .data_json = "{\"items\":[]}",
    } });
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
    try std.testing.expectEqual(transcript_mod.Durability.persistent, app.transcript.items[0].durability);

    const contribution_id: slot_mod.ContributionId = @enumFromInt(1);
    try app.dispatch(.{ .slot_set_text = .{
        .slot_id = .composer_footer,
        .contribution_id = contribution_id,
        .owner = .builtin,
        .text = "gpt-5.5",
    } });
    const footer = app.slots.get(.composer_footer);
    try std.testing.expectEqual(@as(usize, 1), footer.contribution_count);
    try std.testing.expectEqualStrings("gpt-5.5", footer.contributions[0].text);

    try app.dispatch(.{ .composer_insert = "@src" });
    try std.testing.expectEqualStrings("@src", app.composer.text());
    try std.testing.expectEqual(@as(u8, '@'), app.composer.completion.open.trigger);
}

test "composer completion events are emitted only on transitions" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "hello" });
    try std.testing.expectEqual(@as(usize, 1), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.composer_changed, app.events[0]);

    try app.dispatch(.{ .composer_insert = " @s" });
    try std.testing.expectEqual(@as(usize, 3), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.completion_opened, app.events[2]);

    try app.dispatch(.{ .composer_insert = "rc" });
    try std.testing.expectEqual(@as(usize, 4), app.event_count);

    try app.dispatch(.composer_clear);
    try std.testing.expectEqual(@as(usize, 6), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.completion_closed, app.events[5]);
}

test "event queue is bounded and reports overflow" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    app.event_count = app.events.len;
    try std.testing.expectError(error.TuiEventQueueFull, app.dispatch(.{ .composer_insert = "x" }));
}

test "event queue drains so bounded events can be reused" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "x" });
    try std.testing.expectEqual(@as(usize, 1), app.drainEvents().len);
    try std.testing.expectEqual(@as(usize, 0), app.event_count);
    try app.dispatch(.{ .composer_insert = "y" });
    try std.testing.expectEqual(@as(usize, 1), app.drainEvents().len);
}

test "closing a missing surface does not emit a phantom event" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .close_surface = .diagnostics });
    try std.testing.expectEqual(@as(usize, 0), app.event_count);
}

test "assistant stream deltas accumulate into one transcript item" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.appendAssistantDelta("hel");
    try app.appendAssistantDelta("lo");
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
    try std.testing.expectEqualStrings("hello", app.transcript.items[0].payload.text);
}

test "surfaces render in deterministic layer and insertion order" {
    var app = try App.init(std.testing.allocator, 8, 1);
    defer app.deinit();

    try app.createBuffer(.diagnostics, .diagnostics, "diagnostics");
    try app.createView(.diagnostics, .diagnostics, .init(0, 0, 8, 1));
    try app.appendBuffer(.chat, "base");
    try app.appendBuffer(.diagnostics, "modal");
    try app.createSurface(.diagnostics, .diagnostics, .init(0, 0, 8, 1), .modal);

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 1,
        .cols = 8,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    app.render(.{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    });

    try @import("testing.zig").expectScreenAscii("modal   ", &screen, 8, 1);
}

fn emptyAssistantMessage() ai.AssistantMessage {
    return .{
        .content = &.{},
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
