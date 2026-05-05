const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const ui_event_mod = @import("../ui_event.zig");
const cell_mod = @import("../cell.zig");

const Interactive = @import("../interactive.zig").Interactive;

pub fn publishPending(self: *Interactive) void {
    if (self.runtime_host.takePendingExtensionReport(self.msg_allocator)) |report| {
        _ = self.publishLifecycleUiEvent(.{ .extension_report_shown = .{ .report = report } });
    }
    const updates = self.runtime_host.takePendingExtensionUiPublications(self.msg_allocator);
    if (updates.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_ui_published = .{ .updates = updates } });
    } else {
        self.msg_allocator.free(updates);
    }
    const surface_updates = self.runtime_host.takePendingExtensionSurfaceUpdates(self.msg_allocator);
    if (surface_updates.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_surface_updated = .{ .updates = surface_updates } });
    } else {
        self.msg_allocator.free(surface_updates);
    }
    const actions = self.runtime_host.takePendingExtensionEditorActions(self.msg_allocator);
    if (actions.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_editor_actions = .{ .actions = actions } });
    } else {
        self.msg_allocator.free(actions);
    }
}

pub fn applyReport(self: *Interactive, report: extension_ui.Report) void {
    self.extension_ui_state.applyReport(report);
    self.tui.dirty = true;
}

pub fn applyEditorActions(self: *Interactive, actions: []const extension_ui.EditorAction) void {
    for (actions) |action| {
        switch (action.kind) {
            .set_text => if (action.text) |text| self.active_editor.setText(text),
            .paste_text => if (action.text) |text| self.active_editor.handlePaste(text),
            .clear_text => self.active_editor.clear(),
            .get_text => {},
        }
    }
    self.tui.dirty = true;
}

pub fn applyPublications(self: *Interactive, updates: []const extension_ui.UiPublication) void {
    for (updates) |update| {
        switch (update.kind) {
            .message => self.extension_ui_state.applyMessage(update),
            .status => self.status_data.setStatus(update.id, update.text),
            .progress => self.extension_ui_state.applyProgress(update),
        }
    }
    self.tui.dirty = true;
}

pub fn applySurfaceUpdates(self: *Interactive, updates: []const extension_ui.SurfaceUpdate) void {
    var open_surface: ?extension_ui.SurfaceOpen = null;
    var close_surface = false;
    for (updates) |update| {
        switch (update) {
            .open => |open| open_surface = open,
            .close => close_surface = true,
            .frame => {},
        }
        self.extension_ui_state.applySurfaceUpdate(update);
    }

    if (close_surface) hideSurfaceOverlay(self);
    if (open_surface) |open| showSurfaceOverlay(self, open.wants_keyboard);
    self.tui.dirty = true;
}

fn showSurfaceOverlay(self: *Interactive, wants_keyboard: bool) void {
    if (self.extension_surface_overlay) |_| return;
    const component = self.extension_ui_state.surfaceComponent();
    self.extension_surface_overlay = self.tui.showOverlay(component, .{
        .anchor = .center,
        .width_percent = 92,
        .max_height_percent = 90,
        .margin_top = 1,
        .margin_bottom = 1,
        .non_capturing = !wants_keyboard,
        .surface = .{ .fill = cell_mod.Color.default },
        .backdrop = .dim,
    });
}

pub fn hideSurfaceOverlay(self: *Interactive) void {
    if (self.extension_surface_overlay) |handle| handle.hide();
    self.extension_surface_overlay = null;
}

pub fn applyCommandsUpdate(self: *Interactive, commands: []const ui_event_mod.ExtensionCommandEntry) void {
    for (self.command_registry.dynamic.items) |*cmd| {
        self.allocator.free(cmd.name);
        if (cmd.description) |d| self.allocator.free(d);
    }
    self.command_registry.dynamic.clearRetainingCapacity();

    for (commands) |entry| {
        const name = self.allocator.dupe(u8, entry.name) catch continue;
        const desc = self.allocator.dupe(u8, entry.description) catch {
            self.allocator.free(name);
            continue;
        };
        self.command_registry.register(.{
            .name = name,
            .description = desc,
            .source = .extension,
            .action = .extension,
        });
    }
    self.tui.dirty = true;
}
