const theme_mod = @import("../theme.zig");
const coding_agent_mod = @import("../../coding_agent/root.zig");
const UiEvent = @import("../ui_event.zig").UiEvent;

const Interactive = @import("../interactive.zig").Interactive;

pub fn publishSnapshot(self: *Interactive) void {
    publishSnapshotWithPublisher(&self.runtime_host, self);
}

pub fn publishSnapshotWithPublisher(runtime_host: *coding_agent_mod.RuntimeHost, publisher: anytype) void {
    _ = publisher.publishSnapshotUiEvent(.{ .theme_changed = runtime_host.selectedTheme() });
}

pub fn apply(self: *Interactive, theme: theme_mod.Theme) void {
    self.theme_storage = theme;
    self.theme = &self.theme_storage;
    self.greeter.theme = self.theme;
    self.footer.theme = self.theme;
    self.extension_ui_state.setTheme(self.theme);
    if (self.active_editor_bound) {
        self.active_editor.setTheme(self.theme);
    } else {
        self.editor.setTheme(self.theme);
    }
    self.transcript.theme = self.theme;
    self.status_line.setTheme(self.theme);
    self.pending_image_banner.fg = self.theme.fg(.accent);
    self.pending_image_banner.bg = self.theme.bg(.tool_pending_bg);
}
