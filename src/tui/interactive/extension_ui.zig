const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const ui_event_mod = @import("../ui_event.zig");
const overlay_mod = @import("../primitives/overlay.zig");

const Interactive = @import("../interactive.zig").Interactive;

pub fn publishPending(self: *Interactive) void {
    const render_updates = self.runtime_host.takePendingExtensionRenderUpdates(self.msg_allocator);
    if (render_updates.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_ui_rendered = .{ .updates = render_updates } });
    } else {
        self.msg_allocator.free(render_updates);
    }
    const frame_updates = self.runtime_host.takePendingExtensionFrameUpdates(self.msg_allocator);
    if (frame_updates.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_ui_framed = .{ .updates = frame_updates } });
    } else {
        self.msg_allocator.free(frame_updates);
    }
    const actions = self.runtime_host.takePendingExtensionEditorActions(self.msg_allocator);
    if (actions.len > 0) {
        _ = self.publishLifecycleUiEvent(.{ .extension_editor_actions = .{ .actions = actions } });
    } else {
        self.msg_allocator.free(actions);
    }
}

pub fn applyRenderUpdates(self: *Interactive, updates: []const extension_ui.RenderSpec) void {
    for (updates) |update| self.extension_ui_state.applyRender(update);
    syncExtensionNotificationOverlay(self);
    syncExtensionOverlay(self);
    self.tui.dirty = true;
}

pub fn applyFrameUpdates(self: *Interactive, updates: []const extension_ui.UiFrame) void {
    for (updates) |update| self.extension_ui_state.applyFrame(update);
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

fn extensionNotificationOptions(self: *Interactive) overlay_mod.OverlayOptions {
    var options = overlay_mod.OverlayPresets.topToast();
    options.anchor = .bottom_right;
    options.width = 44;
    options.max_height = null;
    options.max_height_percent = 40;
    return self.extension_ui_state.syncOverlayOptions(.notification, options);
}

fn extensionOverlayOptions(self: *Interactive) overlay_mod.OverlayOptions {
    var options = overlay_mod.OverlayPresets.centerDialog();
    options.non_capturing = !self.extension_ui_state.targetWantsFocus(.overlay);
    return self.extension_ui_state.syncOverlayOptions(.overlay, options);
}

pub fn syncExtensionNotificationOverlay(self: *Interactive) void {
    if (self.extension_ui_state.hasNotificationViews()) {
        if (self.extension_notification_overlay) |handle| {
            handle.setOptions(extensionNotificationOptions(self));
            handle.setHidden(false);
        } else {
            self.extension_notification_overlay = self.tui.showOverlay(self.extension_ui_state.notificationComponent(), extensionNotificationOptions(self));
        }
    } else if (self.extension_notification_overlay) |handle| {
        self.extension_notification_overlay = null;
        handle.hide();
    }
}

pub fn syncExtensionOverlay(self: *Interactive) void {
    if (self.extension_ui_state.hasOverlayViews()) {
        if (self.extension_overlay_handle) |handle| {
            const options = extensionOverlayOptions(self);
            handle.setOptions(options);
            handle.setHidden(false);
            if (!options.non_capturing) handle.focus();
        } else {
            self.extension_overlay_handle = self.tui.showOverlay(self.extension_ui_state.overlayComponent(), extensionOverlayOptions(self));
        }
    } else if (self.extension_overlay_handle) |handle| {
        self.extension_overlay_handle = null;
        handle.hide();
    }
}
