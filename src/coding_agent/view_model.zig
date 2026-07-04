const std = @import("std");
const runtime = @import("../runtime/root.zig");
const tool_metadata = @import("tool_metadata.zig");

pub const frame_interval_ms: i64 = 16;
pub const idle_wait_ms: i64 = 30_000;
pub const sample_bytes_per_frame_max: usize = 64 * 1024;
pub const resident_items_max: usize = 256;
pub const transcript_resident_bytes_max: usize = 512 * 1024;
pub const notice_ring_len: usize = 32;
pub const completion_items_max: usize = 64;
pub const queue_echo_cap: usize = 8;
pub const reader_wake_list_max: usize = 4;

pub const cwd_bytes_max: usize = 1024;
pub const footer_bytes_max: usize = 256;
pub const assistant_text_bytes_max: usize = 256 * 1024;
pub const thinking_text_bytes_max: usize = assistant_text_bytes_max;
pub const tool_output_bytes_max: usize = 64 * 1024;
pub const history_item_text_bytes_max: usize = 16 * 1024;
pub const history_page_item_text_bytes_max: usize = history_item_text_bytes_max;
pub const history_page_total_text_bytes_max: usize = 64 * 1024;
pub const snapshot_history_item_text_bytes_max: usize = history_item_text_bytes_max;
pub const snapshot_history_total_text_bytes_max: usize = 128 * 1024;

pub fn utf8Prefix(value: []const u8, max_bytes: usize) []const u8 {
    if (value.len <= max_bytes) return value;
    var end = max_bytes;
    while (end > 0 and (value[end] & 0xc0) == 0x80) : (end -= 1) {}
    return value[0..end];
}

pub fn BoundedText(comptime cap: usize) type {
    return struct {
        bytes: [cap]u8 = undefined,
        len: u16 = 0,

        pub fn init(text: []const u8) @This() {
            var self: @This() = .{};
            self.set(text);
            return self;
        }

        pub fn set(self: *@This(), text: []const u8) void {
            const clipped = utf8Prefix(text, cap);
            @memcpy(self.bytes[0..clipped.len], clipped);
            self.len = @intCast(clipped.len);
        }

        pub fn slice(self: *const @This()) []const u8 {
            return self.bytes[0..self.len];
        }

        pub fn eql(self: *const @This(), other: []const u8) bool {
            return std.mem.eql(u8, self.slice(), other);
        }
    };
}

pub fn BoundedArray(comptime T: type, comptime cap: usize) type {
    return struct {
        items: [cap]T = undefined,
        len: usize = 0,

        pub fn append(self: *@This(), item: T) bool {
            if (self.len >= cap) return false;
            self.items[self.len] = item;
            self.len += 1;
            return true;
        }

        pub fn removeById(self: *@This(), id: u64) bool {
            var index: usize = 0;
            while (index < self.len) : (index += 1) {
                if (self.items[index].id != id) continue;
                std.mem.copyForwards(T, self.items[index .. self.len - 1], self.items[index + 1 .. self.len]);
                self.len -= 1;
                return true;
            }
            return false;
        }

        pub fn slice(self: *const @This()) []const T {
            return self.items[0..self.len];
        }
    };
}

pub const ThinkingLevel = enum { off, minimal, low, medium, high, xhigh };
pub const CompactionTrigger = enum { manual, context_overflow, startup };

pub const ViewModel = struct {
    mutex: runtime.SharedMutex = .{},
    generation: u64 = 0,
    session_epoch: u32 = 0,

    chrome: Chrome = .{},
    op: OperationStatus = .{},
    queue: QueueEcho = .{},
    transcript: ItemStore = .{},
    history: HistoryWindow = .{},
    completion: CompletionSlot = .{},
    notices: NoticeRing = .{},

    pub fn init(gpa: std.mem.Allocator) !ViewModel {
        _ = gpa;
        return .{};
    }

    pub fn deinit(self: *ViewModel, gpa: std.mem.Allocator) void {
        self.transcript.deinit(gpa);
        self.history.deinit(gpa);
        self.completion.deinit(gpa);
        self.* = undefined;
    }

    pub fn lockWriter(self: *ViewModel) Writer {
        self.mutex.lock();
        return .{ .vm = self, .timer = runtime.SharedMutexHoldTimer.start() };
    }

    pub fn sample(
        self: *ViewModel,
        gpa: std.mem.Allocator,
        cursor: *ReaderCursor,
        max_bytes: usize,
    ) !Sample {
        self.mutex.lock();
        const timer = runtime.SharedMutexHoldTimer.start();
        defer {
            timer.assertUnderLimit();
            self.mutex.unlock();
        }

        if (self.session_epoch != cursor.session_epoch) {
            cursor.resetForEpoch();
            cursor.session_epoch = self.session_epoch;
        }
        cursor.pruneEvicted(self.transcript.evicted_through_id);

        var out = Sample{
            .generation = self.generation,
            .session_epoch = self.session_epoch,
            .chrome = self.chrome,
            .op = self.op,
            .queue = self.queue,
            .evicted_through_id = self.transcript.evicted_through_id,
            .history = null,
            .completion = null,
            .items = .empty,
            .notices = .empty,
            .partial = false,
        };
        errdefer out.deinit(gpa);

        if (self.generation == cursor.generation) return out;

        var bytes: usize = 0;
        for (self.transcript.items.items) |*item| {
            var item_cursor = try cursor.getItem(gpa, item.id);
            if (item.rev == item_cursor.rev and item.text.items.len == item_cursor.consumed_len) continue;

            const replacement = item.text_replaced_at_rev != null and item_cursor.rev < item.text_replaced_at_rev.?;
            const start = if (replacement) 0 else @min(item_cursor.consumed_len, item.text.items.len);
            const suffix = item.text.items[start..];
            const remaining = max_bytes -| bytes;
            if (remaining == 0 and suffix.len > 0) {
                out.partial = true;
                break;
            }
            const take = if (suffix.len > remaining) utf8Prefix(suffix, remaining) else suffix;
            if (take.len == 0 and suffix.len > 0) {
                out.partial = true;
                break;
            }

            try out.items.append(gpa, try ItemDelta.init(gpa, item, take, start == 0));
            bytes += take.len;
            item_cursor.consumed_len = start + take.len;
            if (item_cursor.consumed_len == item.text.items.len) {
                item_cursor.rev = item.rev;
            } else {
                out.partial = true;
                break;
            }
        }

        if (!out.partial and self.history.rev != cursor.history_rev) out.history = try self.history.clone(gpa);
        if (!out.partial and self.completion.rev != cursor.completion_rev) out.completion = try self.completion.clone(gpa);
        if (!out.partial) try self.notices.copySince(gpa, &out.notices, cursor.last_seen_notice_id);

        if (!out.partial) {
            cursor.generation = self.generation;
            cursor.history_rev = self.history.rev;
            cursor.completion_rev = self.completion.rev;
            cursor.last_seen_notice_id = self.notices.latestId();
        }
        return out;
    }
};

pub const Writer = struct {
    vm: *ViewModel,
    timer: runtime.SharedMutexHoldTimer,
    touched: bool = false,

    pub fn bumpEpoch(self: *Writer) void {
        self.vm.session_epoch +%= 1;
        self.touched = true;
    }

    pub fn setChrome(self: *Writer, chrome: Chrome) void {
        self.vm.chrome = chrome;
        self.vm.chrome.bumpRev();
        self.touched = true;
    }

    pub fn addItem(
        self: *Writer,
        gpa: std.mem.Allocator,
        kind: Item.Kind,
        state: Item.State,
        text: []const u8,
        tool: ?ToolMeta,
    ) !u64 {
        const id = try self.vm.transcript.append(gpa, kind, state, text, tool);
        self.touched = true;
        return id;
    }

    pub fn appendItemText(self: *Writer, gpa: std.mem.Allocator, id: u64, text: []const u8) !void {
        try self.vm.transcript.appendText(gpa, id, text);
        self.touched = true;
    }

    pub fn replaceItemText(self: *Writer, gpa: std.mem.Allocator, id: u64, text: []const u8) !void {
        try self.vm.transcript.replaceText(gpa, id, text);
        self.touched = true;
    }

    pub fn setItemFooter(self: *Writer, id: u64, footer: []const u8) !void {
        try self.vm.transcript.setFooter(id, footer);
        self.touched = true;
    }

    pub fn pushNotice(self: *Writer, severity: Notice.Severity, semantic: NoticeSemantic, text: []const u8) void {
        self.vm.notices.push(severity, semantic, text);
        self.touched = true;
    }

    pub fn finish(self: *Writer) void {
        if (self.touched) self.vm.generation +%= 1;
        self.timer.assertUnderLimit();
        self.vm.mutex.unlock();
        self.* = undefined;
    }
};

pub const ReaderCursor = struct {
    generation: u64 = 0,
    session_epoch: u32 = 0,
    last_seen_notice_id: u64 = 0,
    history_rev: u32 = 0,
    completion_rev: u32 = 0,
    items: std.ArrayList(ReaderItemCursor) = .empty,

    pub fn deinit(self: *ReaderCursor, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }

    fn resetForEpoch(self: *ReaderCursor) void {
        self.generation = 0;
        self.last_seen_notice_id = 0;
        self.history_rev = 0;
        self.completion_rev = 0;
        self.items.clearRetainingCapacity();
    }

    fn pruneEvicted(self: *ReaderCursor, evicted_through_id: u64) void {
        var i: usize = 0;
        while (i < self.items.items.len) {
            if (self.items.items[i].id <= evicted_through_id) {
                _ = self.items.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    fn findItem(self: *ReaderCursor, id: u64) ?*ReaderItemCursor {
        for (self.items.items) |*item| if (item.id == id) return item;
        return null;
    }

    fn getItem(self: *ReaderCursor, gpa: std.mem.Allocator, id: u64) !*ReaderItemCursor {
        if (self.findItem(id)) |item| return item;
        try self.items.append(gpa, .{ .id = id });
        return &self.items.items[self.items.items.len - 1];
    }
};

pub const ReaderItemCursor = struct {
    id: u64,
    rev: u32 = 0,
    consumed_len: usize = 0,
};

pub const Chrome = struct {
    rev: u32 = 1,
    cwd: BoundedText(cwd_bytes_max) = .{},
    model_id: BoundedText(128) = .{},
    model_label: BoundedText(128) = .{},
    provider_label: BoundedText(64) = .{},
    thinking_level: ThinkingLevel = .off,
    hide_thinking: bool = true,
    context_used_pct: ?u8 = null,
    session_title: BoundedText(256) = .{},

    pub fn bumpRev(self: *Chrome) void {
        self.rev +%= 1;
        if (self.rev == 0) self.rev = 1;
    }
};

pub const OperationStatus = struct {
    rev: u32 = 1,
    phase: Phase = .idle,
    cancel_requested: bool = false,

    pub const Phase = union(enum) {
        idle,
        running: struct { op_id: u64, started_ms: i64 },
        compacting: struct { op_id: u64, started_ms: i64, trigger: CompactionTrigger },
        retry_wait: struct { until_ms: i64, attempt: u32, reason: BoundedText(256) },
        shutting_down,
        stopped,
    };
};

pub const QueueEcho = struct {
    rev: u32 = 1,
    steering: BoundedArray(QueuedPrompt, queue_echo_cap) = .{},
    follow_up: BoundedArray(QueuedPrompt, queue_echo_cap) = .{},
    dropped: u8 = 0,

    pub fn enqueueSteering(self: *QueueEcho, item: QueuedPrompt) void {
        if (!self.steering.append(item)) self.dropped +|= 1;
        self.bumpRev();
    }

    pub fn enqueueFollowUp(self: *QueueEcho, item: QueuedPrompt) void {
        if (!self.follow_up.append(item)) self.dropped +|= 1;
        self.bumpRev();
    }

    pub fn removeById(self: *QueueEcho, id: u64) bool {
        const removed = self.steering.removeById(id) or self.follow_up.removeById(id);
        if (removed) self.bumpRev();
        return removed;
    }

    fn bumpRev(self: *QueueEcho) void {
        self.rev +%= 1;
        if (self.rev == 0) self.rev = 1;
    }
};

pub const QueuedPrompt = struct { id: u64, text: BoundedText(256) };

pub const ItemStore = struct {
    items: std.ArrayList(Item) = .empty,
    evicted_through_id: u64 = 0,
    next_item_id: u64 = 1,

    pub fn deinit(self: *ItemStore, gpa: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn append(
        self: *ItemStore,
        gpa: std.mem.Allocator,
        kind: Item.Kind,
        state: Item.State,
        text: []const u8,
        tool: ?ToolMeta,
    ) !u64 {
        const id = self.next_item_id;
        self.next_item_id += 1;
        var item = Item{ .id = id, .kind = kind, .state = state, .tool = tool };
        errdefer item.deinit(gpa);
        try item.appendStreaming(gpa, text);
        try self.items.append(gpa, item);
        self.evictOldest(gpa);
        return id;
    }

    pub fn appendText(self: *ItemStore, gpa: std.mem.Allocator, id: u64, text: []const u8) !void {
        const item = self.find(id) orelse return error.UnknownItem;
        try item.appendStreaming(gpa, text);
        self.evictOldest(gpa);
    }

    pub fn replaceText(self: *ItemStore, gpa: std.mem.Allocator, id: u64, text: []const u8) !void {
        const item = self.find(id) orelse return error.UnknownItem;
        try item.replaceText(gpa, text);
        self.evictOldest(gpa);
    }

    pub fn setFooter(self: *ItemStore, id: u64, footer: []const u8) !void {
        const item = self.find(id) orelse return error.UnknownItem;
        item.footer.set(footer);
        item.bumpRev();
    }

    fn find(self: *ItemStore, id: u64) ?*Item {
        for (self.items.items) |*item| if (item.id == id) return item;
        return null;
    }

    fn evictOldest(self: *ItemStore, gpa: std.mem.Allocator) void {
        while (self.items.items.len > resident_items_max or self.residentTextBytes() > transcript_resident_bytes_max) {
            if (self.items.items.len <= 1) break;
            self.evicted_through_id = self.items.items[0].id;
            self.items.items[0].deinit(gpa);
            _ = self.items.orderedRemove(0);
        }
    }

    fn residentTextBytes(self: *const ItemStore) usize {
        var total: usize = 0;
        for (self.items.items) |*item| total += item.text.items.len;
        return total;
    }
};

pub const Item = struct {
    id: u64,
    rev: u32 = 1,
    kind: Kind,
    state: State,
    entry_id: ?u64 = null,
    text: std.ArrayList(u8) = .empty,
    text_replaced_at_rev: ?u32 = null,
    footer: BoundedText(footer_bytes_max) = .{},
    tool: ?ToolMeta = null,

    pub const Kind = enum { user, assistant, thinking, tool, banner, compaction_summary, system_notice };
    pub const State = enum { streaming, final, canceled };

    pub fn deinit(self: *Item, gpa: std.mem.Allocator) void {
        self.text.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const Item, gpa: std.mem.Allocator) !Item {
        var out = self.*;
        out.text = .empty;
        errdefer out.text.deinit(gpa);
        try out.text.appendSlice(gpa, self.text.items);
        return out;
    }

    pub fn appendStreaming(self: *Item, gpa: std.mem.Allocator, text: []const u8) !void {
        if (self.state != .streaming) return error.NotStreaming;
        const cap = textCap(self.kind);
        if (self.text.items.len >= cap) {
            if (self.setTruncated()) self.bumpRev();
            return;
        }
        const clipped = utf8Prefix(text, cap - self.text.items.len);
        try self.text.appendSlice(gpa, clipped);
        _ = if (clipped.len < text.len) self.setTruncated() else false;
        self.bumpRev();
    }

    pub fn replaceText(self: *Item, gpa: std.mem.Allocator, text: []const u8) !void {
        const clipped = utf8Prefix(text, textCap(self.kind));
        var next: std.ArrayList(u8) = .empty;
        errdefer next.deinit(gpa);
        try next.appendSlice(gpa, clipped);
        self.text.deinit(gpa);
        self.text = next;
        self.bumpRev();
        self.text_replaced_at_rev = self.rev;
        _ = if (clipped.len < text.len) self.setTruncated() else false;
    }

    pub fn sampleBytes(self: *const Item) usize {
        return self.text.items.len + self.footer.slice().len + 128;
    }

    fn setTruncated(self: *Item) bool {
        const changed = !self.footer.eql("output truncated") or
            (self.tool != null and !self.tool.?.exit_meta.eql("truncated"));
        self.footer.set("output truncated");
        if (self.tool) |*tool| tool.exit_meta.set("truncated");
        return changed;
    }

    fn bumpRev(self: *Item) void {
        self.rev +%= 1;
        if (self.rev == 0) self.rev = 1;
    }
};

pub const ItemDelta = struct {
    id: u64,
    rev: u32,
    kind: Item.Kind,
    state: Item.State,
    entry_id: ?u64,
    text_suffix: []u8,
    full_text: bool,
    text_replaced_at_rev: ?u32,
    text_len: usize,
    footer: BoundedText(footer_bytes_max),
    tool: ?ToolMeta,

    pub fn init(gpa: std.mem.Allocator, item: *const Item, text_suffix: []const u8, full_text: bool) !ItemDelta {
        return .{
            .id = item.id,
            .rev = item.rev,
            .kind = item.kind,
            .state = item.state,
            .entry_id = item.entry_id,
            .text_suffix = try gpa.dupe(u8, text_suffix),
            .full_text = full_text,
            .text_replaced_at_rev = item.text_replaced_at_rev,
            .text_len = if (full_text) text_suffix.len else item.text.items.len,
            .footer = item.footer,
            .tool = item.tool,
        };
    }

    pub fn deinit(self: *ItemDelta, gpa: std.mem.Allocator) void {
        gpa.free(self.text_suffix);
        self.* = undefined;
    }
};

fn textCap(kind: Item.Kind) usize {
    return switch (kind) {
        .assistant => assistant_text_bytes_max,
        .thinking => thinking_text_bytes_max,
        .tool => tool_output_bytes_max,
        .user, .banner, .compaction_summary, .system_notice => assistant_text_bytes_max,
    };
}

pub const ToolMeta = struct {
    tool_call_id: BoundedText(128) = .{},
    name: BoundedText(64) = .{},
    title: BoundedText(256) = .{},
    display: tool_metadata.Display = .{},
    streams_output: bool = false,
    started_ms: ?i64 = null,
    duration_ms: ?u64 = null,
    exit_meta: BoundedText(128) = .{},
};

pub const HistoryWindow = struct {
    rev: u32 = 1,
    state: State = .closed,
    items: std.ArrayList(Item) = .empty,
    has_more_before: bool = false,
    has_more_after: bool = false,
    oldest_entry_id: ?u64 = null,
    newest_entry_id: ?u64 = null,

    pub const State = enum { closed, loading, open };

    pub fn deinit(self: *HistoryWindow, gpa: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const HistoryWindow, gpa: std.mem.Allocator) !HistoryWindow {
        var out = self.*;
        out.items = .empty;
        errdefer out.deinit(gpa);
        for (self.items.items) |*item| try out.items.append(gpa, try item.clone(gpa));
        return out;
    }
};

pub const CompletionSlot = struct {
    rev: u32 = 1,
    query_id: u64 = 0,
    kind: Kind = .none,
    items: std.ArrayList(CompletionItem) = .empty,

    pub const Kind = enum { none, file, model, resume_session, slash_arg, settings };

    pub fn deinit(self: *CompletionSlot, gpa: std.mem.Allocator) void {
        self.items.deinit(gpa);
        self.* = undefined;
    }

    pub fn clone(self: *const CompletionSlot, gpa: std.mem.Allocator) !CompletionSlot {
        var out = self.*;
        out.items = .empty;
        errdefer out.items.deinit(gpa);
        const keep = @min(self.items.items.len, completion_items_max);
        try out.items.appendSlice(gpa, self.items.items[0..keep]);
        return out;
    }

    pub fn set(self: *CompletionSlot, gpa: std.mem.Allocator, query_id: u64, kind: Kind, items: []const CompletionItem) !void {
        var next: std.ArrayList(CompletionItem) = .empty;
        errdefer next.deinit(gpa);
        const keep = @min(items.len, completion_items_max);
        try next.appendSlice(gpa, items[0..keep]);
        self.items.deinit(gpa);
        self.items = next;
        self.query_id = query_id;
        self.kind = kind;
        self.rev +%= 1;
        if (self.rev == 0) self.rev = 1;
    }
};

pub const CompletionItem = struct {
    id: BoundedText(256) = .{},
    label: BoundedText(256) = .{},
    detail: BoundedText(256) = .{},
};

pub const NoticeRing = struct {
    next_id: u64 = 1,
    entries: [notice_ring_len]Notice = undefined,
    start: usize = 0,
    len: usize = 0,
    evicted_through_id: u64 = 0,

    pub fn push(self: *NoticeRing, severity: Notice.Severity, semantic: NoticeSemantic, text: []const u8) void {
        const notice: Notice = .{
            .id = self.next_id,
            .severity = severity,
            .semantic = semantic,
            .text = BoundedText(512).init(text),
        };
        self.next_id += 1;
        if (self.len < notice_ring_len) {
            self.entries[(self.start + self.len) % notice_ring_len] = notice;
            self.len += 1;
            return;
        }
        self.evicted_through_id = self.entries[self.start].id;
        self.entries[self.start] = notice;
        self.start = (self.start + 1) % notice_ring_len;
    }

    pub fn latestId(self: *const NoticeRing) u64 {
        if (self.len == 0) return self.evicted_through_id;
        return self.entries[(self.start + self.len - 1) % notice_ring_len].id;
    }

    pub fn copySince(self: *const NoticeRing, gpa: std.mem.Allocator, out: *std.ArrayList(Notice), last_seen: u64) !void {
        if (self.evicted_through_id > last_seen) {
            try out.append(gpa, .{
                .id = self.evicted_through_id,
                .severity = .warn,
                .semantic = .notices_dropped,
                .text = BoundedText(512).init("some notices were dropped"),
            });
        }
        var i: usize = 0;
        while (i < self.len) : (i += 1) {
            const notice = self.entries[(self.start + i) % notice_ring_len];
            if (notice.id > last_seen) try out.append(gpa, notice);
        }
    }
};

pub const Notice = struct {
    id: u64 = 0,
    severity: Severity = .info,
    semantic: NoticeSemantic = .generic,
    text: BoundedText(512) = .{},

    pub const Severity = enum { info, warn, err };
};

pub const NoticeSemantic = enum {
    generic,
    notices_dropped,
    operation_failed,
    retry_start,
    retry_end,
    queue_full,
    terminal_bell,
};

pub const Sample = struct {
    generation: u64,
    session_epoch: u32,
    chrome: Chrome,
    op: OperationStatus,
    queue: QueueEcho,
    evicted_through_id: u64,
    items: std.ArrayList(ItemDelta),
    history: ?HistoryWindow,
    completion: ?CompletionSlot,
    notices: std.ArrayList(Notice),
    partial: bool,

    pub fn deinit(self: *Sample, gpa: std.mem.Allocator) void {
        for (self.items.items) |*item| item.deinit(gpa);
        self.items.deinit(gpa);
        if (self.history) |*history| history.deinit(gpa);
        if (self.completion) |*completion| completion.deinit(gpa);
        self.notices.deinit(gpa);
        self.* = undefined;
    }
};

test "append-only invariant and text_replaced protocol" {
    const gpa = std.testing.allocator;
    var store: ItemStore = .{};
    defer store.deinit(gpa);
    const id = try store.append(gpa, .assistant, .streaming, "he", null);
    try store.appendText(gpa, id, "llo");
    try std.testing.expectEqualStrings("hello", store.items.items[0].text.items);
    try std.testing.expect(store.items.items[0].text_replaced_at_rev == null);
    const rev_before = store.items.items[0].rev;
    try store.replaceText(gpa, id, "goodbye");
    try std.testing.expectEqualStrings("goodbye", store.items.items[0].text.items);
    try std.testing.expectEqual(store.items.items[0].rev, store.items.items[0].text_replaced_at_rev.?);
    try std.testing.expect(store.items.items[0].rev != rev_before);
}

test "per-kind caps truncate at utf8 boundary and set truncation text" {
    const gpa = std.testing.allocator;
    var store: ItemStore = .{};
    defer store.deinit(gpa);
    const big = try gpa.alloc(u8, assistant_text_bytes_max + 4);
    defer gpa.free(big);
    @memset(big, 'x');
    big[assistant_text_bytes_max - 1] = 0xe2;
    big[assistant_text_bytes_max] = 0x99;
    big[assistant_text_bytes_max + 1] = 0xa5;
    const id = try store.append(gpa, .assistant, .streaming, big, null);
    const item = &store.items.items[0];
    try std.testing.expect(item.text.items.len <= assistant_text_bytes_max);
    try std.testing.expect(item.text.items.len < big.len);
    try std.testing.expectEqualStrings("output truncated", item.footer.slice());
    try std.testing.expectEqual(id, item.id);
}

test "residency eviction advances evicted_through_id" {
    const gpa = std.testing.allocator;
    var store: ItemStore = .{};
    defer store.deinit(gpa);
    var i: usize = 0;
    while (i < resident_items_max + 3) : (i += 1) _ = try store.append(gpa, .user, .streaming, "x", null);
    try std.testing.expectEqual(@as(usize, resident_items_max), store.items.items.len);
    try std.testing.expectEqual(@as(u64, 3), store.evicted_through_id);
    try std.testing.expectEqual(@as(u64, 4), store.items.items[0].id);
}

test "total resident text bytes eviction advances evicted_through_id" {
    const gpa = std.testing.allocator;
    var store: ItemStore = .{};
    defer store.deinit(gpa);
    const chunk = try gpa.alloc(u8, 200 * 1024);
    defer gpa.free(chunk);
    @memset(chunk, 'a');
    _ = try store.append(gpa, .assistant, .streaming, chunk, null);
    _ = try store.append(gpa, .assistant, .streaming, chunk, null);
    _ = try store.append(gpa, .assistant, .streaming, chunk, null);
    try std.testing.expectEqual(@as(u64, 1), store.evicted_through_id);
    try std.testing.expectEqual(@as(usize, 2), store.items.items.len);
}

test "notice-ring overflow reports gap" {
    const gpa = std.testing.allocator;
    var ring: NoticeRing = .{};
    var i: usize = 0;
    while (i < notice_ring_len + 2) : (i += 1) ring.push(.info, .generic, "n");
    var out: std.ArrayList(Notice) = .empty;
    defer out.deinit(gpa);
    try ring.copySince(gpa, &out, 0);
    try std.testing.expectEqual(NoticeSemantic.notices_dropped, out.items[0].semantic);
    try std.testing.expectEqual(@as(u64, 2), ring.evicted_through_id);
}

test "epoch reset and generation batching" {
    const gpa = std.testing.allocator;
    var vm = try ViewModel.init(gpa);
    defer vm.deinit(gpa);
    var writer = vm.lockWriter();
    writer.bumpEpoch();
    _ = try writer.addItem(gpa, .user, .streaming, "a", null);
    writer.finish();
    try std.testing.expectEqual(@as(u64, 1), vm.generation);
    try std.testing.expectEqual(@as(u32, 1), vm.session_epoch);
}

test "reader byte-cap partial sample does not consume generation and makes progress" {
    const gpa = std.testing.allocator;
    var vm = try ViewModel.init(gpa);
    defer vm.deinit(gpa);
    var writer = vm.lockWriter();
    _ = try writer.addItem(gpa, .assistant, .streaming, "0123456789", null);
    _ = try writer.addItem(gpa, .assistant, .streaming, "abcdefghij", null);
    writer.finish();

    var cursor: ReaderCursor = .{};
    defer cursor.deinit(gpa);
    var sample = try vm.sample(gpa, &cursor, 15);
    defer sample.deinit(gpa);
    try std.testing.expect(sample.partial);
    try std.testing.expectEqual(@as(u64, 0), cursor.generation);
    try std.testing.expectEqual(@as(usize, 2), sample.items.items.len);
    try std.testing.expectEqualStrings("abcde", sample.items.items[1].text_suffix);
    try std.testing.expectEqual(@as(usize, 5), cursor.findItem(2).?.consumed_len);
}

test "reader samples only text suffix after consumed_len" {
    const gpa = std.testing.allocator;
    var vm = try ViewModel.init(gpa);
    defer vm.deinit(gpa);
    var writer = vm.lockWriter();
    const id = try writer.addItem(gpa, .assistant, .streaming, "he", null);
    writer.finish();
    var cursor: ReaderCursor = .{};
    defer cursor.deinit(gpa);
    var first = try vm.sample(gpa, &cursor, sample_bytes_per_frame_max);
    first.deinit(gpa);

    var writer2 = vm.lockWriter();
    try writer2.appendItemText(gpa, id, "llo");
    writer2.finish();
    var second = try vm.sample(gpa, &cursor, sample_bytes_per_frame_max);
    defer second.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), second.items.items.len);
    try std.testing.expect(!second.items.items[0].full_text);
    try std.testing.expectEqualStrings("llo", second.items.items[0].text_suffix);
}

test "append at text cap sets footer and bumps rev" {
    const gpa = std.testing.allocator;
    var store: ItemStore = .{};
    defer store.deinit(gpa);
    const exact = try gpa.alloc(u8, assistant_text_bytes_max);
    defer gpa.free(exact);
    @memset(exact, 'x');
    const id = try store.append(gpa, .assistant, .streaming, exact, null);
    const rev = store.items.items[0].rev;
    try std.testing.expectEqualStrings("", store.items.items[0].footer.slice());
    try store.appendText(gpa, id, "y");
    try std.testing.expect(store.items.items[0].rev != rev);
    try std.testing.expectEqualStrings("output truncated", store.items.items[0].footer.slice());
}

test "queue echo follow-up and id removal" {
    var queue: QueueEcho = .{};
    queue.enqueueSteering(.{ .id = 1, .text = BoundedText(256).init("steer") });
    queue.enqueueFollowUp(.{ .id = 2, .text = BoundedText(256).init("follow") });
    try std.testing.expectEqual(@as(usize, 1), queue.steering.len);
    try std.testing.expectEqual(@as(usize, 1), queue.follow_up.len);
    try std.testing.expect(queue.removeById(2));
    try std.testing.expectEqual(@as(usize, 0), queue.follow_up.len);
    try std.testing.expect(!queue.removeById(99));
}

test "partially consumed new item continues without re-copying bytes" {
    const gpa = std.testing.allocator;
    var vm = try ViewModel.init(gpa);
    defer vm.deinit(gpa);
    var writer = vm.lockWriter();
    _ = try writer.addItem(gpa, .assistant, .streaming, "0123456789", null);
    writer.finish();

    var cursor: ReaderCursor = .{};
    defer cursor.deinit(gpa);

    var first = try vm.sample(gpa, &cursor, 4);
    defer first.deinit(gpa);
    try std.testing.expect(first.partial);
    try std.testing.expectEqual(@as(usize, 1), first.items.items.len);
    try std.testing.expect(first.items.items[0].full_text);
    try std.testing.expectEqualStrings("0123", first.items.items[0].text_suffix);

    var second = try vm.sample(gpa, &cursor, 4);
    defer second.deinit(gpa);
    try std.testing.expect(second.partial);
    try std.testing.expect(!second.items.items[0].full_text);
    try std.testing.expectEqualStrings("4567", second.items.items[0].text_suffix);

    var third = try vm.sample(gpa, &cursor, 4);
    defer third.deinit(gpa);
    try std.testing.expect(!third.partial);
    try std.testing.expect(!third.items.items[0].full_text);
    try std.testing.expectEqualStrings("89", third.items.items[0].text_suffix);
    try std.testing.expectEqual(vm.generation, cursor.generation);
}

const StressState = struct {
    gpa: std.mem.Allocator,
    vm: *ViewModel,
    source: []const u8,
    out: []u8,
    out_len: usize = 0,
    item_id: std.atomic.Value(u64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    bad: std.atomic.Value(bool) = .init(false),
    generation: std.atomic.Value(u64) = .init(0),
};

fn stressWriter(state: *StressState) void {
    var writer = state.vm.lockWriter();
    const id = writer.addItem(state.gpa, .assistant, .streaming, "", null) catch {
        state.bad.store(true, .release);
        writer.finish();
        return;
    };
    writer.finish();
    state.item_id.store(id, .release);

    var offset: usize = 0;
    while (offset < state.source.len) {
        const end = @min(offset + 64, state.source.len);
        var append_writer = state.vm.lockWriter();
        append_writer.appendItemText(state.gpa, id, state.source[offset..end]) catch {
            state.bad.store(true, .release);
            append_writer.finish();
            return;
        };
        append_writer.finish();
        offset = end;
    }

    var final_writer = state.vm.lockWriter();
    if (final_writer.vm.transcript.find(id)) |item| {
        item.entry_id = 1;
        item.state = .final;
        item.bumpRev();
        final_writer.touched = true;
    } else {
        state.bad.store(true, .release);
    }
    final_writer.finish();
}

fn stressReader(state: *StressState) void {
    var cursor: ReaderCursor = .{};
    defer cursor.deinit(state.gpa);
    while (!state.done.load(.acquire)) {
        var sample = state.vm.sample(state.gpa, &cursor, sample_bytes_per_frame_max) catch {
            state.bad.store(true, .release);
            return;
        };
        defer sample.deinit(state.gpa);
        var final = false;
        for (sample.items.items) |item| {
            if (item.kind != .assistant) continue;
            if (item.text_suffix.len > 0) {
                if (state.out_len + item.text_suffix.len > state.out.len) {
                    state.bad.store(true, .release);
                    return;
                }
                @memcpy(state.out[state.out_len .. state.out_len + item.text_suffix.len], item.text_suffix);
                state.out_len += item.text_suffix.len;
            }
            if (item.state == .final and item.entry_id != null and item.footer.eql("output truncated")) final = true;
        }
        state.generation.store(cursor.generation, .release);
        if (final and !sample.partial and cursor.generation == sample.generation) {
            state.done.store(true, .release);
            return;
        }
        std.Thread.yield() catch {};
    }
}

test "cross-thread reader samples 1mb stream up to live cap without gaps" {
    const gpa = std.testing.allocator;
    var model = try ViewModel.init(gpa);
    defer model.deinit(gpa);
    const source = try gpa.alloc(u8, 1024 * 1024);
    defer gpa.free(source);
    for (source, 0..) |*byte, index| byte.* = 'a' + @as(u8, @intCast(index % 26));
    const out = try gpa.alloc(u8, assistant_text_bytes_max);
    defer gpa.free(out);
    var state = StressState{ .gpa = gpa, .vm = &model, .source = source, .out = out };
    const reader = try std.Thread.spawn(.{}, stressReader, .{&state});
    const writer = try std.Thread.spawn(.{}, stressWriter, .{&state});
    writer.join();
    const convergence_deadline_ns = runtime.monotonicNowNs() + 10 * std.time.ns_per_s;
    while (!state.done.load(.acquire) and runtime.monotonicNowNs() < convergence_deadline_ns) {
        std.Thread.yield() catch {};
    }
    state.done.store(true, .release);
    reader.join();
    try std.testing.expect(!state.bad.load(.acquire));
    try std.testing.expectEqual(assistant_text_bytes_max, state.out_len);
    try std.testing.expectEqualStrings(source[0..assistant_text_bytes_max], state.out[0..state.out_len]);
    try std.testing.expectEqual(model.generation, state.generation.load(.acquire));
}

test "reader cursor prunes entries for evicted items" {
    const gpa = std.testing.allocator;
    var vm = try ViewModel.init(gpa);
    defer vm.deinit(gpa);
    var cursor: ReaderCursor = .{};
    defer cursor.deinit(gpa);

    var added: usize = 0;
    while (added < resident_items_max) {
        var writer = vm.lockWriter();
        var batch: usize = 0;
        while (batch < 32 and added < resident_items_max) : ({
            batch += 1;
            added += 1;
        }) {
            _ = try writer.addItem(gpa, .user, .streaming, "x", null);
        }
        writer.finish();
    }
    var full = try vm.sample(gpa, &cursor, sample_bytes_per_frame_max);
    full.deinit(gpa);
    try std.testing.expectEqual(resident_items_max, cursor.items.items.len);

    var writer = vm.lockWriter();
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        _ = try writer.addItem(gpa, .user, .streaming, "y", null);
    }
    writer.finish();
    var next = try vm.sample(gpa, &cursor, sample_bytes_per_frame_max);
    next.deinit(gpa);
    try std.testing.expectEqual(@as(u64, 8), vm.transcript.evicted_through_id);
    try std.testing.expectEqual(resident_items_max, cursor.items.items.len);
    for (cursor.items.items) |entry| try std.testing.expect(entry.id > 8);
}
