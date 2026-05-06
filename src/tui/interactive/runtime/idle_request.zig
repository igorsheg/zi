const coding_agent_mod = @import("../../../coding_agent/root.zig");

const Interactive = @import("../../interactive.zig").Interactive;
const AgentRequest = coding_agent_mod.AgentRequest;

pub const Options = struct {
    busy_message: []const u8,
    loader_message: []const u8,
    spawn_failed_message: []const u8,
};

pub fn dispatch(self: *Interactive, req: AgentRequest, options: Options) bool {
    if (self.is_streaming or self.request_in_flight) {
        var rejected = req;
        rejected.deinit(self.msg_allocator);
        self.status_line.setPrimary(options.busy_message, self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return false;
    }

    switch (self.request_queue.trySend(req)) {
        .ok => {},
        .dropped => unreachable,
        .full => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
            self.showAgentRequestQueueFull();
            return false;
        },
        .closed, .oom => |rejected| {
            var failed_req = rejected;
            failed_req.deinit(self.msg_allocator);
            self.status_line.setPrimary(options.spawn_failed_message, self.theme.fg(.@"error"));
            self.tui.dirty = true;
            return false;
        },
    }
    self.request_in_flight = true;
    self.showLoader(options.loader_message);
    self.tui.dirty = true;
    return true;
}
