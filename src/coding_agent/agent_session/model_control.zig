const ai = @import("../../ai/root.zig");
const agent_mod = @import("../../agent/root.zig");
const settings_manager_mod = @import("../settings/manager.zig");
const settings_types_mod = @import("../settings/types.zig");
const event_bridge = @import("../extensions/event_bridge.zig");

const protocol = agent_mod.protocol;

pub const ModelSwitchResult = union(enum) {
    success: struct {
        model: ai.protocol.Model,
        thinking_level: protocol.ThinkingLevel,
        thinking_level_changed: bool,
    },
    no_auth: ai.protocol.Model,
    registry_unavailable: void,
};

pub const ThinkingLevelChangeResult = struct {
    level: protocol.ThinkingLevel,
    changed: bool,
};

pub const StatusSnapshot = struct {
    model_provider: []const u8,
    model_id: []const u8,
    thinking_level: protocol.ThinkingLevel,
    context_tokens: ?u64,
    context_window: u64,
};

/// Canonical session-owned model switch. Owns validation,
/// in-memory state mutation, session persistence, and thinking-
/// level reclamp for the new model's capabilities.
pub fn trySetModel(self: anytype, model: ai.protocol.Model) ModelSwitchResult {
    const registry = self.model_registry orelse return .registry_unavailable;
    if (!registry.hasConfiguredAuth(model)) {
        return .{ .no_auth = model };
    }

    const previous_model = self.agent.modelValue();
    const previous_thinking = self.agent.thinkingLevel();
    const next_thinking = clampThinkingLevelForModel(previous_thinking, model);
    const thinking_changed = next_thinking != previous_thinking;

    self.agent.setModel(model);
    self.agent.setThinkingLevel(next_thinking);
    const provider_str = ai.json_util.providerToString(model.provider);
    self.session_store.appendModelChange(provider_str, model.id);
    if (self.settings_manager) |settings| {
        settings.setDefaultModelAndProvider(provider_str, model.id);
        persistDefaultThinkingLevel(settings, model, next_thinking);
    }
    if (thinking_changed) {
        self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(next_thinking));
    }

    if (self._extension_runner) |runner| {
        if (!ai.models.modelsAreEqual(previous_model, model)) {
            event_bridge.dispatchModelSelect(runner, model, previous_model, "set");
        }
    }

    return .{ .success = .{
        .model = model,
        .thinking_level = next_thinking,
        .thinking_level_changed = thinking_changed,
    } };
}

pub fn trySetThinkingLevel(self: anytype, level: protocol.ThinkingLevel) ThinkingLevelChangeResult {
    const effective = clampThinkingLevelForModel(level, self.agent.modelValue());
    const changed = effective != self.agent.thinkingLevel();
    self.agent.setThinkingLevel(effective);
    if (changed) {
        self.session_store.appendThinkingLevelChange(agentThinkingLevelToString(effective));
        if (self.settings_manager) |settings| {
            persistDefaultThinkingLevel(settings, self.agent.modelValue(), effective);
        }
    }
    return .{ .level = effective, .changed = changed };
}

pub fn availableThinkingLevelsForModel(model: ai.protocol.Model) []const protocol.ThinkingLevel {
    return if (!model.reasoning)
        &.{.off}
    else if (ai.models.supportsXhigh(model))
        &.{ .off, .minimal, .low, .medium, .high, .xhigh }
    else
        &.{ .off, .minimal, .low, .medium, .high };
}

pub fn clampThinkingLevelForModel(level: protocol.ThinkingLevel, model: ai.protocol.Model) protocol.ThinkingLevel {
    if (!model.reasoning) return .off;
    return switch (level) {
        .xhigh => if (ai.models.supportsXhigh(model)) .xhigh else .high,
        else => level,
    };
}

pub fn agentThinkingLevelToString(level: protocol.ThinkingLevel) []const u8 {
    return switch (level) {
        .off => "off",
        .minimal => "minimal",
        .low => "low",
        .medium => "medium",
        .high => "high",
        .xhigh => "xhigh",
    };
}

fn agentThinkingLevelToDefault(level: protocol.ThinkingLevel) settings_types_mod.DefaultThinkingLevel {
    return switch (level) {
        .off => .off,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

fn persistDefaultThinkingLevel(
    settings: *settings_manager_mod.SettingsManager,
    model: ai.protocol.Model,
    level: protocol.ThinkingLevel,
) void {
    if (model.reasoning or level != .off) {
        settings.setDefaultThinkingLevel(agentThinkingLevelToDefault(level));
    }
}
