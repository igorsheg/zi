// Adapted from vercel-labs/fx src/ui/transcript/store.zig and
// src/ui/render_engine/transcript_blocks.zig. Licensed under Apache-2.0.
const std = @import("std");

pub const Store = @This();

pub const default_max_store_bytes: usize = 1024 * 1024;

pub const EntryClass = enum {
    welcome,
    model_change,
    user_turn,
    assistant_turn,
    thinking,
    tool_status,
    system_notice,
};

pub const ToolOutcome = enum {
    success,
    failed,
    cancelled,
    interrupted,
};

pub const Error = error{
    OutOfMemory,
    StoreFull,
    EntryNotFound,
    EntrySealed,
    IdExhausted,
    OpenEntryExists,
    InvalidOpenEntryClass,
    InvalidTextEntryClass,
};

pub const TextEntry = struct {
    id: u32,
    sealed: bool,
    source: std.ArrayList(u8),
};

pub const ToolStatus = struct {
    id: u32,
    outcome: ToolOutcome,
    phrase: std.ArrayList(u8),
};

pub const Entry = union(EntryClass) {
    welcome: TextEntry,
    model_change: TextEntry,
    user_turn: TextEntry,
    assistant_turn: TextEntry,
    thinking: TextEntry,
    tool_status: ToolStatus,
    system_notice: TextEntry,

    pub fn class(self: Entry) EntryClass {
        return std.meta.activeTag(self);
    }

    pub fn id(self: Entry) u32 {
        return switch (self) {
            .tool_status => |value| value.id,
            inline else => |value| value.id,
        };
    }

    pub fn isSealed(self: Entry) bool {
        return switch (self) {
            .tool_status => true,
            inline else => |value| value.sealed,
        };
    }

    pub fn textBytes(self: Entry) ?[]const u8 {
        return switch (self) {
            .tool_status => null,
            inline else => |value| value.source.items,
        };
    }

    pub fn toolStatus(self: Entry) ?ToolStatus {
        return switch (self) {
            .tool_status => |value| value,
            else => null,
        };
    }

    fn byteLen(self: Entry) usize {
        return switch (self) {
            .tool_status => |value| value.phrase.items.len,
            inline else => |value| value.source.items.len,
        };
    }

    fn textMut(self: *Entry) ?*TextEntry {
        return switch (self.*) {
            .tool_status => null,
            inline else => |*value| value,
        };
    }

    fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .tool_status => |*value| value.phrase.deinit(allocator),
            inline else => |*value| value.source.deinit(allocator),
        }
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
entries: std.ArrayList(Entry) = .empty,
total_bytes: usize = 0,
next_id: u32 = 1,
max_store_bytes: usize,

pub fn init(allocator: std.mem.Allocator, max_store_bytes: usize) Store {
    return .{
        .allocator = allocator,
        .max_store_bytes = max_store_bytes,
    };
}

pub fn deinit(self: *Store) void {
    for (self.entries.items) |*value| value.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.* = undefined;
}

/// Appends one immutable text entry. Tool statuses use `appendToolStatus` so
/// outcome remains typed until paint-time presentation.
pub fn appendSealed(self: *Store, class: EntryClass, bytes: []const u8) Error!u32 {
    if (class == .tool_status) return error.InvalidTextEntryClass;
    return self.appendText(class, bytes, true);
}

/// Opens the only mutable response entry, which is always the store tail.
pub fn openEntry(self: *Store, class: EntryClass, bytes: []const u8) Error!u32 {
    switch (class) {
        .assistant_turn, .thinking => {},
        else => return error.InvalidOpenEntryClass,
    }
    return self.appendText(class, bytes, false);
}

pub fn appendToolStatus(
    self: *Store,
    phrase: []const u8,
    outcome: ToolOutcome,
) Error!u32 {
    try self.requireAppendable(phrase.len);
    const id = try self.takeId();
    errdefer self.next_id -= 1;

    var owned_phrase: std.ArrayList(u8) = .empty;
    errdefer owned_phrase.deinit(self.allocator);
    try owned_phrase.appendSlice(self.allocator, phrase);
    try self.entries.append(self.allocator, .{ .tool_status = .{
        .id = id,
        .outcome = outcome,
        .phrase = owned_phrase,
    } });
    self.total_bytes += phrase.len;
    return id;
}

fn appendText(self: *Store, class: EntryClass, bytes: []const u8, sealed: bool) Error!u32 {
    try self.requireAppendable(bytes.len);
    const id = try self.takeId();
    errdefer self.next_id -= 1;

    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(self.allocator);
    try source.appendSlice(self.allocator, bytes);
    try self.entries.append(self.allocator, makeTextEntry(class, .{
        .id = id,
        .sealed = sealed,
        .source = source,
    }));
    self.total_bytes += bytes.len;
    return id;
}

fn requireAppendable(self: *Store, byte_len: usize) Error!void {
    if (self.lastEntry()) |last| {
        if (!last.isSealed()) return error.OpenEntryExists;
    }
    if (byte_len > self.max_store_bytes - self.total_bytes) return error.StoreFull;
}

fn takeId(self: *Store) Error!u32 {
    if (self.next_id == std.math.maxInt(u32)) return error.IdExhausted;
    const id = self.next_id;
    self.next_id += 1;
    return id;
}

fn makeTextEntry(class: EntryClass, value: TextEntry) Entry {
    return switch (class) {
        .welcome => .{ .welcome = value },
        .model_change => .{ .model_change = value },
        .user_turn => .{ .user_turn = value },
        .assistant_turn => .{ .assistant_turn = value },
        .thinking => .{ .thinking = value },
        .tool_status => unreachable,
        .system_notice => .{ .system_notice = value },
    };
}

/// Grows one unsealed response entry. Rejection leaves the store unchanged.
pub fn appendTo(self: *Store, id: u32, bytes: []const u8) Error!void {
    const target = self.entry(id) orelse return error.EntryNotFound;
    const text = target.textMut() orelse return error.EntrySealed;
    if (text.sealed) return error.EntrySealed;
    if (bytes.len > self.max_store_bytes - self.total_bytes) return error.StoreFull;
    try text.source.appendSlice(self.allocator, bytes);
    self.total_bytes += bytes.len;
}

pub fn sealEntry(self: *Store, id: u32) Error!void {
    const target = self.entry(id) orelse return error.EntryNotFound;
    const text = target.textMut() orelse return error.EntrySealed;
    if (text.sealed) return error.EntrySealed;
    text.sealed = true;
}

pub fn dropEntriesFrom(self: *Store, id: u32) Error!void {
    var index: usize = 0;
    while (index < self.entries.items.len and self.entries.items[index].id() != id) : (index += 1) {}
    if (index == self.entries.items.len) return error.EntryNotFound;
    for (self.entries.items[index..]) |*value| {
        self.total_bytes -= value.byteLen();
        value.deinit(self.allocator);
    }
    self.entries.shrinkRetainingCapacity(index);
}

pub fn items(self: *const Store) []const Entry {
    return self.entries.items;
}

pub fn entryCount(self: *const Store) usize {
    return self.entries.items.len;
}

pub fn entryAt(self: *const Store, index: usize) ?*const Entry {
    if (index >= self.entries.items.len) return null;
    return &self.entries.items[index];
}

pub fn lastEntry(self: *Store) ?*Entry {
    if (self.entries.items.len == 0) return null;
    return &self.entries.items[self.entries.items.len - 1];
}

fn entry(self: *Store, id: u32) ?*Entry {
    var index = self.entries.items.len;
    while (index > 0) {
        index -= 1;
        const candidate = &self.entries.items[index];
        if (candidate.id() == id) return candidate;
        if (candidate.id() < id) return null;
    }
    return null;
}

test "semantic entries constrain mutable tails" {
    var store = init(std.testing.allocator, 256);
    defer store.deinit();

    const first = try store.appendSealed(.user_turn, "hello\n");
    try std.testing.expectError(
        error.InvalidOpenEntryClass,
        store.openEntry(.user_turn, "invalid"),
    );
    try std.testing.expectError(
        error.InvalidTextEntryClass,
        store.appendSealed(.tool_status, "invalid"),
    );
    const second = try store.openEntry(.assistant_turn, "");
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expectError(error.OpenEntryExists, store.openEntry(.thinking, ""));
    try std.testing.expectError(
        error.OpenEntryExists,
        store.appendSealed(.system_notice, "later"),
    );

    try store.appendTo(second, "streaming text");
    try store.sealEntry(second);
    try std.testing.expectEqualStrings("streaming text", store.entry(second).?.textBytes().?);
    try std.testing.expect(store.entry(second).?.isSealed());
    try std.testing.expect(store.entry(second).?.class() == .assistant_turn);
}

test "tool status retains outcome separately from presentation" {
    var store = init(std.testing.allocator, 256);
    defer store.deinit();

    _ = try store.appendToolStatus("Ran zig build", .failed);
    const status = store.entryAt(0).?.toolStatus().?;
    try std.testing.expectEqualStrings("Ran zig build", status.phrase.items);
    try std.testing.expectEqual(ToolOutcome.failed, status.outcome);
    try std.testing.expect(store.entryAt(0).?.textBytes() == null);
}

test "drop frees a semantic suffix and keeps stable ids" {
    var store = init(std.testing.allocator, 256);
    defer store.deinit();
    const keep = try store.appendSealed(.welcome, "welcome\n");
    _ = try store.appendSealed(.assistant_turn, "partial");
    _ = try store.appendSealed(.system_notice, "cancelled\n");
    const before = store.total_bytes;

    try store.dropEntriesFrom(keep + 1);
    try std.testing.expectEqual(@as(usize, 1), store.entryCount());
    try std.testing.expectEqual(before - "partial".len - "cancelled\n".len, store.total_bytes);
    try std.testing.expectEqualStrings("welcome\n", store.entryAt(0).?.textBytes().?);
    const fresh = try store.appendSealed(.user_turn, "again\n");
    try std.testing.expect(fresh > keep + 2);
}

test "byte bounds reject semantic mutations transactionally" {
    var store = init(std.testing.allocator, 16);
    defer store.deinit();
    try std.testing.expectError(
        error.StoreFull,
        store.appendSealed(.system_notice, "way too long for bound"),
    );
    const id = try store.openEntry(.assistant_turn, "twelve bytes");
    try std.testing.expectError(error.StoreFull, store.appendTo(id, "overflow"));
    try std.testing.expectEqual(@as(usize, 12), store.total_bytes);
    try std.testing.expectEqualStrings("twelve bytes", store.entry(id).?.textBytes().?);
}

test "entry ids fail explicitly before exhaustion" {
    var store = init(std.testing.allocator, 64);
    defer store.deinit();
    store.next_id = std.math.maxInt(u32);
    try std.testing.expectError(
        error.IdExhausted,
        store.appendSealed(.system_notice, ""),
    );
}

test "entry lookups miss unknown and dropped ids" {
    var store = init(std.testing.allocator, 64);
    defer store.deinit();
    try std.testing.expectError(error.EntryNotFound, store.sealEntry(99));
    const id = try store.openEntry(.assistant_turn, "tail\n");
    try std.testing.expectError(error.EntryNotFound, store.dropEntriesFrom(50));
    try store.dropEntriesFrom(id);
    try std.testing.expectError(error.EntryNotFound, store.appendTo(id, "x"));
    try std.testing.expect(store.lastEntry() == null);
}
