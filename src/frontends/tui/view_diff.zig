const std = @import("std");

const coding_agent = @import("../../coding_agent/root.zig");
const tui = @import("../../tui/root.zig");

const vm = coding_agent.view_model;

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

    pub fn deinit(self: *ViewCursor, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn noteQuery(self: *ViewCursor, query_id: u64) void {
        self.latest_query_id = query_id;
    }

    fn resetForEpoch(self: *ViewCursor, gpa: std.mem.Allocator, epoch: u32) void {
        self.items.clearRetainingCapacity();
        _ = gpa;
        self.* = .{ .epoch = epoch, .latest_query_id = self.latest_query_id };
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
};

pub const DiffResult = struct {
    commands: std.ArrayList(tui.Command),

    pub fn deinit(self: *DiffResult, gpa: std.mem.Allocator) void {
        self.commands.deinit(gpa);
        self.* = undefined;
    }
};

pub fn diff(gpa: std.mem.Allocator, sample: *const vm.Sample, cursor: *ViewCursor) !DiffResult {
    var result = DiffResult{ .commands = .empty };
    errdefer result.deinit(gpa);

    if (cursor.epoch != sample.session_epoch) {
        cursor.resetForEpoch(gpa, sample.session_epoch);
        try result.commands.append(gpa, .clear_transcript);
    }

    try emitNotices(gpa, sample, cursor, &result.commands);
    try emitCompletion(gpa, sample, cursor, &result.commands);

    for (sample.items.items) |*item| {
        if (item.kind == .thinking and item.state == .streaming and sample.chrome.hide_thinking and cursor.findItem(item.id) == null) {
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

fn appendNewItem(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    item: *const vm.ItemDelta,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    _ = sample;
    try commands.append(gpa, .{ .append_transcript = appendCommandForItem(item, .new_item) });
    try cursor.items.append(gpa, .{
        .id = item.id,
        .rev = item.rev,
        .consumed_len = item.text_suffix.len,
        .text_replaced_rev = item.text_replaced_at_rev,
        .state = item.state,
    });
}

fn diffExistingItem(
    gpa: std.mem.Allocator,
    item: *const vm.ItemDelta,
    cursor: *ItemCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    if (item.full_text) {
        if (item.kind == .tool and item.tool != null) {
            try commands.append(gpa, .{ .replace_tool_output = .{
                .tool_call_id = item.tool.?.tool_call_id.slice(),
                .text = item.text_suffix,
            } });
        } else {
            try commands.append(gpa, .{ .append_transcript = appendCommandForItem(item, .new_item) });
        }
        cursor.text_replaced_rev = item.text_replaced_at_rev;
    } else if (item.text_suffix.len > 0) {
        try appendDeltaCommand(gpa, item, item.text_suffix, commands);
    }

    if (item.kind == .tool and item.tool != null and item.footer.slice().len > 0) {
        try commands.append(gpa, .{ .replace_tool_footer = .{
            .tool_call_id = item.tool.?.tool_call_id.slice(),
            .text = item.footer.slice(),
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
        .tool => if (item.tool) |tool| try commands.append(gpa, .{ .tool_output_delta = .{
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

fn appendCommandForItem(item: *const vm.ItemDelta, mode: tui.Transcript.AppendMode) tui.Transcript.Append {
    return switch (item.kind) {
        .user => .{ .message = .{ .role = .user, .text = item.text_suffix, .mode = mode } },
        .assistant => .{ .message = .{ .role = .assistant, .text = item.text_suffix, .mode = mode } },
        .thinking => .{ .thinking = .{ .text = item.text_suffix, .hidden = false, .mode = mode } },
        .tool => .{ .tool = toolAppend(item) },
        .banner => .{ .custom = .{ .title = "notice", .text = item.text_suffix } },
        .compaction_summary => .{ .custom = .{ .title = "compaction", .text = item.text_suffix, .format = .markdown } },
        .system_notice => .{ .status = .{ .level = .info, .text = item.text_suffix } },
    };
}

fn toolAppend(item: *const vm.ItemDelta) tui.Transcript.Append.ToolAppend {
    const tool = item.tool.?;
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
        .footer = item.footer.slice(),
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

fn emitNotices(
    gpa: std.mem.Allocator,
    sample: *const vm.Sample,
    cursor: *ViewCursor,
    commands: *std.ArrayList(tui.Command),
) !void {
    for (sample.notices.items) |notice| {
        if (notice.id <= cursor.last_notice_id) continue;
        try commands.append(gpa, .{ .notify = .{
            .key = @intCast(@min(notice.id, std.math.maxInt(u32))),
            .message = notice.text.slice(),
            .level = switch (notice.severity) {
                .info => .info,
                .warn => .warning,
                .err => .err,
            },
            .skip_dedup = true,
        } });
        cursor.last_notice_id = notice.id;
    }
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
    if (completion.kind == .none) return;
    var items = try gpa.alloc(tui.Picker.Item, completion.items.items.len);
    errdefer gpa.free(items);
    for (completion.items.items, 0..) |item, index| {
        items[index] = .{ .id = item.id.slice(), .label = item.label.slice(), .detail = item.detail.slice() };
    }
    switch (completion.kind) {
        .file => try commands.append(gpa, .{ .set_file_completions = .{ .id = @intCast(completion.query_id), .items = items } }),
        .model, .resume_session, .settings => try commands.append(gpa, .{ .open_picker = .{ .id = @intCast(completion.query_id), .items = items } }),
        .slash_arg => {},
        .none => {},
    }
}

fn oneItemSample(gpa: std.mem.Allocator, item: *const vm.Item, chrome: vm.Chrome) !vm.Sample {
    var sample = vm.Sample{
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
    var item = vm.Item{ .id = 1, .kind = .assistant, .state = .streaming };
    defer item.deinit(gpa);
    try item.text.appendSlice(gpa, "hello");
    var sample = try oneItemSample(gpa, &item, .{});
    defer sample.deinit(gpa);
    var cursor: ViewCursor = .{};
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 2), out.commands.items.len);
    try std.testing.expect(out.commands.items[0] == .clear_transcript);
    try std.testing.expectEqualStrings("hello", out.commands.items[1].append_transcript.message.text);
}

test "streaming delta append via consumed_len" {
    const gpa = std.testing.allocator;
    var item = vm.Item{ .id = 1, .kind = .assistant, .state = .streaming, .rev = 1 };
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
    var item = vm.Item{ .id = 1, .kind = .tool, .state = .streaming, .tool = tool };
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

test "epoch reset produces clear_transcript" {
    const gpa = std.testing.allocator;
    var item = vm.Item{ .id = 1, .kind = .user, .state = .streaming };
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
    var item = vm.Item{ .id = 1, .kind = .thinking, .state = .streaming };
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
    try std.testing.expectEqual(@as(usize, 1), out.commands.items.len);
    try std.testing.expect(out.commands.items[0] == .clear_transcript);
}

test "stale completion query_id ignored" {
    const gpa = std.testing.allocator;
    var sample = vm.Sample{
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
    var cursor: ViewCursor = .{ .epoch = 1, .latest_query_id = 2 };
    defer cursor.deinit(gpa);
    var out = try diff(gpa, &sample, &cursor);
    defer out.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 0), out.commands.items.len);
}
