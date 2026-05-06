const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const ui_event_mod = @import("../ui_event.zig");
const overlay_mod = @import("../overlay.zig");

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
    syncExtensionToastOverlay(self);
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

fn extensionToastOptions() overlay_mod.OverlayOptions {
    var options = overlay_mod.OverlayPresets.topToast();
    options.width = 40;
    options.max_height = null;
    options.max_height_percent = 40;
    return options;
}

pub fn syncExtensionToastOverlay(self: *Interactive) void {
    if (self.extension_ui_state.hasToastViews()) {
        if (self.extension_toast_overlay) |handle| {
            handle.setHidden(false);
        } else {
            self.extension_toast_overlay = self.tui.showOverlay(self.extension_ui_state.toastComponent(), extensionToastOptions());
        }
    } else if (self.extension_toast_overlay) |handle| {
        self.extension_toast_overlay = null;
        handle.hide();
    }
}
