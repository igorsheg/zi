const std = @import("std");

pub const maximum_levels: usize = 10;
/// Maximum stored length. Hax rejects values whose length is 16 bytes or more.
pub const maximum_value_bytes: usize = 15;

pub const Error = error{
    InvalidEffort,
    TooManyEfforts,
};

pub const canonical_ladder = [_][]const u8{
    "none",
    "minimal",
    "low",
    "medium",
    "high",
    "xhigh",
    "max",
};

/// Allocation-free effort vocabulary. Values are owned inline. `known` separates
/// absent metadata from metadata that explicitly reports no accepted values.
pub const Set = struct {
    known: bool = false,
    count: u8 = 0,
    storage: [maximum_levels][maximum_value_bytes]u8 = undefined,
    lengths: [maximum_levels]u8 = undefined,

    /// Copies a complete vocabulary. An empty input creates a known-empty set.
    pub fn init(values: []const []const u8) Error!Set {
        var result: Set = .{ .known = true };
        for (values) |value| try result.add(value);
        return result;
    }

    /// Copies one exact spelling. Duplicate values are already satisfied.
    pub fn add(self: *Set, value: []const u8) Error!void {
        self.known = true;
        if (value.len == 0 or value.len > maximum_value_bytes) return error.InvalidEffort;
        if (self.has(value)) return;
        if (self.count >= maximum_levels) return error.TooManyEfforts;

        const index: usize = self.count;
        @memcpy(self.storage[index][0..value.len], value);
        self.lengths[index] = @intCast(value.len);
        self.count += 1;
    }

    pub fn has(self: *const Set, value: []const u8) bool {
        if (!self.known) return false;
        for (0..self.count) |index| {
            if (std.mem.eql(u8, self.valueAt(index), value)) return true;
        }
        return false;
    }

    /// Returns a borrowed inline value in insertion order.
    pub fn valueAt(self: *const Set, index: usize) []const u8 {
        std.debug.assert(index < self.count);
        return self.storage[index][0..self.lengths[index]];
    }

    /// Returns the exact offered value. Otherwise it returns the closest ranked
    /// lower value, then the closest ranked higher value. Results borrow this set.
    pub fn clamp(self: *const Set, requested: []const u8) ?[]const u8 {
        if (!self.known or self.count == 0 or requested.len == 0) return null;
        for (0..self.count) |index| {
            const value = self.valueAt(index);
            if (std.mem.eql(u8, value, requested)) return value;
        }

        const requested_rank = rank(requested) orelse return null;
        var lower: ?[]const u8 = null;
        var upper: ?[]const u8 = null;
        var lower_rank: ?usize = null;
        var upper_rank: ?usize = null;
        for (0..self.count) |index| {
            const value = self.valueAt(index);
            const value_rank = rank(value) orelse continue;
            if (value_rank <= requested_rank and
                (lower_rank == null or value_rank > lower_rank.?))
            {
                lower = value;
                lower_rank = value_rank;
            }
            if (value_rank > requested_rank and
                (upper_rank == null or value_rank < upper_rank.?))
            {
                upper = value;
                upper_rank = value_rank;
            }
        }
        return lower orelse upper;
    }
};

/// Intersects known vocabularies in `a` order. Unknown metadata imposes no
/// constraint; known-empty metadata remains restrictive.
pub fn intersection(a: *const Set, b: *const Set) Set {
    if (!a.known) return b.*;
    if (!b.known) return a.*;

    var result: Set = .{ .known = true };
    for (0..a.count) |index| {
        const value = a.valueAt(index);
        if (b.has(value)) result.add(value) catch unreachable;
    }
    return result;
}

fn rank(value: []const u8) ?usize {
    for (canonical_ladder, 0..) |canonical, index| {
        if (std.mem.eql(u8, canonical, value)) return index;
    }
    return null;
}

test "effort set owns bounded deduplicated values and tracks known empty" {
    var set = try Set.init(&.{ "low", "low" });
    try std.testing.expect(set.known);
    try std.testing.expectEqual(@as(u8, 1), set.count);
    try std.testing.expect(set.has("low"));
    try std.testing.expect(!set.has("Low"));

    var source = [_]u8{ 'h', 'i', 'g', 'h' };
    try set.add(&source);
    source[0] = 'x';
    try std.testing.expect(set.has("high"));
    try std.testing.expect(!set.has("xigh"));

    const empty = try Set.init(&.{});
    try std.testing.expect(empty.known);
    try std.testing.expectEqual(@as(u8, 0), empty.count);
    try std.testing.expectError(error.InvalidEffort, set.add(""));
    try std.testing.expectError(error.InvalidEffort, set.add("0123456789abcdef"));
    try set.add("0123456789abcde");
}

test "effort set reports values beyond its fixed capacity" {
    var set = try Set.init(&.{});
    var buffer: [2]u8 = undefined;
    for (0..maximum_levels) |index| {
        buffer[0] = 'a';
        buffer[1] = @intCast('0' + index);
        try set.add(&buffer);
    }
    try std.testing.expectError(error.TooManyEfforts, set.add("overflow"));
    try std.testing.expectEqual(@as(u8, maximum_levels), set.count);
}

test "effort intersection preserves order and known-empty semantics" {
    const left = try Set.init(&.{ "low", "high", "provider-only" });
    const right = try Set.init(&.{ "high", "low", "max" });

    const both = intersection(&left, &right);
    try std.testing.expect(both.known);
    try std.testing.expectEqual(@as(u8, 2), both.count);
    try std.testing.expectEqualStrings("low", both.valueAt(0));
    try std.testing.expectEqualStrings("high", both.valueAt(1));

    const unknown: Set = .{};
    const constrained = intersection(&unknown, &left);
    try std.testing.expect(constrained.known);
    try std.testing.expect(constrained.has("provider-only"));
    try std.testing.expect(!intersection(&unknown, &unknown).known);

    const empty = try Set.init(&.{});
    const none = intersection(&left, &empty);
    try std.testing.expect(none.known);
    try std.testing.expectEqual(@as(u8, 0), none.count);
}

test "effort clamp matches exact or nearest ranked hax value" {
    const levels = try Set.init(&.{ "low", "high", "custom" });

    const exact = levels.clamp("custom").?;
    try std.testing.expectEqualStrings("custom", exact);
    try std.testing.expect(exact.ptr == levels.valueAt(2).ptr);
    try std.testing.expectEqualStrings("high", levels.clamp("xhigh").?);
    try std.testing.expectEqualStrings("low", levels.clamp("medium").?);
    try std.testing.expectEqualStrings("low", levels.clamp("none").?);
    try std.testing.expectEqualStrings("high", levels.clamp("max").?);
    try std.testing.expect(levels.clamp("ludicrous") == null);
    try std.testing.expect(levels.clamp("") == null);

    const empty = try Set.init(&.{});
    try std.testing.expect(empty.clamp("low") == null);
    const unknown: Set = .{};
    try std.testing.expect(unknown.clamp("low") == null);
}

test "effort clamp covers complete canonical rank" {
    const levels = try Set.init(&canonical_ladder);
    for (canonical_ladder) |value| try std.testing.expectEqualStrings(value, levels.clamp(value).?);

    const upper_only = try Set.init(&.{ "minimal", "max" });
    try std.testing.expectEqualStrings("minimal", upper_only.clamp("none").?);
}
