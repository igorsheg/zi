const std = @import("std");
const ai_protocol = @import("../ai/protocol.zig");
const agent_root = @import("../agent/root.zig");
const control_mod = @import("../agent/control.zig");
const agent_protocol = agent_root.protocol;
const AgentToolResult = agent_protocol.AgentToolResult;
const transcript_mod = @import("transcript.zig");
const tool_display_mod = @import("tool_display.zig");
const editor_iface_mod = @import("editor_iface.zig");
const markdown_mod = @import("components/markdown.zig");
const assistant_message_component_mod = @import("components/assistant_message.zig");
const user_message_component_mod = @import("components/user_message.zig");
const theme_mod = @import("theme.zig");
const themes_builtin = @import("../themes/builtin.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const editor_mod = @import("components/editor.zig");
const conversation_state_mod = @import("../agent/conversation_state.zig");
const message_memory = @import("../agent/message_memory.zig");
const json_util = @import("../ai/json_util.zig");
const rendered_tool_result_view = @import("rendered_tool_result.zig");

const Transcript = transcript_mod.Transcript;
const TranscriptItem = transcript_mod.TranscriptItem;
const TranscriptRenderable = transcript_mod.TranscriptRenderable;
const ToolRendererResolver = tool_display_mod.ToolRendererResolver;
const EditorInterface = editor_iface_mod.EditorInterface;
const Theme = theme_mod.Theme;
const Markdown = markdown_mod.Markdown;
const Buffer = buffer_mod.Buffer;
const Color = cell_mod.Color;
const testing = std.testing;

pub const RebuildOptions = struct {
    theme: *const Theme,
    retry_attempt: u32 = 0,
    hidden_thinking_label: []const u8 = "Thinking...",
};

const DesiredItem = struct {
    item_id: transcript_mod.ItemId,
    semantic_version: transcript_mod.SemanticVersion,
    /// P2: null means "the transcript already has a retained row with
    /// this id+version; reconcile must only retain/move, not replace or
    /// insert." Non-null rows are owned until reconcile transfers
    /// ownership via insertItemAt/replaceItemAt and disarmDesiredRow.
    row: ?TranscriptItem = null,
    seed_editor_history: bool = false,
    history_text: ?ExtractedText = null,

    fn deinit(self: *DesiredItem, allocator: std.mem.Allocator) void {
        if (self.history_text) |text| text.deinit(allocator);
        if (self.row) |*row| row.deinit(allocator);
        self.* = undefined;
    }
};

const ExtractedText = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn slice(self: ExtractedText) []const u8 {
        return switch (self) {
            .borrowed => |text| text,
            .owned => |text| text,
        };
    }

    fn deinit(self: ExtractedText, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |text| allocator.free(text),
        }
    }
};

fn ownedViewSnapshotFromMessages(
    allocator: std.mem.Allocator,
    messages: []const agent_protocol.AgentMessage,
) !conversation_state_mod.ConversationSnapshotEnvelope {
    const shared = try conversation_state_mod.SharedCommitted.fromMessages(allocator, messages);
    errdefer shared.release();

    return .{ .view = .{
        .committed = shared,
        .in_flight = null,
    } };
}

fn emptyQueuedSnapshot(allocator: std.mem.Allocator) !control_mod.QueuedMessageSnapshot {
    const steering = try allocator.alloc(control_mod.QueuedMessageText, 0);
    errdefer allocator.free(steering);
    const follow_up = try allocator.alloc(control_mod.QueuedMessageText, 0);
    return .{
        .steering = steering,
        .follow_up = follow_up,
    };
}

const CachedCommittedItem = struct {
    item_id: transcript_mod.ItemId,
    semantic_version: transcript_mod.SemanticVersion,
};

const CommittedCacheReuse = enum {
    hit,
    no_cache,
    committed_changed,
    retry_changed,
};

/// Cached metadata for the committed portion of the last projected
/// view snapshot. Reused by replaceViewSnapshot when the incoming
/// snapshot points at the same *SharedCommitted and the cache key
/// inputs (retry_attempt) still match — lets us skip rebuilding the
/// committed-message portion of desired items, which is the hot part
/// of the projection loop on soft updates.
///
/// The cache retains its own reference on `committed` because the
/// pointer is used as a cache key across frames; without the retain,
/// a failed full-rebuild after the previous view_snapshot is released
/// could leave the cache holding a freed pointer that a later frame
/// would compare against (ABA risk).
const CommittedProjectionCache = struct {
    committed: *conversation_state_mod.SharedCommitted,
    retry_attempt: u32,
    items: []CachedCommittedItem,

    fn deinit(self: *CommittedProjectionCache, allocator: std.mem.Allocator) void {
        self.committed.release();
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub const ProjectionState = struct {
    allocator: std.mem.Allocator,
    view_snapshot: ?conversation_state_mod.ConversationSnapshotEnvelope = null,
    queued_snapshot: ?control_mod.QueuedMessageSnapshot = null,
    committed_cache: ?CommittedProjectionCache = null,
    committed_cache_hits: u32 = 0,
    committed_cache_misses: u32 = 0,
    committed_cache_fallbacks: u32 = 0,
    full_rebuilds: u32 = 0,
    transient_rebuilds: u32 = 0,
    cache_miss_no_cache: u32 = 0,
    cache_miss_committed_changed: u32 = 0,
    cache_miss_retry_changed: u32 = 0,
    queued_reconciles: u32 = 0,

    pub fn init(allocator: std.mem.Allocator) ProjectionState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProjectionState) void {
        self.clear();
    }

    pub fn clear(self: *ProjectionState) void {
        if (self.view_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        if (self.queued_snapshot) |*snapshot| snapshot.deinit(self.allocator);
        if (self.committed_cache) |*cache| cache.deinit(self.allocator);
        self.view_snapshot = null;
        self.queued_snapshot = null;
        self.committed_cache = null;
    }

    pub fn replaceViewSnapshot(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        snapshot: *conversation_state_mod.ConversationSnapshotEnvelope,
        options: RebuildOptions,
    ) void {
        var owned = snapshot.*;
        snapshot.* = undefined;

        // Reject stale snapshots by generation/version (authoritative ordering truth).
        if (self.view_snapshot) |previous| {
            if (owned.session_generation < previous.session_generation or
                (owned.session_generation == previous.session_generation and
                    owned.conversation_version < previous.conversation_version))
            {
                owned.deinit(self.allocator);
                return;
            }
        }

        const must_reset_history = if (self.view_snapshot) |previous|
            previous.view.committed != owned.view.committed and
                !committedUserHistoryIsPrefix(previous.view.committed.flat, owned.view.committed.flat)
        else
            false;
        const cache_reuse = self.committedCacheReuseFor(owned.view.committed, options.retry_attempt);

        if (self.view_snapshot) |*s| s.deinit(self.allocator);
        self.view_snapshot = owned;

        self.reconcileView(transcript, editor, resolver, options, cache_reuse);

        if (must_reset_history) {
            editor.clearHistory();
            seedHistoryFromCommittedMessages(editor, self.view_snapshot.?.view.committed.flat);
        }
    }

    fn canReuseCommittedCache(self: *const ProjectionState, retry_attempt: u32) bool {
        const snapshot = self.view_snapshot orelse return false;
        return self.committedCacheReuseFor(snapshot.view.committed, retry_attempt) == .hit;
    }

    fn committedCacheReuseFor(
        self: *const ProjectionState,
        committed: *conversation_state_mod.SharedCommitted,
        retry_attempt: u32,
    ) CommittedCacheReuse {
        const cache = self.committed_cache orelse return .no_cache;
        if (cache.committed != committed) return .committed_changed;
        if (cache.retry_attempt != retry_attempt) return .retry_changed;
        return .hit;
    }

    fn reconcileView(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        options: RebuildOptions,
        cache_reuse: CommittedCacheReuse,
    ) void {
        const allocator = transcript.allocator;

        if (cache_reuse == .hit) {
            self.transient_rebuilds +%= 1;
            const cache = &self.committed_cache.?;
            var transient_items = buildTransientDesiredItems(
                allocator,
                resolver,
                transcript,
                self.view_snapshot,
                self.queued_snapshot,
                options,
                transcript.hide_thinking_block,
            ) catch return;
            defer {
                for (transient_items.items) |*item| item.deinit(allocator);
                transient_items.deinit(allocator);
            }
            if (reconcileTransientItemsAfterCommittedCache(transcript, editor, cache.items, &transient_items)) {
                self.committed_cache_hits +%= 1;
                return;
            }
            // Cache key matched but transcript rows were externally cleared or
            // reordered. Fall through to the full rebuild path below.
            self.committed_cache_fallbacks +%= 1;
        } else {
            self.committed_cache_misses +%= 1;
            switch (cache_reuse) {
                .hit => unreachable,
                .no_cache => self.cache_miss_no_cache +%= 1,
                .committed_changed => self.cache_miss_committed_changed +%= 1,
                .retry_changed => self.cache_miss_retry_changed +%= 1,
            }
        }

        self.full_rebuilds +%= 1;
        var cache_builder: std.ArrayList(CachedCommittedItem) = .empty;
        var cache_ptr: ?*std.ArrayList(CachedCommittedItem) = null;
        const can_cache = if (self.view_snapshot) |v| blk: {
            cache_ptr = &cache_builder;
            break :blk v.view.committed;
        } else null;

        var desired_items = buildDesiredItemsFull(
            allocator,
            resolver,
            transcript,
            self.view_snapshot,
            self.queued_snapshot,
            options,
            transcript.hide_thinking_block,
            cache_ptr,
        ) catch {
            cache_builder.deinit(allocator);
            return;
        };
        defer {
            for (desired_items.items) |*item| item.deinit(allocator);
            desired_items.deinit(allocator);
        }

        if (can_cache) |committed| {
            if (self.committed_cache) |*old| old.deinit(allocator);
            self.committed_cache = .{
                .committed = committed.retain(),
                .retry_attempt = options.retry_attempt,
                .items = cache_builder.toOwnedSlice(allocator) catch &.{},
            };
        } else {
            cache_builder.deinit(allocator);
        }

        reconcileDesiredItems(transcript, editor, &desired_items);
    }

    pub fn replaceQueuedSnapshot(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        snapshot: *control_mod.QueuedMessageSnapshot,
        options: RebuildOptions,
    ) void {
        var owned = snapshot.*;
        snapshot.* = undefined;
        if (self.queued_snapshot) |current| {
            if (owned.version <= current.version) {
                owned.deinit(self.allocator);
                return;
            }
        }
        if (self.queued_snapshot) |*s| s.deinit(self.allocator);
        self.queued_snapshot = owned;
        self.queued_reconciles +%= 1;
        reconcileFromSnapshots(transcript, editor, resolver, self.view_snapshot, self.queued_snapshot, options);
    }

    pub fn replaceAllOwnedState(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        view: *conversation_state_mod.ConversationSnapshotEnvelope,
        queued: *control_mod.QueuedMessageSnapshot,
        options: RebuildOptions,
    ) void {
        self.replaceViewSnapshot(transcript, editor, resolver, view, options);
        self.replaceQueuedSnapshot(transcript, editor, resolver, queued, options);
    }
};

pub fn rebuildFromSnapshots(
    transcript: *Transcript,
    editor: EditorInterface,
    resolver: ToolRendererResolver,
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
) void {
    transcript.clearAll();
    editor.clearHistory();

    var desired_items = buildDesiredItems(transcript.allocator, resolver, transcript, view, queued, options, transcript.hide_thinking_block) catch return;
    defer {
        for (desired_items.items) |*item| item.deinit(transcript.allocator);
        desired_items.deinit(transcript.allocator);
    }

    for (desired_items.items, 0..) |desired, idx| {
        // rebuildFromSnapshots cleared the transcript above, so every desired
        // item MUST carry a freshly-built row (P2 retain path can't trigger
        // against an empty transcript).
        std.debug.assert(desired.row != null);
        if (!transcript.addItem(desired.row.?)) return;
        disarmDesiredRow(&desired_items.items[idx]);
        if (desired.seed_editor_history) {
            if (desired.history_text) |history_text| editor.addToHistory(history_text.slice());
        }
    }

    transcript.clearPendingToolRouting();
}

pub fn reconcileFromSnapshots(
    transcript: *Transcript,
    editor: EditorInterface,
    resolver: ToolRendererResolver,
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
) void {
    var desired_items = buildDesiredItems(transcript.allocator, resolver, transcript, view, queued, options, transcript.hide_thinking_block) catch return;
    defer {
        for (desired_items.items) |*item| item.deinit(transcript.allocator);
        desired_items.deinit(transcript.allocator);
    }

    reconcileDesiredItems(transcript, editor, &desired_items);
}

fn reconcileTransientItemsAfterCommittedCache(
    transcript: *Transcript,
    editor: EditorInterface,
    cache_items: []const CachedCommittedItem,
    transient_items: *std.ArrayList(DesiredItem),
) bool {
    if (!transcriptPrefixMatchesCommittedCache(transcript, cache_items)) return false;
    for (transient_items.items) |desired| {
        if (desired.row == null) return false;
    }

    const was_following_bottom = transcript.isFollowingBottom();
    const scroll_before = transcript.scrollOffset();
    const width_before = transcript.last_render_width;
    const height_before = transcript.last_visible_height;

    transcript.truncateFrom(cache_items.len);
    var index = cache_items.len;
    for (transient_items.items, 0..) |desired, desired_idx| {
        _ = transcript.insertItemAt(index, desired.row.?);
        disarmDesiredRow(&transient_items.items[desired_idx]);
        if (desired.seed_editor_history) {
            if (desired.history_text) |history_text| editor.addToHistory(history_text.slice());
        }
        index += 1;
    }
    if (!was_following_bottom) {
        transcript.restoreScrollOffset(scroll_before, false, width_before, height_before);
    }
    transcript.clearPendingToolRouting();
    return true;
}

fn transcriptPrefixMatchesCommittedCache(transcript: *const Transcript, cache_items: []const CachedCommittedItem) bool {
    if (transcript.items.items.len < cache_items.len) return false;
    for (cache_items, 0..) |cached, idx| {
        const item = transcript.items.items[idx];
        if (item.retained_item_id == null or item.retained_item_id.? != cached.item_id) return false;
        if (item.retained_semantic_version == null or item.retained_semantic_version.? != cached.semantic_version) return false;
    }
    return true;
}

fn reconcileDesiredItems(
    transcript: *Transcript,
    editor: EditorInterface,
    desired_items: *std.ArrayList(DesiredItem),
) void {
    var desired_index: usize = 0;
    while (desired_index < desired_items.items.len) : (desired_index += 1) {
        const desired = desired_items.items[desired_index];
        const existing_index = transcript.findRetainedItemIndex(desired.item_id);
        if (existing_index) |current_index| {
            if (transcript.retainedItemSemanticVersionAt(current_index) == desired.semantic_version) {
                // P2 contract: same version ⇒ row must be null (not built).
                std.debug.assert(desired.row == null);
                if (current_index != desired_index) transcript.moveItem(current_index, desired_index);
            } else {
                // Version changed ⇒ builder must have produced a fresh row.
                std.debug.assert(desired.row != null);
                _ = transcript.replaceItemAt(current_index, desired.row.?);
                disarmDesiredRow(&desired_items.items[desired_index]);
                if (current_index != desired_index) transcript.moveItem(current_index, desired_index);
            }
        } else {
            // New item ⇒ builder must have produced a fresh row.
            std.debug.assert(desired.row != null);
            _ = transcript.insertItemAt(desired_index, desired.row.?);
            disarmDesiredRow(&desired_items.items[desired_index]);
        }

        if (desired.seed_editor_history and existing_index == null) {
            if (desired.history_text) |history_text| editor.addToHistory(history_text.slice());
        }
    }

    while (transcript.items.items.len > desired_items.items.len) {
        transcript.removeRenderable(transcript.items.items[transcript.items.items.len - 1].renderable);
    }

    transcript.clearPendingToolRouting();
}

const QueuedUserMessageKind = enum {
    steering,
    follow_up,
};

/// Editor history should survive append-only conversation growth, but whole
/// conversation replacement must reseed it from committed user messages.
/// We treat the previous committed user-message sequence as a prefix contract.
fn committedUserHistoryIsPrefix(
    previous_messages: []const agent_protocol.AgentMessage,
    next_messages: []const agent_protocol.AgentMessage,
) bool {
    var next_index: usize = 0;
    for (previous_messages) |previous_message| {
        const previous_text = extractUserMessageText(std.heap.page_allocator, previous_message) orelse continue;
        defer previous_text.deinit(std.heap.page_allocator);

        var matched = false;
        while (next_index < next_messages.len) : (next_index += 1) {
            const next_message = next_messages[next_index];
            const next_text = extractUserMessageText(std.heap.page_allocator, next_message) orelse continue;
            defer next_text.deinit(std.heap.page_allocator);
            next_index += 1;
            if (!std.mem.eql(u8, previous_text.slice(), next_text.slice())) return false;
            matched = true;
            break;
        }
        if (!matched) return false;
    }
    return true;
}

fn buildDesiredItems(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
    hide_thinking_block: bool,
) !std.ArrayList(DesiredItem) {
    return buildDesiredItemsFull(allocator, resolver, transcript, view, queued, options, hide_thinking_block, null);
}

/// Full builder: rebuilds committed-message desired items from scratch
/// and appends transient items (active assistant, live tool executions,
/// queued messages). If `cache_out` is non-null, records the committed
/// prefix metadata so a later soft update with an unchanged committed
/// pointer can skip the committed portion.
fn buildDesiredItemsFull(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
    hide_thinking_block: bool,
    cache_out: ?*std.ArrayList(CachedCommittedItem),
) !std.ArrayList(DesiredItem) {
    var desired_items: std.ArrayList(DesiredItem) = .empty;
    errdefer {
        for (desired_items.items) |*item| item.deinit(allocator);
        desired_items.deinit(allocator);
    }

    var live_tool_ids: std.ArrayList([]const u8) = .empty;
    defer live_tool_ids.deinit(allocator);
    if (view) |v| if (v.view.in_flight) |turn| {
        for (turn.tool_executions) |tool| {
            try live_tool_ids.append(allocator, tool.tool_call_id);
        }
    };

    const committed_start = desired_items.items.len;
    if (view) |v| try appendCommittedDesiredItems(
        allocator,
        resolver,
        transcript,
        &desired_items,
        v,
        options,
        live_tool_ids.items,
        hide_thinking_block,
    );
    if (cache_out) |out| try recordCommittedCacheItems(allocator, out, desired_items.items[committed_start..]);

    try appendTransientDesiredItems(
        allocator,
        resolver,
        transcript,
        &desired_items,
        view,
        queued,
        options,
        live_tool_ids.items,
        hide_thinking_block,
    );
    return desired_items;
}

/// Fast path for unchanged committed snapshots: build only active/queued rows.
/// The committed prefix is already retained in the transcript and represented
/// by `CommittedProjectionCache.items`, so soft streaming updates avoid
/// allocating one DesiredItem per historical row.
fn buildTransientDesiredItems(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
    hide_thinking_block: bool,
) !std.ArrayList(DesiredItem) {
    var desired_items: std.ArrayList(DesiredItem) = .empty;
    errdefer {
        for (desired_items.items) |*item| item.deinit(allocator);
        desired_items.deinit(allocator);
    }

    var live_tool_ids: std.ArrayList([]const u8) = .empty;
    defer live_tool_ids.deinit(allocator);
    if (view) |v| if (v.view.in_flight) |turn| {
        for (turn.tool_executions) |tool| {
            try live_tool_ids.append(allocator, tool.tool_call_id);
        }
    };

    try appendTransientDesiredItems(
        allocator,
        resolver,
        transcript,
        &desired_items,
        view,
        queued,
        options,
        live_tool_ids.items,
        hide_thinking_block,
    );
    return desired_items;
}

fn appendCommittedDesiredItems(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    desired_items: *std.ArrayList(DesiredItem),
    view: conversation_state_mod.ConversationSnapshotEnvelope,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !void {
    const committed_slice = view.view.committed.flat;
    for (committed_slice, 0..) |message, idx| {
        try appendDesiredItem(
            allocator,
            desired_items,
            buildCommittedMessageItem(allocator, resolver, transcript, idx, message, options, live_tool_ids, hide_thinking_block),
        );
        switch (message) {
            .assistant => |assistant| {
                for (assistant.content) |block| {
                    if (block != .tool_call) continue;
                    const tool_call = block.tool_call;
                    if (containsToolCallId(live_tool_ids, tool_call.id)) continue;
                    try appendDesiredItem(
                        allocator,
                        desired_items,
                        buildCommittedToolCallDesiredItem(
                            allocator,
                            resolver,
                            transcript,
                            tool_call,
                            assistant,
                            findCommittedToolResultMessage(committed_slice[idx + 1 ..], tool_call.id),
                            view.view.rendered_tool_renders,
                            options,
                        ),
                    );
                }
            },
            else => {},
        }
    }
}

fn appendTransientDesiredItems(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    desired_items: *std.ArrayList(DesiredItem),
    view: ?conversation_state_mod.ConversationSnapshotEnvelope,
    queued: ?control_mod.QueuedMessageSnapshot,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !void {
    if (view) |v| if (v.view.in_flight) |turn| {
        if (turn.assistant) |assistant| {
            try appendDesiredItem(
                allocator,
                desired_items,
                buildActiveAssistantDesiredItem(allocator, transcript, assistant, live_tool_ids, options.theme, hide_thinking_block, options.hidden_thinking_label),
            );
        }
        for (turn.tool_executions) |*tool| {
            try appendDesiredItem(
                allocator,
                desired_items,
                buildToolExecutionDesiredItem(allocator, resolver, transcript, tool, options.theme),
            );
        }
    };
    if (queued) |q| {
        for (q.steering, 0..) |entry, idx| {
            try appendDesiredItem(
                allocator,
                desired_items,
                buildQueuedUserDesiredItem(allocator, transcript, .steering, idx, entry.text, options.theme),
            );
        }
        for (q.follow_up, 0..) |entry, idx| {
            try appendDesiredItem(
                allocator,
                desired_items,
                buildQueuedUserDesiredItem(allocator, transcript, .follow_up, idx, entry.text, options.theme),
            );
        }
    }
}

fn recordCommittedCacheItems(
    allocator: std.mem.Allocator,
    cache_out: *std.ArrayList(CachedCommittedItem),
    committed_items: []const DesiredItem,
) !void {
    try cache_out.ensureTotalCapacity(allocator, committed_items.len);
    for (committed_items) |desired| {
        cache_out.appendAssumeCapacity(.{
            .item_id = desired.item_id,
            .semantic_version = desired.semantic_version,
        });
    }
}

fn appendDesiredItem(
    allocator: std.mem.Allocator,
    desired_items: *std.ArrayList(DesiredItem),
    result: anyerror!DesiredItem,
) !void {
    const desired = result catch |err| switch (err) {
        error.SkipHiddenCustomMessage,
        error.EmptyCustomMessage,
        error.EmptyUserMessage,
        error.EmptyAssistantMessage,
        error.UnsupportedStandaloneToolResult,
        => return,
        else => return err,
    };
    try desired_items.append(allocator, desired);
}

fn buildCommittedMessageItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    index: usize,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !DesiredItem {
    const item_id = committedMessageId(index, message);
    const semantic_version = committedMessageSemanticVersion(message);
    if (transcript.hasRetainedMatch(item_id, semantic_version)) {
        return .{ .item_id = item_id, .semantic_version = semantic_version };
    }
    var row = try buildMessageRow(allocator, resolver, message, options, live_tool_ids, hide_thinking_block);
    row.retained_item_id = item_id;
    row.retained_semantic_version = semantic_version;

    const history_text = extractUserMessageText(allocator, message);
    return .{
        .item_id = item_id,
        .semantic_version = semantic_version,
        .row = row,
        .seed_editor_history = history_text != null,
        .history_text = history_text,
    };
}

fn buildActiveAssistantDesiredItem(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    assistant: agent_protocol.AssistantMessage,
    live_tool_ids: []const []const u8,
    theme: *const Theme,
    hide_thinking_block: bool,
    hidden_thinking_label: []const u8,
) !DesiredItem {
    const item_id = activeAssistantId(assistant);
    const semantic_version = activeAssistantSemanticVersion(assistant);
    if (transcript.hasRetainedMatch(item_id, semantic_version)) {
        return .{ .item_id = item_id, .semantic_version = semantic_version };
    }
    var row = try createAssistantMessageRow(allocator, assistant, live_tool_ids, theme, hide_thinking_block, hidden_thinking_label);
    row.retained_item_id = item_id;
    row.retained_semantic_version = semantic_version;
    return .{ .item_id = item_id, .semantic_version = semantic_version, .row = row };
}

fn buildToolExecutionDesiredItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    tool_execution: *conversation_state_mod.ToolExecution,
    theme: *const Theme,
) !DesiredItem {
    const item_id = toolExecutionId(tool_execution.tool_call_id);
    const semantic_version = toolExecutionSemanticVersion(tool_execution.*);
    if (transcript.hasRetainedMatch(item_id, semantic_version)) {
        return .{ .item_id = item_id, .semantic_version = semantic_version };
    }
    var row = try createToolExecutionRow(allocator, resolver, tool_execution, theme);
    row.retained_item_id = item_id;
    row.retained_semantic_version = semantic_version;
    return .{ .item_id = item_id, .semantic_version = semantic_version, .row = row };
}

fn buildCommittedToolCallDesiredItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    transcript: *Transcript,
    tool_call: agent_protocol.ToolCall,
    assistant: agent_protocol.AssistantMessage,
    result_message: ?agent_protocol.ToolResultMessage,
    rendered_entries: []conversation_state_mod.RenderedToolRenderEntry,
    options: RebuildOptions,
) !DesiredItem {
    const item_id = toolExecutionId(tool_call.id);
    const semantic_version = committedToolCallSemanticVersion(tool_call, assistant, result_message, options.retry_attempt);
    if (transcript.hasRetainedMatch(item_id, semantic_version)) {
        return .{ .item_id = item_id, .semantic_version = semantic_version };
    }
    const rendered = findRenderedToolRender(rendered_entries, tool_call.id);
    var row = try createCommittedToolCallRow(
        allocator,
        resolver,
        tool_call,
        assistant,
        result_message,
        rendered,
        options.retry_attempt,
        options.theme,
    );
    row.retained_item_id = item_id;
    row.retained_semantic_version = semantic_version;
    return .{ .item_id = item_id, .semantic_version = semantic_version, .row = row };
}

fn buildQueuedUserDesiredItem(
    allocator: std.mem.Allocator,
    transcript: *Transcript,
    kind: QueuedUserMessageKind,
    ordinal: usize,
    text: []const u8,
    theme: *const Theme,
) !DesiredItem {
    const item_id = queuedUserMessageId(kind, ordinal);
    const semantic_version = queuedUserMessageSemanticVersion(text);
    if (transcript.hasRetainedMatch(item_id, semantic_version)) {
        return .{ .item_id = item_id, .semantic_version = semantic_version };
    }
    var model = try buildUserRowModel(
        allocator,
        text,
        switch (kind) {
            .steering => .queued_steering,
            .follow_up => .queued_follow_up,
        },
        .pending,
    );
    defer model.deinit(allocator);

    var row = try createUserMessageRow(allocator, &model, .queued_user_message, theme);
    row.retained_item_id = item_id;
    row.retained_semantic_version = semantic_version;
    return .{ .item_id = item_id, .semantic_version = semantic_version, .row = row };
}
fn disarmDesiredRow(item: *DesiredItem) void {
    if (item.row) |*row| {
        row.deinit_ctx = null;
        row.deinit_fn = null;
    }
}

fn seedHistoryFromCommittedMessages(editor: EditorInterface, messages: []const agent_protocol.AgentMessage) void {
    for (messages) |message| seedHistoryFromMessage(editor, message);
}

fn seedHistoryFromMessage(editor: EditorInterface, message: agent_protocol.AgentMessage) void {
    const text = extractUserMessageText(std.heap.page_allocator, message) orelse return;
    defer text.deinit(std.heap.page_allocator);
    editor.addToHistory(text.slice());
}

fn containsToolCallId(tool_call_ids: []const []const u8, tool_call_id: []const u8) bool {
    for (tool_call_ids) |candidate| {
        if (std.mem.eql(u8, candidate, tool_call_id)) return true;
    }
    return false;
}

fn createCommittedToolCallRow(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool_call: agent_protocol.ToolCall,
    assistant: agent_protocol.AssistantMessage,
    result_message: ?agent_protocol.ToolResultMessage,
    rendered: RenderedToolRender,
    retry_attempt: u32,
    theme: *const Theme,
) !TranscriptItem {
    var owned_abort_message: ?[]u8 = null;
    defer if (owned_abort_message) |message| allocator.free(message);

    var error_content: [1]AgentToolResult.ContentBlock = undefined;
    var result: ?AgentToolResult = null;
    var is_error = false;
    if (result_message == null) {
        if (failedAssistantToolCallText(allocator, assistant, retry_attempt, &owned_abort_message)) |error_text| {
            error_content[0] = .{ .text = .{ .text = error_text } };
            result = .{
                .content = &error_content,
                .is_error = true,
            };
            is_error = true;
        }
    }

    var model = try buildToolExecutionRowModel(
        allocator,
        tool_call.id,
        tool_call.name,
        tool_call.arguments,
        null,
        true,
        false,
        result,
        rendered.rendered_call,
        rendered.rendered_result,
        result_message,
        false,
        if (result_message) |message| message.is_error else is_error,
    );
    defer model.deinit(allocator);
    return createToolExecutionRowParts(allocator, resolver, &model, theme);
}

fn failedAssistantToolCallText(
    allocator: std.mem.Allocator,
    assistant: agent_protocol.AssistantMessage,
    retry_attempt: u32,
    owned_abort_message: *?[]u8,
) ?[]const u8 {
    return switch (assistant.stop_reason) {
        .aborted => blk: {
            if (retry_attempt == 0) break :blk "Operation aborted";
            owned_abort_message.* = std.fmt.allocPrint(
                allocator,
                "Aborted after {d} retry attempt{s}",
                .{ retry_attempt, if (retry_attempt == 1) "" else "s" },
            ) catch null;
            break :blk owned_abort_message.* orelse "Operation aborted";
        },
        .@"error" => assistant.error_message orelse "Error",
        else => null,
    };
}

fn findCommittedToolResultMessage(
    messages: []const agent_protocol.AgentMessage,
    tool_call_id: []const u8,
) ?agent_protocol.ToolResultMessage {
    for (messages) |message| {
        if (message != .tool_result) continue;
        const tool_result = message.tool_result;
        if (std.mem.eql(u8, tool_result.tool_call_id, tool_call_id)) return tool_result;
    }
    return null;
}

const RenderedToolRender = struct {
    rendered_call: ?*rendered_tool_result_view.RenderedToolResult = null,
    rendered_result: ?*rendered_tool_result_view.RenderedToolResult = null,
};

fn findRenderedToolRender(
    entries: []conversation_state_mod.RenderedToolRenderEntry,
    tool_call_id: []const u8,
) RenderedToolRender {
    for (entries) |*entry| {
        if (!std.mem.eql(u8, entry.tool_call_id, tool_call_id)) continue;
        const rendered = RenderedToolRender{
            .rendered_call = entry.rendered_call,
            .rendered_result = entry.rendered_result,
        };
        entry.rendered_call = null;
        entry.rendered_result = null;
        return rendered;
    }
    return .{};
}

fn extractUserMessageText(
    allocator: std.mem.Allocator,
    message: agent_protocol.AgentMessage,
) ?ExtractedText {
    switch (message) {
        .user => |user| return switch (user.content) {
            .text => |text| if (text.len == 0) null else .{ .borrowed = text },
            .blocks => |blocks| blk: {
                const joined = joinUserBlocksText(allocator, blocks) catch return null;
                if (joined.len == 0) {
                    allocator.free(joined);
                    break :blk null;
                }
                break :blk .{ .owned = joined };
            },
        },
        else => return null,
    }
}

fn buildMessageRow(
    allocator: std.mem.Allocator,
    _: ToolRendererResolver,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !TranscriptItem {
    return switch (message) {
        .user => try buildUserRow(allocator, message, options.theme),
        .assistant => |assistant| try createAssistantMessageRow(allocator, assistant, live_tool_ids, options.theme, hide_thinking_block, options.hidden_thinking_label),
        .compaction_summary => |summary| try buildSummaryRow(allocator, options.theme, "Compaction summary", summary.summary),
        .branch_summary => |summary| try buildSummaryRow(allocator, options.theme, "Branch summary", summary.summary),
        .custom => |custom| if (custom.display)
            try buildCustomRow(allocator, options.theme, custom)
        else
            error.SkipHiddenCustomMessage,
        .tool_result => error.UnsupportedStandaloneToolResult,
    };
}

fn buildUserRow(allocator: std.mem.Allocator, message: agent_protocol.AgentMessage, theme: *const Theme) !TranscriptItem {
    const text = extractUserMessageText(allocator, message) orelse return error.EmptyUserMessage;
    defer text.deinit(allocator);

    var model = try buildUserRowModel(allocator, text.slice(), .none, .in_chat);
    defer model.deinit(allocator);
    return createUserMessageRow(allocator, &model, .user_message, theme);
}

fn buildSummaryRow(allocator: std.mem.Allocator, theme: *const Theme, label: []const u8, summary: []const u8) !TranscriptItem {
    const content = try std.fmt.allocPrint(allocator, "**{s}**\n\n{s}", .{ label, summary });
    defer allocator.free(content);
    return createMarkdownRow(allocator, theme, content, theme.fg(.muted), Color.default);
}

fn buildCustomRow(allocator: std.mem.Allocator, theme: *const Theme, custom: agent_protocol.AgentMessage.CustomMessage) !TranscriptItem {
    const body = try customContentText(allocator, custom.content);
    defer allocator.free(body);
    if (body.len == 0) return error.EmptyCustomMessage;
    const content = try std.fmt.allocPrint(allocator, "**{s}**\n\n{s}", .{ custom.custom_type, body });
    defer allocator.free(content);
    return createMarkdownRow(allocator, theme, content, theme.fg(.custom_message_text), theme.bg(.custom_message_bg));
}

fn buildAssistantRowModel(
    allocator: std.mem.Allocator,
    assistant: agent_protocol.AssistantMessage,
    live_tool_ids: []const []const u8,
) !assistant_message_component_mod.AssistantRowModel {
    var model: assistant_message_component_mod.AssistantRowModel = .{};
    errdefer model.deinit(allocator);

    for (assistant.content) |block| {
        switch (block) {
            .text => |text| {
                if (std.mem.trim(u8, text.text, &std.ascii.whitespace).len == 0) continue;
                try model.blocks.append(allocator, .{ .text = try allocator.dupe(u8, text.text) });
            },
            .thinking => |thinking| {
                if (std.mem.trim(u8, thinking.thinking, &std.ascii.whitespace).len == 0) continue;
                try model.blocks.append(allocator, .{ .thinking = try allocator.dupe(u8, thinking.thinking) });
            },
            .tool_call => |tool_call| if (containsToolCallId(live_tool_ids, tool_call.id)) continue,
        }
    }

    return model;
}

fn createAssistantMessageRow(
    allocator: std.mem.Allocator,
    assistant: agent_protocol.AssistantMessage,
    live_tool_ids: []const []const u8,
    theme: *const Theme,
    hide_thinking_block: bool,
    hidden_thinking_label: []const u8,
) !TranscriptItem {
    var model = try buildAssistantRowModel(allocator, assistant, live_tool_ids);
    errdefer model.deinit(allocator);
    if (model.blocks.items.len == 0) return error.EmptyAssistantMessage;

    const am = try allocator.create(assistant_message_component_mod.AssistantMessage);
    errdefer allocator.destroy(am);
    am.* = assistant_message_component_mod.AssistantMessage.init(allocator);
    errdefer am.deinit();
    am.theme = theme;
    am.hide_thinking_block = hide_thinking_block;
    am.hidden_thinking_label = hidden_thinking_label;
    try am.setOwnedModel(&model);
    return .{
        .renderable = TranscriptRenderable.init(assistant_message_component_mod.AssistantMessage, am),
        .kind = .assistant_message,
        .deinit_ctx = @ptrCast(am),
        .deinit_fn = deinitAssistantMessageRow,
    };
}

pub fn buildUserRowModel(
    allocator: std.mem.Allocator,
    text: []const u8,
    meta: user_message_component_mod.MetaLine,
    status: user_message_component_mod.Status,
) !user_message_component_mod.UserRowModel {
    return .{
        .text = try allocator.dupe(u8, text),
        .meta = try meta.clone(allocator),
        .status = status,
    };
}

pub fn createUserMessageRow(
    allocator: std.mem.Allocator,
    model: *user_message_component_mod.UserRowModel,
    kind: transcript_mod.ItemKind,
    theme: *const Theme,
) !TranscriptItem {
    const msg = try allocator.create(user_message_component_mod.UserMessage);
    errdefer allocator.destroy(msg);
    msg.* = user_message_component_mod.UserMessage.init(allocator);
    errdefer msg.deinit();
    msg.setTheme(theme);
    msg.setOwnedModel(model);
    return .{
        .renderable = TranscriptRenderable.init(user_message_component_mod.UserMessage, msg),
        .kind = kind,
        .deinit_ctx = @ptrCast(msg),
        .deinit_fn = deinitUserMessageRow,
    };
}

fn createToolExecutionRow(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool_execution: *conversation_state_mod.ToolExecution,
    theme: *const Theme,
) !TranscriptItem {
    var model = try buildToolExecutionRowModel(
        allocator,
        tool_execution.tool_call_id,
        tool_execution.tool_name,
        tool_execution.args,
        tool_execution.args_json_source,
        tool_execution.args_complete,
        tool_execution.execution_started,
        tool_execution.result,
        tool_execution.rendered_call,
        tool_execution.rendered_result,
        null,
        tool_execution.is_partial,
        tool_execution.is_error,
    );
    defer model.deinit(allocator);
    const row = try createToolExecutionRowParts(allocator, resolver, &model, theme);
    tool_execution.rendered_call = null;
    tool_execution.rendered_result = null;
    return row;
}

fn buildToolExecutionRowModel(
    allocator: std.mem.Allocator,
    tool_call_id_src: []const u8,
    tool_name_src: []const u8,
    args: std.json.Value,
    args_json_source: ?[]const u8,
    args_complete: bool,
    execution_started: bool,
    result: ?AgentToolResult,
    rendered_call: ?*rendered_tool_result_view.RenderedToolResult,
    rendered_result: ?*rendered_tool_result_view.RenderedToolResult,
    result_message: ?agent_protocol.ToolResultMessage,
    is_partial: bool,
    is_error: bool,
) !transcript_mod.ToolExecutionRowModel {
    var model: transcript_mod.ToolExecutionRowModel = .{};
    errdefer model.deinit(allocator);

    model.tool_call_id = try allocator.dupe(u8, tool_call_id_src);
    model.tool_name = try allocator.dupe(u8, tool_name_src);
    model.args = try json_util.cloneJsonValue(allocator, args);
    model.args_json_source = if (!args_complete)
        if (args_json_source) |source| try allocator.dupe(u8, source) else null
    else
        null;
    model.args_complete = args_complete;
    model.execution_started = execution_started;
    model.is_partial = is_partial;
    model.is_error = is_error;

    if (result_message) |message| {
        model.result = try toolResultMessageAsAgentToolResult(allocator, message);
        model.is_partial = false;
        model.is_error = message.is_error;
    } else if (result) |value| {
        model.result = try value.clone(allocator);
    }
    model.rendered_call = rendered_call;
    if (model.result) |*owned| owned.is_error = model.is_error;
    if (model.result != null) model.rendered_result = rendered_result;
    return model;
}

fn createToolExecutionRowParts(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    model: *transcript_mod.ToolExecutionRowModel,
    theme: *const Theme,
) !TranscriptItem {
    const renderer = resolver.resolve(model.tool_name orelse return error.InvalidToolExecutionRowModel);
    const te = try allocator.create(transcript_mod.ToolExecution);
    errdefer allocator.destroy(te);
    te.* = .{
        .allocator = allocator,
        .theme = theme,
        .renderer = renderer,
    };
    errdefer te.deinit();
    if (renderer.init_state) |init_fn| te.renderer_state = init_fn(allocator);
    try te.setOwnedModel(model);
    return .{
        .renderable = TranscriptRenderable.init(transcript_mod.ToolExecution, te),
        .kind = .tool_execution,
        .tool_call_id = te.model.tool_call_id.?,
        .deinit_ctx = @ptrCast(te),
        .deinit_fn = deinitToolExecutionRow,
    };
}

fn toolResultMessageAsAgentToolResult(
    allocator: std.mem.Allocator,
    tool_result: agent_protocol.ToolResultMessage,
) !AgentToolResult {
    const blocks = try allocator.alloc(AgentToolResult.ContentBlock, tool_result.content.len);
    var initialized: usize = 0;
    errdefer {
        for (blocks[0..initialized]) |block| switch (block) {
            .text => |text| {
                allocator.free(text.text);
                if (text.text_signature) |signature| allocator.free(signature);
            },
            .image => |image| {
                allocator.free(image.data);
                allocator.free(image.mime_type);
            },
        };
        allocator.free(blocks);
    }

    for (tool_result.content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |text| .{ .text = .{
                .text = try allocator.dupe(u8, text.text),
                .text_signature = if (text.text_signature) |signature| try allocator.dupe(u8, signature) else null,
            } },
            .image => |image| .{ .image = .{
                .data = try allocator.dupe(u8, image.data),
                .mime_type = try allocator.dupe(u8, image.mime_type),
            } },
        };
        initialized += 1;
    }

    return .{
        .content = blocks,
        .details = if (tool_result.details) |details| try json_util.cloneJsonValue(allocator, details) else .null,
        .presentation = if (tool_result.presentation) |presentation| try json_util.cloneJsonValue(allocator, presentation) else .null,
        .is_error = tool_result.is_error,
    };
}

fn committedMessageSemanticVersion(message: agent_protocol.AgentMessage) transcript_mod.SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x434f_4d4d_56455231);
    hasher.update("committed_message_semantic");
    hashAgentMessage(&hasher, message);
    return hasher.final();
}

fn activeAssistantId(message: agent_protocol.AssistantMessage) transcript_mod.ItemId {
    var hasher = std.hash.Wyhash.init(0x41435449_56454944);
    hasher.update("active_assistant");
    std.hash.autoHash(&hasher, message.timestamp);
    return @enumFromInt(hasher.final());
}

fn activeAssistantSemanticVersion(message: agent_protocol.AssistantMessage) transcript_mod.SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x41435449_56455652);
    hasher.update("active_assistant_semantic");
    hashAssistantMessage(&hasher, message);
    return hasher.final();
}

fn committedMessageId(index: usize, message: agent_protocol.AgentMessage) transcript_mod.ItemId {
    var hasher = std.hash.Wyhash.init(0x434f_4e56_534e_4150);
    hasher.update("committed_message");
    std.hash.autoHash(&hasher, index);
    std.hash.autoHash(&hasher, messageTagCode(message));
    std.hash.autoHash(&hasher, messageTimestamp(message));
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageId(kind: QueuedUserMessageKind, ordinal: usize) transcript_mod.ItemId {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4549_4401);
    hasher.update("queued_user_message");
    std.hash.autoHash(&hasher, @intFromEnum(kind));
    std.hash.autoHash(&hasher, ordinal);
    return @enumFromInt(hasher.final());
}

fn queuedUserMessageSemanticVersion(text: []const u8) transcript_mod.SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x5155_4555_4556_4552);
    hasher.update(text);
    return hasher.final();
}

fn toolExecutionId(tool_call_id: []const u8) transcript_mod.ItemId {
    var hasher = std.hash.Wyhash.init(0x544f4f4c_45584944);
    hasher.update("tool_execution");
    hasher.update(tool_call_id);
    return @enumFromInt(hasher.final());
}

fn committedToolCallSemanticVersion(
    tool_call: agent_protocol.ToolCall,
    assistant: agent_protocol.AssistantMessage,
    result_message: ?agent_protocol.ToolResultMessage,
    retry_attempt: u32,
) transcript_mod.SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x544f4f4c_43565352);
    hasher.update("committed_tool_call_semantic");
    hasher.update(tool_call.id);
    hasher.update(tool_call.name);
    hashJsonValue(&hasher, tool_call.arguments);
    std.hash.autoHash(&hasher, retry_attempt);
    if (result_message) |message| {
        std.hash.autoHash(&hasher, true);
        std.hash.autoHash(&hasher, message.is_error);
        for (message.content) |block| hashToolResultContentBlock(&hasher, block);
        if (message.details) |details| hashJsonValue(&hasher, details) else hashJsonValue(&hasher, .null);
    } else {
        std.hash.autoHash(&hasher, false);
        std.hash.autoHash(&hasher, assistant.stop_reason);
        if (assistant.error_message) |message| {
            std.hash.autoHash(&hasher, true);
            hasher.update(message);
        } else {
            std.hash.autoHash(&hasher, false);
        }
    }
    return hasher.final();
}

fn toolExecutionSemanticVersion(tool: conversation_state_mod.ToolExecution) transcript_mod.SemanticVersion {
    var hasher = std.hash.Wyhash.init(0x544f4f4c_45585652);
    hasher.update("tool_execution_semantic");
    hasher.update(tool.tool_call_id);
    hasher.update(tool.tool_name);
    hashJsonValue(&hasher, tool.args);
    if (tool.args_json_source) |source| {
        std.hash.autoHash(&hasher, true);
        hasher.update(source);
    } else {
        std.hash.autoHash(&hasher, false);
    }
    std.hash.autoHash(&hasher, tool.args_complete);
    std.hash.autoHash(&hasher, tool.execution_started);
    std.hash.autoHash(&hasher, tool.result_message != null);
    if (tool.result_message) |result_message| {
        std.hash.autoHash(&hasher, result_message.is_error);
        std.hash.autoHash(&hasher, false);
        for (result_message.content) |block| hashToolResultContentBlock(&hasher, block);
        if (result_message.details) |details| hashJsonValue(&hasher, details) else hashJsonValue(&hasher, .null);
    } else {
        std.hash.autoHash(&hasher, tool.is_error);
        std.hash.autoHash(&hasher, tool.is_partial);
        if (tool.result) |result| {
            std.hash.autoHash(&hasher, true);
            hashAgentToolResult(&hasher, result);
        } else {
            std.hash.autoHash(&hasher, false);
        }
    }
    return hasher.final();
}

fn messageTagCode(message: agent_protocol.AgentMessage) u8 {
    return switch (message) {
        .user => 1,
        .assistant => 2,
        .tool_result => 3,
        .compaction_summary => 4,
        .branch_summary => 5,
        .custom => 6,
    };
}

fn messageTimestamp(message: agent_protocol.AgentMessage) i64 {
    return switch (message) {
        .user => |user| user.timestamp,
        .assistant => |assistant| assistant.timestamp,
        .tool_result => |tool_result| tool_result.timestamp,
        .compaction_summary => |summary| summary.timestamp,
        .branch_summary => |summary| summary.timestamp,
        .custom => |custom| custom.timestamp,
    };
}

fn hashAgentMessage(hasher: *std.hash.Wyhash, message: agent_protocol.AgentMessage) void {
    std.hash.autoHash(hasher, messageTagCode(message));
    std.hash.autoHash(hasher, messageTimestamp(message));
    switch (message) {
        .user => |user| hashUserContent(hasher, user.content),
        .assistant => |assistant| hashAssistantMessage(hasher, assistant),
        .tool_result => |tool_result| {
            hasher.update(tool_result.tool_call_id);
            hasher.update(tool_result.tool_name);
            std.hash.autoHash(hasher, tool_result.is_error);
            for (tool_result.content) |block| hashToolResultContentBlock(hasher, block);
            if (tool_result.details) |details| hashJsonValue(hasher, details) else hashJsonValue(hasher, .null);
            if (tool_result.presentation) |presentation| hashJsonValue(hasher, presentation) else hashJsonValue(hasher, .null);
        },
        .compaction_summary => |summary| {
            hasher.update(summary.summary);
            std.hash.autoHash(hasher, summary.tokens_before);
        },
        .branch_summary => |summary| {
            hasher.update(summary.summary);
            hasher.update(summary.from_id);
        },
        .custom => |custom| {
            hasher.update(custom.custom_type);
            std.hash.autoHash(hasher, custom.display);
            hashCustomContent(hasher, custom.content);
            if (custom.details) |details| hashJsonValue(hasher, details) else hashJsonValue(hasher, .null);
        },
    }
}

fn hashAssistantMessage(hasher: *std.hash.Wyhash, assistant: agent_protocol.AssistantMessage) void {
    std.hash.autoHash(hasher, @intFromEnum(assistant.api));
    std.hash.autoHash(hasher, @intFromEnum(assistant.provider));
    hasher.update(assistant.model);
    std.hash.autoHash(hasher, assistant.timestamp);
    std.hash.autoHash(hasher, @intFromEnum(assistant.stop_reason));
    if (assistant.error_message) |msg| {
        std.hash.autoHash(hasher, true);
        hasher.update(msg);
    } else {
        std.hash.autoHash(hasher, false);
    }
    for (assistant.content) |block| switch (block) {
        .text => |text| hasher.update(text.text),
        .thinking => |thinking| {
            hasher.update(thinking.thinking);
            if (thinking.thinking_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
            std.hash.autoHash(hasher, thinking.redacted != null);
            if (thinking.redacted) |redacted| std.hash.autoHash(hasher, redacted);
        },
        .tool_call => |tool_call| {
            hasher.update(tool_call.id);
            hasher.update(tool_call.name);
            hashJsonValue(hasher, tool_call.arguments);
        },
    };
}

fn hashUserContent(hasher: *std.hash.Wyhash, content: ai_protocol.UserMessage.UserMessageContent) void {
    switch (content) {
        .text => |text| hasher.update(text),
        .blocks => |blocks| for (blocks) |block| switch (block) {
            .text => |text| hasher.update(text.text),
            .image => |image| {
                hasher.update(image.mime_type);
                hasher.update(image.data);
            },
        },
    }
}

fn hashCustomContent(hasher: *std.hash.Wyhash, content: agent_protocol.AgentMessage.CustomContent) void {
    switch (content) {
        .text => |text| hasher.update(text),
        .blocks => |blocks| for (blocks) |block| switch (block) {
            .text => |text| hasher.update(text.text),
            .image => |image| {
                hasher.update(image.mime_type);
                hasher.update(image.data);
            },
        },
    }
}

fn hashAgentToolResult(hasher: *std.hash.Wyhash, result: AgentToolResult) void {
    std.hash.autoHash(hasher, result.is_error);
    for (result.content) |block| hashAgentToolResultContentBlock(hasher, block);
    hashJsonValue(hasher, result.details);
    hashJsonValue(hasher, result.presentation);
}

fn hashAgentToolResultContentBlock(hasher: *std.hash.Wyhash, block: AgentToolResult.ContentBlock) void {
    switch (block) {
        .text => |text| {
            hasher.update(text.text);
            if (text.text_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
        },
        .image => |image| {
            hasher.update(image.mime_type);
            hasher.update(image.data);
        },
    }
}

fn hashToolResultContentBlock(hasher: *std.hash.Wyhash, block: agent_protocol.ToolResultMessage.ContentBlock) void {
    switch (block) {
        .text => |text| {
            hasher.update(text.text);
            if (text.text_signature) |sig| {
                std.hash.autoHash(hasher, true);
                hasher.update(sig);
            } else {
                std.hash.autoHash(hasher, false);
            }
        },
        .image => |image| {
            hasher.update(image.mime_type);
            hasher.update(image.data);
        },
    }
}

fn hashJsonValue(hasher: *std.hash.Wyhash, value: std.json.Value) void {
    switch (value) {
        .null => std.hash.autoHash(hasher, @as(u8, 0)),
        .bool => |bool_value| {
            std.hash.autoHash(hasher, @as(u8, 1));
            std.hash.autoHash(hasher, bool_value);
        },
        .integer => |integer| {
            std.hash.autoHash(hasher, @as(u8, 2));
            std.hash.autoHash(hasher, integer);
        },
        .float => |float_value| {
            std.hash.autoHash(hasher, @as(u8, 3));
            hasher.update(std.mem.asBytes(&float_value));
        },
        .number_string => |number_string| {
            std.hash.autoHash(hasher, @as(u8, 4));
            hasher.update(number_string);
        },
        .string => |string| {
            std.hash.autoHash(hasher, @as(u8, 5));
            hasher.update(string);
        },
        .array => |array| {
            std.hash.autoHash(hasher, @as(u8, 6));
            for (array.items) |entry| hashJsonValue(hasher, entry);
        },
        .object => |object| {
            std.hash.autoHash(hasher, @as(u8, 7));
            var it = object.iterator();
            while (it.next()) |entry| {
                hasher.update(entry.key_ptr.*);
                hashJsonValue(hasher, entry.value_ptr.*);
            }
        },
    }
}

fn createMarkdownRow(
    allocator: std.mem.Allocator,
    theme: *const Theme,
    content: []const u8,
    fg: Color,
    bg: Color,
) !TranscriptItem {
    const md = try allocator.create(Markdown);
    errdefer allocator.destroy(md);
    md.* = Markdown.init(allocator);
    errdefer md.deinit();
    md.theme = theme;
    md.padding_x = 1;
    md.padding_y = if (bg.eql(Color.default)) 0 else 1;
    md.fg = fg;
    md.bg = bg;
    md.setContent(content);
    return .{
        .renderable = TranscriptRenderable.init(Markdown, md),
        .deinit_ctx = @ptrCast(md),
        .deinit_fn = deinitMarkdown,
    };
}

fn deinitAssistantMessageRow(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const am: *assistant_message_component_mod.AssistantMessage = @ptrCast(@alignCast(ctx));
    am.deinit();
    allocator.destroy(am);
}

fn deinitUserMessageRow(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const msg: *user_message_component_mod.UserMessage = @ptrCast(@alignCast(ctx));
    msg.deinit();
    allocator.destroy(msg);
}

fn deinitToolExecutionRow(ctx: *anyopaque, _: std.mem.Allocator) void {
    const te: *transcript_mod.ToolExecution = @ptrCast(@alignCast(ctx));
    te.deinit();
}

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

fn customContentText(
    allocator: std.mem.Allocator,
    content: agent_protocol.AgentMessage.CustomContent,
) ![]u8 {
    switch (content) {
        .text => |text| return allocator.dupe(u8, text),
        .blocks => |blocks| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            for (blocks, 0..) |block, idx| {
                if (idx > 0) try out.append(allocator, '\n');
                switch (block) {
                    .text => |text| try out.appendSlice(allocator, text.text),
                    .image => |image| try out.print(allocator, "[image: {s}]", .{image.mime_type}),
                }
            }
            return out.toOwnedSlice(allocator);
        },
    }
}

fn joinUserBlocksText(
    allocator: std.mem.Allocator,
    blocks: []const ai_protocol.UserMessage.UserMessageContent.Block,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var image_index: usize = 0;
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            .image => {
                image_index += 1;
                if (out.items.len > 0 and !std.ascii.isWhitespace(out.items[out.items.len - 1])) {
                    try out.append(allocator, ' ');
                }
                try out.print(allocator, "[image{d}]", .{image_index});
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

fn renderTranscriptText(allocator: std.mem.Allocator, transcript: *Transcript, width: u32) ![]u8 {
    const height = @max(@as(u32, 1), transcript.totalHeight(width));
    var buf = try Buffer.init(allocator, width, height);
    defer buf.deinit();
    transcript.render(buf.region());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try out.append(allocator, '\n');
        var end = width;
        while (end > 0 and buf.get(end - 1, row).grapheme.codepoint == ' ') : (end -= 1) {}
        var col: u32 = 0;
        while (col < end) : (col += 1) {
            var utf8_buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(buf.get(col, row).grapheme.codepoint, &utf8_buf) catch continue;
            try out.appendSlice(allocator, utf8_buf[0..len]);
        }
    }

    return out.toOwnedSlice(allocator);
}

fn makeUserMessage(text: []const u8) agent_protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = 1,
    } };
}

fn makeUserBlocksMessage(blocks: []const ai_protocol.UserMessage.UserMessageContent.Block) agent_protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .blocks = blocks },
        .timestamp = 1,
    } };
}

fn makeAssistantMessage(
    content: []const agent_protocol.AssistantMessage.AssistantContentBlock,
    stop_reason: agent_protocol.StopReason,
    error_message: ?[]const u8,
) agent_protocol.AgentMessage {
    return .{ .assistant = .{
        .content = content,
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "claude-test",
        .usage = .{
            .input = 1,
            .output = 1,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 2,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 1,
    } };
}

fn makeToolResultMessage(
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const agent_protocol.ToolResultMessage.ContentBlock,
    is_error: bool,
) agent_protocol.AgentMessage {
    return .{ .tool_result = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .is_error = is_error,
        .timestamp = 1,
    } };
}

fn dupQueuedEntries(allocator: std.mem.Allocator, texts: []const []const u8) ![]control_mod.QueuedMessageText {
    const entries = try allocator.alloc(control_mod.QueuedMessageText, texts.len);
    errdefer allocator.free(entries);
    for (texts, 0..) |text, i| {
        entries[i].text = try allocator.dupe(u8, text);
        errdefer allocator.free(entries[i].text);
    }
    return entries;
}

test "rebuildFromSnapshots reconstructs tool call rows and tool results from committed messages" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const tool_call = agent_protocol.ToolCall{ .id = "tc-1", .name = "bash", .arguments = .null };
    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "running bash" } },
        .{ .tool_call = tool_call },
    };
    const tool_result_content = [_]agent_protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeUserMessage("do it"),
        makeAssistantMessage(&assistant_content, .toolUse, null),
        makeToolResultMessage("tc-1", "bash", &tool_result_content, false),
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{ .theme = themes_builtin.dark() },
    );

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("do it", editor.history.items[0]);
    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);
    try testing.expectEqual(@as(usize, 0), transcript.pending_tools.count());

    const tool_item = transcript.items.items[2];
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(tool_item.deinit_ctx.?));
    try testing.expect(tool.model.args_complete);
    try testing.expect(!tool.model.is_partial);
    try testing.expect(!tool.model.is_error);
    try testing.expect(tool.model.result != null);
    try testing.expectEqualStrings("done", tool.model.result.?.content[0].text.text);
}

test "rebuildFromSnapshots preserves assistant text thinking and tool call ordering" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "alpha" } },
        .{ .thinking = .{ .thinking = "ponder" } },
        .{ .tool_call = .{ .id = "tc-1", .name = "read", .arguments = .null } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .toolUse, null),
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);

    const alpha_idx = std.mem.indexOf(u8, rendered, "alpha") orelse return error.MissingAssistantText;
    const ponder_idx = std.mem.indexOf(u8, rendered, "ponder") orelse return error.MissingThinkingText;
    const tool_idx = std.mem.indexOf(u8, rendered, "read") orelse return error.MissingToolRow;
    try testing.expect(alpha_idx < ponder_idx);
    try testing.expect(ponder_idx < tool_idx);
}

test "rebuildFromSnapshots respects hidden thinking labels for committed assistant rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();
    transcript.hide_thinking_block = true;

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "alpha" } },
        .{ .thinking = .{ .thinking = "ponder" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .stop, null),
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Thinking...") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "ponder") == null);
}

test "rebuildFromSnapshots renders failed tool rows for aborted assistant" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .tool_call = .{ .id = "tc-1", .name = "bash", .arguments = .null } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .aborted, null),
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{
            .theme = themes_builtin.dark(),
            .retry_attempt = 0,
        },
    );

    try testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(transcript.items.items[0].deinit_ctx.?));
    try testing.expect(tool.model.args_complete);
    try testing.expect(tool.model.is_error);
    try testing.expect(!tool.model.is_partial);
    try testing.expect(tool.model.result != null);
    try testing.expectEqualStrings("Operation aborted", tool.model.result.?.content[0].text.text);
}

test "rebuildFromSnapshots includes summaries displayable custom messages and editor history" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const user_blocks = [_]ai_protocol.UserMessage.UserMessageContent.Block{
        .{ .text = .{ .text = "hello" } },
        .{ .image = .{ .data = "abc", .mime_type = "image/png" } },
        .{ .text = .{ .text = " world" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeUserBlocksMessage(&user_blocks),
        .{ .compaction_summary = .{ .summary = "kept the recent turns", .tokens_before = 42, .timestamp = 1 } },
        .{ .branch_summary = .{ .summary = "previous branch summary", .from_id = "branch-1", .timestamp = 1 } },
        .{ .custom = .{
            .custom_type = "demo",
            .content = .{ .text = "shown custom" },
            .display = true,
            .timestamp = 1,
        } },
        .{ .custom = .{
            .custom_type = "hidden",
            .content = .{ .text = "do not show" },
            .display = false,
            .timestamp = 1,
        } },
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{ .theme = themes_builtin.dark() },
    );

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("hello [image1] world", editor.history.items[0]);
    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "hello [image1] world") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "kept the recent turns") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "previous branch summary") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "shown custom") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "do not show") == null);
}

test "rebuildFromSnapshots reconstructs committed messages and queued rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const messages = [_]agent_protocol.AgentMessage{
        makeUserMessage("hello"),
        .{ .compaction_summary = .{ .summary = "kept the recent turns", .tokens_before = 42, .timestamp = 2 } },
    };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &messages);
    defer state.deinit(testing.allocator);

    var queued: control_mod.QueuedMessageSnapshot = .{
        .steering = try dupQueuedEntries(testing.allocator, &.{"steer me"}),
        .follow_up = try dupQueuedEntries(testing.allocator, &.{"follow me"}),
    };
    defer queued.deinit(testing.allocator);

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        queued,
        .{ .theme = themes_builtin.dark() },
    );

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("hello", editor.history.items[0]);

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "hello") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "kept the recent turns") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Queued · Steering") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "steer me") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Queued · Follow-up") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "follow me") != null);
}

test "rebuildFromSnapshots reconstructs active assistant and live tool execution rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "working" } },
        .{ .tool_call = .{ .id = "tc-1", .name = "bash", .arguments = .null } },
    };
    const assistant = makeAssistantMessage(&assistant_content, .toolUse, null);
    const partial_blocks = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = "partial output" } },
    };
    const partial_result = AgentToolResult{ .content = &partial_blocks, .is_error = false };

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &.{makeUserMessage("hello")});
    defer state.deinit(testing.allocator);
    const live_tools = try testing.allocator.alloc(conversation_state_mod.ToolExecution, 1);
    live_tools[0] = .{
        .tool_call_id = try testing.allocator.dupe(u8, "tc-1"),
        .tool_name = try testing.allocator.dupe(u8, "bash"),
        .args = .null,
        .args_complete = true,
        .execution_started = true,
        .result = try partial_result.clone(testing.allocator),
        .is_error = false,
        .is_partial = true,
    };
    state.view.in_flight = .{
        .locator = .{ .assistant_timestamp = assistant.assistant.timestamp },
        .assistant = try message_memory.cloneAssistantMessage(testing.allocator, assistant.assistant),
        .tool_executions = live_tools,
    };

    rebuildFromSnapshots(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        state,
        null,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "working") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "partial output") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, rendered, "tc-1 tc-1"));
}

test "reconcileFromSnapshots retains unchanged rows and appends editor history once" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var state = try ownedViewSnapshotFromMessages(testing.allocator, &.{makeUserMessage("hello")});
    defer state.deinit(testing.allocator);

    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state, null, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const first_ptr = transcript.items.items[0].deinit_ctx;
    try testing.expectEqual(@as(u32, 1), mock_editor.history_count);

    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state, null, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(first_ptr, transcript.items.items[0].deinit_ctx);
    try testing.expectEqual(@as(u32, 1), mock_editor.history_count);
}

test "reconcileFromSnapshots replaces only changed semantic rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var state_a = try ownedViewSnapshotFromMessages(testing.allocator, &.{ makeUserMessage("one"), makeUserMessage("two") });
    defer state_a.deinit(testing.allocator);
    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state_a, null, .{ .theme = themes_builtin.dark() });

    const first_ptr = transcript.items.items[0].deinit_ctx;
    const second_ptr = transcript.items.items[1].deinit_ctx;

    var state_b = try ownedViewSnapshotFromMessages(testing.allocator, &.{ makeUserMessage("one"), makeUserMessage("two updated") });
    defer state_b.deinit(testing.allocator);
    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state_b, null, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(first_ptr, transcript.items.items[0].deinit_ctx);
    try testing.expect(second_ptr != transcript.items.items[1].deinit_ctx);
}

test "reconcileFromSnapshots reorders rows and preserves scroll offset when not following bottom" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var state_a = try ownedViewSnapshotFromMessages(testing.allocator, &.{ makeUserMessage("one"), makeUserMessage("two"), makeUserMessage("three") });
    defer state_a.deinit(testing.allocator);
    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state_a, null, .{ .theme = themes_builtin.dark() });
    _ = transcript.totalHeight(40);
    transcript.scrollBy(40, 2, -1);
    const scroll_before = transcript.scrollOffset();

    var state_b = try ownedViewSnapshotFromMessages(testing.allocator, &.{ makeUserMessage("three"), makeUserMessage("one"), makeUserMessage("two") });
    defer state_b.deinit(testing.allocator);
    reconcileFromSnapshots(&transcript, editor, tool_display_mod.empty_resolver, state_b, null, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(scroll_before, transcript.scrollOffset());
}

test "replaceAllOwnedState clears and reseeds editor history when committed user history changes" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var view_a = try ownedViewSnapshotFromMessages(testing.allocator, &.{makeUserMessage("old")});
    var queued_a = try emptyQueuedSnapshot(testing.allocator);
    projection.replaceAllOwnedState(&transcript, editor, tool_display_mod.empty_resolver, &view_a, &queued_a, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u32, 1), mock_editor.history_count);
    try testing.expectEqual(@as(u32, 0), mock_editor.clear_history_count);

    var view_b = try ownedViewSnapshotFromMessages(testing.allocator, &.{makeUserMessage("new")});
    var queued_b = try emptyQueuedSnapshot(testing.allocator);
    projection.replaceAllOwnedState(&transcript, editor, tool_display_mod.empty_resolver, &view_b, &queued_b, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(@as(u32, 2), mock_editor.history_count);
    try testing.expectEqual(@as(u32, 1), mock_editor.clear_history_count);
}

test "replaceAllOwnedState preserves editor history on append-only user history" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var view_a = try ownedViewSnapshotFromMessages(testing.allocator, &.{makeUserMessage("one")});
    var queued_a = try emptyQueuedSnapshot(testing.allocator);
    projection.replaceAllOwnedState(&transcript, editor, tool_display_mod.empty_resolver, &view_a, &queued_a, .{ .theme = themes_builtin.dark() });

    var view_b = try ownedViewSnapshotFromMessages(testing.allocator, &.{ makeUserMessage("one"), makeUserMessage("two") });
    var queued_b = try emptyQueuedSnapshot(testing.allocator);
    projection.replaceAllOwnedState(&transcript, editor, tool_display_mod.empty_resolver, &view_b, &queued_b, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(@as(u32, 2), mock_editor.history_count);
    try testing.expectEqual(@as(u32, 0), mock_editor.clear_history_count);
}

test "replaceViewSnapshot converges frontier commit into committed history" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    const user_message = makeUserMessage("hello");
    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "working" } },
    };
    const assistant_message = makeAssistantMessage(&assistant_content, .stop, null);
    const locator: conversation_state_mod.FrontierLocator = .{ .assistant_timestamp = assistant_message.assistant.timestamp };

    var frontier_view = try ownedViewSnapshotFromMessages(testing.allocator, &.{user_message});
    frontier_view.view.in_flight = .{
        .locator = locator,
        .assistant = try message_memory.cloneAssistantMessage(testing.allocator, assistant_message.assistant),
        .tool_executions = try testing.allocator.alloc(conversation_state_mod.ToolExecution, 0),
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &frontier_view, .{ .theme = themes_builtin.dark() });

    var committed_view = try ownedViewSnapshotFromMessages(testing.allocator, &.{ user_message, .{ .assistant = assistant_message.assistant } });
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &committed_view, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    try testing.expect(projection.view_snapshot.?.view.in_flight == null);
    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "working") != null);
}

test "replaceViewSnapshot rejects stale snapshots by generation and version" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    const shared = try conversation_state_mod.SharedCommitted.fromMessages(testing.allocator, &.{});
    errdefer shared.release();

    var fresh = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 1,
        .conversation_version = 1,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &fresh, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.conversation_version);

    var stale_version = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 1,
        .conversation_version = 0,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &stale_version, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.conversation_version);

    var stale_gen = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 0,
        .conversation_version = 5,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &stale_gen, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.conversation_version);

    var newer_gen = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 2,
        .conversation_version = 0,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &newer_gen, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 2), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 0), projection.view_snapshot.?.conversation_version);

    shared.release();
}

test "replaceViewSnapshot converges after dropped intermediate snapshot because final snapshot is authoritative" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    const shared = try conversation_state_mod.SharedCommitted.fromMessages(testing.allocator, &.{});
    errdefer shared.release();

    var initial = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 1,
        .conversation_version = 1,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &initial, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.conversation_version);

    var final = conversation_state_mod.ConversationSnapshotEnvelope{
        .session_generation = 1,
        .conversation_version = 3,
        .view = .{ .committed = shared.retain(), .in_flight = null },
    };
    projection.replaceViewSnapshot(&transcript, editor, tool_display_mod.empty_resolver, &final, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(u64, 1), projection.view_snapshot.?.session_generation);
    try testing.expectEqual(@as(u64, 3), projection.view_snapshot.?.conversation_version);

    shared.release();
}
