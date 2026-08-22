// Modeled on vercel-labs/fx src/ui/transcript/store.zig (bounded ordered raw
// entries with explicit lifecycle transitions), adapted to Zi's allocator and
// error model.
// Licensed under Apache-2.0 and adapted for Zi.
const std = @import("std");

pub const Store = @This();

pub const default_max_store_bytes: usize = 1024 * 1024;

pub const Kind = enum {
    welcome,
    model,
    user,
    assistant,
    thinking,
    tool,
    notice,
};

pub const Error = error{
    OutOfMemory,
    StoreFull,
    EntryNotFound,
    EntrySealed,
    IdExhausted,
};

/// One transcript entry. The source holds presentation bytes (text with
/// inline SGR runs); the painter owns wrapping and styling interpretation.
pub const Entry = struct {
    id: u32,
    kind: Kind,
    sealed: bool = false,
    source: std.ArrayList(u8) = .empty,

    pub fn bytes(self: *const Entry) []const u8 {
        return self.source.items;
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
    for (self.entries.items) |*value| value.source.deinit(self.allocator);
    self.entries.deinit(self.allocator);
    self.* = undefined;
}

/// Appends one open entry seeded with `bytes`. Returns the sequential id.
pub fn appendEntry(self: *Store, kind: Kind, bytes: []const u8) Error!u32 {
    if (bytes.len > self.max_store_bytes - self.total_bytes) return error.StoreFull;
    if (self.next_id == std.math.maxInt(u32)) return error.IdExhausted;
    const id = self.next_id;
    self.next_id += 1;
    errdefer self.next_id -= 1;
    var source: std.ArrayList(u8) = .empty;
    errdefer source.deinit(self.allocator);
    try source.appendSlice(self.allocator, bytes);
    try self.entries.append(self.allocator, .{
        .id = id,
        .kind = kind,
        .source = source,
    });
    self.total_bytes += bytes.len;
    return id;
}

/// Grows one unsealed entry. The store bound is checked before any mutation
/// so a rejected append leaves the store unchanged.
pub fn appendTo(self: *Store, id: u32, bytes: []const u8) Error!void {
    const target = self.entry(id) orelse return error.EntryNotFound;
    if (target.sealed) return error.EntrySealed;
    if (bytes.len > self.max_store_bytes - self.total_bytes) return error.StoreFull;
    try target.source.appendSlice(self.allocator, bytes);
    self.total_bytes += bytes.len;
}

pub fn sealEntry(self: *Store, id: u32) Error!void {
    const target = self.entry(id) orelse return error.EntryNotFound;
    target.sealed = true;
}

/// Removes `id` and every later entry, for abnormal turn resets. Sealed or
/// not, dropped sources are freed; the ids of surviving entries never change.
pub fn dropEntriesFrom(self: *Store, id: u32) Error!void {
    var index: usize = 0;
    while (index < self.entries.items.len and self.entries.items[index].id != id) : (index += 1) {}
    if (index == self.entries.items.len) return error.EntryNotFound;
    for (self.entries.items[index..]) |*value| {
        self.total_bytes -= value.source.items.len;
        value.source.deinit(self.allocator);
    }
    self.entries.shrinkRetainingCapacity(index);
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
    // Ids are sequential and dense except across drops; scan from the tail
    // because streaming appends target the most recent entries.
    var index = self.entries.items.len;
    while (index > 0) {
        index -= 1;
        if (self.entries.items[index].id == id) return &self.entries.items[index];
        if (self.entries.items[index].id < id) return null;
    }
    return null;
}

test "entries get sequential ids and grow until sealed" {
    var store = init(std.testing.allocator, 256);
    defer store.deinit();

    const first = try store.appendEntry(.user, "hello\n");
    const second = try store.appendEntry(.assistant, "");
    try std.testing.expectEqual(first + 1, second);
    try std.testing.expectEqual(@as(usize, 2), store.entryCount());

    try store.appendTo(second, "streaming ");
    try store.appendTo(second, "text");
    try store.sealEntry(second);
    try std.testing.expectEqualStrings("streaming text", store.entry(second).?.bytes());
    try std.testing.expect(store.entry(second).?.sealed);

    try std.testing.expectError(error.EntrySealed, store.appendTo(second, "more"));
    try std.testing.expect(store.entry(first).?.sealed == false);
}

test "dropEntriesFrom frees the subtree and keeps earlier entries" {
    var store = init(std.testing.allocator, 256);
    defer store.deinit();

    const keep = try store.appendEntry(.welcome, "welcome\n");
    _ = try store.appendEntry(.assistant, "partial");
    _ = try store.appendEntry(.notice, "[cancelled]\n");
    const before = store.total_bytes;

    try store.dropEntriesFrom(keep + 1);
    try std.testing.expectEqual(@as(usize, 1), store.entryCount());
    try std.testing.expectEqual(before - "partial".len - "[cancelled]\n".len, store.total_bytes);
    try std.testing.expectEqualStrings("welcome\n", store.entryAt(0).?.bytes());

    // Dropped ids are gone; new appends continue the sequence without reuse.
    const fresh = try store.appendEntry(.user, "again\n");
    try std.testing.expect(fresh > keep + 2);
}

test "the byte bound rejects appends transactionally" {
    var store = init(std.testing.allocator, 16);
    defer store.deinit();

    const id = try store.appendEntry(.assistant, "twelve bytes");
    try std.testing.expectError(error.StoreFull, store.appendEntry(.notice, "way too long"));
    try std.testing.expectError(error.StoreFull, store.appendTo(id, "overflow"));
    try std.testing.expectEqual(@as(usize, 12), store.total_bytes);
    try std.testing.expectEqualStrings("twelve bytes", store.entry(id).?.bytes());
}

test "entry ids fail explicitly before integer exhaustion" {
    var store = init(std.testing.allocator, 64);
    defer store.deinit();
    store.next_id = std.math.maxInt(u32);

    try std.testing.expectError(error.IdExhausted, store.appendEntry(.notice, ""));
    try std.testing.expectEqual(@as(usize, 0), store.entryCount());
}

test "entry lookups miss unknown and dropped ids" {
    var store = init(std.testing.allocator, 64);
    defer store.deinit();

    try std.testing.expectError(error.EntryNotFound, store.sealEntry(99));
    const id = try store.appendEntry(.tool, "tool\n");
    try std.testing.expectError(error.EntryNotFound, store.dropEntriesFrom(50));
    try store.dropEntriesFrom(id);
    try std.testing.expectError(error.EntryNotFound, store.appendTo(id, "x"));
    try std.testing.expect(store.lastEntry() == null);
}
