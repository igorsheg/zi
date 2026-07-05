const std = @import("std");

const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");
const failure_text = @import("failure_text.zig");
const pickers = @import("pickers.zig");
const tool_view = @import("tool_view.zig");

const vm = coding_agent.view_model;

const status_id_working: tui.status.ContributionId = 1;
const status_id_queue: tui.status.ContributionId = 2;
const status_id_cwd: tui.status.ContributionId = 3;
const status_id_session: tui.status.ContributionId = 4;

pub const ViewCursor = struct {
    epoch: u32 = 0,
    generation: u64 = 0,
    chrome_rev: u32 = 0,
    op_rev: u32 = 0,
    queue_rev: u32 = 0,
    history_rev: u32 = 0,
    completion_rev: u32 = 0,
    last_notice_id: u64 = 0,
    items: std.ArrayList(ItemCursor) = .empty,
    latest_query_id: u64 = 0,
    latest_query_kind: vm.CompletionSlot.Kind = .none,
    queue_status_bytes: [64]u8 = undefined,
    queue_status_len: usize = 0,
    home_dir: ?[]const u8 = null,
    chrome_left_bytes: [tui.status.text_bytes_max]u8 = undefined,
    chrome_left_len: usize = 0,
    chrome_right_bytes: [tui.status.text_bytes_max]u8 = undefined,
    chrome_right_len: usize = 0,

    pub fn deinit(self: *ViewCursor, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn noteQuery(self: *ViewCursor, query_id: u64) void {
        self.latest_query_id = query_id;
        self.latest_query_kind = .none;
    }

    pub fn noteCompletionQuery(self: *ViewCursor, query_id: u64, kind: vm.CompletionSlot.Kind) void {
        self.latest_query_id = query_id;
        self.latest_query_kind = kind;
    }

    fn resetForEpoch(self: *ViewCursor, gpa: std.mem.Allocator, epoch: u32) void {
        _ = gpa;
        var items = self.items;
        items.clearRetainingCapacity();
        self.* = .{
            .epoch = epoch,
            .latest_query_id = self.latest_query_id,
            .latest_query_kind = self.latest_query_kind,
            .items = items,
            .home_dir = self.home_dir,
        };
    }

    fn findItem(self: *ViewCursor, id: u64) ?*ItemCursor {
        for (self.items.items) |*item| if (item.id == id) return item;
        return null;
    }
};

const ItemCursor = struct {
    id: u64,
    rev: u32 = 0,
    consumed_len: usize = 0,
    text_replaced_rev: ?u32 = null,
    state: vm.Item.State = .streaming,
    footer_bytes: [tool_view.footer_bytes_max]u8 = undefined,
    footer_len: usize = 0,
    static_footer_bytes: [tool_view.footer_bytes_max]u8 = undefined,
    static_footer_len: usize = 0,
    tool_call_id: [128]u8 = undefined,
    tool_call_id_len: usize = 0,
    shows_duration: bool = false,
    started_ms: ?i64 = null,
    duration_ms: ?u64 = null,

    fn footer(self: *const ItemCursor, fallback: []const u8) []const u8 {
        if (self.footer_len > 0) return self.footer_bytes[0..self.footer_len];
        return fallback;
    }

    fn toolCallId(self: *const ItemCursor) []const u8 {
        return self.tool_call_id[0..self.tool_call_id_len];
    }
};

pub const DiffResult = struct {
    commands: std.ArrayList(tui.Command),

    pub fn deinit(self: *DiffResult, gpa: std.mem.Allocator) void {
        self.commands.deinit(gpa);
        self.* = undefined;
    }
};

pub fn tickDurations(gpa: std.mem.Allocator, cursor: *ViewCursor, now_ms: i64) !DiffResult {
    var result: DiffResult = .{ .commands = .empty };
    errdefer result.deinit(gpa);
    for (cursor.items.items) |*item| {
        if (!item.shows_duration or item.started_ms == null or item.duration_ms != null) continue;
        if (item.tool_call_id_len == 0) continue;
        const elapsed: u64 = @intCast(@max(@as(i64, 0), now_ms - item.started_ms.?));
        renderToolFooter(item, elapsed);
        try result.commands.append(gpa, .{ .replace_tool_footer = .{
            .tool_call_id = item.toolCallId(),
            .text = item.footer(""),
        } });
    }
    return result;
}

pub fn diff(gpa: std.mem.Allocator, sample: *const vm.Sample, cursor: *ViewCursor) !DiffResult {
    var result: DiffResult = .{ .commands = .empty };
    errdefer result.deinit(gpa);

    if (cursor.epoch != sample.session_epoch) {
        cursor.resetForEpoch(gpa, sample.session_epoch);
        try result.commands.append(gpa, .clear_transcript);
    }

    try emitNotices(gpa, sample, cursor, &result.commands);
    try emitChrome(gpa, sample, cursor, &result.commands);
    try emitOperation(gpa, sample, cursor, &result.commands);
    try emitQueue(gpa, sample, cursor, &result.commands);
    try emitCompletion(gpa, sample, cursor, &result.commands);

    for (sample.items.items) |*item| {
        if (item.kind == .thinking and
            item.state == .streaming and
            sample.chrome.hide_thinking and
            cursor.findItem(item.id) == null)
        {
            try cursor.items.append(gpa, .{ .id = item.id, .rev = item.rev, .state = item.state });
            continue;
        }
        if (cursor.findItem(item.id)) |item_cursor| {
            try diffExistingItem(gpa, item, item_cursor, &result.commands);
        } else {
            try appendNewItem(gpa, sample, item, cursor, &result.commands);
        }
    }

    cursor.generation = sample.generation;
    cursor.chrome_rev = sample.chrome.rev;
    cursor.op_rev = sample.op.rev;
    cursor.queue_rev = sample.queue.rev;
    if (sample.history) |history| cursor.history_rev = history.rev;
    if (sample.completion) |completion| cursor.completion_rev = completion.rev;
    return result;
}

fn emitChrome(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    if (sample.chrome.rev == cursor.chrome_rev) return;
    const left = formatChromeCwd(&cursor.chrome_left_bytes, sample.chrome.cwd.slice(), cursor.home_dir);
    cursor.chrome_left_len = left.len;
    try commands.append(gpa, .{ .set_status = .{
        .slot = .composer_left,
        .id = status_id_cwd,
        .priority = 1,
        .text = cursor.chrome_left_bytes[0..cursor.chrome_left_len],
    } });
    const right = formatChromeRight(&cursor.chrome_right_bytes, &sample.chrome);
    cursor.chrome_right_len = right.len;
    try commands.append(gpa, .{ .set_status = .{
        .slot = .composer_right,
        .id = status_id_session,
        .priority = 1,
        .text = cursor.chrome_right_bytes[0..cursor.chrome_right_len],
    } });
}

fn formatChromeCwd(buffer: []u8, cwd: []const u8, home_dir_raw: ?[]const u8) []const u8 {
    const bounded = vm.utf8Prefix(cwd, buffer.len);
    const suffix = homePathSuffix(bounded, home_dir_raw) orelse {
        @memcpy(buffer[0..bounded.len], bounded);
        return buffer[0..bounded.len];
    };
    if (suffix.len == 0) {
        buffer[0] = '~';
        return buffer[0..1];
    }
    return std.fmt.bufPrint(buffer, "~{s}", .{vm.utf8Prefix(suffix, buffer.len - 1)}) catch buffer[0..0];
}

fn homePathSuffix(path: []const u8, home_dir_raw: ?[]const u8) ?[]const u8 {
    const home_dir = trimTrailingPathSeparators(home_dir_raw orelse return null);
    if (home_dir.len == 0) return null;
    if (std.mem.eql(u8, path, home_dir)) return "";
    if (!std.mem.startsWith(u8, path, home_dir)) return null;
    if (path.len <= home_dir.len or !isPathSeparator(path[home_dir.len])) return null;
    return path[home_dir.len..];
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and isPathSeparator(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn isPathSeparator(byte: u8) bool {
    return byte == '/' or byte == '\\';
}

fn formatChromeRight(buffer: []u8, chrome: *const vm.Chrome) []const u8 {
    var pct_buffer: [8]u8 = undefined;
    const pct = if (chrome.context_used_pct) |value|
        std.fmt.bufPrint(&pct_buffer, "{d}%", .{value}) catch "?%"
    else
        "?%";
    const provider = chrome.provider_label.slice();
    const model = chrome.model_id.slice();
    if (provider.len == 0 or std.mem.eql(u8, provider, "unknown")) {
        return std.fmt.bufPrint(buffer, "{s} \u{2022} no authenticated model", .{pct}) catch buffer[0..0];
    }
    return std.fmt.bufPrint(buffer, "{s} \u{2022} {s}/{s} ({s})", .{
        pct,
        provider,
        model,
        @tagName(chrome.thinking_level),
    }) catch {
        const bounded = vm.utf8Prefix(model, buffer.len);
        @memcpy(buffer[0..bounded.len], bounded);
        return buffer[0..bounded.len];
    };
}

fn appendNewItem(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    item: *const vm.ItemDelta,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    _ = sample;
    var item_cursor: ItemCursor = .{
        .id = item.id,
        .rev = item.rev,
        .consumed_len = item.text_suffix.len,
        .text_replaced_rev = item.text_replaced_at_rev,
        .state = item.state,
    };
    try updateToolFooter(gpa, &item_cursor, item);
    try cursor.items.append(gpa, item_cursor);
    const stored_cursor = &cursor.items.items[cursor.items.items.len - 1];
    try commands.append(gpa, .{ .append_transcript = appendCommandForItem(
        item,
        .new_item,
        stored_cursor.footer(item.footer.slice()),
    ) });
}

fn diffExistingItem(
    gpa: std.mem.Allocator,
    item: *const vm.ItemDelta,
    cursor: *ItemCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    if (item.full_text) {
        if (item.kind == .tool and item.tool != null) {
            const tool = &item.tool.?;
            try commands.append(gpa, .{ .replace_tool_output = .{
                .tool_call_id = tool.tool_call_id.slice(),
                .text = item.text_suffix,
            } });
        } else {
            try commands.append(gpa, .{ .append_transcript = appendCommandForItem(
                item,
                .new_item,
                cursor.footer(item.footer.slice()),
            ) });
        }
        cursor.text_replaced_rev = item.text_replaced_at_rev;
    } else if (item.text_suffix.len > 0) {
        try appendDeltaCommand(gpa, item, item.text_suffix, commands);
    }

    try updateToolFooter(gpa, cursor, item);
    const footer = cursor.footer(item.footer.slice());
    if (item.kind == .tool and item.tool != null and footer.len > 0) {
        try commands.append(gpa, .{ .replace_tool_footer = .{
            .tool_call_id = cursor.toolCallId(),
            .text = footer,
        } });
    }
    if (item.state == .canceled and cursor.state != .canceled) try commands.append(gpa, .mark_pending_tools_canceled);
    cursor.rev = item.rev;
    cursor.state = item.state;
}

fn appendDeltaCommand(
    gpa: std.mem.Allocator,
    item: *const vm.ItemDelta,
    delta: []const u8,
    commands: *std.ArrayList(tui.Command),
) !void {
    switch (item.kind) {
        .tool => if (item.tool) |*tool| try commands.append(gpa, .{ .tool_output_delta = .{
            .tool_call_id = tool.tool_call_id.slice(),
            .text = delta,
        } }),
        .assistant => try commands.append(gpa, .{ .append_transcript = .{ .message = .{
            .role = .assistant,
            .text = delta,
            .mode = .extend_previous_assistant_message,
        } } }),
        .user => try commands.append(gpa, .{ .append_transcript = .{ .message = .{
            .role = .user,
            .text = delta,
            .mode = .extend_previous_same_role,
        } } }),
        .thinking => try commands.append(gpa, .{ .append_transcript = .{ .thinking = .{
            .text = delta,
            .hidden = false,
            .mode = .extend_previous_same_role,
        } } }),
        .banner, .compaction_summary, .system_notice => {},
    }
}

fn appendCommandForItem(
    item: *const vm.ItemDelta,
    mode: tui.Transcript.AppendMode,
    footer: []const u8,
) tui.Transcript.Append {
    return switch (item.kind) {
        .user => .{ .message = .{ .role = .user, .text = item.text_suffix, .mode = mode } },
        .assistant => .{ .message = .{ .role = .assistant, .text = item.text_suffix, .mode = mode } },
        .thinking => .{ .thinking = .{ .text = item.text_suffix, .hidden = false, .mode = mode } },
        .tool => .{ .tool = toolAppend(item, footer) },
        .banner => .{ .custom = .{ .title = "notice", .text = item.text_suffix } },
        .compaction_summary => .{ .custom = .{ .title = "compaction", .text = item.text_suffix, .format = .markdown } },
        .system_notice => .{ .status = .{ .level = .info, .text = item.text_suffix } },
    };
}

fn toolAppend(item: *const vm.ItemDelta, footer: []const u8) tui.Transcript.Append.ToolAppend {
    // Pointer, not copy: the returned slices must point into the sample-owned
    // ItemDelta, never into this frame's stack.
    const tool = &item.tool.?;
    const display = tool.display;
    return .{
        .tool_call_id = tool.tool_call_id.slice(),
        .name = tool.name.slice(),
        .presentation = presentation(display.presentation),
        .status = toolStatus(item.state),
        .body_mode = bodyMode(display.body_mode),
        .collapse = .{ .mode = collapseMode(display.collapse.mode), .lines_max = display.collapse.lines_max },
        .title = tool.title.slice(),
        .compact_title = tool.title.slice(),
        .output = item.text_suffix,
        .footer = footer,
    };
}

fn presentation(value: coding_agent.tool_metadata.Presentation) tui.Transcript.ToolPresentation {
    return switch (value) {
        .generic => .generic,
        .command => .command,
        .file => .file,
        .patch => .patch,
    };
}

fn bodyMode(value: coding_agent.tool_metadata.BodyMode) tui.Transcript.ToolBodyMode {
    return switch (value) {
        .visible => .visible,
        .hidden_on_success => .hidden_on_success,
    };
}

fn collapseMode(value: coding_agent.tool_metadata.CollapseMode) tui.Transcript.ToolCollapseMode {
    return switch (value) {
        .head => .head,
        .tail => .tail,
    };
}

fn toolStatus(state: vm.Item.State) tui.Transcript.ToolStatus {
    return switch (state) {
        .streaming => .pending,
        .final => .success,
        .canceled => .canceled,
    };
}

fn updateToolFooter(gpa: std.mem.Allocator, cursor: *ItemCursor, item: *const vm.ItemDelta) !void {
    const tool = item.tool orelse {
        cursor.footer_len = 0;
        cursor.static_footer_len = 0;
        cursor.shows_duration = false;
        return;
    };
    cursor.shows_duration = tool.display.shows_duration;
    cursor.started_ms = tool.started_ms;
    cursor.duration_ms = tool.duration_ms;
    const call_id = tool.tool_call_id.slice();
    @memcpy(cursor.tool_call_id[0..call_id.len], call_id);
    cursor.tool_call_id_len = call_id.len;

    var metadata_buffer: [tool_view.metadata_bytes_max]u8 = undefined;
    const metadata = try toolMetadata(gpa, &metadata_buffer, tool.name.slice(), tool.details_json.slice());
    const static_footer = if (metadata.len > 0) metadata else item.footer.slice();
    copyCursorText(&cursor.static_footer_bytes, &cursor.static_footer_len, static_footer);
    renderToolFooter(cursor, null);
}

fn toolMetadata(
    gpa: std.mem.Allocator,
    buffer: []u8,
    tool_name: []const u8,
    details_json: []const u8,
) ![]const u8 {
    if (details_json.len == 0) return "";
    var parsed = std.json.parseFromSlice(std.json.Value, gpa, details_json, .{}) catch return "";
    defer parsed.deinit();
    return tool_view.metadataForDetails(buffer, tool_name, parsed.value);
}

fn renderToolFooter(cursor: *ItemCursor, running_elapsed_ms: ?u64) void {
    const static_footer = cursor.static_footer_bytes[0..cursor.static_footer_len];
    var duration_buffer: [32]u8 = undefined;
    const duration = if (cursor.duration_ms) |duration_ms|
        tool_view.durationChip(&duration_buffer, "took", duration_ms)
    else if (running_elapsed_ms) |elapsed_ms|
        tool_view.durationChip(&duration_buffer, "running", elapsed_ms)
    else if (cursor.started_ms != null)
        tool_view.durationChip(&duration_buffer, "running", 0)
    else
        "";

    if (!cursor.shows_duration or duration.len == 0) {
        copyCursorText(&cursor.footer_bytes, &cursor.footer_len, static_footer);
        return;
    }
    if (static_footer.len == 0) {
        copyCursorText(&cursor.footer_bytes, &cursor.footer_len, duration);
        return;
    }
    const joined = tool_view.joinMetadata(&cursor.footer_bytes, static_footer, duration);
    cursor.footer_len = joined.len;
}

fn copyCursorText(buffer: []u8, len: *usize, text: []const u8) void {
    const clipped = vm.utf8Prefix(text, buffer.len);
    @memcpy(buffer[0..clipped.len], clipped);
    len.* = clipped.len;
}

fn emitNotices(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    for (sample.notices.items) |notice| {
        if (notice.id <= cursor.last_notice_id) continue;
        var buffer: [512]u8 = undefined;
        const copy = failure_text.noticeCopy(&buffer, notice);
        try commands.append(gpa, .{ .notify = .{
            .key = @intCast(@min(notice.id, std.math.maxInt(u32))),
            .message = copy.text,
            .level = copy.level,
            .skip_dedup = true,
        } });
        cursor.last_notice_id = notice.id;
    }
}

fn emitOperation(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    if (sample.op.rev == cursor.op_rev) return;
    if (sample.op.cancel_requested) {
        try commands.append(gpa, .{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 100,
            .text = "cancel requested",
            .tone = .canceled,
        } });
        return;
    }
    switch (sample.op.phase) {
        .idle, .stopped => try commands.append(gpa, .{ .clear_status = .{
            .slot = .status_line,
            .id = status_id_working,
        } }),
        .running => try commands.append(gpa, .{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 100,
            .text = "working",
            .effect = .shimmer,
            .tone = .accent,
        } }),
        .compacting => try commands.append(gpa, .{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 100,
            .text = "compacting",
            .effect = .shimmer,
            .tone = .accent,
        } }),
        .retry_wait => |retry| try commands.append(gpa, .{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 100,
            .text = retry.reason.slice(),
            .tone = .warning,
        } }),
        .shutting_down => try commands.append(gpa, .{ .set_status = .{
            .slot = .status_line,
            .id = status_id_working,
            .priority = 100,
            .text = "shutting down",
            .tone = .secondary,
        } }),
    }
}

fn emitQueue(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    if (sample.queue.rev == cursor.queue_rev) return;
    const steering = sample.queue.steering.len;
    const follow_up = sample.queue.follow_up.len;
    if (steering == 0 and follow_up == 0) {
        try commands.append(gpa, .{ .clear_status = .{ .slot = .status_line, .id = status_id_queue } });
        return;
    }
    const text = std.fmt.bufPrint(&cursor.queue_status_bytes, "queued: {d} steering, {d} follow-up", .{
        steering,
        follow_up,
    }) catch "queued prompts";
    cursor.queue_status_len = text.len;
    try commands.append(gpa, .{ .set_status = .{
        .slot = .status_line,
        .id = status_id_queue,
        .priority = 80,
        .text = text,
        .tone = .secondary,
    } });
}

fn emitCompletion(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    const completion = sample.completion orelse return;
    if (completion.rev == cursor.completion_rev) return;
    if (completion.query_id != cursor.latest_query_id) return;
    if (cursor.latest_query_kind != .none and completion.kind != cursor.latest_query_kind) return;
    const command = try pickers.commandForCompletion(gpa, completion) orelse return;
    try commands.append(gpa, command);
}

fn oneItemSample(gpa: std.mem.Allocator, item: *const vm.Item, chrome: vm.Chrome) !vm.Sample {
    var sample: vm.Sample = .{
        .generation = 1,
        .session_epoch = 1,
        .chrome = chrome,
        .op = .{},
        .queue = .{},
        .evicted_through_id = 0,
        .items = .empty,
        .history = null,
        .completion = null,
        .notices = .empty,
        .partial = false,
    };
    errdefer sample.deinit(gpa);
    try sample.items.append(gpa, try vm.ItemDelta.init(gpa, item, item.text.items, true));
    return sample;
}

test "new item append golden" {
    const gpa = std.testing.allocator;
    var item: vm.Item = .{ .id = 1, .kind = .assistant, .state = .streaming };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "hello");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{};
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expect(out.commands.items[0] == .clear_transcript);
    try std.testing.expect(out.commands.items[out.commands.items.len - 1] == .append_transcript);
    try std.testing.expectEqualStrings(
        "hello",
        out.commands.items[out.commands.items.len - 1].append_transcript.message.text,
    );
}

test "streaming delta append via consumed_len" {
    const gpa = std.testing.allocator;
    var item: vm.Item = .{ .id = 1, .kind = .assistant, .state = .streaming, .rev = 1 };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "he");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1 };
    defer cursor.deinit(gpa);
    var first = try diff(gpa, &sample, &cursor);
    first.deinit(gpa);
    gpa.free(sample.items.items[0].text_suffix);
    sample.items.items[0].text_suffix = try gpa.dupe(u8, "llo");
    sample.items.items[0].full_text = false;
    sample.items.items[0].rev += 1;
    var second = try diff(gpa, &sample, &cursor);
    defer second.deinit(gpa);
    try std.testing.expectEqualStrings("llo", second.commands.items[0].append_transcript.message.text);
}

test "text_replaced full replace and footer change" {
    const gpa = std.testing.allocator;
    var tool: vm.ToolMeta = .{};
    tool.tool_call_id.set("t1");
    tool.name.set("bash");
    var item: vm.Item = .{ .id = 1, .kind = .tool, .state = .streaming, .tool = tool };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "old");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1 };
    defer cursor.deinit(gpa);
    var first = try diff(gpa, &sample, &cursor);
    first.deinit(gpa);
    gpa.free(sample.items.items[0].text_suffix);
    sample.items.items[0].text_suffix = try gpa.dupe(u8, "new");
    sample.items.items[0].full_text = true;
    sample.items.items[0].rev += 1;
    sample.items.items[0].text_replaced_at_rev = sample.items.items[0].rev;
    sample.items.items[0].footer.set("done");
    var second = try diff(gpa, &sample, &cursor);
    defer second.deinit(gpa);
    try std.testing.expect(second.commands.items[0] == .replace_tool_output);
    try std.testing.expectEqualStrings("new", second.commands.items[0].replace_tool_output.text);
    try std.testing.expect(second.commands.items[1] == .replace_tool_footer);
}

test "tool duration footer golden" {
    const gpa = std.testing.allocator;
    var tool: vm.ToolMeta = .{};
    tool.tool_call_id.set("t1");
    tool.name.set("bash");
    tool.display = coding_agent.tool_metadata.displayForTool("bash");
    tool.duration_ms = 1234;
    var item: vm.Item = .{ .id = 1, .kind = .tool, .state = .streaming, .tool = tool, .rev = 1 };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "out");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1 };
    defer cursor.deinit(gpa);
    var first = try diff(gpa, &sample, &cursor);
    defer first.deinit(gpa);
    const append = first.commands.items[first.commands.items.len - 1].append_transcript;
    try std.testing.expectEqualStrings("took 1.2s", append.tool.footer);
}

test "bash truncation details join duration footer golden" {
    const gpa = std.testing.allocator;
    var tool: vm.ToolMeta = .{};
    tool.tool_call_id.set("t1");
    tool.name.set("bash");
    tool.display = coding_agent.tool_metadata.displayForTool("bash");
    tool.duration_ms = 1234;
    tool.details_json.set(
        "{\"exitCode\":1,\"truncation\":{\"truncated\":true,\"truncatedBy\":\"lines\"," ++
            "\"outputLines\":5,\"totalLines\":100,\"outputBytes\":16,\"maxBytes\":51200}}",
    );
    var item: vm.Item = .{ .id = 1, .kind = .tool, .state = .streaming, .tool = tool, .rev = 1 };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "line 96\nline 100");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1 };
    defer cursor.deinit(gpa);
    var first = try diff(gpa, &sample, &cursor);
    defer first.deinit(gpa);
    const append = first.commands.items[first.commands.items.len - 1].append_transcript;
    try std.testing.expectEqualStrings("Truncated: showing 5 of 100 lines • took 1.2s", append.tool.footer);
}

test "tool duration tick footer golden" {
    const gpa = std.testing.allocator;
    var tool: vm.ToolMeta = .{};
    tool.tool_call_id.set("t1");
    tool.name.set("bash");
    tool.display = coding_agent.tool_metadata.displayForTool("bash");
    tool.started_ms = 1_000;
    var item: vm.Item = .{ .id = 1, .kind = .tool, .state = .streaming, .tool = tool, .rev = 1 };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "out");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1 };
    defer cursor.deinit(gpa);
    var first = try diff(gpa, &sample, &cursor);
    first.deinit(gpa);
    var tick = try tickDurations(gpa, &cursor, 2_250);
    defer tick.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), tick.commands.items.len);
    try std.testing.expectEqualStrings("running 1.2s", tick.commands.items[0].replace_tool_footer.text);
}

test "epoch reset produces clear_transcript" {
    const gpa = std.testing.allocator;
    var item: vm.Item = .{ .id = 1, .kind = .user, .state = .streaming };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "u");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 99 };
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expect(out.commands.items[0] == .clear_transcript);
}

test "hide_thinking filters first append" {
    const gpa = std.testing.allocator;
    var item: vm.Item = .{ .id = 1, .kind = .thinking, .state = .streaming };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "secret");
    var chrome: vm.Chrome = .{};
    chrome.hide_thinking = true;
    var sample = try oneItemSample(gpa, &item, chrome);
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{};
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expect(out.commands.items[0] == .clear_transcript);
}

test "stale completion query_id ignored" {
    const gpa = std.testing.allocator;
    var sample: vm.Sample = .{
        .generation = 1,
        .session_epoch = 1,
        .chrome = .{},
        .op = .{},
        .queue = .{},
        .evicted_through_id = 0,
        .items = .empty,
        .history = null,
        .completion = .{ .rev = 2, .query_id = 1, .kind = .file },
        .notices = .empty,
        .partial = false,
    };
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{ .epoch = 1, .latest_query_id = 2, .chrome_rev = 1 };
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), out.commands.items.len);
}

test "streaming turn paints incremental assistant text through the full chain" {
    const gpa = std.testing.allocator;
    const engine_drain = @import("../../coding_agent/engine_drain.zig");
    const ai_mod = @import("../../ai/root.zig");
    const agent_mod = @import("../../agent/root.zig");

    var model = try vm.ViewModel.init(gpa);
    defer model.deinit(gpa);
    var drain = engine_drain.EngineDrain.init(gpa, &model);
    defer drain.deinit();

    var reader_cursor: vm.ReaderCursor = .{};
    defer reader_cursor.deinit(gpa);
    var view_cursor: ViewCursor = .{};
    defer view_cursor.deinit(gpa);

    const user_message = agent_mod.AgentMessage{ .user = .{
        .content = .{ .string = "hi" },
        .timestamp = 0,
    } };
    try drain.agentEvent(.{ .message_start = .{ .message = user_message } });
    try drain.agentEvent(.{ .message_end = .{ .message = user_message } });

    const deltas = [_][]const u8{ "alpha ", "beta ", "gamma" };
    var accumulated: std.ArrayList(u8) = .empty;
    defer accumulated.deinit(gpa);
    var streamed_assistant_bytes: usize = 0;

    for (deltas, 0..) |delta, index| {
        try accumulated.appendSlice(gpa, delta);
        const content = [_]ai_mod.AssistantContent{ai_mod.faux.text(accumulated.items)};
        const partial = ai_mod.faux.assistantMessage(&content, .{});
        if (index == 0) {
            try drain.agentEvent(.{ .message_start = .{ .message = .{ .assistant = partial } } });
        }
        try drain.agentEvent(.{ .message_update = .{ .assistant_message_event = .{ .text_delta = .{
            .content_index = 0,
            .delta = delta,
            .partial = partial,
        } } } });

        // Mirrors frame_loop.sampleViewModel: sample, guard, diff.
        var sample = try model.sample(gpa, &reader_cursor, vm.sample_bytes_per_frame_max);
        defer sample.deinit(gpa);
        if (!(sample.generation == view_cursor.generation and
            sample.session_epoch == view_cursor.epoch and
            !sample.partial))
        {
            var out = try diff(gpa, &sample, &view_cursor);
            defer out.deinit(gpa);
            for (out.commands.items) |command| switch (command) {
                .append_transcript => |append| switch (append) {
                    .message => |message| {
                        if (message.role == .assistant) streamed_assistant_bytes += message.text.len;
                    },
                    else => {},
                },
                else => {},
            };
        }
    }

    // Every streamed byte must have been painted before the final replace.
    try std.testing.expectEqual(accumulated.items.len, streamed_assistant_bytes);
}
