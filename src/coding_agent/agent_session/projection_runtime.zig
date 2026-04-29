const std = @import("std");
const ai = @import("../../ai/root.zig");
const session_bootstrap = @import("../session_bootstrap.zig");
const model_control = @import("model_control.zig");
const AgentSession = @import("../agent_session.zig").AgentSession;

pub fn rebuildVisibleModelCatalogFromActiveProviders(self: anytype) !void {
    const registry = self.model_registry orelse return;
    const current = self.agent.modelValue();
    const provider_name = try self.allocator.dupe(u8, ai.json_util.providerToString(current.provider));
    defer self.allocator.free(provider_name);
    const model_id = try self.allocator.dupe(u8, current.id);
    defer self.allocator.free(model_id);
    const thinking_level = self.agent.thinkingLevel();

    try registry.rebuildFromActiveProviderClaims(self._stream_closure.registry);
    if (registry.findByProviderName(provider_name, model_id)) |refreshed| {
        self.agent.setModel(refreshed);
        self.agent.setThinkingLevel(model_control.clampThinkingLevelForModel(thinking_level, refreshed));
    }
    self.emitSessionEvent(.{ .visible_models_changed = {} });
}

pub fn providerProjectionChanged(session_ptr: *anyopaque) void {
    const self = session(session_ptr);
    rebuildVisibleModelCatalogFromActiveProviders(self) catch |err| {
        std.log.scoped(.coding_agent).warn("failed to rebuild visible model catalog: {s}", .{@errorName(err)});
    };
}

pub fn toolProjectionChanged(session_ptr: *anyopaque) void {
    const self = session(session_ptr);
    if (self.agent.isStreaming() or self.agent.hasQueuedMessages()) {
        self.pending_tool_projection_refresh = true;
        return;
    }
    rebuildVisibleToolsAndPromptFromRunner(self) catch |err| {
        self.pending_tool_projection_refresh = true;
        std.log.scoped(.coding_agent).warn("failed to rebuild visible tool projection: {s}", .{@errorName(err)});
    };
}

pub fn flushPendingToolProjectionRefresh(self: anytype) void {
    if (!self.pending_tool_projection_refresh) return;
    if (self.agent.isStreaming() or self.agent.hasQueuedMessages()) return;
    rebuildVisibleToolsAndPromptFromRunner(self) catch |err| {
        std.log.scoped(.coding_agent).warn("failed to refresh visible tool projection: {s}", .{@errorName(err)});
        return;
    };
    self.pending_tool_projection_refresh = false;
}

fn rebuildVisibleToolsAndPromptFromRunner(self: anytype) !void {
    const runner = self._extension_runner orelse return;
    const definitions = runner.tool_registry.items();
    const tools = try session_bootstrap.buildAgentTools(self.allocator, definitions, runner);
    errdefer self.allocator.free(tools);
    const system_prompt = try session_bootstrap.buildSystemPrompt(self.allocator, self.resource_loader, definitions);
    errdefer self.allocator.free(system_prompt);

    const old_tools = self.tools;
    const old_system_prompt = self._owned_system_prompt;
    self.tools = tools;
    self._owned_system_prompt = system_prompt;
    self.agent.replaceRuntimeInputs(system_prompt, tools);
    if (old_tools.len > 0) self.allocator.free(old_tools);
    if (old_system_prompt.len > 0) self.allocator.free(old_system_prompt);
}

fn session(session_ptr: *anyopaque) *AgentSession {
    return @ptrCast(@alignCast(session_ptr));
}
