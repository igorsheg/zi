const coding_agent_mod = @import("../../coding_agent/root.zig");
const thinking_mod = @import("thinking.zig");
const json_util = @import("../../ai/json_util.zig");
const ai_protocol = @import("../../ai/protocol.zig");

pub fn showSettings(self: anytype, on_select: anytype, on_cancel: anytype) void {
    var count: usize = 0;

    self.settings_picker_items[count] = .{
        .value = "thinking",
        .label = "Thinking level",
        .description = currentThinkingSettingsDescription(self),
    };
    self.settings_picker_actions[count] = .open_thinking;
    count += 1;

    self.settings_picker_items[count] = .{
        .value = "hide-thinking",
        .label = "Hide thinking",
        .description = if (self.hide_thinking_block) "On" else "Off",
    };
    self.settings_picker_actions[count] = .toggle_hide_thinking;
    count += 1;

    self.settings_picker_count = count;
    self.configureSimplePicker(
        &self.settings_picker,
        "Settings",
        10,
        self.settings_picker_items[0..count],
        on_select,
        on_cancel,
    );
    self.showSimplePickerOverlay(&self.settings_picker);
}

pub fn settingsSelected(self: anytype, selection: anytype, on_thinking_select: anytype, on_thinking_cancel: anytype) void {
    self.hideSimplePickerOverlay(&self.settings_picker);
    if (selection.source_index >= self.settings_picker_count) return;

    switch (self.settings_picker_actions[selection.source_index]) {
        .open_thinking => showThinkingLevel(self, on_thinking_select, on_thinking_cancel),
        .toggle_hide_thinking => {
            self.hide_thinking_block = !self.hide_thinking_block;
            self.settings_manager.setHideThinkingBlock(self.hide_thinking_block);
            self.applyTranscriptHideThinkingBlock();
            self.status_line.setPrimary(if (self.hide_thinking_block) "thinking hidden" else "thinking shown", self.theme.fg(.success));
            self.tui.dirty = true;
        },
    }
}

pub fn showThinkingLevel(self: anytype, on_select: anytype, on_cancel: anytype) void {
    const model = currentStatusModel(self) orelse {
        self.status_line.setPrimary("current model unavailable", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    const available = coding_agent_mod.AgentSession.getAvailableThinkingLevelsForModel(model);
    const count = @min(available.len, self.thinking_picker_items.len);
    for (0..count) |i| {
        const level = available[i];
        self.thinking_picker_levels[i] = level;
        self.thinking_picker_items[i] = .{
            .value = thinking_mod.value(level),
            .label = thinking_mod.value(level),
            .description = thinking_mod.description(level),
        };
    }
    self.thinking_picker_count = count;
    self.configureSimplePicker(
        &self.thinking_picker,
        "Thinking level",
        8,
        self.thinking_picker_items[0..count],
        on_select,
        on_cancel,
    );
    self.thinking_picker.picker.setInitialSelectionByValue(if (self.status_data.thinking_level.len > 0) self.status_data.thinking_level else "off");
    self.showSimplePickerOverlay(&self.thinking_picker);
}

pub fn thinkingLevelSelected(self: anytype, selection: anytype) void {
    self.hideSimplePickerOverlay(&self.thinking_picker);
    if (selection.source_index < self.thinking_picker_count) {
        self.applyThinkingLevelChange(self.thinking_picker_levels[selection.source_index]);
    }
}

fn currentThinkingSettingsDescription(self: anytype) []const u8 {
    const model = currentStatusModel(self) orelse return "Current model unavailable";
    if (!model.reasoning) return "Current model does not support thinking";
    return if (self.status_data.thinking_level.len > 0) self.status_data.thinking_level else "off";
}

fn currentStatusModel(self: anytype) ?ai_protocol.Model {
    const provider_name = self.status_data.model_provider;
    const model_id = self.status_data.model_id;
    for (self.model_catalog) |model| {
        if (!std.mem.eql(u8, json_util.providerToString(model.provider), provider_name)) continue;
        if (!std.mem.eql(u8, model.id, model_id)) continue;
        return model;
    }
    return null;
}
const std = @import("std");
