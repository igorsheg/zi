const std = @import("std");
const vaxis = @import("vaxis");

const buffer_mod = @import("../primitive/buffer.zig");
const command_mod = @import("command.zig");
const composer_mod = @import("../product/composer.zig");
const event_mod = @import("event.zig");
const focus_mod = @import("../primitive/focus.zig");
const read_model_mod = @import("read_model.zig");
const builtin_mod = @import("../composition/builtin.zig");
const shell_mod = @import("../composition/shell.zig");
const renderer = @import("../substrate/renderer.zig");
const slot_mod = @import("../primitive/slot.zig");
const surface_mod = @import("../primitive/surface.zig");
const transcript_mod = @import("../product/transcript.zig");
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
    focus_stack: focus_mod.Stack = .init(builtin_mod.surfaces.composer),
    next_surface_insertion_index: u64 = 1,
    active_view_id: ?view_mod.ViewId = null,
    active_assistant_item_id: ?transcript_mod.TranscriptItemId = null,
    transcript: transcript_mod.Store,
    slots: slot_mod.Registry(&builtin_mod.slot_ids) = .{},
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
        app.active_view_id = builtin_mod.views.composer;
        app.getSurface(builtin_mod.surfaces.composer).?.focused = true;
        app.getSurface(builtin_mod.surfaces.composer).?.cursor_visible = true;
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

    pub fn drainEvents(self: *App, out: []event_mod.TuiEvent) usize {
        const drain_count = @min(out.len, self.event_count);
        if (drain_count == 0) return 0;
        @memcpy(out[0..drain_count], self.events[0..drain_count]);

        const remaining_count = self.event_count - drain_count;
        if (remaining_count > 0) {
            @memmove(self.events[0..remaining_count], self.events[drain_count..self.event_count]);
        }
        self.event_count = remaining_count;
        return drain_count;
    }

    pub fn dispatch(self: *App, command: command_mod.TuiCommand) !void {
        switch (command) {
            .append_transcript_text => |payload| try self.dispatchAppendTranscriptText(payload),
            .append_custom_transcript_item => |payload| try self.dispatchAppendCustomTranscriptItem(payload),
            .buffer_append => |payload| try self.appendBuffer(payload.id, payload.bytes),
            .buffer_replace => |payload| try self.replaceBuffer(payload.id, payload.bytes),
            .slot_set_text => |payload| try self.dispatchSlotSetText(payload),
            .slot_clear => |payload| try self.dispatchSlotClear(payload),
            .assistant_delta => |delta| try self.appendAssistantDelta(delta),
            .assistant_final_text => |text| try self.appendAssistantFinalText(text),
            .assistant_end => self.active_assistant_item_id = null,
            .composer_insert => |bytes| try self.dispatchComposerInsert(bytes),
            .composer_backspace => try self.dispatchComposerBackspace(),
            .composer_move_left => try self.dispatchComposerMoveLeft(),
            .composer_move_right => try self.dispatchComposerMoveRight(),
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
            if (buf.kind == .scrollback) {
                renderer.renderTextTail(surf, win, buf.text());
            } else {
                renderer.renderText(surf, win, buf.text());
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
        const surf = self.getSurfaceConst(builtin_mod.surfaces.composer) orelse return;
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
        for (builtin_mod.shell_buffers) |spec| {
            try self.createBuffer(spec.id, spec.kind, spec.name);
            if (spec.initial_text.len > 0) try self.appendBufferNoEvent(spec.id, spec.initial_text);
        }

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
            builtin_mod.surfaces.header => layout.header,
            builtin_mod.surfaces.transcript => layout.transcript,
            builtin_mod.surfaces.status => layout.status,
            builtin_mod.surfaces.composer => layout.composer,
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
        try self.rebuildTranscriptProjection();
    }

    fn dispatchAppendCustomTranscriptItem(
        self: *App,
        payload: command_mod.TuiCommand.AppendCustomTranscriptItem,
    ) !void {
        const item_id = try self.transcript.appendCustom(payload.durability, payload.custom_type, payload.data_json, 0);
        try self.emitTranscriptAppended(item_id, payload.durability);
        try self.rebuildTranscriptProjection();
    }

    fn dispatchSlotSetText(self: *App, payload: command_mod.TuiCommand.SlotSetText) !void {
        const s = self.slots.get(payload.slot_id);
        try s.setText(
            self.allocator,
            payload.contribution_id,
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

    fn dispatchComposerMoveLeft(self: *App) !void {
        const was_open = self.composer.completion != .closed;
        if (!self.composer.moveCursorLeft()) return;
        self.markBufferSurfacesDirty(builtin_mod.buffers.composer);
        try self.emit(.composer_changed);
        try self.emitCompletionTransition(was_open);
    }

    fn dispatchComposerMoveRight(self: *App) !void {
        const was_open = self.composer.completion != .closed;
        if (!self.composer.moveCursorRight()) return;
        self.markBufferSurfacesDirty(builtin_mod.buffers.composer);
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
        var buf = self.getBuffer(builtin_mod.buffers.composer).?;
        buf.clear(self.allocator);
        try buf.append(self.allocator, builtin_mod.composer_prompt);
        try buf.append(self.allocator, self.composer.text());
        self.markBufferSurfacesDirty(builtin_mod.buffers.composer);
        try self.emit(.{ .buffer_changed = .{ .id = builtin_mod.buffers.composer, .revision = buf.revision } });
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

    fn appendAssistantFinalText(self: *App, text: []const u8) !void {
        try self.applyAssistantTextUpdate(
            try self.transcript.appendAssistantFinalText(self.active_assistant_item_id, text, .ephemeral, 0),
        );
    }

    fn appendAssistantDelta(self: *App, delta: []const u8) !void {
        try self.applyAssistantTextUpdate(
            try self.transcript.appendAssistantDelta(&self.active_assistant_item_id, delta, .ephemeral, 0),
        );
    }

    fn applyAssistantTextUpdate(self: *App, update: transcript_mod.Store.TextUpdate) !void {
        switch (update) {
            .unchanged => return,
            .changed_existing => {},
            .appended_new => |id| try self.emitTranscriptAppended(id, .ephemeral),
        }
        try self.rebuildTranscriptProjection();
    }

    fn rebuildTranscriptProjection(self: *App) !void {
        const projection = self.getBuffer(builtin_mod.buffers.transcript).?;
        // The transcript store is the source of truth. Rebuild the projection
        // from it here so no mutation path can drift into a second transcript.
        try transcript_renderer_mod.Renderer.rebuildProjectionBuffer(self.allocator, &self.transcript, projection);
        self.markBufferSurfacesDirty(builtin_mod.buffers.transcript);
        try self.emit(.{ .buffer_changed = .{
            .id = builtin_mod.buffers.transcript,
            .revision = projection.revision,
        } });
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

    fn getBufferConst(self: *const App, id: buffer_mod.BufferId) ?*const buffer_mod.Buffer {
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

    fn focusedViewIdConst(self: *const App) view_mod.ViewId {
        const surf = self.getSurfaceConst(self.focusedSurfaceId()).?;
        return surf.view_id;
    }

    pub fn prepareComposerSubmission(self: *const App, allocator: std.mem.Allocator) !?[]u8 {
        const text = self.composer.text();
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return null;
        const owned = try allocator.dupe(u8, text);
        return owned;
    }

    /// Snapshot the observable TUI state without lending mutable store access.
    /// Future extension hooks should read this and request typed commands
    /// instead of touching App internals.
    pub fn readModel(self: *const App) read_model_mod.ReadModel {
        const projection = self.getBufferConst(builtin_mod.buffers.transcript).?;
        return .{
            .buffers = .{ .count = self.buffer_count, .capacity = buffer_count_max },
            .views = .{ .count = self.view_count, .capacity = view_count_max },
            .surfaces = .{ .count = self.surface_count, .capacity = surface_count_max },
            .events = .{ .count = self.event_count, .capacity = event_count_max },
            .focus = .{
                .surface_id = self.focusedSurfaceId(),
                .view_id = self.focusedViewIdConst(),
                .input_target = self.focusInputTarget(),
            },
            .transcript = .{
                .item_count = self.transcript.item_count,
                .item_count_max = transcript_mod.Store.item_count_max,
                .revision = self.transcript.revision,
                .active_assistant_item_id = self.active_assistant_item_id,
            },
            .composer = .{
                .text_byte_count = self.composer.text().len,
                .input_bytes_max = composer_mod.Composer.input_bytes_max,
                .cursor_byte_index = self.composer.cursor_byte_index,
                .revision = self.composer.revision,
                .completion = read_model_mod.completionFromComposer(self.composer.completion),
            },
            .transcript_projection = .{
                .buffer_id = projection.id,
                .revision = projection.revision,
                .byte_count = projection.text().len,
                .dropped_prefix_byte_count = projection.dropped_prefix_byte_count,
            },
        };
    }

    fn focusInputTarget(self: *const App) read_model_mod.ReadModel.InputTarget {
        return if (self.focusedSurfaceId() == builtin_mod.surfaces.composer) .composer else .surface;
    }

    pub fn dismissFocusedSurfaceByEscape(self: *App) !bool {
        const focused_id = self.focusedSurfaceId();
        const surf = self.getSurface(focused_id).?;
        if (!surface_mod.dismissesOnEscape(surf.dismiss_policy)) return false;
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
            self.surfaces[index].cursor_visible =
                is_active and self.surfaces[index].id == builtin_mod.surfaces.composer;
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

test "tui commands append to transcript buffer and render through the tui world" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .user_message,
        .durability = .persistent,
        .text = "hello",
    } });
    try app.dispatch(.{ .assistant_delta = "hi" });

    const projection = app.getBuffer(builtin_mod.buffers.transcript).?;
    try std.testing.expectEqualStrings("\n> hello\nhi", projection.text());
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

test "transcript rendering follows the live transcript tail" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .user_message,
        .durability = .persistent,
        .text = "Read the ai subsystem",
    } });
    inline for (0..3) |_| {
        try app.dispatch(.{ .append_transcript_text = .{
            .kind = .tool_call,
            .durability = .ephemeral,
            .text = "read",
        } });
    }
    try app.dispatch(.{ .assistant_delta = "final answer" });

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

test "transcript projection buffer is rebuildable from transcript store" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .user_message,
        .durability = .persistent,
        .text = "hello",
    } });
    try app.dispatch(.{ .assistant_delta = "hi" });

    const projected_before = try std.testing.allocator.dupe(u8, app.getBuffer(builtin_mod.buffers.transcript).?.text());
    defer std.testing.allocator.free(projected_before);

    app.getBuffer(builtin_mod.buffers.transcript).?.clear(std.testing.allocator);
    try app.rebuildTranscriptProjection();

    try std.testing.expectEqualStrings(projected_before, app.getBuffer(builtin_mod.buffers.transcript).?.text());
    try std.testing.expectEqual(@as(usize, 2), app.transcript.item_count);
}

test "assistant deltas mutate transcript before transcript projection" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.dispatch(.{ .assistant_delta = "he" });
    try app.dispatch(.{ .assistant_delta = "llo" });

    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
    try std.testing.expectEqualStrings("hello", app.transcript.items[0].payload.text);
    try std.testing.expectEqualStrings("hello", app.getBuffer(builtin_mod.buffers.transcript).?.text());
}

test "assistant final message renders when no deltas were streamed" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.dispatch(.{ .assistant_final_text = "final only answer" });
    try app.dispatch(.assistant_end);

    const projection = app.getBuffer(builtin_mod.buffers.transcript).?;
    try std.testing.expectEqualStrings("final only answer", projection.text());
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
}

test "assistant error message is visible even without text content" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.dispatch(.{ .assistant_final_text = "provider rejected tool result" });
    try app.dispatch(.assistant_end);

    try std.testing.expectEqualStrings(
        "provider rejected tool result",
        app.getBuffer(builtin_mod.buffers.transcript).?.text(),
    );
}

test "assistant final message does not duplicate streamed deltas" {
    var app = try App.init(std.testing.allocator, 40, 6);
    defer app.deinit();

    try app.dispatch(.{ .assistant_delta = "final" });
    try app.dispatch(.{ .assistant_final_text = "final answer" });
    try app.dispatch(.assistant_end);

    const projection = app.getBuffer(builtin_mod.buffers.transcript).?;
    try std.testing.expectEqualStrings("final answer", projection.text());
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
        .slot_id = builtin_mod.slots.composer_footer,
        .contribution_id = contribution_id,
        .text = "gpt-5.5",
    } });
    const footer = app.slots.get(builtin_mod.slots.composer_footer);
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
    try std.testing.expectEqualStrings("> hello", app.getBuffer(builtin_mod.buffers.composer).?.text());

    try app.dispatch(.composer_backspace);
    try std.testing.expectEqualStrings("> hell", app.getBuffer(builtin_mod.buffers.composer).?.text());

    try app.dispatch(.composer_clear);
    try std.testing.expectEqualStrings("> ", app.getBuffer(builtin_mod.buffers.composer).?.text());
}

test "composer cursor movement dirties input without changing text projection" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "a" });
    try app.dispatch(.{ .composer_insert = "中" });
    var drained_events: [App.event_count_max]event_mod.TuiEvent = undefined;
    _ = app.drainEvents(&drained_events);
    app.getSurface(builtin_mod.surfaces.composer).?.markClean();

    try app.dispatch(.composer_move_left);
    try std.testing.expectEqualStrings("> a中", app.getBuffer(builtin_mod.buffers.composer).?.text());
    try std.testing.expectEqual(@as(usize, 1), app.event_count);
    try std.testing.expectEqual(event_mod.TuiEvent.composer_changed, app.events[0]);
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.composer).?.dirty);
    try std.testing.expectEqual(@as(usize, 1), app.composer.cursor_byte_index);

    try app.dispatch(.composer_move_right);
    try std.testing.expectEqual(@as(usize, "a中".len), app.composer.cursor_byte_index);
}

test "read model exposes bounded state without store handles" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "@src" });
    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .user_message,
        .durability = .persistent,
        .text = "hello",
    } });

    const model = app.readModel();
    try std.testing.expectEqual(@as(usize, App.buffer_count_max), model.buffers.capacity);
    try std.testing.expectEqual(@as(usize, App.event_count_max), model.events.capacity);
    try std.testing.expectEqual(builtin_mod.surfaces.composer, model.focus.surface_id);
    try std.testing.expectEqual(builtin_mod.views.composer, model.focus.view_id);
    try std.testing.expectEqual(read_model_mod.ReadModel.InputTarget.composer, model.focus.input_target);
    try std.testing.expectEqual(@as(usize, 4), model.composer.text_byte_count);
    try std.testing.expectEqual(@as(usize, 4), model.composer.cursor_byte_index);
    try std.testing.expect(model.composer.completion == .open);
    try std.testing.expectEqual(@as(u8, '@'), model.composer.completion.open.trigger);
    try std.testing.expectEqual(@as(usize, 0), model.composer.completion.open.candidate_count);
    try std.testing.expectEqual(@as(usize, 1), model.transcript.item_count);
    try std.testing.expectEqual(builtin_mod.buffers.transcript, model.transcript_projection.buffer_id);
    try std.testing.expect(model.transcript_projection.byte_count > 0);
}

test "composer submission snapshot owns non-empty text" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try std.testing.expectEqual(@as(?[]u8, null), try app.prepareComposerSubmission(std.testing.allocator));
    try app.dispatch(.{ .composer_insert = "   " });
    try std.testing.expectEqual(@as(?[]u8, null), try app.prepareComposerSubmission(std.testing.allocator));

    try app.dispatch(.{ .composer_insert = "hello" });
    const submission = (try app.prepareComposerSubmission(std.testing.allocator)).?;
    defer std.testing.allocator.free(submission);
    try std.testing.expectEqualStrings("   hello", submission);
}

test "status buffer replacement is one owner mutation path" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .buffer_replace = .{ .id = builtin_mod.buffers.status, .bytes = "running" } });

    try std.testing.expectEqualStrings("running", app.getBuffer(builtin_mod.buffers.status).?.text());
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.status).?.dirty);
}

test "tool result errors are visible transcript items" {
    var app = try App.init(std.testing.allocator, 48, 6);
    defer app.deinit();

    try app.dispatch(.{ .append_transcript_text = .{
        .kind = .tool_call,
        .durability = .ephemeral,
        .text = "read error: tool execution failed: PathOutsideCwd",
    } });

    try std.testing.expectEqualStrings(
        "\n[tool] read error: tool execution failed: PathOutsideCwd\n",
        app.getBuffer(builtin_mod.buffers.transcript).?.text(),
    );
}

test "event queue is bounded and reports overflow" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    app.event_count = app.events.len;
    try std.testing.expectError(error.TuiEventQueueFull, app.dispatch(.{ .composer_insert = "x" }));
}

test "event queue drains in caller bounded batches" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .composer_insert = "x" });
    var first_event: [1]event_mod.TuiEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.drainEvents(&first_event));
    try std.testing.expect(first_event[0] == .buffer_changed);
    try std.testing.expectEqual(@as(usize, 1), app.event_count);

    var remaining_events: [App.event_count_max]event_mod.TuiEvent = undefined;
    try std.testing.expectEqual(@as(usize, 1), app.drainEvents(&remaining_events));
    try std.testing.expectEqual(event_mod.TuiEvent.composer_changed, remaining_events[0]);
    try std.testing.expectEqual(@as(usize, 0), app.event_count);

    try app.dispatch(.{ .composer_insert = "y" });
    try std.testing.expectEqual(@as(usize, 2), app.event_count);
}

test "closing a missing surface does not emit a phantom event" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .close_surface = builtin_mod.surfaces.diagnostics });
    try std.testing.expectEqual(@as(usize, 0), app.event_count);
}

test "open text surface command owns buffer view surface setup" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.dispatch(.{ .open_text_surface = .{
        .surface_id = builtin_mod.surfaces.diagnostics,
        .view_id = builtin_mod.views.diagnostics,
        .buffer_id = builtin_mod.buffers.diagnostics,
        .buffer_kind = .text,
        .buffer_name = "diagnostics",
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .escape,
        .text = "modal text",
    } });

    try std.testing.expectEqualStrings("modal text", app.getBuffer(builtin_mod.buffers.diagnostics).?.text());
    try std.testing.expectEqual(builtin_mod.surfaces.diagnostics, app.focusedSurfaceId());
    try std.testing.expectEqual(builtin_mod.views.diagnostics, app.focusedViewId());
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.diagnostics).?.focused);
}

test "modal surface owns focus and blocks composer routing until closed" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.createBuffer(builtin_mod.buffers.diagnostics, .text, "diagnostics");
    try app.createView(builtin_mod.views.diagnostics, builtin_mod.buffers.diagnostics, .init(2, 1, 20, 3));
    try app.dispatch(.{ .open_surface = .{
        .id = builtin_mod.surfaces.diagnostics,
        .view_id = builtin_mod.views.diagnostics,
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .escape,
    } });

    try std.testing.expectEqual(builtin_mod.surfaces.diagnostics, app.focusedSurfaceId());
    try std.testing.expectEqual(builtin_mod.views.diagnostics, app.focusedViewId());
    try std.testing.expectEqual(read_model_mod.ReadModel.InputTarget.surface, app.readModel().focus.input_target);
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.diagnostics).?.focused);
    try std.testing.expect(!app.getSurface(builtin_mod.surfaces.composer).?.focused);

    try app.dispatch(.{ .close_surface = builtin_mod.surfaces.diagnostics });
    try std.testing.expectEqual(builtin_mod.surfaces.composer, app.focusedSurfaceId());
    try std.testing.expectEqual(read_model_mod.ReadModel.InputTarget.composer, app.readModel().focus.input_target);
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.composer).?.focused);
}

test "escape dismisses only focused surfaces with escape dismiss policy" {
    var app = try App.init(std.testing.allocator, 32, 6);
    defer app.deinit();

    try app.createBuffer(builtin_mod.buffers.diagnostics, .text, "diagnostics");
    try app.createView(builtin_mod.views.diagnostics, builtin_mod.buffers.diagnostics, .init(2, 1, 20, 3));
    try app.dispatch(.{ .open_surface = .{
        .id = builtin_mod.surfaces.diagnostics,
        .view_id = builtin_mod.views.diagnostics,
        .rect = .init(2, 1, 20, 3),
        .layer = .modal,
        .modality = .focus_trap,
        .dismiss_policy = .none,
    } });

    try std.testing.expect(!try app.dismissFocusedSurfaceByEscape());
    try std.testing.expectEqual(builtin_mod.surfaces.diagnostics, app.focusedSurfaceId());

    app.getSurface(builtin_mod.surfaces.diagnostics).?.dismiss_policy = .escape_or_outside_click;
    try std.testing.expect(try app.dismissFocusedSurfaceByEscape());
    try std.testing.expectEqual(builtin_mod.surfaces.composer, app.focusedSurfaceId());
    try std.testing.expectEqual(@as(?*surface_mod.Surface, null), app.getSurface(builtin_mod.surfaces.diagnostics));
    try std.testing.expect(app.isDirty());
}

test "base shell surfaces are not closeable through commands" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try std.testing.expectError(
        error.CannotCloseBaseSurface,
        app.dispatch(.{ .close_surface = builtin_mod.surfaces.composer }),
    );
    try std.testing.expectEqual(builtin_mod.surfaces.composer, app.focusedSurfaceId());
}

test "assistant stream deltas accumulate into one transcript item" {
    var app = try App.init(std.testing.allocator, 32, 4);
    defer app.deinit();

    try app.dispatch(.{ .assistant_delta = "hel" });
    try app.dispatch(.{ .assistant_delta = "lo" });
    try std.testing.expectEqual(@as(usize, 1), app.transcript.item_count);
    try std.testing.expectEqualStrings("hello", app.transcript.items[0].payload.text);
}

test "surfaces render in deterministic layer and insertion order" {
    var app = try App.init(std.testing.allocator, 8, 4);
    defer app.deinit();

    try app.createBuffer(builtin_mod.buffers.diagnostics, .text, "diagnostics");
    try app.createView(builtin_mod.views.diagnostics, builtin_mod.buffers.diagnostics, .init(0, 0, 8, 1));
    try app.appendBuffer(builtin_mod.buffers.transcript, "base");
    try app.appendBuffer(builtin_mod.buffers.diagnostics, "modal");
    try app.createSurface(builtin_mod.surfaces.diagnostics, builtin_mod.views.diagnostics, .init(0, 0, 8, 1), .modal);

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

    const surf = app.getSurface(builtin_mod.surfaces.transcript).?;
    try std.testing.expectEqual(@as(u16, 20), surf.rect.width);
    try std.testing.expectEqual(@as(u16, 5), surf.rect.height);
    try std.testing.expectEqual(@as(u16, 1), surf.rect.y);
    const v = app.getView(builtin_mod.views.transcript).?;
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

    try app.appendBuffer(builtin_mod.buffers.transcript, "x");
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
    const composer_buffer = app.getBuffer(builtin_mod.buffers.composer).?;
    const composer_view = app.getView(builtin_mod.views.composer).?;
    try std.testing.expectEqual(composer_buffer.revision, composer_view.revision_seen);

    try app.dispatch(.{ .composer_insert = "z" });
    try std.testing.expect(composer_buffer.revision > composer_view.revision_seen);
    app.render(root);
    try std.testing.expectEqual(composer_buffer.revision, composer_view.revision_seen);
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
    try std.testing.expect(!app.getSurface(builtin_mod.surfaces.composer).?.dirty);

    try app.dispatch(.{ .composer_insert = "z" });
    app.debugAssertRenderInvariants();
    try std.testing.expect(app.getSurface(builtin_mod.surfaces.composer).?.dirty);
    try std.testing.expect(
        app.getView(builtin_mod.views.composer).?.revision_seen <
            app.getBuffer(builtin_mod.buffers.composer).?.revision,
    );
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
    const header_revision_seen = app.getView(builtin_mod.views.header).?.revision_seen;
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
    try std.testing.expectEqual(header_revision_seen, app.getView(builtin_mod.views.header).?.revision_seen);

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
        .surface_id = builtin_mod.surfaces.diagnostics,
        .view_id = builtin_mod.views.diagnostics,
        .buffer_id = builtin_mod.buffers.diagnostics,
        .buffer_kind = .text,
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
    try app.appendBuffer(builtin_mod.buffers.transcript, "dirty");
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
