const std = @import("std");
const protocol = @import("protocol.zig");
const generated = @import("models_generated.zig");

/// Get a model by provider and model ID.
pub fn getModel(provider: protocol.Provider, model_id: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.meta.eql(m.provider, provider) and std.mem.eql(u8, m.id, model_id)) {
            return m;
        }
    }
    return null;
}

/// Get a model by ID string alone (searches all providers).
pub fn getModelById(model_id: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.mem.eql(u8, m.id, model_id)) {
            return m;
        }
    }
    return null;
}

/// Get a model by partial ID match (first match wins).
pub fn findModel(pattern: []const u8) ?protocol.Model {
    for (generated.models) |m| {
        if (std.mem.indexOf(u8, m.id, pattern) != null) {
            return m;
        }
    }
    return null;
}

/// Get all models for a provider.
/// Get all models in the catalog.
pub fn getAllModels() []const protocol.Model {
    return &generated.models;
}

/// Calculate cost for a model given usage.
pub fn calculateCost(model: protocol.Model, usage: *protocol.Usage) protocol.Usage.Cost {
    usage.cost.input = (model.cost.input / 1_000_000.0) * @as(f64, @floatFromInt(usage.input));
    usage.cost.output = (model.cost.output / 1_000_000.0) * @as(f64, @floatFromInt(usage.output));
    usage.cost.cache_read = (model.cost.cache_read / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_read));
    usage.cost.cache_write = (model.cost.cache_write / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_write));
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
    return usage.cost;
}

/// Check if a model supports xhigh thinking level.
pub fn supportsXhigh(model: protocol.Model) bool {
    if (std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null) return true;
    if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null) return true;
    return false;
}

/// Clamp xhigh → high for models that don't support it.
pub fn clampReasoning(level: ?protocol.ThinkingLevel, model: protocol.Model) ?protocol.ThinkingLevel {
    const l = level orelse return null;
    if (l == .xhigh and !supportsXhigh(model)) return .high;
    return l;
}

/// Check if two models are equal by id and provider.
pub fn modelsAreEqual(a: ?protocol.Model, b: ?protocol.Model) bool {
    const ma = a orelse return false;
    const mb = b orelse return false;
    return std.mem.eql(u8, ma.id, mb.id) and std.meta.eql(ma.provider, mb.provider);
}

/// Total number of models in the catalog.
pub const model_count = generated.models.len;

test "find anthropic sonnet by id" {
    const m = getModelById("claude-sonnet-4-20250514") orelse
        getModelById("claude-sonnet-4-5") orelse
        findModel("sonnet");
    try std.testing.expect(m != null);
}
