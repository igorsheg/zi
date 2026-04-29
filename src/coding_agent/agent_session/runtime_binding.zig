const std = @import("std");
const ai = @import("../../ai/root.zig");
const protocol = @import("../../agent3/types.zig");
const extension_runner_mod = @import("../extensions/runner.zig");
const runtime_models = @import("runtime_models.zig");
const runtime_state = @import("runtime_state.zig");
const runtime_session = @import("runtime_session.zig");
const runtime_ui = @import("runtime_ui.zig");
const projection_runtime = @import("projection_runtime.zig");
const event_bridge = @import("../extensions/event_bridge.zig");
const AgentSession = @import("../agent_session.zig").AgentSession;

const ContextUsage = @import("../../session/root.zig").context_usage.ContextUsage;
const ExtensionRunner = extension_runner_mod.ExtensionRunner;
const ExtensionRunnerRef = extension_runner_mod.ExtensionRunnerRef;

pub const agentEventSink = agentEventSinkFromRunnerRef;
pub const beforeToolCall = beforeToolCallFromRunnerRef;
pub const afterToolCall = afterToolCallFromRunnerRef;

pub fn bind(self: *AgentSession, runner: *ExtensionRunner) void {
    if (runner.isBound()) return;

    runner.bindRuntime(.{
        .session = @ptrCast(self),
        .ui = null,
        .command_actions = null,
        .get_model = &runtimeGetModel,
        .models_get = &runtimeModelsGet,
        .models_get_one = &runtimeModelsGetOne,
        .is_idle = &runtimeIsIdle,
        .abort = &runtimeAbort,
        .has_pending_messages = &runtimeHasPendingMessages,
        .shutdown = null,
        .get_context_usage = &runtimeGetContextUsage,
        .get_system_prompt = &runtimeGetSystemPrompt,
        .get_binding_info = &runtimeGetBindingInfo,
        .session_state_get = &runtimeSessionStateGet,
        .session_state_set = &runtimeSessionStateSet,
        .session_state_delete = &runtimeSessionStateDelete,
        .session_info_get = &runtimeSessionInfoGet,
        .session_name_get = &runtimeSessionNameGet,
        .session_name_set = &runtimeSessionNameSet,
        .session_tool_results_get = &runtimeSessionToolResultsGet,
        .session_messages_get = &runtimeSessionMessagesGet,
        .session_note_append = &runtimeSessionNoteAppend,
        .session_notes_get = &runtimeSessionNotesGet,
        .session_label_set = &runtimeSessionLabelSet,
        .session_labels_get = &runtimeSessionLabelsGet,
        .session_entry_get = &runtimeSessionEntryGet,
        .session_entries_get = &runtimeSessionEntriesGet,
        .publish_report = &runtime_ui.publishReport,
        .publish_prompt = &runtime_ui.publishPrompt,
        .resolve_prompt = &runtime_ui.resolvePrompt,
        .cancel_prompts = &runtime_ui.cancelPrompts,
        .publish_ui = &runtime_ui.publishUi,
        .revoke_ui = &runtime_ui.revokeUi,
        .publish_editor_action = &runtime_ui.publishEditorAction,
        .clear_editor_actions = &runtime_ui.clearEditorActions,
        .provider_projection_changed = &projection_runtime.providerProjectionChanged,
        .tool_projection_changed = &projection_runtime.toolProjectionChanged,
    }, self._stream_closure.registry) catch {};
}

fn agentEventSinkFromRunnerRef(event: protocol.AgentEvent, ctx: ?*anyopaque) void {
    const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
    const runner = ref.current orelse return;
    event_bridge.agentEventSink(event, @ptrCast(runner));
}

fn beforeToolCallFromRunnerRef(
    ctx_arg: protocol.BeforeToolCallContext,
    signal: @import("../../abort_signal.zig").AbortSignal,
    ctx: ?*anyopaque,
) ?protocol.BeforeToolCallResult {
    const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
    const runner = ref.current orelse return null;
    return event_bridge.beforeToolCall(ctx_arg, signal, @ptrCast(runner));
}

fn afterToolCallFromRunnerRef(
    ctx_arg: protocol.AfterToolCallContext,
    signal: @import("../../abort_signal.zig").AbortSignal,
    ctx: ?*anyopaque,
) ?protocol.AfterToolCallResult {
    const ref: *ExtensionRunnerRef = @ptrCast(@alignCast(ctx.?));
    const runner = ref.current orelse return null;
    return event_bridge.afterToolCall(ctx_arg, signal, @ptrCast(runner));
}

fn runtimeGetModel(session_ptr: *anyopaque) protocol.Model {
    return session(session_ptr).agent.modelValue();
}

fn runtimeModelsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
    return runtime_models.modelsGet(session(session_ptr), allocator);
}

fn runtimeModelsGetOne(session_ptr: *anyopaque, allocator: std.mem.Allocator, model_ref: []const u8) ?std.json.Value {
    return runtime_models.modelGet(session(session_ptr), allocator, model_ref);
}

fn runtimeIsIdle(session_ptr: *anyopaque) bool {
    return !session(session_ptr).agent.isStreaming();
}

fn runtimeAbort(session_ptr: *anyopaque) void {
    session(session_ptr).agent.abort();
}

fn runtimeHasPendingMessages(session_ptr: *anyopaque) bool {
    return session(session_ptr).agent.hasQueuedMessages();
}

fn runtimeGetContextUsage(session_ptr: *anyopaque) ?ContextUsage {
    return session(session_ptr).getContextUsage();
}

fn runtimeGetSystemPrompt(session_ptr: *anyopaque) []const u8 {
    return session(session_ptr).agent.systemPrompt();
}

fn runtimeGetBindingInfo(session_ptr: *anyopaque) extension_runner_mod.ExtensionBindingInfo {
    const self = session(session_ptr);
    const session_file = self.getSessionFile();
    return .{
        .workspace_id = self.resource_loader.cwd,
        .session_id = self.session_store.sessionId(),
        .session_file = if (session_file.len == 0) null else session_file,
    };
}

fn runtimeSessionStateGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, state_owner_id: []const u8, key: []const u8) ?std.json.Value {
    return runtime_state.get(session(session_ptr), allocator, state_owner_id, key);
}

fn runtimeSessionStateSet(session_ptr: *anyopaque, state_owner_id: []const u8, key: []const u8, value: std.json.Value) !void {
    try runtime_state.set(session(session_ptr), state_owner_id, key, value);
}

fn runtimeSessionStateDelete(session_ptr: *anyopaque, state_owner_id: []const u8, key: []const u8) !void {
    try runtime_state.delete(session(session_ptr), state_owner_id, key);
}

fn runtimeSessionInfoGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?std.json.Value {
    return runtime_session.infoGet(session(session_ptr), allocator);
}

fn runtimeSessionNameGet(session_ptr: *anyopaque, allocator: std.mem.Allocator) ?[]const u8 {
    return runtime_session.latestName(session(session_ptr), allocator);
}

fn runtimeSessionNameSet(session_ptr: *anyopaque, name: ?[]const u8) !void {
    session(session_ptr).session_store.appendSessionInfo(name);
}

fn runtimeSessionToolResultsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, tool_name: []const u8) ?std.json.Value {
    return runtime_session.toolResultsGet(session(session_ptr), allocator, tool_name);
}

fn runtimeSessionMessagesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value {
    return runtime_session.messagesGet(session(session_ptr), allocator, limit, include_tools);
}

fn runtimeSessionNoteAppend(session_ptr: *anyopaque, kind: []const u8, title: ?[]const u8, body: []const u8, source_entry_id: ?[]const u8) !void {
    try runtime_session.noteAppend(session(session_ptr), kind, title, body, source_entry_id);
}

fn runtimeSessionNotesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, kind: ?[]const u8, source_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
    return runtime_session.notesGet(session(session_ptr), allocator, kind, source_entry_id, limit);
}

fn runtimeSessionLabelSet(session_ptr: *anyopaque, target_entry_id: []const u8, label: ?[]const u8) !void {
    runtime_session.labelSet(session(session_ptr), target_entry_id, label);
}

fn runtimeSessionLabelsGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, target_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
    return runtime_session.labelsGet(session(session_ptr), allocator, target_entry_id, limit);
}

fn runtimeSessionEntryGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, entry_id: []const u8) ?std.json.Value {
    return runtime_session.entryGet(session(session_ptr), allocator, entry_id);
}

fn runtimeSessionEntriesGet(session_ptr: *anyopaque, allocator: std.mem.Allocator, label: ?[]const u8, limit: usize) ?std.json.Value {
    return runtime_session.entriesGet(session(session_ptr), allocator, label, limit);
}

fn session(session_ptr: *anyopaque) *AgentSession {
    return @ptrCast(@alignCast(session_ptr));
}
