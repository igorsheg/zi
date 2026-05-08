const theme_mod = @import("../theme.zig");

const Interactive = @import("../interactive.zig").Interactive;

pub fn publishSnapshot(self: *Interactive) void {
    _ = self.publishSnapshotUiEvent(.{ .theme_changed = self.runtime_host.selectedTheme() });
}

pub fn apply(self: *Interactive, theme: theme_mod.Theme) void {
    self.theme_storage = theme;
    self.theme = &self.theme_storage;
    self.greeter.theme = self.theme;
    self.footer.theme = self.theme;
    self.hotkeys_overlay.theme = self.theme;
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
