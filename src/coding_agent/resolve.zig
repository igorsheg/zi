const std = @import("std");
const protocol = @import("../ai/protocol.zig");
const json_util = @import("../ai/json_util.zig");
const defaults = @import("defaults.zig");
const model_registry_mod = @import("model_registry.zig");

const Model = protocol.Model;
const ThinkingLevel = protocol.ThinkingLevel;
const ModelRegistry = model_registry_mod.ModelRegistry;

pub const ScopedModel = struct {
    model: Model,
    thinking_level: ?ThinkingLevel = null,
};

pub const ParsedModelResult = struct {
    model: ?Model,
    thinking_level: ?ThinkingLevel,

    warning: ?[]u8,
};

pub const ResolveCliModelResult = struct {
    model: ?Model,
    thinking_level: ?ThinkingLevel,

    warning: ?[]u8,

    err: ?[]u8,
};

pub const InitialModelResult = struct {
    model: ?Model,
    thinking_level: ThinkingLevel,

    fallback_message: ?[]u8,
};

pub const RestoreResult = struct {
    model: ?Model,

    fallback_message: ?[]u8,
};

fn isAlias(id: []const u8) bool {
    if (std.mem.endsWith(u8, id, "-latest")) return true;
    if (id.len < 9) return true;
    const tail = id[id.len - 9 ..];
    if (tail[0] != '-') return true;
    for (tail[1..]) |c| {
        if (c < '0' or c > '9') return true;
    }
    return false;
}

fn parseThinkingLevel(s: []const u8) ParsedThinking {
    if (std.mem.eql(u8, s, "off")) return .{ .valid = true, .level = null };
    if (std.mem.eql(u8, s, "minimal")) return .{ .valid = true, .level = .minimal };
    if (std.mem.eql(u8, s, "low")) return .{ .valid = true, .level = .low };
    if (std.mem.eql(u8, s, "medium")) return .{ .valid = true, .level = .medium };
    if (std.mem.eql(u8, s, "high")) return .{ .valid = true, .level = .high };
    if (std.mem.eql(u8, s, "xhigh")) return .{ .valid = true, .level = .xhigh };
    return .{ .valid = false, .level = null };
}

const ParsedThinking = struct {
    valid: bool,
    level: ?ThinkingLevel,
};

fn providerCanonical(p: protocol.Provider) []const u8 {
    return json_util.providerToString(p);
}

fn eqlIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn idDescLessThan(_: void, a: Model, b: Model) bool {
    return std.mem.order(u8, a.id, b.id) == .gt;
}

pub fn findExactModelReferenceMatch(
    reference: []const u8,
    available_models: []const Model,
) ?Model {
    const trimmed = std.mem.trim(u8, reference, " \t\r\n");
    if (trimmed.len == 0) return null;

    var stage1_hit: ?Model = null;
    var stage1_count: usize = 0;
    var canonical_buf: [256]u8 = undefined;
    for (available_models) |m| {
        const canonical = std.fmt.bufPrint(&canonical_buf, "{s}/{s}", .{
            providerCanonical(m.provider),
            m.id,
        }) catch continue;
        if (eqlIgnoreCase(canonical, trimmed)) {
            stage1_hit = m;
            stage1_count += 1;
            if (stage1_count > 1) return null;
        }
    }
    if (stage1_count == 1) return stage1_hit;

    if (std.mem.indexOfScalar(u8, trimmed, '/')) |slash| {
        const prov = std.mem.trim(u8, trimmed[0..slash], " \t");
        const mid = std.mem.trim(u8, trimmed[slash + 1 ..], " \t");
        if (prov.len > 0 and mid.len > 0) {
            var stage2_hit: ?Model = null;
            var stage2_count: usize = 0;
            for (available_models) |m| {
                if (eqlIgnoreCase(providerCanonical(m.provider), prov) and
                    eqlIgnoreCase(m.id, mid))
                {
                    stage2_hit = m;
                    stage2_count += 1;
                    if (stage2_count > 1) return null;
                }
            }
            if (stage2_count == 1) return stage2_hit;
        }
    }

    var stage3_hit: ?Model = null;
    var stage3_count: usize = 0;
    for (available_models) |m| {
        if (eqlIgnoreCase(m.id, trimmed)) {
            stage3_hit = m;
            stage3_count += 1;
            if (stage3_count > 1) return null;
        }
    }
    return if (stage3_count == 1) stage3_hit else null;
}

fn tryMatchModel(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    available_models: []const Model,
) ?Model {
    if (findExactModelReferenceMatch(pattern, available_models)) |m| return m;

    var matches: std.ArrayListUnmanaged(Model) = .empty;
    defer matches.deinit(allocator);

    var pat_lower_buf: [256]u8 = undefined;
    if (pattern.len > pat_lower_buf.len) return null;
    const pat_lower = std.ascii.lowerString(pat_lower_buf[0..pattern.len], pattern);

    var id_buf: [256]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    for (available_models) |m| {
        var hit = false;
        if (m.id.len <= id_buf.len) {
            const id_lower = std.ascii.lowerString(id_buf[0..m.id.len], m.id);
            if (std.mem.indexOf(u8, id_lower, pat_lower) != null) hit = true;
        }
        if (!hit and m.name.len <= name_buf.len) {
            const name_lower = std.ascii.lowerString(name_buf[0..m.name.len], m.name);
            if (std.mem.indexOf(u8, name_lower, pat_lower) != null) hit = true;
        }
        if (hit) matches.append(allocator, m) catch return null;
    }

    if (matches.items.len == 0) return null;

    var aliases: std.ArrayListUnmanaged(Model) = .empty;
    defer aliases.deinit(allocator);
    var dated: std.ArrayListUnmanaged(Model) = .empty;
    defer dated.deinit(allocator);

    for (matches.items) |m| {
        if (isAlias(m.id)) {
            aliases.append(allocator, m) catch return null;
        } else {
            dated.append(allocator, m) catch return null;
        }
    }

    if (aliases.items.len > 0) {
        std.mem.sort(Model, aliases.items, {}, idDescLessThan);
        return aliases.items[0];
    }
    std.mem.sort(Model, dated.items, {}, idDescLessThan);
    return dated.items[0];
}

pub const ParseOptions = struct {
    allow_invalid_thinking_level_fallback: bool = true,

    warning_allocator: ?std.mem.Allocator = null,
};

pub fn parseModelPattern(
    allocator: std.mem.Allocator,
    pattern: []const u8,
    available_models: []const Model,
    opts: ParseOptions,
) ParsedModelResult {
    if (tryMatchModel(allocator, pattern, available_models)) |m| {
        return .{ .model = m, .thinking_level = null, .warning = null };
    }

    const last_colon = std.mem.lastIndexOfScalar(u8, pattern, ':') orelse {
        return .{ .model = null, .thinking_level = null, .warning = null };
    };

    const prefix = pattern[0..last_colon];
    const suffix = pattern[last_colon + 1 ..];

    const parsed = parseThinkingLevel(suffix);
    if (parsed.valid) {
        const inner = parseModelPattern(allocator, prefix, available_models, opts);
        if (inner.model != null) {
            return .{
                .model = inner.model,
                .thinking_level = if (inner.warning != null) null else parsed.level,
                .warning = inner.warning,
            };
        }
        return inner;
    }

    if (!opts.allow_invalid_thinking_level_fallback) {
        return .{ .model = null, .thinking_level = null, .warning = null };
    }

    const inner = parseModelPattern(allocator, prefix, available_models, opts);
    if (inner.model != null) {
        const warn: ?[]u8 = if (opts.warning_allocator) |wa|
            std.fmt.allocPrint(
                wa,
                "Invalid thinking level \"{s}\" in pattern \"{s}\". Using default instead.",
                .{ suffix, pattern },
            ) catch null
        else
            null;
        return .{
            .model = inner.model,
            .thinking_level = null,
            .warning = warn,
        };
    }
    return inner;
}

fn buildFallbackModel(
    provider: protocol.Provider,
    model_id: []const u8,
    available_models: []const Model,
) ?Model {
    var first: ?Model = null;
    var default_id: ?[]const u8 = null;
    for (defaults.default_model_per_provider) |entry| {
        if (std.meta.eql(entry.provider, provider)) {
            default_id = entry.id;
            break;
        }
    }

    var chosen: ?Model = null;
    for (available_models) |m| {
        if (!std.meta.eql(m.provider, provider)) continue;
        if (first == null) first = m;
        if (default_id) |d| {
            if (std.mem.eql(u8, m.id, d)) {
                chosen = m;
                break;
            }
        }
    }
    const base = chosen orelse first orelse return null;
    var out = base;
    out.id = model_id;
    out.name = model_id;
    return out;
}

pub const ResolveCliOptions = struct {
    cli_provider: ?[]const u8 = null,
    cli_model: ?[]const u8 = null,
    registry: *const ModelRegistry,

    allocator: std.mem.Allocator,
};

pub fn resolveCliModel(opts: ResolveCliOptions) ResolveCliModelResult {
    const cli_model = opts.cli_model orelse return .{
        .model = null,
        .thinking_level = null,
        .warning = null,
        .err = null,
    };

    const available = opts.registry.getAll();
    if (available.len == 0) {
        const msg = opts.allocator.dupe(
            u8,
            "No models available. Check your installation or add models to models.json.",
        ) catch null;
        return .{ .model = null, .thinking_level = null, .warning = null, .err = msg };
    }

    var provider: ?protocol.Provider = null;
    if (opts.cli_provider) |cp| {
        for (available) |m| {
            if (eqlIgnoreCase(providerCanonical(m.provider), cp)) {
                provider = m.provider;
                break;
            }
        }
        if (provider == null) {
            const msg = std.fmt.allocPrint(
                opts.allocator,
                "Unknown provider \"{s}\". Use --list-models to see available providers/models.",
                .{cp},
            ) catch null;
            return .{ .model = null, .thinking_level = null, .warning = null, .err = msg };
        }
    }

    var pattern: []const u8 = cli_model;
    var inferred_provider = false;

    if (provider == null) {
        if (std.mem.indexOfScalar(u8, cli_model, '/')) |slash| {
            const maybe = cli_model[0..slash];
            for (available) |m| {
                if (eqlIgnoreCase(providerCanonical(m.provider), maybe)) {
                    provider = m.provider;
                    pattern = cli_model[slash + 1 ..];
                    inferred_provider = true;
                    break;
                }
            }
        }
    }

    if (provider == null) {
        var full_buf: [256]u8 = undefined;
        for (available) |m| {
            if (eqlIgnoreCase(m.id, cli_model)) {
                return .{ .model = m, .thinking_level = null, .warning = null, .err = null };
            }
            const canon = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
                providerCanonical(m.provider), m.id,
            }) catch continue;
            if (eqlIgnoreCase(canon, cli_model)) {
                return .{ .model = m, .thinking_level = null, .warning = null, .err = null };
            }
        }
    }

    if (opts.cli_provider != null and provider != null) {
        const canon = providerCanonical(provider.?);
        if (cli_model.len > canon.len + 1 and
            std.ascii.startsWithIgnoreCase(cli_model, canon) and
            cli_model[canon.len] == '/')
        {
            pattern = cli_model[canon.len + 1 ..];
        }
    }

    var candidates_buf: std.ArrayListUnmanaged(Model) = .empty;
    defer candidates_buf.deinit(opts.allocator);
    const candidates: []const Model = if (provider) |p| blk: {
        for (available) |m| {
            if (std.meta.eql(m.provider, p)) {
                candidates_buf.append(opts.allocator, m) catch break :blk &.{};
            }
        }
        break :blk candidates_buf.items;
    } else available;

    const parsed = parseModelPattern(opts.allocator, pattern, candidates, .{
        .allow_invalid_thinking_level_fallback = false,
        .warning_allocator = opts.allocator,
    });

    if (parsed.model) |m| {
        return .{
            .model = m,
            .thinking_level = parsed.thinking_level,
            .warning = parsed.warning,
            .err = null,
        };
    }

    if (inferred_provider) {
        var full_buf: [256]u8 = undefined;
        for (available) |m| {
            if (eqlIgnoreCase(m.id, cli_model)) {
                return .{ .model = m, .thinking_level = null, .warning = null, .err = null };
            }
            const canon = std.fmt.bufPrint(&full_buf, "{s}/{s}", .{
                providerCanonical(m.provider), m.id,
            }) catch continue;
            if (eqlIgnoreCase(canon, cli_model)) {
                return .{ .model = m, .thinking_level = null, .warning = null, .err = null };
            }
        }
        const fallback = parseModelPattern(opts.allocator, cli_model, available, .{
            .allow_invalid_thinking_level_fallback = false,
            .warning_allocator = opts.allocator,
        });
        if (fallback.model != null) {
            return .{
                .model = fallback.model,
                .thinking_level = fallback.thinking_level,
                .warning = fallback.warning,
                .err = null,
            };
        }
    }

    if (provider) |p| {
        if (buildFallbackModel(p, pattern, available)) |fm| {
            const msg = std.fmt.allocPrint(
                opts.allocator,
                "Model \"{s}\" not found for provider \"{s}\". Using custom model id.",
                .{ pattern, providerCanonical(p) },
            ) catch null;
            return .{ .model = fm, .thinking_level = null, .warning = msg, .err = null };
        }
    }

    const display: []const u8 = if (provider) |p|
        std.fmt.allocPrint(opts.allocator, "{s}/{s}", .{ providerCanonical(p), pattern }) catch cli_model
    else
        cli_model;
    const err = std.fmt.allocPrint(
        opts.allocator,
        "Model \"{s}\" not found. Use --list-models to see available models.",
        .{display},
    ) catch null;
    return .{ .model = null, .thinking_level = null, .warning = null, .err = err };
}

pub const FindInitialOptions = struct {
    cli_provider: ?[]const u8 = null,
    cli_model: ?[]const u8 = null,
    scoped_models: []const ScopedModel = &.{},
    is_continuing: bool = false,
    default_provider: ?[]const u8 = null,
    default_model_id: ?[]const u8 = null,
    default_thinking_level: ?ThinkingLevel = null,
    registry: *const ModelRegistry,
    allocator: std.mem.Allocator,
};

pub fn findInitialModel(opts: FindInitialOptions) !InitialModelResult {
    if (opts.cli_provider != null and opts.cli_model != null) {
        const resolved = resolveCliModel(.{
            .cli_provider = opts.cli_provider,
            .cli_model = opts.cli_model,
            .registry = opts.registry,
            .allocator = opts.allocator,
        });
        if (resolved.err) |msg| {
            return .{
                .model = null,
                .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
                .fallback_message = msg,
            };
        }
        if (resolved.model) |m| {
            return .{
                .model = m,
                .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
                .fallback_message = null,
            };
        }
    }

    if (opts.cli_model != null) {
        const resolved = resolveCliModel(.{
            .cli_model = opts.cli_model,
            .registry = opts.registry,
            .allocator = opts.allocator,
        });
        if (resolved.model) |m| {
            return .{
                .model = m,
                .thinking_level = resolved.thinking_level orelse defaults.DEFAULT_THINKING_LEVEL,
                .fallback_message = null,
            };
        }
        if (resolved.err) |msg| {
            return .{
                .model = null,
                .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
                .fallback_message = msg,
            };
        }
    }

    if (opts.scoped_models.len > 0 and !opts.is_continuing) {
        const first = opts.scoped_models[0];
        return .{
            .model = first.model,
            .thinking_level = first.thinking_level orelse opts.default_thinking_level orelse defaults.DEFAULT_THINKING_LEVEL,
            .fallback_message = null,
        };
    }

    if (opts.default_provider) |dp| if (opts.default_model_id) |dm| {
        const provider = json_util.parseProvider(dp);
        if (opts.registry.find(provider, dm)) |m| {
            return .{
                .model = m,
                .thinking_level = opts.default_thinking_level orelse defaults.DEFAULT_THINKING_LEVEL,
                .fallback_message = null,
            };
        }
    };

    const available = try opts.registry.getAvailable(opts.allocator);
    defer opts.allocator.free(available);

    if (available.len > 0) {
        for (defaults.default_model_per_provider) |entry| {
            for (available) |m| {
                if (std.meta.eql(m.provider, entry.provider) and
                    std.mem.eql(u8, m.id, entry.id))
                {
                    return .{
                        .model = m,
                        .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
                        .fallback_message = null,
                    };
                }
            }
        }
        return .{
            .model = available[0],
            .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
            .fallback_message = null,
        };
    }

    return .{
        .model = null,
        .thinking_level = defaults.DEFAULT_THINKING_LEVEL,
        .fallback_message = null,
    };
}

pub const RestoreOptions = struct {
    saved_provider: []const u8,
    saved_model_id: []const u8,
    current_model: ?Model = null,
    registry: *const ModelRegistry,
    allocator: std.mem.Allocator,
};

pub fn restoreModelFromSession(opts: RestoreOptions) !RestoreResult {
    const saved_provider = json_util.parseProvider(opts.saved_provider);
    const restored = opts.registry.find(saved_provider, opts.saved_model_id);
    const has_auth = if (restored) |m| opts.registry.hasConfiguredAuth(m) else false;

    if (restored != null and has_auth) {
        return .{ .model = restored, .fallback_message = null };
    }

    const reason: []const u8 = if (restored == null)
        "model no longer exists"
    else
        "no auth configured";

    if (opts.current_model) |cm| {
        const msg = try std.fmt.allocPrint(
            opts.allocator,
            "Could not restore model {s}/{s} ({s}). Using {s}/{s}.",
            .{ opts.saved_provider, opts.saved_model_id, reason, providerCanonical(cm.provider), cm.id },
        );
        return .{ .model = cm, .fallback_message = msg };
    }

    const available = try opts.registry.getAvailable(opts.allocator);
    defer opts.allocator.free(available);

    if (available.len > 0) {
        var fallback: ?Model = null;
        for (defaults.default_model_per_provider) |entry| {
            for (available) |m| {
                if (std.meta.eql(m.provider, entry.provider) and
                    std.mem.eql(u8, m.id, entry.id))
                {
                    fallback = m;
                    break;
                }
            }
            if (fallback != null) break;
        }
        if (fallback == null) fallback = available[0];

        const fm = fallback.?;
        const msg = try std.fmt.allocPrint(
            opts.allocator,
            "Could not restore model {s}/{s} ({s}). Using {s}/{s}.",
            .{ opts.saved_provider, opts.saved_model_id, reason, providerCanonical(fm.provider), fm.id },
        );
        return .{ .model = fm, .fallback_message = msg };
    }

    return .{ .model = null, .fallback_message = null };
}

const auth_storage_mod = @import("auth/storage.zig");
const generated = @import("../ai/models_generated.zig");

test "parseModelPattern handles colon-thinking-level suffix" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const r1 = parseModelPattern(alloc, "opus-4-6:high", reg.getAll(), .{});
    try std.testing.expect(r1.model != null);
    try std.testing.expect(r1.thinking_level != null);
    try std.testing.expectEqual(ThinkingLevel.high, r1.thinking_level.?);

    const r2 = parseModelPattern(alloc, "claude-opus-4-6", reg.getAll(), .{});
    try std.testing.expect(r2.model != null);
    try std.testing.expect(r2.thinking_level == null);
}

test "findInitialModel walks defaults_per_provider in order" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("anthropic", "k");
    auth.setRuntimeApiKey("openai", "k");

    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const result = try findInitialModel(.{
        .registry = &reg,
        .allocator = alloc,
    });
    try std.testing.expect(result.model != null);
    try std.testing.expectEqualStrings("claude-opus-4-6", result.model.?.id);
    try std.testing.expect(std.meta.eql(result.model.?.provider, protocol.Provider.anthropic));
}

test "resolveCliModel infers provider from slash and strips the prefix" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    var scratch = std.heap.ArenaAllocator.init(alloc);
    defer scratch.deinit();
    const result = resolveCliModel(.{
        .cli_model = "anthropic/claude-opus-4-6",
        .registry = &reg,
        .allocator = scratch.allocator(),
    });
    try std.testing.expect(result.err == null);
    try std.testing.expect(result.model != null);
    try std.testing.expectEqualStrings("claude-opus-4-6", result.model.?.id);
    try std.testing.expect(std.meta.eql(result.model.?.provider, protocol.Provider.anthropic));
}

test "restoreModelFromSession falls back when saved model lacks auth" {
    const alloc = std.testing.allocator;
    var auth = try auth_storage_mod.AuthStorage.inMemory(alloc, null);
    defer auth.deinit();
    auth.setRuntimeApiKey("openai", "k");

    var reg = try ModelRegistry.init(alloc, &auth, &.{});
    defer reg.deinit();

    const result = try restoreModelFromSession(.{
        .saved_provider = "anthropic",
        .saved_model_id = "claude-opus-4-6",
        .registry = &reg,
        .allocator = alloc,
    });
    defer if (result.fallback_message) |m| alloc.free(m);

    try std.testing.expect(result.model != null);
    try std.testing.expect(std.meta.eql(result.model.?.provider, protocol.Provider.openai));
    try std.testing.expect(result.fallback_message != null);
}
