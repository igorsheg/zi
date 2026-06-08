const std = @import("std");
pub const contribution_count_max: usize = 16;
pub const contribution_text_bytes_max: usize = 160;
pub const status_area_slot_count_max: usize = 8;

pub const SlotName = enum {
    composer_top_right,
    status_area,
};

pub const RenderEffect = enum {
    none,
    shimmer,
};

pub const ContributionId = u32;
pub const OwnerId = u32;

pub const SetContribution = struct {
    slot: SlotName,
    id: ContributionId,
    owner: OwnerId,
    priority: i16 = 0,
    text: []const u8,
    effect: RenderEffect = .none,
};

pub const ClearContribution = struct {
    slot: SlotName,
    id: ContributionId,
    owner: OwnerId,
};

const Contribution = struct {
    slot: SlotName,
    id: ContributionId,
    owner: OwnerId,
    priority: i16,
    text: []u8,
    effect: RenderEffect,
};

pub const SlotStore = struct {
    items: [contribution_count_max]Contribution = undefined,
    len: usize = 0,

    pub fn deinit(self: *SlotStore, allocator: std.mem.Allocator) void {
        var index: usize = 0;
        while (index < self.len) : (index += 1) allocator.free(self.items[index].text);
        self.* = undefined;
    }

    pub fn set(self: *SlotStore, allocator: std.mem.Allocator, update: SetContribution) !void {
        try validateSet(update);
        const existing = self.find(update.slot, update.id, update.owner);
        if (existing == null and self.len == self.items.len) return error.SlotContributionLimitExceeded;

        const text = try allocator.dupe(u8, update.text);
        errdefer allocator.free(text);

        if (existing) |index| {
            const old_text = self.items[index].text;
            self.items[index] = .{
                .slot = update.slot,
                .id = update.id,
                .owner = update.owner,
                .priority = update.priority,
                .text = text,
                .effect = update.effect,
            };
            allocator.free(old_text);
            return;
        }

        self.items[self.len] = .{
            .slot = update.slot,
            .id = update.id,
            .owner = update.owner,
            .priority = update.priority,
            .text = text,
            .effect = update.effect,
        };
        self.len += 1;
    }

    pub fn clear(self: *SlotStore, allocator: std.mem.Allocator, request: ClearContribution) bool {
        const index = self.find(request.slot, request.id, request.owner) orelse return false;
        self.removeAt(allocator, index);
        return true;
    }

    pub fn count(self: SlotStore, slot: SlotName) usize {
        var n: usize = 0;
        for (self.items[0..self.len]) |item| {
            if (item.slot == slot) n += 1;
        }
        return n;
    }

    pub fn orderedSlot(self: SlotStore, slot: SlotName, out: []SlotView) usize {
        var n: usize = 0;
        for (self.items[0..self.len]) |item| {
            if (item.slot != slot) continue;
            if (n == out.len) break;
            out[n] = .{
                .priority = item.priority,
                .text = item.text,
                .effect = item.effect,
            };
            n += 1;
        }
        sortViews(out[0..n]);
        return n;
    }

    pub fn highestPriority(self: SlotStore, slot: SlotName) ?SlotView {
        var views: [1]SlotView = undefined;
        if (self.orderedSlot(slot, &views) == 0) return null;
        return views[0];
    }

    pub fn hasAnimated(self: SlotStore, slot: SlotName) bool {
        for (self.items[0..self.len]) |item| {
            if (item.slot != slot) continue;
            switch (item.effect) {
                .none => {},
                .shimmer => return true,
            }
        }
        return false;
    }

    fn find(self: SlotStore, slot: SlotName, id: ContributionId, owner: OwnerId) ?usize {
        for (self.items[0..self.len], 0..) |item, index| {
            if (item.slot == slot and item.id == id and item.owner == owner) return index;
        }
        return null;
    }

    fn removeAt(self: *SlotStore, allocator: std.mem.Allocator, index: usize) void {
        std.debug.assert(index < self.len);
        allocator.free(self.items[index].text);
        var i = index;
        while (i + 1 < self.len) : (i += 1) self.items[i] = self.items[i + 1];
        self.len -= 1;
    }
};

pub const SlotView = struct {
    priority: i16,
    text: []const u8,
    effect: RenderEffect,
};

fn validateSet(update: SetContribution) !void {
    if (update.id == 0 or update.owner == 0) return error.InvalidSlotContribution;
    if (update.text.len > contribution_text_bytes_max) return error.SlotContributionTooLarge;
    if (!std.unicode.utf8ValidateSlice(update.text)) return error.InvalidSlotContributionText;
    if (std.mem.indexOfScalar(u8, update.text, '\n') != null) return error.InvalidSlotContributionText;
    if (std.mem.indexOfScalar(u8, update.text, '\r') != null) return error.InvalidSlotContributionText;
}

fn sortViews(items: []SlotView) void {
    var i: usize = 1;
    while (i < items.len) : (i += 1) {
        const current = items[i];
        var j = i;
        while (j > 0 and before(current, items[j - 1])) : (j -= 1) items[j] = items[j - 1];
        items[j] = current;
    }
}

fn before(a: SlotView, b: SlotView) bool {
    return a.priority > b.priority;
}

test "slot store sets replaces clears and bounds contributions" {
    var slots: SlotStore = .{};
    defer slots.deinit(std.testing.allocator);

    try slots.set(std.testing.allocator, .{
        .slot = .composer_top_right,
        .id = 1,
        .owner = 7,
        .priority = 1,
        .text = "one",
    });
    try slots.set(std.testing.allocator, .{
        .slot = .composer_top_right,
        .id = 2,
        .owner = 7,
        .priority = 2,
        .text = "two",
    });
    try slots.set(std.testing.allocator, .{
        .slot = .composer_top_right,
        .id = 1,
        .owner = 7,
        .priority = 3,
        .text = "new",
    });

    var views: [2]SlotView = undefined;
    const n = slots.orderedSlot(.composer_top_right, &views);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("new", views[0].text);
    try std.testing.expectEqualStrings("two", views[1].text);

    try std.testing.expect(slots.clear(std.testing.allocator, .{ .slot = .composer_top_right, .id = 2, .owner = 7 }));
    try std.testing.expectEqual(@as(usize, 1), slots.count(.composer_top_right));
    try std.testing.expect(slots.clear(std.testing.allocator, .{ .slot = .composer_top_right, .id = 1, .owner = 7 }));
    try std.testing.expectEqual(@as(usize, 0), slots.len);
}

test "slot store tracks animated status contributions" {
    var slots: SlotStore = .{};
    defer slots.deinit(std.testing.allocator);

    try slots.set(std.testing.allocator, .{
        .slot = .status_area,
        .id = 1,
        .owner = 1,
        .text = "working",
        .effect = .shimmer,
    });
    try std.testing.expect(slots.hasAnimated(.status_area));
    try std.testing.expect(slots.clear(std.testing.allocator, .{ .slot = .status_area, .id = 1, .owner = 1 }));
    try std.testing.expect(!slots.hasAnimated(.status_area));
}

test "slot store rejects invalid text before mutation" {
    var slots: SlotStore = .{};
    defer slots.deinit(std.testing.allocator);

    try slots.set(std.testing.allocator, .{ .slot = .composer_top_right, .id = 1, .owner = 1, .text = "ok" });
    try std.testing.expectError(
        error.InvalidSlotContributionText,
        slots.set(std.testing.allocator, .{
            .slot = .composer_top_right,
            .id = 2,
            .owner = 1,
            .text = "bad\n",
        }),
    );
    try std.testing.expectEqual(@as(usize, 1), slots.len);
}
