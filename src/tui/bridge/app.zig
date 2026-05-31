const std = @import("std");
const vaxis = @import("vaxis");

const agent_mod = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const AgentSession = @import("../../coding_agent/AgentSession.zig");

const buffer_mod = @import("../primitive/buffer.zig");
const command_mod = @import("../primitive/command.zig");
const composer_mod = @import("../product/composer.zig");
const event_mod = @import("../primitive/event.zig");
const focus_mod = @import("../primitive/focus.zig");
const input_router_mod = @import("../primitive/input_router.zig");
const shell_mod = @import("../composition/shell.zig");
const slot_mod = @import("../primitive/slot.zig");
const surface_mod = @import("../primitive/surface.zig");
const transcript_mod = @import("../primitive/transcript.zig");
const transcript_renderer_mod = @import("../product/transcript_renderer.zig");
const tui_testing = @import("../substrate/testing.zig");
const view_mod = @import("../primitive/view.zig");

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
    focus_stack: focus_mod.Stack = .init(.input),
    next_surface_insertion_index: u64 = 1,
    active_view_id: ?view_mod.ViewId = null,
    active_assistant_item_id: ?transcript_mod.TranscriptItemId = null,
    transcript: transcript_mod.Store,
    slots: slot_mod.Registry = .{},
    composer: composer_mod.Composer = .{},
    events: [event_count_max]event_mod.TuiEvent = undefined,
    event_count: usize = 0,

    pub fn init(allocator: std.mem.Allocator, width: u16, height: u16) !App {
        std.debug.assert(height >= shell_mod.height_min);
        var app: App = .{
            .allocator = allocator,
            .transcript = .init(allocator),
        };
        try app.createShell(width, height);
        app.active_view_id = .input;
        app.getSurface(.input).?.focused = true;
        app.getSurface(.input).?.cursor_visible = true;
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

    pub fn clearEvents(self: *App) void {
        self.event_count = 0;
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
            .buffer_replace => |payload| try self.replaceBuffer(payload.id, payload.bytes),
            .slot_set_text => |payload| try self.dispatchSlotSetText(payload),
            .slot_clear => |payload| try self.dispatchSlotClear(payload),
            .composer_insert => |bytes| try self.dispatchComposerInsert(bytes),
            .composer_backspace => try self.dispatchComposerBackspace(),
            .composer_clear => try self.dispatchComposerClear(),
            .open_text_surface => |payload| try self.dispatchOpenTextSurface(payload),
            .open_surface => |payload| try self.dispatchOpenSurface(payload),
            .close_surface => |id| try self.dispatchCloseSurface(id),
        }
    }

    pub fn render(self: *App, win: vaxis.Window) void {
        self.debugAssertRenderInvariants();

        var ordered: [surface_count_max]usize = undefined;
        var count: usize = 0;
        while (count < self.surface_count) : (count += 1) ordered[count] = count;
        std.sort.insertion(usize, ordered[0..self.surface_count], self, surfaceLessThan);

        var order_index = firstDirtyOrderedSurface(self, ordered[0..self.surface_count]) orelse return;
        while (order_index < self.surface_count) : (order_index += 1) {
            const surf = &self.surfaces[ordered[order_index]];
            const view = self.getView(surf.view_id).?;
            const buf = self.getBuffer(view.buffer_id).?;
            if (buf.kind == .chat) {
                renderSurfaceTextTail(surf, win, buf.text());
            } else {
                renderSurfaceText(surf, win, buf.text());
            }
            view.markSeen(buf.revision);
        }
        self.applyCursor(win);
    }

    /// True when any surface has pending paint. The frame loop uses this to
    /// skip rendering when nothing changed, so repaint cost is paid only on
    /// real mutation rather than once per input event.
    pub fn isDirty(self: *const App) bool {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            if (self.surfaces[index].dirty) return true;
        }
        return false;
    }

    /// Retained rendering is correct only if every unseen buffer revision is
    /// covered by at least one dirty surface. Mutation paths must dirty the
    /// affected surfaces before the frame loop is allowed to skip or coalesce
    /// paint.
    fn debugAssertRenderInvariants(self: *App) void {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            const surf = self.surfaces[index];
            const view = self.getView(surf.view_id).?;
            const buf = self.getBuffer(view.buffer_id).?;
            if (view.revision_seen < buf.revision) {
                std.debug.assert(surf.dirty);
            }
        }
    }

    /// Mark every surface for repaint. Use this after the terminal backing
    /// screen is cleared or replaced, such as a physical terminal resize.
    pub fn forceFullRepaint(self: *App) void {
        self.markAllSurfacesDirty();
    }

    /// Stretch base-layer surfaces (and their views) to the full terminal
    /// bounds on a resize. Overlay layers keep their explicit rects.
    pub fn resize(self: *App, width: u16, height: u16) void {
        std.debug.assert(width > 0);
        std.debug.assert(height >= shell_mod.height_min);
        const layout = shell_mod.layout(width, height);
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            var surf = &self.surfaces[index];
            if (surf.layer != .base) continue;
            surf.rect = shellPlacement(layout, surf.id).rect;
            surf.markDirty();
            self.getView(surf.view_id).?.rect = surf.rect;
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

    fn firstDirtyOrderedSurface(self: *const App, ordered: []const usize) ?usize {
        var order_index: usize = 0;
        while (order_index < ordered.len) : (order_index += 1) {
            if (self.surfaces[ordered[order_index]].dirty) return order_index;
        }
        return null;
    }

    fn applyCursor(self: *const App, win: vaxis.Window) void {
        const surf = self.getSurfaceConst(.input) orelse return;
        if (!surf.cursor_visible) {
            win.hideCursor();
            return;
        }
        const cursor_col = self.composerCursorCol(win, surf.rect.width);
        win.showCursor(cursor_col, surf.rect.y);
    }

    fn composerCursorCol(self: *const App, win: vaxis.Window, width: u16) u16 {
        std.debug.assert(width > 0);
        const prompt_width: u16 = 2;
        const text = self.composer.text();
        std.debug.assert(self.composer.cursor_byte_index <= text.len);
        const before_cursor = text[0..self.composer.cursor_byte_index];
        const text_width: u16 = @intCast(win.gwidth(before_cursor));
        const col = prompt_width + text_width;
        return @min(col, width - 1);
    }

    fn createShell(self: *App, width: u16, height: u16) !void {
        try self.createBuffer(.header, .status, "header");
        try self.createBuffer(.chat, .chat, "chat");
        try self.createBuffer(.status, .status, "status");
        try self.createBuffer(.input, .input, "input");

        try self.appendBufferNoEvent(.header, "zi");
        try self.appendBufferNoEvent(.status, "idle");
        try self.appendBufferNoEvent(.input, "> ");

        const layout = shell_mod.layout(width, height);
        try self.createShellViewAndSurface(layout.header);
        try self.createShellViewAndSurface(layout.transcript);
        try self.createShellViewAndSurface(layout.status);
        try self.createShellViewAndSurface(layout.composer);
    }

    fn createShellViewAndSurface(self: *App, placement: shell_mod.Placement) !void {
        try self.createView(placement.view_id, placement.buffer_id, placement.rect);
        try self.createSurface(placement.surface_id, placement.view_id, placement.rect, .base);
    }

    fn shellPlacement(layout: shell_mod.Layout, id: surface_mod.SurfaceId) shell_mod.Placement {
        return switch (id) {
            .header => layout.header,
            .chat => layout.transcript,
            .status => layout.status,
            .input => layout.composer,
            else => unreachable,
        };
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

    fn ensureBufferAndView(
        self: *App,
        buffer_id: buffer_mod.BufferId,
        buffer_kind: buffer_mod.Kind,
        buffer_name: []const u8,
        view_id: view_mod.ViewId,
        rect: view_mod.Rect,
    ) !void {
        if (self.getBuffer(buffer_id) == null) try self.createBuffer(buffer_id, buffer_kind, buffer_name);
        if (self.getView(view_id)) |existing_view| {
            std.debug.assert(existing_view.buffer_id == buffer_id);
            existing_view.rect = rect;
        } else {
            try self.createView(view_id, buffer_id, rect);
        }
    }

    fn dispatchAppendTranscriptText(self: *App, payload: command_mod.TuiCommand.AppendTranscriptText) !void {
        const item_id = try self.transcript.appendText(payload.kind, payload.durability, payload.text, 0);
        try self.emitTranscriptAppended(item_id, payload.durability);
        try self.appendTranscriptItemProjection(item_id);
    }

    fn dispatchAppendCustomTranscriptItem(
        self: *App,
        payload: command_mod.TuiCommand.AppendCustomTranscriptItem,
    ) !void {
        const item_id = try self.transcript.appendCustom(payload.durability, payload.custom_type, payload.data_json, 0);
        try self.emitTranscriptAppended(item_id, payload.durability);
        try self.appendTranscriptItemProjection(item_id);
    }

    fn dispatchSlotSetText(self: *App, payload: command_mod.TuiCommand.SlotSetText) !void {
        const s = self.slots.get(payload.slot_id);
        try s.setText(
            self.allocator,
            payload.contribution_id,
            payload.owner,
            payload.priority,
            payload.lifetime,
            payload.text,
        );
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
        try self.syncComposerBuffer();
        try self.emit(.composer_changed);
        try self.emitCompletionTransition(was_open);
    }

    fn dispatchComposerBackspace(self: *App) !void {
        const was_open = self.composer.completion != .closed;
        if (!self.composer.backspace()) return;
        try self.syncComposerBuffer();
        try self.emit(.composer_changed);
        try self.emitCompletionTransition(was_open);
    }

    fn dispatchComposerClear(self: *App) !void {
        const was_open = self.composer.completion != .closed;
        self.composer.clear(self.allocator);
        try self.syncComposerBuffer();
        try self.emit(.composer_changed);
        if (was_open) try self.emit(.completion_closed);
    }

    fn dispatchOpenTextSurface(self: *App, payload: command_mod.TuiCommand.OpenTextSurface) !void {
        try self.ensureBufferAndView(
            payload.buffer_id,
            payload.buffer_kind,
            payload.buffer_name,
            payload.view_id,
            payload.rect,
        );
        if (self.getSurface(payload.surface_id) != null) {
            try self.dispatchCloseSurface(payload.surface_id);
        }
        try self.replaceBuffer(payload.buffer_id, payload.text);
        try self.dispatchOpenSurface(.{
            .id = payload.surface_id,
            .view_id = payload.view_id,
            .rect = payload.rect,
            .layer = payload.layer,
            .modality = payload.modality,
            .dismiss_policy = payload.dismiss_policy,
        });
    }

    fn syncComposerBuffer(self: *App) !void {
        var buf = self.getBuffer(.input).?;
        buf.clear(self.allocator);
        try buf.append(self.allocator, "> ");
        try buf.append(self.allocator, self.composer.text());
        self.markBufferSurfacesDirty(.input);
        try self.emit(.{ .buffer_changed = .{ .id = .input, .revision = buf.revision } });
    }

    fn dispatchOpenSurface(self: *App, payload: command_mod.TuiCommand.OpenSurface) !void {
        try self.createSurface(payload.id, payload.view_id, payload.rect, payload.layer);
        const surf = self.getSurface(payload.id).?;
        surf.modality = payload.modality;
        surf.dismiss_policy = payload.dismiss_policy;
        if (payload.modality != .modeless) try self.focusSurface(payload.id);
        try self.emit(.{ .surface_opened = .{ .id = payload.id } });
    }

    fn dispatchCloseSurface(self: *App, id: surface_mod.SurfaceId) !void {
        if (self.getSurface(id)) |surf| {
            if (surf.layer == .base) return error.CannotCloseBaseSurface;
        }
        if (!self.closeSurface(id)) return;
        self.focus_stack.remove(id);
        self.applyActiveFocus();
        self.markAllSurfacesDirty();
        try self.emitFocusedView();
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
            .assistant => |assistant| try self.appendAssistantMessageEnd(assistant),
            .tool_result => |tool_result| try self.appendToolResultMessage(tool_result),
            else => {},
        }
    }

    fn appendToolResultMessage(self: *App, message: ai.ToolResultMessage) !void {
        if (!message.is_error) return;
        const text = firstToolResultText(message.content) orelse return;
        const rendered = try std.fmt.allocPrint(self.allocator, "{s} error: {s}", .{ message.tool_name, text });
        defer self.allocator.free(rendered);
        try self.dispatch(.{ .append_transcript_text = .{
            .kind = .tool_call,
            .durability = .ephemeral,
            .text = rendered,
        } });
    }

    fn appendAssistantEvent(self: *App, event: ai.AssistantMessageEvent) !void {
        switch (event) {
            .text_delta => |payload| try self.appendAssistantDelta(payload.delta),
            .text_end => {
                // Keep the active item until message_end. Some providers emit only
                // final text at message_end, and streamed providers may need a
                // final suffix reconciliation.
            },
            else => {},
        }
    }

    fn appendAssistantMessageEnd(self: *App, assistant: ai.AssistantMessage) !void {
        if (assistant.error_message) |message| {
            try self.appendAssistantFinalText(message);
        }
        for (assistant.content) |content| {
            if (content != .text) continue;
            try self.appendAssistantFinalText(content.text.text);
        }
        self.active_assistant_item_id = null;
    }

    fn appendAssistantFinalText(self: *App, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.active_assistant_item_id) |id| {
            const item = self.transcript.get(id).?;
            const current = item.payload.text;
            if (std.mem.eql(u8, current, text)) return;
            if (std.mem.startsWith(u8, text, current)) {
                try self.appendAssistantDelta(text[current.len..]);
                return;
            }
        }

        const id = try self.transcript.appendText(.assistant_message, .ephemeral, text, 0);
        try self.emitTranscriptAppended(id, .ephemeral);
        try self.appendTranscriptItemProjection(id);
    }

    fn appendAssistantDelta(self: *App, delta: []const u8) !void {
        if (self.active_assistant_item_id) |id| {
            try self.transcript.appendTextToItem(id, delta);
        } else {
            const id = try self.transcript.appendText(.assistant_message, .ephemeral, delta, 0);
            self.active_assistant_item_id = id;
            try self.emitTranscriptAppended(id, .ephemeral);
        }
        try self.appendAssistantDeltaProjection(delta);
    }

    fn appendTranscriptItemProjection(self: *App, item_id: transcript_mod.TranscriptItemId) !void {
        const chat = self.getBuffer(.chat).?;
        const item = self.transcript.get(item_id).?;
        try transcript_renderer_mod.Renderer.appendItemToChatBuffer(self.allocator, item, chat);
        self.markBufferSurfacesDirty(.chat);
        try self.emit(.{ .buffer_changed = .{ .id = .chat, .revision = chat.revision } });
    }

    fn appendAssistantDeltaProjection(self: *App, delta: []const u8) !void {
        const chat = self.getBuffer(.chat).?;
        try transcript_renderer_mod.Renderer.appendAssistantDeltaToChatBuffer(self.allocator, delta, chat);
        self.markBufferSurfacesDirty(.chat);
        try self.emit(.{ .buffer_changed = .{ .id = .chat, .revision = chat.revision } });
    }

    fn appendBuffer(self: *App, id: buffer_mod.BufferId, bytes: []const u8) !void {
        var buf = self.getBuffer(id).?;
        try buf.append(self.allocator, bytes);
        self.markBufferSurfacesDirty(id);
        try self.emit(.{ .buffer_changed = .{ .id = id, .revision = buf.revision } });
    }

    fn replaceBuffer(self: *App, id: buffer_mod.BufferId, bytes: []const u8) !void {
        var buf = self.getBuffer(id).?;
        try buf.replace(self.allocator, bytes);
        self.markBufferSurfacesDirty(id);
        try self.emit(.{ .buffer_changed = .{ .id = id, .revision = buf.revision } });
    }

    fn appendBufferNoEvent(self: *App, id: buffer_mod.BufferId, bytes: []const u8) !void {
        var buf = self.getBuffer(id).?;
        try buf.append(self.allocator, bytes);
    }

    fn markBufferSurfacesDirty(self: *App, buffer_id: buffer_mod.BufferId) void {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            const surf = &self.surfaces[index];
            const view = self.getView(surf.view_id).?;
            if (view.buffer_id == buffer_id) self.surfaces[index].markDirty();
        }
    }

    fn markAllSurfacesDirty(self: *App) void {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) self.surfaces[index].markDirty();
    }

    fn getBuffer(self: *App, id: buffer_mod.BufferId) ?*buffer_mod.Buffer {
        var index: usize = 0;
        while (index < self.buffer_count) : (index += 1) {
            if (self.buffers[index].id == id) return &self.buffers[index];
        }
        return null;
    }

    fn getView(self: *App, id: view_mod.ViewId) ?*view_mod.View {
        var index: usize = 0;
        while (index < self.view_count) : (index += 1) {
            if (self.views[index].id == id) return &self.views[index];
        }
        return null;
    }

    fn getSurface(self: *App, id: surface_mod.SurfaceId) ?*surface_mod.Surface {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            if (self.surfaces[index].id == id) return &self.surfaces[index];
        }
        return null;
    }

    fn getSurfaceConst(self: *const App, id: surface_mod.SurfaceId) ?*const surface_mod.Surface {
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            if (self.surfaces[index].id == id) return &self.surfaces[index];
        }
        return null;
    }

    fn focusedSurfaceId(self: *const App) surface_mod.SurfaceId {
        return self.focus_stack.active();
    }

    fn focusedViewId(self: *App) view_mod.ViewId {
        const surf = self.getSurface(self.focusedSurfaceId()).?;
        return surf.view_id;
    }

    pub fn inputFocusTarget(self: *const App) input_router_mod.FocusTarget {
        return if (self.focusedSurfaceId() == .input) .composer else .surface;
    }

    pub fn dismissFocusedSurfaceByEscape(self: *App) !bool {
        const focused_id = self.focusedSurfaceId();
        const surf = self.getSurface(focused_id).?;
        if (!dismissesOnEscape(surf.dismiss_policy)) return false;
        try self.dispatch(.{ .close_surface = focused_id });
        return true;
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

    fn focusSurface(self: *App, id: surface_mod.SurfaceId) !void {
        std.debug.assert(self.getSurface(id) != null);
        try self.focus_stack.push(id);
        self.applyActiveFocus();
        try self.emitFocusedView();
    }

    fn applyActiveFocus(self: *App) void {
        const active_id = self.focusedSurfaceId();
        var index: usize = 0;
        while (index < self.surface_count) : (index += 1) {
            const is_active = self.surfaces[index].id == active_id;
            self.surfaces[index].focused = is_active;
            self.surfaces[index].cursor_visible = is_active and self.surfaces[index].id == .input;
            if (is_active) self.active_view_id = self.surfaces[index].view_id;
        }
    }

    fn emitFocusedView(self: *App) !void {
        try self.emit(.{ .view_focused = .{ .id = self.focusedViewId() } });
    }

    fn emitTranscriptAppended(
        self: *App,
        id: transcript_mod.TranscriptItemId,
        durability: transcript_mod.Durability,
    ) !void {
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

fn dismissesOnEscape(policy: surface_mod.DismissPolicy) bool {
    return switch (policy) {
        .escape, .escape_or_outside_click => true,
        .none, .outside_click, .action => false,
    };
}

fn firstToolResultText(content: []const ai.ToolResultContent) ?[]const u8 {
    for (content) |item| switch (item) {
        .text => |text| return text.text,
        .image => {},
    };
    return null;
}

fn renderSurfaceText(surf: *surface_mod.Surface, win: vaxis.Window, text: []const u8) void {
    const child = win.child(.{
        .x_off = @intCast(surf.rect.x),
        .y_off = @intCast(surf.rect.y),
        .width = surf.rect.width,
        .height = surf.rect.height,
    });
    child.clear();
    _ = child.print(&.{.{ .text = text }}, .{ .wrap = .word });
    surf.markClean();
}

fn renderSurfaceTextTail(surf: *surface_mod.Surface, win: vaxis.Window, text: []const u8) void {
    const tail = text[tailStartForLineCount(text, surf.rect.height)..];
    renderSurfaceText(surf, win, tail);
}

fn tailStartForLineCount(text: []const u8, line_count: u16) usize {
    if (line_count == 0 or text.len == 0) return text.len;

    var lines_seen: u16 = 1;
    var index = text.len;
    while (index > 0) {
        index -= 1;
        if (text[index] != '\n') continue;
        if (lines_seen == line_count) return index + 1;
        lines_seen += 1;
    }
    return 0;
}

test "agent events append to chat buffer and render through the tui world" {
    var app = try App.init(std.testing.allocator, 32, 6);
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
        .rows = 6,
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

    const rendered = try tui_testing.screenToAscii(std.testing.allocator, &screen, 32, 6);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "zi") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "> hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "idle") != null);
}

test "chat rendering follows the live transcript tail" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .user = .{
            .content = .{ .string = "Read the ai subsystem" },
            .timestamp = 0,
        } },
    } } });
    inline for (0..3) |_| {
        try app.applyAgentSessionEvent(.{ .agent_event = .{ .tool_execution_start = .{
            .tool_call_id = "tool",
            .tool_name = "read",
            .args = .null,
        } } });
    }
    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = "final answer",
            .partial = emptyAssistantMessage(),
        } },
    } } });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 6,
        .cols = 40,
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

    const rendered = try tui_testing.screenToAscii(std.testing.allocator, &screen, 40, 6);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "[tool] read") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "final answer") != null);
}

test "assistant final message renders when no deltas were streamed" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .assistant = assistantTextMessage("final only answer") },
    } } });

    const chat = app.getBuffer(.chat).?;
    try std.testing.expectEqualStrings("final only answer", chat.text());
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
}

test "assistant error message is visible even without text content" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    var message = emptyAssistantMessage();
    message.stop_reason = .error_;
    message.error_message = "provider rejected tool result";

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .assistant = message },
    } } });

    try std.testing.expectEqualStrings("provider rejected tool result", app.getBuffer(.chat).?.text());
}

test "assistant final message does not duplicate streamed deltas" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = "final",
            .partial = emptyAssistantMessage(),
        } },
    } } });
    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_update = .{
        .message = .{ .assistant = emptyAssistantMessage() },
        .assistant_message_event = .{ .text_end = .{
            .content_index = 0,
            .content = "final answer",
            .partial = assistantTextMessage("final answer"),
        } },
    } } });
    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .assistant = assistantTextMessage("final answer") },
    } } });

    const chat = app.getBuffer(.chat).?;
    try std.testing.expectEqualStrings("final answer", chat.text());
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
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
    try std.testing.expectEqual(@as(usize, 2), app.event_count);
    try std.testing.expect(app.events[0] == .buffer_changed);
    try std.testing.expectEqual(event_mod.TuiEvent.composer_changed, app.events[1]);

    try app.dispatch(.{ .composer_insert = " @s" });
    try std.testing.expectEqual(@as(usize, 5), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.completion_opened, app.events[4]);

    try app.dispatch(.{ .composer_insert = "rc" });
    try std.testing.expectEqual(@as(usize, 7), app.event_count);

    try app.dispatch(.composer_clear);
    try std.testing.expectEqual(@as(usize, 10), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.completion_closed, app.events[9]);
}

test "composer input buffer is a projection of editable text" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "hel" });
    try app.dispatch(.{ .composer_insert = "lo" });
    try std.testing.expectEqualStrings("> hello", app.getBuffer(.input).?.text());

    try app.dispatch(.composer_backspace);
    try std.testing.expectEqualStrings("> hell", app.getBuffer(.input).?.text());

    try app.dispatch(.composer_clear);
    try std.testing.expectEqualStrings("> ", app.getBuffer(.input).?.text());
}

test "status buffer replacement is one owner mutation path" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .buffer_replace = .{ .id = .status, .bytes = "running" } });

    try std.testing.expectEqualStrings("running", app.getBuffer(.status).?.text());
    try std.testing.expect(app.getSurface(.status).?.dirty);
}

test "tool result errors are visible transcript items" {
    var app = try App.init(std.testing.allocator, 48, 6);
    defer app.deinit();

    try app.applyAgentSessionEvent(.{ .agent_event = .{ .message_end = .{
        .message = .{ .tool_result = .{
            .tool_call_id = "tool-1",
            .tool_name = "read",
            .content = &.{.{ .text = .{ .text = "tool execution failed: PathOutsideCwd" } }},
            .is_error = true,
            .timestamp = 0,
        } },
    } } });

    try std.testing.expectEqualStrings(
        "\n[tool] read error: tool execution failed: PathOutsideCwd\n",
        app.getBuffer(.chat).?.text(),
    );
}

test "event queue is bounded and reports overflow" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    app.event_count = app.events.len;
    try std.testing.expectError(error.TuiEventQueueFull, app.dispatch(.{ .composer_insert = "x" }));
}

test "event queue clears so bounded events can be reused" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "x" });
    app.clearEvents();
    try std.testing.expectEqual(@as(usize, 0), app.event_count);

    try app.dispatch(.{ .composer_insert = "y" });
    try std.testing.expectEqual(@as(usize, 2), app.event_count);
}

test "closing a missing surface does not emit a phantom event" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .close_surface = .diagnostics });
    try std.testing.expectEqual(@as(usize, 0), app.event_count);
}

test "open text surface command owns buffer view surface setup" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.dispatch(.{ .open_text_surface = .{
        .surface_id = .diagnostics,
        .view_id = .diagnostics,
        .buffer_id = .diagnostics,
        .buffer_kind = .diagnostics,
        .buffer_name = "diagnostics",
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .escape,
        .text = "modal text",
    } });

    try std.testing.expectEqualStrings("modal text", app.getBuffer(.diagnostics).?.text());
    try std.testing.expectEqual(surface_mod.SurfaceId.diagnostics, app.focusedSurfaceId());
    try std.testing.expectEqual(view_mod.ViewId.diagnostics, app.focusedViewId());
    try std.testing.expect(app.getSurface(.diagnostics).?.focused);
}

test "modal surface owns focus and blocks composer routing until closed" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.createBuffer(.diagnostics, .diagnostics, "diagnostics");
    try app.createView(.diagnostics, .diagnostics, .init(2, 1, 20, 3));
    try app.dispatch(.{ .open_surface = .{
        .id = .diagnostics,
        .view_id = .diagnostics,
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .escape,
    } });

    try std.testing.expectEqual(surface_mod.SurfaceId.diagnostics, app.focusedSurfaceId());
    try std.testing.expectEqual(view_mod.ViewId.diagnostics, app.focusedViewId());
    try std.testing.expectEqual(input_router_mod.FocusTarget.surface, app.inputFocusTarget());
    try std.testing.expect(app.getSurface(.diagnostics).?.focused);
    try std.testing.expect(!app.getSurface(.input).?.focused);

    try app.dispatch(.{ .close_surface = .diagnostics });
    try std.testing.expectEqual(surface_mod.SurfaceId.input, app.focusedSurfaceId());
    try std.testing.expectEqual(input_router_mod.FocusTarget.composer, app.inputFocusTarget());
    try std.testing.expect(app.getSurface(.input).?.focused);
}

test "escape dismisses only focused surfaces with escape dismiss policy" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.createBuffer(.diagnostics, .diagnostics, "diagnostics");
    try app.createView(.diagnostics, .diagnostics, .init(2, 1, 20, 3));
    try app.dispatch(.{ .open_surface = .{
        .id = .diagnostics,
        .view_id = .diagnostics,
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .none,
    } });

    try std.testing.expect(!try app.dismissFocusedSurfaceByEscape());
    try std.testing.expectEqual(surface_mod.SurfaceId.diagnostics, app.focusedSurfaceId());

    app.getSurface(.diagnostics).?.dismiss_policy = .escape_or_outside_click;
    try std.testing.expect(try app.dismissFocusedSurfaceByEscape());
    try std.testing.expectEqual(surface_mod.SurfaceId.input, app.focusedSurfaceId());
    try std.testing.expectEqual(@as(?*surface_mod.Surface, null), app.getSurface(.diagnostics));
    try std.testing.expect(app.isDirty());
}

test "base shell surfaces are not closeable through commands" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try std.testing.expectError(error.CannotCloseBaseSurface, app.dispatch(.{ .close_surface = .input }));
    try std.testing.expectEqual(surface_mod.SurfaceId.input, app.focusedSurfaceId());
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
    var app = try App.init(std.testing.allocator, 8, 4);
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

    try tui_testing.expectScreenAscii("modal   ", &screen, 8, 1);
}

test "resize lays out shell surfaces and views and marks dirty" {
    var app = try App.init(std.testing.allocator, 10, 4);
    defer app.deinit();

    app.resize(20, 8);

    const surf = app.getSurface(.chat).?;
    try std.testing.expectEqual(@as(u16, 20), surf.rect.width);
    try std.testing.expectEqual(@as(u16, 5), surf.rect.height);
    try std.testing.expectEqual(@as(u16, 1), surf.rect.y);
    const v = app.getView(.chat).?;
    try std.testing.expectEqual(@as(u16, 20), v.rect.width);
    try std.testing.expectEqual(@as(u16, 5), v.rect.height);
    try std.testing.expectEqual(@as(u16, 1), v.rect.y);
    try std.testing.expect(app.isDirty());
}

test "force full repaint dirties every surface after retained render is clean" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    try std.testing.expect(!app.isDirty());

    app.forceFullRepaint();

    var index: usize = 0;
    while (index < app.surface_count) : (index += 1) {
        try std.testing.expect(app.surfaces[index].dirty);
    }
}

test "render clears dirty until the next mutation" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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

    try std.testing.expect(app.isDirty());
    app.render(root);
    try std.testing.expect(!app.isDirty());

    try app.appendBuffer(.chat, "x");
    try std.testing.expect(app.isDirty());
}

test "render records buffer revision seen by painted views" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    try std.testing.expectEqual(app.getBuffer(.input).?.revision, app.getView(.input).?.revision_seen);

    try app.dispatch(.{ .composer_insert = "z" });
    try std.testing.expect(app.getBuffer(.input).?.revision > app.getView(.input).?.revision_seen);
    app.render(root);
    try std.testing.expectEqual(app.getBuffer(.input).?.revision, app.getView(.input).?.revision_seen);
}

test "render places composer cursor from composer state" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    try std.testing.expect(screen.cursor_vis);
    try std.testing.expectEqual(@as(u16, 2), screen.cursor.col);
    try std.testing.expectEqual(@as(u16, shell_mod.layout(12, 4).composer.rect.y), screen.cursor.row);

    try app.dispatch(.{ .composer_insert = "hello" });
    app.render(root);
    try std.testing.expectEqual(@as(u16, 7), screen.cursor.col);

    try app.dispatch(.composer_backspace);
    app.render(root);
    try std.testing.expectEqual(@as(u16, 6), screen.cursor.col);
}

test "mutation dirties surfaces that have not seen the latest buffer revision" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    try std.testing.expect(!app.getSurface(.input).?.dirty);

    try app.dispatch(.{ .composer_insert = "z" });
    app.debugAssertRenderInvariants();
    try std.testing.expect(app.getSurface(.input).?.dirty);
    try std.testing.expect(app.getView(.input).?.revision_seen < app.getBuffer(.input).?.revision);
}

test "render skips clean surfaces before the first dirty surface" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    const header_revision_seen = app.getView(.header).?.revision_seen;
    try tui_testing.expectScreenAscii(
        "zi          \n" ++
            "            \n" ++
            "idle        \n" ++
            ">           ",
        &screen,
        12,
        4,
    );

    _ = root.print(&.{.{ .text = "XX" }}, .{});
    try app.dispatch(.{ .composer_insert = "a" });
    app.render(root);
    try std.testing.expectEqual(header_revision_seen, app.getView(.header).?.revision_seen);

    try tui_testing.expectScreenAscii(
        "XX          \n" ++
            "            \n" ++
            "idle        \n" ++
            "> a         ",
        &screen,
        12,
        4,
    );
}

test "render repaints clean overlays above a dirty lower layer" {
    var app = try App.init(std.testing.allocator, 12, 4);
    defer app.deinit();

    try app.dispatch(.{ .open_text_surface = .{
        .surface_id = .diagnostics,
        .view_id = .diagnostics,
        .buffer_id = .diagnostics,
        .buffer_kind = .diagnostics,
        .buffer_name = "diagnostics",
        .rect = .init(0, 1, 12, 1),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .escape,
        .text = "modal",
    } });

    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 4,
        .cols = 12,
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
    try app.appendBuffer(.chat, "dirty");
    app.render(root);

    try tui_testing.expectScreenAscii(
        "zi          \n" ++
            "modal       \n" ++
            "idle        \n" ++
            ">           ",
        &screen,
        12,
        4,
    );
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

fn assistantTextMessage(comptime text: []const u8) ai.AssistantMessage {
    return .{
        .content = &.{.{ .text = .{ .text = text } }},
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
