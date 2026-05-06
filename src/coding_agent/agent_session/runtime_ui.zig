const extension_ui = @import("../extensions/ui.zig");
const request_mod = @import("../request.zig");
const AgentSession = @import("../agent_session.zig").AgentSession;

pub fn publishRender(session_ptr: *anyopaque, spec: extension_ui.RenderSpec) !void {
    _ = session_ptr;
    _ = spec;
}

pub fn publishFrame(session_ptr: *anyopaque, spec: extension_ui.FrameSpec) !void {
    _ = session_ptr;
    _ = spec;
}

pub fn publishReport(session_ptr: *anyopaque, report: extension_ui.Report) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishReport(report);
}

pub fn publishPrompt(session_ptr: *anyopaque, prompt: extension_ui.PromptRequest) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishPrompt(prompt);
}

pub fn resolvePrompt(session_ptr: *anyopaque, prompt: extension_ui.PromptRequest, response: *request_mod.ExtensionPromptResponse) void {
    const self = session(session_ptr);
    self.emitSessionEvent(.{ .extension_prompt_request = .{ .prompt = prompt, .response = response } });
}

pub fn cancelPrompts(session_ptr: *anyopaque) void {
    const self = session(session_ptr);
    self.pending_extension_ui.clearPrompts();
}

pub fn publishUi(session_ptr: *anyopaque, update: extension_ui.UiPublication) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishUi(update);
}

pub fn revokeUi(session_ptr: *anyopaque) void {
    const self = session(session_ptr);
    self.pending_extension_ui.clearUiPublications();
}

pub fn publishSurfaceUpdate(session_ptr: *anyopaque, update: extension_ui.SurfaceUpdate) !void {
    const self = session(session_ptr);
    try self.pending_extension_ui.publishSurfaceUpdate(update);
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
