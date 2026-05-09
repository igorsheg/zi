const std = @import("std");

/// Core notification domain shared by zi-native flows and extension adapters.
/// This module intentionally knows nothing about Lua or extension UI targets.
pub const Level = enum { debug, info, warn, error_, success };

pub const Lifetime = union(enum) {
    manual,
    ttl_ms: u32,

    pub fn doneDefault() Lifetime {
        return .{ .ttl_ms = 3000 };
    }
};

pub const Spec = struct {
    state_owner_id: []const u8,
    generation: u64,
    id: []const u8,
    message: []const u8,
    group: ?[]const u8 = null,
    title: ?[]const u8 = null,
    annote: ?[]const u8 = null,
    level: Level = .info,
    progress: bool = false,
    done: bool = false,
    clear: bool = false,
    created_ns: i128 = 0,
    updated_ns: i128 = 0,
    lifetime: Lifetime = .manual,
    count: u32 = 1,

    pub fn ttlMs(self: Spec) ?u32 {
        return switch (self.lifetime) {
            .manual => null,
            .ttl_ms => |ms| ms,
        };
    }

    pub fn clone(allocator: std.mem.Allocator, spec: Spec) !Spec {
        const state_owner_id = try allocator.dupe(u8, spec.state_owner_id);
        errdefer allocator.free(state_owner_id);
        const id = try allocator.dupe(u8, spec.id);
        errdefer allocator.free(id);
        const message = try allocator.dupe(u8, spec.message);
        errdefer allocator.free(message);
        const group = if (spec.group) |v| try allocator.dupe(u8, v) else null;
        errdefer if (group) |v| allocator.free(v);
        const title = if (spec.title) |v| try allocator.dupe(u8, v) else null;
        errdefer if (title) |v| allocator.free(v);
        const annote = if (spec.annote) |v| try allocator.dupe(u8, v) else null;
        return .{
            .state_owner_id = state_owner_id,
            .generation = spec.generation,
            .id = id,
            .message = message,
            .group = group,
            .title = title,
            .annote = annote,
            .level = spec.level,
            .progress = spec.progress,
            .done = spec.done,
            .clear = spec.clear,
            .created_ns = spec.created_ns,
            .updated_ns = spec.updated_ns,
            .lifetime = spec.lifetime,
            .count = spec.count,
        };
    }

    pub fn deinit(self: *Spec, allocator: std.mem.Allocator) void {
        allocator.free(self.state_owner_id);
        allocator.free(self.id);
        allocator.free(self.message);
        if (self.group) |v| allocator.free(v);
        if (self.title) |v| allocator.free(v);
        if (self.annote) |v| allocator.free(v);
        self.* = undefined;
    }
};

pub const Center = struct {
    allocator: std.mem.Allocator,
    records: std.StringHashMap(Spec),

    pub fn init(allocator: std.mem.Allocator) Center {
        return .{ .allocator = allocator, .records = std.StringHashMap(Spec).init(allocator) };
    }

    pub fn deinit(self: *Center) void {
        var it = self.records.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.records.deinit();
    }

    pub fn apply(self: *Center, spec: Spec) !void {
        const key = try makeKey(self.allocator, spec.state_owner_id, spec.id);
        errdefer self.allocator.free(key);
        if (spec.clear) {
            if (self.records.fetchRemove(key)) |old| {
                self.allocator.free(old.key);
                var value = old.value;
                value.deinit(self.allocator);
            }
            self.allocator.free(key);
            return;
        }
        var cloned = try Spec.clone(self.allocator, spec);
        errdefer cloned.deinit(self.allocator);
        if (self.records.getEntry(key)) |entry| {
            if (spec.generation < entry.value_ptr.generation) {
                self.allocator.free(key);
                return;
            }
            cloned.created_ns = entry.value_ptr.created_ns;
            if (std.mem.eql(u8, cloned.message, entry.value_ptr.message)) cloned.count = entry.value_ptr.count + 1;
            entry.value_ptr.deinit(self.allocator);
            entry.value_ptr.* = cloned;
            self.allocator.free(key);
            return;
        }
        try self.records.put(key, cloned);
    }

    pub fn expire(self: *Center, now_ns: i128) bool {
        var keys = std.ArrayList([]const u8).empty;
        defer keys.deinit(self.allocator);
        var it = self.records.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.ttlMs()) |ttl_ms| {
                if (now_ns - entry.value_ptr.updated_ns >= @as(i128, ttl_ms) * std.time.ns_per_ms) {
                    keys.append(self.allocator, entry.key_ptr.*) catch break;
                }
            }
        }
        for (keys.items) |key| {
            var old = self.records.fetchRemove(key) orelse continue;
            self.allocator.free(old.key);
            old.value.deinit(self.allocator);
        }
        return keys.items.len > 0;
    }

    pub fn hasActiveProgress(self: *Center) bool {
        var it = self.records.iterator();
        while (it.next()) |entry| if (entry.value_ptr.progress and !entry.value_ptr.done) return true;
        return false;
    }
};

pub fn makeKey(allocator: std.mem.Allocator, owner: []const u8, id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\x1f{s}", .{ owner, id });
}

test "notification center replaces by key and counts duplicate messages" {
    var center = Center.init(std.testing.allocator);
    defer center.deinit();

    try center.apply(.{ .state_owner_id = "core", .generation = 1, .id = "build", .message = "running", .updated_ns = 10 });
    try center.apply(.{ .state_owner_id = "core", .generation = 2, .id = "build", .message = "running", .updated_ns = 20 });

    const key = try makeKey(std.testing.allocator, "core", "build");
    defer std.testing.allocator.free(key);
    const record = center.records.get(key).?;
    try std.testing.expectEqual(@as(u32, 2), record.count);
    try std.testing.expectEqual(@as(i128, 0), record.created_ns);
    try std.testing.expectEqual(@as(i128, 20), record.updated_ns);
}

test "notification center expires ttl records" {
    var center = Center.init(std.testing.allocator);
    defer center.deinit();

    try center.apply(.{ .state_owner_id = "core", .generation = 1, .id = "done", .message = "done", .updated_ns = 1_000, .lifetime = .{ .ttl_ms = 2 } });
    try std.testing.expect(!center.expire(1_000 + std.time.ns_per_ms));
    try std.testing.expect(center.expire(1_000 + 2 * std.time.ns_per_ms));
    try std.testing.expectEqual(@as(usize, 0), center.records.count());
}
