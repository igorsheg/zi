const std = @import("std");

const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const client_protocol = @import("client_protocol.zig");
const tool_metadata = @import("tool_metadata.zig");
const vm = @import("view_model.zig");

/// A preview rebuild costs O(accumulated args); deltas arrive at network
/// rate, so rebuilds are rate-limited per tool call.
const preview_rebuild_interval_ms: i64 = 32;

pub const EngineDrain = struct {
    allocator: std.mem.Allocator,
    view_model: *vm.ViewModel,
    dirty: bool = false,
    assistant_item: ?u64 = null,
    thinking_item: ?u64 = null,
    pending: Pending = .{},
    tools: std.ArrayList(ToolCursor) = .empty,
    /// Test-only clock override for throttle tests; null in production.
    test_now_ms: ?i64 = null,
    home_dir: ?[]const u8 = null,

    const Pending = struct {
        user: ?u64 = null,
        assistant: ?u64 = null,
        tool: ?u64 = null,
        custom: ?u64 = null,
    };

    const ToolCursor = struct {
        id_buf: [128]u8 = undefined,
        id_len: u16 = 0,
        item_id: u64,
        streams_output: bool,
        started_ms: ?i64 = null,
        last_preview_ms: ?i64 = null,
        preview_len: usize = 0,
        preview_total_lines: usize = 0,

        fn id(self: *const ToolCursor) []const u8 {
            return self.id_buf[0..self.id_len];
        }
    };

    pub fn init(allocator: std.mem.Allocator, view_model: *vm.ViewModel) EngineDrain {
        return .{ .allocator = allocator, .view_model = view_model };
    }

    pub fn deinit(self: *EngineDrain) void {
        self.tools.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn isDirty(self: *const EngineDrain) bool {
        return self.dirty;
    }

    pub fn takeDirty(self: *EngineDrain) bool {
        const value = self.dirty;
        self.dirty = false;
        return value;
    }

    pub fn agentEvent(self: *EngineDrain, event: agent_mod.AgentEvent) !void {
        var writer = self.view_model.lockWriter();
        defer self.finish(&writer);
        switch (event) {
            .message_start => |payload| try self.messageStart(&writer, payload.message),
            .message_update => |payload| try self.messageUpdate(&writer, payload.assistant_message_event),
            .message_end => |payload| try self.messageEnd(&writer, payload.message),
            .tool_execution_start => |payload| try self.toolStart(&writer, payload),
            .tool_execution_update => |payload| try self.toolUpdate(&writer, payload),
            .tool_execution_end => |payload| try self.toolEnd(&writer, payload),
            .agent_start, .agent_end, .turn_start, .turn_end => {},
        }
    }

    pub fn messageCommitted(self: *EngineDrain, entry_id: []const u8, message: agent_mod.AgentMessage) void {
        var writer = self.view_model.lockWriter();
        defer self.finish(&writer);
        const id = switch (message) {
            .user => self.pending.user,
            .assistant => self.pending.assistant,
            .tool_result => |tool| if (self.findTool(tool.tool_call_id)) |cursor| cursor.item_id else self.pending.tool,
            .custom => self.pending.custom,
        } orelse return;
        if (findItem(&writer, id)) |item| {
            item.entry_id = parseEntryId(entry_id);
            item.source_id.set(entry_id);
            item.state = .final;
            bumpItem(item);
            writer.touched = true;
        }
        switch (message) {
            .user => self.pending.user = null,
            .assistant => {
                self.pending.assistant = null;
                self.assistant_item = null;
                self.thinking_item = null;
            },
            .tool_result => self.pending.tool = null,
            .custom => self.pending.custom = null,
        }
    }

    pub fn operationRunning(self: *EngineDrain, op_id: u64) void {
        self.setPhase(.{ .running = .{ .op_id = op_id, .started_ms = nowMs() } }, false);
    }

    pub fn operationIdle(self: *EngineDrain) void {
        self.setPhase(.idle, false);
    }

    pub fn operationCancelRequested(self: *EngineDrain) void {
        var writer = self.view_model.lockWriter();
        writer.vm.op.cancel_requested = true;
        bumpOp(&writer);
        writer.pushNotice(.info, .cancel_requested, "cancel requested");
        self.finish(&writer);
    }

    pub fn cancelStreaming(self: *EngineDrain) void {
        var writer = self.view_model.lockWriter();
        var changed = false;
        for (writer.vm.transcript.items.items) |*item| {
            if (item.state == .streaming) {
                item.state = .canceled;
                bumpItem(item);
                writer.touched = true;
                changed = true;
            }
        }
        if (!changed) {
            if (writer.addItem(self.allocator, .system_notice, .streaming, "canceled", null)) |id| {
                if (findItem(&writer, id)) |item| {
                    item.state = .canceled;
                    bumpItem(item);
                    writer.touched = true;
                }
            } else |_| {}
        }
        writer.pushNotice(.info, .cancel_done, "canceled");
        self.finish(&writer);
    }

    pub fn stopped(self: *EngineDrain) void {
        self.setPhase(.stopped, false);
    }

    pub fn shuttingDown(self: *EngineDrain) void {
        self.setPhase(.shutting_down, false);
    }

    pub fn compactionStart(self: *EngineDrain, reason: client_protocol.CompactionReason) void {
        self.setPhase(.{ .compacting = .{ .op_id = 0, .started_ms = nowMs(), .trigger = compactionTrigger(reason) } }, false);
    }

    pub fn compactionEnd(self: *EngineDrain, end: client_protocol.CompactionEnd) void {
        var writer = self.view_model.lockWriter();
        if (end.result) |result| {
            if (writer.addItem(self.allocator, .compaction_summary, .streaming, result.summary.text, null)) |id| {
                if (findItem(&writer, id)) |item| {
                    item.markdown = true;
                    item.compaction = .{ .reason = compactionReason(end.reason), .tokens_before = result.tokens_before };
                    item.state = .final;
                    bumpItem(item);
                    writer.touched = true;
                }
            } else |_| {}
        }
        if (end.error_message) |message| writer.pushNotice(.warn, .operation_failed, message.text);
        self.finish(&writer);
    }

    pub fn retryStart(
        self: *EngineDrain,
        attempt: usize,
        max_attempts: usize,
        delay_ms: u64,
        reason: []const u8,
        _: ?ai.OperationalFailure.Category,
    ) void {
        var writer = self.view_model.lockWriter();
        const bounded = vm.BoundedText(256).init(reason);
        writer.vm.op.phase = .{ .retry_wait = .{
            .until_ms = nowMs() + @as(i64, @intCast(delay_ms)),
            .attempt = @intCast(attempt),
            .max_attempts = @intCast(max_attempts),
            .delay_ms = delay_ms,
            .reason = bounded,
        } };
        writer.vm.op.cancel_requested = false;
        bumpOp(&writer);
        writer.pushNotice(.warn, .retry_start, reason);
        self.finish(&writer);
    }

    pub fn retryEnd(self: *EngineDrain, success: bool, _: usize, final_error: ?[]const u8, _: ?ai.OperationalFailure) void {
        if (!success) self.notice(.err, .retry_end, final_error orelse "retry failed");
    }

    pub fn notice(self: *EngineDrain, severity: vm.Notice.Severity, semantic: vm.NoticeSemantic, text: []const u8) void {
        var writer = self.view_model.lockWriter();
        writer.pushNotice(severity, semantic, text);
        self.finish(&writer);
    }

    pub fn operationalFailure(self: *EngineDrain, failure: ai.OperationalFailure) void {
        var writer = self.view_model.lockWriter();
        writer.pushFailureNotice(.err, noticeFailureCategory(failure.category), failure.message);
        self.finish(&writer);
    }

    pub fn transcriptCustom(self: *EngineDrain, title: []const u8, text: []const u8, markdown: bool) !void {
        if (title.len == 0 and text.len == 0) return;
        var writer = self.view_model.lockWriter();
        defer self.finish(&writer);
        const id = try writer.addItem(self.allocator, .banner, .streaming, text, null);
        if (findItem(&writer, id)) |item| {
            item.title.set(title);
            item.markdown = markdown;
            item.state = .final;
            bumpItem(item);
            writer.touched = true;
        }
    }

    pub fn promptCommand(self: *EngineDrain, command: client_protocol.PromptCommand) void {
        switch (command.presentation) {
            .transcript => self.transcriptCustom(
                if (command.session_info != null) "Session Info" else "Command",
                command.message.text,
                true,
            ) catch {},
            .status => self.notice(
                if (command.result == .failed) .warn else .info,
                .generic,
                command.message.text,
            ),
        }
    }

    pub fn rejection(self: *EngineDrain, rejection_value: client_protocol.Rejection) void {
        self.notice(
            .warn,
            if (rejection_value.code == .queue_full) .queue_full else .operation_failed,
            rejection_value.message.text,
        );
    }

    pub fn eventOverflow(self: *EngineDrain, overflow: client_protocol.EventOverflow) void {
        var buffer: [64]u8 = undefined;
        const text = std.fmt.bufPrint(
            &buffer,
            "event overflow: dropped {d}",
            .{overflow.dropped_count},
        ) catch "event overflow";
        self.notice(.warn, .notices_dropped, text);
    }

    pub fn clientEvent(self: *EngineDrain, event: client_protocol.ClientEvent) void {
        switch (event) {
            .compaction_start => |start| self.compactionStart(start.reason),
            .compaction_end => |end| self.compactionEnd(end),
            .auto_retry_start => |retry| self.retryStart(
                retry.attempt,
                retry.max_attempts,
                retry.delay_ms,
                retry.error_message.text,
                if (retry.failure) |failure| failure.category else null,
            ),
            .auto_retry_end => |retry| self.retryEnd(
                retry.success,
                @intCast(retry.attempt),
                if (retry.final_error) |err| err.text else null,
                null,
            ),
            .rejected => |rejection_value| self.rejection(rejection_value),
            .event_overflow => |overflow| self.eventOverflow(overflow),
            .prompt_command => |command| self.promptCommand(command),
            else => {},
        }
    }

    pub fn queueAdd(self: *EngineDrain, id: u64, kind: anytype, text: []const u8) void {
        var writer = self.view_model.lockWriter();
        const prompt = vm.QueuedPrompt{ .id = id, .text = vm.BoundedText(256).init(text) };
        switch (kind) {
            .steering => writer.vm.queue.enqueueSteering(prompt),
            .follow_up => writer.vm.queue.enqueueFollowUp(prompt),
        }
        writer.touched = true;
        self.finish(&writer);
    }

    pub fn queueRemove(self: *EngineDrain, id: u64) void {
        var writer = self.view_model.lockWriter();
        if (writer.vm.queue.removeById(id)) writer.touched = true;
        self.finish(&writer);
    }

    pub fn queueClear(self: *EngineDrain) void {
        var writer = self.view_model.lockWriter();
        writer.vm.queue = .{ .rev = writer.vm.queue.rev +% 1 };
        if (writer.vm.queue.rev == 0) writer.vm.queue.rev = 1;
        writer.touched = true;
        self.finish(&writer);
    }

    pub fn setChrome(self: *EngineDrain, chrome: vm.Chrome) void {
        var writer = self.view_model.lockWriter();
        writer.setChrome(chrome);
        self.finish(&writer);
    }

    pub fn closeHistory(self: *EngineDrain) void {
        var writer = self.view_model.lockWriter();
        for (writer.vm.history.items.items) |*item| item.deinit(self.allocator);
        writer.vm.history.items.clearRetainingCapacity();
        writer.vm.history.state = .closed;
        writer.vm.history.has_more_before = false;
        writer.vm.history.has_more_after = false;
        writer.vm.history.oldest_entry_id.len = 0;
        writer.vm.history.newest_entry_id.len = 0;
        writer.vm.history.rev +%= 1;
        if (writer.vm.history.rev == 0) writer.vm.history.rev = 1;
        writer.touched = true;
        self.finish(&writer);
    }

    pub fn publishHistoryPage(self: *EngineDrain, page: client_protocol.HistoryPage) !void {
        var next_items = try buildHistoryItems(self.allocator, page.items, self.home_dir);
        errdefer deinitHistoryItems(self.allocator, &next_items);

        var writer = self.view_model.lockWriter();
        for (writer.vm.history.items.items) |*item| item.deinit(self.allocator);
        writer.vm.history.items.deinit(self.allocator);
        writer.vm.history.items = next_items;
        next_items = .empty;
        writer.vm.history.state = if (page.items.len > 0) .open else .closed;
        writer.vm.history.has_more_before = page.items.len > 0 and page.has_more_before;
        writer.vm.history.has_more_after = page.items.len > 0;
        if (page.items.len > 0) {
            writer.vm.history.oldest_entry_id.set(page.items[0].entry_id.text);
            writer.vm.history.newest_entry_id.set(page.items[page.items.len - 1].entry_id.text);
        } else {
            writer.vm.history.oldest_entry_id.len = 0;
            writer.vm.history.newest_entry_id.len = 0;
        }
        writer.vm.history.rev +%= 1;
        if (writer.vm.history.rev == 0) writer.vm.history.rev = 1;
        writer.touched = true;
        self.finish(&writer);
    }

    pub fn startCompletion(self: *EngineDrain, query_id: u64, kind: vm.CompletionSlot.Kind) void {
        var writer = self.view_model.lockWriter();
        writer.vm.completion.start(self.allocator, query_id, kind);
        writer.touched = true;
        self.finish(&writer);
    }

    pub fn setCompletion(self: *EngineDrain, query_id: u64, kind: vm.CompletionSlot.Kind, items: []const vm.CompletionItem) !void {
        var writer = self.view_model.lockWriter();
        defer self.finish(&writer);
        try writer.vm.completion.set(self.allocator, query_id, kind, items);
        writer.touched = true;
    }

    pub fn bumpEpoch(self: *EngineDrain) void {
        var writer = self.view_model.lockWriter();
        writer.bumpEpoch();
        writer.finish();
        self.dirty = true;
    }

    fn messageStart(self: *EngineDrain, writer: *vm.Writer, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| self.pending.user = try writer.addItem(self.allocator, .user, .streaming, userText(user), null),
            .assistant => |assistant| try self.ensureAssistantItems(writer, assistant),
            .tool_result, .custom => {},
        }
    }

    fn messageUpdate(self: *EngineDrain, writer: *vm.Writer, event: ai.AssistantMessageEvent) !void {
        switch (event) {
            .text_delta => |payload| {
                try self.ensureAssistantItems(writer, payload.partial);
                if (self.assistant_item) |id| try writer.appendItemText(self.allocator, id, payload.delta);
            },
            .thinking_delta => |payload| {
                try self.ensureAssistantItems(writer, payload.partial);
                if (self.thinking_item) |id| try writer.appendItemText(self.allocator, id, payload.delta);
            },
            .toolcall_start => |payload| try self.toolPreview(writer, payload.partial, payload.content_index, false),
            .toolcall_delta => |payload| try self.toolPreview(writer, payload.partial, payload.content_index, false),
            .toolcall_end => |payload| try self.toolPreview(writer, payload.partial, payload.content_index, true),
            .done => |payload| try self.replaceAssistantFinal(writer, payload.message),
            .@"error" => |payload| try self.replaceAssistantFinal(writer, payload.@"error"),
            .start, .text_start, .text_end, .thinking_start, .thinking_end => {},
        }
    }

    fn messageEnd(self: *EngineDrain, writer: *vm.Writer, message: agent_mod.AgentMessage) !void {
        switch (message) {
            .user => |user| if (self.pending.user) |id| try writer.replaceItemText(self.allocator, id, userText(user)),
            .assistant => |assistant| try self.replaceAssistantFinal(writer, assistant),
            .tool_result => |tool| {
                const cursor = try self.ensureTool(writer, tool.tool_call_id, tool.tool_name);
                self.pending.tool = cursor.item_id;
                try replaceToolResultBody(
                    writer,
                    self.allocator,
                    cursor.item_id,
                    tool.tool_name,
                    tool.is_error,
                    tool.content,
                    tool.details,
                );
                setToolResultMeta(writer, cursor.item_id, tool.is_error, tool.details);
            },
            .custom => |custom| self.pending.custom = try writer.addItem(self.allocator, .system_notice, .streaming, custom.kind, null),
        }
    }

    fn ensureAssistantItems(self: *EngineDrain, writer: *vm.Writer, assistant: ai.AssistantMessage) !void {
        try self.ensureAssistantItemsBefore(writer, assistant, assistant.content.len);
    }

    fn ensureAssistantItemsBefore(self: *EngineDrain, writer: *vm.Writer, assistant: ai.AssistantMessage, index: usize) !void {
        for (assistant.content[0..@min(index, assistant.content.len)]) |content| switch (content) {
            .text => {
                if (self.assistant_item == null) {
                    self.assistant_item = try writer.addItem(self.allocator, .assistant, .streaming, "", null);
                }
            },
            .thinking => {
                if (self.thinking_item == null) {
                    self.thinking_item = try writer.addItem(self.allocator, .thinking, .streaming, "", null);
                }
            },
            .tool_call => {},
        };
    }

    fn replaceAssistantFinal(self: *EngineDrain, writer: *vm.Writer, assistant: ai.AssistantMessage) !void {
        for (assistant.content, 0..) |content, index| switch (content) {
            .text => |text| {
                if (self.assistant_item == null) self.assistant_item = try writer.addItem(self.allocator, .assistant, .streaming, "", null);
                try replaceIfChanged(writer, self.allocator, self.assistant_item.?, text.text, vm.assistant_text_bytes_max);
                self.pending.assistant = self.assistant_item;
            },
            .thinking => |thinking| {
                if (self.thinking_item == null) self.thinking_item = try writer.addItem(self.allocator, .thinking, .streaming, "", null);
                try replaceIfChanged(writer, self.allocator, self.thinking_item.?, thinking.thinking, vm.thinking_text_bytes_max);
            },
            .tool_call => try self.toolPreview(writer, assistant, index, true),
        };
        if (assistant.content.len == 0) if (assistant.error_message) |message| {
            if (self.assistant_item == null) self.assistant_item = try writer.addItem(self.allocator, .assistant, .streaming, "", null);
            try replaceIfChanged(writer, self.allocator, self.assistant_item.?, message, vm.assistant_text_bytes_max);
            self.pending.assistant = self.assistant_item;
        };
    }

    fn toolPreview(self: *EngineDrain, writer: *vm.Writer, assistant: ai.AssistantMessage, index: usize, final: bool) !void {
        if (index >= assistant.content.len or assistant.content[index] != .tool_call) return;
        try self.ensureAssistantItemsBefore(writer, assistant, index);
        const call = assistant.content[index].tool_call;
        const cursor = try self.ensureTool(writer, call.id, call.name);
        const now = self.currentMs();
        if (!final) {
            if (cursor.last_preview_ms) |last| {
                if (now - last < preview_rebuild_interval_ms) return;
            }
        }
        cursor.last_preview_ms = now;
        updateToolTitle(writer, cursor.item_id, call.name, call.arguments, self.home_dir);
        if (std.mem.eql(u8, call.name, "write")) try self.writePreview(writer, cursor, call.arguments);
    }

    /// Write-tool call preview: the first `lines_max` content lines stream
    /// as append-only item text (reader sampling stays O(delta)); past the
    /// cap only the "Showing lines" footer grows.
    fn writePreview(self: *EngineDrain, writer: *vm.Writer, cursor: *ToolCursor, arguments: std.json.Value) !void {
        const content = trimTrailingEmptyLines(argContentString(arguments) orelse return);
        const lines_max: usize = tool_metadata.displayForTool("write").collapse.lines_max;
        const visible = firstLines(content, lines_max);
        if (visible.len > cursor.preview_len) {
            try writer.appendItemText(self.allocator, cursor.item_id, visible[cursor.preview_len..]);
            cursor.preview_len = visible.len;
        }
        const total_lines = countLines(content);
        if (total_lines > lines_max and total_lines != cursor.preview_total_lines) {
            cursor.preview_total_lines = total_lines;
            var buffer: [64]u8 = undefined;
            const footer = std.fmt.bufPrint(
                &buffer,
                "Showing lines 1-{d} of {d}",
                .{ lines_max, total_lines },
            ) catch return;
            try writer.setItemFooter(cursor.item_id, footer);
        }
    }

    fn currentMs(self: *const EngineDrain) i64 {
        return self.test_now_ms orelse nowMs();
    }

    fn toolStart(self: *EngineDrain, writer: *vm.Writer, payload: agent_mod.AgentEvent.ToolExecutionStart) !void {
        const cursor = try self.ensureTool(writer, payload.tool_call_id, payload.tool_name);
        cursor.started_ms = nowMs();
        updateToolTitle(writer, cursor.item_id, payload.tool_name, payload.args, self.home_dir);
        if (toolKind(payload.tool_name) == .write) {
            try writer.replaceItemText(self.allocator, cursor.item_id, "");
            try writer.setItemFooter(cursor.item_id, "");
        }
        if (findItem(writer, cursor.item_id)) |item| {
            if (item.tool) |*tool| tool.started_ms = cursor.started_ms;
            bumpItem(item);
            writer.touched = true;
        }
    }

    fn toolUpdate(self: *EngineDrain, writer: *vm.Writer, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
        const cursor = try self.ensureTool(writer, payload.tool_call_id, payload.tool_name);
        try appendItemTextNormalized(writer, self.allocator, cursor.item_id, toolResultText(payload.partial_result.content));
    }

    fn toolEnd(self: *EngineDrain, writer: *vm.Writer, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
        const cursor = try self.ensureTool(writer, payload.tool_call_id, payload.tool_name);
        try replaceToolResultBody(
            writer,
            self.allocator,
            cursor.item_id,
            payload.tool_name,
            payload.is_error,
            payload.result.content,
            payload.result.details,
        );
        if (findItem(writer, cursor.item_id)) |item| {
            if (item.tool) |*tool| {
                tool.duration_ms = if (cursor.started_ms) |start| @intCast(@max(nowMs() - start, 0)) else 0;
                tool.is_error = payload.is_error;
                setDetailsJson(tool, payload.result.details);
            }
            bumpItem(item);
            writer.touched = true;
        }
    }

    fn ensureTool(self: *EngineDrain, writer: *vm.Writer, id: []const u8, name: []const u8) !*ToolCursor {
        if (self.findTool(id)) |cursor| return cursor;
        var meta: vm.ToolMeta = .{};
        meta.tool_call_id.set(id);
        meta.name.set(name);
        meta.display = tool_metadata.displayForTool(name);
        meta.streams_output = meta.display.streams_output;
        const item_id = try writer.addItem(self.allocator, .tool, .streaming, "", meta);
        try self.tools.append(self.allocator, .{
            .id_len = @intCast(@min(id.len, 128)),
            .item_id = item_id,
            .streams_output = meta.streams_output,
        });
        const cursor = &self.tools.items[self.tools.items.len - 1];
        @memcpy(cursor.id_buf[0..cursor.id_len], id[0..cursor.id_len]);
        return cursor;
    }

    fn findTool(self: *EngineDrain, id: []const u8) ?*ToolCursor {
        for (self.tools.items) |*cursor| if (std.mem.eql(u8, cursor.id(), id)) return cursor;
        return null;
    }

    fn setPhase(self: *EngineDrain, phase: vm.OperationStatus.Phase, cancel_requested: bool) void {
        var writer = self.view_model.lockWriter();
        writer.vm.op.phase = phase;
        writer.vm.op.cancel_requested = cancel_requested;
        bumpOp(&writer);
        self.finish(&writer);
    }

    fn finish(self: *EngineDrain, writer: *vm.Writer) void {
        const touched = writer.touched;
        writer.finish();
        if (touched) self.dirty = true;
    }
};

fn deinitHistoryItems(allocator: std.mem.Allocator, items: *std.ArrayList(vm.Item)) void {
    for (items.items) |*item| item.deinit(allocator);
    items.deinit(allocator);
    items.* = .empty;
}

fn buildHistoryItems(
    allocator: std.mem.Allocator,
    source_items: []const client_protocol.HistorySnapshotItem,
    home_dir: ?[]const u8,
) !std.ArrayList(vm.Item) {
    var items: std.ArrayList(vm.Item) = .empty;
    errdefer deinitHistoryItems(allocator, &items);

    var next_id: u64 = 1;
    for (source_items) |source| {
        switch (source.kind) {
            .user => try appendHistoryVmItem(
                allocator,
                &items,
                &next_id,
                .user,
                .final,
                source.text.text,
                source.entry_id.text,
                null,
            ),
            .system => try appendHistoryVmItem(
                allocator,
                &items,
                &next_id,
                .system,
                .final,
                source.text.text,
                source.entry_id.text,
                null,
            ),
            .assistant => {
                if (source.has_thinking) try appendHistoryVmItem(
                    allocator,
                    &items,
                    &next_id,
                    .thinking,
                    .final,
                    "",
                    source.entry_id.text,
                    null,
                );
                if (source.text.text.len > 0) try appendHistoryVmItem(
                    allocator,
                    &items,
                    &next_id,
                    .assistant,
                    .final,
                    source.text.text,
                    source.entry_id.text,
                    null,
                );
                for (source.tool_calls) |tool_call| {
                    const meta = try historyToolCallMeta(allocator, tool_call, home_dir);
                    try appendHistoryVmItem(
                        allocator,
                        &items,
                        &next_id,
                        .tool,
                        .streaming,
                        "",
                        source.entry_id.text,
                        meta,
                    );
                }
            },
            .tool_result => {
                const meta = historyToolResultMeta(source);
                try appendHistoryVmItem(
                    allocator,
                    &items,
                    &next_id,
                    .tool,
                    .final,
                    source.text.text,
                    source.entry_id.text,
                    meta,
                );
            },
        }
    }
    return items;
}

fn appendHistoryVmItem(
    allocator: std.mem.Allocator,
    items: *std.ArrayList(vm.Item),
    next_id: *u64,
    kind: vm.Item.Kind,
    state: vm.Item.State,
    text: []const u8,
    source_id: []const u8,
    tool: ?vm.ToolMeta,
) !void {
    var item: vm.Item = .{ .id = next_id.*, .kind = kind, .state = .streaming, .tool = tool };
    errdefer item.deinit(allocator);
    item.source_id.set(source_id);
    if (text.len > 0) try item.appendStreaming(allocator, text);
    item.state = state;
    try items.append(allocator, item);
    next_id.* += 1;
}

fn historyToolCallMeta(
    allocator: std.mem.Allocator,
    tool_call: client_protocol.HistoryToolCall,
    home_dir: ?[]const u8,
) !vm.ToolMeta {
    var meta: vm.ToolMeta = .{};
    meta.tool_call_id.set(tool_call.id.text);
    meta.name.set(tool_call.name.text);
    meta.display = tool_metadata.displayForTool(tool_call.name.text);
    meta.streams_output = meta.display.streams_output;
    meta.arguments_json.set(tool_call.arguments_json.text);
    meta.title.set(tool_call.title.text);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tool_call.arguments_json.text, .{}) catch null;
    defer if (parsed) |*value| value.deinit();
    if (parsed) |value| {
        var title_buffer: [(vm.ToolMeta{}).title.bytes.len]u8 = undefined;
        var compact_buffer: [(vm.ToolMeta{}).compact_title.bytes.len]u8 = undefined;
        const title = formatToolTitle(&title_buffer, tool_call.name.text, value.value, home_dir);
        if (title.len > 0) meta.title.set(title);
        meta.compact_title.set(formatCompactToolTitle(&compact_buffer, tool_call.name.text, value.value));
    }
    return meta;
}

fn historyToolResultMeta(source: client_protocol.HistorySnapshotItem) vm.ToolMeta {
    var meta: vm.ToolMeta = .{};
    if (source.tool_call_id) |id| meta.tool_call_id.set(id.text);
    if (source.tool_name) |name| {
        meta.name.set(name.text);
        meta.display = tool_metadata.displayForTool(name.text);
        meta.streams_output = meta.display.streams_output;
    }
    meta.is_error = source.is_error;
    if (source.details_json) |json| meta.details_json.set(json.text);
    return meta;
}

fn findItem(writer: *vm.Writer, id: u64) ?*vm.Item {
    for (writer.vm.transcript.items.items) |*item| if (item.id == id) return item;
    return null;
}

fn replaceIfChanged(writer: *vm.Writer, allocator: std.mem.Allocator, id: u64, text: []const u8, cap: usize) !void {
    const clipped = vm.utf8Prefix(text, cap);
    if (findItem(writer, id)) |item| {
        if (std.mem.eql(u8, item.text.items, clipped)) return;
    }
    try writer.replaceItemText(allocator, id, text);
}

fn bumpItem(item: *vm.Item) void {
    item.rev +%= 1;
    if (item.rev == 0) item.rev = 1;
}

fn bumpOp(writer: *vm.Writer) void {
    writer.vm.op.rev +%= 1;
    if (writer.vm.op.rev == 0) writer.vm.op.rev = 1;
    writer.touched = true;
}

fn userText(message: ai.UserMessage) []const u8 {
    return switch (message.content) {
        .string => |text| text,
        .blocks => |blocks| for (blocks) |block| {
            if (block == .text) break block.text.text;
        } else "",
    };
}

fn toolResultText(content: []const ai.ToolResultContent) []const u8 {
    for (content) |item| if (item == .text) return item.text.text;
    return "";
}

fn toolResultBody(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    is_error: bool,
    content: []const ai.ToolResultContent,
    details: ?std.json.Value,
) ![]u8 {
    if (!is_error and toolKind(tool_name) == .edit) {
        if (details) |value| if (value == .object) if (value.object.get("diff")) |diff| if (diff == .string)
            return allocator.dupe(u8, diff.string);
    }

    const trim = shouldTrimResult(tool_name, is_error);
    var body = try formatResultContent(allocator, content, trim);
    errdefer allocator.free(body);
    if (details) |value| if (value == .object) if (outputPrefixFromDetails(value.object, body)) |prefix| {
        const clipped = try allocator.dupe(u8, prefix);
        allocator.free(body);
        body = clipped;
    };

    return switch (toolKind(tool_name)) {
        .bash => try bashBodyFromDetails(allocator, details, body),
        .read => if (!is_error) try trimOwnedTrailingEmptyLines(allocator, body) else body,
        .edit, .write, .custom => body,
    };
}

fn replaceToolResultBody(
    writer: *vm.Writer,
    allocator: std.mem.Allocator,
    item_id: u64,
    tool_name: []const u8,
    is_error: bool,
    content: []const ai.ToolResultContent,
    details: ?std.json.Value,
) !void {
    if (shouldHideSuccessfulToolResult(tool_name, is_error, details)) return;
    const body = try toolResultBody(allocator, tool_name, is_error, content, details);
    defer allocator.free(body);
    try replaceItemTextNormalized(writer, allocator, item_id, body);
}

fn formatResultContent(
    allocator: std.mem.Allocator,
    content: []const ai.ToolResultContent,
    trim_trailing_empty_lines: bool,
) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    for (content) |item| {
        const text = switch (item) {
            .text => |text_content| if (trim_trailing_empty_lines)
                trimTrailingEmptyLines(text_content.text)
            else
                text_content.text,
            .image => |image| imageFallbackText(image.mime_type),
        };
        if (text.len == 0) continue;
        if (wrote_any) try writer.writer.writeByte('\n');
        try writer.writer.writeAll(text);
        wrote_any = true;
    }
    return writer.toOwnedSlice();
}

fn imageFallbackText(mime_type: []const u8) []const u8 {
    if (mime_type.len == 0) return "[Image]";
    if (std.mem.eql(u8, mime_type, "image/png")) return "[Image: image/png]";
    if (std.mem.eql(u8, mime_type, "image/jpeg")) return "[Image: image/jpeg]";
    if (std.mem.eql(u8, mime_type, "image/gif")) return "[Image: image/gif]";
    if (std.mem.eql(u8, mime_type, "image/webp")) return "[Image: image/webp]";
    return "[Image]";
}

fn bashBodyFromDetails(allocator: std.mem.Allocator, details: ?std.json.Value, owned_text: []u8) ![]u8 {
    errdefer allocator.free(owned_text);
    const object = if (details) |value| if (value == .object) value.object else return owned_text else return owned_text;
    const output = trimTrailingEmptyLines(stripLegacyBashNotices(owned_text));
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    var wrote_any = false;
    if (output.len > 0) {
        try writer.writer.writeAll(output);
        wrote_any = true;
    }
    try writeBashStatus(&writer.writer, object, &wrote_any);
    allocator.free(owned_text);
    return writer.toOwnedSlice();
}

fn shouldHideSuccessfulToolResult(tool_name: []const u8, is_error: bool, details: ?std.json.Value) bool {
    if (is_error or toolKind(tool_name) != .write) return false;
    const value = details orelse return false;
    if (value != .object) return false;
    return jsonInt(value.object, "bytesWritten") != null;
}

fn shouldTrimResult(name: []const u8, is_error: bool) bool {
    if (is_error) return false;
    return switch (toolKind(name)) {
        .bash, .read, .write => true,
        .edit, .custom => false,
    };
}

fn trimOwnedTrailingEmptyLines(allocator: std.mem.Allocator, owned_text: []u8) ![]u8 {
    const trimmed = trimTrailingEmptyLines(owned_text);
    if (trimmed.len == owned_text.len) return owned_text;
    const copy = try allocator.dupe(u8, trimmed);
    allocator.free(owned_text);
    return copy;
}

fn trimTrailingEmptyLines(text: []const u8) []const u8 {
    var end = text.len;
    while (end > 0 and text[end - 1] == '\n') {
        end -= 1;
        if (end > 0 and text[end - 1] == '\r') end -= 1;
    }
    return text[0..end];
}

fn outputPrefixFromDetails(object: std.json.ObjectMap, text: []const u8) ?[]const u8 {
    const truncation = jsonObject(object, "truncation") orelse return null;
    const output_bytes = jsonInt(truncation, "outputBytes") orelse return null;
    if (output_bytes < 0) return null;
    const end = std.math.cast(usize, output_bytes) orelse return null;
    if (end > text.len) return null;
    return utf8Prefix(text, end);
}

fn utf8Prefix(text: []const u8, end: usize) []const u8 {
    var valid_end = end;
    while (valid_end > 0 and !std.unicode.utf8ValidateSlice(text[0..valid_end])) valid_end -= 1;
    return text[0..valid_end];
}

fn stripLegacyBashNotices(text: []const u8) []const u8 {
    var end = trimTrailingEmptyLines(text).len;
    while (end > 0) {
        const start = if (std.mem.lastIndexOfScalar(u8, text[0..end], '\n')) |index| index + 1 else 0;
        const line = text[start..end];
        if (!isLegacyBashNotice(line)) break;
        end = trimTrailingEmptyLines(text[0..start]).len;
    }
    return text[0..end];
}

fn isLegacyBashNotice(line: []const u8) bool {
    return (std.mem.startsWith(u8, line, "[Showing ") and std.mem.endsWith(u8, line, "]")) or
        (std.mem.startsWith(u8, line, "[Command exited with code ") and std.mem.endsWith(u8, line, "]")) or
        std.mem.eql(u8, line, "[Command timed out]") or
        std.mem.eql(u8, line, "[bash output limit exceeded]") or
        std.mem.eql(u8, line, "[Command aborted]") or
        (std.mem.startsWith(u8, line, "[Command killed by signal ") and std.mem.endsWith(u8, line, "]")) or
        (std.mem.startsWith(u8, line, "[Command stopped by signal ") and std.mem.endsWith(u8, line, "]")) or
        (std.mem.startsWith(u8, line, "[Command exited with unknown status ") and std.mem.endsWith(u8, line, "]"));
}

fn writeBashStatus(writer: *std.Io.Writer, object: std.json.ObjectMap, wrote_any: *bool) !void {
    if (jsonInt(object, "exitCode")) |code| {
        if (code == 0) return;
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command exited with code {d}", .{code});
        return;
    }
    if (jsonBool(object, "timedOut") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("Command timed out");
        return;
    }
    if (jsonBool(object, "outputLimitExceeded") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("bash output limit exceeded");
        return;
    }
    if (jsonBool(object, "cancelled") orelse false) {
        try writeStatusSeparator(writer, wrote_any);
        try writer.writeAll("Command aborted");
        return;
    }
    if (jsonInt(object, "signal")) |signal| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command killed by signal {d}", .{signal});
        return;
    }
    if (jsonInt(object, "stopped")) |signal| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command stopped by signal {d}", .{signal});
        return;
    }
    if (jsonInt(object, "unknown")) |code| {
        try writeStatusSeparator(writer, wrote_any);
        try writer.print("Command exited with unknown status {d}", .{code});
    }
}

fn writeStatusSeparator(writer: *std.Io.Writer, wrote_any: *bool) !void {
    if (wrote_any.*) try writer.writeByte('\n');
    wrote_any.* = true;
}

fn jsonObject(object: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const value = object.get(key) orelse return null;
    return if (value == .object) value.object else null;
}

fn jsonInt(object: std.json.ObjectMap, key: []const u8) ?i64 {
    const value = object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn jsonBool(object: std.json.ObjectMap, key: []const u8) ?bool {
    const value = object.get(key) orelse return null;
    return if (value == .bool) value.bool else null;
}

fn appendItemTextNormalized(writer: *vm.Writer, allocator: std.mem.Allocator, item_id: u64, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var rest = text;
    while (rest.len > 0) {
        const chunk = normalizedOutputChunk(&buffer, rest);
        if (chunk.consumed == 0) return;
        if (chunk.text.len > 0) try writer.appendItemText(allocator, item_id, chunk.text);
        rest = rest[chunk.consumed..];
    }
}

fn replaceItemTextNormalized(writer: *vm.Writer, allocator: std.mem.Allocator, item_id: u64, text: []const u8) !void {
    var buffer: [vm.tool_output_bytes_max + 1]u8 = undefined;
    const chunk = normalizedOutputChunk(&buffer, text);
    try writer.replaceItemText(allocator, item_id, chunk.text);
}

const NormalizedChunk = struct {
    text: []const u8,
    consumed: usize,
};

fn normalizedOutputChunk(buffer: []u8, text: []const u8) NormalizedChunk {
    var out: usize = 0;
    var consumed: usize = 0;
    for (text) |byte| {
        if (byte == '\r') {
            consumed += 1;
            continue;
        }
        const replacement = if (byte == '\t') "   " else text[consumed .. consumed + 1];
        if (out + replacement.len > buffer.len) break;
        @memcpy(buffer[out..][0..replacement.len], replacement);
        out += replacement.len;
        consumed += 1;
    }
    return .{ .text = buffer[0..out], .consumed = consumed };
}

fn setToolResultMeta(writer: *vm.Writer, item_id: u64, is_error: bool, details: ?std.json.Value) void {
    if (findItem(writer, item_id)) |item| if (item.tool) |*tool| {
        tool.is_error = is_error;
        setDetailsJson(tool, details);
        bumpItem(item);
        writer.touched = true;
    };
}

fn updateToolTitle(
    writer: *vm.Writer,
    item_id: u64,
    name: []const u8,
    arguments: std.json.Value,
    home_dir: ?[]const u8,
) void {
    var title_buffer: [(vm.ToolMeta{}).title.bytes.len]u8 = undefined;
    var compact_buffer: [(vm.ToolMeta{}).compact_title.bytes.len]u8 = undefined;
    const title = formatToolTitle(&title_buffer, name, arguments, home_dir);
    const compact_title = formatCompactToolTitle(&compact_buffer, name, arguments);
    if (findItem(writer, item_id)) |item| if (item.tool) |*tool| {
        var arguments_buffer: [2048]u8 = undefined;
        const arguments_json = stringifyJson(&arguments_buffer, arguments);
        if (tool.title.eql(title) and tool.compact_title.eql(compact_title) and tool.arguments_json.eql(arguments_json)) return;
        tool.title.set(title);
        tool.compact_title.set(compact_title);
        tool.arguments_json.set(arguments_json);
        bumpItem(item);
        writer.touched = true;
    };
}

const ToolKind = enum { bash, read, edit, write, custom };

fn toolKind(name: []const u8) ToolKind {
    if (std.mem.eql(u8, name, "bash")) return .bash;
    if (std.mem.eql(u8, name, "read")) return .read;
    if (std.mem.eql(u8, name, "edit")) return .edit;
    if (std.mem.eql(u8, name, "write")) return .write;
    return .custom;
}

fn formatToolTitle(
    buffer: []u8,
    name: []const u8,
    arguments: std.json.Value,
    home_dir: ?[]const u8,
) []const u8 {
    var title: TitleBuilder = .{ .buffer = buffer, .home_dir = home_dir };
    switch (toolKind(name)) {
        .bash => {
            title.add("$ ");
            title.add(argStringOrEllipsis(arguments, "command"));
            if (argInt(arguments, "timeout")) |timeout| {
                title.add(" (timeout ");
                title.addInt(timeout);
                title.add("s)");
            }
        },
        .read => {
            title.add("read ");
            title.addPath(argString(arguments, "file_path") orelse argStringOrEllipsis(arguments, "path"));
            addReadLineRange(&title, arguments);
        },
        .edit, .write => {
            title.add(name);
            title.add(" ");
            title.addPath(argString(arguments, "file_path") orelse argStringOrEllipsis(arguments, "path"));
        },
        .custom => return "",
    }
    return title.slice();
}

fn formatCompactToolTitle(buffer: []u8, name: []const u8, arguments: std.json.Value) []const u8 {
    if (toolKind(name) != .read) return "";
    const classification = compactReadClassification(arguments) orelse return "";
    var title: TitleBuilder = .{ .buffer = buffer };
    switch (classification.kind) {
        .skill => {
            title.add("[skill] ");
            title.add(classification.label);
        },
        .docs => {
            title.add("read docs ");
            title.add(classification.label);
        },
        .resource => {
            title.add("read resource ");
            title.add(classification.label);
        },
    }
    addReadLineRange(&title, arguments);
    title.add(" (ctrl+o to expand)");
    return title.slice();
}

const CompactReadKind = enum { skill, docs, resource };

const CompactReadClassification = struct {
    kind: CompactReadKind,
    label: []const u8,
};

fn compactReadClassification(arguments: std.json.Value) ?CompactReadClassification {
    const path = argString(arguments, "file_path") orelse argString(arguments, "path") orelse return null;
    const leaf = std.fs.path.basename(path);
    if (std.mem.eql(u8, leaf, "SKILL.md")) {
        const parent = if (std.fs.path.dirname(path)) |dirname| std.fs.path.basename(dirname) else leaf;
        return .{ .kind = .skill, .label = if (parent.len > 0) parent else leaf };
    }
    if (isCompactResourceLeaf(leaf)) return .{ .kind = .resource, .label = path };
    if (!std.fs.path.isAbsolute(path) and isCompactDocsPath(path)) return .{ .kind = .docs, .label = path };
    return null;
}

fn isCompactResourceLeaf(leaf: []const u8) bool {
    return std.mem.eql(u8, leaf, "AGENTS.md") or
        std.mem.eql(u8, leaf, "AGENTS.MD") or
        std.mem.eql(u8, leaf, "CLAUDE.md") or
        std.mem.eql(u8, leaf, "CLAUDE.MD");
}

fn isCompactDocsPath(path: []const u8) bool {
    return std.mem.eql(u8, path, "README.md") or
        std.mem.startsWith(u8, path, "docs/") or
        std.mem.startsWith(u8, path, "examples/");
}

const TitleBuilder = struct {
    buffer: []u8,
    home_dir: ?[]const u8 = null,
    len: usize = 0,

    fn add(self: *TitleBuilder, text: []const u8) void {
        for (text) |byte| {
            if (self.len >= self.buffer.len) return;
            self.buffer[self.len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
            self.len += 1;
        }
    }

    fn addInt(self: *TitleBuilder, value: i64) void {
        var digits: [24]u8 = undefined;
        self.add(std.fmt.bufPrint(&digits, "{d}", .{value}) catch return);
    }

    fn addPath(self: *TitleBuilder, path: []const u8) void {
        const suffix = homePathSuffix(path, self.home_dir) orelse {
            self.add(path);
            return;
        };
        self.add("~");
        self.add(suffix);
    }

    fn slice(self: *const TitleBuilder) []const u8 {
        var end = self.len;
        while (end > 0 and !std.unicode.utf8ValidateSlice(self.buffer[0..end])) end -= 1;
        return self.buffer[0..end];
    }
};

fn homePathSuffix(path: []const u8, home_dir_raw: ?[]const u8) ?[]const u8 {
    const home_raw = home_dir_raw orelse return null;
    const home = trimTrailingPathSeparators(home_raw);
    if (home.len == 0 or !std.mem.startsWith(u8, path, home)) return null;
    if (path.len == home.len) return "";
    if (!isPathSeparator(path[home.len])) return null;
    return path[home.len..];
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) end -= 1;
    return path[0..end];
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn addReadLineRange(title: *TitleBuilder, arguments: std.json.Value) void {
    const offset = argPositiveInt(arguments, "offset");
    const limit = argPositiveInt(arguments, "limit");
    if (offset == null and limit == null) return;
    const start = offset orelse 1;
    title.add(":");
    title.addInt(start);
    if (limit) |count| {
        title.add("-");
        title.addInt(start +| count -| 1);
    }
}

fn argString(arguments: std.json.Value, key: []const u8) ?[]const u8 {
    if (arguments != .object) return null;
    const value = arguments.object.get(key) orelse return null;
    return if (value == .string and value.string.len > 0) value.string else null;
}

fn argStringOrEllipsis(arguments: std.json.Value, key: []const u8) []const u8 {
    return argString(arguments, key) orelse "...";
}

fn argPositiveInt(arguments: std.json.Value, key: []const u8) ?i64 {
    const value = argInt(arguments, key) orelse return null;
    return if (value > 0) value else null;
}

fn argInt(arguments: std.json.Value, key: []const u8) ?i64 {
    if (arguments != .object) return null;
    const value = arguments.object.get(key) orelse return null;
    return if (value == .integer) value.integer else null;
}

fn setDetailsJson(tool: *vm.ToolMeta, details: ?std.json.Value) void {
    const value = details orelse {
        tool.details_json.len = 0;
        return;
    };
    var buffer: [2048]u8 = undefined;
    tool.details_json.set(stringifyJson(&buffer, value));
}

fn stringifyJson(buffer: []u8, value: std.json.Value) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    std.json.Stringify.value(value, .{}, &writer) catch |err| switch (err) {
        error.WriteFailed => {},
    };
    return writer.buffered();
}

fn compactionTrigger(reason: client_protocol.CompactionReason) vm.CompactionTrigger {
    return switch (reason) {
        .manual => .manual,
        .threshold, .overflow => .context_overflow,
    };
}

fn compactionReason(reason: client_protocol.CompactionReason) vm.CompactionReason {
    return switch (reason) {
        .manual => .manual,
        .threshold => .threshold,
        .overflow => .overflow,
    };
}

fn noticeFailureCategory(category: ai.OperationalFailure.Category) vm.NoticeFailureCategory {
    return switch (category) {
        .auth_missing => .auth_missing,
        .auth_rejected => .auth_rejected,
        .rate_limited => .rate_limited,
        .context_overflow => .context_overflow,
        .provider_unavailable => .provider_unavailable,
        .transport => .transport,
        .malformed_response => .malformed_response,
        .canceled => .canceled,
        .unknown => .unknown,
    };
}

fn parseEntryId(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 16) catch null;
}

fn nowMs() i64 {
    return @intCast(@divFloor(@import("../runtime/root.zig").SharedMutexHoldTimer.start().start_ns, std.time.ns_per_ms));
}

fn argContentString(arguments: std.json.Value) ?[]const u8 {
    if (arguments != .object) return null;
    const value = arguments.object.get("content") orelse return null;
    return switch (value) {
        .string => |text| text,
        else => null,
    };
}

/// Prefix of `text` holding at most `count` lines, excluding the newline
/// that would start line count+1. Monotone under append-only growth.
fn firstLines(text: []const u8, count: usize) []const u8 {
    var lines: usize = 0;
    for (text, 0..) |ch, i| {
        if (ch == '\n') {
            lines += 1;
            if (lines == count) return text[0..i];
        }
    }
    return text;
}

fn countLines(text: []const u8) usize {
    if (text.len == 0) return 0;
    var lines: usize = 1;
    for (text) |ch| {
        if (ch == '\n') lines += 1;
    }
    return lines;
}

test "edit tool end publishes diff body and details json" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var details = try std.json.parseFromSlice(std.json.Value, gpa, "{\"diff\":\"--- a/file\\n+++ b/file\"}", .{});
    defer details.deinit();
    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = "Edited file" } }};

    try drain.agentEvent(.{ .tool_execution_end = .{
        .tool_call_id = "call-edit",
        .tool_name = "edit",
        .result = .{ .content = &content, .details = details.value },
        .is_error = false,
    } });

    const item = &model.transcript.items.items[0];
    try std.testing.expectEqualStrings("--- a/file\n+++ b/file", item.text.items);
    try std.testing.expect(item.tool != null);
    try std.testing.expect(std.mem.indexOf(u8, item.tool.?.details_json.slice(), "\"diff\"") != null);
}

test "settled tool result body joins text blocks and image fallback" {
    const gpa = std.testing.allocator;
    const content = [_]ai.ToolResultContent{
        .{ .text = .{ .text = "Read image file [image/png]\n" } },
        .{ .image = .{ .data = "base64", .mime_type = "image/png" } },
        .{ .text = .{ .text = "tail" } },
    };
    const text = try toolResultBody(gpa, "read", false, &content, null);
    defer gpa.free(text);

    try std.testing.expectEqualStrings("Read image file [image/png]\n[Image: image/png]\ntail", text);
}

test "settled bash result strips legacy notices and appends status from details" {
    const gpa = std.testing.allocator;
    var details = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"exitCode\":1,\"truncation\":{\"truncated\":true,\"truncatedBy\":\"lines\"," ++
            "\"outputLines\":5,\"totalLines\":100,\"outputBytes\":16,\"maxBytes\":51200}}",
        .{},
    );
    defer details.deinit();
    const content = [_]ai.ToolResultContent{.{ .text = .{
        .text = "line 96\nline 100\n\n[Showing lines 96-100 of 100 (50KB limit)]\n\nCommand exited with code 1",
    } }};
    const text = try toolResultBody(gpa, "bash", true, &content, details.value);
    defer gpa.free(text);

    try std.testing.expectEqualStrings("line 96\nline 100\nCommand exited with code 1", text);
}

test "settled read result moves continuation notices out of body" {
    const gpa = std.testing.allocator;
    var details = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"nextOffset\":4,\"truncation\":{\"truncated\":false,\"userLimit\":true," ++
            "\"remainingLines\":1,\"outputBytes\":9}}",
        .{},
    );
    defer details.deinit();
    const content = [_]ai.ToolResultContent{.{ .text = .{
        .text = "two\nthree\n\n[1 more lines in file. Use offset=4 to continue.]",
    } }};
    const text = try toolResultBody(gpa, "read", false, &content, details.value);
    defer gpa.free(text);

    try std.testing.expectEqualStrings("two\nthree", text);
}

test "tool preview preserves prior thinking order" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var args = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer args.deinit();
    const content = [_]ai.AssistantContent{
        ai.faux.thinking("Planning bash tool usage"),
        ai.faux.toolCall("call-b", "bash", args.value),
    };
    const assistant = ai.faux.assistantMessage(&content, .{});
    var writer = model.lockWriter();
    try drain.toolPreview(&writer, assistant, 1, false);
    try drain.replaceAssistantFinal(&writer, assistant);
    writer.finish();

    try std.testing.expectEqual(vm.Item.Kind.thinking, model.transcript.items.items[0].kind);
    try std.testing.expectEqual(vm.Item.Kind.tool, model.transcript.items.items[1].kind);
    try std.testing.expectEqualStrings("Planning bash tool usage", model.transcript.items.items[0].text.items);
}

test "settled write success keeps preview body and error flag is retained" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"f.txt\",\"content\":\"one\\n\\n\"}", .{});
    defer args.deinit();
    const call_content = [_]ai.AssistantContent{ai.faux.toolCall("call-w", "write", args.value)};
    const assistant = ai.faux.assistantMessage(&call_content, .{});
    var preview = model.lockWriter();
    try drain.toolPreview(&preview, assistant, 0, true);
    preview.finish();
    try std.testing.expectEqualStrings("one", model.transcript.items.items[0].text.items);

    var details = try std.json.parseFromSlice(std.json.Value, gpa, "{\"bytesWritten\":5,\"path\":\"f.txt\"}", .{});
    defer details.deinit();
    const result_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "Wrote file" } }};
    try drain.agentEvent(.{ .tool_execution_end = .{
        .tool_call_id = "call-w",
        .tool_name = "write",
        .result = .{ .content = &result_content, .details = details.value },
        .is_error = false,
    } });

    try std.testing.expectEqualStrings("one", model.transcript.items.items[0].text.items);
    try std.testing.expect(!model.transcript.items.items[0].tool.?.is_error);
}

test "tool start only clears write body and footer" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var write_args = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"path\":\"f.txt\",\"content\":\"l1\\nl2\\nl3\\nl4\\nl5\\nl6\\nl7\\nl8\\nl9\\nl10\\nl11\"}",
        .{},
    );
    defer write_args.deinit();
    const write_call = [_]ai.AssistantContent{ai.faux.toolCall("call-w", "write", write_args.value)};
    const write_assistant = ai.faux.assistantMessage(&write_call, .{});
    var preview = model.lockWriter();
    try drain.toolPreview(&preview, write_assistant, 0, true);
    preview.finish();
    try std.testing.expectEqualStrings("Showing lines 1-10 of 11", model.transcript.items.items[0].footer.slice());

    try drain.agentEvent(.{ .tool_execution_start = .{
        .tool_call_id = "call-w",
        .tool_name = "write",
        .args = write_args.value,
    } });
    try std.testing.expectEqualStrings("", model.transcript.items.items[0].text.items);
    try std.testing.expectEqualStrings("", model.transcript.items.items[0].footer.slice());

    var bash_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"pwd\"}", .{});
    defer bash_args.deinit();
    const bash_content = [_]ai.ToolResultContent{.{ .text = .{ .text = "already streamed" } }};
    try drain.agentEvent(.{ .tool_execution_update = .{
        .tool_call_id = "call-b",
        .tool_name = "bash",
        .args = bash_args.value,
        .partial_result = .{ .content = &bash_content },
    } });
    try drain.agentEvent(.{ .tool_execution_start = .{
        .tool_call_id = "call-b",
        .tool_name = "bash",
        .args = bash_args.value,
    } });
    try std.testing.expectEqualStrings("already streamed", model.transcript.items.items[1].text.items);
}

test "settled tool error flag is retained" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = "nope" } }};
    try drain.agentEvent(.{ .tool_execution_end = .{
        .tool_call_id = "call-read",
        .tool_name = "read",
        .result = .{ .content = &content },
        .is_error = true,
    } });

    try std.testing.expect(model.transcript.items.items[0].tool.?.is_error);
}

test "tool preview derives bash and write titles from arguments" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var bash_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"rg foo\"}", .{});
    defer bash_args.deinit();
    const bash_content = [_]ai.AssistantContent{ai.faux.toolCall("call-b", "bash", bash_args.value)};
    const bash_assistant = ai.faux.assistantMessage(&bash_content, .{});

    var first = model.lockWriter();
    try drain.toolPreview(&first, bash_assistant, 0, true);
    first.finish();
    try std.testing.expectEqualStrings("$ rg foo", model.transcript.items.items[0].tool.?.title.slice());
    try std.testing.expectEqualStrings("bash", model.transcript.items.items[0].tool.?.name.slice());
    try std.testing.expectEqualStrings("", model.transcript.items.items[0].text.items);

    var write_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"src/file.zig\"}", .{});
    defer write_args.deinit();
    const write_content = [_]ai.AssistantContent{ai.faux.toolCall("call-w", "write", write_args.value)};
    const write_assistant = ai.faux.assistantMessage(&write_content, .{});

    var second = model.lockWriter();
    try drain.toolPreview(&second, write_assistant, 0, true);
    second.finish();
    try std.testing.expectEqualStrings("write src/file.zig", model.transcript.items.items[1].tool.?.title.slice());
    try std.testing.expectEqualStrings("write", model.transcript.items.items[1].tool.?.name.slice());
}

test "tool title builder mirrors pre-cutover goldens" {
    const gpa = std.testing.allocator;
    var buffer: [(vm.ToolMeta{}).title.bytes.len]u8 = undefined;

    var bash_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"pwd\",\"timeout\":5}", .{});
    defer bash_args.deinit();
    try std.testing.expectEqualStrings("$ pwd (timeout 5s)", formatToolTitle(&buffer, "bash", bash_args.value, null));

    var read_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"src/main.zig\",\"offset\":10,\"limit\":20}", .{});
    defer read_args.deinit();
    try std.testing.expectEqualStrings("read src/main.zig:10-29", formatToolTitle(&buffer, "read", read_args.value, null));

    var home_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"/Users/me/repo/src/main.zig\"}", .{});
    defer home_args.deinit();
    try std.testing.expectEqualStrings("read ~/repo/src/main.zig", formatToolTitle(&buffer, "read", home_args.value, "/Users/me"));

    var home_root_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"/Users/me\"}", .{});
    defer home_root_args.deinit();
    try std.testing.expectEqualStrings("read ~", formatToolTitle(&buffer, "read", home_root_args.value, "/Users/me"));

    var empty_args = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer empty_args.deinit();
    try std.testing.expectEqualStrings("$ ...", formatToolTitle(&buffer, "bash", empty_args.value, null));
    try std.testing.expectEqualStrings("", formatToolTitle(&buffer, "mystery", empty_args.value, null));

    var multiline_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"echo a\\necho b\"}", .{});
    defer multiline_args.deinit();
    try std.testing.expectEqualStrings("$ echo a echo b", formatToolTitle(&buffer, "bash", multiline_args.value, null));
}

test "compact tool titles mirror pre-cutover read headers" {
    const gpa = std.testing.allocator;
    var buffer: [(vm.ToolMeta{}).compact_title.bytes.len]u8 = undefined;

    var skill_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\".zi/skills/review/SKILL.md\",\"limit\":10}", .{});
    defer skill_args.deinit();
    try std.testing.expectEqualStrings(
        "[skill] review:1-10 (ctrl+o to expand)",
        formatCompactToolTitle(&buffer, "read", skill_args.value),
    );

    var docs_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"docs/themes.md\"}", .{});
    defer docs_args.deinit();
    try std.testing.expectEqualStrings(
        "read docs docs/themes.md (ctrl+o to expand)",
        formatCompactToolTitle(&buffer, "read", docs_args.value),
    );

    var resource_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"AGENTS.md\"}", .{});
    defer resource_args.deinit();
    try std.testing.expectEqualStrings(
        "read resource AGENTS.md (ctrl+o to expand)",
        formatCompactToolTitle(&buffer, "read", resource_args.value),
    );

    var regular_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"path\":\"src/main.zig\"}", .{});
    defer regular_args.deinit();
    try std.testing.expectEqualStrings("", formatCompactToolTitle(&buffer, "read", regular_args.value));
}

test "tool output normalization removes carriage returns and expands tabs" {
    var buffer: [16]u8 = undefined;
    const chunk = normalizedOutputChunk(&buffer, "a\tb\rc");
    try std.testing.expectEqualStrings("a   bc", chunk.text);
    try std.testing.expectEqual(@as(usize, 5), chunk.consumed);

    const bounded = normalizedOutputChunk(buffer[0..5], "a\tb\tc");
    try std.testing.expectEqualStrings("a   b", bounded.text);
    try std.testing.expectEqual(@as(usize, 3), bounded.consumed);
}

test "live tool update output is normalized" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var args = try std.json.parseFromSlice(std.json.Value, gpa, "{}", .{});
    defer args.deinit();
    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = "a\tb\rc" } }};
    try drain.agentEvent(.{ .tool_execution_update = .{
        .tool_call_id = "call-b",
        .tool_name = "bash",
        .args = args.value,
        .partial_result = .{ .content = &content },
    } });

    try std.testing.expectEqualStrings("a   bc", model.transcript.items.items[0].text.items);
}

test "tool preview title updates after throttle window" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();
    drain.test_now_ms = 0;

    var first_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"rg\"}", .{});
    defer first_args.deinit();
    const first_content = [_]ai.AssistantContent{ai.faux.toolCall("call-b", "bash", first_args.value)};
    const first_assistant = ai.faux.assistantMessage(&first_content, .{});

    var first = model.lockWriter();
    try drain.toolPreview(&first, first_assistant, 0, false);
    first.finish();
    try std.testing.expectEqualStrings("$ rg", model.transcript.items.items[0].tool.?.title.slice());

    var grown_args = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"rg foo\"}", .{});
    defer grown_args.deinit();
    const grown_content = [_]ai.AssistantContent{ai.faux.toolCall("call-b", "bash", grown_args.value)};
    const grown_assistant = ai.faux.assistantMessage(&grown_content, .{});

    drain.test_now_ms = preview_rebuild_interval_ms - 1;
    var throttled = model.lockWriter();
    try drain.toolPreview(&throttled, grown_assistant, 0, false);
    throttled.finish();
    try std.testing.expectEqualStrings("$ rg", model.transcript.items.items[0].tool.?.title.slice());

    drain.test_now_ms = preview_rebuild_interval_ms;
    var rebuilt = model.lockWriter();
    try drain.toolPreview(&rebuilt, grown_assistant, 0, false);
    rebuilt.finish();
    try std.testing.expectEqualStrings("$ rg foo", model.transcript.items.items[0].tool.?.title.slice());
}

test "tool preview rebuilds are throttled to the interval" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();
    drain.test_now_ms = 0;

    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "{\"command\":\"ls\"}", .{});
    defer parsed.deinit();
    const content = [_]ai.AssistantContent{ai.faux.toolCall("call-1", "bash", parsed.value)};
    const assistant = ai.faux.assistantMessage(&content, .{});

    var rebuilds: usize = 0;
    var last_rev: u32 = 0;
    var step: usize = 0;
    while (step < 200) : (step += 1) {
        drain.test_now_ms = @intCast(step / 2); // 200 deltas across 100ms
        var writer = model.lockWriter();
        try drain.toolPreview(&writer, assistant, 0, false);
        writer.finish();
        const rev = model.transcript.items.items[0].rev;
        if (rev != last_rev) {
            rebuilds += 1;
            last_rev = rev;
        }
    }
    // Stable args mutate only once; throttled rebuilds do not produce duplicate view churn.
    try std.testing.expectEqual(@as(usize, 1), rebuilds);
}

test "write preview caps visible lines and grows the count footer" {
    const gpa = std.testing.allocator;
    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = EngineDrain.init(gpa, &model);
    defer drain.deinit();
    drain.test_now_ms = 0;

    var parsed = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"path\":\"f.txt\",\"content\":\"l1\\nl2\\nl3\\nl4\\nl5\\nl6\\nl7\\nl8\\nl9\\nl10\\nl11\\nl12\"}",
        .{},
    );
    defer parsed.deinit();
    const content = [_]ai.AssistantContent{ai.faux.toolCall("call-w", "write", parsed.value)};
    const assistant = ai.faux.assistantMessage(&content, .{});

    var writer = model.lockWriter();
    try drain.toolPreview(&writer, assistant, 0, true);
    writer.finish();

    const item = &model.transcript.items.items[0];
    try std.testing.expectEqualStrings("l1\nl2\nl3\nl4\nl5\nl6\nl7\nl8\nl9\nl10", item.text.items);
    try std.testing.expectEqualStrings("Showing lines 1-10 of 12", item.footer.slice());
    const capped_len = item.text.items.len;

    var grown = try std.json.parseFromSlice(
        std.json.Value,
        gpa,
        "{\"path\":\"f.txt\",\"content\":\"l1\\nl2\\nl3\\nl4\\nl5\\nl6\\nl7\\nl8\\nl9\\nl10\\nl11\\nl12\\nl13\\nl14\\nl15\\nl16\\nl17\\nl18\\nl19\\nl20\"}",
        .{},
    );
    defer grown.deinit();
    const grown_content = [_]ai.AssistantContent{ai.faux.toolCall("call-w", "write", grown.value)};
    const grown_assistant = ai.faux.assistantMessage(&grown_content, .{});

    drain.test_now_ms = 100;
    var second = model.lockWriter();
    try drain.toolPreview(&second, grown_assistant, 0, true);
    second.finish();

    try std.testing.expectEqual(capped_len, model.transcript.items.items[0].text.items.len);
    try std.testing.expectEqualStrings("Showing lines 1-10 of 20", model.transcript.items.items[0].footer.slice());
}
