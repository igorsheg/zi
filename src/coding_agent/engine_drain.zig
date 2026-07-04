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

    pub fn compactionEnd(self: *EngineDrain, aborted: bool, message: ?[]const u8) void {
        if (aborted) self.notice(.warn, .operation_failed, message orelse "compaction aborted");
    }

    pub fn retryStart(self: *EngineDrain, attempt: usize, delay_ms: u64, reason: []const u8, _: ?ai.OperationalFailure.Category) void {
        var writer = self.view_model.lockWriter();
        const bounded = vm.BoundedText(256).init(reason);
        writer.vm.op.phase = .{ .retry_wait = .{
            .until_ms = nowMs() + @as(i64, @intCast(delay_ms)),
            .attempt = @intCast(attempt),
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
        writer.vm.history.state = .closed;
        writer.vm.history.rev +%= 1;
        if (writer.vm.history.rev == 0) writer.vm.history.rev = 1;
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
                if (!cursor.streams_output) try writer.replaceItemText(self.allocator, cursor.item_id, toolResultText(tool.content));
            },
            .custom => |custom| self.pending.custom = try writer.addItem(self.allocator, .system_notice, .streaming, custom.kind, null),
        }
    }

    fn ensureAssistantItems(self: *EngineDrain, writer: *vm.Writer, assistant: ai.AssistantMessage) !void {
        for (assistant.content) |content| switch (content) {
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
        const call = assistant.content[index].tool_call;
        const cursor = try self.ensureTool(writer, call.id, call.name);
        const now = self.currentMs();
        if (!final) {
            if (cursor.last_preview_ms) |last| {
                if (now - last < preview_rebuild_interval_ms) return;
            }
        }
        cursor.last_preview_ms = now;
        if (std.mem.eql(u8, call.name, "write")) {
            try self.writePreview(writer, cursor, call.arguments);
            return;
        }
        const preview = try jsonPreview(self.allocator, call.arguments);
        defer self.allocator.free(preview);
        try writer.replaceItemText(self.allocator, cursor.item_id, preview);
    }

    /// Write-tool call preview: the first `lines_max` content lines stream
    /// as append-only item text (reader sampling stays O(delta)); past the
    /// cap only the "Showing lines" footer grows.
    fn writePreview(self: *EngineDrain, writer: *vm.Writer, cursor: *ToolCursor, arguments: std.json.Value) !void {
        const content = argContentString(arguments) orelse return;
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
        try writer.replaceItemText(self.allocator, cursor.item_id, "");
        if (findItem(writer, cursor.item_id)) |item| {
            if (item.tool) |*tool| tool.started_ms = cursor.started_ms;
            bumpItem(item);
            writer.touched = true;
        }
    }

    fn toolUpdate(self: *EngineDrain, writer: *vm.Writer, payload: agent_mod.AgentEvent.ToolExecutionUpdate) !void {
        const cursor = try self.ensureTool(writer, payload.tool_call_id, payload.tool_name);
        try writer.appendItemText(self.allocator, cursor.item_id, toolResultText(payload.partial_result.content));
    }

    fn toolEnd(self: *EngineDrain, writer: *vm.Writer, payload: agent_mod.AgentEvent.ToolExecutionEnd) !void {
        const cursor = try self.ensureTool(writer, payload.tool_call_id, payload.tool_name);
        if (!cursor.streams_output) try writer.replaceItemText(self.allocator, cursor.item_id, toolResultText(payload.result.content));
        if (findItem(writer, cursor.item_id)) |item| {
            if (item.tool) |*tool| tool.duration_ms = if (cursor.started_ms) |start| @intCast(@max(nowMs() - start, 0)) else 0;
            bumpItem(item);
            writer.touched = true;
        }
    }

    fn ensureTool(self: *EngineDrain, writer: *vm.Writer, id: []const u8, name: []const u8) !*ToolCursor {
        if (self.findTool(id)) |cursor| return cursor;
        var meta: vm.ToolMeta = .{};
        meta.tool_call_id.set(id);
        meta.name.set(name);
        meta.title.set(name);
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

fn jsonPreview(allocator: std.mem.Allocator, value: std.json.Value) ![]u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try std.json.Stringify.value(value, .{}, &writer.writer);
    return writer.toOwnedSlice();
}

fn compactionTrigger(reason: client_protocol.CompactionReason) vm.CompactionTrigger {
    return switch (reason) {
        .manual => .manual,
        .threshold, .overflow => .context_overflow,
    };
}

fn parseEntryId(text: []const u8) ?u64 {
    return std.fmt.parseInt(u64, text, 10) catch null;
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
    // First build plus at most one rebuild per 32ms window: 100/32 + 2.
    try std.testing.expect(rebuilds <= 5);
    try std.testing.expect(rebuilds >= 2);
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
