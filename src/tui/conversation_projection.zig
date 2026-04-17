const std = @import("std");
const ai_protocol = @import("../ai/protocol.zig");
const agent_root = @import("../agent/root.zig");
const agent_protocol = agent_root.protocol;
const conversation_mod = agent_root.conversation;
const message_memory = agent_root.message_memory;
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
const conversation_snapshot_mod = @import("../conversation_snapshot.zig");
const run_control_mod = @import("../runtime/run_control.zig");

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
};

const DesiredItem = struct {
    item_id: conversation_snapshot_mod.ItemId,
    semantic_version: conversation_snapshot_mod.SemanticVersion,
    row: TranscriptItem,
    seed_editor_history: bool = false,
    history_text: ?ExtractedText = null,

    fn deinit(self: *DesiredItem, allocator: std.mem.Allocator) void {
        if (self.history_text) |text| text.deinit(allocator);
        self.row.deinit(allocator);
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

pub fn rebuildFromMessages(
    transcript: *Transcript,
    editor: EditorInterface,
    resolver: ToolRendererResolver,
    messages: []const agent_protocol.AgentMessage,
    options: RebuildOptions,
) void {
    transcript.clearAll();
    editor.clearHistory();

    for (messages) |message| {
        seedHistoryFromMessage(editor, message);
        appendProjectedMessage(transcript, resolver, message, options);
    }

    transcript.clearPendingToolRouting();
}

pub const ProjectionState = struct {
    allocator: std.mem.Allocator,
    snapshot: ?conversation_mod.ConversationSnapshot = null,
    frontier_item_start: usize = 0,

    pub fn init(allocator: std.mem.Allocator) ProjectionState {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ProjectionState) void {
        self.clear();
    }

    pub fn clear(self: *ProjectionState) void {
        if (self.snapshot) |*snapshot| {
            snapshot.deinit(self.allocator);
            self.snapshot = null;
        }
        self.frontier_item_start = 0;
    }

    pub fn replaceAllFromMessages(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        messages: []const agent_protocol.AgentMessage,
        options: RebuildOptions,
    ) void {
        const committed = message_memory.cloneMessages(self.allocator, messages) catch return;
        self.clear();
        self.snapshot = .{
            .committed = committed,
            .frontier = null,
        };
        self.rebuildTranscript(transcript, editor, resolver, options);
    }

    pub fn applyOwnedPatch(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        patch: *conversation_mod.ConversationPatch,
        options: RebuildOptions,
    ) bool {
        switch (patch.*) {
            .replace_all => |*snapshot| {
                self.replaceAllOwnedSnapshot(transcript, editor, resolver, snapshot, options);
                patch.* = .commit_frontier;
                return true;
            },
            .append_committed => |*message| {
                const owned_message = message.*;
                message.* = undefined;
                patch.* = .commit_frontier;
                return self.appendCommittedOwned(transcript, editor, resolver, owned_message, options);
            },
            .replace_frontier => |*frontier| {
                const owned_frontier = frontier.*;
                frontier.* = null;
                patch.* = .commit_frontier;
                return self.replaceFrontierOwned(transcript, resolver, owned_frontier);
            },
            .append_frontier_content => |append| {
                return self.appendFrontierContent(transcript, append.target, append.bytes);
            },
            .commit_frontier => {
                return self.commitFrontier(transcript);
            },
        }
    }

    fn replaceAllOwnedSnapshot(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        snapshot: *conversation_mod.ConversationSnapshot,
        options: RebuildOptions,
    ) void {
        const owned_snapshot = snapshot.*;
        snapshot.* = undefined;
        self.clear();
        self.snapshot = owned_snapshot;
        self.rebuildTranscript(transcript, editor, resolver, options);
    }

    fn appendCommittedOwned(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        message: agent_protocol.AgentMessage,
        options: RebuildOptions,
    ) bool {
        const snapshot = self.ensureSnapshot() orelse {
            var mutable = message;
            message_memory.freeMessage(self.allocator, &mutable);
            return false;
        };

        const grown = self.allocator.alloc(agent_protocol.AgentMessage, snapshot.committed.len + 1) catch {
            var mutable = message;
            message_memory.freeMessage(self.allocator, &mutable);
            return false;
        };
        @memcpy(grown[0..snapshot.committed.len], snapshot.committed);
        grown[snapshot.committed.len] = message;
        self.allocator.free(snapshot.committed);
        snapshot.committed = grown;

        seedHistoryFromMessage(editor, message);
        appendProjectedMessage(transcript, resolver, message, options);
        if (snapshot.frontier == null) {
            self.frontier_item_start = transcript.items.items.len;
        }
        return true;
    }

    fn replaceFrontierOwned(
        self: *ProjectionState,
        transcript: *Transcript,
        resolver: ToolRendererResolver,
        frontier: ?conversation_mod.ConversationFrontier,
    ) bool {
        var owned_frontier = frontier;
        const snapshot = self.ensureSnapshot() orelse {
            if (owned_frontier) |*owned| owned.deinit(self.allocator);
            return false;
        };
        if (snapshot.frontier) |*old| old.deinit(self.allocator);
        snapshot.frontier = owned_frontier;
        self.syncFrontierTail(transcript, resolver);
        return true;
    }

    fn appendFrontierContent(
        self: *ProjectionState,
        transcript: *Transcript,
        target: conversation_mod.FrontierAppendTarget,
        bytes: []const u8,
    ) bool {
        const snapshot = if (self.snapshot) |*snapshot| snapshot else return false;
        const frontier = if (snapshot.frontier) |*frontier| frontier else return false;
        switch (target) {
            .assistant_content => |assistant_target| {
                const assistant = if (frontier.assistant) |*assistant| assistant else return false;
                if (!appendAssistantBytes(self.allocator, assistant, assistant_target, bytes)) return false;
                if (self.frontier_item_start >= transcript.items.items.len) return false;
                return switch (assistant_target.kind) {
                    .text => transcript.appendAssistantTextAt(self.frontier_item_start, assistant_target.content_index, bytes),
                    .thinking => transcript.appendAssistantThinkingAt(self.frontier_item_start, assistant_target.content_index, bytes),
                };
            },
            .tool_call_arguments, .tool_result_content => return false,
        }
    }

    fn commitFrontier(self: *ProjectionState, transcript: *Transcript) bool {
        const snapshot = self.snapshot orelse return false;
        if (snapshot.frontier == null) return false;
        if (self.snapshot) |*owned| {
            if (owned.frontier) |*frontier| frontier.deinit(self.allocator);
            owned.frontier = null;
        }
        transcript.truncateFrom(self.frontier_item_start);
        self.frontier_item_start = transcript.items.items.len;
        return true;
    }

    fn ensureSnapshot(self: *ProjectionState) ?*conversation_mod.ConversationSnapshot {
        if (self.snapshot == null) {
            const committed = self.allocator.alloc(agent_protocol.AgentMessage, 0) catch return null;
            self.snapshot = .{
                .committed = committed,
                .frontier = null,
            };
        }
        return &self.snapshot.?;
    }

    fn rebuildTranscript(
        self: *ProjectionState,
        transcript: *Transcript,
        editor: EditorInterface,
        resolver: ToolRendererResolver,
        options: RebuildOptions,
    ) void {
        const snapshot = self.snapshot orelse {
            transcript.clearAll();
            editor.clearHistory();
            self.frontier_item_start = 0;
            return;
        };

        transcript.clearAll();
        editor.clearHistory();
        for (snapshot.committed) |message| {
            seedHistoryFromMessage(editor, message);
            appendProjectedMessage(transcript, resolver, message, options);
        }
        transcript.clearPendingToolRouting();
        self.frontier_item_start = transcript.items.items.len;
        self.syncFrontierTail(transcript, resolver);
    }

    fn syncFrontierTail(self: *ProjectionState, transcript: *Transcript, resolver: ToolRendererResolver) void {
        transcript.truncateFrom(self.frontier_item_start);
        const snapshot = self.snapshot orelse return;
        const frontier = snapshot.frontier orelse return;
        appendProjectedFrontierRows(transcript, resolver, frontier);
    }
};

fn appendProjectedFrontierRows(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    frontier: conversation_mod.ConversationFrontier,
) void {
    var live_tool_ids: std.ArrayList([]const u8) = .empty;
    defer live_tool_ids.deinit(transcript.allocator);
    for (frontier.live_tools) |tool| {
        live_tool_ids.append(transcript.allocator, tool.tool_call_id) catch return;
    }

    if (frontier.assistant) |assistant| {
        const row = createAssistantMessageRow(
            transcript.allocator,
            assistant,
            live_tool_ids.items,
            transcript.theme,
            transcript.hide_thinking_block,
        ) catch return;
        if (!transcript.addItem(row)) {
            var owned_row = row;
            owned_row.deinit(transcript.allocator);
            return;
        }
    }

    for (frontier.live_tools) |tool| {
        const row = createLiveToolExecutionRow(transcript.allocator, resolver, tool, transcript.theme) catch return;
        if (!transcript.addItem(row)) {
            var owned_row = row;
            owned_row.deinit(transcript.allocator);
            return;
        }
    }
}

pub fn rebuildFromSnapshot(
    transcript: *Transcript,
    editor: EditorInterface,
    resolver: ToolRendererResolver,
    snapshot: conversation_snapshot_mod.ConversationSnapshot,
    options: RebuildOptions,
) void {
    transcript.clearAll();
    editor.clearHistory();

    var desired_items = buildDesiredItems(transcript.allocator, resolver, snapshot, options, transcript.hide_thinking_block) catch return;
    defer {
        for (desired_items.items) |*item| item.deinit(transcript.allocator);
        desired_items.deinit(transcript.allocator);
    }

    for (desired_items.items, 0..) |desired, idx| {
        if (!transcript.addItem(desired.row)) return;
        disarmDesiredRow(&desired_items.items[idx]);
        if (desired.seed_editor_history) {
            if (desired.history_text) |history_text| editor.addToHistory(history_text.slice());
        }
    }

    transcript.clearPendingToolRouting();
}

pub fn reconcileFromSnapshot(
    transcript: *Transcript,
    editor: EditorInterface,
    resolver: ToolRendererResolver,
    snapshot: conversation_snapshot_mod.ConversationSnapshot,
    options: RebuildOptions,
) void {
    var desired_items = buildDesiredItems(transcript.allocator, resolver, snapshot, options, transcript.hide_thinking_block) catch return;
    defer {
        for (desired_items.items) |*item| item.deinit(transcript.allocator);
        desired_items.deinit(transcript.allocator);
    }

    var desired_index: usize = 0;
    while (desired_index < desired_items.items.len) : (desired_index += 1) {
        const desired = desired_items.items[desired_index];
        const existing_index = transcript.findSnapshotItemIndex(desired.item_id);
        if (existing_index) |current_index| {
            if (transcript.snapshotItemSemanticVersionAt(current_index) == desired.semantic_version) {
                if (current_index != desired_index) transcript.moveItem(current_index, desired_index);
            } else {
                _ = transcript.replaceItemAt(current_index, desired.row);
                disarmDesiredRow(&desired_items.items[desired_index]);
                if (current_index != desired_index) transcript.moveItem(current_index, desired_index);
            }
        } else {
            _ = transcript.insertItemAt(desired_index, desired.row);
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

fn buildDesiredItems(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    snapshot: conversation_snapshot_mod.ConversationSnapshot,
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
    for (snapshot.items) |item| {
        if (item != .tool_execution) continue;
        try live_tool_ids.append(allocator, item.tool_execution.tool_call_id);
    }

    for (snapshot.items) |item| {
        const desired = buildDesiredItem(allocator, resolver, item, options, live_tool_ids.items, hide_thinking_block) catch |err| switch (err) {
            error.SkipHiddenCustomMessage,
            error.EmptyCustomMessage,
            error.EmptyUserMessage,
            error.UnsupportedStandaloneToolResult,
            => continue,
            else => return err,
        };
        try desired_items.append(allocator, desired);
    }
    return desired_items;
}

fn buildDesiredItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    item: conversation_snapshot_mod.ConversationItem,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !DesiredItem {
    return switch (item) {
        .committed_message => |committed| try buildCommittedMessageItem(allocator, resolver, committed, options, live_tool_ids, hide_thinking_block),
        .active_assistant => |active| try buildActiveAssistantDesiredItem(allocator, active, live_tool_ids, options.theme, hide_thinking_block),
        .tool_execution => |tool_execution| try buildToolExecutionDesiredItem(allocator, resolver, tool_execution, options.theme),
        .queued_user_message => |queued| try buildQueuedUserDesiredItem(allocator, queued, options.theme),
    };
}

fn buildCommittedMessageItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    committed: conversation_snapshot_mod.CommittedMessageItem,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !DesiredItem {
    var row = try buildSnapshotMessageRow(allocator, resolver, committed.message, options, live_tool_ids, hide_thinking_block);
    row.snapshot_item_id = committed.item_id;
    row.snapshot_semantic_version = committed.semantic_version;

    const history_text = extractUserMessageText(allocator, committed.message);
    return .{
        .item_id = committed.item_id,
        .semantic_version = committed.semantic_version,
        .row = row,
        .seed_editor_history = history_text != null,
        .history_text = history_text,
    };
}

fn buildActiveAssistantDesiredItem(
    allocator: std.mem.Allocator,
    active: conversation_snapshot_mod.ActiveAssistantItem,
    live_tool_ids: []const []const u8,
    theme: *const Theme,
    hide_thinking_block: bool,
) !DesiredItem {
    var row = try createAssistantMessageRow(allocator, active.message.assistant, live_tool_ids, theme, hide_thinking_block);
    row.snapshot_item_id = active.item_id;
    row.snapshot_semantic_version = active.semantic_version;
    return .{ .item_id = active.item_id, .semantic_version = active.semantic_version, .row = row };
}

fn buildToolExecutionDesiredItem(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool_execution: conversation_snapshot_mod.ToolExecutionItem,
    theme: *const Theme,
) !DesiredItem {
    var row = try createToolExecutionRow(allocator, resolver, tool_execution, theme);
    row.snapshot_item_id = tool_execution.item_id;
    row.snapshot_semantic_version = tool_execution.semantic_version;
    return .{ .item_id = tool_execution.item_id, .semantic_version = tool_execution.semantic_version, .row = row };
}

fn buildQueuedUserDesiredItem(
    allocator: std.mem.Allocator,
    queued: conversation_snapshot_mod.QueuedUserMessageItem,
    theme: *const Theme,
) !DesiredItem {
    var row = try createUserMessageRow(allocator, .{
        .text = queued.text,
        .footer = switch (queued.kind) {
            .steering => .queued_steering,
            .follow_up => .queued_follow_up,
        },
    }, .queued_user_message, theme);
    row.snapshot_item_id = queued.item_id;
    row.snapshot_semantic_version = queued.semantic_version;
    return .{ .item_id = queued.item_id, .semantic_version = queued.semantic_version, .row = row };
}
fn disarmDesiredRow(item: *DesiredItem) void {
    item.row.deinit_ctx = null;
    item.row.deinit_fn = null;
}

fn appendAssistantBytes(
    allocator: std.mem.Allocator,
    assistant: *agent_protocol.AssistantMessage,
    target: conversation_mod.AssistantAppendTarget,
    bytes: []const u8,
) bool {
    const content = ensureAssistantContentBlock(allocator, assistant, target, bytes) orelse return false;
    if (content.preexisting) {
        switch (target.kind) {
            .text => {
                const old = content.block.text.text;
                const combined = appendBytesOwned(allocator, old, bytes) catch return false;
                allocator.free(old);
                content.block.text.text = combined;
            },
            .thinking => {
                const old = content.block.thinking.thinking;
                const combined = appendBytesOwned(allocator, old, bytes) catch return false;
                allocator.free(old);
                content.block.thinking.thinking = combined;
            },
        }
    }
    return true;
}

const AssistantContentBlockRef = struct {
    block: *agent_protocol.AssistantMessage.AssistantContentBlock,
    preexisting: bool,
};

fn ensureAssistantContentBlock(
    allocator: std.mem.Allocator,
    assistant: *agent_protocol.AssistantMessage,
    target: conversation_mod.AssistantAppendTarget,
    bytes: []const u8,
) ?AssistantContentBlockRef {
    if (target.content_index < assistant.content.len) {
        const block: *agent_protocol.AssistantMessage.AssistantContentBlock = @constCast(&assistant.content[target.content_index]);
        switch (target.kind) {
            .text => if (block.* != .text) return null,
            .thinking => if (block.* != .thinking) return null,
        }
        return .{ .block = block, .preexisting = true };
    }
    if (target.content_index != assistant.content.len) return null;

    const grown = allocator.alloc(agent_protocol.AssistantMessage.AssistantContentBlock, assistant.content.len + 1) catch return null;
    @memcpy(grown[0..assistant.content.len], assistant.content);
    grown[target.content_index] = switch (target.kind) {
        .text => .{ .text = .{ .text = allocator.dupe(u8, bytes) catch {
            allocator.free(grown);
            return null;
        } } },
        .thinking => .{ .thinking = .{ .thinking = allocator.dupe(u8, bytes) catch {
            allocator.free(grown);
            return null;
        } } },
    };
    allocator.free(assistant.content);
    assistant.content = grown;
    return .{ .block = @constCast(&assistant.content[target.content_index]), .preexisting = false };
}

fn appendBytesOwned(allocator: std.mem.Allocator, existing: []const u8, extra: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, existing.len + extra.len);
    @memcpy(out[0..existing.len], existing);
    @memcpy(out[existing.len..], extra);
    return out;
}

// Legacy resume-only wrappers. New callers should use
// `rebuildFromMessages` / `rebuildFromSnapshot` / `ProjectionState.applyOwnedPatch`.
pub fn seedEditorHistory(editor: EditorInterface, messages: []const agent_protocol.AgentMessage) void {
    editor.clearHistory();
    for (messages) |message| seedHistoryFromMessage(editor, message);
}

pub fn applySessionMessages(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    messages: []const agent_protocol.AgentMessage,
    options: RebuildOptions,
) void {
    for (messages) |message| {
        appendProjectedMessage(transcript, resolver, message, options);
    }
    transcript.clearPendingToolRouting();
}

fn seedHistoryFromMessage(editor: EditorInterface, message: agent_protocol.AgentMessage) void {
    // Tiny extraction buffer, freed immediately after the history append.
    const text = extractUserMessageText(std.heap.page_allocator, message) orelse return;
    defer text.deinit(std.heap.page_allocator);
    editor.addToHistory(text.slice());
}

fn appendProjectedMessage(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
) void {
    appendProjectedMessageWithSkippedToolCalls(transcript, resolver, message, options, &.{});
}

fn appendProjectedMessageWithSkippedToolCalls(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
) void {
    switch (message) {
        .assistant => |assistant| appendAssistantMessageRows(transcript, resolver, assistant, options.retry_attempt, live_tool_ids, options.theme),
        .tool_result => |tool_result| appendToolResultMessage(transcript, tool_result),
        else => appendProjectedSingleRowMessage(transcript, resolver, message, options, live_tool_ids),
    }
}

fn appendProjectedSingleRowMessage(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
) void {
    const row = buildSnapshotMessageRow(
        transcript.allocator,
        resolver,
        message,
        options,
        live_tool_ids,
        transcript.hide_thinking_block,
    ) catch |err| switch (err) {
        error.SkipHiddenCustomMessage,
        error.EmptyCustomMessage,
        error.EmptyUserMessage,
        error.UnsupportedStandaloneToolResult,
        => return,
        else => return,
    };
    _ = appendOwnedRow(transcript, row);
}

fn appendAssistantMessageRows(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    assistant: agent_protocol.AssistantMessage,
    retry_attempt: u32,
    live_tool_ids: []const []const u8,
    theme: *const Theme,
) void {
    const assistant_row = createAssistantMessageRow(
        transcript.allocator,
        assistant,
        live_tool_ids,
        theme,
        transcript.hide_thinking_block,
    ) catch return;
    if (!appendOwnedRow(transcript, assistant_row)) return;

    for (assistant.content) |block| {
        if (block != .tool_call) continue;
        const tool_call = block.tool_call;
        if (containsToolCallId(live_tool_ids, tool_call.id)) continue;
        const tool_row = createCommittedToolCallRow(
            transcript.allocator,
            resolver,
            tool_call,
            assistant,
            retry_attempt,
            theme,
        ) catch return;
        if (!appendOwnedRow(transcript, tool_row)) return;
    }
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
    retry_attempt: u32,
    theme: *const Theme,
) !TranscriptItem {
    var owned_abort_message: ?[]u8 = null;
    defer if (owned_abort_message) |message| allocator.free(message);

    var error_content: [1]AgentToolResult.ContentBlock = undefined;
    var result: ?AgentToolResult = null;
    var is_error = false;
    if (failedAssistantToolCallText(allocator, assistant, retry_attempt, &owned_abort_message)) |error_text| {
        error_content[0] = .{ .text = .{ .text = error_text } };
        result = .{
            .content = &error_content,
            .is_error = true,
        };
        is_error = true;
    }

    return createToolExecutionRowParts(
        allocator,
        resolver,
        tool_call.id,
        tool_call.name,
        tool_call.arguments,
        true,
        false,
        result,
        null,
        false,
        is_error,
        theme,
    );
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

fn appendToolResultMessage(transcript: *Transcript, tool_result: agent_protocol.ToolResultMessage) void {
    const blocks = transcript.allocator.alloc(AgentToolResult.ContentBlock, tool_result.content.len) catch return;
    defer transcript.allocator.free(blocks);

    for (tool_result.content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |text| .{ .text = text },
            .image => |image| .{ .image = image },
        };
    }

    finalizeToolResult(transcript, tool_result.tool_call_id, .{
        .content = blocks,
        .details = if (tool_result.details) |details| details else .null,
        .is_error = tool_result.is_error,
    }, tool_result.is_error);
}

fn finalizeToolResult(
    transcript: *Transcript,
    tool_call_id: []const u8,
    result: ?AgentToolResult,
    is_error: bool,
) void {
    transcript.toolSetFinalResult(tool_call_id, result, is_error);
}

fn appendOwnedRow(transcript: *Transcript, row: TranscriptItem) bool {
    if (transcript.addItem(row)) return true;
    var owned_row = row;
    owned_row.deinit(transcript.allocator);
    return false;
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

fn buildSnapshotMessageRow(
    allocator: std.mem.Allocator,
    _: ToolRendererResolver,
    message: agent_protocol.AgentMessage,
    options: RebuildOptions,
    live_tool_ids: []const []const u8,
    hide_thinking_block: bool,
) !TranscriptItem {
    return switch (message) {
        .user => try buildUserRow(allocator, message, options.theme),
        .assistant => |assistant| try createAssistantMessageRow(allocator, assistant, live_tool_ids, options.theme, hide_thinking_block),
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
    return createUserMessageRow(allocator, .{ .text = text.slice() }, .user_message, theme);
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

fn createAssistantMessageRow(
    allocator: std.mem.Allocator,
    assistant: agent_protocol.AssistantMessage,
    live_tool_ids: []const []const u8,
    theme: *const Theme,
    hide_thinking_block: bool,
) !TranscriptItem {
    const am = try allocator.create(assistant_message_component_mod.AssistantMessage);
    errdefer allocator.destroy(am);
    am.* = assistant_message_component_mod.AssistantMessage.init(allocator);
    errdefer am.deinit();
    am.theme = theme;
    am.hide_thinking_block = hide_thinking_block;
    for (assistant.content, 0..) |block, idx| {
        switch (block) {
            .text => |text| am.appendText(idx, text.text),
            .thinking => |thinking| am.appendThinking(idx, thinking.thinking),
            .tool_call => |tool_call| if (containsToolCallId(live_tool_ids, tool_call.id)) continue,
        }
    }
    return .{
        .renderable = TranscriptRenderable.init(assistant_message_component_mod.AssistantMessage, am),
        .kind = .assistant_message,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(am),
        .deinit_fn = deinitAssistantMessageRow,
    };
}

fn createUserMessageRow(
    allocator: std.mem.Allocator,
    props: user_message_component_mod.Props,
    kind: transcript_mod.ItemKind,
    theme: *const Theme,
) !TranscriptItem {
    const msg = try allocator.create(user_message_component_mod.UserMessage);
    errdefer allocator.destroy(msg);
    msg.* = user_message_component_mod.UserMessage.init(allocator);
    errdefer msg.deinit();
    msg.setTheme(theme);

    var message_props = props;
    message_props.status = if (kind == .queued_user_message) .pending else .in_chat;
    msg.setProps(message_props);
    return .{
        .renderable = TranscriptRenderable.init(user_message_component_mod.UserMessage, msg),
        .kind = kind,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(msg),
        .deinit_fn = deinitUserMessageRow,
    };
}

fn createToolExecutionRow(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool_execution: conversation_snapshot_mod.ToolExecutionItem,
    theme: *const Theme,
) !TranscriptItem {
    return createToolExecutionRowParts(
        allocator,
        resolver,
        tool_execution.tool_call_id,
        tool_execution.tool_name,
        tool_execution.args,
        tool_execution.args_complete,
        tool_execution.execution_started,
        tool_execution.result,
        null,
        tool_execution.is_partial,
        tool_execution.is_error,
        theme,
    );
}

fn createLiveToolExecutionRow(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool: conversation_mod.LiveToolExecution,
    theme: *const Theme,
) !TranscriptItem {
    return createToolExecutionRowParts(
        allocator,
        resolver,
        tool.tool_call_id,
        tool.tool_name,
        tool.args,
        tool.args_complete,
        tool.execution_started,
        tool.result,
        tool.result_message,
        tool.is_partial,
        tool.is_error,
        theme,
    );
}

fn createToolExecutionRowParts(
    allocator: std.mem.Allocator,
    resolver: ToolRendererResolver,
    tool_call_id_src: []const u8,
    tool_name_src: []const u8,
    args: std.json.Value,
    args_complete: bool,
    execution_started: bool,
    result: ?AgentToolResult,
    result_message: ?agent_protocol.ToolResultMessage,
    is_partial: bool,
    is_error: bool,
    theme: *const Theme,
) !TranscriptItem {
    const renderer = resolver.resolve(tool_name_src);
    const tool_call_id = try allocator.dupe(u8, tool_call_id_src);
    errdefer allocator.free(tool_call_id);
    const tool_name = try allocator.dupe(u8, tool_name_src);
    errdefer allocator.free(tool_name);
    const te = try allocator.create(transcript_mod.ToolExecution);
    errdefer allocator.destroy(te);
    te.* = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .allocator = allocator,
        .theme = theme,
        .renderer = renderer,
    };
    errdefer te.deinit();
    if (renderer.init_state) |init_fn| te.renderer_state = init_fn(allocator);
    te.setArgs(args);
    if (args_complete) te.setArgsComplete();
    if (execution_started) te.markExecutionStarted();
    if (result_message) |message| {
        const rendered_result = try toolResultMessageAsAgentToolResult(allocator, message);
        defer rendered_result.free(allocator);
        te.setFinalResult(rendered_result, message.is_error);
    } else if (result) |value| {
        if (is_partial) {
            te.setPartialResult(value, is_error);
        } else {
            te.setFinalResult(value, is_error);
        }
    }
    return .{
        .renderable = TranscriptRenderable.init(transcript_mod.ToolExecution, te),
        .kind = .tool_execution,
        .tool_call_id = te.tool_call_id,
        .extra_height = 1,
        .deinit_ctx = @ptrCast(te),
        .deinit_fn = deinitToolExecutionRow,
    };
}

fn toolResultMessageAsAgentToolResult(
    allocator: std.mem.Allocator,
    tool_result: agent_protocol.ToolResultMessage,
) !AgentToolResult {
    const blocks = try allocator.alloc(AgentToolResult.ContentBlock, tool_result.content.len);
    errdefer allocator.free(blocks);

    for (tool_result.content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |text| .{ .text = text },
            .image => |image| .{ .image = image },
        };
    }

    return .{
        .content = blocks,
        .details = if (tool_result.details) |details| details else .null,
        .is_error = tool_result.is_error,
    };
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
        .extra_height = 1,
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
                    .image => |image| try out.writer(allocator).print("[image: {s}]", .{image.mime_type}),
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
                try out.writer(allocator).print("[image{d}]", .{image_index});
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
            try out.append(allocator, @intCast(buf.get(col, row).grapheme.codepoint));
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

test "rebuildFromMessages reconstructs tool call rows and tool results" {
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

    rebuildFromMessages(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &messages,
        .{ .theme = themes_builtin.dark() },
    );

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("do it", editor.history.items[0]);
    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);
    try testing.expectEqual(@as(usize, 0), transcript.pending_tools.count());

    const tool_item = transcript.items.items[2];
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(tool_item.deinit_ctx.?));
    try testing.expect(tool.args_complete);
    try testing.expect(!tool.is_partial);
    try testing.expect(!tool.is_error);
    try testing.expect(tool.result != null);
    try testing.expectEqualStrings("done", tool.result.?.content[0].text.text);
}

test "rebuildFromMessages preserves assistant text thinking and tool call ordering" {
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

    rebuildFromMessages(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &messages,
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

test "rebuildFromMessages respects hidden thinking labels during direct row projection" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();
    transcript.setHideThinkingBlock(true);

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "alpha" } },
        .{ .thinking = .{ .thinking = "ponder" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .stop, null),
    };

    rebuildFromMessages(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &messages,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "alpha") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Thinking...") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "ponder") == null);
}

test "rebuildFromMessages renders failed tool rows for aborted assistant" {
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

    rebuildFromMessages(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &messages,
        .{
            .theme = themes_builtin.dark(),
            .retry_attempt = 0,
        },
    );

    try testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(transcript.items.items[0].deinit_ctx.?));
    try testing.expect(tool.args_complete);
    try testing.expect(tool.is_error);
    try testing.expect(!tool.is_partial);
    try testing.expect(tool.result != null);
    try testing.expectEqualStrings("Operation aborted", tool.result.?.content[0].text.text);
}

test "rebuildFromMessages includes summaries displayable custom messages and editor history" {
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

    rebuildFromMessages(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &messages,
        .{ .theme = themes_builtin.dark() },
    );

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("hello[image1] world", editor.history.items[0]);

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "hello[image1] world") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "kept the recent turns") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "previous branch summary") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "shown custom") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "do not show") == null);
}

test "rebuildFromSnapshot reconstructs committed messages and queued rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const messages = [_]agent_protocol.AgentMessage{
        makeUserMessage("hello"),
        .{ .compaction_summary = .{ .summary = "kept the recent turns", .tokens_before = 42, .timestamp = 2 } },
    };
    var steering = [_]run_control_mod.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "steer me") },
    };
    defer testing.allocator.free(steering[0].text);
    var follow_up = [_]run_control_mod.QueuedMessageText{
        .{ .text = try testing.allocator.dupe(u8, "follow me") },
    };
    defer testing.allocator.free(follow_up[0].text);

    var snapshot = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &messages,
        .steering = &steering,
        .follow_up = &follow_up,
    });
    defer snapshot.deinit(testing.allocator);

    rebuildFromSnapshot(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        snapshot,
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

test "rebuildFromSnapshot reconstructs active assistant and live tool execution rows" {
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

    var snapshot = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 2,
        .messages = &.{makeUserMessage("hello")},
        .active_assistant = assistant.assistant,
        .tool_executions = &.{.{
            .tool_call_id = "tc-1",
            .tool_name = "bash",
            .args = .null,
            .args_complete = true,
            .execution_started = true,
            .result = partial_result,
            .is_error = false,
            .is_partial = true,
        }},
    });
    defer snapshot.deinit(testing.allocator);

    rebuildFromSnapshot(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        snapshot,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "working") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "bash") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "partial output") != null);
    try testing.expectEqual(@as(?usize, null), std.mem.indexOf(u8, rendered, "tc-1 tc-1"));
}

test "rebuildFromSnapshot respects hidden thinking labels for active assistant rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();
    transcript.setHideThinkingBlock(true);

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "working" } },
        .{ .thinking = .{ .thinking = "ponder" } },
    };
    const assistant = makeAssistantMessage(&assistant_content, .stop, null);

    var snapshot = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &.{},
        .active_assistant = assistant.assistant,
    });
    defer snapshot.deinit(testing.allocator);

    rebuildFromSnapshot(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        snapshot,
        .{ .theme = themes_builtin.dark() },
    );

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "working") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "Thinking...") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "ponder") == null);
}

test "reconcileFromSnapshot retains unchanged rows and appends editor history once" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var snapshot = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &.{makeUserMessage("hello")},
    });
    defer snapshot.deinit(testing.allocator);

    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const first_ptr = transcript.items.items[0].deinit_ctx;
    try testing.expectEqual(@as(u32, 1), mock_editor.history_count);

    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot, .{ .theme = themes_builtin.dark() });
    try testing.expectEqual(first_ptr, transcript.items.items[0].deinit_ctx);
    try testing.expectEqual(@as(u32, 1), mock_editor.history_count);
}

test "reconcileFromSnapshot replaces only changed semantic rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var snapshot_a = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &.{ makeUserMessage("one"), makeUserMessage("two") },
    });
    defer snapshot_a.deinit(testing.allocator);
    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot_a, .{ .theme = themes_builtin.dark() });

    const first_ptr = transcript.items.items[0].deinit_ctx;
    const second_ptr = transcript.items.items[1].deinit_ctx;

    var snapshot_b = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 2,
        .messages = &.{ makeUserMessage("one"), makeUserMessage("two updated") },
    });
    defer snapshot_b.deinit(testing.allocator);
    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot_b, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(first_ptr, transcript.items.items[0].deinit_ctx);
    try testing.expect(second_ptr != transcript.items.items[1].deinit_ctx);
}

test "reconcileFromSnapshot reorders rows and preserves scroll offset when not following bottom" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var mock_editor = editor_iface_mod.MockEditor{};
    const editor = mock_editor.editorInterface();

    var snapshot_a = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 1,
        .messages = &.{ makeUserMessage("one"), makeUserMessage("two"), makeUserMessage("three") },
    });
    defer snapshot_a.deinit(testing.allocator);
    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot_a, .{ .theme = themes_builtin.dark() });
    _ = transcript.totalHeight(40);
    transcript.scrollBy(40, 2, -1);
    const scroll_before = transcript.scrollOffset();

    var snapshot_b = try conversation_snapshot_mod.build(testing.allocator, .{
        .version = 2,
        .messages = &.{ makeUserMessage("three"), makeUserMessage("one"), makeUserMessage("two") },
    });
    defer snapshot_b.deinit(testing.allocator);
    reconcileFromSnapshot(&transcript, editor, tool_display_mod.empty_resolver, snapshot_b, .{ .theme = themes_builtin.dark() });

    try testing.expectEqual(scroll_before, transcript.scrollOffset());
}

test "ProjectionState applies assistant text frontier deltas" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    const empty_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{};
    const assistant = try conversation_mod.cloneAssistantMessage(
        testing.allocator,
        makeAssistantMessage(&empty_content, .stop, null).assistant,
    );
    var replace_frontier = conversation_mod.ConversationPatch{ .replace_frontier = .{
        .assistant = assistant,
        .live_tools = try testing.allocator.alloc(conversation_mod.LiveToolExecution, 0),
    } };
    defer replace_frontier.deinit(testing.allocator);

    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &replace_frontier,
        .{ .theme = themes_builtin.dark() },
    ));

    var delta_patch = conversation_mod.ConversationPatch{ .append_frontier_content = .{
        .target = .{ .assistant_content = .{ .content_index = 0, .kind = .text } },
        .bytes = try testing.allocator.dupe(u8, "running bash"),
    } };
    defer delta_patch.deinit(testing.allocator);

    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &delta_patch,
        .{ .theme = themes_builtin.dark() },
    ));

    try testing.expect(projection.snapshot != null);
    try testing.expect(projection.snapshot.?.frontier != null);
    try testing.expectEqualStrings("running bash", projection.snapshot.?.frontier.?.assistant.?.content[0].text.text);

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);
    try testing.expect(std.mem.indexOf(u8, rendered, "running bash") != null);
}

test "ProjectionState commits frontier then appends final assistant and tool-result messages" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    var projection = ProjectionState.init(testing.allocator);
    defer projection.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "running bash" } },
        .{ .tool_call = .{ .id = "tc-1", .name = "bash", .arguments = .null } },
    };
    const tool_result_content = [_]agent_protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };

    const assistant_frontier = try conversation_mod.cloneAssistantMessage(
        testing.allocator,
        makeAssistantMessage(&assistant_content, .toolUse, null).assistant,
    );
    const result_message = try conversation_mod.cloneToolResultMessage(
        testing.allocator,
        makeToolResultMessage("tc-1", "bash", &tool_result_content, false).tool_result,
    );
    var replace_frontier = conversation_mod.ConversationPatch{ .replace_frontier = .{
        .assistant = assistant_frontier,
        .live_tools = try testing.allocator.dupe(conversation_mod.LiveToolExecution, &.{.{
            .tool_call_id = try testing.allocator.dupe(u8, "tc-1"),
            .tool_name = try testing.allocator.dupe(u8, "bash"),
            .args = .null,
            .args_complete = true,
            .execution_started = true,
            .result_message = result_message,
        }}),
    } };
    defer replace_frontier.deinit(testing.allocator);

    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &replace_frontier,
        .{ .theme = themes_builtin.dark() },
    ));

    var commit_patch = conversation_mod.ConversationPatch{ .commit_frontier = {} };
    defer commit_patch.deinit(testing.allocator);
    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &commit_patch,
        .{ .theme = themes_builtin.dark() },
    ));

    var assistant_patch = conversation_mod.ConversationPatch{ .append_committed = try message_memory.cloneMessage(
        testing.allocator,
        makeAssistantMessage(&assistant_content, .toolUse, null),
    ) };
    defer assistant_patch.deinit(testing.allocator);
    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &assistant_patch,
        .{ .theme = themes_builtin.dark() },
    ));

    var tool_patch = conversation_mod.ConversationPatch{ .append_committed = try message_memory.cloneMessage(
        testing.allocator,
        makeToolResultMessage("tc-1", "bash", &tool_result_content, false),
    ) };
    defer tool_patch.deinit(testing.allocator);
    try testing.expect(projection.applyOwnedPatch(
        &transcript,
        EditorInterface.init(editor_mod.Editor, &editor),
        tool_display_mod.empty_resolver,
        &tool_patch,
        .{ .theme = themes_builtin.dark() },
    ));

    try testing.expect(projection.snapshot != null);
    try testing.expect(projection.snapshot.?.frontier == null);
    try testing.expectEqual(@as(usize, 2), projection.snapshot.?.committed.len);
    try testing.expectEqual(@as(usize, 2), transcript.items.items.len);
    try testing.expectEqual(@as(usize, 0), transcript.pending_tools.count());

    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(transcript.items.items[1].deinit_ctx.?));
    try testing.expect(tool.args_complete);
    try testing.expect(!tool.is_error);
    try testing.expect(tool.result != null);
    try testing.expectEqualStrings("done", tool.result.?.content[0].text.text);
}
