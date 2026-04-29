const Interactive = @import("../interactive.zig").Interactive;

pub fn performStartupAction(self: *Interactive) void {
    switch (self.startup_action) {
        .none => {},
        .prompt => |content| {
            _ = self.submitUserContent(content);
        },
        .resume_session => |session_resume| {
            const path_copy = self.msg_allocator.dupe(u8, session_resume.path) catch {
                self.status_line.setPrimary("out of memory", self.theme.fg(.@"error"));
                self.tui.dirty = true;
                self.startup_action = .none;
                return;
            };
            _ = self.dispatchIdleRequest(.{ .resume_session = .{
                .path = path_copy,
                .restore_session_model = session_resume.restore_session_model,
            } }, .{
                .busy_message = "cannot resume while agent is running",
                .loader_message = "Loading session...",
                .spawn_failed_message = "failed to queue resume",
            });
        },
        .resume_picker => |picker| self.showSessionPicker(picker.restore_session_model),
    }
    self.startup_action = .none;
}

pub fn bootstrapStatusSnapshot(self: *Interactive) void {
    switch (self.request_queue.trySend(.{ .refresh_status_snapshot = {} })) {
        .ok => {},
        .dropped => unreachable,
        .full => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
            self.showAgentRequestQueueFull();
        },
        .closed, .oom => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
        },
    }
}
