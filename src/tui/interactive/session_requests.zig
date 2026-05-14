const std = @import("std");

const log = std.log.scoped(.zi_interactive);

fn refreshToolDisplayResolver(self: anytype) void {
    self.resolver.ctx = @ptrCast(self.runtime_host.currentSession());
}

pub fn handleNewSession(self: anytype) void {
    self.runtime_host.newSession() catch |err| {
        const msg = switch (err) {
            error.SessionBeforeSwitchBlocked => self.msg_allocator.dupe(u8, "session switch blocked by extension") catch return,
            else => std.fmt.allocPrint(self.msg_allocator, "failed to start new session: {s}", .{@errorName(err)}) catch return,
        };
        _ = self.publishLifecycleUiEvent(.{ .session_new_failed = .{ .message = msg } });
        return;
    };
    refreshToolDisplayResolver(self);
    self.publishExtensionCommandsUpdate();
    self.publishThemeSnapshot();
    self.publishVisibleModelsSnapshot();
    self.publishStatusSnapshot();
    if (!self.publishConversationState()) {
        log.warn("snapshot queue dropped new-session conversation state", .{});
    }
    self.publishQueuedSnapshotIfChanged();
    _ = self.publishLifecycleUiEvent(.{ .session_new_started = {} });
}

pub fn handleForkSession(self: anytype, entry_id: []const u8) void {
    self.runtime_host.forkSession(entry_id) catch |err| {
        const msg = switch (err) {
            error.SessionBeforeForkBlocked => self.msg_allocator.dupe(u8, "session fork blocked by extension") catch return,
            else => std.fmt.allocPrint(self.msg_allocator, "failed to fork session: {s}", .{@errorName(err)}) catch return,
        };
        _ = self.publishLifecycleUiEvent(.{ .session_new_failed = .{ .message = msg } });
        return;
    };
    refreshToolDisplayResolver(self);
    self.publishExtensionCommandsUpdate();
    self.publishThemeSnapshot();
    self.publishVisibleModelsSnapshot();
    self.publishStatusSnapshot();
    if (!self.publishConversationState()) {
        log.warn("snapshot queue dropped forked conversation state", .{});
    }
    self.publishQueuedSnapshotIfChanged();
    _ = self.publishLifecycleUiEvent(.{ .session_fork_started = {} });
}

pub fn handleResumeSession(self: anytype, path: []const u8, restore_session_model: bool) void {
    const result = self.runtime_host.resumeSession(path, restore_session_model) catch |err| {
        const message = switch (err) {
            error.SessionAlreadyActive => "session is already active",
            error.SessionBeforeSwitchBlocked => "session switch blocked by extension",
            else => "failed to load session",
        };
        const msg = self.msg_allocator.dupe(u8, message) catch return;
        _ = self.publishLifecycleUiEvent(.{ .session_resume_failed = .{ .message = msg } });
        return;
    };

    const restore_warning = result.restore_warning;
    refreshToolDisplayResolver(self);

    self.publishExtensionCommandsUpdate();
    self.publishThemeSnapshot();
    self.publishVisibleModelsSnapshot();
    self.publishStatusSnapshot();
    if (!self.publishConversationState()) {
        log.warn("snapshot queue dropped resumed conversation state", .{});
    }
    self.publishQueuedSnapshotIfChanged();
    _ = self.publishLifecycleUiEvent(.{ .session_resumed = .{
        .restore_warning = restore_warning,
    } });
}
