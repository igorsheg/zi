const std = @import("std");
const ai = @import("../ai/root.zig");
const TurnModule = @import("Turn.zig");

const Item = ai.Item.Item;
const Turn = TurnModule.Turn;

pub const interrupt_marker = "[interrupted]";
pub const continuation_marker = "[continue]";

pub const Limits = struct {
    items: usize = 16 * 1024,
    user_text_bytes: usize = 8 * 1024 * 1024,
    provider_id_bytes: usize = 256,
    model_id_bytes: usize = 512,
    label_bytes: usize = 512,
    effort_bytes: usize = 64,
    preset_bytes: usize = 512,
    retained_bytes: usize = 64 * 1024 * 1024,
    images: usize = 256,
    image_base64_bytes: usize = 256 * 1024 * 1024,
    provenance_value_bytes: usize = 8 * 1024,
};

pub const Selection = struct {
    provider_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
};

pub const Options = struct {
    provider_id: ?[]const u8 = null,
    model: ?[]const u8 = null,
    model_label: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
    limits: Limits = .{},
};

pub const Error = error{
    OutOfMemory,
    SessionBusy,
    TooManyItems,
    UserTextTooLarge,
    ProviderIdTooLarge,
    ModelIdTooLarge,
    LabelTooLarge,
    EffortTooLarge,
    PresetTooLarge,
    RetainedDataTooLarge,
    TooManyImages,
    ImageDataTooLarge,
    ProvenanceTooLarge,
    TurnStillStreaming,
    TurnNeedsRepair,
    InvalidItemIndex,
    InvalidItem,
    InvalidUsage,
};

pub const AbsorbResult = struct {
    items_from: usize,
    had_tool_call: bool,
};

pub const UsageInput = struct {
    stream: ai.Usage.StreamUsage = .{},
    elapsed_ms: ?u64 = null,
    uncached_input_tokens: ?u64 = null,
    cost_input_usd: ?f64 = null,
    cost_cache_read_usd: ?f64 = null,
    cost_cache_write_usd: ?f64 = null,
    cost_output_usd: ?f64 = null,
    cost_total_usd: ?f64 = null,
    cost_estimated: bool = false,
    provider_label: ?[]const u8 = null,
    response: ai.StreamEvent.ResponseIdentity = .{},
    /// Explicit wire identity for transactions whose request selection may
    /// differ from the session's retained display selection.
    source_provider: ?[]const u8 = null,
    source_model: ?[]const u8 = null,
};

/// Move-only selection replacement prepared without changing the session.
pub const PreparedSelection = struct {
    owner: *Session,
    generation: u64,
    allocator: std.mem.Allocator,
    replacement: ?OwnedSelection,
    active: bool = true,

    pub fn deinit(self: *PreparedSelection) void {
        if (self.active) if (self.replacement) |*replacement| replacement.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Move-only selection strings displaced by publication.
pub const RetiredSelection = struct {
    allocator: std.mem.Allocator,
    selection: ?OwnedSelection,
    active: bool = true,

    pub fn deinit(self: *RetiredSelection) void {
        if (self.active) if (self.selection) |*selection| selection.deinit(self.allocator);
        self.* = undefined;
    }
};

/// Move-only whole-session replacement prepared without changing the live session.
pub const PreparedReplacement = struct {
    owner: *Session,
    history_generation: u64,
    selection_generation: u64,
    replacement: Session,
    active: bool = true,

    pub fn deinit(self: *PreparedReplacement) void {
        if (self.active) self.replacement.deinit();
        self.* = undefined;
    }
};

/// Owns the session displaced by whole-session publication.
pub const Retired = struct {
    session: Session,
    active: bool = true,

    pub fn deinit(self: *Retired) void {
        if (self.active) self.session.deinit();
        self.* = undefined;
    }
};

/// Move-only usage footer prepared for an allocation-free session commit.
pub const PreparedUsage = struct {
    item: ai.Item.Item,
    retained_bytes: usize,
    image_count: usize,
    image_base64_bytes: usize,
    active: bool = true,

    pub fn deinit(self: *PreparedUsage, allocator: std.mem.Allocator) void {
        if (self.active) self.item.deinit(allocator);
        self.* = undefined;
    }
};

/// Owns one bounded flat provider-independent conversation record.
pub const Session = struct {
    const RunState = enum { idle, running, hook, compacting, compaction_mutation };

    allocator: std.mem.Allocator,
    run_state: RunState = .idle,
    history_generation: u64 = 0,
    selection_generation: u64 = 0,
    limits: Limits,
    provider_id: ?[]u8,
    model: ?[]u8,
    model_label: ?[]u8,
    effort: ?[]u8,
    preset: ?[]u8,
    record: std.ArrayList(Item) = .empty,
    retained_bytes: usize = 0,
    image_count: usize = 0,
    image_base64_bytes: usize = 0,

    pub fn init(allocator: std.mem.Allocator, options: Options) Error!Session {
        var decoded_items: std.ArrayList(Item) = .empty;
        return initAdoptingItems(allocator, options, &decoded_items);
    }

    /// Validates then moves a decoded list into a new session without copying.
    /// The list and every nested allocation must belong to `allocator`. On
    /// failure the caller retains full ownership. Success empties `items`.
    pub fn initAdoptingItems(
        allocator: std.mem.Allocator,
        options: Options,
        decoded_items: *std.ArrayList(Item),
    ) Error!Session {
        const selection: Selection = .{
            .provider_id = options.provider_id,
            .model = options.model,
            .model_label = options.model_label,
            .effort = options.effort,
            .preset = options.preset,
        };
        try validateSelection(selection, options.limits);
        if (decoded_items.items.len > options.limits.items) return error.TooManyItems;

        var retained_bytes: usize = 0;
        for (decoded_items.items) |item| {
            try validateItemLimits(item, options.limits);
            retained_bytes +|= ai.Item.retainedBytes(item);
        }
        const image_count = ai.Item.imageCount(decoded_items.items);
        const image_base64_bytes = ai.Item.imageBase64Bytes(decoded_items.items);
        if (retained_bytes > options.limits.retained_bytes) return error.RetainedDataTooLarge;
        if (image_count > options.limits.images) return error.TooManyImages;
        if (image_base64_bytes > options.limits.image_base64_bytes) return error.ImageDataTooLarge;

        var owned = try OwnedSelection.init(allocator, selection);
        errdefer owned.deinit(allocator);
        const record = decoded_items.*;
        decoded_items.* = .empty;
        return .{
            .allocator = allocator,
            .limits = options.limits,
            .provider_id = owned.provider_id,
            .model = owned.model,
            .model_label = owned.model_label,
            .effort = owned.effort,
            .preset = owned.preset,
            .record = record,
            .retained_bytes = retained_bytes,
            .image_count = image_count,
            .image_base64_bytes = image_base64_bytes,
        };
    }

    pub fn deinit(self: *Session) void {
        std.debug.assert(self.run_state == .idle);
        self.reset();
        self.record.deinit(self.allocator);
        if (self.provider_id) |provider_id| self.allocator.free(provider_id);
        if (self.model) |model| self.allocator.free(model);
        if (self.model_label) |model_label| self.allocator.free(model_label);
        if (self.effort) |effort| self.allocator.free(effort);
        if (self.preset) |preset| self.allocator.free(preset);
        self.* = undefined;
    }

    /// Owns a prospective selection without changing the live session.
    /// The returned value is move-only and must be published or deinitialized.
    pub fn prepareSelection(self: *Session, selection: Selection) Error!PreparedSelection {
        try self.ensureMutable();
        try validateSelection(selection, self.limits);
        if (selectionEqual(self.currentSelection(), selection)) return .{
            .owner = self,
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .replacement = null,
        };
        return .{
            .owner = self,
            .generation = self.selection_generation,
            .allocator = self.allocator,
            .replacement = try OwnedSelection.init(self.allocator, selection),
        };
    }

    /// Publishes a prepared replacement without allocating or freeing. Consumes
    /// `prepared`; the caller must later deinitialize the returned owner.
    pub fn publishSelectionRetired(
        self: *Session,
        prepared: *PreparedSelection,
    ) RetiredSelection {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.generation == self.selection_generation);
        std.debug.assert(self.run_state != .running);
        std.debug.assert(self.run_state != .compacting);
        prepared.active = false;
        self.selection_generation +%= 1;
        const replacement = prepared.replacement orelse return .{
            .allocator = self.allocator,
            .selection = null,
        };
        prepared.replacement = null;
        const previous: OwnedSelection = .{
            .provider_id = self.provider_id,
            .model = self.model,
            .model_label = self.model_label,
            .effort = self.effort,
            .preset = self.preset,
        };
        self.provider_id = replacement.provider_id;
        self.model = replacement.model;
        self.model_label = replacement.model_label;
        self.effort = replacement.effort;
        self.preset = replacement.preset;
        return .{ .allocator = self.allocator, .selection = previous };
    }

    /// Publishes and immediately releases displaced selection strings.
    pub fn publishSelection(self: *Session, prepared: *PreparedSelection) void {
        var retired = self.publishSelectionRetired(prepared);
        retired.deinit();
    }

    /// Atomically owns and replaces the live selection. Conversation items and
    /// their accounting remain unchanged. Allocation failure preserves the old selection.
    pub fn reconfigureSelection(self: *Session, selection: Selection) Error!void {
        var prepared = try self.prepareSelection(selection);
        defer if (prepared.active) prepared.deinit();
        self.publishSelection(&prepared);
    }

    /// Moves a validated idle replacement into a candidate. On failure, the
    /// source remains owned by the caller.
    pub fn prepareReplacement(
        self: *Session,
        replacement: *Session,
    ) Error!PreparedReplacement {
        std.debug.assert(replacement != self);
        if (self.run_state != .idle or replacement.run_state != .idle) return error.SessionBusy;
        try replacement.validateOwnedState();
        const moved = replacement.*;
        replacement.* = undefined;
        return .{
            .owner = self,
            .history_generation = self.history_generation,
            .selection_generation = self.selection_generation,
            .replacement = moved,
        };
    }

    /// Publishes a prepared whole-session replacement without allocating. The
    /// returned retired session owns all state displaced from the stable address.
    pub fn publishReplacement(
        self: *Session,
        prepared: *PreparedReplacement,
    ) Retired {
        std.debug.assert(prepared.active);
        std.debug.assert(prepared.owner == self);
        std.debug.assert(prepared.history_generation == self.history_generation);
        std.debug.assert(prepared.selection_generation == self.selection_generation);
        std.debug.assert(self.run_state == .idle);
        std.debug.assert(prepared.replacement.run_state == .idle);

        prepared.active = false;
        var replacement = prepared.replacement;
        replacement.history_generation = self.history_generation +% 1;
        replacement.selection_generation = self.selection_generation +% 1;
        const retired: Retired = .{ .session = self.* };
        self.* = replacement;
        return retired;
    }

    /// Replaces admission limits without cloning history. The existing selection
    /// and every retained item must fit the new limits. Failure preserves the old limits.
    pub fn reconfigureLimits(self: *Session, limits: Limits) Error!void {
        try self.ensureMutable();
        try validateSelection(self.currentSelection(), limits);
        if (self.record.items.len > limits.items) return error.TooManyItems;
        if (self.retained_bytes > limits.retained_bytes) return error.RetainedDataTooLarge;
        if (self.image_count > limits.images) return error.TooManyImages;
        if (self.image_base64_bytes > limits.image_base64_bytes) return error.ImageDataTooLarge;
        for (self.record.items) |item| try validateItemLimits(item, limits);
        self.limits = limits;
    }

    /// Clears conversation items while retaining selection and vector capacity.
    pub fn reset(self: *Session) void {
        std.debug.assert(self.run_state == .idle);
        for (self.record.items) |*item| item.deinit(self.allocator);
        self.record.items.len = 0;
        self.retained_bytes = 0;
        self.image_count = 0;
        self.image_base64_bytes = 0;
        self.history_generation +%= 1;
    }

    /// Acquires the exclusive Loop run lease.
    pub fn beginRun(self: *Session) error{SessionBusy}!void {
        if (self.run_state != .idle) return error.SessionBusy;
        self.run_state = .running;
    }

    /// Releases a run lease. Loop must leave hook phase first.
    pub fn endRun(self: *Session) void {
        std.debug.assert(self.run_state == .running);
        self.run_state = .idle;
    }

    /// Temporarily permits Loop-owned or continuation-hook session mutations.
    pub fn beginHookMutation(self: *Session) void {
        std.debug.assert(self.run_state == .running);
        self.run_state = .hook;
    }

    pub fn endHookMutation(self: *Session) void {
        std.debug.assert(self.run_state == .hook);
        self.run_state = .running;
    }

    /// Acquires a standalone compaction lease from an idle session.
    pub fn beginStandaloneCompaction(self: *Session) error{SessionBusy}!void {
        if (self.run_state != .idle) return error.SessionBusy;
        self.run_state = .compacting;
    }

    pub fn endStandaloneCompaction(self: *Session) void {
        std.debug.assert(self.run_state == .compacting);
        self.run_state = .idle;
    }

    /// Acquires compaction only from a Loop continuation-hook phase.
    pub fn beginContinuationCompaction(self: *Session) error{SessionBusy}!void {
        if (self.run_state != .hook) return error.SessionBusy;
        self.run_state = .compacting;
    }

    pub fn endContinuationCompaction(self: *Session) void {
        std.debug.assert(self.run_state == .compacting);
        self.run_state = .hook;
    }

    /// Temporarily permits only CompactRunner-owned session commits.
    pub fn beginCompactionMutation(self: *Session) void {
        std.debug.assert(self.run_state == .compacting);
        self.run_state = .compaction_mutation;
    }

    pub fn endCompactionMutation(self: *Session) void {
        std.debug.assert(self.run_state == .compaction_mutation);
        self.run_state = .compacting;
    }

    fn ensureMutable(self: *const Session) error{SessionBusy}!void {
        if (self.run_state == .running or self.run_state == .compacting) {
            return error.SessionBusy;
        }
    }

    pub fn historyGeneration(self: *const Session) u64 {
        return self.history_generation;
    }

    pub fn selectionGeneration(self: *const Session) u64 {
        return self.selection_generation;
    }

    /// Returns the live selection borrowed until the next selection change or deinit.
    pub fn currentSelection(self: *const Session) Selection {
        return .{
            .provider_id = self.provider_id,
            .model = self.model,
            .model_label = self.model_label,
            .effort = self.effort,
            .preset = self.preset,
        };
    }

    pub fn items(self: *const Session) []const Item {
        return self.record.items;
    }

    /// Copies one borrowed item into the session allocator after bounded admission.
    pub fn appendCopy(self: *Session, item: *const Item) Error!void {
        try self.ensureMutable();
        const admission = try self.reserveAdmission(&.{item.*});
        var cloned = try item.clone(self.allocator);
        errdefer cloned.deinit(self.allocator);
        self.record.appendAssumeCapacity(cloned);
        self.commitAdmission(admission);
    }

    /// Atomically replaces one retained item after cloning and bounded admission.
    /// The existing item remains unchanged on every failure.
    pub fn replaceItemCopy(self: *Session, index: usize, item: *const Item) Error!void {
        try self.ensureMutable();
        if (index >= self.record.items.len) return error.InvalidItemIndex;
        var cloned = if (item.* == .reasoning)
            try item.cloneWithReasoningSource(self.allocator, self.provider_id, self.model)
        else
            try item.clone(self.allocator);
        errdefer cloned.deinit(self.allocator);

        try validateItem(cloned);
        const old = self.record.items[index];
        const old_retained = ai.Item.retainedBytes(old);
        const old_images = ai.Item.imageCount(&.{old});
        const old_image_bytes = ai.Item.imageBase64Bytes(&.{old});
        const new_retained = ai.Item.retainedBytes(cloned);
        const new_images = ai.Item.imageCount(&.{cloned});
        const new_image_bytes = ai.Item.imageBase64Bytes(&.{cloned});
        const retained_without_old = self.retained_bytes - old_retained;
        const images_without_old = self.image_count - old_images;
        const image_bytes_without_old = self.image_base64_bytes - old_image_bytes;
        if (new_retained > self.limits.retained_bytes -| retained_without_old)
            return error.RetainedDataTooLarge;
        if (new_images > self.limits.images -| images_without_old)
            return error.TooManyImages;
        if (new_image_bytes > self.limits.image_base64_bytes -| image_bytes_without_old)
            return error.ImageDataTooLarge;

        self.record.items[index].deinit(self.allocator);
        self.record.items[index] = cloned;
        self.retained_bytes = retained_without_old + new_retained;
        self.image_count = images_without_old + new_images;
        self.image_base64_bytes = image_bytes_without_old + new_image_bytes;
        self.history_generation +%= 1;
    }

    /// Replaces one tool-result placeholder by consuming an item allocated by
    /// this session's allocator. On success `item` becomes undefined. No
    /// allocation occurs, so callers may use it to settle a side-effecting tool.
    pub fn replaceToolResultOwned(self: *Session, index: usize, item: *Item) Error!void {
        try self.ensureMutable();
        if (index >= self.record.items.len) return error.InvalidItemIndex;
        if (self.record.items[index] != .tool_result or item.* != .tool_result) return error.InvalidItem;
        try validateItem(item.*);
        const old = self.record.items[index];
        const old_retained = ai.Item.retainedBytes(old);
        const old_images = ai.Item.imageCount(&.{old});
        const old_image_bytes = ai.Item.imageBase64Bytes(&.{old});
        const new_retained = ai.Item.retainedBytes(item.*);
        const new_images = ai.Item.imageCount(&.{item.*});
        const new_image_bytes = ai.Item.imageBase64Bytes(&.{item.*});
        const retained_without_old = self.retained_bytes - old_retained;
        const images_without_old = self.image_count - old_images;
        const image_bytes_without_old = self.image_base64_bytes - old_image_bytes;
        if (new_retained > self.limits.retained_bytes -| retained_without_old)
            return error.RetainedDataTooLarge;
        if (new_images > self.limits.images -| images_without_old) return error.TooManyImages;
        if (new_image_bytes > self.limits.image_base64_bytes -| image_bytes_without_old)
            return error.ImageDataTooLarge;

        self.record.items[index].deinit(self.allocator);
        self.record.items[index] = item.*;
        item.* = undefined;
        self.retained_bytes = retained_without_old + new_retained;
        self.image_count = images_without_old + new_images;
        self.image_base64_bytes = image_bytes_without_old + new_image_bytes;
        self.history_generation +%= 1;
    }

    /// Atomically appends a boundary followed by a copied user message.
    pub fn addUser(self: *Session, text: []const u8) Error!void {
        return self.addUserWithOrigin(text, .external);
    }

    pub fn addContinuation(self: *Session) Error!void {
        return self.addUserWithOrigin(continuation_marker, .continuation);
    }

    /// Atomically appends one background-task notification without a boundary.
    /// Allocation or admission failure leaves the session unchanged.
    pub fn addTaskNote(self: *Session, text: []const u8) Error!void {
        try self.ensureMutable();
        if (text.len > self.limits.user_text_bytes) return error.UserTextTooLarge;
        const admission = try self.reserveValues(1, text.len, 0, 0);
        const owned_text = try self.allocator.dupe(u8, text);
        self.record.appendAssumeCapacity(.{ .user_message = .{
            .text = owned_text,
            .origin = .task_note,
        } });
        self.commitAdmission(admission);
    }

    /// Atomically appends a boundary and a compaction seed. The newest seed is
    /// the provider context floor; earlier retained history remains intact.
    pub fn addCompactSeed(self: *Session, text: []const u8) Error!void {
        try self.ensureMutable();
        return self.addUserWithOrigin(text, .compact_seed);
    }

    fn addUserWithOrigin(
        self: *Session,
        text: []const u8,
        origin: ai.Item.UserOrigin,
    ) Error!void {
        try self.ensureMutable();
        if (text.len > self.limits.user_text_bytes) return error.UserTextTooLarge;
        const admission = try self.reserveValues(2, text.len, 0, 0);
        const owned_text = try self.allocator.dupe(u8, text);
        self.record.appendAssumeCapacity(.turn_boundary);
        self.record.appendAssumeCapacity(.{ .user_message = .{
            .text = owned_text,
            .origin = origin,
        } });
        self.commitAdmission(admission);
    }

    pub fn addBoundary(self: *Session) Error!void {
        try self.ensureMutable();
        const admission = try self.reserveValues(1, 0, 0, 0);
        self.record.appendAssumeCapacity(.turn_boundary);
        self.commitAdmission(admission);
    }

    /// Clones one completed turn into the session and resets it after commit.
    /// Failed turns must pass through `AbortRepair.repairAndAbsorb`.
    pub fn absorbTurn(self: *Session, turn: *Turn) Error!AbsorbResult {
        try self.ensureMutable();
        return switch (turn.state) {
            .streaming => error.TurnStillStreaming,
            .failed => error.TurnNeedsRepair,
            .done => {
                const result = try self.absorbItemsCopy(turn.items.items);
                turn.reset();
                return result;
            },
        };
    }

    /// Atomically clones and stamps one prepared turn batch. This is the narrow
    /// commit seam used by ordinary turns and abort repair.
    pub fn absorbItemsCopy(self: *Session, source: []const Item) Error!AbsorbResult {
        try self.ensureMutable();
        var staged: std.ArrayList(Item) = .empty;
        defer {
            for (staged.items) |*item| item.deinit(self.allocator);
            staged.deinit(self.allocator);
        }
        try staged.ensureUnusedCapacity(self.allocator, source.len);
        var had_tool_call = false;
        for (source) |item| {
            var cloned = if (item == .reasoning)
                try item.cloneWithReasoningSource(self.allocator, self.provider_id, self.model)
            else
                try item.clone(self.allocator);
            errdefer cloned.deinit(self.allocator);
            if (cloned == .tool_call) had_tool_call = true;
            staged.appendAssumeCapacity(cloned);
        }

        const admission = try self.reserveAdmission(staged.items);
        const items_from = self.record.items.len;
        self.record.appendSliceAssumeCapacity(staged.items);
        self.commitAdmission(admission);
        staged.items.len = 0;
        return .{ .items_from = items_from, .had_tool_call = had_tool_call };
    }

    /// Appends one owned usage footer and stamps the current wire selection.
    /// Display labels equal to wire IDs are omitted, matching hax transcripts.
    pub fn addTurnUsage(self: *Session, input: UsageInput) Error!bool {
        return self.addTurnUsageWithBoundary(input, false);
    }

    pub fn addTurnUsageWithBoundary(
        self: *Session,
        input: UsageInput,
        prepend_boundary: bool,
    ) Error!bool {
        try self.ensureMutable();
        inline for (.{
            input.stream.cost_usd,
            input.cost_input_usd,
            input.cost_cache_read_usd,
            input.cost_cache_write_usd,
            input.cost_output_usd,
            input.cost_total_usd,
        }) |cost| {
            if (cost) |value| if (!std.math.isFinite(value) or value < 0) return error.InvalidUsage;
        }
        if (!ai.Usage.usageReported(input.stream) and input.elapsed_ms == null) return false;
        const provider_label = distinctLabel(input.provider_label, self.provider_id);
        const model_label = distinctLabel(self.model_label, self.model);
        const effort = nonEmpty(self.effort);
        const served_model = distinctLabel(input.response.model, self.model);
        const route = input.response.route;
        const response_id = input.response.id;
        const usage_model = nonEmpty(self.model);
        const source_provider = input.source_provider orelse self.provider_id;
        const source_model = input.source_model orelse usage_model;
        for ([_]?[]const u8{
            provider_label,
            model_label,
            effort,
            served_model,
            route,
            response_id,
            source_provider,
            source_model,
        }) |value| {
            if (value) |bytes| {
                if (bytes.len > self.limits.provenance_value_bytes) return error.ProvenanceTooLarge;
            }
        }

        const has_source = source_provider != null or source_model != null;
        var retained_bytes: usize = 0;
        for ([_]?[]const u8{ provider_label, model_label, effort, served_model, route, response_id }) |value| {
            if (value) |bytes| retained_bytes +|= bytes.len;
        }
        if (source_provider) |provider_id| retained_bytes +|= provider_id.len;
        if (source_model) |model| retained_bytes +|= model.len;
        const admission = try self.reserveValues(
            1 + @as(usize, @intFromBool(prepend_boundary)),
            retained_bytes,
            0,
            0,
        );

        var item: Item = .{ .turn_usage = .{ .value = .{
            .stream = input.stream,
            .elapsed_ms = input.elapsed_ms,
            .uncached_input_tokens = input.uncached_input_tokens,
            .cost_input_usd = input.cost_input_usd,
            .cost_cache_read_usd = input.cost_cache_read_usd,
            .cost_cache_write_usd = input.cost_cache_write_usd,
            .cost_output_usd = input.cost_output_usd,
            .cost_total_usd = input.cost_total_usd,
            .cost_estimated = input.cost_estimated,
        } } };
        errdefer item.deinit(self.allocator);
        const provenance = &item.turn_usage.value.provenance;
        provenance.provider_label = try duplicateOptional(self.allocator, provider_label);
        provenance.model_label = try duplicateOptional(self.allocator, model_label);
        provenance.effort = try duplicateOptional(self.allocator, effort);
        provenance.served_model = try duplicateOptional(self.allocator, served_model);
        provenance.route = try duplicateOptional(self.allocator, route);
        provenance.response_id = try duplicateOptional(self.allocator, response_id);
        if (has_source) {
            item.turn_usage.source = .{};
            item.turn_usage.source.?.provider = try duplicateOptional(self.allocator, source_provider);
            item.turn_usage.source.?.model = try duplicateOptional(self.allocator, source_model);
        }
        if (prepend_boundary) self.record.appendAssumeCapacity(.turn_boundary);
        self.record.appendAssumeCapacity(item);
        self.commitAdmission(admission);
        return true;
    }

    /// Prepares an owned usage footer and reserves capacity for either the
    /// footer alone or a boundary/seed/footer compaction commit.
    pub fn prepareCompactionUsage(
        self: *Session,
        input: UsageInput,
    ) Error!PreparedUsage {
        try self.ensureMutable();
        var staged = try Session.init(self.allocator, .{
            .provider_id = self.provider_id,
            .model = self.model,
            .model_label = self.model_label,
            .effort = self.effort,
            .preset = self.preset,
            .limits = self.limits,
        });
        defer staged.deinit();
        if (!try staged.addTurnUsage(input)) return error.InvalidUsage;
        std.debug.assert(staged.record.items.len == 1);
        const item = staged.record.items[0];
        staged.record.items.len = 0;
        errdefer {
            var cleanup = item;
            cleanup.deinit(self.allocator);
        }
        const retained_bytes = ai.Item.retainedBytes(item);
        const image_count = ai.Item.imageCount(&.{item});
        const image_base64_bytes = ai.Item.imageBase64Bytes(&.{item});
        _ = try self.reserveValues(1, retained_bytes, image_count, image_base64_bytes);
        try self.record.ensureUnusedCapacity(self.allocator, 3);
        return .{
            .item = item,
            .retained_bytes = retained_bytes,
            .image_count = image_count,
            .image_base64_bytes = image_base64_bytes,
        };
    }

    /// Commits a prepared footer without allocating.
    pub fn commitPreparedUsage(self: *Session, prepared: *PreparedUsage) void {
        std.debug.assert(prepared.active);
        std.debug.assert(self.run_state == .compaction_mutation or self.run_state == .idle or
            self.run_state == .hook);
        self.record.appendAssumeCapacity(prepared.item);
        self.commitAdmission(.{
            .retained_bytes = prepared.retained_bytes,
            .image_count = prepared.image_count,
            .image_base64_bytes = prepared.image_base64_bytes,
        });
        prepared.active = false;
    }

    /// Atomically commits boundary, seed, and a prepared footer. Allocation or
    /// admission failure leaves the prepared footer available to commit alone.
    pub fn commitCompactSeedPrepared(
        self: *Session,
        text: []const u8,
        prepared: *PreparedUsage,
    ) Error!void {
        try self.ensureMutable();
        std.debug.assert(prepared.active);
        if (text.len > self.limits.user_text_bytes) return error.UserTextTooLarge;
        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const seed_item: Item = .{ .user_message = .{
            .text = owned_text,
            .origin = .compact_seed,
        } };
        const admission = try self.reserveAdmission(&.{
            .turn_boundary,
            seed_item,
            prepared.item,
        });
        self.record.appendAssumeCapacity(.turn_boundary);
        self.record.appendAssumeCapacity(seed_item);
        self.record.appendAssumeCapacity(prepared.item);
        self.commitAdmission(admission);
        prepared.active = false;
    }

    /// Atomically appends a boundary, compaction seed, and accepted usage.
    /// The explicit usage source can identify the actual compaction request.
    pub fn addCompactSeedWithUsage(
        self: *Session,
        text: []const u8,
        input: UsageInput,
    ) Error!void {
        try self.ensureMutable();
        if (text.len > self.limits.user_text_bytes) return error.UserTextTooLarge;

        var staged = try Session.init(self.allocator, .{
            .provider_id = self.provider_id,
            .model = self.model,
            .model_label = self.model_label,
            .effort = self.effort,
            .preset = self.preset,
            .limits = self.limits,
        });
        defer staged.deinit();
        if (!try staged.addTurnUsage(input)) return error.InvalidUsage;
        std.debug.assert(staged.record.items.len == 1);
        var usage_item = staged.record.items[0];
        staged.record.items.len = 0;
        errdefer usage_item.deinit(self.allocator);

        const owned_text = try self.allocator.dupe(u8, text);
        errdefer self.allocator.free(owned_text);
        const seed_item: Item = .{ .user_message = .{
            .text = owned_text,
            .origin = .compact_seed,
        } };
        const admission = try self.reserveAdmission(&.{ .turn_boundary, seed_item, usage_item });
        self.record.appendAssumeCapacity(.turn_boundary);
        self.record.appendAssumeCapacity(seed_item);
        self.record.appendAssumeCapacity(usage_item);
        self.commitAdmission(admission);
    }

    /// Adds an interrupted assistant marker unless the latest content is an
    /// already-marked tool result. Usage and boundaries are inert for this scan.
    pub fn markInterrupt(self: *Session) Error!bool {
        try self.ensureMutable();
        var index = self.record.items.len;
        while (index > 0) {
            const item = self.record.items[index - 1];
            if (item == .turn_usage or item == .turn_boundary) {
                index -= 1;
                continue;
            }
            if (item == .tool_result and
                std.mem.endsWith(u8, item.tool_result.output, interrupt_marker))
            {
                return false;
            }
            break;
        }

        const admission = try self.reserveValues(1, interrupt_marker.len, 0, 0);
        const marker = try self.allocator.dupe(u8, interrupt_marker);
        self.record.appendAssumeCapacity(.{ .assistant_message = .{
            .text = marker,
            .origin = .interrupted,
        } });
        self.commitAdmission(admission);
        return true;
    }

    const Admission = struct {
        retained_bytes: usize,
        image_count: usize,
        image_base64_bytes: usize,
    };

    fn reserveAdmission(self: *Session, source_items: []const Item) Error!Admission {
        var retained_bytes: usize = 0;
        for (source_items) |item| {
            try validateItem(item);
            retained_bytes +|= ai.Item.retainedBytes(item);
        }
        return self.reserveValues(
            source_items.len,
            retained_bytes,
            ai.Item.imageCount(source_items),
            ai.Item.imageBase64Bytes(source_items),
        );
    }

    fn reserveValues(
        self: *Session,
        additional_items: usize,
        retained_bytes: usize,
        image_count: usize,
        image_base64_bytes: usize,
    ) Error!Admission {
        if (additional_items > self.limits.items -| self.record.items.len) return error.TooManyItems;
        if (retained_bytes > self.limits.retained_bytes -| self.retained_bytes) {
            return error.RetainedDataTooLarge;
        }
        if (image_count > self.limits.images -| self.image_count) return error.TooManyImages;
        if (image_base64_bytes > self.limits.image_base64_bytes -| self.image_base64_bytes) {
            return error.ImageDataTooLarge;
        }
        try self.record.ensureUnusedCapacity(self.allocator, additional_items);
        return .{
            .retained_bytes = retained_bytes,
            .image_count = image_count,
            .image_base64_bytes = image_base64_bytes,
        };
    }

    fn commitAdmission(self: *Session, admission: Admission) void {
        self.retained_bytes += admission.retained_bytes;
        self.image_count += admission.image_count;
        self.image_base64_bytes += admission.image_base64_bytes;
        self.history_generation +%= 1;
    }

    fn validateOwnedState(self: *const Session) Error!void {
        try validateSelection(self.currentSelection(), self.limits);
        if (self.record.items.len > self.limits.items) return error.TooManyItems;

        var retained_bytes: usize = 0;
        for (self.record.items) |item| {
            try validateItemLimits(item, self.limits);
            retained_bytes +|= ai.Item.retainedBytes(item);
        }
        const image_count = ai.Item.imageCount(self.record.items);
        const image_base64_bytes = ai.Item.imageBase64Bytes(self.record.items);
        if (retained_bytes != self.retained_bytes or image_count != self.image_count or
            image_base64_bytes != self.image_base64_bytes)
        {
            return error.InvalidItem;
        }
        if (retained_bytes > self.limits.retained_bytes) return error.RetainedDataTooLarge;
        if (image_count > self.limits.images) return error.TooManyImages;
        if (image_base64_bytes > self.limits.image_base64_bytes) return error.ImageDataTooLarge;
    }
};

const OwnedSelection = struct {
    provider_id: ?[]u8 = null,
    model: ?[]u8 = null,
    model_label: ?[]u8 = null,
    effort: ?[]u8 = null,
    preset: ?[]u8 = null,

    fn init(allocator: std.mem.Allocator, selection: Selection) error{OutOfMemory}!OwnedSelection {
        var result: OwnedSelection = .{};
        errdefer result.deinit(allocator);
        result.provider_id = try duplicateOptional(allocator, selection.provider_id);
        result.model = try duplicateOptional(allocator, selection.model);
        result.model_label = try duplicateOptional(allocator, selection.model_label);
        result.effort = try duplicateOptional(allocator, selection.effort);
        result.preset = try duplicateOptional(allocator, selection.preset);
        return result;
    }

    fn deinit(self: *OwnedSelection, allocator: std.mem.Allocator) void {
        if (self.provider_id) |value| allocator.free(value);
        if (self.model) |value| allocator.free(value);
        if (self.model_label) |value| allocator.free(value);
        if (self.effort) |value| allocator.free(value);
        if (self.preset) |value| allocator.free(value);
        self.* = undefined;
    }
};

fn selectionEqual(a: Selection, b: Selection) bool {
    return optionalEqual(a.provider_id, b.provider_id) and
        optionalEqual(a.model, b.model) and
        optionalEqual(a.model_label, b.model_label) and
        optionalEqual(a.effort, b.effort) and
        optionalEqual(a.preset, b.preset);
}

fn optionalEqual(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn validateSelection(selection: Selection, limits: Limits) Error!void {
    if (selection.provider_id) |value| {
        if (value.len > limits.provider_id_bytes) return error.ProviderIdTooLarge;
    }
    if (selection.model) |value| {
        if (value.len > limits.model_id_bytes) return error.ModelIdTooLarge;
    }
    if (selection.model_label) |value| {
        if (value.len > limits.label_bytes) return error.LabelTooLarge;
    }
    if (selection.effort) |value| {
        if (value.len > limits.effort_bytes) return error.EffortTooLarge;
    }
    if (selection.preset) |value| {
        if (value.len > limits.preset_bytes) return error.PresetTooLarge;
    }
}

fn validateItemLimits(item: Item, limits: Limits) Error!void {
    try validateItem(item);
    if (item == .user_message and item.user_message.text.len > limits.user_text_bytes) {
        return error.UserTextTooLarge;
    }
    const source = switch (item) {
        .reasoning => |value| value.source,
        .turn_usage => |value| value.source,
        else => null,
    };
    if (source) |identity| {
        if (identity.provider) |value| if (value.len > limits.provenance_value_bytes) {
            return error.ProvenanceTooLarge;
        };
        if (identity.model) |value| if (value.len > limits.provenance_value_bytes) {
            return error.ProvenanceTooLarge;
        };
    }
    if (item == .turn_usage) {
        const provenance = item.turn_usage.value.provenance;
        inline for (.{
            provenance.provider_label,
            provenance.model_label,
            provenance.effort,
            provenance.served_model,
            provenance.route,
            provenance.response_id,
        }) |value| if (value) |bytes| if (bytes.len > limits.provenance_value_bytes) {
            return error.ProvenanceTooLarge;
        };
    }
}

fn validateItem(item: Item) Error!void {
    const images: []const ai.Item.Image = switch (item) {
        .user_message => |message| message.images,
        .tool_result => |result| result.images,
        else => &.{},
    };
    if (item == .tool_result and item.tool_result.hidden_tail_bytes > item.tool_result.output.len) {
        return error.InvalidItem;
    }
    for (images) |image| {
        if (image.mime.len == 0 or !std.unicode.utf8ValidateSlice(image.mime) or
            std.mem.findScalar(u8, image.mime, '/') == null)
        {
            return error.InvalidItem;
        }
        if (!validBase64(image.data_base64)) return error.InvalidItem;
    }
}

fn validBase64(bytes: []const u8) bool {
    _ = std.base64.standard.Decoder.calcSizeForSlice(bytes) catch return false;
    var padding_start = bytes.len;
    while (padding_start > 0 and bytes[padding_start - 1] == '=') padding_start -= 1;
    if (bytes.len - padding_start > 2) return false;
    for (bytes[0..padding_start]) |byte| {
        if (!(std.ascii.isAlphanumeric(byte) or byte == '+' or byte == '/')) return false;
    }
    for (bytes[padding_start..]) |byte| if (byte != '=') return false;
    return true;
}

fn duplicateOptional(
    allocator: std.mem.Allocator,
    value: ?[]const u8,
) error{OutOfMemory}!?[]u8 {
    return if (value) |bytes| try allocator.dupe(u8, bytes) else null;
}

fn distinctLabel(label: ?[]const u8, wire_id: ?[]const u8) ?[]const u8 {
    const value = label orelse return null;
    if (value.len == 0) return null;
    if (wire_id) |wire| if (std.mem.eql(u8, value, wire)) return null;
    return value;
}

fn nonEmpty(value: ?[]const u8) ?[]const u8 {
    const bytes = value orelse return null;
    return if (bytes.len == 0) null else bytes;
}

fn completedTextTurn(allocator: std.mem.Allocator, text: []const u8) !Turn {
    var turn = Turn.init(allocator, .{});
    errdefer turn.deinit();
    try turn.consume(.{ .text_delta = text });
    try turn.consume(.{ .done = .{} });
    return turn;
}

test "adopting initialization transfers list backing and nested ownership" {
    const allocator = std.testing.allocator;
    var decoded: std.ArrayList(Item) = .empty;
    try decoded.append(allocator, .{ .assistant_message = .{
        .text = try allocator.dupe(u8, "owned"),
    } });
    const backing_pointer = decoded.items.ptr;
    const text_pointer = decoded.items[0].assistant_message.text.ptr;

    var session = try Session.initAdoptingItems(allocator, .{}, &decoded);
    defer session.deinit();

    try std.testing.expectEqual(@as(usize, 0), decoded.items.len);
    try std.testing.expectEqual(@as(usize, 0), decoded.capacity);
    try std.testing.expectEqual(backing_pointer, session.record.items.ptr);
    try std.testing.expectEqual(text_pointer, session.items()[0].assistant_message.text.ptr);
}

test "adopting initialization failure preserves complete caller ownership" {
    const allocator = std.testing.allocator;
    var decoded: std.ArrayList(Item) = .empty;
    defer {
        for (decoded.items) |*item| item.deinit(allocator);
        decoded.deinit(allocator);
    }
    try decoded.append(allocator, .{ .assistant_message = .{
        .text = try allocator.dupe(u8, "four"),
    } });
    const backing_pointer = decoded.items.ptr;
    const text_pointer = decoded.items[0].assistant_message.text.ptr;

    try std.testing.expectError(error.RetainedDataTooLarge, Session.initAdoptingItems(
        allocator,
        .{ .limits = .{ .retained_bytes = 3 } },
        &decoded,
    ));
    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);
    try std.testing.expectEqual(backing_pointer, decoded.items.ptr);
    try std.testing.expectEqual(text_pointer, decoded.items[0].assistant_message.text.ptr);
}

test "adopting initialization OOM preserves decoded items" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var decoded: std.ArrayList(Item) = .empty;
    defer {
        for (decoded.items) |*item| item.deinit(allocator);
        decoded.deinit(allocator);
    }
    try decoded.append(allocator, .{ .assistant_message = .{
        .text = try allocator.dupe(u8, "owned"),
    } });
    const backing_pointer = decoded.items.ptr;
    failing.fail_index = failing.alloc_index;

    try std.testing.expectError(error.OutOfMemory, Session.initAdoptingItems(
        allocator,
        .{ .provider_id = "provider" },
        &decoded,
    ));
    try std.testing.expectEqual(@as(usize, 1), decoded.items.len);
    try std.testing.expectEqual(backing_pointer, decoded.items.ptr);
}

test "reconfigure selection owns replacement without changing items" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "old-provider",
        .model = "old-model",
        .preset = "old-preset",
    });
    defer session.deinit();
    try session.addUser("kept");
    const retained_before = session.retained_bytes;
    var provider = [_]u8{ 'n', 'e', 'w' };
    var preset = [_]u8{ 'w', 'o', 'r', 'k' };

    try session.reconfigureSelection(.{
        .provider_id = &provider,
        .model = "new-model",
        .model_label = "New Model",
        .effort = "high",
        .preset = &preset,
    });
    provider = .{ 'x', 'x', 'x' };
    preset = .{ 'x', 'x', 'x', 'x' };

    try std.testing.expectEqualStrings("new", session.provider_id.?);
    try std.testing.expectEqualStrings("new-model", session.model.?);
    try std.testing.expectEqualStrings("New Model", session.model_label.?);
    try std.testing.expectEqualStrings("high", session.effort.?);
    try std.testing.expectEqualStrings("work", session.preset.?);
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expectEqualStrings("kept", session.items()[1].user_message.text);
    try std.testing.expectEqual(retained_before, session.retained_bytes);
}

test "prepared selection can be dropped or publish a no-op without mutation" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "old-provider",
        .model = "old-model",
    });
    defer session.deinit();

    var dropped = try session.prepareSelection(.{
        .provider_id = "new-provider",
        .model = "new-model",
    });
    dropped.deinit();
    try std.testing.expectEqualStrings("old-provider", session.currentSelection().provider_id.?);

    var no_op = try session.prepareSelection(session.currentSelection());
    try std.testing.expect(no_op.replacement == null);
    session.publishSelection(&no_op);
    try std.testing.expectEqualStrings("old-provider", session.currentSelection().provider_id.?);
}

test "selection publication advances its generation even for a no-op" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    const history_before = session.historyGeneration();
    var prepared = try session.prepareSelection(session.currentSelection());
    session.publishSelection(&prepared);

    try std.testing.expectEqual(history_before, session.historyGeneration());
    try std.testing.expectEqual(@as(u64, 1), session.selectionGeneration());
}

test "history mutations advance generation only after success" {
    var session = try Session.init(std.testing.allocator, .{
        .limits = .{ .retained_bytes = 32 },
    });
    defer session.deinit();

    try std.testing.expectEqual(@as(u64, 0), session.historyGeneration());
    try session.addUser("one");
    try std.testing.expectEqual(@as(u64, 1), session.historyGeneration());

    const replacement: Item = .{ .assistant_message = .{ .text = @constCast("answer") } };
    try std.testing.expectError(error.InvalidItemIndex, session.replaceItemCopy(9, &replacement));
    try std.testing.expectEqual(@as(u64, 1), session.historyGeneration());
    try session.appendCopy(&replacement);
    try std.testing.expectEqual(@as(u64, 2), session.historyGeneration());
    try session.replaceItemCopy(2, &replacement);
    try std.testing.expectEqual(@as(u64, 3), session.historyGeneration());

    try std.testing.expect(!try session.addTurnUsage(.{}));
    try std.testing.expectEqual(@as(u64, 3), session.historyGeneration());
    session.reset();
    try std.testing.expectEqual(@as(u64, 4), session.historyGeneration());
}

test "whole-session publication preserves address and retires displaced ownership" {
    var current = try Session.init(std.testing.allocator, .{
        .provider_id = "old-provider",
        .model = "old-model",
    });
    defer current.deinit();
    try current.addUser("old history");
    try current.reconfigureSelection(.{
        .provider_id = "old-provider-2",
        .model = "old-model-2",
    });
    const current_address = &current;
    const old_history_generation = current.historyGeneration();
    const old_selection_generation = current.selectionGeneration();

    var replacement = try Session.init(std.testing.allocator, .{
        .provider_id = "new-provider",
        .model = "new-model",
    });
    try replacement.addUser("new history");
    try replacement.addBoundary();
    try replacement.addBoundary();
    const replacement_history_generation = replacement.historyGeneration();

    var prepared = try current.prepareReplacement(&replacement);
    try std.testing.expectEqual(old_history_generation, prepared.history_generation);
    try std.testing.expectEqual(old_selection_generation, prepared.selection_generation);
    var retired = current.publishReplacement(&prepared);
    defer retired.deinit();

    try std.testing.expectEqual(current_address, &current);
    try std.testing.expectEqual(old_history_generation +% 1, current.historyGeneration());
    try std.testing.expectEqual(old_selection_generation +% 1, current.selectionGeneration());
    try std.testing.expect(replacement_history_generation != current.historyGeneration());
    try std.testing.expectEqualStrings("new-provider", current.currentSelection().provider_id.?);
    try std.testing.expectEqualStrings("new history", current.items()[1].user_message.text);
    try std.testing.expectEqualStrings(
        "old-provider-2",
        retired.session.currentSelection().provider_id.?,
    );
    try std.testing.expectEqualStrings("old history", retired.session.items()[1].user_message.text);
}

test "prepared replacement owns its source and can be dropped" {
    var current = try Session.init(std.testing.allocator, .{});
    defer current.deinit();
    var replacement = try Session.init(std.testing.allocator, .{ .provider_id = "replacement" });
    try replacement.addUser("owned by candidate");

    var prepared = try current.prepareReplacement(&replacement);
    try std.testing.expect(prepared.active);
    try std.testing.expectEqualStrings("replacement", prepared.replacement.provider_id.?);
    prepared.deinit();
}

test "failed replacement preparation retains source ownership" {
    var current = try Session.init(std.testing.allocator, .{});
    defer current.deinit();
    var replacement = try Session.init(std.testing.allocator, .{ .provider_id = "replacement" });
    defer replacement.deinit();
    try replacement.addUser("still owned by caller");

    current.beginRun() catch unreachable;
    try std.testing.expectError(error.SessionBusy, current.prepareReplacement(&replacement));
    current.endRun();
    try std.testing.expectEqualStrings("replacement", replacement.provider_id.?);
    try std.testing.expectEqualStrings("still owned by caller", replacement.items()[1].user_message.text);

    replacement.beginRun() catch unreachable;
    try std.testing.expectError(error.SessionBusy, current.prepareReplacement(&replacement));
    replacement.endRun();
    try std.testing.expectEqualStrings("replacement", replacement.provider_id.?);

    replacement.retained_bytes += 1;
    try std.testing.expectError(error.InvalidItem, current.prepareReplacement(&replacement));
    replacement.retained_bytes -= 1;
    try std.testing.expectEqualStrings("still owned by caller", replacement.items()[1].user_message.text);
}

test "history and selection changes stale a prepared replacement" {
    var current = try Session.init(std.testing.allocator, .{});
    defer current.deinit();
    var replacement = try Session.init(std.testing.allocator, .{});
    var prepared = try current.prepareReplacement(&replacement);
    defer prepared.deinit();

    try current.addBoundary();
    try std.testing.expect(prepared.history_generation != current.historyGeneration());
    try std.testing.expectEqual(prepared.selection_generation, current.selectionGeneration());
    try current.reconfigureSelection(.{ .model = "changed" });
    try std.testing.expect(prepared.selection_generation != current.selectionGeneration());
}

fn exerciseWholeSessionReplacementAllocations(allocator: std.mem.Allocator) !void {
    var current = try Session.init(allocator, .{
        .provider_id = "old-provider",
        .model = "old-model",
    });
    defer current.deinit();
    try current.addUser("old history");

    var replacement = try Session.init(allocator, .{
        .provider_id = "new-provider",
        .model = "new-model",
        .preset = "new-preset",
    });
    var replacement_owned = true;
    defer if (replacement_owned) replacement.deinit();
    try replacement.addUser("new history");

    var prepared = try current.prepareReplacement(&replacement);
    replacement_owned = false;
    defer if (prepared.active) prepared.deinit();
    var retired = current.publishReplacement(&prepared);
    defer retired.deinit();

    try std.testing.expectEqualStrings("new-provider", current.provider_id.?);
    try std.testing.expectEqualStrings("new history", current.items()[1].user_message.text);
    try std.testing.expectEqualStrings("old-provider", retired.session.provider_id.?);
}

test "whole-session replacement handles every allocation failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseWholeSessionReplacementAllocations,
        .{},
    );
}

test "replacement publication performs no allocations" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    const allocator = failing.allocator();
    var current = try Session.init(allocator, .{ .provider_id = "old" });
    defer current.deinit();
    try current.addUser("old");
    var replacement = try Session.init(allocator, .{ .provider_id = "new" });
    try replacement.addUser("new");
    var prepared = try current.prepareReplacement(&replacement);

    failing.fail_index = failing.alloc_index;
    const allocations_before = failing.alloc_index;
    var retired = current.publishReplacement(&prepared);
    defer retired.deinit();

    try std.testing.expectEqual(allocations_before, failing.alloc_index);
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqualStrings("new", current.provider_id.?);
}

test "reconfigure selection allocation failure preserves selection and items" {
    var observed_failure = false;
    var fail_index: usize = 0;
    while (fail_index < 24) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var session = Session.init(failing.allocator(), .{
            .provider_id = "old-provider",
            .model = "old-model",
            .model_label = "Old Model",
            .effort = "low",
            .preset = "old-preset",
        }) catch continue;
        defer session.deinit();
        session.addUser("kept") catch continue;
        session.reconfigureSelection(.{
            .provider_id = "new-provider",
            .model = "new-model",
            .model_label = "New Model",
            .effort = "high",
            .preset = "new-preset",
        }) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            observed_failure = true;
            try std.testing.expectEqualStrings("old-provider", session.provider_id.?);
            try std.testing.expectEqualStrings("old-model", session.model.?);
            try std.testing.expectEqualStrings("Old Model", session.model_label.?);
            try std.testing.expectEqualStrings("low", session.effort.?);
            try std.testing.expectEqualStrings("old-preset", session.preset.?);
            try std.testing.expectEqual(@as(usize, 2), session.items().len);
            try std.testing.expectEqualStrings("kept", session.items()[1].user_message.text);
        };
    }
    try std.testing.expect(observed_failure);
}

test "add user appends boundary then owned message" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try session.addUser("hello");
    try std.testing.expectEqual(@as(usize, 2), session.items().len);
    try std.testing.expect(session.items()[0] == .turn_boundary);
    try std.testing.expectEqualStrings("hello", session.items()[1].user_message.text);
    try std.testing.expectEqual(ai.Item.UserOrigin.external, session.items()[1].user_message.origin);
}

test "continuation is distinguished by origin rather than marker text" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try session.addContinuation();
    try std.testing.expectEqualStrings(continuation_marker, session.items()[1].user_message.text);
    try std.testing.expectEqual(ai.Item.UserOrigin.continuation, session.items()[1].user_message.origin);
}

test "absorb reports old length and stamps reasoning selection" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "model",
    });
    defer session.deinit();
    try session.addUser("question");

    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .reasoning_delta = "thinking" });
    try turn.consume(.{ .text_delta = "answer" });
    try turn.consume(.{ .done = .{} });

    const result = try session.absorbTurn(&turn);
    try std.testing.expectEqual(@as(usize, 2), result.items_from);
    try std.testing.expect(!result.had_tool_call);
    try std.testing.expectEqualStrings("provider", session.items()[2].reasoning.source.?.provider.?);
    try std.testing.expectEqualStrings("model", session.items()[2].reasoning.source.?.model.?);
    try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
}

test "absorb reports completed tool calls" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .tool_call_start = .{ .id = "call", .name = "read" } });
    try turn.consume(.{ .tool_call_end = "call" });
    try turn.consume(.{ .done = .{} });

    const result = try session.absorbTurn(&turn);
    try std.testing.expect(result.had_tool_call);
    try std.testing.expectEqual(@as(usize, 0), result.items_from);
    try std.testing.expect(session.items()[0] == .tool_call);
}

test "interrupt scan ignores usage and boundary after a marked tool result" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var result: Item = .{ .tool_result = .{
        .call_id = try std.testing.allocator.dupe(u8, "call"),
        .output = try std.testing.allocator.dupe(u8, "stopped\n[interrupted]"),
        .origin = .skipped,
    } };
    defer result.deinit(std.testing.allocator);
    try session.appendCopy(&result);
    var usage: Item = .{ .turn_usage = .{ .value = .{} } };
    defer usage.deinit(std.testing.allocator);
    try session.appendCopy(&usage);
    try session.addBoundary();

    try std.testing.expect(!try session.markInterrupt());
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
}

test "interrupt marker is typed and added to empty history" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expect(try session.markInterrupt());
    try std.testing.expectEqualStrings(interrupt_marker, session.items()[0].assistant_message.text);
    try std.testing.expectEqual(
        ai.Item.AssistantOrigin.interrupted,
        session.items()[0].assistant_message.origin,
    );
}

test "add user allocation failure leaves no lone boundary" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    var session = try Session.init(failing.allocator(), .{});
    defer session.deinit();

    try std.testing.expectError(error.OutOfMemory, session.addUser("hello"));
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "absorb allocation failures leave session and turn logically unchanged" {
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var session = try Session.init(failing.allocator(), .{});
        defer session.deinit();
        var turn = try completedTextTurn(std.testing.allocator, "answer");
        defer turn.deinit();

        if (session.absorbTurn(&turn)) |_| {
            try std.testing.expectEqual(@as(usize, 1), session.items().len);
            try std.testing.expectEqual(@as(usize, 0), turn.items.items.len);
            break;
        } else |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expectEqual(@as(usize, 0), session.items().len);
            try std.testing.expectEqual(@as(usize, 1), turn.items.items.len);
        }
    } else return error.TestUnexpectedResult;
}

test "append copy is allocator-independent and enforces retained-byte budget" {
    var session = try Session.init(std.testing.allocator, .{
        .limits = .{ .retained_bytes = 3 },
    });
    defer session.deinit();
    var text = [_]u8{ 'o', 'n', 'e' };
    const item: Item = .{ .assistant_message = .{ .text = &text } };

    try session.appendCopy(&item);
    text = .{ 'x', 'x', 'x' };
    try std.testing.expectEqualStrings("one", session.items()[0].assistant_message.text);
    try std.testing.expectError(error.RetainedDataTooLarge, session.appendCopy(&item));
}

test "append copy enforces aggregate image budgets" {
    var session = try Session.init(std.testing.allocator, .{
        .limits = .{ .images = 1, .image_base64_bytes = 4 },
    });
    defer session.deinit();
    var text = [_]u8{'x'};
    var mime = [_]u8{ 'i', 'm', 'a', 'g', 'e', '/', 'p', 'n', 'g' };
    var data = [_]u8{ 'A', 'A', 'A', 'A' };
    var images = [_]ai.Item.Image{.{ .mime = &mime, .data_base64 = &data }};
    const item: Item = .{ .user_message = .{ .text = &text, .images = &images } };

    try session.appendCopy(&item);
    try std.testing.expectError(error.TooManyImages, session.appendCopy(&item));
}

test "absorb retains source turn when session payload budget rejects it" {
    var session = try Session.init(std.testing.allocator, .{
        .limits = .{ .retained_bytes = 3 },
    });
    defer session.deinit();
    var turn = try completedTextTurn(std.testing.allocator, "four");
    defer turn.deinit();

    try std.testing.expectError(error.RetainedDataTooLarge, session.absorbTurn(&turn));
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
    try std.testing.expectEqual(@as(usize, 1), turn.items.items.len);
}

test "failed turn cannot bypass the abort repair owner" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    var turn = Turn.init(std.testing.allocator, .{});
    defer turn.deinit();
    try turn.consume(.{ .text_delta = "partial" });
    try turn.consume(.{ .failure = .{ .message = "failed" } });

    try std.testing.expectError(error.TurnNeedsRepair, session.absorbTurn(&turn));
    try turn.flushText("\n[interrupted]");
    try std.testing.expectError(error.TurnNeedsRepair, session.absorbTurn(&turn));
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "turn usage owns wire source and normalized display provenance" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "model",
        .model_label = "Model Label",
        .effort = "high",
    });
    defer session.deinit();

    _ = try session.addTurnUsage(.{
        .stream = .{ .input_tokens = 10, .output_tokens = 2 },
        .elapsed_ms = 25,
        .cost_total_usd = 0.5,
        .provider_label = "Provider Label",
        .response = .{
            .id = "response",
            .model = "model",
            .route = "route",
        },
    });

    const record = session.items()[0].turn_usage;
    try std.testing.expectEqualStrings("provider", record.source.?.provider.?);
    try std.testing.expectEqualStrings("model", record.source.?.model.?);
    try std.testing.expectEqualStrings("Provider Label", record.value.provenance.provider_label.?);
    try std.testing.expectEqualStrings("Model Label", record.value.provenance.model_label.?);
    try std.testing.expectEqualStrings("high", record.value.provenance.effort.?);
    try std.testing.expect(record.value.provenance.served_model == null);
    try std.testing.expectEqualStrings("route", record.value.provenance.route.?);
    try std.testing.expectEqualStrings("response", record.value.provenance.response_id.?);
}

test "turn usage omits labels identical to wire identities" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "model",
        .model_label = "model",
        .effort = "",
    });
    defer session.deinit();

    _ = try session.addTurnUsage(.{
        .elapsed_ms = 0,
        .provider_label = "provider",
        .response = .{ .model = "served" },
    });
    const provenance = session.items()[0].turn_usage.value.provenance;
    try std.testing.expect(provenance.provider_label == null);
    try std.testing.expect(provenance.model_label == null);
    try std.testing.expect(provenance.effort == null);
    try std.testing.expectEqualStrings("served", provenance.served_model.?);
}

test "reset clears accounting and retains selection" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .limits = .{ .retained_bytes = 3 },
    });
    defer session.deinit();
    try session.addUser("one");
    session.reset();
    try session.addUser("two");

    try std.testing.expectEqualStrings("provider", session.provider_id.?);
    try std.testing.expectEqualStrings("two", session.items()[1].user_message.text);
}

test "unreported usage without elapsed time is omitted" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expect(!try session.addTurnUsage(.{
        .provider_label = "display-only",
        .response = .{ .id = "response-only" },
    }));
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "usage source omits an empty wire model" {
    var session = try Session.init(std.testing.allocator, .{
        .provider_id = "provider",
        .model = "",
    });
    defer session.deinit();

    try std.testing.expect(try session.addTurnUsage(.{ .elapsed_ms = 0 }));
    const source = session.items()[0].turn_usage.source.?;
    try std.testing.expectEqualStrings("provider", source.provider.?);
    try std.testing.expect(source.model == null);
}

test "cache-only counters do not create a usage footer without elapsed time" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();

    try std.testing.expect(!try session.addTurnUsage(.{ .stream = .{
        .cached_tokens = 1,
        .cache_write_tokens = 2,
        .cache_write_1h_tokens = 3,
    } }));
    try std.testing.expectEqual(@as(usize, 0), session.items().len);
}

test "replace item is atomic and validates hidden tail" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    const original: Item = .{ .assistant_message = .{ .text = @constCast("old") } };
    try session.appendCopy(&original);
    const invalid: Item = .{ .tool_result = .{
        .call_id = @constCast("call"),
        .output = @constCast("x"),
        .hidden_tail_bytes = 2,
    } };
    try std.testing.expectError(error.InvalidItem, session.replaceItemCopy(0, &invalid));
    try std.testing.expectEqualStrings("old", session.items()[0].assistant_message.text);
    const replacement: Item = .{ .tool_result = .{
        .call_id = @constCast("call"),
        .output = @constCast("done"),
        .hidden_tail_bytes = 2,
    } };
    try session.replaceItemCopy(0, &replacement);
    try std.testing.expect(session.items()[0] == .tool_result);
    try std.testing.expectEqualStrings("done", session.items()[0].tool_result.output);
}

test "session rejects malformed externally built image metadata" {
    var images = [_]ai.Item.Image{.{
        .mime = @constCast("image/png"),
        .data_base64 = @constCast("@@@@"),
    }};
    const item: Item = .{ .user_message = .{
        .text = @constCast("image"),
        .images = &images,
    } };
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.InvalidItem, session.appendCopy(&item));
}

test "session rejects negative costs" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try std.testing.expectError(error.InvalidUsage, session.addTurnUsage(.{
        .stream = .{ .cost_usd = -1 },
    }));
}

test "boundary and usage footer admission is atomic under allocation failure" {
    var saw_success = false;
    var fail_index: usize = 0;
    while (fail_index < 12) : (fail_index += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{
            .fail_index = fail_index,
        });
        var session = try Session.init(failing.allocator(), .{});
        defer session.deinit();
        const admitted = session.addTurnUsageWithBoundary(.{
            .stream = .{ .input_tokens = 1 },
            .response = .{ .route = "provider", .model = "model", .id = "id" },
        }, true);
        if (admitted) |did_admit| {
            saw_success = true;
            try std.testing.expect(did_admit);
            try std.testing.expectEqual(@as(usize, 2), session.items().len);
            try std.testing.expect(session.items()[0] == .turn_boundary);
            try std.testing.expect(session.items()[1] == .turn_usage);
        } else |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            try std.testing.expectEqual(@as(usize, 0), session.items().len);
        }
    }
    try std.testing.expect(saw_success);
}

test "reconfigure limits validates retained history without cloning it" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("four");
    const text_pointer = session.items()[1].user_message.text.ptr;

    try std.testing.expectError(error.UserTextTooLarge, session.reconfigureLimits(.{
        .user_text_bytes = 3,
    }));
    try session.addUser("still uses the old limits");
    try session.reconfigureLimits(.{
        .items = 16,
        .user_text_bytes = 32,
    });
    try std.testing.expectEqual(text_pointer, session.items()[1].user_message.text.ptr);
    try std.testing.expectError(error.UserTextTooLarge, session.addUser("012345678901234567890123456789012"));
}

test "reconfigure limits rejects aggregate history and preserves old limits" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addUser("hello");
    try std.testing.expectError(error.TooManyItems, session.reconfigureLimits(.{ .items = 1 }));
    try session.addBoundary();
    try std.testing.expectEqual(@as(usize, 3), session.items().len);
}

test "task note atomically appends one tagged user message" {
    var session = try Session.init(std.testing.allocator, .{});
    defer session.deinit();
    try session.addTaskNote("[task t1 exited 0]");
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
    try std.testing.expect(session.items()[0] == .user_message);
    try std.testing.expectEqual(ai.Item.UserOrigin.task_note, session.items()[0].user_message.origin);
}

fn exerciseTaskNoteAllocations(allocator: std.mem.Allocator) !void {
    var session = try Session.init(allocator, .{});
    defer session.deinit();
    session.addTaskNote("[task t1 exited 0]") catch |err| {
        try std.testing.expectEqual(@as(usize, 0), session.items().len);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), session.items().len);
}

test "task note allocation failures leave the session unchanged" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTaskNoteAllocations,
        .{},
    );
}
