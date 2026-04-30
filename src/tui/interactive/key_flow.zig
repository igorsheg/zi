const std = @import("std");
const keybindings = @import("../keybindings.zig");
const keys_mod = @import("../keys.zig");

const Key = keys_mod.Key;

pub fn handle(self: anytype, key: Key) void {
    if (self.tui.hasOverlay()) {
        if (self.tui.handleInput(key)) {
            if (self.extension_prompt_close_after_submit) {
                self.extension_prompt_close_after_submit = false;
                self.closeExtensionPromptFlow(false);
            }
            self.tui.dirty = true;
            return;
        }
        if (keybindings.matches(.select_cancel, key)) {
            if (self.extension_prompt_flow != null) {
                self.closeExtensionPromptFlow(true);
            } else {
                self.tui.hideOverlay();
            }
            return;
        }
        return;
    }

    if (keybindings.matches(.app_interrupt, key)) {
        if (self.retry_waiting) {
            self.runtime_host.abortRetry();
            return;
        }
        if (self.is_streaming) {
            self.runtime_host.abortCurrentRun();
            self.status_line.setPrimary("aborted", self.theme.fg(.@"error"));
            self.tui.dirty = true;
        }
        return;
    }

    if (keybindings.matches(.app_clear, key)) {
        const now = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));

        if (self.composerHasPendingInput()) {
            self.clearComposerDraft();
            self.last_ctrl_c_ns = now;
            self.tui.dirty = true;
            return;
        }

        if (self.login_thread != null) {
            self.login_cancelled.store(true, .release);
            return;
        }
        if (self.retry_waiting) {
            self.runtime_host.abortRetry();
            return;
        }
        if (self.is_streaming) {
            self.runtime_host.abortCurrentRun();
            self.status_line.setPrimary("aborted", self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return;
        }

        const double_tap_ns: i128 = 500 * std.time.ns_per_ms;
        if (now - self.last_ctrl_c_ns < double_tap_ns) {
            self.running = false;
            return;
        }
        self.clearComposerDraft();
        self.last_ctrl_c_ns = now;
        self.tui.dirty = true;
        return;
    }

    if (keybindings.matches(.app_exit, key)) {
        if (!self.composerHasPendingInput()) {
            self.running = false;
            return;
        }
    }

    if (keybindings.matches(.app_toggle_tools, key)) {
        self.tool_output_expanded = !self.tool_output_expanded;
        self.transcript.setToolOutputExpanded(self.tool_output_expanded);
        self.tui.dirty = true;
        return;
    }

    if (keybindings.matches(.app_toggle_thinking, key)) {
        self.hide_thinking_block = !self.hide_thinking_block;
        self.settings_manager.setHideThinkingBlock(self.hide_thinking_block);
        self.applyTranscriptHideThinkingBlock();
        self.tui.dirty = true;
        return;
    }

    if (keybindings.matches(.app_queue_follow_up, key)) {
        self.handleFollowUpShortcut();
        return;
    }

    if (keybindings.matches(.app_restore_queued, key)) {
        self.restoreQueuedInputsToEditor();
        return;
    }

    if (keybindings.matches(.app_paste_image, key)) {
        self.handlePasteImageShortcut();
        return;
    }

    if (handleScroll(self, key)) return;

    if (self.tui.handleInput(key)) {
        self.refreshHeaderVisibility();
        self.tui.dirty = true;
    }
}

pub fn handleScroll(self: anytype, key: Key) bool {
    const output_h = self.outputHeight();
    if (output_h == 0) return false;

    const page_size = @max(1, output_h -| 2);

    const delta: ?i64 = if (keybindings.matches(.app_scroll_page_up, key))
        -@as(i64, @intCast(page_size))
    else if (keybindings.matches(.app_scroll_page_down, key))
        @as(i64, @intCast(page_size))
    else if (keybindings.matches(.app_scroll_line_up, key))
        -3
    else if (keybindings.matches(.app_scroll_line_down, key))
        3
    else
        null;

    if (delta) |d| {
        const w = self.tui.width();
        self.transcript.scrollBy(w, output_h, d);
        self.tui.dirty = true;
        return true;
    }
    return false;
}
