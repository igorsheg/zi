//! Bounded ephemeral notifications for the status row. The App owns this store;
//! frontends mutate it only through App.Command. Items are small inline strings,
//! TTL-pruned on tick, and deduped at view time.
const std = @import("std");
const shuffle_text = @import("shuffle_text.zig");
const status = @import("status.zig");
const text_mod = @import("text.zig");

pub const item_count_max: usize = 16;
pub const group_count_max: usize = 8;
pub const text_bytes_max: usize = status.text_bytes_max;
pub const annote_bytes_max: usize = 16;
pub const count_max: u16 = 9999;
pub const default_ttl_ms: i64 = 5_000;
pub const never_expires: i64 = std.math.maxInt(i64);

pub const Key = u32;
pub const GroupKey = u8;
pub const Level = enum { debug, info, warning, err };
pub const Tone = status.Tone;

pub const Group = struct {
    key: GroupKey,
    priority: i16 = 50,
    ttl_ms: i64 = default_ttl_ms,
    render_limit: u8 = 0,
};

pub const Notify = struct {
    group: GroupKey = 0,
    key: Key = 0,
    message: []const u8,
    level: Level = .info,
    annote: ?[]const u8 = null,
    ttl_ms: ?i64 = null,
    tone: ?Tone = null,
    hidden: bool = false,
    update_only: bool = false,
    skip_dedup: bool = false,
};

pub const Clear = union(enum) {
    item: struct { group: GroupKey = 0, key: Key },
    group: GroupKey,
    all,
};

pub const SetResult = enum { ok, dropped_full, update_only_miss };

pub const View = struct {
    message: []const u8,
    annote: []const u8,
    tone: Tone,
    count: u16,
    started_ms: i64,
};

const Item = struct {
    group: GroupKey,
    key: Key,
    message_len: u8,
    message: [text_bytes_max]u8,
    annote_len: u8,
    annote: [annote_bytes_max]u8,
    tone: Tone,
    expires_at: i64,
    last_updated: i64,
    hidden: bool,
    skip_dedup: bool,
};

const Candidate = struct {
    item_index: usize,
    group_priority: i16,
    count: u16,
};

pub const Store = struct {
    items: [item_count_max]Item = undefined,
    item_len: usize = 0,
    groups: [group_count_max]Group = undefined,
    group_len: usize = 0,
    revision: u64 = 0,

    pub fn ensureGroup(self: *Store, group: Group) void {
        if (self.findGroupIndex(group.key)) |index| {
            self.groups[index] = group;
            self.revision +%= 1;
            return;
        }
        if (self.group_len == self.groups.len) return;
        self.groups[self.group_len] = group;
        self.group_len += 1;
        self.revision +%= 1;
    }

    pub fn notify(self: *Store, update: Notify, now_ms: i64) SetResult {
        var message_buffer: [text_bytes_max]u8 = undefined;
        const message = cleanInto(&message_buffer, update.message);
        var annote_buffer: [annote_bytes_max]u8 = undefined;
        const defaults = levelDefaults(update.level);
        const annote_source = update.annote orelse defaults.annote;
        const annote = cleanInto(&annote_buffer, annote_source);
        const tone = update.tone orelse defaults.tone;
        const group = self.groupFor(update.group);

        if (self.findItem(update.group, update.key)) |index| {
            const item = &self.items[index];
            if (message.len > 0) {
                @memcpy(item.message[0..message.len], message);
                item.message_len = @intCast(message.len);
            }
            @memcpy(item.annote[0..annote.len], annote);
            item.annote_len = @intCast(annote.len);
            item.tone = tone;
            item.hidden = update.hidden;
            item.skip_dedup = update.skip_dedup;
            if (update.ttl_ms) |ttl| item.expires_at = computeExpiry(now_ms, ttl, group.ttl_ms);
            item.last_updated = now_ms;
            self.revision +%= 1;
            return .ok;
        }

        if (message.len == 0 or update.update_only) return .update_only_miss;
        if (self.item_len == self.items.len) return .dropped_full;

        const index = self.item_len;
        self.item_len += 1;
        var item = &self.items[index];
        item.group = update.group;
        item.key = update.key;
        @memcpy(item.message[0..message.len], message);
        item.message_len = @intCast(message.len);
        @memcpy(item.annote[0..annote.len], annote);
        item.annote_len = @intCast(annote.len);
        item.tone = tone;
        item.expires_at = computeExpiry(now_ms, update.ttl_ms orelse group.ttl_ms, group.ttl_ms);
        item.last_updated = now_ms;
        item.hidden = update.hidden;
        item.skip_dedup = update.skip_dedup;
        self.revision +%= 1;
        return .ok;
    }

    pub fn clear(self: *Store, request: Clear) bool {
        return switch (request) {
            .item => |item| self.remove(item.group, item.key),
            .group => |group| self.clearGroup(group),
            .all => self.clearAll(),
        };
    }

    pub fn remove(self: *Store, group: GroupKey, key: Key) bool {
        if (key == 0) return false;
        const index = self.findItem(group, key) orelse return false;
        self.removeAt(index);
        return true;
    }

    pub fn tick(self: *Store, now_ms: i64) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.item_len) {
            if (self.items[index].expires_at <= now_ms) {
                self.removeAt(index);
                changed = true;
            } else {
                index += 1;
            }
        }
        return changed;
    }

    pub fn ordered(self: *const Store, now_ms: i64, out: []View) usize {
        var candidates: [item_count_max]Candidate = undefined;
        var candidate_len: usize = 0;

        for (self.items[0..self.item_len], 0..) |*item, index| {
            if (!itemVisible(item, now_ms)) continue;
            if (!item.skip_dedup) {
                if (self.findCandidate(item, candidates[0..candidate_len])) |candidate_index| {
                    var candidate = &candidates[candidate_index];
                    if (candidate.count < count_max) candidate.count += 1;
                    if (item.last_updated > self.items[candidate.item_index].last_updated) {
                        candidate.item_index = index;
                        candidate.group_priority = self.groupFor(item.group).priority;
                    }
                    continue;
                }
            }
            if (candidate_len == candidates.len) break;
            candidates[candidate_len] = .{
                .item_index = index,
                .group_priority = self.groupFor(item.group).priority,
                .count = 1,
            };
            candidate_len += 1;
        }

        sortCandidates(self, candidates[0..candidate_len]);

        var n: usize = 0;
        for (candidates[0..candidate_len]) |candidate| {
            if (n == out.len) break;
            const item = &self.items[candidate.item_index];
            out[n] = .{
                .message = item.message[0..item.message_len],
                .annote = item.annote[0..item.annote_len],
                .tone = item.tone,
                .count = candidate.count,
                .started_ms = item.last_updated,
            };
            n += 1;
        }
        return n;
    }

    pub fn count(self: *const Store, now_ms: i64) usize {
        var n: usize = 0;
        for (self.items[0..self.item_len]) |*item| {
            if (itemVisible(item, now_ms)) n += 1;
        }
        return n;
    }

    pub fn hasAnimated(self: *const Store, now_ms: i64) bool {
        for (self.items[0..self.item_len]) |*item| {
            if (!itemVisible(item, now_ms)) continue;
            if (shuffle_text.isRunning(now_ms, item.last_updated, .{})) return true;
        }
        return false;
    }

    pub fn nextDeadlineMs(self: *const Store, now_ms: i64) ?i64 {
        var deadline: ?i64 = null;
        for (self.items[0..self.item_len]) |*item| {
            if (!itemVisible(item, now_ms)) continue;
            if (item.expires_at == never_expires) continue;
            if (deadline == null or item.expires_at < deadline.?) deadline = item.expires_at;
        }
        return deadline;
    }

    fn clearGroup(self: *Store, group: GroupKey) bool {
        var changed = false;
        var index: usize = 0;
        while (index < self.item_len) {
            if (self.items[index].group == group) {
                self.removeAt(index);
                changed = true;
            } else {
                index += 1;
            }
        }
        return changed;
    }

    fn clearAll(self: *Store) bool {
        if (self.item_len == 0) return false;
        self.item_len = 0;
        self.revision +%= 1;
        return true;
    }

    fn removeAt(self: *Store, index: usize) void {
        var i = index;
        while (i + 1 < self.item_len) : (i += 1) self.items[i] = self.items[i + 1];
        self.item_len -= 1;
        self.revision +%= 1;
    }

    fn findItem(self: *const Store, group: GroupKey, key: Key) ?usize {
        if (key == 0) return null;
        for (self.items[0..self.item_len], 0..) |item, index| {
            if (item.group == group and item.key == key) return index;
        }
        return null;
    }

    fn findGroupIndex(self: *const Store, key: GroupKey) ?usize {
        for (self.groups[0..self.group_len], 0..) |group, index| {
            if (group.key == key) return index;
        }
        return null;
    }

    fn groupFor(self: *const Store, key: GroupKey) Group {
        if (self.findGroupIndex(key)) |index| return self.groups[index];
        return .{ .key = key };
    }

    fn findCandidate(self: *const Store, item: *const Item, candidates: []const Candidate) ?usize {
        for (candidates, 0..) |candidate, index| {
            if (sameContent(item, &self.items[candidate.item_index])) return index;
        }
        return null;
    }
};

fn levelDefaults(level: Level) struct { annote: []const u8, tone: Tone } {
    return switch (level) {
        .debug => .{ .annote = "DEBUG", .tone = .secondary },
        .info => .{ .annote = "INFO", .tone = .accent },
        .warning => .{ .annote = "WARN", .tone = .warning },
        .err => .{ .annote = "ERROR", .tone = .err },
    };
}

fn cleanInto(buffer: []u8, source: []const u8) []const u8 {
    var sanitized: [text_bytes_max]u8 = undefined;
    const clean = text_mod.sanitizeInto(&sanitized, source);
    const bounded = text_mod.utf8Prefix(clean, buffer.len);
    const source_prefix = if (bounded.len > 0 or clean.len == 0) bounded else clean[0..@min(clean.len, buffer.len)];
    var len: usize = 0;
    for (source_prefix) |byte| {
        buffer[len] = if (byte == '\n' or byte == '\r' or byte == '\t') ' ' else byte;
        len += 1;
    }
    return buffer[0..len];
}

fn computeExpiry(now_ms: i64, ttl_ms: i64, default_ttl_ms_value: i64) i64 {
    const ttl = if (ttl_ms == 0) default_ttl_ms_value else ttl_ms;
    if (ttl < 0) return never_expires;
    return now_ms +| ttl;
}

fn itemVisible(item: *const Item, now_ms: i64) bool {
    return !item.hidden and item.expires_at > now_ms;
}

fn sameContent(a: *const Item, b: *const Item) bool {
    return a.group == b.group and
        std.mem.eql(u8, a.message[0..a.message_len], b.message[0..b.message_len]) and
        std.mem.eql(u8, a.annote[0..a.annote_len], b.annote[0..b.annote_len]);
}

fn sortCandidates(store: *const Store, candidates: []Candidate) void {
    var i: usize = 1;
    while (i < candidates.len) : (i += 1) {
        const current = candidates[i];
        var j = i;
        while (j > 0 and candidateBefore(store, current, candidates[j - 1])) : (j -= 1) {
            candidates[j] = candidates[j - 1];
        }
        candidates[j] = current;
    }
}

fn candidateBefore(store: *const Store, a: Candidate, b: Candidate) bool {
    if (a.group_priority != b.group_priority) return a.group_priority > b.group_priority;
    return store.items[a.item_index].last_updated > store.items[b.item_index].last_updated;
}

test "notify creates and tick expires" {
    var store: Store = .{};
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .message = "hello" }, 100));
    try std.testing.expectEqual(@as(usize, 1), store.count(100));
    try std.testing.expect(!store.tick(5_099));
    try std.testing.expectEqual(@as(usize, 1), store.count(5_099));
    try std.testing.expect(store.tick(5_100));
    try std.testing.expectEqual(@as(usize, 0), store.count(5_100));
}

test "same key updates in place" {
    var store: Store = .{};
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .key = 1, .message = "one" }, 0));
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .key = 1, .message = "two" }, 10));
    var views: [4]View = undefined;
    const n = store.ordered(10, &views);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("two", views[0].message);
    try std.testing.expectEqual(@as(u16, 1), views[0].count);
}

test "anonymous duplicate notifications dedup in view" {
    var store: Store = .{};
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .message = "same" }, 0));
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .message = "same" }, 10));
    var views: [4]View = undefined;
    const n = store.ordered(10, &views);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expectEqualStrings("same", views[0].message);
    try std.testing.expectEqual(@as(u16, 2), views[0].count);
}

test "clear scopes and capacity" {
    var store: Store = .{};
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .group = 1, .message = "a" }, 0));
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .group = 2, .message = "b" }, 0));
    try std.testing.expect(store.clear(.{ .group = 1 }));
    try std.testing.expectEqual(@as(usize, 1), store.count(0));
    try std.testing.expect(store.clear(.all));
    try std.testing.expectEqual(@as(usize, 0), store.count(0));

    var i: usize = 0;
    while (i < item_count_max) : (i += 1) {
        try std.testing.expectEqual(SetResult.ok, store.notify(.{ .message = "x", .skip_dedup = true }, 0));
    }
    try std.testing.expectEqual(SetResult.dropped_full, store.notify(.{ .message = "x" }, 0));
}

test "oversized utf8 truncates on a valid boundary" {
    var store: Store = .{};
    const message = "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂" ++
        "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂" ++
        "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂" ++
        "🙂🙂🙂🙂🙂🙂🙂🙂🙂🙂";
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .message = message }, 0));
    var views: [1]View = undefined;
    const n = store.ordered(0, &views);
    try std.testing.expectEqual(@as(usize, 1), n);
    try std.testing.expect(std.unicode.utf8ValidateSlice(views[0].message));
    try std.testing.expect(!std.mem.endsWith(u8, views[0].message, "�"));
}

test "ordered sorts by group priority then recency" {
    var store: Store = .{};
    store.ensureGroup(.{ .key = 1, .priority = 1 });
    store.ensureGroup(.{ .key = 2, .priority = 9 });
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .group = 1, .message = "old" }, 20));
    try std.testing.expectEqual(SetResult.ok, store.notify(.{ .group = 2, .message = "high" }, 10));
    var views: [4]View = undefined;
    const n = store.ordered(20, &views);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("high", views[0].message);
}
