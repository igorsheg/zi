const std = @import("std");
const types = @import("types.zig");

/// Model registry - maps (provider, model_id) to Model
pub const ModelRegistry = struct {
    allocator: std.mem.Allocator,
    // Map from provider -> (map from model_id -> Model)
    providers: std.AutoHashMap(types.Provider, std.StringHashMap(types.Model)),

    pub fn init(allocator: std.mem.Allocator) ModelRegistry {
        return .{
            .allocator = allocator,
            .providers = std.AutoHashMap(types.Provider, std.StringHashMap(types.Model)).init(allocator),
        };
    }

    pub fn deinit(self: *ModelRegistry) void {
        var provider_it = self.providers.iterator();
        while (provider_it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.providers.deinit();
    }

    /// Register a model in the registry
    pub fn register(self: *ModelRegistry, model: types.Model) !void {
        const gop = try self.providers.getOrPut(model.provider);
        if (!gop.found_existing) {
            gop.value_ptr.* = std.StringHashMap(types.Model).init(self.allocator);
        }
        try gop.value_ptr.put(model.id, model);
    }

    /// Get a model by provider and model ID
    pub fn getModel(self: *const ModelRegistry, provider: types.Provider, model_id: []const u8) ?types.Model {
        const provider_models = self.providers.get(provider) orelse return null;
        return provider_models.get(model_id);
    }

    /// Get all models for a provider. Caller owns the returned slice.
    pub fn getModels(self: *const ModelRegistry, allocator: std.mem.Allocator, provider: types.Provider) ![]types.Model {
        const provider_models = self.providers.get(provider) orelse return &[_]types.Model{};
        
        var models = try allocator.alloc(types.Model, provider_models.count());
        errdefer allocator.free(models);
        
        var it = provider_models.valueIterator();
        var i: usize = 0;
        while (it.next()) |model| {
            models[i] = model.*;
            i += 1;
        }
        return models;
    }

    /// Get all providers that have registered models. Caller owns the returned slice.
    pub fn getProviders(self: *const ModelRegistry, allocator: std.mem.Allocator) ![]types.Provider {
        var providers = try allocator.alloc(types.Provider, self.providers.count());
        errdefer allocator.free(providers);
        
        var it = self.providers.keyIterator();
        var i: usize = 0;
        while (it.next()) |provider| {
            providers[i] = provider.*;
            i += 1;
        }
        return providers;
    }
};

/// Calculate cost for a model given usage
pub fn calculateCost(model: types.Model, usage: *types.Usage) types.Usage.Cost {
    usage.cost.input = (model.cost.input / 1_000_000.0) * @as(f64, @floatFromInt(usage.input));
    usage.cost.output = (model.cost.output / 1_000_000.0) * @as(f64, @floatFromInt(usage.output));
    usage.cost.cache_read = (model.cost.cache_read / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_read));
    usage.cost.cache_write = (model.cost.cache_write / 1_000_000.0) * @as(f64, @floatFromInt(usage.cache_write));
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
    return usage.cost;
}

/// Check if a model supports xhigh thinking level
pub fn supportsXhigh(model: types.Model) bool {
    // Check for gpt-5.2, gpt-5.3, gpt-5.4, opus-4-6, opus-4.6 in model.id
    if (std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null) return true;
    if (std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null) return true;
    return false;
}

/// Check if two models are equal by comparing both their id and provider
pub fn modelsAreEqual(a: ?types.Model, b: ?types.Model) bool {
    const ma = a orelse return false;
    const mb = b orelse return false;
    return std.mem.eql(u8, ma.id, mb.id) and ma.provider == mb.provider;
}

test "calculateCost computes costs correctly" {
    const model = types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{
            .input = 2.0,  // $2 per million tokens
            .output = 4.0, // $4 per million tokens
            .cache_read = 0.5,
            .cache_write = 1.0,
        },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    var usage = types.Usage{
        .input = 1_000_000,
        .output = 500_000,
        .cache_read = 100_000,
        .cache_write = 50_000,
        .total_tokens = 1_650_000,
        .cost = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total = 0,
        },
    };

    const cost = calculateCost(model, &usage);

    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cost.input, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 2.0), cost.output, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), cost.cache_read, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 0.05), cost.cache_write, 0.001);
    try std.testing.expectApproxEqAbs(@as(f64, 4.1), cost.total, 0.001);
}

test "supportsXhigh returns true for supported models" {
    const gpt52 = types.Model{
        .id = "gpt-5.2-test",
        .name = "GPT-5.2",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const gpt53 = types.Model{
        .id = "gpt-5.3-test",
        .name = "GPT-5.3",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const gpt54 = types.Model{
        .id = "gpt-5.4-test",
        .name = "GPT-5.4",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = true,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const opus46 = types.Model{
        .id = "opus-4-6-test",
        .name = "Opus 4.6",
        .api = .anthropic_messages,
        .provider = .anthropic,
        .base_url = "https://api.anthropic.com",
        .reasoning = true,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 200_000,
        .max_tokens = 4096,
    };

    const regular = types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    try std.testing.expect(supportsXhigh(gpt52));
    try std.testing.expect(supportsXhigh(gpt53));
    try std.testing.expect(supportsXhigh(gpt54));
    try std.testing.expect(supportsXhigh(opus46));
    try std.testing.expect(!supportsXhigh(regular));
}

test "modelsAreEqual compares id and provider" {
    const model1 = types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const model2 = types.Model{
        .id = "gpt-4o",
        .name = "GPT-4o (variant)",
        .api = .openai_responses,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text, .image},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const model3 = types.Model{
        .id = "claude-3-opus",
        .name = "Claude 3 Opus",
        .api = .anthropic_messages,
        .provider = .anthropic,
        .base_url = "https://api.anthropic.com",
        .reasoning = true,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 200_000,
        .max_tokens = 4096,
    };

    try std.testing.expect(modelsAreEqual(model1, model2)); // Same id and provider
    try std.testing.expect(!modelsAreEqual(model1, model3)); // Different id and provider
    try std.testing.expect(!modelsAreEqual(model1, null)); // One null
    try std.testing.expect(!modelsAreEqual(null, null)); // Both null returns false
}

test "ModelRegistry register and get" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const model = types.Model{
        .id = "test-model",
        .name = "Test Model",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    try registry.register(model);

    const retrieved = registry.getModel(.openai, "test-model");
    try std.testing.expect(retrieved != null);
    try std.testing.expectEqualStrings("test-model", retrieved.?.id);
}

test "ModelRegistry getModels returns all models for provider" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const model1 = types.Model{
        .id = "model-1",
        .name = "Model 1",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const model2 = types.Model{
        .id = "model-2",
        .name = "Model 2",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    try registry.register(model1);
    try registry.register(model2);

    const models = try registry.getModels(std.testing.allocator, .openai);
    defer std.testing.allocator.free(models);

    try std.testing.expectEqual(@as(usize, 2), models.len);
}

test "ModelRegistry getProviders returns all providers" {
    var registry = ModelRegistry.init(std.testing.allocator);
    defer registry.deinit();

    const openai_model = types.Model{
        .id = "gpt-4",
        .name = "GPT-4",
        .api = .openai_completions,
        .provider = .openai,
        .base_url = "https://api.openai.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 128_000,
        .max_tokens = 4096,
    };

    const anthropic_model = types.Model{
        .id = "claude-3",
        .name = "Claude 3",
        .api = .anthropic_messages,
        .provider = .anthropic,
        .base_url = "https://api.anthropic.com",
        .reasoning = false,
        .input = &[_]types.Model.InputType{.text},
        .cost = .{ .input = 1.0, .output = 2.0, .cache_read = 0.0, .cache_write = 0.0 },
        .context_window = 200_000,
        .max_tokens = 4096,
    };

    try registry.register(openai_model);
    try registry.register(anthropic_model);

    const providers = try registry.getProviders(std.testing.allocator);
    defer std.testing.allocator.free(providers);

    try std.testing.expectEqual(@as(usize, 2), providers.len);
}
