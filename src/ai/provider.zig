const std = @import("std");
const protocol = @import("protocol.zig");
const json_value = @import("../json/value.zig");

/// Callback invoked for each streaming event.
pub const EventCallback = *const fn (event: protocol.AssistantMessageEvent, ctx: ?*anyopaque) void;

/// Provider interface — vtable-based polymorphism.
/// Matches pi-mono's ApiProvider contract: stream and streamSimple.
pub const Provider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Stream a response. Must NOT return errors for request/runtime failures.
        /// Failures are encoded as error events via the callback.
        /// Terminal event (done or error) must always be emitted.
        stream: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.StreamOptions,
            callback: EventCallback,
            callback_ctx: ?*anyopaque,
        ) void,

        /// Stream with simplified options (includes reasoning level).
        stream_simple: *const fn (
            ptr: *anyopaque,
            allocator: std.mem.Allocator,
            model: protocol.Model,
            context: protocol.Context,
            options: protocol.SimpleStreamOptions,
            callback: EventCallback,
            callback_ctx: ?*anyopaque,
        ) void,

        /// Provider name for diagnostics.
        get_name: *const fn (ptr: *anyopaque) []const u8,

        /// Clean up resources.
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn stream(self: Provider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.StreamOptions, callback: EventCallback, callback_ctx: ?*anyopaque) void {
        self.vtable.stream(self.ptr, allocator, model, context, options, callback, callback_ctx);
    }

    pub fn streamSimple(self: Provider, allocator: std.mem.Allocator, model: protocol.Model, context: protocol.Context, options: protocol.SimpleStreamOptions, callback: EventCallback, callback_ctx: ?*anyopaque) void {
        self.vtable.stream_simple(self.ptr, allocator, model, context, options, callback, callback_ctx);
    }

    pub fn getName(self: Provider) []const u8 {
        return self.vtable.get_name(self.ptr);
    }

    pub fn deinit(self: Provider) void {
        self.vtable.deinit(self.ptr);
    }
};

pub const ClaimModelRegistration = struct {
    id: []const u8,
    name: []const u8,
    api: ?[]const u8 = null,
    reasoning: bool,
    input: []const protocol.Model.InputType,
    cost: protocol.Model.Cost,
    context_window: u64,
    max_tokens: u64,
    headers: []const protocol.Header = &.{},
    compat: ?std.json.Value = null,

    pub fn deinit(self: *ClaimModelRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
        if (self.api) |api| allocator.free(api);
        if (self.input.len > 0) allocator.free(self.input);
        freeHeaders(allocator, self.headers);
        if (self.compat) |compat| json_value.freeJsonValue(allocator, compat);
        self.* = undefined;
    }
};

pub const ClaimRegistration = struct {
    name: []const u8,
    api: []const u8,
    base_url: []const u8,
    api_key: ?[]const u8 = null,
    headers: []const protocol.Header = &.{},
    oauth_enabled: bool = false,
    oauth_name: ?[]const u8 = null,
    oauth_login_ref: ?c_int = null,
    oauth_refresh_token_ref: ?c_int = null,
    oauth_get_api_key_ref: ?c_int = null,
    owner_id: []const u8,
    generation: u64,
    models: []ClaimModelRegistration = &.{},

    pub fn deinit(self: *ClaimRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.api);
        allocator.free(self.base_url);
        if (self.api_key) |api_key| allocator.free(api_key);
        freeHeaders(allocator, self.headers);
        if (self.oauth_name) |oauth_name| allocator.free(oauth_name);
        allocator.free(self.owner_id);
        for (self.models) |*model| model.deinit(allocator);
        if (self.models.len > 0) allocator.free(self.models);
        self.* = undefined;
    }
};

fn freeHeaders(allocator: std.mem.Allocator, headers: []const protocol.Header) void {
    for (headers) |header| {
        allocator.free(header.key);
        allocator.free(header.value);
    }
    if (headers.len > 0) allocator.free(headers);
}

const Claim = struct {
    registration: ClaimRegistration,
    provider: Provider,

    fn init(allocator: std.mem.Allocator, registration: ClaimRegistration, delegate: Provider) !Claim {
        return .{
            .registration = registration,
            .provider = try BaseUrlClaimProvider.create(
                allocator,
                registration.name,
                registration.base_url,
                delegate,
            ),
        };
    }

    fn deinit(self: *Claim, allocator: std.mem.Allocator) void {
        self.provider.deinit();
        self.registration.deinit(allocator);
    }
};

const BaseUrlClaimProvider = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    base_url: []const u8,
    delegate: Provider,

    const vtable: Provider.VTable = .{
        .stream = streamImpl,
        .stream_simple = streamSimpleImpl,
        .get_name = getNameImpl,
        .deinit = deinitImpl,
    };

    fn create(
        allocator: std.mem.Allocator,
        name: []const u8,
        base_url: []const u8,
        delegate: Provider,
    ) !Provider {
        const self = try allocator.create(BaseUrlClaimProvider);
        self.* = .{
            .allocator = allocator,
            .name = name,
            .base_url = base_url,
            .delegate = delegate,
        };
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn getSelf(ptr: *anyopaque) *BaseUrlClaimProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn streamImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.StreamOptions,
        callback: EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self = getSelf(ptr);
        var overridden = model;
        overridden.base_url = self.base_url;
        self.delegate.stream(allocator, overridden, context, options, callback, callback_ctx);
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        allocator: std.mem.Allocator,
        model: protocol.Model,
        context: protocol.Context,
        options: protocol.SimpleStreamOptions,
        callback: EventCallback,
        callback_ctx: ?*anyopaque,
    ) void {
        const self = getSelf(ptr);
        var overridden = model;
        overridden.base_url = self.base_url;
        self.delegate.streamSimple(allocator, overridden, context, options, callback, callback_ctx);
    }

    fn getNameImpl(ptr: *anyopaque) []const u8 {
        return getSelf(ptr).name;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = getSelf(ptr);
        self.allocator.destroy(self);
    }
};

/// API registry — active projection keyed by Api identifier, with a
/// separate name-keyed claim layer for extension-owned overrides.
pub const Registry = struct {
    providers: std.StringHashMap(Provider),
    baseline: std.StringHashMap(Provider),
    claim_index: std.StringHashMap(std.ArrayListUnmanaged(usize)),
    claims: std.ArrayListUnmanaged(Claim) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .providers = std.StringHashMap(Provider).init(allocator),
            .baseline = std.StringHashMap(Provider).init(allocator),
            .claim_index = std.StringHashMap(std.ArrayListUnmanaged(usize)).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit();
        self.clearClaims();
        self.baseline.deinit();

        var it = self.claim_index.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.claim_index.deinit();
    }

    /// Register a built-in / baseline provider for an API identifier.
    pub fn register(self: *Registry, api: []const u8, prov: Provider, source_id: ?[]const u8) !void {
        _ = source_id;
        try self.baseline.put(api, prov);
        try self.rebuildProjection();
    }

    pub fn registerClaim(self: *Registry, registration: ClaimRegistration) !bool {
        const delegate = self.baseline.get(registration.api) orelse return error.UnknownApi;
        var claim = try Claim.init(self.allocator, registration, delegate);
        errdefer claim.deinit(self.allocator);

        if (self.claim_index.getPtr(claim.registration.name)) |bucket| {
            if (bucket.items.len > 0) {
                const winner = &self.claims.items[bucket.items[0]];
                if (!std.mem.eql(u8, winner.registration.owner_id, claim.registration.owner_id)) {
                    return false;
                }
            }

            const idx = self.claims.items.len;
            try self.claims.append(self.allocator, claim);
            errdefer _ = self.claims.pop();
            try bucket.append(self.allocator, idx);
            errdefer _ = bucket.pop();
            try self.rebuildProjection();
            return true;
        }

        const idx = self.claims.items.len;
        try self.claims.append(self.allocator, claim);
        errdefer _ = self.claims.pop();

        const key_dup = try self.allocator.dupe(u8, claim.registration.name);
        errdefer self.allocator.free(key_dup);

        var bucket: std.ArrayListUnmanaged(usize) = .empty;
        errdefer bucket.deinit(self.allocator);
        try bucket.append(self.allocator, idx);

        try self.claim_index.put(key_dup, bucket);
        errdefer if (self.claim_index.fetchRemove(claim.registration.name)) |removed| {
            var removed_bucket = removed.value;
            removed_bucket.deinit(self.allocator);
            self.allocator.free(removed.key);
        };

        try self.rebuildProjection();
        return true;
    }

    pub fn unregisterClaim(self: *Registry, name: []const u8, owner_id: []const u8, generation: u64) !bool {
        const bucket = self.claim_index.getPtr(name) orelse return false;
        if (bucket.items.len == 0) return false;

        const winner = self.claims.items[bucket.items[0]];
        if (!std.mem.eql(u8, winner.registration.owner_id, owner_id)) return false;
        if (winner.registration.generation != generation) return false;

        const idx = bucket.items[0];
        _ = bucket.orderedRemove(0);
        var removed = self.claims.orderedRemove(idx);

        if (bucket.items.len == 0) {
            const index_entry = self.claim_index.fetchRemove(name) orelse unreachable;
            var removed_bucket = index_entry.value;
            removed_bucket.deinit(self.allocator);
            self.allocator.free(index_entry.key);
        }

        try self.reindexClaimsFrom(idx);
        try self.rebuildProjection();
        removed.deinit(self.allocator);
        return true;
    }

    pub fn unregisterClaimsByGeneration(self: *Registry, generation: u64) !void {
        var i: usize = 0;
        var removed_any = false;
        while (i < self.claims.items.len) {
            if (self.claims.items[i].registration.generation != generation) {
                i += 1;
                continue;
            }

            const name = self.claims.items[i].registration.name;
            const bucket = self.claim_index.getPtr(name) orelse unreachable;
            const bucket_idx = findBucketIndex(bucket.items, i) orelse unreachable;
            _ = bucket.orderedRemove(bucket_idx);

            var removed = self.claims.orderedRemove(i);
            if (bucket.items.len == 0) {
                const index_entry = self.claim_index.fetchRemove(removed.registration.name) orelse unreachable;
                var removed_bucket = index_entry.value;
                removed_bucket.deinit(self.allocator);
                self.allocator.free(index_entry.key);
            }
            removed.deinit(self.allocator);
            removed_any = true;
        }
        if (removed_any) {
            try self.reindexClaimsFrom(0);
            try self.rebuildProjection();
        }
    }

    /// Look up provider by API identifier.
    pub fn get(self: *const Registry, api: []const u8) ?Provider {
        return self.providers.get(api);
    }

    pub fn getForModel(self: *const Registry, api: []const u8, provider_name: []const u8) ?Provider {
        if (self.claimByName(provider_name)) |claim| {
            if (std.mem.eql(u8, claim.registration.api, api)) return claim.provider;
        }
        return self.baseline.get(api) orelse self.providers.get(api);
    }

    pub fn activeClaimCount(self: *const Registry) usize {
        return self.claims.items.len;
    }

    pub fn activeClaimRegistrationAt(self: *const Registry, index: usize) *const ClaimRegistration {
        return &self.claims.items[index].registration;
    }

    pub fn activeClaimRegistrationByName(self: *const Registry, provider_name: []const u8) ?*const ClaimRegistration {
        const claim = self.claimByName(provider_name) orelse return null;
        return &claim.registration;
    }

    /// Unregister all providers with a given source_id.
    pub fn unregisterBySource(self: *Registry, source_id: []const u8) void {
        var i: usize = 0;
        var removed_any = false;
        while (i < self.claims.items.len) {
            if (!std.mem.eql(u8, self.claims.items[i].registration.owner_id, source_id)) {
                i += 1;
                continue;
            }

            const name = self.claims.items[i].registration.name;
            const bucket = self.claim_index.getPtr(name) orelse unreachable;
            const bucket_idx = findBucketIndex(bucket.items, i) orelse unreachable;
            _ = bucket.orderedRemove(bucket_idx);

            var removed = self.claims.orderedRemove(i);
            if (bucket.items.len == 0) {
                const index_entry = self.claim_index.fetchRemove(removed.registration.name) orelse unreachable;
                var removed_bucket = index_entry.value;
                removed_bucket.deinit(self.allocator);
                self.allocator.free(index_entry.key);
            }
            removed.deinit(self.allocator);
            removed_any = true;
        }
        if (removed_any) {
            self.reindexClaimsFrom(0) catch {};
            self.rebuildProjection() catch {};
        }
    }

    /// Get all registered providers. Caller owns the returned slice.
    /// pi-mono equivalent: getApiProviders()
    pub fn getAll(self: *const Registry, allocator: std.mem.Allocator) ![]Provider {
        const count = self.providers.count();
        const result = try allocator.alloc(Provider, count);
        var it = self.providers.valueIterator();
        var i: usize = 0;
        while (it.next()) |provider| {
            result[i] = provider.*;
            i += 1;
        }
        return result;
    }

    /// Clear all providers and dynamic claims.
    pub fn clear(self: *Registry) void {
        self.providers.clearRetainingCapacity();
        self.clearClaims();
        self.baseline.clearRetainingCapacity();
    }

    fn clearClaims(self: *Registry) void {
        for (self.claims.items) |*claim| claim.deinit(self.allocator);
        self.claims.deinit(self.allocator);

        var it = self.claim_index.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.claim_index.clearRetainingCapacity();
    }

    fn claimByName(self: *const Registry, provider_name: []const u8) ?*const Claim {
        const bucket = self.claim_index.get(provider_name) orelse return null;
        if (bucket.items.len == 0) return null;
        return &self.claims.items[bucket.items[0]];
    }

    fn reindexClaimsFrom(self: *Registry, start: usize) !void {
        _ = start;

        var bucket_it = self.claim_index.valueIterator();
        while (bucket_it.next()) |bucket| {
            bucket.clearRetainingCapacity();
        }

        for (self.claims.items, 0..) |claim, idx| {
            const bucket = self.claim_index.getPtr(claim.registration.name) orelse unreachable;
            try bucket.append(self.allocator, idx);
        }
    }

    fn findBucketIndex(items: []const usize, needle: usize) ?usize {
        for (items, 0..) |item, idx| {
            if (item == needle) return idx;
        }
        return null;
    }

    fn rebuildProjection(self: *Registry) !void {
        try self.providers.ensureTotalCapacity(@intCast(self.baseline.count() + self.claims.items.len));
        self.providers.clearRetainingCapacity();

        var baseline_it = self.baseline.iterator();
        while (baseline_it.next()) |entry| {
            try self.providers.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        for (self.claims.items) |claim| {
            try self.providers.put(claim.registration.api, claim.provider);
        }
    }
};

/// Convert Api to its string identifier for registry lookup.
pub fn apiToString(api: protocol.Api) []const u8 {
    return switch (api) {
        .openai_completions => "openai-completions",
        .mistral_conversations => "mistral-conversations",
        .openai_responses => "openai-responses",
        .azure_openai_responses => "azure-openai-responses",
        .openai_codex_responses => "openai-codex-responses",
        .anthropic_messages => "anthropic-messages",
        .bedrock_converse_stream => "bedrock-converse-stream",
        .google_generative_ai => "google-generative-ai",
        .google_gemini_cli => "google-gemini-cli",
        .google_vertex => "google-vertex",
        .custom => |s| s,
    };
}

const testing = std.testing;

const RecordingProvider = struct {
    allocator: std.mem.Allocator,
    name: []const u8,
    last_base_url: ?[]const u8 = null,

    const vtable: Provider.VTable = .{
        .stream = streamImpl,
        .stream_simple = streamSimpleImpl,
        .get_name = getNameImpl,
        .deinit = deinitImpl,
    };

    fn create(allocator: std.mem.Allocator, name: []const u8) !*RecordingProvider {
        const self = try allocator.create(RecordingProvider);
        self.* = .{ .allocator = allocator, .name = name };
        return self;
    }

    fn provider(self: *RecordingProvider) Provider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn getSelf(ptr: *anyopaque) *RecordingProvider {
        return @ptrCast(@alignCast(ptr));
    }

    fn streamImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        model: protocol.Model,
        _: protocol.Context,
        _: protocol.StreamOptions,
        _: EventCallback,
        _: ?*anyopaque,
    ) void {
        getSelf(ptr).last_base_url = model.base_url;
    }

    fn streamSimpleImpl(
        ptr: *anyopaque,
        _: std.mem.Allocator,
        model: protocol.Model,
        _: protocol.Context,
        _: protocol.SimpleStreamOptions,
        _: EventCallback,
        _: ?*anyopaque,
    ) void {
        getSelf(ptr).last_base_url = model.base_url;
    }

    fn getNameImpl(ptr: *anyopaque) []const u8 {
        return getSelf(ptr).name;
    }

    fn deinitImpl(ptr: *anyopaque) void {
        const self = getSelf(ptr);
        self.allocator.destroy(self);
    }
};

fn testModel(base_url: []const u8) protocol.Model {
    return testModelWithProvider(base_url, .anthropic_messages, .anthropic);
}

fn testModelWithProvider(base_url: []const u8, api: protocol.Api, provider: protocol.Provider) protocol.Model {
    return .{
        .id = "model",
        .name = "Model",
        .api = api,
        .provider = provider,
        .base_url = base_url,
        .reasoning = false,
        .input = &.{.text},
        .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 },
        .context_window = 1024,
        .max_tokens = 1024,
    };
}

fn noopEvent(_: protocol.AssistantMessageEvent, _: ?*anyopaque) void {}

test "Registry reapplies surviving provider claims and restores the baseline" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    const baseline = try RecordingProvider.create(testing.allocator, "baseline");
    try reg.register("anthropic-messages", baseline.provider(), null);

    const first_models = blk: {
        const models = try testing.allocator.alloc(ClaimModelRegistration, 1);
        models[0] = .{
            .id = try testing.allocator.dupe(u8, "claude-sonnet-4-20250514"),
            .name = try testing.allocator.dupe(u8, "Claude 4 Sonnet"),
            .reasoning = true,
            .input = try testing.allocator.dupe(protocol.Model.InputType, &.{ .text, .image }),
            .cost = .{ .input = 3, .output = 15, .cache_read = 0.3, .cache_write = 3.75 },
            .context_window = 200000,
            .max_tokens = 16384,
        };
        break :blk models;
    };

    const first = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "proxy-a"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy-a.example"),
        .oauth_enabled = true,
        .oauth_name = try testing.allocator.dupe(u8, "Proxy Login"),
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
        .generation = 1,
        .models = first_models,
    };
    try testing.expect(try reg.registerClaim(first));

    const second = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "proxy-b"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy-b.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-b"),
        .generation = 1,
    };
    try testing.expect(try reg.registerClaim(second));

    try testing.expectEqual(@as(usize, 2), reg.activeClaimCount());
    const active_first = reg.activeClaimRegistrationAt(0);
    try testing.expectEqualStrings("proxy-a", active_first.name);
    try testing.expect(active_first.oauth_enabled);
    try testing.expectEqualStrings("Proxy Login", active_first.oauth_name.?);
    try testing.expectEqual(@as(usize, 1), active_first.models.len);
    try testing.expectEqualStrings("claude-sonnet-4-20250514", active_first.models[0].id);
    try testing.expectEqualStrings("Claude 4 Sonnet", active_first.models[0].name);
    try testing.expectEqual(@as(usize, 2), active_first.models[0].input.len);

    reg.get("anthropic-messages").?.streamSimple(
        testing.allocator,
        testModel("https://baseline.example"),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://proxy-b.example", baseline.last_base_url.?);

    try testing.expect(!(try reg.unregisterClaim("proxy-b", "ext-a", 1)));
    try testing.expect(try reg.unregisterClaim("proxy-b", "ext-b", 1));
    try testing.expectEqual(@as(usize, 1), reg.activeClaimCount());

    reg.get("anthropic-messages").?.streamSimple(
        testing.allocator,
        testModel("https://baseline.example"),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://proxy-a.example", baseline.last_base_url.?);

    try testing.expect(try reg.unregisterClaim("proxy-a", "ext-a", 1));
    try testing.expectEqual(@as(usize, 0), reg.activeClaimCount());

    reg.get("anthropic-messages").?.streamSimple(
        testing.allocator,
        testModel("https://baseline.example"),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://baseline.example", baseline.last_base_url.?);

    baseline.provider().deinit();
}

test "Registry resolves provider claims by provider name before api projection" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    const baseline = try RecordingProvider.create(testing.allocator, "baseline");
    try reg.register("openai-responses", baseline.provider(), null);

    const claim = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "openai"),
        .api = try testing.allocator.dupe(u8, "openai-responses"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-openai"),
        .generation = 1,
    };
    try testing.expect(try reg.registerClaim(claim));
    try testing.expectEqualStrings("openai", reg.get("openai-responses").?.getName());

    reg.getForModel("openai-responses", "openai").?.streamSimple(
        testing.allocator,
        testModelWithProvider("https://baseline.example", .openai_responses, .openai),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://proxy.example", baseline.last_base_url.?);

    reg.getForModel("openai-responses", "github-copilot").?.streamSimple(
        testing.allocator,
        testModelWithProvider("https://baseline.example", .openai_responses, .github_copilot),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://baseline.example", baseline.last_base_url.?);

    baseline.provider().deinit();
}

test "Registry teardown drops one generation and restores surviving same-name claim" {
    var reg = Registry.init(testing.allocator);
    defer reg.deinit();

    const baseline = try RecordingProvider.create(testing.allocator, "baseline");
    try reg.register("anthropic-messages", baseline.provider(), null);

    const first = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "anthropic"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://gen1.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-gen1"),
        .generation = 1,
    };
    try testing.expect(try reg.registerClaim(first));

    const second = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "anthropic"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://gen2.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-gen1"),
        .generation = 2,
    };
    try testing.expect(try reg.registerClaim(second));

    try testing.expectEqual(@as(usize, 2), reg.activeClaimCount());
    try testing.expectEqualStrings("https://gen1.example", reg.activeClaimRegistrationByName("anthropic").?.base_url);

    try reg.unregisterClaimsByGeneration(1);

    try testing.expectEqual(@as(usize, 1), reg.activeClaimCount());
    try testing.expectEqualStrings("https://gen2.example", reg.activeClaimRegistrationByName("anthropic").?.base_url);
    try testing.expectEqualStrings("anthropic", reg.get("anthropic-messages").?.getName());

    reg.getForModel("anthropic-messages", "anthropic").?.streamSimple(
        testing.allocator,
        testModelWithProvider("https://baseline.example", .anthropic_messages, .anthropic),
        .{ .messages = &.{} },
        .{},
        &noopEvent,
        null,
    );
    try testing.expectEqualStrings("https://gen2.example", baseline.last_base_url.?);

    try reg.unregisterClaimsByGeneration(2);
    try testing.expectEqual(@as(usize, 0), reg.activeClaimCount());
    try testing.expect(reg.activeClaimRegistrationByName("anthropic") == null);
    try testing.expectEqualStrings("baseline", reg.get("anthropic-messages").?.getName());

    baseline.provider().deinit();
}
