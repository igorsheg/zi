const std = @import("std");
const protocol = @import("protocol.zig");
const generated = @import("models_generated.zig");

pub fn getModel(provider: protocol.Provider, model_id: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.meta.eql(m.provider, provider) and std.mem.eql(u8, m.id, model_id)) {
            return m;
        }
    }
    return null;
}

pub fn getModelById(model_id: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            return m;
        }
    }
    return null;
}

pub fn findModel(pattern: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.mem.indexOf(u8, m.id, pattern) != null) {
            return m;
        }
    }
    return null;
}

pub fn getAllModels() []const protocol.Model {
    return &generated.models;
}

pub fn defaultBaseUrlForProvider(provider: protocol.Provider) ?[]const u8 {
    for (generated.models) |model| {
        if (std.meta.eql(model.provider, provider) and model.base_url.len > 0) return model.base_url;
    }
    return null;
}

pub fn calculateCost(model: protocol.Model, usage: *protocol.Usage) protocol.Usage.Cost {
    usage.cost.input = (model.cost.input / 1_000_000.0) * @as(f64, @floatFromInt(usage.input));
    usage.cost.output = (model.cost.output / 1_000_000.0) * @as(f64, @floatFromInt(usage.output));
    usage.cost.cache_read = (model.cost.cache_read / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_read));
    usage.cost.cache_write = (model.cost.cache_write / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_write));
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
    return usage.cost;
}

pub fn supportsXhigh(model: protocol.Model) bool {
    if (std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null) return true;
    if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null) return true;
    return false;
}

pub fn clampReasoning(level: ?protocol.ThinkingLevel, model: protocol.Model) ?protocol.ThinkingLevel {
    const l = level orelse return null;
    if (l == .xhigh and !supportsXhigh(model)) return .high;
    return l;
}

pub fn modelsAreEqual(a: ?protocol.Model, b: ?protocol.Model) bool {
    const ma = a orelse return false;
    const mb = b orelse return false;
    return std.mem.eql(u8, ma.id, mb.id) and std.meta.eql(ma.provider, mb.provider);
}

pub const model_count = generated.models.len;

test "find anthropic sonnet by id" {
    const m = getModelById("claude-sonnet-4-20250514") orelse
        getModelById("claude-sonnet-4-5") orelse
        findModel("sonnet");
    try std.testing.expect(m != null);
}

test "provider base url defaults come from generated model catalog" {
    try std.testing.expectEqualStrings("https://openrouter.ai/api/v1", defaultBaseUrlForProvider(.openrouter).?);
    try std.testing.expectEqualStrings("https://api.anthropic.com", defaultBaseUrlForProvider(.anthropic).?);
    try std.testing.expect(defaultBaseUrlForProvider(.{ .custom = "unknown" }) == null);
}
