//! Bounded prompt history for the local TUI composer. This is UI product
//! state, not durable session history: it remembers recent submitted prompts
//! only for arrow-key recall inside one App owner.
const std = @import("std");

const PromptHistory = @This();

pub const entries_max: usize = 64;
pub const bytes_max: usize = 64 * 1024;

const Entry = struct {
    text: []u8,
};

entries: [entries_max]Entry = undefined,
start: usize = 0,
count: usize = 0,
bytes: usize = 0,

pub fn deinit(self: *PromptHistory, gpa: std.mem.Allocator) void {
    while (self.count > 0) self.evictOldest(gpa);
    self.* = undefined;
}

pub fn len(self: *const PromptHistory) usize {
    return self.count;
}

/// Store a submitted prompt. Oversize entries do not fit the resident bound
/// and are deliberately not remembered; submission itself is handled by App.
pub fn record(self: *PromptHistory, gpa: std.mem.Allocator, text: []const u8) error{OutOfMemory}!void {
    if (text.len == 0 or text.len > bytes_max) return;

    const owned = try gpa.dupe(u8, text);
    errdefer gpa.free(owned);

    while (self.count >= entries_max or self.bytes + owned.len > bytes_max) {
        self.evictOldest(gpa);
    }
    self.pushOwned(owned);
}

/// offset 0 is newest, 1 is the prompt before that, etc.
pub fn getFromNewest(self: *const PromptHistory, offset: usize) ?[]const u8 {
    if (offset >= self.count) return null;
    const from_oldest = self.count - 1 - offset;
    const index = (self.start + from_oldest) % entries_max;
    return self.entries[index].text;
}

fn pushOwned(self: *PromptHistory, text: []u8) void {
    std.debug.assert(self.count < entries_max);
    std.debug.assert(text.len <= bytes_max);
    std.debug.assert(self.bytes + text.len <= bytes_max);

    const index = (self.start + self.count) % entries_max;
    self.entries[index] = .{ .text = text };
    self.count += 1;
    self.bytes += text.len;
}

fn evictOldest(self: *PromptHistory, gpa: std.mem.Allocator) void {
    std.debug.assert(self.count > 0);

    const entry = self.entries[self.start];
    gpa.free(entry.text);
    self.bytes -= entry.text.len;
    self.count -= 1;
    self.start = if (self.count == 0) 0 else (self.start + 1) % entries_max;
}

test "records prompts newest-first" {
    const gpa = std.testing.allocator;
    var history: PromptHistory = .{};
    defer history.deinit(gpa);

    try history.record(gpa, "one");
    try history.record(gpa, "two");

    try std.testing.expectEqual(@as(usize, 2), history.len());
    try std.testing.expectEqualStrings("two", history.getFromNewest(0).?);
    try std.testing.expectEqualStrings("one", history.getFromNewest(1).?);
    try std.testing.expect(history.getFromNewest(2) == null);
}

test "evicts oldest prompts at the entry cap" {
    const gpa = std.testing.allocator;
    var history: PromptHistory = .{};
    defer history.deinit(gpa);

    var index: usize = 0;
    while (index < entries_max) : (index += 1) try history.record(gpa, "x");
    try history.record(gpa, "newest");

    try std.testing.expectEqual(entries_max, history.len());
    try std.testing.expectEqualStrings("newest", history.getFromNewest(0).?);
}
