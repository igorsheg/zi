const std = @import("std");

pub const SlotId = enum(u16) {
    _,
};

pub const ContributionId = enum(u32) {
    _,
};

pub const Lifetime = enum {
    frame,
    retained,
};

pub const Contribution = struct {
    id: ContributionId,
    priority: i16,
    lifetime: Lifetime,
    text: []u8,

    pub fn deinit(self: *Contribution, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
        self.* = undefined;
    }
};

pub const Slot = struct {
    pub const contribution_count_max = 16;
    pub const contribution_bytes_max = 4096;

    id: SlotId,
    revision: u64 = 0,
    contributions: [contribution_count_max]Contribution = undefined,
    contribution_count: usize = 0,

    pub fn init(id: SlotId) Slot {
        return .{ .id = id };
    }

    pub fn deinit(self: *Slot, allocator: std.mem.Allocator) void {
        var index: usize = 0;
        while (index < self.contribution_count) : (index += 1) {
            self.contributions[index].deinit(allocator);
        }
        self.* = undefined;
    }

    pub fn setText(
        self: *Slot,
        allocator: std.mem.Allocator,
        id: ContributionId,
        priority: i16,
        lifetime: Lifetime,
        text: []const u8,
    ) !void {
        if (text.len > contribution_bytes_max) return error.SlotContributionTooLarge;
        const owned = try allocator.dupe(u8, text);
        errdefer allocator.free(owned);

        if (self.findIndex(id)) |index| {
            self.contributions[index].deinit(allocator);
            self.contributions[index] = .{
                .id = id,
                .priority = priority,
                .lifetime = lifetime,
                .text = owned,
            };
            self.sortContributions();
            self.revision += 1;
            return;
        }

        if (self.contribution_count == self.contributions.len) return error.SlotFull;
        self.contributions[self.contribution_count] = .{
            .id = id,
            .priority = priority,
            .lifetime = lifetime,
            .text = owned,
        };
        self.contribution_count += 1;
        self.sortContributions();
        self.revision += 1;
    }

    pub fn clear(self: *Slot, allocator: std.mem.Allocator, id: ContributionId) void {
        const index = self.findIndex(id) orelse return;
        self.contributions[index].deinit(allocator);
        var move_index = index;
        while (move_index + 1 < self.contribution_count) : (move_index += 1) {
            self.contributions[move_index] = self.contributions[move_index + 1];
        }
        self.contribution_count -= 1;
        self.revision += 1;
    }

    fn findIndex(self: *const Slot, id: ContributionId) ?usize {
        var index: usize = 0;
        while (index < self.contribution_count) : (index += 1) {
            if (self.contributions[index].id == id) return index;
        }
        return null;
    }

    fn sortContributions(self: *Slot) void {
        std.sort.insertion(Contribution, self.contributions[0..self.contribution_count], {}, contributionLessThan);
    }

    fn contributionLessThan(_: void, lhs: Contribution, rhs: Contribution) bool {
        if (lhs.priority != rhs.priority) return lhs.priority > rhs.priority;
        return @intFromEnum(lhs.id) < @intFromEnum(rhs.id);
    }
};

pub fn Registry(comptime slot_ids: []const SlotId) type {
    return struct {
        const Self = @This();

        slots: [slot_ids.len]Slot = initSlots(),

        fn initSlots() [slot_ids.len]Slot {
            var out: [slot_ids.len]Slot = undefined;
            for (slot_ids, 0..) |id, index| out[index] = .init(id);
            return out;
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            for (&self.slots) |*s| s.deinit(allocator);
            self.* = undefined;
        }

        pub fn get(self: *Self, id: SlotId) *Slot {
            for (&self.slots) |*s| {
                if (s.id == id) return s;
            }
            unreachable;
        }
    };
}

test "slot contribution replace is single-owner mutation" {
    const footer: SlotId = @enumFromInt(1);
    const TestRegistry = Registry(&.{footer});
    var registry: TestRegistry = .{};
    defer registry.deinit(std.testing.allocator);

    const id: ContributionId = @enumFromInt(1);
    const s = registry.get(footer);
    try s.setText(std.testing.allocator, id, 0, .retained, "old");
    try s.setText(std.testing.allocator, id, 1, .retained, "new");
    try std.testing.expectEqual(@as(usize, 1), s.contribution_count);
    try std.testing.expectEqualStrings("new", s.contributions[0].text);
}

test "slot contributions are priority ordered and clear preserves order" {
    const footer: SlotId = @enumFromInt(1);
    const TestRegistry = Registry(&.{footer});
    var registry: TestRegistry = .{};
    defer registry.deinit(std.testing.allocator);

    const low: ContributionId = @enumFromInt(1);
    const high: ContributionId = @enumFromInt(2);
    const middle: ContributionId = @enumFromInt(3);
    const s = registry.get(footer);

    try s.setText(std.testing.allocator, low, 0, .retained, "low");
    try s.setText(std.testing.allocator, high, 10, .retained, "high");
    try s.setText(std.testing.allocator, middle, 5, .retained, "middle");

    try std.testing.expectEqual(high, s.contributions[0].id);
    try std.testing.expectEqual(middle, s.contributions[1].id);
    try std.testing.expectEqual(low, s.contributions[2].id);

    s.clear(std.testing.allocator, middle);
    try std.testing.expectEqual(@as(usize, 2), s.contribution_count);
    try std.testing.expectEqual(high, s.contributions[0].id);
    try std.testing.expectEqual(low, s.contributions[1].id);
}
