//! Allocation-free status contributions. Frontend adapters publish small
//! prioritized text segments into named slots (the status line above the
//! composer and the composer's top border labels); render orders them by
//! priority. Text is stored inline, so the store never allocates and `deinit`
//! is unnecessary.
const std = @import("std");
const text_mod = @import("text.zig");

pub const entry_count_max: usize = 16;
pub const text_bytes_max: usize = 160;

pub const Slot = enum { composer_left, composer_right, status_line };
pub const Effect = enum { none, shimmer };
pub const ContributionId = u32;

pub const Set = struct {
    slot: Slot,
    id: ContributionId,
    priority: i16 = 0,
    text: []const u8,
    effect: Effect = .none,
};

pub const Clear = struct {
    slot: Slot,
    id: ContributionId,
};

pub const View = struct {
    priority: i16,
    text: []const u8,
    effect: Effect,
};

pub const SetResult = enum { ok, dropped_full };

const Entry = struct {
    slot: Slot,
    id: ContributionId,
    priority: i16,
    effect: Effect,
    text_len: u8,
    text: [text_bytes_max]u8,
};

pub const Store = struct {
    entries: [entry_count_max]Entry = undefined,
    len: usize = 0,

    /// Set or replace a contribution. Text is sanitized (invalid UTF-8 and
    /// line breaks never reach render) and truncated to the inline capacity.
    pub fn set(self: *Store, update: Set) SetResult {
        std.debug.assert(update.id != 0); // 0 is reserved as "no id"; adapter owns ids
        const index = self.find(update.slot, update.id) orelse blk: {
            if (self.len == self.entries.len) return .dropped_full;
            self.len += 1;
            break :blk self.len - 1;
        };
        const entry = &self.entries[index];
        entry.slot = update.slot;
        entry.id = update.id;
        entry.priority = update.priority;
        entry.effect = update.effect;
        var sanitized: [text_bytes_max]u8 = undefined;
        const clean = text_mod.sanitizeInto(&sanitized, update.text);
        var len: usize = 0;
        for (clean) |byte| {
            entry.text[len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
            len += 1;
        }
        entry.text_len = @intCast(len);
        return .ok;
    }

    pub fn clear(self: *Store, request: Clear) bool {
        const index = self.find(request.slot, request.id) orelse return false;
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.entries[i] = self.entries[i + 1];
        self.len -= 1;
        return true;
    }

    pub fn count(self: *const Store, slot: Slot) usize {
        var n: usize = 0;
        for (self.entries[0..self.len]) |entry| {
            if (entry.slot == slot) n += 1;
        }
        return n;
    }

    /// Views into `out`, highest priority first. Returned text borrows the
    /// store; valid until the next mutation.
    pub fn ordered(self: *const Store, slot: Slot, out: []View) usize {
        var n: usize = 0;
        for (self.entries[0..self.len]) |*entry| {
            if (entry.slot != slot) continue;
            if (n == out.len) break;
            out[n] = .{
                .priority = entry.priority,
                .text = entry.text[0..entry.text_len],
                .effect = entry.effect,
            };
            n += 1;
        }
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const current = out[i];
            var j = i;
            while (j > 0 and current.priority > out[j - 1].priority) : (j -= 1) out[j] = out[j - 1];
            out[j] = current;
        }
        return n;
    }

    pub fn highestPriority(self: *const Store, slot: Slot) ?View {
        var views: [1]View = undefined;
        if (self.ordered(slot, &views) == 0) return null;
        return views[0];
    }

    pub fn hasAnimated(self: *const Store, slot: Slot) bool {
        for (self.entries[0..self.len]) |entry| {
            if (entry.slot == slot and entry.effect == .shimmer) return true;
        }
        return false;
    }

    fn find(self: *const Store, slot: Slot, id: ContributionId) ?usize {
        for (self.entries[0..self.len], 0..) |entry, index| {
            if (entry.slot == slot and entry.id == id) return index;
        }
        return null;
    }
};

test "set replaces by id and ordered sorts by priority" {
    var store: Store = .{};
    try std.testing.expectEqual(SetResult.ok, store.set(.{
        .slot = .status_line,
        .id = 1,
        .priority = 1,
        .text = "low",
    }));
    try std.testing.expectEqual(SetResult.ok, store.set(.{
        .slot = .status_line,
        .id = 2,
        .priority = 9,
        .text = "high",
    }));
    try std.testing.expectEqual(SetResult.ok, store.set(.{
        .slot = .status_line,
        .id = 1,
        .priority = 1,
        .text = "low2",
    }));

    var views: [4]View = undefined;
    const n = store.ordered(.status_line, &views);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("high", views[0].text);
    try std.testing.expectEqualStrings("low2", views[1].text);
}

test "set sanitizes line breaks and bounds text" {
    var store: Store = .{};
    _ = store.set(.{ .slot = .status_line, .id = 1, .text = "a\nb\xffc" });
    const view = store.highestPriority(.status_line).?;
    try std.testing.expectEqualStrings("a b\u{fffd}c", view.text);
}

test "store rejects past capacity and clear frees a slot" {
    var store: Store = .{};
    var id: ContributionId = 1;
    while (id <= entry_count_max) : (id += 1) {
        try std.testing.expectEqual(SetResult.ok, store.set(.{ .slot = .status_line, .id = id, .text = "x" }));
    }
    try std.testing.expectEqual(SetResult.dropped_full, store.set(.{ .slot = .status_line, .id = 99, .text = "x" }));
    try std.testing.expect(store.clear(.{ .slot = .status_line, .id = 1 }));
    try std.testing.expectEqual(SetResult.ok, store.set(.{ .slot = .status_line, .id = 99, .text = "x" }));
}
