const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent2/root.zig");
const settings_mod = @import("../settings/root.zig");

pub const TEXT_ONLY: []const ai.protocol.Model.InputType = &.{.text};
pub const TEXT_IMAGE: []const ai.protocol.Model.InputType = &.{ .text, .image };

pub fn aiToAgentThinking(level: ai.protocol.ThinkingLevel) agent.protocol.ThinkingLevel {
    return switch (level) {
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

pub fn defaultThinkingLevel(settings: *const settings_mod.manager.SettingsManager) ?ai.protocol.ThinkingLevel {
    const lvl = settings.getDefaultThinkingLevel() orelse return null;
    return switch (lvl) {
        .off => null,
        .minimal => .minimal,
        .low => .low,
        .medium => .medium,
        .high => .high,
        .xhigh => .xhigh,
    };
}

pub fn parseToolAllowlist(
    allocator: std.mem.Allocator,
    tools_filter: ?[]const u8,
) !?[]const []const u8 {
    const filter_str = tools_filter orelse return null;
    var list: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer list.deinit(allocator);

    var it = std.mem.splitScalar(u8, filter_str, ',');
    while (it.next()) |name| {
        const trimmed = std.mem.trim(u8, name, &std.ascii.whitespace);
        if (trimmed.len == 0) continue;
        try list.append(allocator, trimmed);
    }
    return list.items;
}

/// Convert settings CustomModel entries to protocol.Model for ModelRegistry.
/// Validation (known api, no provider shadowing, non-empty fields, unique ids)
/// is handled by ModelRegistry.init — this is a thin format adapter.
pub fn convertCustomModels(
    allocator: std.mem.Allocator,
    customs: ?[]const settings_mod.types.CustomModel,
) ![]const ai.protocol.Model {
    const items = customs orelse return &.{};
    if (items.len == 0) return &.{};

    var result = try allocator.alloc(ai.protocol.Model, items.len);
    for (items, 0..) |cm, i| {
        result[i] = .{
            .id = cm.id,
            .name = cm.name,
            .api = ai.json_util.parseApi(cm.api),
            .provider = ai.json_util.parseProvider(cm.provider),
            .base_url = cm.base_url,
            .reasoning = cm.reasoning,
            .input = if (cm.input_has_image) TEXT_IMAGE else TEXT_ONLY,
            .cost = .{
                .input = cm.cost_input,
                .output = cm.cost_output,
                .cache_read = cm.cost_cache_read,
                .cache_write = cm.cost_cache_write,
            },
            .context_window = cm.context_window,
            .max_tokens = cm.max_tokens,
        };
    }

    return result;
}
