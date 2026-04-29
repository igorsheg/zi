const coding_agent_mod = @import("../../coding_agent/root.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");
const request_mod = @import("../../coding_agent/request.zig");

pub fn handle(self: anytype, event: anytype) void {
    switch (event) {
        .auto_retry_start => |retry| {
            const err_msg = self.msg_allocator.dupe(u8, retry.error_message) catch return;
            _ = self.publishLifecycleUiEvent(.{ .retry_start = .{
                .attempt = retry.attempt,
                .max_attempts = retry.max_attempts,
                .delay_ms = retry.delay_ms,
                .error_message = err_msg,
            } });
        },
        .auto_retry_wait_finished => {
            _ = self.publishLifecycleUiEvent(.retry_wait_finished);
        },
        .auto_retry_end => |retry| {
            const final_error = if (retry.final_error) |msg|
                (self.msg_allocator.dupe(u8, msg) catch null)
            else
                null;
            _ = self.publishLifecycleUiEvent(.{ .retry_end = .{
                .success = retry.success,
                .attempt = retry.attempt,
                .final_error = final_error,
                .failure_kind = retry.failure_kind,
            } });
        },
        .compaction_start => |compaction| {
            _ = self.publishLifecycleUiEvent(.{ .compaction_start = .{ .reason = compaction.reason } });
            self.publishStatusSnapshot();
        },
        .compaction_end => |compaction| {
            _ = self.publishLifecycleUiEvent(.{ .compaction_end = {} });
            publishManualCompactionLifecycle(self, compaction);
            self.publishStatusSnapshot();
            _ = self.publishConversationState();
        },
        .visible_models_changed => {
            self.publishVisibleModelsSnapshot();
            self.publishStatusSnapshot();
        },
        .extension_prompt_request => |request| {
            const prompt = extension_ui.PromptRequest.clone(self.msg_allocator, request.prompt) catch {
                request.response.finish(request_mod.ExtensionPromptResponse.defaultFor(request.prompt.kind));
                return;
            };
            _ = self.publishLifecycleUiEvent(.{ .extension_prompt_requested = .{ .prompt = prompt, .response = request.response } });
        },
    }
}

pub fn publishManualCompactionLifecycle(self: anytype, compaction: coding_agent_mod.session_event.CompactionEnd) void {
    if (compaction.reason != .manual) return;

    if (compaction.success) {
        _ = self.publishLifecycleUiEvent(.{ .session_compacted = {} });
        return;
    }

    const msg = if (compaction.aborted)
        self.msg_allocator.dupe(u8, "compaction cancelled") catch return
    else if (compaction.error_message) |err|
        self.msg_allocator.dupe(u8, err) catch return
    else
        self.msg_allocator.dupe(u8, "compaction failed") catch return;
    _ = self.publishLifecycleUiEvent(.{ .session_compaction_failed = .{ .message = msg } });
}
