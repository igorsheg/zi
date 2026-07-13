const std = @import("std");
const protocol = @import("protocol.zig");
const generated = @import("models.generated.zig");

pub const models = generated.models;
pub const providers = generated.providers;

pub const faux_provider_env = "ZI_ENABLE_FAUX_PROVIDER";

var faux_provider_count: std.atomic.Value(usize) = .init(0);

const providers_with_faux = generated.providers ++ [_]protocol.Provider{protocol.KnownProvider.faux};
const faux_models = [_]protocol.Model{.{
    .id = "faux-default",
    .name = "Faux Model",
    .api = protocol.KnownApi.faux,
    .provider = protocol.KnownProvider.faux,
    .base_url = "http://localhost:0",
    .reasoning = false,
    .input = &.{.text},
    .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
    .context_window = 128_000,
    .max_tokens = 16_384,
}};

pub fn fauxProviderEnabledFromEnviron(environ: ?*const std.process.Environ.Map) bool {
    const env = environ orelse return false;
    const value = env.get(faux_provider_env) orelse return false;
    return std.mem.eql(u8, value, "1");
}

pub fn retainFauxProviderGateFromEnviron(environ: ?*const std.process.Environ.Map) bool {
    if (!fauxProviderEnabledFromEnviron(environ)) return false;
    _ = faux_provider_count.fetchAdd(1, .monotonic);
    return true;
}

pub fn releaseFauxProviderGate() void {
    const previous = faux_provider_count.fetchSub(1, .monotonic);
    std.debug.assert(previous > 0);
}

fn fauxProviderGateEnabled() bool {
    return faux_provider_count.load(.monotonic) > 0;
}

// TODO: Replace static catalog lookups with an owned ModelRegistry when runtime providers can register models.
pub fn getModel(provider: protocol.Provider, model_id: []const u8) ?protocol.Model {
    if (fauxProviderGateEnabled() and std.mem.eql(u8, provider, protocol.KnownProvider.faux)) {
        for (faux_models) |model| {
            if (std.mem.eql(u8, model.id, model_id)) return model;
        }
        return null;
    }
    for (models) |model| {
        if (std.mem.eql(u8, model.provider, provider) and std.mem.eql(u8, model.id, model_id)) {
            return model;
        }
    }
    return null;
}

pub fn getProviders() []const protocol.Provider {
    return if (fauxProviderGateEnabled()) &providers_with_faux else &providers;
}

pub fn getModels(provider: protocol.Provider) []const protocol.Model {
    if (fauxProviderGateEnabled() and std.mem.eql(u8, provider, protocol.KnownProvider.faux)) return &faux_models;

    var start: ?usize = null;
    var end: usize = 0;

    for (models, 0..) |model, index| {
        if (std.mem.eql(u8, model.provider, provider)) {
            if (start == null) start = index;
            end = index + 1;
        } else if (start != null) {
            break;
        }
    }

    const first = start orelse return &.{};
    return models[first..end];
}

pub fn calculateCost(model: protocol.Model, usage: *protocol.Usage) protocol.Usage.Cost {
    usage.cost.input = costForTokens(model.cost.input, usage.input);
    usage.cost.output = costForTokens(model.cost.output, usage.output);
    usage.cost.cache_read = costForTokens(model.cost.cache_read, usage.cache_read);
    usage.cost.cache_write = costForTokens(model.cost.cache_write, usage.cache_write);
    usage.cost.total = usage.cost.input + usage.cost.output + usage.cost.cache_read + usage.cost.cache_write;
    return usage.cost;
}

pub fn supportsXhigh(model: protocol.Model) bool {
    return std.mem.indexOf(u8, model.id, "gpt-5.2") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.3") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.4") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.5") != null or
        std.mem.indexOf(u8, model.id, "gpt-5.6") != null or
        std.mem.indexOf(u8, model.id, "deepseek-v4-pro") != null or
        std.mem.indexOf(u8, model.id, "opus-4-6") != null or
        std.mem.indexOf(u8, model.id, "opus-4.6") != null or
        std.mem.indexOf(u8, model.id, "opus-4-7") != null or
        std.mem.indexOf(u8, model.id, "opus-4.7") != null;
}

pub fn supportsCodexPriorityService(model: protocol.Model) bool {
    if (!std.mem.eql(u8, model.provider, protocol.KnownProvider.openai_codex)) return false;
    return std.mem.eql(u8, model.id, "gpt-5.4") or std.mem.eql(u8, model.id, "gpt-5.5");
}

pub fn modelsAreEqual(a: ?protocol.Model, b: ?protocol.Model) bool {
    const left = a orelse return false;
    const right = b orelse return false;
    return std.mem.eql(u8, left.id, right.id) and std.mem.eql(u8, left.provider, right.provider);
}

fn costForTokens(price_per_million: f64, tokens: u64) f64 {
    return price_per_million / 1_000_000 * @as(f64, @floatFromInt(tokens));
}

fn containsProvider(haystack: []const protocol.Provider, needle: protocol.Provider) bool {
    for (haystack) |provider| {
        if (std.mem.eql(u8, provider, needle)) return true;
    }
    return false;
}

test "get model returns matching provider and id" {
    const model = getModel(protocol.KnownProvider.openai, "gpt-5.1").?;

    try std.testing.expectEqualStrings("gpt-5.1", model.id);
    try std.testing.expectEqualStrings(protocol.KnownProvider.openai, model.provider);
}

test "get model rejects same id under different provider" {
    try std.testing.expectEqual(@as(?protocol.Model, null), getModel(protocol.KnownProvider.anthropic, "gpt-5.1"));
}

test "get providers returns generated providers" {
    const found = getProviders();

    try std.testing.expect(found.len >= 2);
    try std.testing.expect(containsProvider(found, protocol.KnownProvider.openai));
    try std.testing.expect(containsProvider(found, protocol.KnownProvider.openai_codex));
    try std.testing.expect(!containsProvider(found, protocol.KnownProvider.faux));
}

// faux catalog entries are only visible while RuntimeServices has retained the env gate.
test "faux model catalog is gated" {
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put(faux_provider_env, "1");

    try std.testing.expect(retainFauxProviderGateFromEnviron(&environ));
    defer releaseFauxProviderGate();

    try std.testing.expect(containsProvider(getProviders(), protocol.KnownProvider.faux));
    const model = getModel(protocol.KnownProvider.faux, "faux-default").?;
    try std.testing.expectEqualStrings(protocol.KnownApi.faux, model.api);
    try std.testing.expectEqualStrings(protocol.KnownProvider.faux, model.provider);
    try std.testing.expectEqual(@as(usize, 1), getModels(protocol.KnownProvider.faux).len);
}

test "get models returns contiguous provider slice" {
    const found = getModels(protocol.KnownProvider.openai_codex);

    try std.testing.expect(found.len >= 1);
    for (found) |model| {
        try std.testing.expectEqualStrings(protocol.KnownProvider.openai_codex, model.provider);
    }
    try std.testing.expect(getModel(protocol.KnownProvider.openai_codex, "gpt-5.1-codex-max") != null);
}

test "gpt 5.6 models are available in direct and codex catalogs" {
    const direct = getModel(protocol.KnownProvider.openai, "gpt-5.6-luna").?;
    const codex = getModel(protocol.KnownProvider.openai_codex, "gpt-5.6-luna").?;

    try std.testing.expectEqual(@as(u64, 272_000), direct.context_window);
    try std.testing.expectEqual(@as(u64, 372_000), codex.context_window);
    try std.testing.expectEqual(@as(f64, 1.25), direct.cost.cache_write);
    try std.testing.expectEqual(@as(f64, 1.25), codex.cost.cache_write);
    try std.testing.expect(supportsXhigh(direct));
    try std.testing.expect(supportsXhigh(codex));
}

test "calculate cost mutates usage cost in dollars" {
    const model = getModel(protocol.KnownProvider.openai, "gpt-5.1").?;
    var usage = protocol.emptyUsage();
    usage.input = 1_000_000;
    usage.output = 2_000_000;
    usage.cache_read = 3_000_000;
    usage.cache_write = 4_000_000;

    const cost = calculateCost(model, &usage);

    try std.testing.expectEqual(@as(f64, 1.25), cost.input);
    try std.testing.expectEqual(@as(f64, 20), cost.output);
    try std.testing.expectEqual(model.cost.cache_read * 3, cost.cache_read);
    try std.testing.expectEqual(model.cost.cache_write * 4, cost.cache_write);
    try std.testing.expectEqual(cost.input + cost.output + cost.cache_read + cost.cache_write, cost.total);
}

test "supports xhigh follows pi model id policy" {
    const xhigh: protocol.Model = .{
        .id = "gpt-5.4",
        .name = "GPT-5.4",
        .api = protocol.KnownApi.openai_responses,
        .provider = protocol.KnownProvider.openai,
        .base_url = "https://example.test",
        .reasoning = true,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1,
        .max_tokens = 1,
    };
    const normal = getModel(protocol.KnownProvider.openai, "gpt-5.1").?;

    try std.testing.expect(supportsXhigh(xhigh));
    try std.testing.expect(!supportsXhigh(normal));
}

test "codex priority service is limited to advertised models" {
    try std.testing.expect(supportsCodexPriorityService(
        getModel(protocol.KnownProvider.openai_codex, "gpt-5.4").?,
    ));
    try std.testing.expect(supportsCodexPriorityService(
        getModel(protocol.KnownProvider.openai_codex, "gpt-5.5").?,
    ));
    try std.testing.expect(!supportsCodexPriorityService(
        getModel(protocol.KnownProvider.openai_codex, "gpt-5.4-mini").?,
    ));
    try std.testing.expect(!supportsCodexPriorityService(
        getModel(protocol.KnownProvider.openai, "gpt-5.4").?,
    ));
}

test "models are equal by id and provider" {
    const left = getModel(protocol.KnownProvider.openai, "gpt-5.1").?;
    const right = getModel(protocol.KnownProvider.openai, "gpt-5.1").?;
    const other = getModel(protocol.KnownProvider.openai_codex, "gpt-5.1-codex-max").?;

    try std.testing.expect(modelsAreEqual(left, right));
    try std.testing.expect(!modelsAreEqual(left, other));
    try std.testing.expect(!modelsAreEqual(left, null));
}
