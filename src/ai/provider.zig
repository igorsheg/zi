const std = @import("std");
const protocol = @import("protocol.zig");

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

pub const ClaimRegistration = struct {
    name: []const u8,
    api: []const u8,
    base_url: []const u8,
    owner_id: []const u8,
    generation: u64,

    pub fn deinit(self: *ClaimRegistration, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.api);
        allocator.free(self.base_url);
        allocator.free(self.owner_id);
        self.* = undefined;
    }
};

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
    claim_index: std.StringHashMap(usize),
    claims: std.ArrayListUnmanaged(Claim) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{
            .providers = std.StringHashMap(Provider).init(allocator),
            .baseline = std.StringHashMap(Provider).init(allocator),
            .claim_index = std.StringHashMap(usize).init(allocator),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Registry) void {
        self.providers.deinit();
        self.clearClaims();
        self.baseline.deinit();

        var it = self.claim_index.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
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

        if (self.claim_index.get(claim.registration.name)) |idx| {
            const existing = &self.claims.items[idx];
            if (!std.mem.eql(u8, existing.registration.owner_id, claim.registration.owner_id)) {
                return false;
            }

            var old = existing.*;
            existing.* = claim;
            errdefer existing.* = old;
            try self.rebuildProjection();
            old.deinit(self.allocator);
            return true;
        }

        const idx = self.claims.items.len;
        try self.claims.append(self.allocator, claim);
        errdefer _ = self.claims.pop();

        const key_dup = try self.allocator.dupe(u8, claim.registration.name);
        errdefer self.allocator.free(key_dup);

        try self.claim_index.put(key_dup, idx);
        errdefer if (self.claim_index.fetchRemove(claim.registration.name)) |removed| {
            self.allocator.free(removed.key);
        };

        try self.rebuildProjection();
        return true;
    }

    pub fn unregisterClaim(self: *Registry, name: []const u8, owner_id: []const u8, generation: u64) !bool {
        const idx = self.claim_index.get(name) orelse return false;
        const existing = self.claims.items[idx];
        if (!std.mem.eql(u8, existing.registration.owner_id, owner_id)) return false;
        if (existing.registration.generation != generation) return false;

        var removed = self.claims.orderedRemove(idx);

        const index_entry = self.claim_index.fetchRemove(name) orelse unreachable;
        defer self.allocator.free(index_entry.key);

        self.reindexClaimsFrom(idx);
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

            var removed = self.claims.orderedRemove(i);
            const index_entry = self.claim_index.fetchRemove(removed.registration.name) orelse unreachable;
            self.allocator.free(index_entry.key);
            removed.deinit(self.allocator);
            removed_any = true;
        }
        if (removed_any) {
            self.reindexClaimsFrom(0);
            try self.rebuildProjection();
        }
    }

    /// Look up provider by API identifier.
    pub fn get(self: *const Registry, api: []const u8) ?Provider {
        return self.providers.get(api);
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

            var removed = self.claims.orderedRemove(i);
            const index_entry = self.claim_index.fetchRemove(removed.registration.name) orelse unreachable;
            self.allocator.free(index_entry.key);
            removed.deinit(self.allocator);
            removed_any = true;
        }
        if (removed_any) {
            self.reindexClaimsFrom(0);
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
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.claim_index.clearRetainingCapacity();
    }

    fn reindexClaimsFrom(self: *Registry, start: usize) void {
        var i = start;
        while (i < self.claims.items.len) : (i += 1) {
            const value = self.claim_index.getPtr(self.claims.items[i].registration.name) orelse unreachable;
            value.* = i;
        }
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
    return .{
        .id = "model",
        .name = "Model",
        .api = .anthropic_messages,
        .provider = .anthropic,
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

    const first = ClaimRegistration{
        .name = try testing.allocator.dupe(u8, "proxy-a"),
        .api = try testing.allocator.dupe(u8, "anthropic-messages"),
        .base_url = try testing.allocator.dupe(u8, "https://proxy-a.example"),
        .owner_id = try testing.allocator.dupe(u8, "ext-a"),
        .generation = 1,
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
