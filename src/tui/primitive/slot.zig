const std = @import("std");

pub const SlotId = enum(u16) {
    shell_header,
    transcript_status,
    composer_header,
    composer_footer,
};

pub const ContributionId = enum(u32) {
    _,
};

pub const Owner = enum {
    builtin,
    extension,
};

pub const Lifetime = enum {
    frame,
    session,
};

pub const Contribution = struct {
    id: ContributionId,
    owner: Owner,
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
        owner: Owner,
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
                .owner = owner,
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
            .owner = owner,
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

pub const Registry = struct {
    slots: [4]Slot = .{
        .init(.shell_header),
        .init(.transcript_status),
        .init(.composer_header),
        .init(.composer_footer),
    },

    pub fn deinit(self: *Registry, allocator: std.mem.Allocator) void {
        for (&self.slots) |*s| s.deinit(allocator);
        self.* = undefined;
    }

    pub fn get(self: *Registry, id: SlotId) *Slot {
        return switch (id) {
            .shell_header => &self.slots[0],
            .transcript_status => &self.slots[1],
            .composer_header => &self.slots[2],
            .composer_footer => &self.slots[3],
        };
    }
};

test "slot contribution replace is single-owner mutation" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const id: ContributionId = @enumFromInt(1);
    const s = registry.get(.composer_footer);
    try s.setText(std.testing.allocator, id, .builtin, 0, .session, "model");
    try s.setText(std.testing.allocator, id, .builtin, 1, .session, "model gpt");
    try std.testing.expectEqual(@as(usize, 1), s.contribution_count);
    try std.testing.expectEqualStrings("model gpt", s.contributions[0].text);
}

test "slot contributions are priority ordered and clear preserves order" {
    var registry: Registry = .{};
    defer registry.deinit(std.testing.allocator);

    const low: ContributionId = @enumFromInt(1);
    const high: ContributionId = @enumFromInt(2);
    const middle: ContributionId = @enumFromInt(3);
    const s = registry.get(.composer_footer);

    try s.setText(std.testing.allocator, low, .builtin, 0, .session, "low");
    try s.setText(std.testing.allocator, high, .extension, 10, .session, "high");
    try s.setText(std.testing.allocator, middle, .extension, 5, .session, "middle");

    try std.testing.expectEqual(high, s.contributions[0].id);
    try std.testing.expectEqual(middle, s.contributions[1].id);
    try std.testing.expectEqual(low, s.contributions[2].id);

    s.clear(std.testing.allocator, middle);
    try std.testing.expectEqual(@as(usize, 2), s.contribution_count);
    try std.testing.expectEqual(high, s.contributions[0].id);
    try std.testing.expectEqual(low, s.contributions[1].id);
}
