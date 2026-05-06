const extension_ui = @import("../extensions/ui.zig");
const request_mod = @import("../request.zig");
const AgentSession = @import("../agent_session.zig").AgentSession;

pub fn publishRender(session_ptr: *anyopaque, spec: extension_ui.RenderSpec) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishRender(spec);
}

pub fn publishFrame(session_ptr: *anyopaque, spec: extension_ui.FrameSpec) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishFrame(spec);
}

pub fn publishEditorAction(session_ptr: *anyopaque, action: extension_ui.EditorAction) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishEditorAction(action);
}

pub fn clearEditorActions(session_ptr: *anyopaque) void {
    const self = session(session_ptr);
    self.pending_extension_ui.clearEditorActions();
}

fn session(session_ptr: *anyopaque) *AgentSession {
    return @ptrCast(@alignCast(session_ptr));
}
