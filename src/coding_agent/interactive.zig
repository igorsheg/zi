const std = @import("std");
const runtime = @import("../runtime/root.zig");
const agent_mod = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const tui = @import("../tui/root.zig");
const AgentSessionRuntimeHost = @import("AgentSessionRuntimeHost.zig");
const AgentSession = @import("AgentSession.zig");
const session_events = @import("session_events.zig");
const session_history_snapshot = @import("session_history_snapshot.zig");
const tool_registry = @import("tool_registry.zig");
const sdk = @import("sdk.zig");

pub const Options = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    resume_session_file: ?[]const u8 = null,
    resume_latest: bool = false,
    initial_prompt: ?[]const u8 = null,
};

const effect_count_max = tui.product.terminal_loop.effects_per_step_max;
const frame_interval_ms: u64 = 16;
const frame_interval_ns: i128 = frame_interval_ms * std.time.ns_per_ms;
const input_reads_per_tick_max = 1;
const prompt_progress_per_tick_max = 64;
const public_events_per_tick_max = 16;
const render_attempts_per_tick_max = 1;
const shutdown_drain_ticks_max = 60;
const pending_tool_outputs_max = 32;
const pending_tool_id_bytes_max = 128;
const pending_tool_output_bytes_max = tui.product.transcript.append_size_bytes_max;
const tool_call_mirrors_max = 32;
const tool_title_bytes_max = 512;
const model_slot_owner: tui.product.SlotOwnerId = 1;
const model_slot_id: tui.product.SlotContributionId = 1;
const status_owner_run: tui.product.SlotOwnerId = 2;
const status_id_working: tui.product.SlotContributionId = 1;
const status_owner_policy: tui.product.SlotOwnerId = 3;
const status_id_compaction: tui.product.SlotContributionId = 1;
const status_id_retry: tui.product.SlotContributionId = 2;
const confirm_id_start: tui.product.ModalId = 1;

fn frameDue(now_ns: i128, last_render_ns: ?i128) bool {
    const last = last_render_ns orelse return true;
    return now_ns - last >= frame_interval_ns;
}

fn animationTick(now_ns: i128) u64 {
    if (now_ns <= 0) return 0;
    return @intCast(@divFloor(now_ns, frame_interval_ns));
}

const TranscriptAppend = tui.product.transcript.TranscriptAppend;

fn messageAppend(
    role: tui.product.transcript.TranscriptRole,
    text: []const u8,
    mode: tui.product.transcript.TranscriptAppendMode,
) TranscriptAppend {
    return .{ .message = .{ .role = role, .text = text, .mode = mode } };
}

fn statusAppend(level: tui.product.transcript.TranscriptStatusLevel, text: []const u8) TranscriptAppend {
    return .{ .status = .{ .level = level, .text = text } };
}

fn toolAppend(
    tool_call_id: []const u8,
    name: []const u8,
    status: tui.product.transcript.TranscriptToolStatus,
    title: []const u8,
    is_error: bool,
) TranscriptAppend {
    return .{ .tool = .{
        .tool_call_id = tool_call_id,
        .name = name,
        .presentation = toolPresentation(name),
        .status = if (is_error) .err else status,
        .body_mode = toolBodyMode(name),
        .title = title,
    } };
}

fn toolPresentation(name: []const u8) tui.product.transcript.TranscriptToolPresentation {
    if (std.mem.eql(u8, name, "bash")) return .command;
    if (std.mem.eql(u8, name, "read")) return .file;
    if (std.mem.eql(u8, name, "edit")) return .patch;
    if (std.mem.eql(u8, name, "write")) return .file;
    if (std.mem.eql(u8, name, "grep")) return .search;
    if (std.mem.eql(u8, name, "find")) return .directory;
    if (std.mem.eql(u8, name, "ls")) return .directory;
    return .generic;
}

fn toolBodyMode(name: []const u8) tui.product.transcript.TranscriptToolBodyMode {
    if (std.mem.eql(u8, name, "read") or
        std.mem.eql(u8, name, "edit")) return .hidden_on_success;
    return .visible;
}

fn tuiPresentation(
    presentation: tool_registry.ToolDisplayPresentation,
) tui.product.transcript.TranscriptToolPresentation {
    return switch (presentation) {
        .generic => .generic,
        .command => .command,
        .file => .file,
        .patch => .patch,
        .search => .search,
        .directory => .directory,
    };
}

fn tuiBodyMode(body_mode: tool_registry.ToolDisplayBodyMode) tui.product.transcript.TranscriptToolBodyMode {
    return switch (body_mode) {
        .visible => .visible,
        .hidden_on_success => .hidden_on_success,
    };
}

fn toolArgsPreview(tool_name: []const u8, args_value: std.json.Value) []const u8 {
    if (std.mem.eql(u8, tool_name, "bash")) return boundedArgString(args_value, "command");
    return switch (toolTitleShape(tool_name)) {
        .path => boundedArgString(args_value, "path"),
        .search => boundedPreferredArgTitle(args_value, "pattern", "path"),
        .find => boundedPreferredArgTitle(args_value, "path", "name"),
        .none => "",
    };
}

const ToolTitleShape = enum { none, path, search, find };

fn toolTitleShape(tool_name: []const u8) ToolTitleShape {
    if (std.mem.eql(u8, tool_name, "read") or
        std.mem.eql(u8, tool_name, "edit") or
        std.mem.eql(u8, tool_name, "write") or
        std.mem.eql(u8, tool_name, "ls")) return .path;
    if (std.mem.eql(u8, tool_name, "grep")) return .search;
    if (std.mem.eql(u8, tool_name, "find")) return .find;
    return .none;
}

fn boundedPreferredArgTitle(args_value: std.json.Value, first_key: []const u8, second_key: []const u8) []const u8 {
    if (args_value != .object) return "";
    const first = boundedArgString(args_value, first_key);
    const second = boundedArgString(args_value, second_key);
    if (first.len == 0) return second;
    if (second.len == 0) return first;
    return utf8Prefix(first, tool_title_bytes_max);
}

fn boundedArgString(args_value: std.json.Value, key: []const u8) []const u8 {
    if (args_value != .object) return "";
    const value = args_value.object.get(key) orelse return "";
    if (value != .string) return "";
    return utf8Prefix(value.string, tool_title_bytes_max);
}

const write_preview_lines_max = 10;

const WritePreview = struct {
    tool_call_id: []const u8,
    text: []const u8,
};

fn writePreviewFromMessageUpdate(update: agent_mod.AgentEvent.MessageUpdate, buffer: []u8) ?WritePreview {
    return switch (update.assistant_message_event) {
        .toolcall_start => |payload| writePreviewFromPartial(payload.content_index, payload.partial, buffer),
        .toolcall_delta => |payload| writePreviewFromPartial(payload.content_index, payload.partial, buffer),
        .toolcall_end => |payload| writePreviewFromToolCall(payload.tool_call, buffer),
        else => null,
    };
}

fn writePreviewFromPartial(content_index: usize, partial: ai.AssistantMessage, buffer: []u8) ?WritePreview {
    if (content_index >= partial.content.len) return null;
    const content = partial.content[content_index];
    if (content != .tool_call) return null;
    return writePreviewFromToolCall(content.tool_call, buffer);
}

fn writePreviewFromToolCall(tool_call: ai.ToolCall, buffer: []u8) ?WritePreview {
    if (!std.mem.eql(u8, tool_call.name, "write")) return null;
    const preview = writeContentPreview(tool_call.arguments, buffer) orelse return null;
    return .{ .tool_call_id = tool_call.id, .text = preview };
}

fn writeContentPreview(args_value: std.json.Value, buffer: []u8) ?[]const u8 {
    if (args_value != .object) return null;
    const value = args_value.object.get("content") orelse return null;
    if (value != .string) return null;
    const content = value.string;
    if (content.len == 0) return null;

    var writer: std.Io.Writer = .fixed(buffer);
    var lines = std.mem.splitScalar(u8, content, '\n');
    var written_lines: usize = 0;
    var total_lines: usize = 0;
    while (lines.next()) |line| {
        total_lines += 1;
        if (written_lines < write_preview_lines_max) {
            if (written_lines > 0) writer.writeByte('\n') catch return writer.buffered();
            writer.writeAll(line) catch return writer.buffered();
            written_lines += 1;
        }
    }
    if (content.len > 0 and content[content.len - 1] == '\n' and total_lines > 0) total_lines -= 1;
    if (total_lines > write_preview_lines_max) {
        writer.print(
            "\n... ({d} more lines, {d} total)",
            .{ total_lines - write_preview_lines_max, total_lines },
        ) catch return writer.buffered();
    } else {
        writer.print("\n({d} total lines)", .{total_lines}) catch return writer.buffered();
    }
    return writer.buffered();
}

fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

fn sanitizeTranscriptText(input: []const u8, buffer: []u8) []const u8 {
    var out_len: usize = 0;
    var index: usize = 0;
    while (index < input.len and out_len < buffer.len) {
        const byte = input[index];
        if (byte == 0x1b) {
            index = skipEscapeSequence(input, index);
            continue;
        }
        if (byte == '\n') {
            buffer[out_len] = byte;
            out_len += 1;
            index += 1;
            continue;
        }
        if (byte == '\t') {
            const spaces = @min(@as(usize, 4), buffer.len - out_len);
            @memset(buffer[out_len .. out_len + spaces], ' ');
            out_len += spaces;
            index += 1;
            continue;
        }
        if (byte < 0x20 or byte == 0x7f) {
            index += 1;
            continue;
        }
        if (byte == 0xc2 and index + 1 < input.len and input[index + 1] >= 0x80 and input[index + 1] <= 0x9f) {
            index = skipC1Control(input, index);
            continue;
        }
        const scalar_len = utf8ScalarLen(input[index..]);
        if (out_len + scalar_len > buffer.len) break;
        @memcpy(buffer[out_len .. out_len + scalar_len], input[index .. index + scalar_len]);
        out_len += scalar_len;
        index += scalar_len;
    }
    return buffer[0..out_len];
}

fn skipC1Control(input: []const u8, start: usize) usize {
    std.debug.assert(start + 1 < input.len);
    std.debug.assert(input[start] == 0xc2);
    const kind = input[start + 1];
    if (kind == 0x9b) return skipCsiPayload(input, start + 2);
    if (kind == 0x9d) return skipOscPayload(input, start + 2);
    return start + 2;
}

fn skipEscapeSequence(input: []const u8, start: usize) usize {
    std.debug.assert(start < input.len);
    std.debug.assert(input[start] == 0x1b);
    if (start + 1 >= input.len) return input.len;
    const kind = input[start + 1];
    if (kind == '[') return skipCsiPayload(input, start + 2);
    if (kind == ']') return skipOscPayload(input, start + 2);
    return @min(start + 2, input.len);
}

fn skipCsiPayload(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte >= 0x40 and byte <= 0x7e) return index + 1;
    }
    return input.len;
}

fn skipOscPayload(input: []const u8, start: usize) usize {
    var index = start;
    while (index < input.len) : (index += 1) {
        const byte = input[index];
        if (byte == 0x07) return index + 1;
        if (byte == 0x1b and index + 1 < input.len and input[index + 1] == '\\') return index + 2;
    }
    return input.len;
}

fn utf8ScalarLen(input: []const u8) usize {
    if (input.len == 0) return 0;
    const first = input[0];
    if (first < 0x80) return 1;
    const len: usize = if ((first & 0xe0) == 0xc0)
        2
    else if ((first & 0xf0) == 0xe0)
        3
    else if ((first & 0xf8) == 0xf0)
        4
    else
        1;
    if (len > input.len) return 1;
    if (!std.unicode.utf8ValidateSlice(input[0..len])) return 1;
    return len;
}

fn firstToolResultText(result: agent_mod.AgentToolResult) []const u8 {
    for (result.content) |content| {
        switch (content) {
            .text => |text| return text.text,
            .image => {},
        }
    }
    return "";
}

const TranscriptIngest = union(enum) {
    append: TranscriptAppend,
    tool_output_delta: struct {
        tool_call_id: []const u8,
        text: []const u8,
        dropped_head_bytes: usize = 0,
        dropped_head_lines: usize = 0,
    },
};

fn toolOutputAppend(tool_call_id: []const u8, text: []const u8) ?TranscriptIngest {
    if (text.len == 0) return null;
    return .{ .tool_output_delta = .{ .tool_call_id = tool_call_id, .text = text } };
}

fn shouldAppendFinalToolOutput(tool_name: []const u8, is_error: bool) bool {
    if (std.mem.eql(u8, tool_name, "bash")) return false;
    if (std.mem.eql(u8, tool_name, "write") and !is_error) return false;
    if (is_error) return true;
    return toolBodyMode(tool_name) == .visible;
}

fn toolCallAppend(
    content_index: usize,
    partial: ai.AssistantMessage,
) ?TranscriptIngest {
    if (content_index >= partial.content.len) return null;
    const content = partial.content[content_index];
    if (content != .tool_call) return null;
    const tool_call = content.tool_call;
    if (tool_call.id.len == 0) return null;
    return .{ .append = toolAppend(
        tool_call.id,
        tool_call.name,
        .pending,
        toolArgsPreview(tool_call.name, tool_call.arguments),
        false,
    ) };
}

fn transcriptAppendFromEvent(event: session_events.AgentSessionEvent) ?TranscriptIngest {
    return switch (event) {
        .agent_event => |agent_event| transcriptAppendFromAgentEvent(agent_event.event),
        .prompt_command => |payload| .{ .append = statusAppend(.info, payload.message.text) },
        .compaction_start => null,
        .compaction_end => |payload| compactionEndAppend(payload),
        .auto_retry_start => null,
        .auto_retry_end => |payload| autoRetryEndAppend(payload),
        .public_event_overflow => .{ .append = statusAppend(.warning, "public event overflow") },
        .queue_update, .session_info_changed => null,
    };
}

fn compactionEndAppend(payload: session_events.AgentSessionEvent.CompactionEnd) ?TranscriptIngest {
    if (payload.error_message) |_| return .{ .append = statusAppend(.err, "compaction failed") };
    if (payload.aborted and !payload.will_retry) return .{ .append = statusAppend(.warning, "compaction cancelled") };
    return null;
}

fn autoRetryEndAppend(payload: session_events.AgentSessionEvent.AutoRetryEnd) ?TranscriptIngest {
    if (payload.success) return null;
    if (payload.final_error != null) return .{ .append = statusAppend(.err, "auto retry failed") };
    return null;
}

fn transcriptAppendFromAgentEvent(event: agent_mod.AgentEvent) ?TranscriptIngest {
    return switch (event) {
        .agent_start, .agent_end, .turn_start, .turn_end => null,
        .message_update => |message_update| switch (message_update.assistant_message_event) {
            .text_delta => |delta| .{ .append = messageAppend(
                .assistant,
                delta.delta,
                .extend_previous_assistant_message,
            ) },
            .thinking_delta => |delta| .{ .append = messageAppend(
                .thinking,
                delta.delta,
                .extend_previous_same_role,
            ) },
            .toolcall_start => |payload| toolCallAppend(payload.content_index, payload.partial),
            .toolcall_delta => |payload| toolCallAppend(payload.content_index, payload.partial),
            .toolcall_end => |payload| .{ .append = toolAppend(
                payload.tool_call.id,
                payload.tool_call.name,
                .pending,
                toolArgsPreview(payload.tool_call.name, payload.tool_call.arguments),
                false,
            ) },
            .@"error" => .{ .append = statusAppend(.err, "assistant error") },
            else => null,
        },
        .tool_execution_start => |payload| .{ .append = toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            .pending,
            toolArgsPreview(payload.tool_name, payload.args),
            false,
        ) },
        .tool_execution_update => |payload| toolOutputAppend(
            payload.tool_call_id,
            firstToolResultText(payload.partial_result),
        ),
        .tool_execution_end => |payload| .{ .append = toolAppend(
            payload.tool_call_id,
            payload.tool_name,
            if (payload.is_error) .err else .success,
            "",
            payload.is_error,
        ) },
        .message_start, .message_end => null,
    };
}

const PendingToolOutput = struct {
    tool_call_id: [pending_tool_id_bytes_max]u8 = undefined,
    tool_call_id_len: usize = 0,
    text: [pending_tool_output_bytes_max]u8 = undefined,
    text_len: usize = 0,
    dropped_head_bytes: usize = 0,
    dropped_head_lines: usize = 0,

    fn id(self: *const PendingToolOutput) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }

    fn body(self: *const PendingToolOutput) []const u8 {
        return self.text[0..self.text_len];
    }

    fn init(tool_call_id: []const u8, text: []const u8) PendingToolOutput {
        var result: PendingToolOutput = .{};
        result.tool_call_id_len = @min(tool_call_id.len, pending_tool_id_bytes_max);
        @memcpy(result.tool_call_id[0..result.tool_call_id_len], tool_call_id[0..result.tool_call_id_len]);
        result.append(text);
        return result;
    }

    fn append(self: *PendingToolOutput, text: []const u8) void {
        const keep = @min(text.len, pending_tool_output_bytes_max);
        var source_start = text.len - keep;
        while (source_start < text.len and isUtf8ContinuationByte(text[source_start])) : (source_start += 1) {}
        const source = text[source_start..];
        if (source_start > 0) self.recordDropped(text[0..source_start]);
        if (self.text_len + source.len <= pending_tool_output_bytes_max) {
            @memcpy(self.text[self.text_len .. self.text_len + source.len], source);
            self.text_len += source.len;
            return;
        }
        var overflow = self.text_len + source.len - pending_tool_output_bytes_max;
        while (overflow < self.text_len and isUtf8ContinuationByte(self.text[overflow])) : (overflow += 1) {}
        self.recordDropped(self.text[0..overflow]);
        @memmove(self.text[0 .. self.text_len - overflow], self.text[overflow..self.text_len]);
        self.text_len -= overflow;
        @memcpy(self.text[self.text_len .. self.text_len + source.len], source);
        self.text_len += source.len;
    }

    fn recordDropped(self: *PendingToolOutput, bytes: []const u8) void {
        self.dropped_head_bytes += bytes.len;
        self.dropped_head_lines += std.mem.count(u8, bytes, "\n");
    }
};

fn isUtf8ContinuationByte(byte: u8) bool {
    return (byte & 0xc0) == 0x80;
}

const ToolCallMirror = struct {
    tool_call_id: [pending_tool_id_bytes_max]u8 = undefined,
    tool_call_id_len: usize = 0,
    title: [tool_title_bytes_max]u8 = undefined,
    title_len: usize = 0,

    fn id(self: *const ToolCallMirror) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }

    fn titleText(self: *const ToolCallMirror) []const u8 {
        return self.title[0..self.title_len];
    }

    fn init(tool_call_id: []const u8, title: []const u8) ToolCallMirror {
        var result: ToolCallMirror = .{};
        result.tool_call_id_len = @min(tool_call_id.len, pending_tool_id_bytes_max);
        @memcpy(result.tool_call_id[0..result.tool_call_id_len], tool_call_id[0..result.tool_call_id_len]);
        result.setTitle(title);
        return result;
    }

    fn setTitle(self: *ToolCallMirror, title: []const u8) void {
        const bounded = utf8Prefix(title, tool_title_bytes_max);
        self.title_len = bounded.len;
        @memcpy(self.title[0..self.title_len], bounded);
    }
};

const PendingConfirm = struct {
    id: tui.product.ModalId,
    result: ?bool = null,
};

const InteractiveLoop = struct {
    process: runtime.Process,
    host: *AgentSessionRuntimeHost,
    terminal_loop: *tui.product.TerminalLoop,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    active_run: ?*AgentSession.LivePromptRun = null,
    cancel_requested: bool = false,
    last_render_ns: ?i128 = null,
    effects: [effect_count_max]tui.product.Effect = undefined,
    pending_tool_outputs: [pending_tool_outputs_max]PendingToolOutput = undefined,
    pending_tool_output_count: usize = 0,
    tool_call_mirrors: [tool_call_mirrors_max]ToolCallMirror = undefined,
    tool_call_mirror_count: usize = 0,
    tool_metadata_lookup_enabled: bool = true,
    pending_confirm: ?PendingConfirm = null,
    next_confirm_id: tui.product.ModalId = confirm_id_start,

    fn requestConfirm(self: *InteractiveLoop, title: []const u8, body: []const u8) !tui.product.ModalId {
        if (self.pending_confirm != null) return error.ConfirmAlreadyPending;
        const id = self.nextConfirmId();
        _ = try self.terminal_loop.applyCommand(.{ .open_confirm = .{ .id = id, .title = title, .body = body } });
        self.pending_confirm = .{ .id = id };
        return id;
    }

    fn nextConfirmId(self: *InteractiveLoop) tui.product.ModalId {
        const id = self.next_confirm_id;
        self.next_confirm_id +%= 1;
        if (self.next_confirm_id == 0) self.next_confirm_id = confirm_id_start;
        return id;
    }

    fn takeConfirmResult(self: *InteractiveLoop, id: tui.product.ModalId) ?bool {
        const pending = self.pending_confirm orelse return null;
        if (pending.id != id or pending.result == null) return null;
        const result = pending.result.?;
        self.pending_confirm = null;
        return result;
    }

    fn startPrompt(self: *InteractiveLoop, text: []const u8) !bool {
        if (self.active_run != null) {
            try self.stderr.writeAll("prompt already running; submit ignored\n");
            return false;
        }
        self.active_run = try self.host.startPromptRun(text, &.{}, .{});
        self.setWorkingStatus() catch {
            self.stderr.writeAll("status update failed\n") catch return true;
        };
        return true;
    }

    fn requestShutdown(self: *InteractiveLoop) void {
        self.terminal_loop.requestStop();
        if (!self.cancel_requested and self.active_run != null) {
            self.host.cancel();
            self.cancel_requested = true;
        }
    }

    fn tick(self: *InteractiveLoop) !void {
        const input_ready = try self.waitForRuntimeWake();
        if (input_ready) {
            try self.drainInputReadyBounded(input_reads_per_tick_max);
        } else {
            try self.flushPendingInput();
        }
        _ = try self.drainPromptProgressBounded(prompt_progress_per_tick_max);
        _ = try self.drainPublicEventsBounded(public_events_per_tick_max);
        const now_ns = std.Io.Timestamp.now(self.process.io, .awake).nanoseconds;
        _ = try self.terminal_loop.applyCommand(.{ .animation_tick = animationTick(now_ns) });
        if (render_attempts_per_tick_max > 0 and self.terminal_loop.isDirty()) {
            if (frameDue(now_ns, self.last_render_ns)) {
                try self.terminal_loop.renderIfDirty(self.stdout);
                try self.stdout.flush();
                self.last_render_ns = now_ns;
            }
        }
    }

    fn waitForRuntimeWake(self: *InteractiveLoop) !bool {
        const readable = runtime.ReadableFd.initBorrowed(self.terminal_loop.inputFd());
        var input = readable.asyncReadable();
        var frame = runtime.Timeout.fromMilliseconds(frame_interval_ms);
        var public_event_wake = self.host.publicEventWake();
        if (self.active_run) |prompt_run| {
            var progress = self.host.promptRunProgress(prompt_run);
            switch (try runtime.select(.{
                .input = &input,
                .prompt = &progress,
                .public_event = public_event_wake,
                .frame = &frame,
            })) {
                .input => |result| return self.handleInputWaitResult(result),
                .prompt => |result| {
                    try self.applyPromptProgressResult(prompt_run, result);
                    return false;
                },
                .public_event => {
                    public_event_wake.reset();
                    return false;
                },
                .frame => return false,
            }
        } else {
            switch (try runtime.select(.{ .input = &input, .public_event = public_event_wake, .frame = &frame })) {
                .input => |result| return self.handleInputWaitResult(result),
                .public_event => {
                    public_event_wake.reset();
                    return false;
                },
                .frame => return false,
            }
        }
    }

    fn handleInputWaitResult(self: *InteractiveLoop, result: runtime.ReadableFdError!void) bool {
        result catch {
            self.requestShutdown();
            return false;
        };
        return true;
    }

    fn flushPendingInput(self: *InteractiveLoop) !void {
        const result = try self.terminal_loop.flushPendingInput(&self.effects);
        defer self.deinitEffects(result.effect_count);
        try self.handleStepResult(result);
        try self.applyEffects(result.effect_count);
    }

    fn drainInputReadyBounded(self: *InteractiveLoop, limit: usize) !void {
        var reads: usize = 0;
        while (reads < limit) : (reads += 1) {
            const result = self.terminal_loop.readAvailableInput(&self.effects) catch |err| switch (err) {
                error.WouldBlock => {
                    const flush = try self.terminal_loop.flushPendingInput(&self.effects);
                    defer self.deinitEffects(flush.effect_count);
                    try self.handleStepResult(flush);
                    try self.applyEffects(flush.effect_count);
                    return;
                },
                else => {
                    try self.stderr.writeAll("terminal read failed; shutting down\n");
                    self.requestShutdown();
                    return;
                },
            };
            defer self.deinitEffects(result.effect_count);
            try self.handleStepResult(result);
            try self.applyEffects(result.effect_count);
        }
    }

    fn handleStepResult(self: *InteractiveLoop, result: tui.product.terminal_loop.StepResult) !void {
        if (result.input_overflow) try self.stderr.writeAll("terminal input overflow\n");
        if (result.effect_overflow) try self.stderr.writeAll("terminal effect overflow\n");
        if (result.truncated) try self.stderr.writeAll("terminal input truncated\n");
        if (result.shutdown_requested or result.eof) self.requestShutdown();
    }

    fn applyEffects(self: *InteractiveLoop, count: usize) !void {
        for (self.effects[0..count]) |effect| {
            switch (effect) {
                .submit_text => |text| {
                    if (try self.startPrompt(text)) try self.appendTranscript(messageAppend(.user, text, .new_item));
                },
                .request_shutdown => self.requestShutdown(),
                .confirm_result => |result| self.applyConfirmResult(result),
            }
        }
    }

    fn applyConfirmResult(self: *InteractiveLoop, result: tui.product.ConfirmResult) void {
        if (self.pending_confirm) |*pending| {
            if (pending.id == result.id) pending.result = result.accepted;
        }
    }

    fn deinitEffects(self: *InteractiveLoop, count: usize) void {
        for (self.effects[0..count]) |effect| effect.deinit(self.process.gpa);
    }

    fn drainPromptProgressBounded(self: *InteractiveLoop, limit: usize) !usize {
        const prompt_run = self.active_run orelse return 0;
        var count: usize = 0;
        while (count < limit and self.active_run != null) : (count += 1) {
            var progress = self.host.promptRunProgress(prompt_run);
            var ready = runtime.Timeout.fromMilliseconds(0);
            switch (try runtime.select(.{ .prompt = &progress, .ready = &ready })) {
                .prompt => |result| try self.applyPromptProgressResult(prompt_run, result),
                .ready => return count,
            }
        }
        return count;
    }

    fn applyPromptProgressResult(
        self: *InteractiveLoop,
        prompt_run: *AgentSession.LivePromptRun,
        result: anytype,
    ) !void {
        if (self.active_run != prompt_run) return;
        const more = try self.host.applyPromptRunProgress(prompt_run, result);
        if (!more) {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
            self.clearStatus(status_owner_run, status_id_working) catch {
                self.stderr.writeAll("status clear failed\n") catch return;
            };
        }
    }

    fn drainPublicEventsBounded(self: *InteractiveLoop, limit: usize) !usize {
        var count: usize = 0;
        while (count < limit) : (count += 1) {
            var event = self.host.drainPublicEvent() orelse {
                try self.flushToolOutputCoalescer();
                return count;
            };
            defer event.deinit();
            try self.applyPublicEventStatus(event);
            try self.applyPublicEventTranscript(event);
        }
        try self.flushToolOutputCoalescer();
        return count;
    }

    fn applyPublicEventStatus(self: *InteractiveLoop, event: session_events.AgentSessionEvent) !void {
        switch (event) {
            .agent_event => |payload| switch (payload.event) {
                .agent_start => try self.setWorkingStatus(),
                .agent_end => try self.clearStatus(status_owner_run, status_id_working),
                else => {},
            },
            .compaction_start => try self.setStatus(
                status_owner_policy,
                status_id_compaction,
                200,
                "compacting context",
                .shimmer,
            ),
            .compaction_end => try self.clearStatus(status_owner_policy, status_id_compaction),
            .auto_retry_start => |payload| {
                var buffer: [tui.product.slots.contribution_text_bytes_max]u8 = undefined;
                const seconds = (payload.delay_ms + 999) / 1000;
                const text = std.fmt.bufPrint(
                    &buffer,
                    "retry {d}/{d} in {d}s",
                    .{ payload.attempt, payload.max_attempts, seconds },
                ) catch "retrying";
                try self.setStatus(status_owner_policy, status_id_retry, 190, text, .shimmer);
            },
            .auto_retry_end => try self.clearStatus(status_owner_policy, status_id_retry),
            else => {},
        }
    }

    fn setWorkingStatus(self: *InteractiveLoop) !void {
        try self.setStatus(status_owner_run, status_id_working, 100, "working", .shimmer);
    }

    fn setStatus(
        self: *InteractiveLoop,
        owner: tui.product.SlotOwnerId,
        id: tui.product.SlotContributionId,
        priority: i16,
        text: []const u8,
        effect: tui.product.slots.RenderEffect,
    ) !void {
        _ = self.terminal_loop.applyCommand(.{ .set_slot_contribution = .{
            .slot = .status_area,
            .id = id,
            .owner = owner,
            .priority = priority,
            .text = text,
            .effect = effect,
        } }) catch |err| switch (err) {
            error.InvalidSlotContribution,
            error.SlotContributionTooLarge,
            error.InvalidSlotContributionText,
            error.SlotContributionLimitExceeded,
            => return,
            else => return err,
        };
    }

    fn clearStatus(
        self: *InteractiveLoop,
        owner: tui.product.SlotOwnerId,
        id: tui.product.SlotContributionId,
    ) !void {
        _ = try self.terminal_loop.applyCommand(.{ .clear_slot_contribution = .{
            .slot = .status_area,
            .id = id,
            .owner = owner,
        } });
    }

    fn applyPublicEventTranscript(self: *InteractiveLoop, event: session_events.AgentSessionEvent) !void {
        if (event == .agent_event and event.agent_event.event == .message_update) {
            if (transcriptAppendFromAgentEvent(event.agent_event.event)) |projection| {
                try self.applyTranscriptProjection(projection);
            }
            var preview_buffer: [pending_tool_output_bytes_max]u8 = undefined;
            if (writePreviewFromMessageUpdate(event.agent_event.event.message_update, &preview_buffer)) |preview| {
                try self.replaceToolCallPreview(preview.tool_call_id, preview.text);
            }
            return;
        }
        if (event == .agent_event and event.agent_event.event == .tool_execution_start) {
            const payload = event.agent_event.event.tool_execution_start;
            if (transcriptAppendFromAgentEvent(event.agent_event.event)) |projection| {
                try self.applyTranscriptProjection(projection);
            }
            if (std.mem.eql(u8, payload.tool_name, "write")) {
                var preview_buffer: [pending_tool_output_bytes_max]u8 = undefined;
                if (writeContentPreview(payload.args, &preview_buffer)) |preview| {
                    try self.replaceToolCallPreview(payload.tool_call_id, preview);
                }
            }
            return;
        }
        if (event == .agent_event and event.agent_event.event == .tool_execution_update) {
            const payload = event.agent_event.event.tool_execution_update;
            if (std.mem.eql(u8, payload.tool_name, "write")) {
                try self.replaceToolCallPreview(payload.tool_call_id, "");
            }
            if (transcriptAppendFromAgentEvent(event.agent_event.event)) |projection| {
                try self.applyTranscriptProjection(projection);
            }
            return;
        }
        if (event == .agent_event and event.agent_event.event == .tool_execution_end) {
            const payload = event.agent_event.event.tool_execution_end;
            if (transcriptAppendFromAgentEvent(event.agent_event.event)) |projection| {
                try self.applyTranscriptProjection(projection);
            }
            if (shouldAppendFinalToolOutput(payload.tool_name, payload.is_error)) {
                if (toolOutputAppend(payload.tool_call_id, firstToolResultText(payload.result))) |projection| {
                    try self.applyTranscriptProjection(projection);
                }
            }
            return;
        }
        if (transcriptAppendFromEvent(event)) |projection| try self.applyTranscriptProjection(projection);
    }

    fn applyTranscriptProjection(self: *InteractiveLoop, projection: TranscriptIngest) !void {
        switch (projection) {
            .append => |append| try self.appendTranscript(self.applyToolCallMirror(append)),
            .tool_output_delta => |delta| try self.queueToolOutput(delta.tool_call_id, delta.text),
        }
    }

    fn applyToolCallMirror(self: *InteractiveLoop, append: TranscriptAppend) TranscriptAppend {
        if (append != .tool) return append;
        var next = append;
        const tool = &next.tool;
        if (self.tool_metadata_lookup_enabled) {
            if (self.host.findToolMetadata(tool.name)) |metadata| {
                tool.presentation = tuiPresentation(metadata.display.presentation);
                tool.body_mode = tuiBodyMode(metadata.display.body_mode);
            }
        }
        if (tool.tool_call_id.len > pending_tool_id_bytes_max) return next;
        if (tool.title.len > 0) {
            self.rememberToolTitle(tool.tool_call_id, tool.title);
            return next;
        }
        if (self.findToolMirror(tool.tool_call_id)) |index| {
            tool.title = self.tool_call_mirrors[index].titleText();
        }
        return next;
    }

    fn rememberToolTitle(self: *InteractiveLoop, tool_call_id: []const u8, title: []const u8) void {
        if (self.findToolMirror(tool_call_id)) |index| {
            self.tool_call_mirrors[index].setTitle(title);
            return;
        }
        if (self.tool_call_mirror_count == self.tool_call_mirrors.len) {
            self.tool_call_mirrors[0] = self.tool_call_mirrors[self.tool_call_mirror_count - 1];
            self.tool_call_mirror_count -= 1;
        }
        self.tool_call_mirrors[self.tool_call_mirror_count] = ToolCallMirror.init(tool_call_id, title);
        self.tool_call_mirror_count += 1;
    }

    fn findToolMirror(self: *const InteractiveLoop, tool_call_id: []const u8) ?usize {
        for (self.tool_call_mirrors[0..self.tool_call_mirror_count], 0..) |*mirror, index| {
            if (std.mem.eql(u8, mirror.id(), tool_call_id)) return index;
        }
        return null;
    }

    fn replaceToolCallPreview(self: *InteractiveLoop, tool_call_id: []const u8, text: []const u8) !void {
        var sanitized_buffer: [pending_tool_output_bytes_max]u8 = undefined;
        const sanitized = sanitizeTranscriptText(text, &sanitized_buffer);
        try self.applyCommandDegrading(.{ .replace_tool_call_preview = .{
            .tool_call_id = tool_call_id,
            .text = sanitized,
        } });
    }

    fn queueToolOutput(self: *InteractiveLoop, tool_call_id: []const u8, text: []const u8) !void {
        var sanitized_buffer: [pending_tool_output_bytes_max]u8 = undefined;
        const sanitized = sanitizeTranscriptText(text, &sanitized_buffer);
        if (sanitized.len == 0) return;
        if (tool_call_id.len > pending_tool_id_bytes_max) {
            try self.appendTranscript(statusAppend(.warning, "tool output omitted: tool id too long"));
            return;
        }
        for (self.pending_tool_outputs[0..self.pending_tool_output_count]) |*pending| {
            if (std.mem.eql(u8, pending.id(), tool_call_id)) {
                pending.append(sanitized);
                return;
            }
        }
        if (self.pending_tool_output_count == self.pending_tool_outputs.len) {
            try self.flushToolOutputCoalescer();
        }
        if (self.pending_tool_output_count == self.pending_tool_outputs.len) return error.TooManyTools;
        self.pending_tool_outputs[self.pending_tool_output_count] = PendingToolOutput.init(tool_call_id, sanitized);
        self.pending_tool_output_count += 1;
    }

    fn flushToolOutputCoalescer(self: *InteractiveLoop) !void {
        for (self.pending_tool_outputs[0..self.pending_tool_output_count]) |*pending| {
            try self.applyCommandDegrading(.{
                .tool_output_delta = .{
                    .tool_call_id = pending.id(),
                    .text = pending.body(),
                    .dropped_head_bytes = pending.dropped_head_bytes,
                    .dropped_head_lines = pending.dropped_head_lines,
                },
            });
        }
        self.pending_tool_output_count = 0;
    }

    fn appendTranscript(self: *InteractiveLoop, append: TranscriptAppend) !void {
        try self.applyCommandDegrading(.{ .append_transcript = append });
    }

    fn applyCommandDegrading(self: *InteractiveLoop, command: tui.product.Command) !void {
        _ = self.terminal_loop.applyCommand(command) catch |err| switch (err) {
            error.InvalidUtf8 => return self.appendOperationalStatus("transcript update omitted: invalid utf-8"),
            error.TranscriptAppendTooLarge => return self.appendOperationalStatus(
                "transcript update omitted: too large",
            ),
            else => return err,
        };
    }

    fn appendOperationalStatus(self: *InteractiveLoop, text: []const u8) !void {
        _ = self.terminal_loop.applyCommand(.{
            .append_transcript = statusAppend(.warning, text),
        }) catch |err| switch (err) {
            error.InvalidUtf8, error.TranscriptAppendTooLarge => return,
            else => return err,
        };
    }

    fn shutdown(self: *InteractiveLoop) void {
        if (self.active_run != null and !self.cancel_requested) {
            self.host.cancel();
            self.cancel_requested = true;
        }
        var ticks: usize = 0;
        while (self.active_run != null and ticks < shutdown_drain_ticks_max) : (ticks += 1) {
            _ = self.drainPromptProgressBounded(prompt_progress_per_tick_max) catch break;
        }
        if (self.active_run) |prompt_run| {
            self.host.destroyPromptRun(prompt_run);
            self.active_run = null;
        }
    }
};

pub fn run(
    process: runtime.Process,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
    options: Options,
) !void {
    const timestamp = std.Io.Timestamp.now(process.io, .real).nanoseconds;
    const timestamp_text = try std.fmt.allocPrint(process.gpa, "{d}", .{timestamp});
    defer process.gpa.free(timestamp_text);

    var host_handle = try createHost(process, stderr, options, timestamp_text, timestamp);
    defer host_handle.deinit();

    var terminal_loop = try initTerminalLoop(process, stdout);
    defer terminal_loop.deinit();

    try terminal_loop.setup(stdout);
    try stdout.flush();
    defer {
        terminal_loop.shutdown(stdout) catch {};
        stdout.flush() catch {};
    }

    var loop: InteractiveLoop = .{
        .process = process,
        .host = &host_handle.host,
        .terminal_loop = &terminal_loop,
        .stdout = stdout,
        .stderr = stderr,
    };
    defer loop.shutdown();

    try applyModelComposerSlot(&terminal_loop, host_handle.host.base.model);
    try seedTranscriptFromSession(process.gpa, &terminal_loop, &host_handle.host);
    if (options.initial_prompt) |prompt| {
        if (try loop.startPrompt(prompt)) try loop.appendTranscript(messageAppend(.user, prompt, .new_item));
    }
    _ = try loop.drainPublicEventsBounded(public_events_per_tick_max);
    try terminal_loop.renderIfDirty(stdout);
    try stdout.flush();

    while (terminal_loop.isRunning()) try loop.tick();
}

fn applyModelComposerSlot(terminal_loop: *tui.product.TerminalLoop, model: ai.Model) !void {
    var text_buffer: [tui.product.slots.contribution_text_bytes_max]u8 = undefined;
    const text = modelComposerSlotText(model, &text_buffer);
    _ = try terminal_loop.applyCommand(.{ .set_slot_contribution = .{
        .slot = .composer_top_right,
        .id = model_slot_id,
        .owner = model_slot_owner,
        .priority = 100,
        .text = text,
        .effect = .none,
    } });
}

fn modelComposerSlotText(model: ai.Model, buffer: []u8) []const u8 {
    return std.fmt.bufPrint(buffer, "model: {s}/{s}", .{ model.provider, model.id }) catch blk: {
        if (buffer.len == 0) break :blk "";
        const prefix = "model: ";
        var len: usize = 0;
        const prefix_len = @min(prefix.len, buffer.len);
        @memcpy(buffer[0..prefix_len], prefix[0..prefix_len]);
        len += prefix_len;
        if (len < buffer.len) {
            const id = utf8Prefix(model.id, buffer.len - len);
            @memcpy(buffer[len..][0..id.len], id);
            len += id.len;
        }
        break :blk buffer[0..len];
    };
}

fn seedTranscriptFromSession(
    allocator: std.mem.Allocator,
    terminal_loop: *tui.product.TerminalLoop,
    host: *AgentSessionRuntimeHost,
) !void {
    var snapshot = try host.publicHistorySnapshot(allocator);
    defer snapshot.deinit(allocator);
    try seedTranscriptFromSnapshot(terminal_loop, snapshot.items);
}

fn seedTranscriptFromSnapshot(
    terminal_loop: *tui.product.TerminalLoop,
    items: []const session_history_snapshot.Item,
) !void {
    for (items) |item| {
        _ = try terminal_loop.applyCommand(.{
            .append_transcript = messageAppend(
                transcriptRoleFromHistory(item.role),
                item.text,
                .new_item,
            ),
        });
    }
}

fn transcriptRoleFromHistory(role: session_history_snapshot.Role) tui.product.transcript.TranscriptRole {
    return switch (role) {
        .user => .user,
        .assistant => .assistant,
        .system => .system,
    };
}

fn createHost(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    options: Options,
    timestamp_text: []const u8,
    timestamp: i128,
) !sdk.RuntimeHostHandle {
    if (try selectResumeSession(process, stderr, options)) |session_file| {
        defer process.gpa.free(session_file);
        return sdk.resumeRuntimeHost(process.gpa, .{
            .cwd = options.cwd,
            .agent_dir_override = options.agent_dir_override,
            .current_date = timestamp_text,
            .session_file_name = session_file,
            .dir = options.dir,
            .environ = options.environ,
            .zio_runtime = process.zio_runtime,
        });
    }

    const session_id = try std.fmt.allocPrint(process.gpa, "interactive-{d}", .{timestamp});
    defer process.gpa.free(session_id);
    return sdk.createRuntimeHost(process.gpa, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .current_date = timestamp_text,
        .session_id = session_id,
        .timestamp = timestamp_text,
        .dir = options.dir,
        .environ = options.environ,
        .zio_runtime = process.zio_runtime,
    });
}

fn initTerminalLoop(process: runtime.Process, stdout: *std.Io.Writer) !tui.product.TerminalLoop {
    var terminal = tui.Terminal.init(process.io);
    const size = terminal.size() catch tui.TerminalSize{ .width = 80, .height = 24 };
    _ = stdout;
    return tui.product.TerminalLoop.init(
        process.gpa,
        process.io,
        size.width,
        size.height,
        tui.product.loop.output_size_bytes_default,
    );
}

fn selectResumeSession(
    process: runtime.Process,
    stderr: *std.Io.Writer,
    options: Options,
) !?[]const u8 {
    if (options.resume_session_file == null and !options.resume_latest) return null;
    const selected = sdk.selectRuntimeSession(process.gpa, process.io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .explicit_file_name = options.resume_session_file,
    }) catch |err| switch (err) {
        error.InvalidSessionFileName => {
            try stderr.writeAll("invalid resume session file\n");
            return error.InvalidCliUsage;
        },
        error.SessionListTruncated => {
            try stderr.writeAll("too many sessions to choose latest safely\n");
            return error.InvalidCliUsage;
        },
        else => return err,
    };
    if (selected == null) {
        try stderr.writeAll("no resumable session found\n");
        return error.NoResumableSession;
    }
    return selected;
}

test "interactive overflow status is explicit" {
    var err_storage: [256]u8 = undefined;
    var stderr = std.Io.Writer.fixed(&err_storage);
    var loop: InteractiveLoop = undefined;
    loop.stderr = &stderr;

    try loop.handleStepResult(.{
        .input_overflow = true,
        .effect_overflow = true,
        .truncated = true,
    });

    const written = err_storage[0..stderr.end];
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal input overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal effect overflow") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "terminal input truncated") != null);
}

test "interactive frame due enforces sixty fps cadence" {
    try std.testing.expect(frameDue(1000, null));
    try std.testing.expect(!frameDue(1000 + frame_interval_ns - 1, 1000));
    try std.testing.expect(frameDue(1000 + frame_interval_ns, 1000));
    try std.testing.expect(frameDue(1000 + frame_interval_ns + 1, 1000));
}

test "interactive loop bounds stay responsive" {
    try std.testing.expect(frame_interval_ns <= 16 * std.time.ns_per_ms);
    try std.testing.expect(frame_interval_ms <= 16);
    try std.testing.expectEqual(@as(usize, 1), input_reads_per_tick_max);
    try std.testing.expectEqual(@as(usize, 64), prompt_progress_per_tick_max);
    try std.testing.expectEqual(@as(usize, 16), public_events_per_tick_max);
    try std.testing.expectEqual(@as(usize, 1), render_attempts_per_tick_max);
    try std.testing.expectEqual(@as(usize, 60), shutdown_drain_ticks_max);
}

test "interactive sanitizes ansi and terminal controls for transcript text" {
    var buffer: [128]u8 = undefined;
    const sanitized = sanitizeTranscriptText(
        "\x1b[31mred\x1b[0m \x1b]0;title\x07plain\r\ttail\xc2\x9b31m",
        &buffer,
    );

    try std.testing.expectEqualStrings("red plain    tail", sanitized);
}

test "interactive confirm bridge resolves product modal result" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        40,
        10,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    var loop: InteractiveLoop = undefined;
    loop.terminal_loop = &terminal_loop;
    loop.effects = undefined;
    loop.pending_confirm = null;
    loop.next_confirm_id = confirm_id_start;

    const id = try loop.requestConfirm("Import session", "Replace current session?");
    try std.testing.expectEqual(confirm_id_start, id);
    try std.testing.expect(terminal_loop.product.app.modal != null);

    const fed = try terminal_loop.feedInputBytes("n", &loop.effects);
    try std.testing.expectEqual(@as(usize, 1), fed.effect_count);
    try loop.applyEffects(fed.effect_count);
    try std.testing.expectEqual(false, loop.takeConfirmResult(id).?);
    try std.testing.expect(terminal_loop.product.app.modal == null);
}

test "interactive confirm bridge ignores stale result ids" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        40,
        10,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    var loop: InteractiveLoop = undefined;
    loop.terminal_loop = &terminal_loop;
    loop.pending_confirm = .{ .id = 7 };
    loop.applyConfirmResult(.{ .id = 8, .accepted = true });
    try std.testing.expect(loop.takeConfirmResult(7) == null);
    loop.applyConfirmResult(.{ .id = 7, .accepted = true });
    try std.testing.expectEqual(true, loop.takeConfirmResult(7).?);
}

test "interactive model composer slot text is bounded" {
    var buffer: [32]u8 = undefined;
    const model = agent_mod.Agent.defaultModel();
    const text = modelComposerSlotText(model, &buffer);
    try std.testing.expect(text.len <= buffer.len);
    try std.testing.expect(std.mem.startsWith(u8, text, "model: "));
}

test "interactive maps simple public events to transcript appends" {
    try std.testing.expect(transcriptAppendFromAgentEvent(.agent_start) == null);
    try std.testing.expect(transcriptAppendFromAgentEvent(.turn_start) == null);

    const overflow = transcriptAppendFromEvent(.{ .public_event_overflow = .{ .dropped_count = 4 } }).?;
    try std.testing.expect(overflow == .append);
    try std.testing.expect(overflow.append == .status);
    try std.testing.expectEqual(tui.product.transcript.TranscriptStatusLevel.warning, overflow.append.status.level);
    try std.testing.expectEqualStrings("public event overflow", overflow.append.status.text);

    try std.testing.expect(transcriptAppendFromEvent(.{ .session_info_changed = .{ .name = null } }) == null);
}

test "interactive coalesced tool output keeps utf8 boundary after tail drop" {
    var bytes: [pending_tool_output_bytes_max + 1]u8 = undefined;
    var index: usize = 0;
    while (index < bytes.len) : (index += 3) {
        bytes[index] = 0xe2;
        bytes[index + 1] = 0x82;
        bytes[index + 2] = 0xac;
    }

    const pending = PendingToolOutput.init("tool", &bytes);
    try std.testing.expect(std.unicode.utf8ValidateSlice(pending.body()));
    try std.testing.expectEqual(@as(usize, 3), pending.dropped_head_bytes);
    try std.testing.expectEqual(@as(usize, pending_tool_output_bytes_max - 2), pending.body().len);
}

test "interactive transcript append degrades operational invalid utf8" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        20,
        4,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    var loop: InteractiveLoop = undefined;
    loop.terminal_loop = &terminal_loop;

    try loop.appendTranscript(messageAppend(.assistant, "\xff", .extend_previous_assistant_message));

    try std.testing.expectEqual(@as(usize, 1), terminal_loop.product.app.transcript.items.items.len);
    const item = terminal_loop.product.app.transcript.items.items[0];
    try std.testing.expect(item == .status);
    try std.testing.expectEqual(tui.product.transcript.TranscriptStatusLevel.warning, item.status.level);
}

test "interactive maps tool events to typed transcript items" {
    const start = transcriptAppendFromAgentEvent(.{ .tool_execution_start = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .null,
    } }).?;
    try std.testing.expect(start == .append);
    try std.testing.expect(start.append == .tool);
    try std.testing.expectEqualStrings("1", start.append.tool.tool_call_id);
    try std.testing.expectEqualStrings("bash", start.append.tool.name);
    try std.testing.expectEqualStrings("", start.append.tool.title);
    try std.testing.expectEqual(
        tui.product.transcript.TranscriptToolStatus.pending,
        start.append.tool.status,
    );
    try std.testing.expectEqual(
        tui.product.transcript.TranscriptToolPresentation.command,
        start.append.tool.presentation,
    );
    try std.testing.expectEqual(tui.product.transcript.TranscriptToolBodyMode.visible, start.append.tool.body_mode);

    const end = transcriptAppendFromAgentEvent(.{ .tool_execution_end = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .result = .{ .content = &.{} },
        .is_error = true,
    } }).?;
    try std.testing.expect(end == .append);
    try std.testing.expect(end.append == .tool);
    try std.testing.expectEqual(tui.product.transcript.TranscriptToolStatus.err, end.append.tool.status);
}

fn testAssistantMessage(content: []const ai.AssistantContent) ai.AssistantMessage {
    return .{
        .content = content,
        .api = "test-api",
        .provider = "test-provider",
        .model = "test-model",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = 0,
    };
}

test "interactive maps thinking deltas to streaming thinking transcript" {
    const event = transcriptAppendFromAgentEvent(.{ .message_update = .{
        .message = .{ .assistant = testAssistantMessage(&.{}) },
        .assistant_message_event = .{ .thinking_delta = .{
            .content_index = 0,
            .delta = "considering",
            .partial = testAssistantMessage(&.{}),
        } },
    } }).?;
    try std.testing.expect(event == .append);
    try std.testing.expect(event.append == .message);
    try std.testing.expectEqual(tui.product.transcript.TranscriptRole.thinking, event.append.message.role);
    try std.testing.expectEqual(.extend_previous_same_role, event.append.message.mode);
    try std.testing.expectEqualStrings("considering", event.append.message.text);
}

test "interactive maps tool call deltas to pending tool row" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "echo streaming" });
    const content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "bash",
        .arguments = .{ .object = args },
    } }};
    const partial = testAssistantMessage(&content);

    const event = transcriptAppendFromAgentEvent(.{ .message_update = .{
        .message = .{ .assistant = partial },
        .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 0,
            .delta = "streaming",
            .partial = partial,
        } },
    } }).?;
    try std.testing.expect(event == .append);
    try std.testing.expect(event.append == .tool);
    try std.testing.expectEqualStrings("call-1", event.append.tool.tool_call_id);
    try std.testing.expectEqualStrings("bash", event.append.tool.name);
    try std.testing.expectEqualStrings("echo streaming", event.append.tool.title);
    try std.testing.expectEqual(tui.product.transcript.TranscriptToolStatus.pending, event.append.tool.status);
}

test "interactive maps builtin tools to neutral display metadata" {
    const cases = [_]struct {
        name: []const u8,
        presentation: tui.product.transcript.TranscriptToolPresentation,
        body_mode: tui.product.transcript.TranscriptToolBodyMode,
    }{
        .{ .name = "read", .presentation = .file, .body_mode = .hidden_on_success },
        .{ .name = "edit", .presentation = .patch, .body_mode = .hidden_on_success },
        .{ .name = "write", .presentation = .file, .body_mode = .visible },
        .{ .name = "grep", .presentation = .search, .body_mode = .visible },
        .{ .name = "find", .presentation = .directory, .body_mode = .visible },
        .{ .name = "ls", .presentation = .directory, .body_mode = .visible },
        .{ .name = "custom", .presentation = .generic, .body_mode = .visible },
    };
    for (cases) |case| {
        const event = transcriptAppendFromAgentEvent(.{ .tool_execution_start = .{
            .tool_call_id = "1",
            .tool_name = case.name,
            .args = .null,
        } }).?;
        try std.testing.expect(event == .append);
        try std.testing.expect(event.append == .tool);
        try std.testing.expectEqual(case.presentation, event.append.tool.presentation);
        try std.testing.expectEqual(case.body_mode, event.append.tool.body_mode);
    }
}

test "interactive extracts write call preview from streamed tool args" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "content", .{ .string = "one\ntwo" });
    try args.put(std.testing.allocator, "path", .{ .string = "file.txt" });
    const content = [_]ai.AssistantContent{.{ .tool_call = .{
        .id = "call-1",
        .name = "write",
        .arguments = .{ .object = args },
    } }};
    const partial = testAssistantMessage(&content);
    var buffer: [pending_tool_output_bytes_max]u8 = undefined;
    const preview = writePreviewFromMessageUpdate(.{
        .message = .{ .assistant = partial },
        .assistant_message_event = .{ .toolcall_delta = .{
            .content_index = 0,
            .delta = "two",
            .partial = partial,
        } },
    }, &buffer).?;
    try std.testing.expectEqualStrings("call-1", preview.tool_call_id);
    try std.testing.expectEqualStrings("one\ntwo\n(2 total lines)", preview.text);
}

test "interactive appends final output for non-streaming visible tools" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        40,
        8,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    var loop: InteractiveLoop = undefined;
    loop.terminal_loop = &terminal_loop;
    loop.pending_tool_output_count = 0;
    loop.tool_call_mirror_count = 0;
    loop.tool_metadata_lookup_enabled = false;

    const content = [_]ai.ToolResultContent{.{ .text = .{ .text = "a.txt\nb.txt" } }};
    var event: session_events.AgentSessionEvent = .{ .agent_event = try session_events.OwnedAgentEvent.init(
        std.testing.allocator,
        .{ .tool_execution_end = .{
            .tool_call_id = "call-1",
            .tool_name = "ls",
            .result = .{ .content = &content },
            .is_error = false,
        } },
    ) };
    defer event.deinit();

    try loop.applyPublicEventTranscript(event);
    try loop.flushToolOutputCoalescer();

    try std.testing.expectEqual(@as(usize, 1), terminal_loop.product.app.transcript.items.items.len);
    const tool = terminal_loop.product.app.transcript.items.items[0].tool;
    try std.testing.expectEqualStrings("ls", tool.name);
    try std.testing.expectEqualStrings("a.txt\nb.txt", tool.output_preview);
}

test "interactive does not duplicate final bash output after streaming updates" {
    try std.testing.expect(!shouldAppendFinalToolOutput("bash", false));
    try std.testing.expect(shouldAppendFinalToolOutput("grep", false));
    try std.testing.expect(shouldAppendFinalToolOutput("read", true));
    try std.testing.expect(!shouldAppendFinalToolOutput("read", false));
}

test "interactive preserves mirrored tool title on terminal append" {
    var loop: InteractiveLoop = undefined;
    loop.tool_call_mirror_count = 0;
    loop.tool_metadata_lookup_enabled = false;

    const start = loop.applyToolCallMirror(.{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .presentation = .command,
        .status = .pending,
        .body_mode = .visible,
        .title = "zig build test",
    } });
    try std.testing.expect(start == .tool);
    try std.testing.expectEqualStrings("zig build test", start.tool.title);
    try std.testing.expectEqual(@as(usize, 1), loop.tool_call_mirror_count);

    const end = loop.applyToolCallMirror(.{ .tool = .{
        .tool_call_id = "call-1",
        .name = "bash",
        .presentation = .command,
        .status = .success,
        .body_mode = .visible,
        .title = "",
    } });
    try std.testing.expect(end == .tool);
    try std.testing.expectEqualStrings("zig build test", end.tool.title);
}

test "interactive maps tool args to bounded title" {
    var args: std.json.ObjectMap = .empty;
    defer args.deinit(std.testing.allocator);
    try args.put(std.testing.allocator, "command", .{ .string = "zig build test" });

    const start = transcriptAppendFromAgentEvent(.{ .tool_execution_start = .{
        .tool_call_id = "1",
        .tool_name = "bash",
        .args = .{ .object = args },
    } }).?;
    try std.testing.expect(start == .append);
    try std.testing.expect(start.append == .tool);
    try std.testing.expectEqualStrings("zig build test", start.append.tool.title);
}

test "interactive seeds tui transcript from public history snapshot" {
    var terminal_loop = try tui.product.TerminalLoop.init(
        std.testing.allocator,
        std.testing.io,
        20,
        4,
        tui.product.loop.output_size_bytes_default,
    );
    defer terminal_loop.deinit();

    const user_text = try std.testing.allocator.dupe(u8, "hello");
    defer std.testing.allocator.free(user_text);
    const assistant_text = try std.testing.allocator.dupe(u8, "hi");
    defer std.testing.allocator.free(assistant_text);
    const items = [_]session_history_snapshot.Item{
        .{ .role = .user, .text = user_text },
        .{ .role = .assistant, .text = assistant_text },
    };

    try seedTranscriptFromSnapshot(&terminal_loop, &items);

    try std.testing.expectEqual(@as(usize, 2), terminal_loop.product.app.transcript.items.items.len);
    try std.testing.expectEqual(.user, terminal_loop.product.app.transcript.items.items[0].message.role);
    try std.testing.expectEqualStrings("hello", terminal_loop.product.app.transcript.items.items[0].message.text);
    try std.testing.expectEqual(.assistant, terminal_loop.product.app.transcript.items.items[1].message.role);
    try std.testing.expectEqualStrings("hi", terminal_loop.product.app.transcript.items.items[1].message.text);
}
