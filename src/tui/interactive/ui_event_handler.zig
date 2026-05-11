const std = @import("std");
const ui_event_mod = @import("../ui_event.zig");
const agent_ui_event_mod = @import("agent_ui_event.zig");

const UiEvent = ui_event_mod.UiEvent;
const userFacingFailureMessage = agent_ui_event_mod.userFacingFailureMessage;

pub fn handle(self: anytype, ev: *UiEvent) void {
    if (ev.takeConversationSnapshot()) |snapshot| {
        var owned = snapshot;
        const was_following_bottom = self.transcript.isFollowingBottom();
        self.conversation_projection.replaceViewSnapshot(
            &self.transcript,
            self.active_editor,
            self.resolver,
            &owned,
            .{
                .theme = self.theme,
                .retry_attempt = self.retry_attempt,
                .hidden_thinking_label = self.currentHiddenThinkingLabel(),
                .width_method = self.tui.terminal.capabilities.width_method,
            },
        );
        if (was_following_bottom) {
            self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
        }
        self.tui.dirty = true;
        return;
    }

    if (ev.takeQueuedSnapshot()) |snapshot| {
        var owned = snapshot;
        const was_following_bottom = self.transcript.isFollowingBottom();
        self.conversation_projection.replaceQueuedSnapshot(
            &self.transcript,
            self.active_editor,
            self.resolver,
            &owned,
            .{
                .theme = self.theme,
                .retry_attempt = self.retry_attempt,
                .hidden_thinking_label = self.currentHiddenThinkingLabel(),
                .width_method = self.tui.terminal.capabilities.width_method,
            },
        );
        if (was_following_bottom) {
            self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
        }
        self.tui.dirty = true;
        return;
    }

    if (ev.takeVisibleModelsSnapshot()) |models| {
        self.applyVisibleModelsSnapshot(models);
        self.tui.dirty = true;
        return;
    }

    switch (ev.*) {
        .consumed => {},
        .conversation_snapshot => unreachable,
        .queued_snapshot => unreachable,
        .visible_models_snapshot => unreachable,
        .error_message => |e| {
            self.status_line.setPrimary(e.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
        .theme_changed => |theme| {
            self.applyTheme(theme);
            self.tui.dirty = true;
        },
        .assistant_run_finished => |m| {
            self.tui.dirty = true;
            if (m.is_aborted) {
                self.status_line.setPrimary(m.error_message orelse "aborted", self.theme.fg(.@"error"));
            } else if (m.error_message) |msg| {
                self.status_line.setPrimary(userFacingFailureMessage(m.failure_kind, msg), self.theme.fg(.@"error"));
            }
        },
        .tool_running => |t| {
            self.status_line.setPrimary(t.tool_name, self.theme.fg(.accent));
            self.tui.dirty = true;
        },
        .login_progress => |l| {
            self.status_line.setPrimary(l.message, switch (l.kind) {
                .auth_url => self.theme.fg(.accent),
                .info => self.theme.fg(.muted),
            });
            self.tui.dirty = true;
        },
        .login_complete => |l| {
            if (self.login_tasks) |*tasks| tasks.join() catch {};
            self.login_tasks = null;

            if (l.success) {
                self.status_line.setPrimary(l.message, self.theme.fg(.success));
            } else {
                self.status_line.setPrimary(l.message, self.theme.fg(.@"error"));
            }
            self.tui.dirty = true;
        },
        .retry_start => |r| {
            self.retry_active = true;
            self.retry_waiting = true;
            self.retry_attempt = r.attempt;
            self.retry_max_attempts = r.max_attempts;
            self.retry_delay_ms = r.delay_ms;
            self.refreshBuiltInStatus();
        },
        .retry_wait_finished => {
            self.retry_waiting = false;
            self.retry_delay_ms = 0;
            self.refreshBuiltInStatus();
        },
        .retry_end => |r| {
            self.retry_active = false;
            self.retry_waiting = false;
            self.retry_attempt = 0;
            self.retry_max_attempts = 0;
            self.retry_delay_ms = 0;
            self.refreshBuiltInStatus();
            if (!r.success) {
                var buf: [160]u8 = undefined;
                const final_error = r.final_error orelse "unknown error";
                const msg = std.fmt.bufPrint(
                    &buf,
                    "retry failed after {d} attempt{s}: {s}",
                    .{ r.attempt, if (r.attempt == 1) "" else "s", userFacingFailureMessage(r.failure_kind, final_error) },
                ) catch userFacingFailureMessage(r.failure_kind, final_error);
                self.status_line.setPrimary(msg, self.theme.fg(.@"error"));
            }
            self.tui.dirty = true;
        },
        .compaction_start => |c| self.showCompactionLoader(c.reason),
        .compaction_end => self.finishCompactionLoader(),
        .prompt_worker_finished => |p| {
            self.is_streaming = false;
            self.hideLoader();
            self.tui.setFocus(self.active_editor.component());
            switch (p.outcome) {
                .success => self.status_line.clearPrimary(),
                .assistant_error, .aborted => {},
            }
            if (p.internal_error) |msg| {
                self.status_line.setPrimary(msg, self.theme.fg(.@"error"));
            }
            self.tui.dirty = true;
        },
        .request_worker_finished => {
            if (self.request_in_flight) {
                self.request_in_flight = false;
                self.hideLoader();
            }
            self.tui.dirty = true;
        },
        .session_resumed => |r| {
            self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
            if (r.restore_warning) |w| {
                self.status_line.setPrimary(w, self.theme.fg(.warning));
            } else {
                self.status_line.setPrimary("session resumed", self.theme.fg(.success));
            }
            self.tui.dirty = true;
        },
        .session_resume_failed => |f| {
            self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
        .resume_sessions_loaded => |r| self.applyResumeSessionsLoaded(r.generation, r.sessions),
        .resume_sessions_failed => |f| self.applyResumeSessionsFailed(f.generation, f.message),
        .extension_commands_updated => |u| self.applyExtensionCommandsUpdate(u.commands),
        .extension_keybindings_updated => |u| self.applyExtensionKeybindingsUpdate(u.keybindings),
        .extension_ui_rendered => |u| self.applyExtensionRenderUpdates(u.updates),
        .extension_ui_framed => |u| self.applyExtensionFrameUpdates(u.updates),
        .extension_editor_actions => |u| self.applyExtensionEditorActions(u.actions),
        .session_new_started => {
            self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
            self.status_line.setPrimary("new session started", self.theme.fg(.success));
            self.tui.dirty = true;
        },
        .session_fork_started => {
            self.transcript.scrollToBottom(self.tui.width(), self.outputHeight());
            self.status_line.setPrimary("session forked", self.theme.fg(.success));
            self.tui.dirty = true;
        },
        .session_new_failed => |f| {
            self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
        .session_compacted => {
            self.status_line.setPrimary("session compacted; ctx updates after next response", self.theme.fg(.success));
            self.tui.dirty = true;
        },
        .session_compaction_failed => |f| {
            self.status_line.setPrimary(f.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
        .status_snapshot => |s| {
            self.applyStatusSnapshot(s);
            self.tui.dirty = true;
        },
        .model_switch_failed => |m| {
            self.status_line.setPrimary(m.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
        .model_switched => |m| {
            var buf: [80]u8 = undefined;
            const label = if (m.model_id.len > 0) m.model_id else "model switched";
            const msg = std.fmt.bufPrint(&buf, "Model: {s}", .{label}) catch "model switched";
            self.status_line.setPrimary(msg, self.theme.fg(.success));
            self.tui.dirty = true;
        },
        .thinking_level_changed => |t| {
            var buf: [96]u8 = undefined;
            const level = if (t.level.len > 0) t.level else "off";
            const msg = std.fmt.bufPrint(&buf, "Thinking: {s}", .{level}) catch "thinking level updated";
            self.status_line.setPrimary(msg, self.theme.fg(.success));
            self.tui.dirty = true;
        },
        .thinking_level_change_failed => |t| {
            self.status_line.setPrimary(t.message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
        },
    }
}
