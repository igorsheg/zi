const std = @import("std");

pub const Entry = struct {
    mu: std.Io.Mutex = .init,
    refcount: u32 = 0,

    key: []const u8 = "",
};

pub const Registry = struct {
    meta: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    locks: std.StringHashMapUnmanaged(*Entry) = .empty,

    pub fn acquireKey(self: *Registry, key: []const u8) !*Entry {
        self.meta.lockUncancelable(std.Options.debug_io);
        const entry = blk: {
            if (self.locks.get(key)) |existing| {
                existing.refcount += 1;
                break :blk existing;
            }
            const owned_key = try self.gpa.dupe(u8, key);
            errdefer self.gpa.free(owned_key);
            const new_entry = try self.gpa.create(Entry);
            errdefer self.gpa.destroy(new_entry);
            new_entry.* = .{ .refcount = 1, .key = owned_key };
            try self.locks.put(self.gpa, owned_key, new_entry);
            break :blk new_entry;
        };
        self.meta.unlock(std.Options.debug_io);

        entry.mu.lockUncancelable(std.Options.debug_io);
        return entry;
    }

    pub fn acquirePath(self: *Registry, tmp_alloc: std.mem.Allocator, path: []const u8) !*Entry {
        const canon = try canonicalizePath(tmp_alloc, path);
        defer tmp_alloc.free(canon);
        return self.acquireKey(canon);
    }

    pub fn release(self: *Registry, entry: *Entry) void {
        entry.mu.unlock(std.Options.debug_io);

        self.meta.lockUncancelable(std.Options.debug_io);
        defer self.meta.unlock(std.Options.debug_io);

        entry.refcount -= 1;
        if (entry.refcount == 0) {
            _ = self.locks.remove(entry.key);
            const key = entry.key;
            self.gpa.destroy(entry);
            self.gpa.free(key);
        }
    }

    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.locks.count() == 0);
        self.locks.deinit(self.gpa);
    }

    pub fn liveEntryCount(self: *Registry) usize {
        self.meta.lockUncancelable(std.Options.debug_io);
        defer self.meta.unlock(std.Options.debug_io);
        return self.locks.count();
    }
};

pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.Io.Dir.realPathFileAbsoluteAlloc(std.Options.debug_io, path, allocator)) |real_z| {
        defer allocator.free(real_z);
        return allocator.dupe(u8, real_z);
    } else |_| {
        return std.fs.path.resolve(allocator, &.{path});
    }
}

var g_registry: Registry = .{ .gpa = std.heap.page_allocator };

pub fn global() *Registry {
    return &g_registry;
}

fn initTestRegistry() Registry {
    return .{ .gpa = std.testing.allocator };
}

fn expectRegistryDrained(reg: *Registry) !void {
    try std.testing.expectEqual(@as(usize, 0), reg.liveEntryCount());
}

test "canonicalizePath resolves missing paths to absolute stable keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const canon = try canonicalizePath(alloc, "/definitely/not/a/real/path/xyz123");
    defer alloc.free(canon);

    try testing.expect(std.fs.path.isAbsolute(canon));
    try testing.expect(std.mem.endsWith(u8, canon, "xyz123"));
}

test "acquireKey removes entries after each release so future acquires are fresh" {
    var reg = initTestRegistry();
    defer reg.deinit();

    const first = try reg.acquireKey("foo");
    reg.release(first);
    try expectRegistryDrained(&reg);

    const second = try reg.acquireKey("foo");
    reg.release(second);
    try expectRegistryDrained(&reg);
}

test "acquireKey permits only one holder per key across threads" {
    var reg = initTestRegistry();
    defer reg.deinit();

    var in_critical: std.atomic.Value(i32) = .init(0);
    var max_seen: std.atomic.Value(i32) = .init(0);

    const Worker = struct {
        fn run(r: *Registry, ic: *std.atomic.Value(i32), ms: *std.atomic.Value(i32)) void {
            for (0..50) |_| {
                const e = r.acquireKey("shared") catch return;
                const cur = ic.fetchAdd(1, .acq_rel) + 1;
                var prev = ms.load(.acquire);
                while (cur > prev) {
                    if (ms.cmpxchgWeak(prev, cur, .acq_rel, .acquire)) |new_prev| {
                        prev = new_prev;
                    } else break;
                }
                std.Options.debug_io.sleep(.fromNanoseconds(@intCast(10_000)), .awake) catch {};
                _ = ic.fetchSub(1, .acq_rel);
                r.release(e);
            }
        }
    };

    const t1 = try std.Thread.spawn(.{}, Worker.run, .{ &reg, &in_critical, &max_seen });
    const t2 = try std.Thread.spawn(.{}, Worker.run, .{ &reg, &in_critical, &max_seen });
    const t3 = try std.Thread.spawn(.{}, Worker.run, .{ &reg, &in_critical, &max_seen });
    t1.join();
    t2.join();
    t3.join();

    try std.testing.expectEqual(@as(i32, 1), max_seen.load(.acquire));
    try expectRegistryDrained(&reg);
}

test "acquireKey permits distinct keys to be held at the same time" {
    var reg = initTestRegistry();
    defer reg.deinit();

    const a = try reg.acquireKey("key-a");
    const b = try reg.acquireKey("key-b");
    reg.release(b);
    reg.release(a);
    try expectRegistryDrained(&reg);
}

test "acquirePath canonicalizes lexical aliases before locking" {
    const testing = std.testing;
    const alloc = testing.allocator;
    var reg: Registry = .{ .gpa = alloc };
    defer reg.deinit();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const root = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", alloc);
    defer alloc.free(root);

    const path_a = try std.fs.path.join(alloc, &.{ root, "new.txt" });
    defer alloc.free(path_a);
    const path_b = try std.fs.path.join(alloc, &.{ root, "subdir", "..", "new.txt" });
    defer alloc.free(path_b);

    const held = try reg.acquirePath(alloc, path_a);
    var acquired: std.atomic.Value(bool) = .init(false);

    const Worker = struct {
        fn run(r: *Registry, allocator: std.mem.Allocator, path: []const u8, flag: *std.atomic.Value(bool)) void {
            const e = r.acquirePath(allocator, path) catch return;
            flag.store(true, .release);
            r.release(e);
        }
    };

    const t = try std.Thread.spawn(.{}, Worker.run, .{ &reg, alloc, path_b, &acquired });
    std.Options.debug_io.sleep(.fromMilliseconds(10), .awake) catch {};
    try testing.expect(!acquired.load(.acquire));

    reg.release(held);
    t.join();

    try testing.expect(acquired.load(.acquire));
    try expectRegistryDrained(&reg);
}
