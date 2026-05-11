const std = @import("std");
const keybindings = @import("../keybindings.zig");
const keys_mod = @import("../terminal/keys.zig");

const Key = keys_mod.Key;
const log = std.log.scoped(.extension_ui_input);

pub fn handle(self: anytype, key: Key) void {
    if (self.tui.hasCapturingOverlay()) {
        if (self.tui.handleInput(key)) {
            self.tui.dirty = true;
            return;
        }
        if (self.extension_ui_state.handleOverlayInput(key)) |event| {
            log.debug("overlay input event type={s} node={s} action={s} value_len={d}", .{ @tagName(event.type), event.node orelse "", event.action orelse "", if (event.value) |value| value.len else 0 });
            if (dispatchExtensionUiEvent(self, event)) _ = self.extension_ui_state.dismissTopOverlayAfterInput();
            self.tui.dirty = true;
            return;
        }
        if (self.extension_ui_state.matchOverlayKey(key)) |event| {
            if (dispatchExtensionUiEvent(self, event)) _ = self.extension_ui_state.dismissTopOverlayAfterInput();
            self.tui.dirty = true;
            return;
        }
        if (keybindings.matches(.select_cancel, key)) {
            self.tui.hideOverlay();
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

        if (self.login_tasks != null) {
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

    if (dispatchExtensionKeybinding(self, key)) return;

    if (keybindings.matches(.app_toggle_tools, key)) {
        self.tool_output_expanded = !self.tool_output_expanded;
        const events = self.transcript.collectToolExpansionEvents(self.allocator) catch &.{};
        defer if (events.len > 0) self.allocator.free(events);
        self.transcript.setToolOutputExpanded(self.tool_output_expanded);
        for (events) |event| {
            const tool_name = self.msg_allocator.dupe(u8, event.tool_name) catch continue;
            const tool_call_id = self.msg_allocator.dupe(u8, event.tool_call_id) catch {
                self.msg_allocator.free(tool_name);
                continue;
            };
            switch (self.request_queue.trySend(.{ .tool_expanded_changed = .{
                .tool_name = tool_name,
                .tool_call_id = tool_call_id,
                .expanded = self.tool_output_expanded,
            } })) {
                .ok => {},
                .dropped => unreachable,
                .full => |rejected| {
                    var failed = rejected;
                    failed.deinit(self.msg_allocator);
                    break;
                },
                .closed, .oom => |rejected| {
                    var failed = rejected;
                    failed.deinit(self.msg_allocator);
                    break;
                },
            }
        }
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

    if (keybindings.matches(.app_editor_external, key)) {
        self.openPromptInExternalEditor();
        return;
    }

    if (handleScroll(self, key)) return;

    if (self.tui.handleInput(key)) {
        self.refreshHeaderVisibility();
        self.tui.dirty = true;
    }
}

fn dispatchExtensionUiEvent(self: anytype, event: @import("../../coding_agent/extensions/ui.zig").UiEvent) bool {
    const owned = @import("../../coding_agent/extensions/ui.zig").UiEvent.clone(self.msg_allocator, event) catch return false;
    switch (self.request_queue.trySend(.{ .extension_ui_event = owned })) {
        .ok, .dropped => return true,
        .full, .closed, .oom => |rejected| {
            var failed = rejected;
            failed.deinit(self.msg_allocator);
            return false;
        },
    }
}

fn dispatchExtensionKeybinding(self: anytype, key: Key) bool {
    if (keybindings.isReservedForExtensions(key)) return false;
    for (self.extension_keybindings.items) |entry| {
        if (Key.eql(entry.key, key)) {
            const id = self.msg_allocator.dupe(u8, entry.id) catch return true;
            _ = self.dispatchIdleRequest(.{ .extension_keybinding = .{ .id = id } }, .{
                .busy_message = "cannot run keybinding while agent is running",
                .loader_message = "Running keybinding...",
                .spawn_failed_message = "failed to queue extension keybinding",
            });
            return true;
        }
    }
    return false;
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
