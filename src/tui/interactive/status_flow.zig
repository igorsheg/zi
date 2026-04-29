const std = @import("std");
const coding_agent_mod = @import("../../coding_agent/root.zig");

const Interactive = @import("../interactive.zig").Interactive;

pub fn showLoader(self: *Interactive, message: []const u8) void {
    self.built_in_working_message = message;
    refreshBuiltInStatus(self);
}

pub fn showCompactionLoader(self: *Interactive, reason: coding_agent_mod.session_event.CompactionReason) void {
    self.compaction_loader_active = true;
    self.compaction_loader_reason = reason;
    refreshBuiltInStatus(self);
}

pub fn finishCompactionLoader(self: *Interactive) void {
    if (!self.compaction_loader_active) return;
    self.compaction_loader_active = false;
    refreshBuiltInStatus(self);
}

pub fn hideLoader(self: *Interactive) void {
    refreshBuiltInStatus(self);
}

pub fn refreshBuiltInStatus(self: *Interactive) void {
    if (self.compaction_loader_active) {
        const message = switch (self.compaction_loader_reason) {
            .manual => "Compacting session…",
            .threshold => "Auto-compacting…",
            .overflow => "Context overflow detected, auto-compacting…",
        };
        self.status_line.setWorking(message);
        self.loader_active = true;
    } else if (self.retry_waiting) {
        var buf: [128]u8 = undefined;
        const delay_seconds = @divTrunc(self.retry_delay_ms + 500, 1000);
        const message = std.fmt.bufPrint(
            &buf,
            "Retrying ({d}/{d}) in {d}s… (Esc to cancel)",
            .{ self.retry_attempt, self.retry_max_attempts, delay_seconds },
        ) catch "Retrying…";
        self.status_line.setWorking(message);
        self.loader_active = true;
    } else if (self.is_streaming or self.request_in_flight) {
        self.status_line.setWorking(self.built_in_working_message);
        self.loader_active = true;
    } else if (self.loader_active) {
        self.status_line.clearWorking();
        self.loader_active = false;
    }
    self.tui.dirty = true;
}
