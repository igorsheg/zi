const std = @import("std");
const ai = @import("ai/root.zig");
const config = @import("config/root.zig");
const ProviderHeaders = @import("ProviderHeaders.zig");

const ApiKey = config.ApiKey;
const Settings = config.Settings;
const Store = config.Store;
const Document = config.Document;
const Registry = ai.ProviderRegistry;
const ProviderDefinitions = config.ProviderDefinitions;
const Definition = ProviderDefinitions.Definition;

/// Borrowed synchronous access to an already available model catalog snapshot.
/// Implementations must not start or wait for network work. The returned value
/// owns all of its variable data inline.
pub const ModelHintsSource = struct {
    context: *anyopaque,
    lookup_fn: *const fn (
        std.mem.Allocator,
        *anyopaque,
        []const u8,
        []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution,
    lookup_batch_fn: ?*const fn (
        std.mem.Allocator,
        *anyopaque,
        []const u8,
        []const []const u8,
        []ai.ModelCatalog.Contribution,
    ) error{OutOfMemory}!void = null,

    pub fn from(implementation: anytype) ModelHintsSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("ModelHintsSource.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn lookupFn(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                provider_id: []const u8,
                model_id: []const u8,
            ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.lookup(allocator, provider_id, model_id);
            }

            fn lookupBatchFn(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                provider_id: []const u8,
                model_ids: []const []const u8,
                output: []ai.ModelCatalog.Contribution,
            ) error{OutOfMemory}!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.lookupBatch(allocator, provider_id, model_ids, output);
            }
        };
        return .{
            .context = implementation,
            .lookup_fn = Adapter.lookupFn,
            .lookup_batch_fn = if (@hasDecl(Implementation, "lookupBatch")) Adapter.lookupBatchFn else null,
        };
    }

    pub fn lookup(
        self: ModelHintsSource,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
        model_id: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        return self.lookup_fn(allocator, self.context, provider_id, model_id);
    }

    /// Uses one source snapshot when supported. Older implementations retain
    /// scalar behavior through the bounded fallback.
    pub fn lookupBatch(
        self: ModelHintsSource,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
        model_ids: []const []const u8,
        output: []ai.ModelCatalog.Contribution,
    ) error{OutOfMemory}!void {
        std.debug.assert(model_ids.len == output.len);
        std.debug.assert(model_ids.len <= ai.ModelListing.maximum_models);
        if (self.lookup_batch_fn) |lookup_batch| {
            return lookup_batch(allocator, self.context, provider_id, model_ids, output);
        }
        for (model_ids, output) |model_id, *destination| {
            destination.* = try self.lookup(allocator, provider_id, model_id);
        }
    }
};

pub const LlamaModelReconciliation = union(enum) {
    unchanged,
    clear,
    replace: []const u8,
};

pub const HttpPolicy = struct {
    /// Additional attempts after the initial request.
    max_retries: u16 = 4,
    retry_base_ms: u64 = 1_000,
    /// Zero disables the streaming idle timeout.
    idle_timeout_ms: u64 = 10 * 60 * 1_000,
};

pub const PreparedHeaders = struct {
    provider_id: []const u8,
    headers: []const ai.Transport.Header,
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    store: Store,
    api_key_environment: ApiKey.Environment,
    provider_override: ?[]const u8 = null,
    /// Borrowed definitions. Matching values are copied into Owned.
    provider_definitions: []const Definition = &.{},
    /// Availability snapshots supplied by the caller. Resolution never probes.
    codex_available: bool = false,
    llamacpp_available: bool = false,
    ollama_available: bool = false,
    session_cache_key: ?[]const u8 = null,
    /// Borrowed stable implementation. Its context must outlive the returned
    /// Owned and every provider operation which can invoke it.
    codex_source: ?ai.CodexCredentialSource = null,
    default_model: ?[]const u8 = null,
    default_effort: ?[]const u8 = null,
    /// Result of a successful llama.cpp `/models` reconciliation. This outranks
    /// the configured model because classic servers may substitute what they
    /// actually serve and routers may canonicalize or clear a configured ID.
    llama_reconciliation: ?LlamaModelReconciliation = null,
    llama_discovered_model: ?[]const u8 = null,
    ollama_discovered_model: ?[]const u8 = null,
    /// Optional foreground-resolved snapshot, used when availability probing
    /// already needed this provider's headers. A matching snapshot is copied;
    /// its warnings remain the caller's responsibility. Every other selected
    /// provider is resolved here and exposes warnings through `Owned`.
    prepared_headers: ?PreparedHeaders = null,
    /// Optional cache-only catalog lookup. It is called once, after provider
    /// and model selection, with the effective catalog provider ID (or the
    /// selected provider ID when catalog metadata is disabled). `hints.reported`
    /// is never sourced here. Explicit
    /// catalog metadata wins source metadata field by field. An explicit
    /// non-unknown `catalog_wire` wins as one tagged value; otherwise an
    /// explicit catalog metadata `.wire` wins before the source wire may fill.
    hints_source: ?ModelHintsSource = null,
    hints: Registry.ModelHints = .{},
    rules: Registry.Rules = .{},
    http_policy: HttpPolicy = .{},
    /// Listing-only runtimes may resolve an adapter before a model has been
    /// chosen. The placeholder never becomes a streaming run selection.
    listing_only: bool = false,
};

pub const maximum_provider_choices: usize = ProviderDefinitions.maximum_definitions + Registry.order().len;
pub const maximum_provider_choice_bytes: usize = ProviderDefinitions.maximum_retained_bytes;

pub const ProviderChoice = struct {
    id: []const u8,
    label: []const u8,
    available: bool,
    reason: ?[]const u8,
};

const ProviderChoiceOwner = struct {
    parent_allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
};

pub const ProviderChoices = struct {
    values: []const ProviderChoice,
    owner: *ProviderChoiceOwner,

    pub fn deinit(self: *ProviderChoices) void {
        const owner = self.owner;
        const allocator = owner.parent_allocator;
        owner.arena.deinit();
        owner.* = undefined;
        allocator.destroy(owner);
        self.* = undefined;
    }
};

/// Returns the selectable compiled registry followed by config-only providers.
/// Registry order remains automatic-selection priority. Presentation may sort
/// this owned result without changing that order.
pub fn providerChoices(parent_allocator: std.mem.Allocator, inputs: Inputs) !ProviderChoices {
    const owner = try parent_allocator.create(ProviderChoiceOwner);
    errdefer parent_allocator.destroy(owner);
    owner.* = .{ .parent_allocator = parent_allocator, .arena = .init(parent_allocator) };
    errdefer owner.arena.deinit();
    const allocator = owner.arena.allocator();
    var values: std.ArrayList(ProviderChoice) = .empty;
    defer values.deinit(allocator);
    var retained_bytes: usize = 0;

    for (Registry.order()) |descriptor| {
        if (!descriptor.selectable) continue;
        try appendProviderChoice(allocator, &values, &retained_bytes, inputs, descriptor.id, descriptor.display_name);
    }
    for (inputs.provider_definitions) |definition| {
        if (!validDynamicId(definition.id) or Registry.find(definition.id) != null) continue;
        const label = if (definition.display_name) |value|
            if (value.len != 0) value else definition.id
        else
            definition.id;
        try appendProviderChoice(allocator, &values, &retained_bytes, inputs, definition.id, label);
    }
    return .{ .values = try values.toOwnedSlice(allocator), .owner = owner };
}

fn appendProviderChoice(
    allocator: std.mem.Allocator,
    values: *std.ArrayList(ProviderChoice),
    retained_bytes: *usize,
    inputs: Inputs,
    id: []const u8,
    fallback_label: []const u8,
) !void {
    const definition = findDefinition(inputs.provider_definitions, id);
    const label_source = if (definition) |value|
        if (value.display_name) |label| if (label.len != 0) label else fallback_label else fallback_label
    else
        fallback_label;
    const available = providerAvailable(allocator, inputs, id) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => false,
    };
    const reason_source: ?[]const u8 = if (available) null else try unavailableReason(allocator, id, definition);
    if (values.items.len == maximum_provider_choices) return error.TooManyProviderChoices;
    var added_bytes = std.math.add(usize, id.len, label_source.len) catch return error.ProviderChoicesTooLarge;
    if (reason_source) |reason| {
        added_bytes = std.math.add(usize, added_bytes, reason.len) catch return error.ProviderChoicesTooLarge;
    }
    const next_retained = std.math.add(usize, retained_bytes.*, added_bytes) catch
        return error.ProviderChoicesTooLarge;
    if (next_retained > maximum_provider_choice_bytes) return error.ProviderChoicesTooLarge;
    try values.append(allocator, .{
        .id = try allocator.dupe(u8, id),
        .label = try allocator.dupe(u8, label_source),
        .available = available,
        .reason = reason_source,
    });
    retained_bytes.* = next_retained;
}

fn unavailableReason(
    allocator: std.mem.Allocator,
    id: []const u8,
    definition: ?Definition,
) ![]const u8 {
    if (definition) |value| if (definitionDeclaresKey(&value)) {
        if (value.api_key_env) |name| if (name.len != 0) {
            return std.fmt.allocPrint(allocator, "{s} not set", .{name});
        };
        return std.fmt.allocPrint(allocator, "providers.{s}.api_key not set", .{id});
    };
    if (std.mem.eql(u8, id, "codex")) return "not logged in (use /login)";
    if (std.mem.eql(u8, id, "llamacpp") or std.mem.eql(u8, id, "ollama")) {
        return "server not reachable";
    }
    if (std.mem.eql(u8, id, "openai")) return "OPENAI_API_KEY not set";
    if (std.mem.eql(u8, id, "anthropic")) return "ANTHROPIC_API_KEY not set";
    if (std.mem.eql(u8, id, "openrouter")) return "OPENROUTER_API_KEY not set";
    if (std.mem.eql(u8, id, "openai-compatible")) return "ZI_OPENAI_BASE_URL not set";
    if (std.mem.eql(u8, id, "anthropic-compatible")) return "ZI_ANTHROPIC_BASE_URL not set";
    if (isOpenCode(id)) return "OPENCODE_API_KEY not set";
    return "provider is not configured";
}

pub const ResolveError = error{
    OutOfMemory,
    Cancelled,
    SecretTooLong,
    InvalidHeaderValue,
    InvalidProviderId,
    UnknownProvider,
    InvalidModelId,
    InvalidAuth,
    InvalidOverride,
    TooManyRules,
    InvalidRule,
    AdapterUnavailable,
    ProviderUnavailable,
    UnsupportedWire,
    MissingSessionCacheKey,
    MissingProvider,
    MissingCredential,
    MissingModel,
    InvalidSetting,
    UnsupportedSetting,
};

const WipingAllocator = struct {
    backing: std.mem.Allocator,

    fn allocator(self: *WipingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        // Refuse shrinking because the backing allocator could release the tail
        // before it is wiped. Arena growth does not need in-place shrinking.
        if (new_len < memory.len) return false;
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(_: *anyopaque, _: []u8, _: std.mem.Alignment, _: usize, _: usize) ?[*]u8 {
        return null;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *WipingAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

/// Stable, heap-addressed provider composition. Every borrowed resolver input
/// retained by the registry plan is copied into this object's wiping arena. A
/// plan-owned endpoint uses the wiping allocator directly so a successful swap
/// can release it. `codex_source` is borrowed, not owned, and must follow the
/// lifetime rule on Inputs. The resolved field has a final stable address
/// suitable for a separately stable ProviderFactory.Owner. Call `deinit` exactly once.
pub const Owned = struct {
    parent_allocator: std.mem.Allocator,
    wiping_allocator: WipingAllocator,
    arena: std.heap.ArenaAllocator,
    resolved: Registry.Resolved,
    model: []const u8,
    /// Original requested policy before catalog-dependent clamping. An empty
    /// slice is an explicit clear; null means no requested policy.
    requested_effort: ?[]const u8,
    effort: ?[]const u8,
    keep_model_order: bool,
    provider_autoselected: bool,
    model_discovered: bool,
    /// Null for ordinary resolution. A listing-only placeholder is never a
    /// safe provider default and must not be committed as a model choice.
    listing_default_model: ?[]const u8,
    /// Pure resolver inputs retained so an authoritative catalog result can
    /// transactionally rebuild the complete adapter plan without borrowing the
    /// caller's configuration.
    descriptor: *const Registry.Descriptor,
    auth: Registry.Auth,
    overrides: Registry.Overrides,
    rules: Registry.Rules,
    http_policy: HttpPolicy,
    reported_metadata: ai.ModelMeta.Metadata,
    header_warnings: []const ProviderHeaders.Warning,
    explicit_catalog_metadata: ai.ModelCatalog.Contribution,
    catalog_contribution: ai.ModelCatalog.Contribution,
    catalog_authoritative: bool,

    /// Replaces request policy in the retained adapter between provider calls.
    /// Validation completes before the adapter or retained rebuild policy changes.
    pub fn updateHttpPolicy(self: *Owned, policy: HttpPolicy) error{InvalidSetting}!void {
        try validateHttpPolicy(policy);
        self.publishHttpPolicy(policy);
    }

    pub fn publishHttpPolicy(self: *Owned, policy: HttpPolicy) void {
        std.debug.assert(policy.max_retries <= 100);
        applyHttpPolicy(&self.resolved.adapter, policy);
        self.http_policy = policy;
    }

    /// Updates only adapters whose request schema has an explicit reasoning
    /// visibility field. Other adapters must not gain an unrelated body field.
    pub fn updateShowReasoning(self: *Owned, visible: bool) void {
        self.overrides.show_reasoning = visible;
        switch (self.resolved.adapter) {
            .anthropic_messages => |*plan| plan.body.show_reasoning = visible,
            else => {},
        }
    }

    /// True only before an authoritative lookup when an unknown catalog wire can
    /// change the effective routing decision for this model.
    pub fn catalogWirePending(self: *const Owned) bool {
        if (self.catalog_authoritative) return false;
        const catalog = ai.ModelCatalog.merge(
            &self.explicit_catalog_metadata,
            &self.catalog_contribution,
        );
        const hints: Registry.ModelHints = .{
            .reported = &self.reported_metadata,
            .catalog = &catalog.metadata,
            .catalog_wire = registryWireHint(catalog.wire),
        };
        return Registry.catalogWirePending(
            self.descriptor,
            self.model,
            self.overrides,
            hints,
            self.rules,
        ) catch unreachable;
    }

    /// Rebuilds the complete plan from retained inputs. Explicit catalog facts
    /// win field by field over this authoritative contribution. The stable
    /// `resolved` field address changes value only after the new plan succeeds.
    pub fn applyAuthoritativeCatalog(
        self: *Owned,
        contribution: ai.ModelCatalog.Contribution,
    ) ResolveError!void {
        const catalog = ai.ModelCatalog.merge(&self.explicit_catalog_metadata, &contribution);
        const hints: Registry.ModelHints = .{
            .reported = &self.reported_metadata,
            .catalog = &catalog.metadata,
            .catalog_wire = registryWireHint(catalog.wire),
        };
        var next = try Registry.resolveDescriptor(
            self.wiping_allocator.allocator(),
            self.descriptor,
            self.model,
            self.auth,
            self.overrides,
            hints,
            self.rules,
        );
        errdefer next.deinit();
        applyHttpPolicy(&next.adapter, self.http_policy);
        const effort_allocator = self.wiping_allocator.allocator();
        const next_effort = try clampEffort(
            effort_allocator,
            self.requested_effort,
            &next,
        );
        errdefer freeEffort(effort_allocator, next_effort);

        var previous = self.resolved;
        const previous_effort = self.effort;
        self.resolved = next;
        self.effort = next_effort;
        self.catalog_contribution = contribution;
        self.catalog_authoritative = true;
        previous.deinit();
        freeEffort(effort_allocator, previous_effort);
    }

    pub fn deinit(self: *Owned) void { // ziglint-ignore: Z030
        const parent = self.parent_allocator;
        self.resolved.deinit();
        freeEffort(self.wiping_allocator.allocator(), self.effort);
        self.arena.deinit();
        self.* = undefined;
        parent.destroy(self);
    }
};

pub fn resolve(inputs: Inputs) ResolveError!*Owned {
    try validateHttpPolicy(inputs.http_policy);
    const owned = try inputs.allocator.create(Owned);
    errdefer inputs.allocator.destroy(owned);
    owned.parent_allocator = inputs.allocator;
    owned.wiping_allocator = .{ .backing = inputs.allocator };
    owned.arena = .init(owned.wiping_allocator.allocator());
    errdefer owned.arena.deinit();
    const allocator = owned.arena.allocator();

    const selection = try selectProvider(allocator, inputs);
    const provider = selection.id;
    const compiled_descriptor = Registry.find(provider);
    const definition = findDefinition(inputs.provider_definitions, provider);
    const dynamic = compiled_descriptor == null;
    const descriptor = if (compiled_descriptor) |value| blk: {
        if (!isSupportedPlan(value.id)) return error.UnknownProvider;
        break :blk try copyDescriptor(allocator, value);
    } else try dynamicDescriptor(allocator, definition orelse return error.UnknownProvider);

    var overrides: Registry.Overrides = .{
        .session_cache_key = if (inputs.session_cache_key) |value| try allocator.dupe(u8, value) else null,
        .show_reasoning = (try Settings.getBool(inputs.store, allocator, "show_reasoning")).value,
    };
    if (dynamic) {
        const value = definition orelse unreachable;
        try validateRecipeDefinition(value.id, &value);
        try applyDefinition(allocator, value.id, value, &overrides);
    } else if (descriptor.kind == .recipe) {
        if (definition) |value| {
            const effective = try definitionWithEnvironmentApi(allocator, inputs.store, descriptor.id, value);
            try validateRecipeDefinition(descriptor.id, &effective);
        }
        try applyDefinition(allocator, descriptor.id, definition, &overrides);
    }
    const header_resolution: ProviderHeaders.Resolution = if (inputs.prepared_headers) |prepared|
        if (std.mem.eql(u8, prepared.provider_id, descriptor.id))
            .{
                .headers = try copyHeaders(allocator, prepared.headers),
                .warnings = &.{},
            }
        else
            try ProviderHeaders.resolve(allocator, definition, inputs.api_key_environment)
    else
        try ProviderHeaders.resolve(allocator, definition, inputs.api_key_environment);
    overrides.extra_headers = header_resolution.headers;
    owned.header_warnings = header_resolution.warnings;
    const auth = if (dynamic) blk: {
        const value = definition orelse unreachable;
        break :blk try definitionAuth(allocator, inputs, &value, null, false, false);
    } else try configure(
        allocator,
        inputs,
        descriptor.id,
        definition,
        &overrides,
        !selection.explicit,
    );
    const model = try selectModel(allocator, inputs.store, descriptor.id, inputs);

    // Retain every hint source by value. The cache-only contribution is an
    // initial fallback and is replaced by an authoritative late result.
    owned.reported_metadata = if (inputs.hints.reported) |value| value.* else .{};
    owned.explicit_catalog_metadata = .{
        .metadata = if (inputs.hints.catalog) |value| value.* else .{},
        .wire = explicitCatalogWireHint(inputs.hints),
    };
    owned.catalog_contribution = .{};
    if (inputs.hints_source) |source| {
        const lookup_provider_id = if (overrides.catalog_id) |value|
            if (value.len == 0) descriptor.id else value
        else
            descriptor.catalog_id orelse descriptor.id;
        owned.catalog_contribution = try source.lookup(allocator, lookup_provider_id, model);
    }
    const merged_contribution = ai.ModelCatalog.merge(
        &owned.explicit_catalog_metadata,
        &owned.catalog_contribution,
    );
    const effective_hints: Registry.ModelHints = .{
        .reported = &owned.reported_metadata,
        .catalog = &merged_contribution.metadata,
        .catalog_wire = registryWireHint(merged_contribution.wire),
    };

    const rules = if (dynamic or descriptor.kind == .recipe) blk: {
        try validateCombinedRules(descriptor.id, definition, inputs.rules, model);
        break :blk try mergeRules(allocator, descriptor.id, definition, inputs.rules);
    } else blk: {
        try Registry.validateRules(inputs.rules, model);
        break :blk try copyRules(allocator, inputs.rules);
    };

    owned.descriptor = descriptor;
    owned.auth = auth;
    owned.overrides = overrides;
    owned.rules = rules;
    owned.http_policy = inputs.http_policy;
    owned.catalog_authoritative = false;
    owned.resolved = try Registry.resolveDescriptor(
        owned.wiping_allocator.allocator(),
        owned.descriptor,
        model,
        owned.auth,
        owned.overrides,
        effective_hints,
        owned.rules,
    );
    errdefer owned.resolved.deinit();
    applyHttpPolicy(&owned.resolved.adapter, owned.http_policy);
    owned.model = owned.resolved.metadata.model_id;
    owned.requested_effort = try selectRequestedEffort(allocator, inputs.store, descriptor.id, inputs);
    owned.effort = try clampEffort(
        owned.wiping_allocator.allocator(),
        owned.requested_effort,
        &owned.resolved,
    );
    errdefer freeEffort(owned.wiping_allocator.allocator(), owned.effort);
    owned.keep_model_order = !(if (definition) |value| value.sort_models orelse true else true);
    owned.provider_autoselected = !selection.explicit;
    owned.model_discovered = std.mem.eql(u8, descriptor.id, "llamacpp") and
        ((if (inputs.llama_reconciliation) |value| switch (value) {
            .replace => true,
            .unchanged, .clear => false,
        } else false) or
            (if (inputs.llama_discovered_model) |value| std.mem.eql(u8, value, model) else false));
    owned.listing_default_model = if (inputs.listing_only and
        std.mem.eql(u8, model, listing_model_placeholder)) null else model;
    return owned;
}

fn validateHttpPolicy(policy: HttpPolicy) error{InvalidSetting}!void {
    if (policy.max_retries > 100) return error.InvalidSetting;
}

fn applyHttpPolicy(adapter: *Registry.AdapterPlan, policy: HttpPolicy) void {
    switch (adapter.*) {
        // The mock provider performs no HTTP; retry and timeout policy are moot.
        .mock => {},
        inline else => |*plan| {
            plan.retry.policy.max_attempts = policy.max_retries + 1;
            plan.retry.policy.base_delay_ms = policy.retry_base_ms;
            plan.limits.idle_timeout_ms = policy.idle_timeout_ms;
        },
    }
}

fn explicitCatalogWireHint(hints: Registry.ModelHints) ai.ModelCatalog.WireHint {
    return switch (hints.catalog_wire) {
        .unknown => if (hints.catalog) |catalog|
            if (catalog.wire) |wire| .{ .wire = wire } else .unknown
        else
            .unknown,
        .unsupported => .unsupported,
        .wire => |wire| .{ .wire = wire },
    };
}

fn registryWireHint(hint: ai.ModelCatalog.WireHint) Registry.WireHint {
    return switch (hint) {
        .unknown => .unknown,
        .unsupported => .unsupported,
        .wire => |wire| .{ .wire = wire },
    };
}

const ProviderSelection = struct { id: []const u8, explicit: bool };

fn selectProvider(allocator: std.mem.Allocator, inputs: Inputs) !ProviderSelection {
    if (inputs.provider_override) |value| {
        if (value.len != 0) return .{ .id = try allocator.dupe(u8, canonical(value)), .explicit = true };
    } else {
        const selected = try inputs.store.read(allocator, "provider");
        if (selected.value) |value| {
            if (value.len != 0) return .{ .id = try allocator.dupe(u8, canonical(value)), .explicit = true };
        }
    }

    const order = [_][]const u8{
        "codex",
        "llamacpp",
        "openai",
        "anthropic",
        "openrouter",
        "openai-compatible",
        "anthropic-compatible",
        "opencode-zen",
        "opencode-go",
        "ollama",
    };
    for (order) |provider| {
        if (try providerAvailable(allocator, inputs, provider)) {
            return .{ .id = try allocator.dupe(u8, provider), .explicit = false };
        }
    }
    for (inputs.provider_definitions) |definition| {
        // Compiled descriptors stay in their fixed positions. A matching
        // definition overlays that descriptor instead of adding a duplicate.
        if (!validDynamicId(definition.id)) continue;
        if (Registry.find(definition.id) != null) continue;
        if (try dynamicAvailable(allocator, inputs, definition)) {
            return .{ .id = try allocator.dupe(u8, definition.id), .explicit = false };
        }
    }
    return error.MissingProvider;
}

fn providerAvailable(allocator: std.mem.Allocator, inputs: Inputs, provider: []const u8) !bool {
    if (std.mem.eql(u8, provider, "codex")) {
        try validateProviderFields(
            inputs.store,
            "providers.codex",
            if (findDefinition(inputs.provider_definitions, provider) != null)
                &.{"extra_headers"}
            else
                &.{},
        );
        return inputs.codex_available and inputs.codex_source != null;
    }
    if (std.mem.eql(u8, provider, "llamacpp")) return inputs.llamacpp_available;
    if (std.mem.eql(u8, provider, "openai")) {
        return hasKey(allocator, inputs, "providers.openai.api_key", "OPENAI_API_KEY");
    }
    if (std.mem.eql(u8, provider, "anthropic")) {
        return hasKey(allocator, inputs, "providers.anthropic.api_key", "ANTHROPIC_API_KEY");
    }
    if (std.mem.eql(u8, provider, "openrouter")) {
        return hasKey(allocator, inputs, "providers.openrouter.api_key", "OPENROUTER_API_KEY");
    }
    if (isOpenCode(provider)) {
        const definition = findDefinition(inputs.provider_definitions, provider);
        if (definition) |value| return definitionHasKey(allocator, inputs, &value, "OPENCODE_API_KEY");
        const setting = if (std.mem.eql(u8, provider, "opencode-zen"))
            "providers.opencode-zen.api_key"
        else
            "providers.opencode-go.api_key";
        return hasKey(allocator, inputs, setting, "OPENCODE_API_KEY");
    }
    if (std.mem.eql(u8, provider, "ollama")) {
        if (findDefinition(inputs.provider_definitions, provider)) |definition| {
            if (definitionDeclaresKey(&definition))
                return definitionHasKey(allocator, inputs, &definition, null);
        }
        return inputs.ollama_available;
    }
    if (findDefinition(inputs.provider_definitions, provider)) |definition| {
        if (definitionDeclaresKey(&definition))
            return definitionHasKey(allocator, inputs, &definition, null);
        if (definition.base_url) |value| if (value.len != 0) return true;
    }
    const base_key = if (std.mem.eql(u8, provider, "openai-compatible"))
        "providers.openai-compatible.base_url"
    else
        "providers.anthropic-compatible.base_url";
    return (try optionalSetting(allocator, inputs.store, base_key)) != null;
}

fn dynamicAvailable(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    definition: Definition,
) ResolveError!bool {
    try validateRecipeDefinition(definition.id, &definition);
    const base_url = definition.base_url orelse return false;
    if (base_url.len == 0) return false;
    if (!definitionDeclaresKey(&definition)) return true;
    return definitionHasKey(allocator, inputs, &definition, null);
}

fn hasKey(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    setting: []const u8,
    fallback: []const u8,
) !bool {
    const inline_result = try inputs.store.readNonempty(allocator, setting);
    var secret = try ApiKey.resolve(allocator, .{
        .inline_value = inline_result.value,
        .fallback_env_name = fallback,
        .environment = inputs.api_key_environment,
    });
    defer if (secret) |*value| value.deinit(allocator);
    return secret != null;
}

const listing_model_placeholder = "zi-listing-candidate";

fn selectModel(
    allocator: std.mem.Allocator,
    store: Store,
    provider: []const u8,
    inputs: Inputs,
) ![]const u8 {
    if (std.mem.eql(u8, provider, "llamacpp")) if (inputs.llama_reconciliation) |decision| {
        switch (decision) {
            .unchanged => {},
            .clear => return error.MissingModel,
            .replace => |model| return allocator.dupe(u8, model),
        }
    };
    const selected = try store.readForProvider(allocator, "model", provider);
    if (selected.value) |value| if (value.len != 0) return allocator.dupe(u8, value);
    const fallback = if (std.mem.eql(u8, provider, "codex"))
        inputs.default_model
    else if (std.mem.eql(u8, provider, "llamacpp"))
        inputs.llama_discovered_model
    else if (std.mem.eql(u8, provider, "ollama"))
        inputs.ollama_discovered_model
    else if (std.mem.eql(u8, provider, "mock"))
        // hax's mock provider default model; a configured model still wins.
        @as(?[]const u8, "mock-model")
    else
        null;
    if (fallback) |value| return allocator.dupe(u8, value);
    if (inputs.listing_only) return allocator.dupe(u8, listing_model_placeholder);
    return error.MissingModel;
}

fn selectRequestedEffort(
    allocator: std.mem.Allocator,
    store: Store,
    provider: []const u8,
    inputs: Inputs,
) !?[]const u8 {
    const selected = try store.readForProvider(allocator, "effort", provider);
    if (selected.value) |value| return value;
    if (selected.source != .default) return null;
    if (!std.mem.eql(u8, provider, "codex")) return null;
    const fallback = inputs.default_effort orelse return null;
    const copy: []const u8 = try allocator.dupe(u8, fallback);
    return copy;
}

fn clampEffort(
    allocator: std.mem.Allocator,
    requested: ?[]const u8,
    resolved: *const Registry.Resolved,
) !?[]const u8 {
    const value = requested orelse return null;
    const clamped = resolved.metadata.efforts.clamp(value) orelse return null;
    if (clamped.len == 0) return "";
    const copy: []const u8 = try allocator.dupe(u8, clamped);
    return copy;
}

fn freeEffort(allocator: std.mem.Allocator, effort: ?[]const u8) void {
    const value = effort orelse return;
    if (value.len == 0) return;
    allocator.free(@constCast(value));
}

fn findDefinition(definitions: []const Definition, provider: []const u8) ?Definition {
    for (definitions) |definition| {
        if (std.mem.eql(u8, definition.id, provider)) return definition;
    }
    return null;
}

fn copyHeaders(
    allocator: std.mem.Allocator,
    source: []const ai.Transport.Header,
) error{OutOfMemory}![]ai.Transport.Header {
    const headers = try allocator.alloc(ai.Transport.Header, source.len);
    for (source, 0..) |header, index| {
        headers[index] = .{
            .name = try allocator.dupe(u8, header.name),
            .value = try allocator.dupe(u8, header.value),
            .privileged = header.privileged,
        };
    }
    return headers;
}

fn copyDescriptor(
    allocator: std.mem.Allocator,
    source: *const Registry.Descriptor,
) ResolveError!*Registry.Descriptor {
    const descriptor = try allocator.create(Registry.Descriptor);
    descriptor.* = source.*;
    descriptor.id = try allocator.dupe(u8, source.id);
    descriptor.display_name = try allocator.dupe(u8, source.display_name);
    descriptor.base_url = if (source.base_url) |value| try allocator.dupe(u8, value) else null;
    descriptor.catalog_id = if (source.catalog_id) |value| try allocator.dupe(u8, value) else null;
    return descriptor;
}

fn dynamicDescriptor(
    allocator: std.mem.Allocator,
    definition: Definition,
) ResolveError!*Registry.Descriptor {
    const base_url = definition.base_url orelse return error.ProviderUnavailable;
    if (base_url.len == 0) return error.ProviderUnavailable;
    const id = try allocator.dupe(u8, definition.id);
    const display_name = if (definition.display_name) |value|
        if (value.len == 0) id else try allocator.dupe(u8, value)
    else
        id;
    const catalog_id: ?[]const u8 = if (definition.catalog_id) |value|
        if (value.len == 0) null else try allocator.dupe(u8, value)
    else
        id;
    const api = definition.api orelse .openai_completions;
    const descriptor = try allocator.create(Registry.Descriptor);
    descriptor.* = .{
        .id = id,
        .display_name = display_name,
        .kind = .recipe,
        .default_wire = switch (api) {
            .openai_completions, .catalog => .openai_chat,
            .openai_responses => .openai_responses,
            .anthropic_messages => .anthropic_messages,
        },
        .base_url = try allocator.dupe(u8, base_url),
        .catalog_id = catalog_id,
        .catalog_wires = api == .catalog or
            definitionRoutesModels(&definition),
    };
    return descriptor;
}

fn applyDefinition(
    allocator: std.mem.Allocator,
    provider: []const u8,
    definition: ?Definition,
    overrides: *Registry.Overrides,
) !void {
    const value = definition orelse return;
    if (value.base_url) |base_url| {
        if (base_url.len != 0) overrides.base_url = try allocator.dupe(u8, base_url);
    }
    if (value.display_name) |display_name| {
        if (display_name.len != 0) overrides.display_name = try allocator.dupe(u8, display_name);
    }
    if (value.catalog_id) |catalog_id| {
        overrides.catalog_id = try allocator.dupe(u8, catalog_id);
    }
    if (isConfigApiProvider(provider)) if (value.api) |api| {
        overrides.wire = switch (api) {
            .openai_completions => .openai_chat,
            .openai_responses => .openai_responses,
            .anthropic_messages => .anthropic_messages,
            .catalog => null,
        };
    };
    if (value.cache) |cache| overrides.cache = switch (cache) {
        .auto => .automatic,
        .off => .off,
        .on => .on,
    };
    if (value.cache_ttl) |ttl| overrides.cache_ttl = switch (ttl) {
        .five_minutes => "5m",
        .one_hour => "1h",
    };
    if (value.send_cache_key) |setting| overrides.send_cache_key = triStateBool(setting);
    if (value.request_cost) |setting| overrides.request_cost = triStateBool(setting);
    if (value.reasoning_format) |format| {
        overrides.reasoning_format = if (std.ascii.eqlIgnoreCase(format, "flat"))
            .flat
        else if (std.ascii.eqlIgnoreCase(format, "nested"))
            .nested
        else
            return error.InvalidSetting;
    }
    if (value.reasoning_roundtrip) |roundtrip| {
        try applyReasoningRoundtrip(allocator, roundtrip, overrides);
    }
}

fn isConfigApiProvider(provider: []const u8) bool {
    return isCompatible(provider) or Registry.find(provider) == null;
}

fn isCompatible(provider: []const u8) bool {
    return std.mem.eql(u8, provider, "openai-compatible") or
        std.mem.eql(u8, provider, "anthropic-compatible");
}

fn triStateBool(value: ProviderDefinitions.TriState) ?bool {
    return switch (value) {
        .auto => null,
        .off => false,
        .on => true,
    };
}

fn applyReasoningRoundtrip(
    allocator: std.mem.Allocator,
    value: []const u8,
    overrides: *Registry.Overrides,
) ResolveError!void {
    if (value.len == 0 or std.ascii.eqlIgnoreCase(value, "off") or std.mem.eql(u8, value, "0")) {
        overrides.reasoning_roundtrip = .none;
        return;
    }
    if (std.ascii.eqlIgnoreCase(value, "auto")) return;
    if (std.ascii.eqlIgnoreCase(value, "on") or std.mem.eql(u8, value, "1") or
        std.ascii.eqlIgnoreCase(value, "reasoning_content"))
    {
        overrides.reasoning_roundtrip = .{ .field = .reasoning_content };
        return;
    }
    if (std.ascii.eqlIgnoreCase(value, "reasoning")) {
        overrides.reasoning_roundtrip = .{ .field = .reasoning };
        return;
    }
    if (value.len > Registry.maximum_id_bytes or !std.unicode.utf8ValidateSlice(value))
        return error.InvalidSetting;
    for (value) |byte| if (byte < 0x20 or byte == 0x7f) return error.InvalidSetting;
    overrides.reasoning_roundtrip_field = try allocator.dupe(u8, value);
}

fn definitionWithEnvironmentApi(
    allocator: std.mem.Allocator,
    store: Store,
    provider: []const u8,
    definition: Definition,
) ResolveError!Definition {
    if (!isCompatible(provider)) return definition;
    const key = if (std.mem.eql(u8, provider, "openai-compatible"))
        "providers.openai-compatible.api"
    else
        return definition;
    const value = (try environmentSetting(allocator, store, key)) orelse return definition;
    var effective = definition;
    const wire = ai.Wire.parse(value) orelse return error.InvalidSetting;
    effective.api = switch (wire) {
        .openai_chat => .openai_completions,
        .openai_responses => .openai_responses,
        .anthropic_messages => .anthropic_messages,
    };
    effective.api_invalid = false;
    return effective;
}

fn definitionRoutesModels(definition: *const Definition) bool {
    return definition.model_apis_declared_nonempty or
        (definition.model_apis != null and definition.model_apis.?.len != 0);
}

fn validateRecipeDefinition(provider: []const u8, definition: *const Definition) ResolveError!void {
    if (definition.api_invalid) return error.InvalidSetting;
    if (!isConfigApiProvider(provider) and definition.api != null) return error.UnsupportedSetting;
    const mixed = definitionRoutesModels(definition) or
        (isConfigApiProvider(provider) and definition.api != null and definition.api.? == .catalog) or
        isOpenCode(provider);
    const api: ProviderDefinitions.Api = if (isConfigApiProvider(provider))
        definition.api orelse if (std.mem.eql(u8, provider, "anthropic-compatible"))
            .anthropic_messages
        else
            .openai_completions
    else
        .openai_completions;
    const chat = mixed or api == .openai_completions;
    const responses = mixed or api == .openai_responses;
    const anthropic = mixed or api == .anthropic_messages;
    if ((definition.cache != null or definition.cache_ttl != null) and !chat and !anthropic)
        return error.UnsupportedSetting;
    if (definition.send_cache_key != null and !chat and !responses)
        return error.UnsupportedSetting;
    if ((definition.request_cost != null or definition.reasoning_format != null or
        definition.reasoning_roundtrip != null) and !chat)
        return error.UnsupportedSetting;
    if (definition.max_tokens != null or definition.thinking_mode != null or
        definition.thinking_budget != null or definition.version != null or
        definition.extra_body_json != null)
    {
        return error.UnsupportedSetting;
    }
}

fn definitionDeclaresKey(definition: *const Definition) bool {
    const inline_declared = if (definition.api_key) |value| value.len != 0 else false;
    const environment = if (definition.api_key_env) |value| value.len != 0 else false;
    return inline_declared or environment;
}

fn definitionHasKey(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    definition: *const Definition,
    default_environment: ?[]const u8,
) !bool {
    const fallback = if (definition.api_key_env) |name|
        (if (name.len == 0) default_environment else name)
    else
        default_environment;
    var secret = try ApiKey.resolve(allocator, .{
        .inline_value = definition.api_key,
        .fallback_env_name = fallback,
        .environment = inputs.api_key_environment,
    });
    defer if (secret) |*value| value.deinit(allocator);
    return secret != null;
}

fn definitionAuth(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    definition: *const Definition,
    default_environment: ?[]const u8,
    anthropic: bool,
    required: bool,
) ResolveError!Registry.Auth {
    const fallback = if (definition.api_key_env) |name|
        (if (name.len == 0) default_environment else name)
    else
        default_environment;
    const secret = try ApiKey.resolve(allocator, .{
        .inline_value = definition.api_key,
        .fallback_env_name = fallback,
        .environment = inputs.api_key_environment,
    });
    const key = if (secret) |item| item.value else {
        if (required) return error.MissingCredential;
        return .none;
    };
    return if (anthropic) .{ .anthropic_key = key } else .{ .bearer = key };
}

fn apiTarget(api: ProviderDefinitions.Api) Registry.RuleTarget {
    return switch (api) {
        .openai_completions => .{ .wire = .openai_chat },
        .openai_responses => .{ .wire = .openai_responses },
        .anthropic_messages => .{ .wire = .anthropic_messages },
        .catalog => .catalog,
    };
}

fn validateCombinedRules(
    provider: []const u8,
    definition: ?Definition,
    injected: Registry.Rules,
    model: []const u8,
) ResolveError!void {
    var values: [Registry.maximum_rules]Registry.Rule = undefined;
    var count: usize = 0;
    if (definition) |value| {
        if (value.model_apis) |configured| {
            for (configured) |rule| {
                if (count == values.len) return error.TooManyRules;
                values[count] = .{ .pattern = rule.pattern, .target = apiTarget(rule.api) };
                count += 1;
            }
        }
        if (isConfigApiProvider(provider) and value.api != null and value.api.? == .catalog) {
            if (count == values.len) return error.TooManyRules;
            values[count] = .{ .pattern = "*", .target = .catalog };
            count += 1;
        }
    }
    for (injected.values) |rule| {
        if (count == values.len) return error.TooManyRules;
        values[count] = rule;
        count += 1;
    }
    try Registry.validateRules(.{ .values = values[0..count] }, model);
}

fn mergeRules(
    allocator: std.mem.Allocator,
    provider: []const u8,
    definition: ?Definition,
    injected: Registry.Rules,
) ResolveError!Registry.Rules {
    const config_count = if (definition) |value|
        (if (value.model_apis) |rules| rules.len else 0) +
            @intFromBool(isConfigApiProvider(provider) and value.api != null and value.api.? == .catalog)
    else
        0;
    const total = std.math.add(usize, config_count, injected.values.len) catch
        return error.TooManyRules;
    if (total > Registry.maximum_rules) return error.TooManyRules;
    if (total == 0) return .{};
    const rules = try allocator.alloc(Registry.Rule, total);
    var index: usize = 0;
    if (definition) |value| {
        if (value.model_apis) |configured| {
            for (configured) |rule| {
                rules[index] = .{
                    .pattern = try allocator.dupe(u8, rule.pattern),
                    .target = apiTarget(rule.api),
                };
                index += 1;
            }
        }
        if (isConfigApiProvider(provider) and value.api != null and value.api.? == .catalog) {
            rules[index] = .{ .pattern = try allocator.dupe(u8, "*"), .target = .catalog };
            index += 1;
        }
    }
    for (injected.values) |rule| {
        rules[index] = .{
            .pattern = try allocator.dupe(u8, rule.pattern),
            .target = rule.target,
        };
        index += 1;
    }
    return .{ .values = rules };
}

fn copyRules(allocator: std.mem.Allocator, rules: Registry.Rules) ResolveError!Registry.Rules {
    return mergeRules(allocator, "", null, rules);
}

fn configure(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    provider: []const u8,
    definition: ?Definition,
    overrides: *Registry.Overrides,
    require_available_auth: bool,
) ResolveError!Registry.Auth {
    if (std.mem.eql(u8, provider, "mock")) {
        // The internal development provider has no auth or wire settings; its
        // only configuration is the optional script fixture path.
        try validateProviderFields(inputs.store, "providers.mock", &.{"script"});
        const script = try inputs.store.readNonempty(allocator, "providers.mock.script");
        if (script.value) |value| overrides.mock_script = try allocator.dupe(u8, value);
        return .none;
    }
    if (std.mem.eql(u8, provider, "codex")) {
        try validateProviderFields(
            inputs.store,
            "providers.codex",
            if (definition != null) &.{"extra_headers"} else &.{},
        );
        return .{ .codex = inputs.codex_source orelse return error.InvalidAuth };
    }
    if (std.mem.eql(u8, provider, "llamacpp")) {
        try validateProviderFields(
            inputs.store,
            "providers.llamacpp",
            if (definition != null)
                &.{ "base_url", "api_key", "port", "extra_headers" }
            else
                &.{ "base_url", "api_key", "port" },
        );
        try configureLlama(allocator, inputs.store, overrides);
        return keyAuth(allocator, inputs, "providers.llamacpp.api_key", null, false, false);
    }
    if (std.mem.eql(u8, provider, "openai-compatible")) {
        if (definition) |value| {
            try validateProviderFields(inputs.store, "providers.openai-compatible", &compatible_definition_fields);
            try applyCompatibleEnvironment(allocator, inputs.store, provider, overrides);
            return compatibleDefinitionAuth(allocator, inputs, provider, &value, false);
        }
        try validateProviderFields(inputs.store, "providers.openai-compatible", &.{
            "base_url",       "api_key",      "display_name", "api",       "reasoning_format",
            "send_cache_key", "request_cost", "cache",        "cache_ttl", "reasoning_roundtrip",
        });
        try configureOpenAiCompatible(allocator, inputs.store, overrides, false);
        return keyAuth(allocator, inputs, "providers.openai-compatible.api_key", null, false, false);
    }
    if (std.mem.eql(u8, provider, "anthropic-compatible")) {
        if (definition) |value| {
            try validateProviderFields(
                inputs.store,
                "providers.anthropic-compatible",
                &compatible_definition_fields,
            );
            try applyCompatibleEnvironment(allocator, inputs.store, provider, overrides);
            return compatibleDefinitionAuth(allocator, inputs, provider, &value, true);
        }
        try validateProviderFields(inputs.store, "providers.anthropic-compatible", &.{
            "base_url",      "api_key",         "display_name", "cache", "cache_ttl", "max_tokens",
            "thinking_mode", "thinking_budget", "version",
        });
        try configureAnthropicCompatible(allocator, inputs.store, overrides, false);
        return keyAuth(allocator, inputs, "providers.anthropic-compatible.api_key", null, true, false);
    }
    if (isOpenCode(provider)) {
        const prefix = if (std.mem.eql(u8, provider, "opencode-zen"))
            "providers.opencode-zen"
        else
            "providers.opencode-go";
        if (definition != null) {
            try validateProviderFields(inputs.store, prefix, &.{
                "base_url",            "api_key",        "api_key_env",  "display_name",
                "catalog_id",          "sort_models",    "model_apis",   "cache",
                "cache_ttl",           "send_cache_key", "request_cost", "reasoning_format",
                "reasoning_roundtrip", "extra_headers",
            });
        } else try validateProviderFields(inputs.store, prefix, &.{"api_key"});
        if (definition) |value| {
            return definitionAuth(allocator, inputs, &value, "OPENCODE_API_KEY", false, require_available_auth);
        }
        const setting = if (std.mem.eql(u8, provider, "opencode-zen"))
            "providers.opencode-zen.api_key"
        else
            "providers.opencode-go.api_key";
        // opencode-go's /usage callback is a separate library operation. This
        // composition slice only claims the inference adapter plan.
        return keyAuth(allocator, inputs, setting, "OPENCODE_API_KEY", false, require_available_auth);
    }
    if (std.mem.eql(u8, provider, "ollama")) {
        if (definition != null) {
            try validateProviderFields(inputs.store, "providers.ollama", &.{
                "base_url",            "api_key",        "api_key_env",  "display_name",
                "catalog_id",          "sort_models",    "model_apis",   "cache",
                "cache_ttl",           "send_cache_key", "request_cost", "reasoning_format",
                "reasoning_roundtrip", "extra_headers",
            });
        } else try validateProviderFields(inputs.store, "providers.ollama", &.{"api_key"});
        if (definition) |value| {
            return definitionAuth(allocator, inputs, &value, null, false, false);
        }
        return keyAuth(allocator, inputs, "providers.ollama.api_key", null, false, false);
    }
    if (std.mem.eql(u8, provider, "openai")) {
        try validateProviderFields(
            inputs.store,
            "providers.openai",
            if (definition != null) &.{ "api_key", "extra_headers" } else &.{"api_key"},
        );
        try rejectFirstPartyBase(allocator, inputs.store, provider);
        return keyAuth(allocator, inputs, "providers.openai.api_key", "OPENAI_API_KEY", false, require_available_auth);
    }
    if (std.mem.eql(u8, provider, "anthropic")) {
        try validateProviderFields(
            inputs.store,
            "providers.anthropic",
            if (definition != null) &.{ "api_key", "extra_headers" } else &.{"api_key"},
        );
        try rejectFirstPartyBase(allocator, inputs.store, provider);
        return keyAuth(
            allocator,
            inputs,
            "providers.anthropic.api_key",
            "ANTHROPIC_API_KEY",
            true,
            require_available_auth,
        );
    }
    if (std.mem.eql(u8, provider, "openrouter")) {
        try validateProviderFields(
            inputs.store,
            "providers.openrouter",
            if (definition != null) &.{ "api_key", "extra_headers" } else &.{"api_key"},
        );
        try rejectFirstPartyBase(allocator, inputs.store, provider);
        return keyAuth(
            allocator,
            inputs,
            "providers.openrouter.api_key",
            "OPENROUTER_API_KEY",
            false,
            require_available_auth,
        );
    }
    return error.UnknownProvider;
}

fn keyAuth(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    setting: []const u8,
    fallback: ?[]const u8,
    anthropic: bool,
    required: bool,
) ResolveError!Registry.Auth {
    const inline_result = try inputs.store.readNonempty(allocator, setting);
    const secret = try ApiKey.resolve(allocator, .{
        .inline_value = inline_result.value,
        .fallback_env_name = fallback,
        .environment = inputs.api_key_environment,
    });
    const value = if (secret) |item| item.value else {
        if (required) return error.MissingCredential;
        return .none;
    };
    return if (anthropic) .{ .anthropic_key = value } else .{ .bearer = value };
}

fn environmentSetting(
    allocator: std.mem.Allocator,
    store: Store,
    key: []const u8,
) !?[]u8 {
    var result = try store.readNonempty(allocator, key);
    if (result.source != .env) {
        result.deinit(allocator);
        return null;
    }
    const value = result.value;
    result.value = null;
    result.deinit(allocator);
    return value;
}

fn compatibleDefinitionAuth(
    allocator: std.mem.Allocator,
    inputs: Inputs,
    provider: []const u8,
    definition: *const Definition,
    anthropic: bool,
) ResolveError!Registry.Auth {
    const key = if (std.mem.eql(u8, provider, "openai-compatible"))
        "providers.openai-compatible.api_key"
    else
        "providers.anthropic-compatible.api_key";
    if (try environmentSetting(allocator, inputs.store, key)) |value| {
        return if (anthropic) .{ .anthropic_key = value } else .{ .bearer = value };
    }
    return definitionAuth(allocator, inputs, definition, null, anthropic, false);
}

fn applyCompatibleEnvironment(
    allocator: std.mem.Allocator,
    store: Store,
    provider: []const u8,
    overrides: *Registry.Overrides,
) ResolveError!void {
    const prefix = if (std.mem.eql(u8, provider, "openai-compatible"))
        "providers.openai-compatible"
    else
        "providers.anthropic-compatible";
    var buffer: [128]u8 = undefined;
    const base_key = std.fmt.bufPrint(&buffer, "{s}.base_url", .{prefix}) catch return error.UnsupportedSetting;
    if (try environmentSetting(allocator, store, base_key)) |value| overrides.base_url = value;
    const display_key = std.fmt.bufPrint(&buffer, "{s}.display_name", .{prefix}) catch return error.UnsupportedSetting;
    if (try environmentSetting(allocator, store, display_key)) |value| overrides.display_name = value;
    if (std.mem.eql(u8, provider, "openai-compatible")) {
        if (try environmentSetting(allocator, store, "providers.openai-compatible.api")) |value| {
            overrides.wire = ai.Wire.parse(value) orelse return error.InvalidSetting;
        }
        if (try environmentSetting(allocator, store, "providers.openai-compatible.reasoning_format")) |value| {
            overrides.reasoning_format = if (std.ascii.eqlIgnoreCase(value, "flat"))
                .flat
            else if (std.ascii.eqlIgnoreCase(value, "nested"))
                .nested
            else
                return error.InvalidSetting;
        }
        if (try environmentSetting(allocator, store, "providers.openai-compatible.reasoning_roundtrip")) |value|
            try applyReasoningRoundtrip(allocator, value, overrides);
        if (try environmentSetting(allocator, store, "providers.openai-compatible.send_cache_key")) |value|
            overrides.send_cache_key = try textTriState(value);
        if (try environmentSetting(allocator, store, "providers.openai-compatible.request_cost")) |value|
            overrides.request_cost = try textTriState(value);
        if (try environmentSetting(allocator, store, "providers.openai-compatible.cache")) |value|
            overrides.cache = try textCache(value);
    } else {
        inline for (.{ "max_tokens", "thinking_mode", "thinking_budget", "version" }) |leaf| {
            const key = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ prefix, leaf }) catch return error.UnsupportedSetting;
            if (try environmentSetting(allocator, store, key) != null) return error.UnsupportedSetting;
        }
        if (try environmentSetting(allocator, store, "providers.anthropic-compatible.cache")) |value|
            overrides.cache = try textCache(value);
    }
    const ttl_key = std.fmt.bufPrint(&buffer, "{s}.cache_ttl", .{prefix}) catch return error.UnsupportedSetting;
    if (try environmentSetting(allocator, store, ttl_key)) |value| {
        if (!std.ascii.eqlIgnoreCase(value, "5m") and !std.ascii.eqlIgnoreCase(value, "1h"))
            return error.InvalidSetting;
        overrides.cache_ttl = value;
    }
}

fn textTriState(value: []const u8) ResolveError!?bool {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return null;
    if (isOn(value)) return true;
    if (isOff(value)) return false;
    return error.InvalidSetting;
}

fn textCache(value: []const u8) ResolveError!Registry.CacheSetting {
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .automatic;
    if (isOn(value)) return .on;
    if (isOff(value)) return .off;
    return error.InvalidSetting;
}

fn configureLlama(allocator: std.mem.Allocator, store: Store, overrides: *Registry.Overrides) !void {
    const base = try store.readNonempty(allocator, "providers.llamacpp.base_url");
    if (base.value) |value| {
        overrides.base_url = try allocator.dupe(u8, value);
        return;
    }
    const port = try Settings.getInt(store, allocator, "providers.llamacpp.port");
    overrides.base_url = try std.fmt.allocPrint(allocator, "http://127.0.0.1:{d}/v1", .{port.value});
}

fn configureOpenAiCompatible(
    allocator: std.mem.Allocator,
    store: Store,
    overrides: *Registry.Overrides,
    definition_common: bool,
) !void {
    if (overrides.base_url == null)
        overrides.base_url = try requiredSetting(allocator, store, "providers.openai-compatible.base_url");
    if (overrides.display_name == null)
        overrides.display_name = try optionalSetting(allocator, store, "providers.openai-compatible.display_name");
    if (!definition_common) {
        if (try optionalSetting(allocator, store, "providers.openai-compatible.api")) |value| {
            const wire = ai.Wire.parse(value) orelse return error.InvalidSetting;
            if (wire == .anthropic_messages) return error.UnsupportedSetting;
            overrides.wire = wire;
        }
    }
    if (try optionalSetting(allocator, store, "providers.openai-compatible.reasoning_format")) |value| {
        if (!std.mem.eql(u8, value, "flat")) return error.UnsupportedSetting;
    }
    try rejectConfigured(allocator, store, "providers.openai-compatible.reasoning_roundtrip");
    overrides.send_cache_key = try optionalBool(allocator, store, "providers.openai-compatible.send_cache_key");
    overrides.request_cost = try optionalBool(allocator, store, "providers.openai-compatible.request_cost");
    overrides.cache = try cacheSetting(allocator, store, "providers.openai-compatible.cache");
    if (try optionalSetting(allocator, store, "providers.openai-compatible.cache_ttl")) |value| {
        overrides.cache_ttl = value;
    }
}

fn configureAnthropicCompatible(
    allocator: std.mem.Allocator,
    store: Store,
    overrides: *Registry.Overrides,
    definition_common: bool,
) !void {
    _ = definition_common;
    if (overrides.base_url == null)
        overrides.base_url = try requiredSetting(allocator, store, "providers.anthropic-compatible.base_url");
    if (overrides.display_name == null)
        overrides.display_name = try optionalSetting(allocator, store, "providers.anthropic-compatible.display_name");
    overrides.cache = try cacheSetting(allocator, store, "providers.anthropic-compatible.cache");
    if (try optionalSetting(allocator, store, "providers.anthropic-compatible.cache_ttl")) |value| {
        overrides.cache_ttl = value;
    }
    try rejectConfigured(allocator, store, "providers.anthropic-compatible.max_tokens");
    try acceptOnlyDefault(allocator, store, "providers.anthropic-compatible.thinking_mode", "budget");
    try rejectConfigured(allocator, store, "providers.anthropic-compatible.thinking_budget");
    try acceptOnlyDefault(allocator, store, "providers.anthropic-compatible.version", "2023-06-01");
}

const compatible_definition_fields = [_][]const u8{
    "api",              "base_url",            "api_key",        "api_key_env",
    "display_name",     "catalog_id",          "sort_models",    "model_apis",
    "cache",            "cache_ttl",           "send_cache_key", "request_cost",
    "reasoning_format", "reasoning_roundtrip", "extra_headers",
};

const known_provider_fields = [_][]const u8{
    "api",
    "base_url",
    "api_key",
    "api_key_env",
    "display_name",
    "catalog_id",
    "sort_models",
    "model_apis",
    "cache",
    "cache_ttl",
    "send_cache_key",
    "request_cost",
    "reasoning_format",
    "reasoning_roundtrip",
    "max_tokens",
    "thinking_mode",
    "thinking_budget",
    "version",
    "extra_body",
    "extra_headers",
    "script",
};

fn validateProviderFields(store: Store, prefix: []const u8, allowed: []const []const u8) !void {
    var buffer: [256]u8 = undefined;
    for (known_provider_fields) |field| {
        const key = std.fmt.bufPrint(&buffer, "{s}.{s}", .{ prefix, field }) catch
            return error.UnsupportedSetting;
        if (!store.hasExplicit(key)) continue;
        var is_allowed = false;
        for (allowed) |candidate| {
            if (std.mem.eql(u8, candidate, field)) {
                is_allowed = true;
                break;
            }
        }
        if (!is_allowed) return error.UnsupportedSetting;
    }
}

fn requiredSetting(allocator: std.mem.Allocator, store: Store, key: []const u8) ![]const u8 {
    return (try optionalSetting(allocator, store, key)) orelse return error.ProviderUnavailable;
}

fn optionalSetting(allocator: std.mem.Allocator, store: Store, key: []const u8) !?[]const u8 {
    const result = try store.readNonempty(allocator, key);
    if (result.value) |value| {
        const copy: []const u8 = try allocator.dupe(u8, value);
        return copy;
    }
    return null;
}

fn optionalBool(allocator: std.mem.Allocator, store: Store, key: []const u8) !?bool {
    const value = (try optionalSetting(allocator, store, key)) orelse return null;
    if (isOn(value)) return true;
    if (isOff(value)) return false;
    if (std.ascii.eqlIgnoreCase(value, "auto")) return null;
    return error.InvalidSetting;
}

fn cacheSetting(allocator: std.mem.Allocator, store: Store, key: []const u8) !Registry.CacheSetting {
    const value = (try optionalSetting(allocator, store, key)) orelse return .automatic;
    if (isOn(value)) return .on;
    if (isOff(value)) return .off;
    if (std.ascii.eqlIgnoreCase(value, "auto")) return .automatic;
    return error.InvalidSetting;
}

fn retainedSetting(allocator: std.mem.Allocator, store: Store, key: []const u8) !?[]const u8 {
    const result = try store.read(allocator, key);
    if (result.value) |value| {
        const copy: []const u8 = try allocator.dupe(u8, value);
        return copy;
    }
    return null;
}

fn rejectConfigured(allocator: std.mem.Allocator, store: Store, key: []const u8) !void {
    if (try retainedSetting(allocator, store, key) != null) return error.UnsupportedSetting;
}

fn acceptOnlyDefault(
    allocator: std.mem.Allocator,
    store: Store,
    key: []const u8,
    default_value: []const u8,
) !void {
    const value = (try retainedSetting(allocator, store, key)) orelse return;
    if (!std.mem.eql(u8, value, default_value)) return error.UnsupportedSetting;
}

fn rejectFirstPartyBase(allocator: std.mem.Allocator, store: Store, provider: []const u8) !void {
    const key = try std.fmt.allocPrint(allocator, "providers.{s}.base_url", .{provider});
    try rejectConfigured(allocator, store, key);
}

fn isOn(value: []const u8) bool {
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true") or
        std.ascii.eqlIgnoreCase(value, "yes") or std.ascii.eqlIgnoreCase(value, "on");
}

fn isOff(value: []const u8) bool {
    return std.mem.eql(u8, value, "0") or std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "no") or std.ascii.eqlIgnoreCase(value, "off");
}

fn validDynamicId(value: []const u8) bool {
    if (value.len == 0 or value.len > 63) return false;
    for (value) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_')) return false;
    }
    return true;
}

fn canonical(value: []const u8) []const u8 {
    return if (std.mem.eql(u8, value, "llama.cpp")) "llamacpp" else value;
}

fn isOpenCode(value: []const u8) bool {
    return std.mem.eql(u8, value, "opencode-zen") or std.mem.eql(u8, value, "opencode-go");
}

fn isSupportedPlan(value: []const u8) bool {
    const supported = [_][]const u8{
        "codex",             "llamacpp",             "openai",       "anthropic",   "openrouter",
        "openai-compatible", "anthropic-compatible", "opencode-zen", "opencode-go", "ollama",
        "mock",
    };
    for (supported) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

const TestEnvironment = struct {
    entries: []const Entry = &.{},
    const Entry = struct { name: []const u8, value: []const u8 };

    pub fn get(self: *const TestEnvironment, name: []const u8) ?[]const u8 {
        for (self.entries) |entry| if (std.mem.eql(u8, entry.name, name)) return entry.value;
        return null;
    }
};

const TestCodexSource = struct {
    pub fn acquire(
        _: *TestCodexSource,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: ?ai.Provider.Tick,
        _: ai.CodexAcquirePurpose,
    ) ai.CodexCredentialSource.CallbackError!ai.CodexAcquireDecision {
        return .{ .ready = try ai.CodexOwnedCredential.init(allocator, .{
            .access_token = "token",
            .account_id = "account",
        }) };
    }

    pub fn recoverUnauthorized(
        _: *TestCodexSource,
        _: std.mem.Allocator,
        _: std.Io,
        _: ?ai.Provider.Tick,
        _: ai.CodexCredential,
    ) ai.CodexCredentialSource.CallbackError!ai.CodexUnauthorizedDecision {
        return .use_response;
    }

    pub fn noteUnauthorized(_: *TestCodexSource, _: ai.CodexCredential) void {}
};

fn testStore(document: *const Document, environment: *const TestEnvironment) Store {
    return .init(.{
        .file = document,
        .registry = Settings.storeRegistry(),
        .environment = .from(environment),
    });
}

fn expectHttpPolicy(
    adapter: Registry.AdapterPlan,
    max_attempts: u16,
    base_delay_ms: u64,
    idle_timeout_ms: u64,
) !void {
    switch (adapter) {
        .mock => {},
        inline else => |plan| {
            try std.testing.expectEqual(max_attempts, plan.retry.policy.max_attempts);
            try std.testing.expectEqual(base_delay_ms, plan.retry.policy.base_delay_ms);
            try std.testing.expectEqual(idle_timeout_ms, plan.limits.idle_timeout_ms);
            // Provider-wide policy must not replace each adapter's connect limit.
            try std.testing.expectEqual(@as(u64, 10_000), plan.limits.connect_timeout_ms);
        },
    }
}

test "all four adapter plans accept large HTTP durations" {
    const maximum_duration_ms: u64 = @intCast(std.math.maxInt(c_long));
    const cases = [_]struct { json: []const u8, provider: []const u8 }{
        .{ .json = "{\"provider\":\"llamacpp\",\"model\":\"local\"}", .provider = "llamacpp" },
        .{ .json = "{\"provider\":\"openai\",\"model\":\"gpt\"}", .provider = "openai" },
        .{
            .json = "{\"provider\":\"anthropic\",\"model\":\"claude\",\"show_reasoning\":true}",
            .provider = "anthropic",
        },
        .{ .json = "{\"provider\":\"openrouter\",\"model\":\"vendor/model\"}", .provider = "openrouter" },
        .{
            .json = "{\"provider\":\"openai-compatible\",\"model\":\"m\"," ++
                "\"providers\":{\"openai-compatible\":{\"base_url\":\"http://example.test/v1\"}}}",
            .provider = "openai-compatible",
        },
        .{
            .json = "{\"provider\":\"anthropic-compatible\",\"model\":\"m\"," ++
                "\"providers\":{\"anthropic-compatible\":{\"base_url\":\"http://example.test/v1\"}}}",
            .provider = "anthropic-compatible",
        },
    };
    const environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "OPENAI_API_KEY", .value = "key" },
        .{ .name = "ANTHROPIC_API_KEY", .value = "key" },
        .{ .name = "OPENROUTER_API_KEY", .value = "key" },
    } };
    for (cases) |case| {
        var document = try Document.parse(std.testing.allocator, case.json, .{});
        defer document.deinit();
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .session_cache_key = "12345678-1234-4234-8234-123456789abc",
            .http_policy = .{
                .max_retries = 100,
                .retry_base_ms = maximum_duration_ms,
                .idle_timeout_ms = maximum_duration_ms,
            },
        });
        defer result.deinit();
        try std.testing.expectEqualStrings(case.provider, result.resolved.metadata.provider_id);
        try expectHttpPolicy(result.resolved.adapter, 101, maximum_duration_ms, maximum_duration_ms);
        try result.updateHttpPolicy(.{
            .max_retries = 2,
            .retry_base_ms = 17,
            .idle_timeout_ms = 23,
        });
        try expectHttpPolicy(result.resolved.adapter, 3, 17, 23);
        if (std.mem.eql(u8, case.provider, "anthropic")) {
            try std.testing.expect(result.resolved.adapter.anthropic_messages.body.show_reasoning);
            result.updateShowReasoning(false);
            try std.testing.expect(!result.resolved.adapter.anthropic_messages.body.show_reasoning);
            try result.applyAuthoritativeCatalog(.{});
            try std.testing.expect(!result.resolved.adapter.anthropic_messages.body.show_reasoning);
        }
        try std.testing.expect(!result.provider_autoselected);
    }

    var codex_document = try Document.parse(std.testing.allocator, "{}", .{});
    defer codex_document.deinit();
    var source: TestCodexSource = .{};
    var codex = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&codex_document, &environment),
        .api_key_environment = .from(&environment),
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
        .codex_source = .from(&source),
        .codex_available = true,
        .default_model = "codex-default",
        .default_effort = "high",
        .http_policy = .{
            .max_retries = 100,
            .retry_base_ms = maximum_duration_ms,
            .idle_timeout_ms = maximum_duration_ms,
        },
    });
    defer codex.deinit();
    try std.testing.expectEqualStrings("codex", codex.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("high", codex.effort.?);
    try expectHttpPolicy(codex.resolved.adapter, 101, maximum_duration_ms, maximum_duration_ms);
    try std.testing.expect(codex.provider_autoselected);
}

test "the three remaining compiled recipe plans resolve explicitly" {
    const cases = [_]struct { provider: []const u8, endpoint: []const u8, json: []const u8 }{
        .{
            .provider = "opencode-zen",
            .endpoint = "https://opencode.ai/zen/v1/chat/completions",
            .json = "{\"provider\":\"opencode-zen\",\"model\":\"zen-model\"}",
        },
        .{
            .provider = "opencode-go",
            .endpoint = "https://opencode.ai/zen/go/v1/chat/completions",
            .json = "{\"provider\":\"opencode-go\",\"model\":\"go-model\"}",
        },
        .{
            .provider = "ollama",
            .endpoint = "http://127.0.0.1:11434/v1/chat/completions",
            .json = "{\"provider\":\"ollama\",\"model\":\"\"}",
        },
    };
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "opencode-key" }},
    };
    for (cases) |case| {
        var document = try Document.parse(std.testing.allocator, case.json, .{});
        defer document.deinit();
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_override = case.provider,
            .ollama_available = true,
            .ollama_discovered_model = "discovered-local",
            .default_model = "not-a-recipe-fallback",
            .http_policy = .{ .max_retries = 100, .retry_base_ms = 17, .idle_timeout_ms = 0 },
        });
        defer result.deinit();
        try std.testing.expectEqualStrings(case.provider, result.resolved.metadata.provider_id);
        try std.testing.expectEqualStrings(case.endpoint, result.resolved.adapter.openai_chat.endpoint);
        try expectHttpPolicy(result.resolved.adapter, 101, 17, 0);
        if (std.mem.eql(u8, case.provider, "ollama")) {
            try std.testing.expectEqualStrings("discovered-local", result.model);
            try std.testing.expect(result.resolved.adapter.openai_chat.api_key == null);
        } else {
            try std.testing.expectEqualStrings("opencode-key", result.resolved.adapter.openai_chat.api_key.?);
        }
    }
}

test "mock provider resolves from settings with script and default model" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"mock\",\"providers\":{\"mock\":{\"script\":\"fixtures/demo.txt\"}}}",
        .{},
    );
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
    });
    defer result.deinit();

    try std.testing.expectEqualStrings("mock", result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("mock-model", result.model);
    try std.testing.expectEqual(@as(?[]const u8, null), result.effort);
    try std.testing.expect(!result.provider_autoselected);
    try std.testing.expectEqual(@as(?ai.Wire, null), result.resolved.metadata.wire);
    switch (result.resolved.adapter) {
        .mock => |mock_config| try std.testing.expectEqualStrings("fixtures/demo.txt", mock_config.script_path.?),
        else => return error.TestExpectedEqual,
    }

    var interactive_document = try Document.parse(std.testing.allocator, "{\"provider\":\"mock\"}", .{});
    defer interactive_document.deinit();
    var interactive = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&interactive_document, &environment),
        .api_key_environment = .from(&environment),
    });
    defer interactive.deinit();
    switch (interactive.resolved.adapter) {
        .mock => |mock_config| try std.testing.expectEqual(@as(?[]const u8, null), mock_config.script_path),
        else => return error.TestExpectedEqual,
    }
}

test "HTTP policy applies to dynamic plans and rejects too many retries" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    const definition: Definition = .{
        .id = @constCast("dynamic-http"),
        .api = .openai_responses,
        .base_url = @constCast("https://example.test/v1"),
    };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "dynamic-http",
        .provider_definitions = &.{definition},
        .http_policy = .{ .max_retries = 0, .retry_base_ms = 0, .idle_timeout_ms = 0 },
    });
    defer result.deinit();
    try expectHttpPolicy(result.resolved.adapter, 1, 0, 0);

    try std.testing.expectError(error.InvalidSetting, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .http_policy = .{ .max_retries = 101 },
    }));
}

test "compiled recipe availability and explicit failures are consistent" {
    const empty: TestEnvironment = .{};
    var model_document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer model_document.deinit();
    inline for (.{ "opencode-zen", "opencode-go" }) |provider| {
        var explicit = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&model_document, &empty),
            .api_key_environment = .from(&empty),
            .provider_override = provider,
        });
        defer explicit.deinit();
        try std.testing.expect(explicit.resolved.adapter.openai_chat.api_key == null);
    }
    var offline_ollama = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&model_document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "ollama",
        .ollama_available = false,
    });
    offline_ollama.deinit();

    var none = try Document.parse(std.testing.allocator, "{}", .{});
    defer none.deinit();
    try std.testing.expectError(error.MissingProvider, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&none, &empty),
        .api_key_environment = .from(&empty),
    }));
}

test "OpenCode catalog hints select wire and provider blocks stay pinned" {
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "key" }},
    };
    var accepted = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"claude\",\"providers\":{\"opencode-go\":{" ++
            "\"catalog_id\":\"handled\",\"sort_models\":\"on\",\"model_apis\":\"handled\"}}}",
        .{},
    );
    defer accepted.deinit();
    const definition: Definition = .{ .id = @constCast("opencode-go") };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&accepted, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "opencode-go",
        .provider_definitions = &.{definition},
        .hints = .{ .catalog_wire = .{ .wire = .anthropic_messages } },
    });
    defer result.deinit();
    try std.testing.expect(result.resolved.metadata.wire == .anthropic_messages);
    try std.testing.expectEqualStrings("key", result.resolved.adapter.anthropic_messages.api_key.?);

    var rejected = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"m\",\"providers\":{\"opencode-zen\":{" ++
            "\"base_url\":\"https://override.test/v1\"}}}",
        .{},
    );
    defer rejected.deinit();
    try std.testing.expectError(error.UnsupportedSetting, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&rejected, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "opencode-zen",
    }));
}

test "provider definitions overlay recipe identity ordering and remote Ollama" {
    const empty: TestEnvironment = .{};
    const definition: Definition = .{
        .id = @constCast("ollama"),
        .base_url = @constCast("https://remote-ollama.test/v1"),
        .catalog_id = @constCast(""),
        .sort_models = false,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"remote-model\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "ollama",
        .provider_definitions = &.{definition},
        .ollama_available = false,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "https://remote-ollama.test/v1/chat/completions",
        result.resolved.adapter.openai_chat.endpoint,
    );
    try std.testing.expect(result.resolved.metadata.catalog_id == null);
    try std.testing.expect(result.keep_model_order);
}

test "definition-declared keys override compatible base and Ollama probe availability" {
    var document = try Document.parse(std.testing.allocator, "{\"provider\":\"\",\"model\":\"m\"}", .{});
    defer document.deinit();
    const empty: TestEnvironment = .{};
    const compatible: Definition = .{
        .id = @constCast("openai-compatible"),
        .base_url = @constCast("https://compatible.test/v1"),
        .api_key_env = @constCast("CUSTOM_COMPATIBLE_KEY"),
    };
    try std.testing.expectError(error.MissingProvider, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_definitions = &.{compatible},
    }));
    const compatible_environment: TestEnvironment = .{
        .entries = &.{.{ .name = "CUSTOM_COMPATIBLE_KEY", .value = "compatible-key" }},
    };
    var compatible_result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &compatible_environment),
        .api_key_environment = .from(&compatible_environment),
        .provider_definitions = &.{compatible},
    });
    defer compatible_result.deinit();
    try std.testing.expectEqualStrings(
        "openai-compatible",
        compatible_result.resolved.metadata.provider_id,
    );
    try std.testing.expectEqualStrings(
        "compatible-key",
        compatible_result.resolved.adapter.openai_chat.api_key.?,
    );

    const ollama: Definition = .{
        .id = @constCast("ollama"),
        .base_url = @constCast("https://keyed-ollama.test/v1"),
        .api_key_env = @constCast("KEYED_OLLAMA_KEY"),
    };
    try std.testing.expectError(error.MissingProvider, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_definitions = &.{ollama},
        .ollama_available = true,
    }));
    const ollama_environment: TestEnvironment = .{
        .entries = &.{.{ .name = "KEYED_OLLAMA_KEY", .value = "ollama-key" }},
    };
    var ollama_result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &ollama_environment),
        .api_key_environment = .from(&ollama_environment),
        .provider_definitions = &.{ollama},
        .ollama_available = false,
    });
    defer ollama_result.deinit();
    try std.testing.expectEqualStrings("ollama", ollama_result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("ollama-key", ollama_result.resolved.adapter.openai_chat.api_key.?);
}

test "Ollama definition common chat fields reach the adapter plan" {
    const empty: TestEnvironment = .{};
    const definition: Definition = .{
        .id = @constCast("ollama"),
        .base_url = @constCast("https://advanced-ollama.test/v1"),
        .cache = .on,
        .cache_ttl = .five_minutes,
        .send_cache_key = .on,
        .request_cost = .off,
        .reasoning_format = @constCast("nested"),
        .reasoning_roundtrip = @constCast("reasoning"),
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "ollama",
        .provider_definitions = &.{definition},
        .session_cache_key = "cache-key",
    });
    defer result.deinit();
    const plan = result.resolved.adapter.openai_chat;
    try std.testing.expect(plan.body.cache_markers);
    try std.testing.expectEqualStrings("5m", plan.body.cache_ttl);
    try std.testing.expectEqualStrings("cache-key", plan.body.prompt_cache_key.?);
    try std.testing.expect(!plan.body.request_cost);
    try std.testing.expect(plan.body.reasoning_format == .nested);
    try std.testing.expectEqualStrings("reasoning", plan.body.reasoning_field.?);
}

test "provider definition model API rules preserve order and every target" {
    var model_apis = [_]ProviderDefinitions.ModelApi{
        .{ .pattern = @constCast("resp-*"), .api = .openai_responses },
        .{ .pattern = @constCast("anth-*"), .api = .anthropic_messages },
        .{ .pattern = @constCast("catalog-*"), .api = .catalog },
        .{ .pattern = @constCast("*"), .api = .openai_completions },
    };
    const definition: Definition = .{
        .id = @constCast("opencode-go"),
        .api_key_env = @constCast("CUSTOM_OPENCODE_KEY"),
        .model_apis = &model_apis,
    };
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "CUSTOM_OPENCODE_KEY", .value = "custom-key" }},
    };
    const cases = [_]struct {
        model: []const u8,
        expected: ai.Wire,
        hint: Registry.WireHint = .unknown,
    }{
        .{ .model = "resp-model", .expected = .openai_responses },
        .{ .model = "anth-model", .expected = .anthropic_messages },
        .{
            .model = "catalog-model",
            .expected = .openai_responses,
            .hint = .{ .wire = .openai_responses },
        },
        .{ .model = "other-model", .expected = .openai_chat },
    };
    for (cases) |case| {
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"provider\":\"opencode-go\",\"model\":\"{s}\"}}",
            .{case.model},
        );
        defer std.testing.allocator.free(json);
        var document = try Document.parse(std.testing.allocator, json, .{});
        defer document.deinit();
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_definitions = &.{definition},
            .hints = .{ .catalog_wire = case.hint },
            .rules = .{ .values = &.{.{
                .pattern = "*",
                .target = .{ .wire = .anthropic_messages },
            }} },
        });
        defer result.deinit();
        try std.testing.expectEqual(case.expected, result.resolved.metadata.wire);
    }

    var unsupported_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-go\",\"model\":\"catalog-model\"}",
        .{},
    );
    defer unsupported_document.deinit();
    try std.testing.expectError(error.UnsupportedWire, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&unsupported_document, &environment),
        .api_key_environment = .from(&environment),
        .provider_definitions = &.{definition},
        .hints = .{ .catalog_wire = .unsupported },
    }));
}

test "first-party fallback does not consume compatible provider variables" {
    var document = try Document.parse(std.testing.allocator, "{\"provider\":\"openai\",\"model\":\"gpt\"}", .{});
    defer document.deinit();
    const environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "ZI_OPENAI_API_KEY", .value = "wrong" },
        .{ .name = "OPENAI_API_KEY", .value = "right" },
    } };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .session_cache_key = "cache-key",
    });
    defer result.deinit();
    const plan = result.resolved.adapter.openai_responses;
    try std.testing.expectEqualStrings("right", plan.api_key.?);
}

test "owned plan survives destroyed collaborators and mutable inputs" {
    var provider = [_]u8{ 'o', 'p', 'e', 'n', 'a', 'i' };
    var session = [_]u8{ 'c', 'a', 'c', 'h', 'e', '-', 'k', 'e', 'y' };
    var key = [_]u8{ 's', 'e', 'c', 'r', 'e', 't' };
    var result: *Owned = undefined;
    {
        var document = try Document.parse(std.testing.allocator, "{\"model\":\"mutable-model\"}", .{});
        defer document.deinit();
        const store_environment: TestEnvironment = .{};
        const key_environment: TestEnvironment = .{
            .entries = &.{.{ .name = "OPENAI_API_KEY", .value = &key }},
        };
        result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &store_environment),
            .api_key_environment = .from(&key_environment),
            .provider_override = &provider,
            .session_cache_key = &session,
        });
    }
    defer result.deinit();
    @memset(&provider, 'x');
    @memset(&session, 'x');
    @memset(&key, 'x');
    try std.testing.expectEqualStrings("openai", result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("mutable-model", result.model);
    const plan = result.resolved.adapter.openai_responses;
    try std.testing.expectEqualStrings("secret", plan.api_key.?);
    try std.testing.expectEqualStrings("cache-key", plan.session_cache_key.?);
}

test "Codex source stays callable after input collaborators are destroyed" {
    var source: TestCodexSource = .{};
    var model = [_]u8{ 'c', 'o', 'd', 'e', 'x', '-', 'm' };
    var effort = [_]u8{ 'h', 'i', 'g', 'h' };
    var session = "12345678-1234-4234-8234-123456789abc".*;
    var result: *Owned = undefined;
    {
        var document = try Document.parse(std.testing.allocator, "{}", .{});
        defer document.deinit();
        const environment: TestEnvironment = .{};
        result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .session_cache_key = &session,
            .codex_source = .from(&source),
            .codex_available = true,
            .default_model = &model,
            .default_effort = &effort,
        });
    }
    defer result.deinit();
    @memset(&model, 'x');
    @memset(&effort, 'x');
    @memset(&session, 'x');
    try std.testing.expectEqualStrings("codex-m", result.model);
    try std.testing.expectEqualStrings("high", result.effort.?);
    var decision = try result.resolved.adapter.codex.source.acquire(
        std.testing.allocator,
        std.testing.io,
        null,
        .request,
    );
    defer decision.deinit();
    try std.testing.expectEqualStrings("token", decision.ready.access_token);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const environment: TestEnvironment = .{};
    var compatible_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"openai-compatible\",\"model\":\"gpt\"," ++
            "\"effort\":\"medium\",\"providers\":{\"openai-compatible\":{" ++
            "\"base_url\":\"http://example.test/v1\",\"api_key\":\"super-secret\"," ++
            "\"send_cache_key\":\"on\",\"cache_ttl\":\"5m\"}}}",
        .{},
    );
    defer compatible_document.deinit();
    var compatible = try resolve(.{
        .allocator = allocator,
        .store = testStore(&compatible_document, &environment),
        .api_key_environment = .from(&environment),
        .session_cache_key = "cache-key",
    });
    compatible.deinit();

    const opencode_environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "super-secret" }},
    };
    var opencode_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-go\",\"model\":\"go-model\"}",
        .{},
    );
    defer opencode_document.deinit();
    var catalog_source: AllocatingModelHintsSource = .{};
    var opencode = try resolve(.{
        .allocator = allocator,
        .store = testStore(&opencode_document, &opencode_environment),
        .api_key_environment = .from(&opencode_environment),
        .hints_source = .from(&catalog_source),
    });
    opencode.deinit();

    var codex_document = try Document.parse(std.testing.allocator, "{}", .{});
    defer codex_document.deinit();
    var source: TestCodexSource = .{};
    var codex = try resolve(.{
        .allocator = allocator,
        .store = testStore(&codex_document, &environment),
        .api_key_environment = .from(&environment),
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
        .codex_source = .from(&source),
        .codex_available = true,
        .default_model = "codex-model",
        .default_effort = "high",
    });
    codex.deinit();

    var dynamic_document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer dynamic_document.deinit();
    var dynamic_headers = [_]ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = @constCast("value") },
        .{ .name = @constCast("X-Missing"), .value = @constCast("$MISSING") },
    };
    const dynamic_definition: Definition = .{
        .id = @constCast("dynamic-oom"),
        .base_url = @constCast("https://dynamic.test/v1"),
        .api_key = @constCast("secret"),
        .catalog_id = @constCast("dynamic-catalog"),
        .extra_headers = &dynamic_headers,
    };
    var dynamic = try resolve(.{
        .allocator = allocator,
        .store = testStore(&dynamic_document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "dynamic-oom",
        .provider_definitions = &.{dynamic_definition},
    });
    dynamic.deinit();
}

test "composition releases compatible OpenCode Codex dynamic and late-effort allocations on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "explicit first-party selection permits absent credentials" {
    const providers = [_][]const u8{ "openai", "anthropic", "openrouter" };
    const environment: TestEnvironment = .{};
    for (providers) |provider| {
        var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
        defer document.deinit();
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_override = provider,
            .session_cache_key = "cache-key",
        });
        defer result.deinit();
        switch (result.resolved.adapter) {
            .openai_responses => |plan| try std.testing.expect(plan.api_key == null),
            .openai_chat => |plan| try std.testing.expect(plan.api_key == null),
            .anthropic_messages => |plan| try std.testing.expect(plan.api_key == null),
            .codex => unreachable,
            .mock => unreachable,
        }
    }
}

test "automatic selection preserves the first seven provider positions" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"\",\"model\":\"m\",\"providers\":{" ++
            "\"openai-compatible\":{\"base_url\":\"http://openai.test/v1\"}," ++
            "\"anthropic-compatible\":{\"base_url\":\"http://anthropic.test/v1\"}}}",
        .{},
    );
    defer document.deinit();
    var source: TestCodexSource = .{};
    const cases = [_]struct {
        expected: []const u8,
        codex: bool = false,
        llama: bool = false,
        entries: []const TestEnvironment.Entry = &.{},
    }{
        .{ .expected = "codex", .codex = true, .llama = true, .entries = &.{
            .{ .name = "OPENAI_API_KEY", .value = "key" },
        } },
        .{ .expected = "llamacpp", .llama = true, .entries = &.{
            .{ .name = "OPENAI_API_KEY", .value = "key" },
        } },
        .{ .expected = "openai", .entries = &.{
            .{ .name = "OPENAI_API_KEY", .value = "key" },
            .{ .name = "ANTHROPIC_API_KEY", .value = "key" },
        } },
        .{ .expected = "anthropic", .entries = &.{
            .{ .name = "ANTHROPIC_API_KEY", .value = "key" },
            .{ .name = "OPENROUTER_API_KEY", .value = "key" },
        } },
        .{ .expected = "openrouter", .entries = &.{
            .{ .name = "OPENROUTER_API_KEY", .value = "key" },
        } },
        .{ .expected = "openai-compatible" },
    };
    for (cases) |case| {
        const environment: TestEnvironment = .{ .entries = case.entries };
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .codex_available = case.codex,
            .llamacpp_available = case.llama,
            .codex_source = .from(&source),
            .session_cache_key = "12345678-1234-4234-8234-123456789abc",
        });
        defer result.deinit();
        try std.testing.expectEqualStrings(case.expected, result.resolved.metadata.provider_id);
    }

    var anthropic_only = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"m\",\"providers\":{\"anthropic-compatible\":{" ++
            "\"base_url\":\"http://anthropic.test/v1\"}}}",
        .{},
    );
    defer anthropic_only.deinit();
    const empty: TestEnvironment = .{};
    var last = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&anthropic_only, &empty),
        .api_key_environment = .from(&empty),
    });
    defer last.deinit();
    try std.testing.expectEqualStrings("anthropic-compatible", last.resolved.metadata.provider_id);

    var none = try Document.parse(std.testing.allocator, "{}", .{});
    defer none.deinit();
    try std.testing.expectError(error.MissingProvider, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&none, &empty),
        .api_key_environment = .from(&empty),
    }));
}

test "automatic selection appends compiled recipes in recipe order" {
    const opencode_environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "key" }},
    };
    var compatible = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"\",\"model\":\"m\",\"providers\":{" ++
            "\"anthropic-compatible\":{\"base_url\":\"http://compatible.test/v1\"}}}",
        .{},
    );
    defer compatible.deinit();
    var before_zen = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&compatible, &opencode_environment),
        .api_key_environment = .from(&opencode_environment),
        .ollama_available = true,
    });
    defer before_zen.deinit();
    try std.testing.expectEqualStrings("anthropic-compatible", before_zen.resolved.metadata.provider_id);

    var recipes = try Document.parse(std.testing.allocator, "{\"provider\":\"\",\"model\":\"m\"}", .{});
    defer recipes.deinit();
    var zen = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&recipes, &opencode_environment),
        .api_key_environment = .from(&opencode_environment),
        .ollama_available = true,
    });
    defer zen.deinit();
    try std.testing.expectEqualStrings("opencode-zen", zen.resolved.metadata.provider_id);

    const empty: TestEnvironment = .{};
    var go_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"\",\"model\":\"m\",\"providers\":{" ++
            "\"opencode-go\":{\"api_key\":\"go-inline\"}}}",
        .{},
    );
    defer go_document.deinit();
    var go = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&go_document, &empty),
        .api_key_environment = .from(&empty),
        .ollama_available = true,
    });
    defer go.deinit();
    try std.testing.expectEqualStrings("opencode-go", go.resolved.metadata.provider_id);

    var ollama = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&recipes, &empty),
        .api_key_environment = .from(&empty),
        .ollama_available = true,
    });
    defer ollama.deinit();
    try std.testing.expectEqualStrings("ollama", ollama.resolved.metadata.provider_id);
}

test "OpenCode environment credentials are copied into owned plans" {
    var key = "mutable-opencode-key".*;
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = &key }},
    };
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-zen\",\"model\":\"m\"}",
        .{},
    );
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
    });
    defer result.deinit();
    @memset(&key, 'x');
    try std.testing.expectEqualStrings("mutable-opencode-key", result.resolved.adapter.openai_chat.api_key.?);
}

test "explicit empties preserve provider model and effort tier semantics" {
    var run = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"\",\"model\":\"\",\"effort\":\"\"}",
        .{},
    );
    defer run.deinit();
    const environment: TestEnvironment = .{};
    const store = Store.init(.{
        .run = &run,
        .registry = Settings.storeRegistry(),
        .environment = .from(&environment),
    });
    var source: TestCodexSource = .{};
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = store,
        .api_key_environment = .from(&environment),
        .codex_available = true,
        .codex_source = .from(&source),
        .session_cache_key = "12345678-1234-4234-8234-123456789abc",
        .default_model = "fallback-model",
        .default_effort = "high",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("fallback-model", result.model);
    try std.testing.expect(result.effort == null);
}

test "provider override governs lower provider-bound model selection" {
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"anthropic\",\"model\":\"wrong-provider-model\"}",
        .{},
    );
    defer document.deinit();
    const environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "OPENAI_API_KEY", .value = "key" },
    } };
    try std.testing.expectError(error.MissingModel, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "openai",
        .session_cache_key = "cache-key",
    }));
}

test "every unsupported known provider field is rejected" {
    const environment: TestEnvironment = .{};
    for (known_provider_fields) |field| {
        if (std.mem.eql(u8, field, "api_key")) continue;
        const json = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"provider\":\"openai\",\"model\":\"m\"," ++
                "\"providers.openai.api_key\":\"key\",\"providers.openai.{s}\":\"x\"}}",
            .{field},
        );
        defer std.testing.allocator.free(json);
        var document = try Document.parse(std.testing.allocator, json, .{});
        defer document.deinit();
        try std.testing.expectError(error.UnsupportedSetting, resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .session_cache_key = "cache-key",
        }));
    }
}

const ObservingAllocator = struct {
    backing: std.mem.Allocator,
    fail_index: ?usize = null,
    allocations: usize = 0,
    frees: usize = 0,
    live_bytes: usize = 0,
    peak_live_bytes: usize = 0,
    zeroed_frees: usize = 0,
    secret_seen_on_free: bool = false,

    fn allocator(self: *ObservingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        const index = self.allocations;
        self.allocations += 1;
        if (self.fail_index == index) return null;
        const memory = self.backing.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.live_bytes += len;
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return memory;
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        if (!self.backing.rawResize(memory, alignment, new_len, ret_addr)) return false;
        if (new_len >= memory.len) {
            self.live_bytes += new_len - memory.len;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return true;
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        const remapped = self.backing.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        if (new_len >= memory.len) {
            self.live_bytes += new_len - memory.len;
        } else {
            self.live_bytes -= memory.len - new_len;
        }
        self.peak_live_bytes = @max(self.peak_live_bytes, self.live_bytes);
        return remapped;
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *ObservingAllocator = @ptrCast(@alignCast(context));
        self.frees += 1;
        self.live_bytes -= memory.len;
        if (std.mem.indexOf(u8, memory, "super-secret") != null) self.secret_seen_on_free = true;
        var all_zero = true;
        for (memory) |byte| all_zero = all_zero and byte == 0;
        if (all_zero) self.zeroed_frees += 1;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn resolveSecretWithAllocator(allocator: std.mem.Allocator) ResolveError!*Owned {
    var document = Document.parse(
        std.testing.allocator,
        "{\"provider\":\"openai-compatible\",\"model\":\"gpt\"," ++
            "\"providers\":{\"openai-compatible\":{\"base_url\":\"http://example.test/v1\"," ++
            "\"api_key\":\"super-secret\"}}}",
        .{},
    ) catch unreachable;
    defer document.deinit();
    const environment: TestEnvironment = .{};
    var catalog_source: AllocatingModelHintsSource = .{};
    return resolve(.{
        .allocator = allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&catalog_source),
    });
}

test "arena wipes duplicate secrets before normal and error-path frees" {
    var normal: ObservingAllocator = .{ .backing = std.testing.allocator };
    var result = try resolveSecretWithAllocator(normal.allocator());
    result.deinit();
    try std.testing.expect(normal.zeroed_frees > 0);
    try std.testing.expect(!normal.secret_seen_on_free);

    // Cover failures after the inline Store value and API-key duplicate have
    // both had a chance to enter the arena.
    for (0..32) |fail_index| {
        var failing: ObservingAllocator = .{
            .backing = std.testing.allocator,
            .fail_index = fail_index,
        };
        if (resolveSecretWithAllocator(failing.allocator())) |owned| {
            owned.deinit();
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
        }
        try std.testing.expect(!failing.secret_seen_on_free);
    }
}

test "config-only providers resolve defaults APIs auth and catalog identity" {
    const environment: TestEnvironment = .{ .entries = &.{.{ .name = "CUSTOM_KEY", .value = "env-secret" }} };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    const cases = [_]struct {
        definition: Definition,
        wire: ai.Wire,
    }{
        .{ .definition = .{
            .id = @constCast("custom-chat"),
            .base_url = @constCast("https://chat.test/v1"),
            .display_name = @constCast("Custom Chat"),
        }, .wire = .openai_chat },
        .{ .definition = .{
            .id = @constCast("custom-responses"),
            .api = .openai_responses,
            .base_url = @constCast("https://responses.test/v1"),
            .api_key_env = @constCast("CUSTOM_KEY"),
            .catalog_id = @constCast(""),
        }, .wire = .openai_responses },
        .{ .definition = .{
            .id = @constCast("custom-messages"),
            .api = .anthropic_messages,
            .base_url = @constCast("https://messages.test/v1"),
            .api_key = @constCast("inline-secret"),
            .catalog_id = @constCast("anthropic"),
        }, .wire = .anthropic_messages },
    };
    for (cases) |case| {
        var result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &environment),
            .api_key_environment = .from(&environment),
            .provider_override = case.definition.id,
            .provider_definitions = &.{case.definition},
        });
        defer result.deinit();
        try std.testing.expect(result.resolved.metadata.wire == case.wire);
        if (std.mem.eql(u8, case.definition.id, "custom-chat")) {
            try std.testing.expectEqualStrings("Custom Chat", result.resolved.metadata.display_name);
            try std.testing.expectEqualStrings("custom-chat", result.resolved.metadata.catalog_id.?);
            try std.testing.expect(result.resolved.adapter.openai_chat.api_key == null);
        } else if (std.mem.eql(u8, case.definition.id, "custom-responses")) {
            try std.testing.expect(result.resolved.metadata.catalog_id == null);
            try std.testing.expectEqualStrings("env-secret", result.resolved.adapter.openai_responses.api_key.?);
        } else {
            try std.testing.expectEqualStrings("inline-secret", result.resolved.adapter.anthropic_messages.api_key.?);
        }
    }
}

test "config-only auto selection follows definition order after compiled plans" {
    const empty: TestEnvironment = .{};
    const definitions = [_]Definition{
        .{ .id = @constCast("unconfigured"), .base_url = @constCast("") },
        .{
            .id = @constCast("missing-key"),
            .base_url = @constCast("https://keyed.test/v1"),
            .api_key_env = @constCast("MISSING_KEY"),
        },
        .{ .id = @constCast("unkeyed"), .base_url = @constCast("https://first.test/v1") },
        .{ .id = @constCast("later"), .base_url = @constCast("https://later.test/v1") },
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_definitions = &definitions,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("unkeyed", result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("https://first.test/v1/chat/completions", result.resolved.endpoint);
}

test "config-only mixed rules and supported policy fields are retained" {
    const empty: TestEnvironment = .{};
    const configured_rules = [_]ProviderDefinitions.ModelApi{
        .{ .pattern = @constCast("claude-*"), .api = .anthropic_messages },
        .{ .pattern = @constCast("resp-*"), .api = .openai_responses },
    };
    const definition: Definition = .{
        .id = @constCast("gateway"),
        .api = .catalog,
        .base_url = @constCast("https://gateway.test/v1"),
        .model_apis = @constCast(&configured_rules),
        .cache = .on,
        .cache_ttl = .five_minutes,
        .send_cache_key = .on,
        .request_cost = .on,
        .reasoning_format = @constCast("nested"),
        .reasoning_roundtrip = @constCast("reasoning_content"),
        .sort_models = false,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"resp-model\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "gateway",
        .provider_definitions = &.{definition},
        .session_cache_key = "session",
    });
    defer result.deinit();
    try std.testing.expect(result.resolved.metadata.wire == .openai_responses);
    try std.testing.expect(result.resolved.metadata.send_cache_key);
    try std.testing.expect(result.keep_model_order);
    try std.testing.expectEqualStrings("session", result.resolved.adapter.openai_responses.session_cache_key.?);
}

test "Ollama extra headers follow non-chat model routes with local transport policy" {
    const empty: TestEnvironment = .{};
    const configured_rules = [_]ProviderDefinitions.ModelApi{
        .{ .pattern = @constCast("*"), .api = .openai_responses },
    };
    const definition: Definition = .{
        .id = @constCast("ollama"),
        .model_apis = @constCast(&configured_rules),
        .model_apis_declared_nonempty = true,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"qwen\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "ollama",
        .provider_definitions = &.{definition},
        .prepared_headers = .{
            .provider_id = "ollama",
            .headers = &.{.{
                .name = "X-Local",
                .value = "value",
                .privileged = true,
            }},
        },
    });
    defer result.deinit();
    try std.testing.expect(result.resolved.metadata.wire == .openai_responses);
    try std.testing.expectEqual(
        ai.Transport.PrivilegedHeaderPolicy.https_or_loopback_http,
        result.resolved.adapter.openai_responses.privileged_header_policy,
    );
    try std.testing.expectEqual(@as(usize, 1), result.resolved.adapter.openai_responses.extra_headers.len);
}

test "selected dynamic provider resolves owned headers and retains safe warnings" {
    const environment: TestEnvironment = .{ .entries = &.{.{ .name = "TOKEN", .value = "secret" }} };
    var token_value = "$TOKEN".*;
    var missing_value = "$MISSING".*;
    var configured_headers = [_]ProviderDefinitions.Header{
        .{ .name = @constCast("X-Token"), .value = &token_value },
        .{ .name = @constCast("X-Missing"), .value = &missing_value },
    };
    const definition: Definition = .{
        .id = @constCast("gateway"),
        .base_url = @constCast("https://gateway.test/v1"),
        .extra_headers = &configured_headers,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "gateway",
        .provider_definitions = &.{definition},
        .session_cache_key = "cache-key",
    });
    defer result.deinit();
    @memset(&token_value, 'x');
    @memset(&missing_value, 'x');
    const headers = result.resolved.adapter.openai_chat.extra_headers;
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Token", headers[0].name);
    try std.testing.expectEqualStrings("secret", headers[0].value);
    try std.testing.expect(headers[0].privileged);
    try std.testing.expectEqual(@as(usize, 1), result.header_warnings.len);
    try std.testing.expectEqualStrings("X-Missing", result.header_warnings[0].name);
    try std.testing.expectEqualStrings("MISSING", result.header_warnings[0].environment_name.?);
}

test "selected provider ignores mismatched prepared headers" {
    const environment: TestEnvironment = .{ .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "key" }} };
    var configured_headers = [_]ProviderDefinitions.Header{.{
        .name = @constCast("X-Selected"),
        .value = @constCast("value"),
    }};
    const definition: Definition = .{
        .id = @constCast("openai"),
        .extra_headers = &configured_headers,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "openai",
        .provider_definitions = &.{definition},
        .prepared_headers = .{
            .provider_id = "ollama",
            .headers = &.{.{ .name = "X-Wrong", .value = "wrong" }},
        },
        .session_cache_key = "cache-key",
    });
    defer result.deinit();
    const headers = result.resolved.adapter.openai_responses.extra_headers;
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings("X-Selected", headers[0].name);
}

test "provider header collision fails during plan resolution" {
    const environment: TestEnvironment = .{};
    var configured_headers = [_]ProviderDefinitions.Header{.{
        .name = @constCast("Authorization"),
        .value = @constCast("Bearer replacement"),
    }};
    const definition: Definition = .{
        .id = @constCast("gateway"),
        .base_url = @constCast("https://gateway.test/v1"),
        .api_key = @constCast("key"),
        .extra_headers = &configured_headers,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    try std.testing.expectError(error.InvalidHeaderValue, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "gateway",
        .provider_definitions = &.{definition},
        .session_cache_key = "cache-key",
    }));
}

test "config-only providers reject missing inputs and unsupported retained knobs" {
    const empty: TestEnvironment = .{};
    var no_model = try Document.parse(std.testing.allocator, "{}", .{});
    defer no_model.deinit();
    const no_base: Definition = .{ .id = @constCast("no-base") };
    try std.testing.expectError(error.ProviderUnavailable, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&no_model, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "no-base",
        .provider_definitions = &.{no_base},
    }));
    const no_model_definition: Definition = .{
        .id = @constCast("no-model"),
        .base_url = @constCast("https://missing.test/v1"),
    };
    try std.testing.expectError(error.MissingModel, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&no_model, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "no-model",
        .provider_definitions = &.{no_model_definition},
    }));
    var with_model = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer with_model.deinit();
    const unsupported: Definition = .{
        .id = @constCast("unsupported"),
        .base_url = @constCast("https://unsupported.test/v1"),
        .extra_body_json = @constCast("{}"),
    };
    try std.testing.expectError(error.UnsupportedSetting, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&with_model, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "unsupported",
        .provider_definitions = &.{unsupported},
    }));
}

test "config-only descriptor owns mutable definition fields and secrets" {
    const empty: TestEnvironment = .{};
    var id = "mutable-provider".*;
    var base = "https://mutable.test/v1".*;
    var display = "Mutable Provider".*;
    var catalog = "mutable-catalog".*;
    var key = "mutable-secret".*;
    var model = "mutable-model".*;
    var result: *Owned = undefined;
    {
        var document = try Document.parse(std.testing.allocator, "{\"model\":\"mutable-model\"}", .{});
        defer document.deinit();
        const definition: Definition = .{
            .id = &id,
            .base_url = &base,
            .display_name = &display,
            .catalog_id = &catalog,
            .api_key = &key,
        };
        result = try resolve(.{
            .allocator = std.testing.allocator,
            .store = testStore(&document, &empty),
            .api_key_environment = .from(&empty),
            .provider_override = &id,
            .provider_definitions = &.{definition},
        });
    }
    defer result.deinit();
    @memset(&id, 'x');
    @memset(&base, 'x');
    @memset(&display, 'x');
    @memset(&catalog, 'x');
    @memset(&key, 'x');
    @memset(&model, 'x');
    try std.testing.expectEqualStrings("mutable-provider", result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("Mutable Provider", result.resolved.metadata.display_name);
    try std.testing.expectEqualStrings("mutable-catalog", result.resolved.metadata.catalog_id.?);
    try std.testing.expectEqualStrings("mutable-secret", result.resolved.adapter.openai_chat.api_key.?);
}

test "compiled descriptors shadow config-only definitions" {
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENAI_API_KEY", .value = "key" }},
    };
    const shadow: Definition = .{
        .id = @constCast("openai"),
        .base_url = @constCast("https://shadow.test/v1"),
        .display_name = @constCast("Shadow"),
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"gpt\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_definitions = &.{shadow},
        .session_cache_key = "session",
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("openai", result.resolved.metadata.provider_id);
    try std.testing.expectEqualStrings("openai", result.resolved.metadata.display_name);
    try std.testing.expectEqualStrings("https://api.openai.com/v1/responses", result.resolved.endpoint);
}

test "compatible definition retains environment scalar precedence" {
    const environment: TestEnvironment = .{ .entries = &.{
        .{ .name = "ZI_OPENAI_BASE_URL", .value = "https://env-compatible.test/v1" },
        .{ .name = "ZI_OPENAI_DISPLAY_NAME", .value = "Environment Name" },
    } };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    const definition: Definition = .{
        .id = @constCast("openai-compatible"),
        .display_name = @constCast("Definition Name"),
    };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "openai-compatible",
        .provider_definitions = &.{definition},
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("https://env-compatible.test/v1/chat/completions", result.resolved.endpoint);
    try std.testing.expectEqualStrings("Environment Name", result.resolved.metadata.display_name);
}

test "invalid explicit API fails and raw model APIs retain catalog routing" {
    const empty: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"m\",\"providers\":{\"badapi\":{\"api\":\"soap\"," ++
            "\"base_url\":\"https://bad.test/v1\"},\"rawgateway\":{" ++
            "\"base_url\":\"https://gateway.test/v1\",\"model_apis\":{\"*\":\"soap\"}}}}",
        .{},
    );
    defer document.deinit();
    var definitions = try ProviderDefinitions.enumerate(std.testing.allocator, .{ .config = &document });
    defer definitions.deinit();
    try std.testing.expectError(error.InvalidSetting, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "badapi",
        .provider_definitions = definitions.definitions,
    }));
    var gateway = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "rawgateway",
        .provider_definitions = definitions.definitions,
        .hints = .{ .catalog_wire = .{ .wire = .openai_responses } },
    });
    defer gateway.deinit();
    try std.testing.expect(gateway.resolved.metadata.wire == .openai_responses);
}

test "custom reasoning replay field is copied and control-safe" {
    const empty: TestEnvironment = .{};
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    const definition: Definition = .{
        .id = @constCast("reasoning-provider"),
        .base_url = @constCast("https://reasoning.test/v1"),
        .reasoning_roundtrip = @constCast("vendor_reasoning_trace"),
    };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "reasoning-provider",
        .provider_definitions = &.{definition},
    });
    defer result.deinit();
    try std.testing.expectEqualStrings(
        "vendor_reasoning_trace",
        result.resolved.adapter.openai_chat.body.reasoning_field.?,
    );
    var invalid = definition;
    invalid.reasoning_roundtrip = @constCast("bad\nfield");
    try std.testing.expectError(error.InvalidSetting, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "reasoning-provider",
        .provider_definitions = &.{invalid},
    }));
}

test "invalid auto definition is skipped before a valid custom provider" {
    const empty: TestEnvironment = .{};
    const definitions = [_]Definition{
        .{ .id = @constCast("bad id"), .base_url = @constCast("https://bad.test/v1") },
        .{ .id = @constCast("valid-id"), .base_url = @constCast("https://valid.test/v1") },
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_definitions = &definitions,
    });
    defer result.deinit();
    try std.testing.expectEqualStrings("valid-id", result.resolved.metadata.provider_id);
}

test "combined rules reject excess before retained pattern copies" {
    const empty: TestEnvironment = .{};
    var configured: [Registry.maximum_rules]ProviderDefinitions.ModelApi = undefined;
    for (&configured, 0..) |*rule, index| {
        rule.* = .{ .pattern = @constCast(if (index == 0) "first" else "other"), .api = .openai_completions };
    }
    const injected = [_]Registry.Rule{.{ .pattern = "last", .target = .{ .wire = .openai_chat } }};
    const definition: Definition = .{
        .id = @constCast("too-many-rules"),
        .base_url = @constCast("https://rules.test/v1"),
        .model_apis = &configured,
        .model_apis_declared_nonempty = true,
    };
    var document = try Document.parse(std.testing.allocator, "{\"model\":\"m\"}", .{});
    defer document.deinit();
    try std.testing.expectError(error.TooManyRules, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &empty),
        .api_key_environment = .from(&empty),
        .provider_override = "too-many-rules",
        .provider_definitions = &.{definition},
        .rules = .{ .values = &injected },
    }));
}

const AllocatingModelHintsSource = struct {
    pub fn lookup(
        _: *AllocatingModelHintsSource,
        allocator: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        _ = try allocator.dupe(u8, "super-secret catalog lookup allocation");
        return .{ .metadata = .{ .context_window = 64 } };
    }
};

const TestModelHintsSource = struct {
    calls: usize = 0,
    expected_provider: []const u8,
    expected_model: []const u8,
    contribution: ai.ModelCatalog.Contribution = .{},

    pub fn lookup(
        self: *TestModelHintsSource,
        _: std.mem.Allocator,
        provider_id: []const u8,
        model_id: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        self.calls += 1;
        std.debug.assert(std.mem.eql(u8, self.expected_provider, provider_id));
        std.debug.assert(std.mem.eql(u8, self.expected_model, model_id));
        return self.contribution;
    }
};

const BatchModelHintsSource = struct {
    scalar_calls: usize = 0,
    batch_calls: usize = 0,

    pub fn lookup(
        self: *BatchModelHintsSource,
        _: std.mem.Allocator,
        _: []const u8,
        _: []const u8,
    ) error{OutOfMemory}!ai.ModelCatalog.Contribution {
        self.scalar_calls += 1;
        return .{};
    }

    pub fn lookupBatch(
        self: *BatchModelHintsSource,
        _: std.mem.Allocator,
        provider_id: []const u8,
        model_ids: []const []const u8,
        output: []ai.ModelCatalog.Contribution,
    ) error{OutOfMemory}!void {
        self.batch_calls += 1;
        std.debug.assert(std.mem.eql(u8, provider_id, "p"));
        for (model_ids, output, 1..) |_, *destination, context_window| {
            destination.* = .{ .metadata = .{ .context_window = context_window } };
        }
    }
};

test "model hints batch uses one callback and scalar sources retain bounded fallback" {
    const ids = [_][]const u8{ "a", "b", "c" };
    var output: [ids.len]ai.ModelCatalog.Contribution = undefined;
    var batch: BatchModelHintsSource = .{};
    try ModelHintsSource.from(&batch).lookupBatch(std.testing.allocator, "p", &ids, &output);
    try std.testing.expectEqual(@as(usize, 1), batch.batch_calls);
    try std.testing.expectEqual(@as(usize, 0), batch.scalar_calls);
    try std.testing.expectEqual(@as(u64, 3), output[2].metadata.context_window);

    var scalar: TestModelHintsSource = .{
        .expected_provider = "p",
        .expected_model = "same",
        .contribution = .{ .metadata = .{ .context_window = 9 } },
    };
    const same = [_][]const u8{ "same", "same", "same" };
    try ModelHintsSource.from(&scalar).lookupBatch(std.testing.allocator, "p", &same, &output);
    try std.testing.expectEqual(ids.len, scalar.calls);
    try std.testing.expectEqual(@as(u64, 9), output[1].metadata.context_window);
}

test "cached model hints lookup uses catalog identity once for compiled and dynamic providers" {
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "key" }},
    };
    var compiled_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-zen\",\"model\":\"compiled-model\"}",
        .{},
    );
    defer compiled_document.deinit();
    var compiled_source: TestModelHintsSource = .{
        .expected_provider = "opencode",
        .expected_model = "compiled-model",
    };
    var compiled = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&compiled_document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&compiled_source),
    });
    compiled.deinit();
    try std.testing.expectEqual(@as(usize, 1), compiled_source.calls);

    var dynamic_document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"custom\",\"model\":\"dynamic-model\"}",
        .{},
    );
    defer dynamic_document.deinit();
    const definition: Definition = .{
        .id = @constCast("custom"),
        .api = .catalog,
        .base_url = @constCast("https://custom.test/v1"),
        .catalog_id = @constCast("models-dev-custom"),
    };
    var dynamic_source: TestModelHintsSource = .{
        .expected_provider = "models-dev-custom",
        .expected_model = "dynamic-model",
    };
    var dynamic = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&dynamic_document, &environment),
        .api_key_environment = .from(&environment),
        .provider_definitions = &.{definition},
        .hints_source = .from(&dynamic_source),
    });
    dynamic.deinit();
    try std.testing.expectEqual(@as(usize, 1), dynamic_source.calls);
}

test "explicit catalog hints merge over cached metadata and wire" {
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "key" }},
    };
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-zen\",\"model\":\"model\"}",
        .{},
    );
    defer document.deinit();
    var source: TestModelHintsSource = .{
        .expected_provider = "opencode",
        .expected_model = "model",
        .contribution = .{
            .metadata = .{ .context_window = 100, .max_output = 200 },
            .wire = .{ .wire = .openai_responses },
        },
    };
    const explicit_catalog: ai.ModelMeta.Metadata = .{
        .context_window = 300,
        .wire = .openai_chat,
    };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&source),
        .hints = .{ .catalog = &explicit_catalog },
    });
    defer result.deinit();
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqual(@as(u64, 300), result.resolved.metadata.model.context_window);
    try std.testing.expectEqual(@as(u64, 200), result.resolved.metadata.model.max_output);
    try std.testing.expect(result.resolved.metadata.wire == .openai_chat);

    try std.testing.expectError(error.UnsupportedWire, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&source),
        .hints = .{ .catalog_wire = .unsupported },
    }));

    const conflicting_catalog: ai.ModelMeta.Metadata = .{ .wire = .openai_responses };
    var wire_override = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&source),
        .hints = .{
            .catalog = &conflicting_catalog,
            .catalog_wire = .{ .wire = .openai_chat },
        },
    });
    defer wire_override.deinit();
    try std.testing.expect(wire_override.resolved.metadata.wire == .openai_chat);
    try std.testing.expectEqual(@as(usize, 3), source.calls);
}

test "empty cached contribution preserves descriptor defaults and unsupported wire maps exactly" {
    const environment: TestEnvironment = .{
        .entries = &.{.{ .name = "OPENCODE_API_KEY", .value = "key" }},
    };
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"opencode-zen\",\"model\":\"model\"}",
        .{},
    );
    defer document.deinit();
    var empty_source: TestModelHintsSource = .{
        .expected_provider = "opencode",
        .expected_model = "model",
    };
    var result = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&empty_source),
    });
    try std.testing.expect(result.resolved.metadata.wire == .openai_chat);
    result.deinit();

    var unsupported_source: TestModelHintsSource = .{
        .expected_provider = "opencode",
        .expected_model = "model",
        .contribution = .{ .wire = .unsupported },
    };
    try std.testing.expectError(error.UnsupportedWire, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .hints_source = .from(&unsupported_source),
    }));
    try std.testing.expectEqual(@as(usize, 1), unsupported_source.calls);
}

test "catalog pending respects routing and authoritative empty clears stale facts" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\"}",
        .{},
    );
    defer document.deinit();
    const catalog_definition: Definition = .{
        .id = @constCast("pending-dynamic"),
        .api = .catalog,
        .base_url = @constCast("https://pending.test/v1"),
    };
    var source: TestModelHintsSource = .{
        .expected_provider = "pending-dynamic",
        .expected_model = "model",
        .contribution = .{ .metadata = .{ .context_window = 123 } },
    };
    var pending = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "pending-dynamic",
        .provider_definitions = &.{catalog_definition},
        .hints_source = .from(&source),
    });
    defer pending.deinit();
    try std.testing.expect(pending.catalogWirePending());
    try std.testing.expectEqual(@as(u64, 123), pending.resolved.metadata.model.context_window);
    try pending.applyAuthoritativeCatalog(.{});
    try std.testing.expect(!pending.catalogWirePending());
    try std.testing.expect(pending.resolved.metadata.wire == .openai_chat);
    try std.testing.expectEqual(@as(u64, 0), pending.resolved.metadata.model.context_window);

    const explicit_definition: Definition = .{
        .id = @constCast("explicit-dynamic"),
        .api = .openai_responses,
        .base_url = @constCast("https://explicit.test/v1"),
    };
    var explicit = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "explicit-dynamic",
        .provider_definitions = &.{explicit_definition},
    });
    defer explicit.deinit();
    try std.testing.expect(!explicit.catalogWirePending());

    const rule_definition: Definition = .{
        .id = @constCast("rule-dynamic"),
        .api = .openai_completions,
        .base_url = @constCast("https://rules.test/v1"),
        .model_apis_declared_nonempty = true,
    };
    const wire_rule: Registry.Rule = .{ .pattern = "*", .target = .{ .wire = .anthropic_messages } };
    var concrete_rule = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "rule-dynamic",
        .provider_definitions = &.{rule_definition},
        .rules = .{ .values = &.{wire_rule} },
    });
    defer concrete_rule.deinit();
    try std.testing.expect(!concrete_rule.catalogWirePending());

    const catalog_rule: Registry.Rule = .{ .pattern = "*", .target = .catalog };
    var routed_catalog = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "rule-dynamic",
        .provider_definitions = &.{rule_definition},
        .rules = .{ .values = &.{catalog_rule} },
    });
    defer routed_catalog.deinit();
    try std.testing.expect(routed_catalog.catalogWirePending());
}

test "authoritative catalog reclamps the original requested effort" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\",\"effort\":\"high\"}",
        .{},
    );
    defer document.deinit();
    const definition: Definition = .{
        .id = @constCast("effort-catalog"),
        .api = .catalog,
        .base_url = @constCast("https://effort.test/v1"),
    };
    const stale_high = try ai.Effort.Set.init(&.{"high"});
    var source: TestModelHintsSource = .{
        .expected_provider = "effort-catalog",
        .expected_model = "model",
        .contribution = .{ .metadata = .{ .efforts = stale_high } },
    };
    var owned = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "effort-catalog",
        .provider_definitions = &.{definition},
        .hints_source = .from(&source),
    });
    defer owned.deinit();
    try std.testing.expectEqualStrings("high", owned.requested_effort.?);
    try std.testing.expectEqualStrings("high", owned.effort.?);

    const known_low = try ai.Effort.Set.init(&.{"low"});
    try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = known_low } });
    try std.testing.expectEqualStrings("low", owned.effort.?);

    const known_empty = try ai.Effort.Set.init(&.{});
    try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = known_empty } });
    try std.testing.expectEqual(@as(?[]const u8, null), owned.effort);

    const later_high = try ai.Effort.Set.init(&.{"high"});
    try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = later_high } });
    try std.testing.expectEqualStrings("high", owned.effort.?);
}

test "repeated authoritative effort reclamps keep live allocation bytes bounded" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\",\"effort\":\"high\"}",
        .{},
    );
    defer document.deinit();
    const definition: Definition = .{
        .id = @constCast("bounded-effort-catalog"),
        .api = .catalog,
        .base_url = @constCast("https://effort.test/v1"),
    };
    const initial_high = try ai.Effort.Set.init(&.{"high"});
    const low = try ai.Effort.Set.init(&.{"low"});
    const high = try ai.Effort.Set.init(&.{"high"});
    var observing: ObservingAllocator = .{ .backing = std.testing.allocator };
    var owned = try resolve(.{
        .allocator = observing.allocator(),
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "bounded-effort-catalog",
        .provider_definitions = &.{definition},
        .hints = .{ .catalog = &.{ .efforts = initial_high } },
    });

    try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = low } });
    const low_live_bytes = observing.live_bytes;
    const allocations_before_high = observing.allocations;
    try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = high } });
    const allocations_per_apply = observing.allocations - allocations_before_high;
    const live_byte_bound = @max(low_live_bytes, observing.live_bytes);

    const live_before_oom = observing.live_bytes;
    observing.fail_index = observing.allocations + allocations_per_apply - 1;
    try std.testing.expectError(
        error.OutOfMemory,
        owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = low } }),
    );
    try std.testing.expectEqualStrings("high", owned.effort.?);
    try std.testing.expectEqual(live_before_oom, observing.live_bytes);
    observing.fail_index = null;

    const zeroed_before = observing.zeroed_frees;
    for (0..2000) |index| {
        const efforts = if (index % 2 == 0) low else high;
        try owned.applyAuthoritativeCatalog(.{ .metadata = .{ .efforts = efforts } });
        try std.testing.expect(observing.live_bytes <= live_byte_bound);
    }
    try std.testing.expectEqualStrings("high", owned.effort.?);
    try std.testing.expect(observing.zeroed_frees >= zeroed_before + 2000);

    owned.deinit();
    try std.testing.expectEqual(@as(usize, 0), observing.live_bytes);
}

test "authoritative catalog rebuild is transactional on allocation failure" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"model\":\"model\",\"effort\":\"high\"}",
        .{},
    );
    defer document.deinit();
    const efforts = try ai.Effort.Set.init(&.{"high"});
    const metadata: ai.ModelMeta.Metadata = .{ .efforts = efforts };
    const definition: Definition = .{
        .id = @constCast("oom-catalog"),
        .api = .catalog,
        .base_url = @constCast("https://oom.test/v1"),
        .api_key = @constCast("super-secret-authoritative"),
    };
    var observing: ObservingAllocator = .{ .backing = std.testing.allocator };
    var owned = try resolve(.{
        .allocator = observing.allocator(),
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .provider_override = "oom-catalog",
        .provider_definitions = &.{definition},
        .hints = .{ .catalog = &metadata },
    });
    observing.fail_index = observing.allocations;
    var failed = false;
    for (0..4096) |index| {
        const wire: ai.Wire = if (index % 2 == 0) .anthropic_messages else .openai_responses;
        const previous_wire = owned.resolved.metadata.wire;
        const previous_effort = owned.effort;
        const previous_endpoint = try std.testing.allocator.dupe(u8, owned.resolved.endpoint);
        defer std.testing.allocator.free(previous_endpoint);
        owned.applyAuthoritativeCatalog(.{ .wire = .{ .wire = wire } }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expect(owned.resolved.metadata.wire == previous_wire);
            try std.testing.expectEqualStrings(previous_effort.?, owned.effort.?);
            try std.testing.expectEqualStrings(previous_endpoint, owned.resolved.endpoint);
            failed = true;
            break;
        };
    }
    try std.testing.expect(failed);
    observing.fail_index = null;
    try owned.applyAuthoritativeCatalog(.{ .wire = .{ .wire = .openai_responses } });
    try std.testing.expect(owned.resolved.adapter == .openai_responses);
    owned.deinit();
    try std.testing.expect(!observing.secret_seen_on_free);
}

const ChoiceEnvironment = struct {
    pub fn get(_: *const ChoiceEnvironment, name: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, name, "OPENAI_API_KEY")) return "openai-secret";
        return null;
    }
};

fn exerciseProviderChoices(allocator: std.mem.Allocator) !void {
    const environment: ChoiceEnvironment = .{};
    const definitions = [_]Definition{
        .{ .id = @constCast("openai"), .display_name = @constCast("Zulu OpenAI") },
        .{
            .id = @constCast("custom-provider"),
            .api = .openai_completions,
            .base_url = @constCast("https://custom.test/v1"),
            .display_name = @constCast("Alpha Custom"),
        },
    };
    var choices = try providerChoices(allocator, .{
        .allocator = allocator,
        .store = .init(.{
            .registry = Settings.storeRegistry(),
            .environment = .from(&environment),
        }),
        .api_key_environment = .from(&environment),
        .provider_definitions = &definitions,
    });
    defer choices.deinit();
    try std.testing.expect(choices.values.len > Registry.order().len);
    try std.testing.expectEqualStrings("codex", choices.values[0].id);
    var openai_count: usize = 0;
    var saw_custom = false;
    for (choices.values) |choice| {
        if (std.mem.eql(u8, choice.id, "openai")) {
            openai_count += 1;
            try std.testing.expect(choice.available);
            try std.testing.expectEqualStrings("Zulu OpenAI", choice.label);
        }
        if (std.mem.eql(u8, choice.id, "custom-provider")) {
            saw_custom = true;
            try std.testing.expect(choice.available);
            try std.testing.expectEqualStrings("Alpha Custom", choice.label);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), openai_count);
    try std.testing.expect(saw_custom);
}

test "provider choices merge registry priority with config-only definitions" {
    try exerciseProviderChoices(std.testing.allocator);
}

test "provider choice ownership handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseProviderChoices, .{});
}

test "provider choices reject counts beyond the public bound" {
    const environment: ChoiceEnvironment = .{};
    const definitions = try std.testing.allocator.alloc(Definition, maximum_provider_choices + 1);
    defer std.testing.allocator.free(definitions);
    for (definitions) |*definition| definition.* = .{ .id = @constCast("x") };
    try std.testing.expectError(error.TooManyProviderChoices, providerChoices(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .store = .init(.{
            .registry = Settings.storeRegistry(),
            .environment = .from(&environment),
        }),
        .api_key_environment = .from(&environment),
        .provider_definitions = definitions,
    }));
}

test "provider choices reject retained data beyond the public bound" {
    const environment: ChoiceEnvironment = .{};
    const label = try std.testing.allocator.alloc(u8, maximum_provider_choice_bytes + 1);
    defer std.testing.allocator.free(label);
    @memset(label, 'x');
    const definition: Definition = .{
        .id = @constCast("bounded-provider"),
        .display_name = label,
    };
    try std.testing.expectError(error.ProviderChoicesTooLarge, providerChoices(std.testing.allocator, .{
        .allocator = std.testing.allocator,
        .store = .init(.{
            .registry = Settings.storeRegistry(),
            .environment = .from(&environment),
        }),
        .api_key_environment = .from(&environment),
        .provider_definitions = &.{definition},
    }));
}

test "llama reconciliation overrides configured IDs and can clear them" {
    const environment: TestEnvironment = .{};
    var document = try Document.parse(
        std.testing.allocator,
        "{\"provider\":\"llamacpp\",\"model\":\"configured\"}",
        .{},
    );
    defer document.deinit();
    var header_name = "X-Local".*;
    var header_value = "local-secret".*;
    var replaced = try resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .llama_reconciliation = .{ .replace = "served" },
        .prepared_headers = .{
            .provider_id = "llamacpp",
            .headers = &.{.{
                .name = &header_name,
                .value = &header_value,
                .privileged = true,
            }},
        },
    });
    defer replaced.deinit();
    @memset(&header_name, 'x');
    @memset(&header_value, 'x');
    try std.testing.expectEqualStrings("served", replaced.model);
    try std.testing.expect(replaced.model_discovered);
    try std.testing.expectEqual(@as(usize, 1), replaced.resolved.adapter.openai_chat.extra_headers.len);
    try std.testing.expectEqualStrings("X-Local", replaced.resolved.adapter.openai_chat.extra_headers[0].name);
    try std.testing.expectEqualStrings("local-secret", replaced.resolved.adapter.openai_chat.extra_headers[0].value);
    try std.testing.expect(replaced.resolved.adapter.openai_chat.extra_headers[0].privileged);

    try std.testing.expectError(error.MissingModel, resolve(.{
        .allocator = std.testing.allocator,
        .store = testStore(&document, &environment),
        .api_key_environment = .from(&environment),
        .llama_reconciliation = .clear,
    }));
}
