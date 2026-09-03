const std = @import("std");
const ApiKey = @import("ApiKey.zig");
const Document = @import("Document.zig");
const Preset = @import("Preset.zig");
const PromptValue = @import("PromptValue.zig");
const Store = @import("Store.zig");

const default_sentinel = Store.default_sentinel;

const Selection = @This();

pub const Tier = enum { run, conversation };

pub const Error = error{ OutOfMemory, TooLarge, Invalid };

pub const RestoreMetadata = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
};

pub const RestoreOutcome = enum {
    restored,
    no_preset,
    missing_preset,
    invalid_preset,
    mismatched_preset,
};

/// Explicit startup facts. A non-null environment value records presence even
/// when its bytes are empty; this is important for the shell's empty preset
/// sentinel.
pub const StartupInputs = struct {
    cli_provider: ?[]const u8 = null,
    cli_model: ?[]const u8 = null,
    cli_effort: ?[]const u8 = null,
    cli_preset: ?[]const u8 = null,
    env_provider: ?[]const u8 = null,
    env_model: ?[]const u8 = null,
    env_effort: ?[]const u8 = null,
    env_preset: ?[]const u8 = null,
    env_system_prompt: ?[]const u8 = null,
    effective_preset: ?[]const u8 = null,
    effective_preset_from_conversation: bool = false,
};

pub const Decision = struct {
    restore_resumed_preset: bool,
    run_preset: ?[]const u8,
    run_preset_explicit: bool,
    suppress_lower_preset: bool,
};

/// Pure adaptation of hax's resumed-preset suppression rules.
pub fn startupDecision(inputs: StartupInputs) Decision {
    const run_preset = inputs.cli_preset orelse inputs.env_preset;
    const replaces_resumed = inputs.cli_provider != null or inputs.cli_model != null or
        inputs.cli_effort != null or inputs.cli_preset != null or
        (inputs.env_preset != null and inputs.env_preset.?.len != 0);
    const has_per_setting = inputs.cli_provider != null or inputs.cli_model != null or
        inputs.cli_effort != null or inputs.env_provider != null or
        inputs.env_model != null or inputs.env_effort != null or
        inputs.env_system_prompt != null;
    const lower_is_eligible = run_preset == null and
        !inputs.effective_preset_from_conversation and
        inputs.effective_preset != null and inputs.effective_preset.?.len != 0;
    return .{
        .restore_resumed_preset = !replaces_resumed,
        .run_preset = run_preset,
        .run_preset_explicit = run_preset != null,
        .suppress_lower_preset = lower_is_eligible and has_per_setting,
    };
}

pub const RunInputs = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
    tint: ?[]const u8 = null,
    no_env: ?bool = null,
    no_agents_md: ?bool = null,
    no_skills: ?bool = null,
    no_subagents: ?bool = null,
    no_tasks: ?bool = null,
    no_session: ?bool = null,
};

pub const RunChange = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    exit_preset: bool = false,
};

/// Move-only prospective run overlay. Derive Store on demand because retaining
/// one here would point into this value and become invalid when it moves.
pub const PreparedRun = struct {
    document: Document,
    conversation: ?Document,
    tint: ?[]u8,
    options: Store.Options,
    exits_preset: bool,

    pub fn deinit(self: *PreparedRun, allocator: std.mem.Allocator) void {
        wipeDocument(&self.document);
        self.document.deinit();
        if (self.conversation) |*document| {
            wipeDocument(document);
            document.deinit();
        }
        if (self.tint) |value| {
            @memset(value, 0);
            allocator.free(value);
        }
        self.* = undefined;
    }

    /// Borrows this prepared value and its Selection collaborators.
    pub fn store(self: *const PreparedRun) Store {
        var options = self.options;
        options.run = &self.document;
        if (self.conversation) |*document| options.conversation = document;
        return .init(options);
    }
};

/// Move-only prospective replacement of one run-tier setting.
pub const PreparedOverride = struct {
    document: Document,
    options: Store.Options,

    pub fn deinit(self: *PreparedOverride) void {
        wipeDocument(&self.document);
        self.document.deinit();
        self.* = undefined;
    }

    /// Borrows this prepared value and Selection's stable collaborators.
    pub fn store(self: *const PreparedOverride) Store {
        var options = self.options;
        options.run = &self.document;
        return .init(options);
    }
};

/// Move-only complete prospective preset overlay.
pub const PreparedPreset = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    base_options: Store.Options,
    active: bool = true,

    pub fn store(self: *const PreparedPreset) Store {
        std.debug.assert(self.active);
        return overlayStore(
            self.base_options,
            &self.run_document,
            &self.conversation_document,
        );
    }

    pub fn deinit(self: *PreparedPreset) void {
        if (self.active) deinitOverlayValues(
            self.allocator,
            &self.run_document,
            &self.conversation_document,
            &self.run_tint,
            &self.conversation_tint,
        );
        self.* = undefined;
    }
};

/// Move-only complete prospective conversation restore overlay.
pub const PreparedRestore = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    outcome: RestoreOutcome,
    base_options: Store.Options,
    active: bool = true,

    pub fn store(self: *const PreparedRestore) Store {
        std.debug.assert(self.active);
        return overlayStore(
            self.base_options,
            &self.run_document,
            &self.conversation_document,
        );
    }

    pub fn deinit(self: *PreparedRestore) void {
        if (self.active) deinitOverlayValues(
            self.allocator,
            &self.run_document,
            &self.conversation_document,
            &self.run_tint,
            &self.conversation_tint,
        );
        self.* = undefined;
    }
};

/// Owns an overlay displaced by allocation-free publication.
pub const RetiredOverlay = struct {
    allocator: std.mem.Allocator,
    run_document: ?Document,
    conversation_document: ?Document,
    run_tint: ?[]u8,
    conversation_tint: ?[]u8,
    active: bool = true,

    pub fn deinit(self: *RetiredOverlay) void {
        if (self.active) deinitOverlayValues(
            self.allocator,
            &self.run_document,
            &self.conversation_document,
            &self.run_tint,
            &self.conversation_tint,
        );
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
base: Store.Options,
run: ?Document = null,
conversation: ?Document = null,
run_preset_tint: ?[]u8 = null,
conversation_preset_tint: ?[]u8 = null,

/// Selection owns only its mutable overlays. All Store collaborators and base
/// documents remain borrowed. A Store returned by store() is invalidated by
/// the next mutation or deinit.
pub fn init(allocator: std.mem.Allocator, base: Store.Options) Selection {
    return .{ .allocator = allocator, .base = base };
}

pub fn deinit(self: *Selection) void {
    self.clearOwnedDocument(&self.run);
    self.clearOwnedDocument(&self.conversation);
    self.freeSecret(&self.run_preset_tint);
    self.freeSecret(&self.conversation_preset_tint);
    self.* = undefined;
}

pub fn store(self: *const Selection) Store {
    var options = self.base;
    options.run = if (self.run) |*document| document else self.base.run;
    options.conversation = if (self.conversation) |*document| document else self.base.conversation;
    return .init(options);
}

/// Returns the active preset tint. The run stance shadows the conversation
/// stance. An explicit run-tier tint remains a normal Store setting.
pub fn presetTint(self: *const Selection) ?[]const u8 {
    if (self.run_preset_tint) |value| return value;
    return self.conversation_preset_tint;
}

pub fn exitPreset(self: *Selection, tier: Tier) Error!void {
    switch (tier) {
        .conversation => {
            try self.replaceTier(.conversation, &.{
                .{ .key = "preset", .value = "" },
                .{ .key = "system_prompt", .value = null },
                .{ .key = "system_prompt_append", .value = null },
            });
            self.freeSecret(&self.conversation_preset_tint);
        },
        .run => {
            // Prepare both replacements before publishing either one.
            var new_run = try self.changedDocument(.run, &.{
                .{ .key = "preset", .value = "" },
                .{ .key = "system_prompt", .value = null },
                .{ .key = "system_prompt_append", .value = null },
            });
            errdefer {
                wipeDocument(&new_run);
                new_run.deinit();
            }
            const new_conversation = try self.changedDocument(.conversation, &.{
                .{ .key = "preset", .value = null },
                .{ .key = "system_prompt", .value = null },
                .{ .key = "system_prompt_append", .value = null },
            });
            self.publishDocument(.run, new_run);
            self.publishDocument(.conversation, new_conversation);
            self.freeSecret(&self.run_preset_tint);
            self.freeSecret(&self.conversation_preset_tint);
        },
    }
}

/// Builds a complete prospective preset overlay without changing Selection.
pub fn preparePreset(self: *const Selection, tier: Tier, plan: *const Preset.Plan) Error!PreparedPreset {
    const plan_changes = [_]Change{
        .{ .key = "preset", .value = plan.name },
        .{ .key = "provider", .value = plan.provider },
        .{ .key = "model", .value = plan.model.value orelse default_sentinel },
        .{ .key = "effort", .value = plan.effort.value orelse default_sentinel },
        .{ .key = "system_prompt", .value = plan.system_prompt.value },
        .{ .key = "system_prompt_append", .value = plan.system_prompt_append.value },
    };
    try validateChanges(&plan_changes);

    var prepared: PreparedPreset = .{
        .allocator = self.allocator,
        .run_document = null,
        .conversation_document = null,
        .run_tint = null,
        .conversation_tint = null,
        .base_options = self.base,
    };
    errdefer prepared.deinit();
    switch (tier) {
        .conversation => {
            prepared.run_document = try self.cloneOptionalDocument(&self.run);
            prepared.conversation_document = try self.changedDocument(.conversation, &plan_changes);
            prepared.run_tint = try self.copyOptional(self.run_preset_tint);
            prepared.conversation_tint = try self.copyOptional(plan.tint.value);
        },
        .run => {
            prepared.run_document = try self.changedDocument(.run, &plan_changes);
            prepared.conversation_document = try self.changedDocument(.conversation, &.{
                .{ .key = "preset", .value = null },
                .{ .key = "system_prompt", .value = null },
                .{ .key = "system_prompt_append", .value = null },
            });
            prepared.run_tint = try self.copyOptional(plan.tint.value);
        },
    }
    return prepared;
}

/// Consumes prepared, installs it without allocation, and returns the displaced overlay.
pub fn publishPreset(self: *Selection, prepared: *PreparedPreset) RetiredOverlay {
    std.debug.assert(prepared.active);
    std.debug.assert(prepared.allocator.ptr == self.allocator.ptr);
    std.debug.assert(prepared.allocator.vtable == self.allocator.vtable);
    const retired = self.replaceOverlay(
        &prepared.run_document,
        &prepared.conversation_document,
        &prepared.run_tint,
        &prepared.conversation_tint,
    );
    prepared.active = false;
    return retired;
}

/// Applies an already validated Plan as one overlay transaction. The Plan is
/// borrowed and remains owned by its caller.
pub fn applyPreset(self: *Selection, tier: Tier, plan: *const Preset.Plan) Error!void {
    var prepared = try self.preparePreset(tier, plan);
    defer prepared.deinit();
    var retired = self.publishPreset(&prepared);
    defer retired.deinit();
}

/// Restores provider-bound metadata and the recorded preset stance. A missing
/// or invalid lookup is reported after the core selection is restored, which
/// matches hax's resume behavior. No mutation occurs until every replacement
/// allocation succeeds.
pub fn prepareRestoreConversation(
    self: *const Selection,
    metadata: RestoreMetadata,
    lookup: ?*const Preset.Lookup,
) Error!PreparedRestore {
    return self.prepareRestoreOverlay(metadata, lookup, false);
}

/// Prepares a runtime resume stance. Recorded selection fields replace current
/// run-tier selection overrides while unrelated run settings remain.
pub fn prepareRestoreRun(
    self: *const Selection,
    metadata: RestoreMetadata,
    lookup: ?*const Preset.Lookup,
) Error!PreparedRestore {
    return self.prepareRestoreOverlay(metadata, lookup, true);
}

fn prepareRestoreOverlay(
    self: *const Selection,
    metadata: RestoreMetadata,
    lookup: ?*const Preset.Lookup,
    clear_run_selection: bool,
) Error!PreparedRestore {
    var changes: [13]Change = undefined;
    var count: usize = 0;
    if (metadata.provider) |provider| {
        if (provider.len != 0 and !std.mem.eql(u8, provider, "none")) {
            appendChange(&changes, &count, "provider", provider);
            appendChange(&changes, &count, "model", nonemptyOrDefault(metadata.model));
            appendChange(&changes, &count, "effort", nonemptyOrDefault(metadata.effort));
        }
    }
    appendChange(&changes, &count, "preset", "");
    appendChange(&changes, &count, "system_prompt", null);
    appendChange(&changes, &count, "system_prompt_append", null);

    const recorded = metadata.preset;
    var outcome: RestoreOutcome = .no_preset;
    var plan: ?*const Preset.Plan = null;
    if (recorded) |name| if (name.len != 0) {
        if (lookup) |candidate| switch (candidate.*) {
            .missing => outcome = .missing_preset,
            .invalid => outcome = .invalid_preset,
            .plan => |*value| {
                if (!std.mem.eql(u8, name, value.name)) {
                    outcome = .mismatched_preset;
                } else {
                    plan = value;
                    outcome = .restored;
                    appendPlanChanges(&changes, &count, value);
                }
            },
        } else outcome = .missing_preset;
    };

    try validateChanges(changes[0..count]);
    var prepared: PreparedRestore = .{
        .allocator = self.allocator,
        .run_document = null,
        .conversation_document = null,
        .run_tint = null,
        .conversation_tint = null,
        .outcome = outcome,
        .base_options = self.base,
    };
    errdefer prepared.deinit();
    if (clear_run_selection) {
        prepared.run_document = try self.changedDocument(.run, &.{
            .{ .key = "provider", .value = null },
            .{ .key = "model", .value = null },
            .{ .key = "effort", .value = null },
            .{ .key = "preset", .value = null },
            .{ .key = "system_prompt", .value = null },
            .{ .key = "system_prompt_append", .value = null },
        });
        prepared.run_tint = null;
    } else {
        prepared.run_document = try self.cloneOptionalDocument(&self.run);
        prepared.run_tint = try self.copyOptional(self.run_preset_tint);
    }
    prepared.conversation_document = try self.changedDocument(.conversation, changes[0..count]);
    prepared.conversation_tint = if (plan) |value| try self.copyOptional(value.tint.value) else null;
    return prepared;
}

/// Consumes prepared, installs it without allocation, and returns the displaced overlay.
pub fn publishRestoreConversation(self: *Selection, prepared: *PreparedRestore) RetiredOverlay {
    std.debug.assert(prepared.active);
    std.debug.assert(prepared.allocator.ptr == self.allocator.ptr);
    std.debug.assert(prepared.allocator.vtable == self.allocator.vtable);
    const retired = self.replaceOverlay(
        &prepared.run_document,
        &prepared.conversation_document,
        &prepared.run_tint,
        &prepared.conversation_tint,
    );
    prepared.active = false;
    return retired;
}

/// Restores provider-bound metadata and the recorded preset stance. A missing
/// or invalid lookup is reported after the core selection is restored, which
/// matches hax's resume behavior. No mutation occurs until every replacement
/// allocation succeeds.
pub fn restoreConversation(
    self: *Selection,
    metadata: RestoreMetadata,
    lookup: ?*const Preset.Lookup,
) Error!RestoreOutcome {
    var prepared = try self.prepareRestoreConversation(metadata, lookup);
    defer prepared.deinit();
    const outcome = prepared.outcome;
    var retired = self.publishRestoreConversation(&prepared);
    defer retired.deinit();
    return outcome;
}

/// Writes only fields explicitly present in inputs, so empty strings and
/// false values remain meaningful run overrides.
pub fn setRun(self: *Selection, inputs: RunInputs) Error!void {
    var changes: [11]Change = undefined;
    var count: usize = 0;
    appendOptional(&changes, &count, "provider", inputs.provider);
    appendOptional(&changes, &count, "model", inputs.model);
    appendOptional(&changes, &count, "effort", inputs.effort);
    appendOptional(&changes, &count, "preset", inputs.preset);
    appendOptional(&changes, &count, "tint", inputs.tint);
    appendBoolean(&changes, &count, "no_env", inputs.no_env);
    appendBoolean(&changes, &count, "no_agents_md", inputs.no_agents_md);
    appendBoolean(&changes, &count, "no_skills", inputs.no_skills);
    appendBoolean(&changes, &count, "no_subagents", inputs.no_subagents);
    appendBoolean(&changes, &count, "no_tasks", inputs.no_tasks);
    appendBoolean(&changes, &count, "no_session", inputs.no_session);
    if (count != 0) try self.replaceTier(.run, changes[0..count]);
}

/// Builds a complete prospective run document changing exactly one key.
pub fn prepareRunOverride(
    self: *const Selection,
    key: []const u8,
    value: ?[]const u8,
) Error!PreparedOverride {
    var document = try self.changedDocument(.run, &.{.{ .key = key, .value = value }});
    errdefer {
        wipeDocument(&document);
        document.deinit();
    }
    var options = self.base;
    options.conversation = if (self.conversation) |*current| current else self.base.conversation;
    return .{ .document = document, .options = options };
}

/// Consumes a prepared override, installs it without allocation, and returns
/// the displaced run document for cleanup after publication.
pub fn publishRunOverrideRetired(
    self: *Selection,
    prepared: *PreparedOverride,
) RetiredOverlay {
    const retired: RetiredOverlay = .{
        .allocator = self.allocator,
        .run_document = self.run,
        .conversation_document = null,
        .run_tint = null,
        .conversation_tint = null,
    };
    self.run = prepared.document;
    prepared.document = undefined;
    prepared.* = undefined;
    return retired;
}

pub fn publishRunOverride(self: *Selection, prepared: *PreparedOverride) void {
    var retired = self.publishRunOverrideRetired(prepared);
    retired.deinit();
}

/// Builds a complete prospective run stance without changing Selection.
/// Provider replacement clears stale model and effort before applying any
/// explicit final values carried by the same change.
pub fn prepareRun(self: *const Selection, change: RunChange) Error!PreparedRun {
    var changes: [7]Change = undefined;
    var count: usize = 0;
    if (change.provider) |provider| {
        appendChange(&changes, &count, "provider", provider);
        appendChange(&changes, &count, "model", change.model orelse default_sentinel);
        appendChange(&changes, &count, "effort", change.effort orelse default_sentinel);
    } else {
        appendOptional(&changes, &count, "model", change.model);
        appendOptional(&changes, &count, "effort", change.effort);
    }

    const exits_preset = change.exit_preset or change.provider != null or
        change.model != null or change.effort != null;
    if (exits_preset) {
        appendChange(&changes, &count, "preset", "");
        appendChange(&changes, &count, "system_prompt", null);
        appendChange(&changes, &count, "system_prompt_append", null);
    }

    var document = try self.changedDocument(.run, changes[0..count]);
    errdefer {
        wipeDocument(&document);
        document.deinit();
    }
    var conversation: ?Document = null;
    errdefer if (conversation) |*value| {
        wipeDocument(value);
        value.deinit();
    };
    if (exits_preset) conversation = try self.changedDocument(.conversation, &.{
        .{ .key = "preset", .value = null },
        .{ .key = "system_prompt", .value = null },
        .{ .key = "system_prompt_append", .value = null },
    });
    const tint = if (!exits_preset) try self.copyOptional(self.run_preset_tint) else null;

    var options = self.base;
    options.conversation = if (self.conversation) |*value| value else self.base.conversation;
    return .{
        .document = document,
        .conversation = conversation,
        .tint = tint,
        .options = options,
        .exits_preset = exits_preset,
    };
}

/// Consumes prepared, installs it without allocation or cleanup, and returns
/// every displaced owned value for destruction after publication.
pub fn publishRunRetired(self: *Selection, prepared: *PreparedRun) RetiredOverlay {
    const retired: RetiredOverlay = .{
        .allocator = self.allocator,
        .run_document = self.run,
        .conversation_document = if (prepared.conversation != null) self.conversation else null,
        .run_tint = self.run_preset_tint,
        .conversation_tint = if (prepared.exits_preset) self.conversation_preset_tint else null,
    };
    self.run = prepared.document;
    prepared.document = undefined;
    if (prepared.conversation) |document| {
        self.conversation = document;
        prepared.conversation = null;
    }
    self.run_preset_tint = prepared.tint;
    prepared.tint = null;
    if (prepared.exits_preset) self.conversation_preset_tint = null;
    prepared.* = undefined;
    return retired;
}

/// Direct wrapper for ordinary selection commits.
pub fn publishRun(self: *Selection, prepared: *PreparedRun) void {
    var retired = self.publishRunRetired(prepared);
    retired.deinit();
}

const Change = struct { key: []const u8, value: ?[]const u8 };

fn appendChange(changes: []Change, count: *usize, key: []const u8, value: ?[]const u8) void {
    changes[count.*] = .{ .key = key, .value = value };
    count.* += 1;
}

fn appendOptional(changes: []Change, count: *usize, key: []const u8, value: ?[]const u8) void {
    if (value) |text| appendChange(changes, count, key, text);
}

fn appendBoolean(changes: []Change, count: *usize, key: []const u8, value: ?bool) void {
    if (value) |boolean| appendChange(changes, count, key, if (boolean) "1" else "0");
}

fn appendPlanChanges(changes: []Change, count: *usize, plan: *const Preset.Plan) void {
    appendChange(changes, count, "preset", plan.name);
    appendChange(changes, count, "provider", plan.provider);
    appendChange(changes, count, "model", plan.model.value orelse default_sentinel);
    appendChange(changes, count, "effort", plan.effort.value orelse default_sentinel);
    appendChange(changes, count, "system_prompt", plan.system_prompt.value);
    appendChange(changes, count, "system_prompt_append", plan.system_prompt_append.value);
    appendChange(changes, count, "tint", null);
}

fn nonemptyOrDefault(value: ?[]const u8) []const u8 {
    if (value) |text| if (text.len != 0) return text;
    return default_sentinel;
}

fn tierDocument(self: *const Selection, tier: Tier) ?*const Document {
    return switch (tier) {
        .run => if (self.run) |*document| document else self.base.run,
        .conversation => if (self.conversation) |*document| document else self.base.conversation,
    };
}

fn validateChanges(changes: []const Change) Error!void {
    for (changes) |change| {
        if (change.key.len > Document.runtime_limits.max_string_bytes) return error.TooLarge;
        if (change.value) |value| {
            if (value.len > Document.runtime_limits.max_string_bytes) return error.TooLarge;
        }
    }
}

fn cloneOptionalDocument(self: *const Selection, source: *const ?Document) Error!?Document {
    return if (source.*) |*document| try self.cloneDocument(document) else null;
}

fn cloneDocument(self: *const Selection, source: *const Document) Error!Document {
    var scratch: Document.WipingAllocator = .{ .backing = self.allocator };
    const scratch_allocator = scratch.allocator();
    const bytes = std.json.Stringify.valueAlloc(
        scratch_allocator,
        source.parsed.value,
        .{},
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, bytes);
        scratch_allocator.free(bytes);
    }
    return Document.parse(self.allocator, bytes, Document.runtime_limits) catch |err|
        return mapDocumentError(err);
}

fn changedDocument(self: *const Selection, tier: Tier, changes: []const Change) Error!Document {
    try validateChanges(changes);
    const source = self.tierDocument(tier);
    var scratch: Document.WipingAllocator = .{ .backing = self.allocator };
    const scratch_allocator = scratch.allocator();
    const bytes = if (source) |document|
        std.json.Stringify.valueAlloc(scratch_allocator, document.parsed.value, .{}) catch return error.OutOfMemory
    else
        scratch_allocator.dupe(u8, "{}") catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, bytes);
        scratch_allocator.free(bytes);
    }
    var result = Document.parse(self.allocator, bytes, Document.runtime_limits) catch |err|
        return mapDocumentError(err);
    errdefer {
        wipeDocument(&result);
        result.deinit();
    }
    const allocator = result.parsed.arena.allocator();
    var object = &result.parsed.value.object;
    for (changes) |change| {
        if (change.value) |value| {
            const owned_value = try allocator.dupe(u8, value);
            var inserted = false;
            errdefer if (!inserted) @memset(owned_value, 0);
            const key = if (object.contains(change.key)) change.key else try allocator.dupe(u8, change.key);
            if (object.getPtr(change.key)) |old_value| wipeValue(old_value);
            try object.put(allocator, key, .{ .string = owned_value });
            inserted = true;
        } else {
            if (object.getPtr(change.key)) |old_value| wipeValue(old_value);
            _ = object.swapRemove(change.key);
        }
    }

    const final_bytes = std.json.Stringify.valueAlloc(
        scratch_allocator,
        result.parsed.value,
        .{},
    ) catch return error.OutOfMemory;
    defer {
        std.crypto.secureZero(u8, final_bytes);
        scratch_allocator.free(final_bytes);
    }
    const validated = Document.parse(
        self.allocator,
        final_bytes,
        Document.runtime_limits,
    ) catch |err| return mapDocumentError(err);
    wipeDocument(&result);
    result.deinit();
    return validated;
}

fn mapDocumentError(err: Document.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.InputTooLarge,
        error.StringTooLong,
        error.NestingTooDeep,
        error.TooManyFields,
        error.TooManyTokens,
        => error.TooLarge,
        error.InvalidLimits,
        error.InvalidJson,
        error.NumberOutOfRange,
        error.RootNotObject,
        => error.Invalid,
    };
}

fn replaceTier(self: *Selection, tier: Tier, changes: []const Change) Error!void {
    const document = try self.changedDocument(tier, changes);
    self.publishDocument(tier, document);
}

fn replaceOverlay(
    self: *Selection,
    run_document: *?Document,
    conversation_document: *?Document,
    run_tint: *?[]u8,
    conversation_tint: *?[]u8,
) RetiredOverlay {
    const retired: RetiredOverlay = .{
        .allocator = self.allocator,
        .run_document = self.run,
        .conversation_document = self.conversation,
        .run_tint = self.run_preset_tint,
        .conversation_tint = self.conversation_preset_tint,
    };
    self.run = run_document.*;
    self.conversation = conversation_document.*;
    self.run_preset_tint = run_tint.*;
    self.conversation_preset_tint = conversation_tint.*;
    run_document.* = null;
    conversation_document.* = null;
    run_tint.* = null;
    conversation_tint.* = null;
    return retired;
}

fn publishDocument(self: *Selection, tier: Tier, document: Document) void {
    const destination = switch (tier) {
        .run => &self.run,
        .conversation => &self.conversation,
    };
    self.clearOwnedDocument(destination);
    destination.* = document;
}

fn clearOwnedDocument(self: *Selection, document: *?Document) void {
    _ = self;
    if (document.*) |*value| {
        wipeDocument(value);
        value.deinit();
    }
    document.* = null;
}

fn overlayStore(
    base_options: Store.Options,
    run_document: *const ?Document,
    conversation_document: *const ?Document,
) Store {
    var options = base_options;
    options.run = if (run_document.*) |*document| document else base_options.run;
    options.conversation = if (conversation_document.*) |*document| document else base_options.conversation;
    return .init(options);
}

fn deinitOverlayValues(
    allocator: std.mem.Allocator,
    run_document: *?Document,
    conversation_document: *?Document,
    run_tint: *?[]u8,
    conversation_tint: *?[]u8,
) void {
    deinitOptionalDocument(run_document);
    deinitOptionalDocument(conversation_document);
    freeOptionalSecret(allocator, run_tint);
    freeOptionalSecret(allocator, conversation_tint);
}

fn deinitOptionalDocument(document: *?Document) void {
    if (document.*) |*value| {
        wipeDocument(value);
        value.deinit();
    }
    document.* = null;
}

fn freeOptionalSecret(allocator: std.mem.Allocator, value: *?[]u8) void {
    if (value.*) |bytes| {
        @memset(bytes, 0);
        allocator.free(bytes);
    }
    value.* = null;
}

fn wipeDocument(document: *Document) void {
    var iterator = document.parsed.value.object.iterator();
    while (iterator.next()) |entry| wipeValue(entry.value_ptr);
}

fn wipeValue(value: *std.json.Value) void {
    switch (value.*) {
        .string => |text| @memset(@constCast(text), 0),
        .array => |*array| for (array.items) |*item| wipeValue(item),
        .object => |*object| {
            var iterator = object.iterator();
            while (iterator.next()) |entry| wipeValue(entry.value_ptr);
        },
        else => {},
    }
}

fn copyOptional(self: *const Selection, value: ?[]const u8) Error!?[]u8 {
    return if (value) |text| self.allocator.dupe(u8, text) catch error.OutOfMemory else null;
}

fn publishTint(self: *Selection, tier: Tier, value: ?[]u8) void {
    const destination = switch (tier) {
        .run => &self.run_preset_tint,
        .conversation => &self.conversation_preset_tint,
    };
    self.freeSecret(destination);
    destination.* = value;
}

fn freeSecret(self: *Selection, value: *?[]u8) void {
    if (value.*) |bytes| self.wipeFree(bytes);
    value.* = null;
}

fn wipeFree(self: *Selection, value: []u8) void {
    @memset(value, 0);
    self.allocator.free(value);
}

const TestRegistry = struct {
    pub fn find(_: *const TestRegistry, key: []const u8) ?Store.Setting {
        if (std.mem.eql(u8, key, "tint")) return .{ .default_value = "teal" };
        return .{ .keep_empty = true };
    }
};

const TestEnvironment = struct {
    pub fn get(_: *const TestEnvironment, _: []const u8) ?[]const u8 {
        return null;
    }
};

fn testBase(file: ?*const Document, state: ?*const Document) Store.Options {
    const Static = struct {
        var registry: TestRegistry = .{};
        var environment: TestEnvironment = .{};
    };
    return .{
        .file = file,
        .state = state,
        .registry = .from(&Static.registry),
        .environment = .from(&Static.environment),
    };
}

fn expectSelectionRead(selection: *const Selection, key: []const u8, expected: []const u8, source: Store.Source) !void {
    var result = try selection.store().read(std.testing.allocator, key);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(source, result.source);
    try std.testing.expectEqualStrings(expected, result.value.?);
}

fn testPlan() Preset.Plan {
    return .{
        .name = @constCast("work"),
        .provider = @constCast("p"),
        .model = .{ .value = @constCast("preset-model") },
        .effort = .{},
        .system_prompt = .{ .value = @constCast("secret prompt") },
        .system_prompt_append = .{},
        .tint = .{ .value = @constCast("rose") },
        .description = .{},
    };
}

test "restore preserves provider binding and preset defaults" {
    var file = try Document.parse(std.testing.allocator, "{\"provider\":\"p\",\"model\":\"file-model\"}", .{});
    defer file.deinit();
    var selection = Selection.init(std.testing.allocator, testBase(&file, null));
    defer selection.deinit();
    const plan = testPlan();
    const lookup: Preset.Lookup = .{ .plan = plan };
    try std.testing.expectEqual(.restored, try selection.restoreConversation(.{
        .provider = "p",
        .model = "recorded",
        .preset = "work",
    }, &lookup));
    try expectSelectionRead(&selection, "model", "preset-model", .conversation);
    var effort = try selection.store().read(std.testing.allocator, "effort");
    defer effort.deinit(std.testing.allocator);
    try std.testing.expectEqual(Store.Source.conversation, effort.source);
    try std.testing.expect(effort.value == null);
    try std.testing.expectEqualStrings("rose", selection.presetTint().?);
}

test "preset application is atomic and run overrides follow it" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    const plan = testPlan();
    try selection.applyPreset(.run, &plan);
    try selection.setRun(.{ .model = "cli-model", .effort = "", .tint = "sage", .no_tasks = true });
    try expectSelectionRead(&selection, "provider", "p", .run);
    try expectSelectionRead(&selection, "model", "cli-model", .run);
    try expectSelectionRead(&selection, "effort", "", .run);
    try expectSelectionRead(&selection, "tint", "sage", .run);
    try expectSelectionRead(&selection, "no_tasks", "1", .run);
    try selection.exitPreset(.run);
    try expectSelectionRead(&selection, "preset", "", .run);
    var prompt = try selection.store().read(std.testing.allocator, "system_prompt");
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(prompt.value == null);
}

test "run preset exit deletes the resumed stance and prompt" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    const plan = testPlan();
    const lookup: Preset.Lookup = .{ .plan = plan };
    _ = try selection.restoreConversation(.{ .preset = "work" }, &lookup);
    try selection.exitPreset(.run);
    try expectSelectionRead(&selection, "preset", "", .run);
    var below = try selection.store().readBelowRun(std.testing.allocator, "preset");
    defer below.deinit(std.testing.allocator);
    try std.testing.expect(below.value == null);
}

test "startup suppression matrix is explicit" {
    try std.testing.expect(startupDecision(.{}).restore_resumed_preset);
    try std.testing.expect(startupDecision(.{ .env_preset = "" }).restore_resumed_preset);
    try std.testing.expect(!startupDecision(.{ .env_preset = "work" }).restore_resumed_preset);
    try std.testing.expect(!startupDecision(.{ .cli_model = "m" }).restore_resumed_preset);
    try std.testing.expect(startupDecision(.{
        .effective_preset = "saved",
        .env_model = "",
    }).suppress_lower_preset);
    try std.testing.expect(!startupDecision(.{
        .effective_preset = "saved",
        .effective_preset_from_conversation = true,
        .env_model = "m",
    }).suppress_lower_preset);
}

fn exerciseSelectionAllocationFailures(allocator: std.mem.Allocator) !void {
    var selection = Selection.init(allocator, testBase(null, null));
    defer selection.deinit();
    const plan = testPlan();
    try selection.applyPreset(.run, &plan);
    try selection.setRun(.{ .model = "override", .no_env = true, .no_session = false });
    try selection.exitPreset(.run);
}

test "mutations roll back and release allocations on OOM" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseSelectionAllocationFailures, .{});
}

fn conversationPlan() Preset.Plan {
    var plan = testPlan();
    plan.name = @constCast("resumed");
    plan.provider = @constCast("conversation-provider");
    plan.tint.value = @constCast("amber");
    return plan;
}

fn runPlanWithoutPromptOrTint() Preset.Plan {
    return .{
        .name = @constCast("fresh"),
        .provider = @constCast("new-provider"),
        .model = .{},
        .effort = .{},
        .system_prompt = .{},
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    };
}

test "new run preset cannot expose a resumed prompt or tint" {
    var file = try Document.parse(std.testing.allocator, "{\"system_prompt\":\"ordinary prompt\"}", .{});
    defer file.deinit();
    var selection = Selection.init(std.testing.allocator, testBase(&file, null));
    defer selection.deinit();
    const resumed = testPlan();
    const lookup: Preset.Lookup = .{ .plan = resumed };
    _ = try selection.restoreConversation(.{ .preset = "work" }, &lookup);
    var resumed_prompt = try selection.store().read(std.testing.allocator, "system_prompt");
    defer resumed_prompt.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("secret prompt", resumed_prompt.value.?);

    const fresh = runPlanWithoutPromptOrTint();
    try selection.applyPreset(.run, &fresh);
    try expectSelectionRead(&selection, "system_prompt", "ordinary prompt", .config);
    try std.testing.expect(selection.presetTint() == null);
    var below_preset = try selection.store().readBelowRun(std.testing.allocator, "preset");
    defer below_preset.deinit(std.testing.allocator);

    try std.testing.expect(below_preset.value == null);
}

fn exerciseDualStagePresetAllocationFailures(allocator: std.mem.Allocator) !void {
    var file = try Document.parse(allocator, "{\"system_prompt\":\"ordinary prompt\"}", .{});
    defer file.deinit();
    var selection = Selection.init(allocator, testBase(&file, null));
    defer selection.deinit();
    const resumed = testPlan();
    const lookup: Preset.Lookup = .{ .plan = resumed };
    _ = try selection.restoreConversation(.{ .preset = "work" }, &lookup);
    try selection.setRun(.{ .provider = "old-run" });

    const fresh = runPlanWithoutPromptOrTint();
    selection.applyPreset(.run, &fresh) catch |err| {
        try expectSelectionRead(&selection, "provider", "old-run", .run);
        var below_preset = try selection.store().readBelowRun(std.testing.allocator, "preset");
        defer below_preset.deinit(std.testing.allocator);
        try std.testing.expectEqual(Store.Source.conversation, below_preset.source);
        try std.testing.expectEqualStrings("work", below_preset.value.?);
        var prompt = try selection.store().readBelowRun(std.testing.allocator, "system_prompt");
        defer prompt.deinit(std.testing.allocator);
        try std.testing.expectEqual(Store.Source.conversation, prompt.source);
        try std.testing.expectEqualStrings("secret prompt", prompt.value.?);
        try std.testing.expectEqualStrings("rose", selection.presetTint().?);
        return err;
    };

    try expectSelectionRead(&selection, "provider", "new-provider", .run);
    try expectSelectionRead(&selection, "system_prompt", "ordinary prompt", .config);
    try std.testing.expect(selection.presetTint() == null);
}

test "run preset dual-document staging rolls back on every OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseDualStagePresetAllocationFailures,
        .{},
    );
}

test "oversized run values and plans reject before either tier changes" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    try selection.setRun(.{ .provider = "old-run", .model = "old-model" });
    const resumed = testPlan();
    const lookup: Preset.Lookup = .{ .plan = resumed };
    _ = try selection.restoreConversation(.{ .preset = "work" }, &lookup);

    const oversized = try std.testing.allocator.alloc(u8, Document.maximum_runtime_string_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.TooLarge, selection.setRun(.{ .model = oversized }));
    try expectSelectionRead(&selection, "provider", "old-run", .run);
    try expectSelectionRead(&selection, "model", "old-model", .run);

    var plan = runPlanWithoutPromptOrTint();
    plan.system_prompt.value = oversized;
    try std.testing.expectError(error.TooLarge, selection.applyPreset(.run, &plan));
    try expectSelectionRead(&selection, "provider", "old-run", .run);
    var below = try selection.store().readBelowRun(std.testing.allocator, "preset");
    defer below.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("work", below.value.?);
    try std.testing.expectEqualStrings("rose", selection.presetTint().?);
}

test "prospective provider change is complete and cancellation leaves selection unchanged" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    const resumed = testPlan();
    const lookup: Preset.Lookup = .{ .plan = resumed };
    _ = try selection.restoreConversation(.{ .preset = "work" }, &lookup);
    try selection.setRun(.{ .provider = "old-p", .model = "old-m", .effort = "old-e" });

    var prepared = try selection.prepareRun(.{ .provider = "new-p" });
    var moved = prepared;
    prepared = undefined;
    defer moved.deinit(std.testing.allocator);

    var candidate_provider = try moved.store().read(std.testing.allocator, "provider");
    defer candidate_provider.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("new-p", candidate_provider.value.?);
    try std.testing.expectEqualStrings(default_sentinel, moved.document.getRaw("model").?.string);
    try std.testing.expectEqualStrings(default_sentinel, moved.document.getRaw("effort").?.string);
    var candidate_preset = try moved.store().read(std.testing.allocator, "preset");
    defer candidate_preset.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("", candidate_preset.value.?);
    var below_preset = try moved.store().readBelowRun(std.testing.allocator, "preset");
    defer below_preset.deinit(std.testing.allocator);
    try std.testing.expect(below_preset.value == null);

    try expectSelectionRead(&selection, "provider", "old-p", .run);
    try expectSelectionRead(&selection, "model", "old-m", .run);
    try expectSelectionRead(&selection, "effort", "old-e", .run);
    var live_below = try selection.store().readBelowRun(std.testing.allocator, "preset");
    defer live_below.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("work", live_below.value.?);
}

test "effort preparation preserves a provider-default model stance" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    try selection.setRun(.{
        .provider = "p",
        .model = default_sentinel,
        .effort = "low",
    });

    var effort = try selection.prepareRun(.{ .effort = "high" });
    defer effort.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(default_sentinel, effort.document.getRaw("model").?.string);
    try expectStoreRead(effort.store(), "effort", "high", .run);
}

test "model and effort preparation preserves the other run fields" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    try selection.setRun(.{
        .provider = "p",
        .model = "old-model",
        .effort = "old-effort",
        .preset = "work",
    });

    var model = try selection.prepareRun(.{ .model = "new-model" });
    try expectStoreRead(model.store(), "provider", "p", .run);
    try expectStoreRead(model.store(), "model", "new-model", .run);
    try expectStoreRead(model.store(), "effort", "old-effort", .run);
    selection.publishRun(&model);
    try expectSelectionRead(&selection, "preset", "", .run);

    var effort = try selection.prepareRun(.{ .effort = "high" });
    defer effort.deinit(std.testing.allocator);
    try expectStoreRead(effort.store(), "provider", "p", .run);
    try expectStoreRead(effort.store(), "model", "new-model", .run);
    try expectStoreRead(effort.store(), "effort", "high", .run);
}

fn expectStoreRead(store_value: Store, key: []const u8, expected: []const u8, source: Store.Source) !void {
    var result = try store_value.read(std.testing.allocator, key);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(source, result.source);
    try std.testing.expectEqualStrings(expected, result.value.?);
}

fn exercisePreparedRunAllocationFailures(allocator: std.mem.Allocator) !void {
    var selection = Selection.init(allocator, testBase(null, null));
    defer selection.deinit();
    const plan = testPlan();
    try selection.applyPreset(.run, &plan);
    var prepared = selection.prepareRun(.{
        .provider = "new-provider",
        .model = "new-model",
        .effort = "high",
    }) catch |err| {
        try expectSelectionRead(&selection, "provider", "p", .run);
        try expectSelectionRead(&selection, "model", "preset-model", .run);
        try std.testing.expectEqualStrings("rose", selection.presetTint().?);
        return err;
    };
    defer prepared.deinit(allocator);
}

test "prospective run preparation releases every allocation and rolls back on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePreparedRunAllocationFailures,
        .{},
    );
}

const SecretFreeObserver = struct {
    backing: std.mem.Allocator,
    fail_index: ?usize = null,
    allocations: usize = 0,
    frees: usize = 0,
    secret_seen: bool = false,

    fn allocator(self: *SecretFreeObserver) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *SecretFreeObserver = @ptrCast(@alignCast(context));
        const index = self.allocations;
        self.allocations += 1;
        if (self.fail_index == index) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) bool {
        const self: *SecretFreeObserver = @ptrCast(@alignCast(context));
        return self.backing.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ret_addr: usize,
    ) ?[*]u8 {
        const self: *SecretFreeObserver = @ptrCast(@alignCast(context));
        return self.backing.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        ret_addr: usize,
    ) void {
        const self: *SecretFreeObserver = @ptrCast(@alignCast(context));
        self.frees += 1;
        if (std.mem.indexOf(u8, memory, "wipe-marker") != null) self.secret_seen = true;
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

test "prepared run publication performs no allocation" {
    var observer: SecretFreeObserver = .{ .backing = std.testing.allocator };
    const allocator = observer.allocator();
    var selection = Selection.init(allocator, testBase(null, null));
    defer selection.deinit();
    try selection.setRun(.{ .provider = "old-p", .model = "old-m", .effort = "low" });
    var prepared = try selection.prepareRun(.{
        .provider = "new-p",
        .model = "new-m",
        .effort = "high",
    });

    observer.fail_index = observer.allocations;
    selection.publishRun(&prepared);
    try expectSelectionRead(&selection, "provider", "new-p", .run);
    try expectSelectionRead(&selection, "model", "new-m", .run);
    try expectSelectionRead(&selection, "effort", "high", .run);
}

test "prepared preset owns a complete overlay and cancellation changes nothing" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    const run_plan = testPlan();
    try selection.applyPreset(.run, &run_plan);
    const conversation_plan = conversationPlan();
    try selection.applyPreset(.conversation, &conversation_plan);

    var replacement = conversationPlan();
    replacement.model.value = @constCast("replacement-model");
    var original = try selection.preparePreset(.conversation, &replacement);
    var prepared = original;
    original = undefined;
    defer prepared.deinit();

    try std.testing.expect(prepared.run_document != null);
    try std.testing.expect(prepared.conversation_document != null);
    try std.testing.expectEqualStrings("rose", prepared.run_tint.?);
    try std.testing.expectEqualStrings("amber", prepared.conversation_tint.?);
    try expectStoreRead(prepared.store(), "preset", "work", .run);
    try std.testing.expectEqualStrings(
        "replacement-model",
        prepared.conversation_document.?.getRaw("model").?.string,
    );

    try expectSelectionRead(&selection, "preset", "work", .run);
    var live_below = try selection.store().readBelowRun(std.testing.allocator, "preset");
    defer live_below.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("resumed", live_below.value.?);
    try std.testing.expectEqualStrings("rose", selection.run_preset_tint.?);
    try std.testing.expectEqualStrings("amber", selection.conversation_preset_tint.?);
}

test "preset publication retires all old ownership without allocation or cleanup" {
    var observer: SecretFreeObserver = .{ .backing = std.testing.allocator };
    const allocator = observer.allocator();
    var selection = Selection.init(allocator, testBase(null, null));
    defer selection.deinit();
    const run_plan = testPlan();
    try selection.applyPreset(.run, &run_plan);
    const conversation_plan = conversationPlan();
    try selection.applyPreset(.conversation, &conversation_plan);
    const fresh = runPlanWithoutPromptOrTint();
    var prepared = try selection.preparePreset(.run, &fresh);
    defer prepared.deinit();

    observer.fail_index = observer.allocations;
    const frees_before = observer.frees;
    var retired = selection.publishPreset(&prepared);
    try std.testing.expectEqual(frees_before, observer.frees);
    try std.testing.expect(!prepared.active);
    try std.testing.expect(retired.run_document != null);
    try std.testing.expect(retired.conversation_document != null);
    try std.testing.expectEqualStrings("work", retired.run_document.?.getRaw("preset").?.string);
    try std.testing.expectEqualStrings("resumed", retired.conversation_document.?.getRaw("preset").?.string);
    try std.testing.expectEqualStrings("rose", retired.run_tint.?);
    try std.testing.expectEqualStrings("amber", retired.conversation_tint.?);
    try expectSelectionRead(&selection, "preset", "fresh", .run);

    retired.deinit();
    try std.testing.expect(observer.frees > frees_before);
}

fn exercisePreparedOverlayAllocationFailures(allocator: std.mem.Allocator) !void {
    var selection = Selection.init(allocator, testBase(null, null));
    defer selection.deinit();
    const run_plan = testPlan();
    try selection.applyPreset(.run, &run_plan);
    const conversation_plan = conversationPlan();
    try selection.applyPreset(.conversation, &conversation_plan);

    const fresh = runPlanWithoutPromptOrTint();
    var preset = selection.preparePreset(.run, &fresh) catch |err| {
        try expectSelectionRead(&selection, "preset", "work", .run);
        try std.testing.expectEqualStrings("rose", selection.presetTint().?);
        return err;
    };
    preset.deinit();

    const lookup: Preset.Lookup = .{ .plan = conversation_plan };
    var restore = selection.prepareRestoreConversation(.{
        .provider = "conversation-provider",
        .model = "recorded-model",
        .preset = "resumed",
    }, &lookup) catch |err| {
        try expectSelectionRead(&selection, "preset", "work", .run);
        try std.testing.expectEqualStrings("rose", selection.presetTint().?);
        return err;
    };
    restore.deinit();
}

test "prepared preset and restore release ownership and leave selection atomic on OOM" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exercisePreparedOverlayAllocationFailures,
        .{},
    );
}

test "owned config secrets are wiped before allocator free" {
    var observer: SecretFreeObserver = .{ .backing = std.testing.allocator };
    const allocator = observer.allocator();

    var api_secret: ApiKey.Secret = .{ .value = try allocator.dupe(u8, "wipe-marker-api") };
    api_secret.deinit(allocator);
    var prompt: PromptValue.Value = .{ .text = try allocator.dupe(u8, "wipe-marker-prompt") };
    prompt.deinit(allocator);
    var result: Store.Result = .{
        .value = try allocator.dupe(u8, "wipe-marker-result"),
        .source = .run,
    };
    result.deinit(allocator);

    var plan: Preset.Plan = .{
        .name = try allocator.dupe(u8, "wipe-marker-name"),
        .provider = try allocator.dupe(u8, "wipe-marker-provider"),
        .model = .{ .value = try allocator.dupe(u8, "wipe-marker-model") },
        .effort = .{},
        .system_prompt = .{ .value = try allocator.dupe(u8, "wipe-marker-system") },
        .system_prompt_append = .{},
        .tint = .{},
        .description = .{},
    };
    plan.deinit(allocator);

    var selection = Selection.init(allocator, testBase(null, null));
    const overlay_plan: Preset.Plan = .{
        .name = @constCast("marked"),
        .provider = @constCast("provider"),
        .model = .{},
        .effort = .{},
        .system_prompt = .{ .value = @constCast("wipe-marker-overlay\n\"escaped") },
        .system_prompt_append = .{},
        .tint = .{ .value = @constCast("wipe-marker-tint") },
        .description = .{},
    };
    try selection.applyPreset(.run, &overlay_plan);
    try selection.setRun(.{ .model = "wipe-marker-second" });
    selection.deinit();
    try std.testing.expect(!observer.secret_seen);
}

test "aggregate runtime limit rejects near-one-MiB tree and later mutations stay valid" {
    const large = try std.testing.allocator.alloc(u8, Document.maximum_runtime_string_bytes);
    defer std.testing.allocator.free(large);
    @memset(large, 'x');
    const medium = try std.testing.allocator.alloc(u8, 100 * 1024);
    defer std.testing.allocator.free(medium);
    @memset(medium, 'm');
    const json = try std.json.Stringify.valueAlloc(std.testing.allocator, .{
        .padding_a = large,
        .padding_b = large,
        .padding_c = large,
        .padding_d = large,
        .provider = medium,
    }, .{});
    defer std.testing.allocator.free(json);
    var base_run = try Document.parse(std.testing.allocator, json, Document.runtime_limits);
    defer base_run.deinit();
    var options = testBase(null, null);
    options.run = &base_run;
    var selection = Selection.init(std.testing.allocator, options);
    defer selection.deinit();

    try std.testing.expectError(error.TooLarge, selection.setRun(.{ .effort = large }));
    try expectSelectionRead(&selection, "provider", medium, .run);
    var failed_effort = try selection.store().read(std.testing.allocator, "effort");
    defer failed_effort.deinit(std.testing.allocator);
    try std.testing.expect(failed_effort.value == null);

    // Replacing the medium value first creates room for a full 192 KiB field.
    // A following mutation proves the reparsed document remains usable.
    try selection.setRun(.{ .provider = "p", .effort = large });
    try expectSelectionRead(&selection, "effort", large, .run);
    try selection.setRun(.{ .no_tasks = true });
    try expectSelectionRead(&selection, "no_tasks", "1", .run);
}

test "Document parser and repeated Selection mutations wipe every OOM path" {
    var fail_index: usize = 0;
    while (true) : (fail_index += 1) {
        var observer: SecretFreeObserver = .{
            .backing = std.testing.allocator,
            .fail_index = fail_index,
        };
        const allocator = observer.allocator();
        var selection = Selection.init(allocator, testBase(null, null));
        const plan: Preset.Plan = .{
            .name = @constCast("marked"),
            .provider = @constCast("provider"),
            .model = .{},
            .effort = .{},
            .system_prompt = .{ .value = @constCast("wipe-marker\\n\"escaped") },
            .system_prompt_append = .{},
            .tint = .{},
            .description = .{},
        };
        var completed = true;
        selection.applyPreset(.run, &plan) catch |err| switch (err) {
            error.OutOfMemory => completed = false,
            else => return err,
        };
        if (completed) selection.setRun(.{
            .model = "wipe-marker-second",
        }) catch |err| switch (err) {
            error.OutOfMemory => completed = false,
            else => return err,
        };
        if (completed) {
            var prepared = selection.prepareRunOverride(
                "compact.threshold",
                "wipe-marker-third",
            ) catch |err| switch (err) {
                error.OutOfMemory => {
                    completed = false;
                    selection.deinit();
                    try std.testing.expect(!observer.secret_seen);
                    continue;
                },
                else => return err,
            };
            selection.publishRunOverride(&prepared);
        }
        selection.deinit();
        try std.testing.expect(!observer.secret_seen);
        if (completed) break;
    }
}

test "preset replacement preserves an explicit runtime tint override" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    try selection.applyPreset(.run, &testPlan());
    var tint_override = try selection.prepareRunOverride("tint", "sage");
    selection.publishRunOverride(&tint_override);

    const replacement = conversationPlan();
    try selection.applyPreset(.run, &replacement);
    try expectSelectionRead(&selection, "tint", "sage", .run);
    try std.testing.expectEqualStrings("amber", selection.presetTint().?);
}

test "generic run override preserves preset tint and publishes without touching conversation" {
    var selection = Selection.init(std.testing.allocator, testBase(null, null));
    defer selection.deinit();
    try selection.applyPreset(.run, &testPlan());
    const tint_before = selection.presetTint();
    try std.testing.expect(tint_before != null);

    var prepared = try selection.prepareRunOverride("compact.threshold", "75");
    var candidate = try prepared.store().read(std.testing.allocator, "compact.threshold");
    defer candidate.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("75", candidate.value.?);
    var retired = selection.publishRunOverrideRetired(&prepared);
    retired.deinit();

    try std.testing.expectEqualStrings(tint_before.?, selection.presetTint().?);
    var current = try selection.store().read(std.testing.allocator, "compact.threshold");
    defer current.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("75", current.value.?);
    try std.testing.expectEqual(Store.Source.run, current.source);

    var cleared = try selection.prepareRunOverride("compact.threshold", null);
    selection.publishRunOverride(&cleared);
    var lower = try selection.store().read(std.testing.allocator, "compact.threshold");
    defer lower.deinit(std.testing.allocator);
    try std.testing.expect(lower.value == null);
}
