//! Process-global keyed mutex registry for serializing concurrent
//! access to shared resources (primarily file paths).
//!
//! Mirrors `~/.pi/agent/extensions/tools/lib/mutex.ts` from the user's
//! custom pi config: a module-level `Map<key, Mutex>` keyed by the
//! canonicalized form of a path so that two relative paths pointing at
//! the same file share one lock.
//!
//! # Thread safety contract
//!
//! - `meta` guards the key→entry map and entry refcount mutations.
//! - Each `Entry` owns its own `mu` for the actual mutual exclusion.
//!
//! RULE: NEVER hold `meta` while blocking on `entry.mu`. Doing so
//! would let one thread's acquire serialize behind another thread's
//! long-running critical section on an unrelated key.
//!
//! Lock order:
//!   acquire: meta.lock → map lookup/insert → refcount++ → meta.unlock → entry.mu.lock
//!   release: entry.mu.unlock → meta.lock → refcount-- → maybe free → meta.unlock
//!
//! # Canonicalization
//!
//! `canonicalizePath` tries `std.fs.realpath`, falling back to
//! `std.fs.path.resolve` when the path does not exist yet (the
//! create-file case). This matches the ts override's fallback from
//! `realpathSync.native` to `path.resolve`.
//!
//! # Usage
//!
//! ```zig
//! const lr = @import("lock_registry.zig");
//! const entry = try lr.global().acquirePath(tmp_alloc, "/abs/path");
//! defer lr.global().release(entry);
//! // ... exclusive file work ...
//! ```
//!
//! For synthetic keys (e.g. bash's per-repo git lock) use `acquireKey`
//! directly — the caller is responsible for canonicalizing the base
//! path component if cross-alias serialization matters.

const std = @import("std");

pub const Entry = struct {
    mu: std.Io.Mutex = .init,
    refcount: u32 = 0,
    /// Owned by the registry's allocator; used by `release` to
    /// remove the map entry when refcount hits zero.
    key: []const u8 = "",
};

pub const Registry = struct {
    meta: std.Io.Mutex = .init,
    gpa: std.mem.Allocator,
    locks: std.StringHashMapUnmanaged(*Entry) = .empty,

    /// Acquire an exclusive lock on `key`. Blocks until available.
    /// Caller must pair with `release(entry)`.
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

    /// Canonicalize `path` and acquire a lock on the result. `tmp_alloc`
    /// is used for the canonicalization scratch space only; the key
    /// stored in the registry is owned by the registry's own allocator.
    pub fn acquirePath(self: *Registry, tmp_alloc: std.mem.Allocator, path: []const u8) !*Entry {
        const canon = try canonicalizePath(tmp_alloc, path);
        defer tmp_alloc.free(canon);
        return self.acquireKey(canon);
    }

    /// Release a previously-acquired entry. Decrements refcount and
    /// frees the entry when no other holders remain.
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

    /// Release the hashmap backing storage. Only meaningful for
    /// test-scoped registries — the process-global singleton is
    /// never deinit'd. Asserts no outstanding locks.
    pub fn deinit(self: *Registry) void {
        std.debug.assert(self.locks.count() == 0);
        self.locks.deinit(self.gpa);
    }

    /// Test-only: current number of tracked entries.
    pub fn liveEntryCount(self: *Registry) usize {
        self.meta.lockUncancelable(std.Options.debug_io);
        defer self.meta.unlock(std.Options.debug_io);
        return self.locks.count();
    }
};

/// Canonicalize a path for use as a lock key. Uses `std.fs.realpath`
/// when the path exists, falling back to `std.fs.path.resolve` when
/// it doesn't (e.g. create-file on a not-yet-existing target).
///
/// Caller owns the returned slice.
pub fn canonicalizePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (std.Io.Dir.realPathFileAbsoluteAlloc(std.Options.debug_io, path, allocator)) |real_z| {
        defer allocator.free(real_z);
        return allocator.dupe(u8, real_z);
    } else |_| {
        return std.fs.path.resolve(allocator, &.{path});
    }
}

// Process-lifetime singleton backing store; this registry is intentionally
// immortal and matches the module-level map shape in pi-mono.
var g_registry: Registry = .{ .gpa = std.heap.page_allocator };

/// Process-global registry. Never deinit'd; lives for the process
/// lifetime. Matches the module-level `Map` in the ts override.
pub fn global() *Registry {
    return &g_registry;
}

test "canonicalizePath resolves missing paths to absolute stable keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    const canon = try canonicalizePath(alloc, "/definitely/not/a/real/path/xyz123");
    defer alloc.free(canon);

    try testing.expect(std.fs.path.isAbsolute(canon));
    try testing.expect(std.mem.endsWith(u8, canon, "xyz123"));
}

test "acquireKey release removes stale entries and permits reacquire" {
    const testing = std.testing;
    var reg: Registry = .{ .gpa = testing.allocator };
    defer reg.deinit();

    const first = try reg.acquireKey("foo");
    reg.release(first);
    try testing.expectEqual(@as(usize, 0), reg.liveEntryCount());

    const second = try reg.acquireKey("foo");
    reg.release(second);
    try testing.expectEqual(@as(usize, 0), reg.liveEntryCount());
}

test "acquireKey serializes duplicate keys across threads" {
    const testing = std.testing;
    var reg: Registry = .{ .gpa = testing.allocator };
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

    try testing.expectEqual(@as(i32, 1), max_seen.load(.acquire));
    try testing.expectEqual(@as(usize, 0), reg.liveEntryCount());
}

test "acquireKey permits distinct keys to be held simultaneously" {
    const testing = std.testing;
    var reg: Registry = .{ .gpa = testing.allocator };
    defer reg.deinit();

    const a = try reg.acquireKey("key-a");
    const b = try reg.acquireKey("key-b");
    reg.release(b);
    reg.release(a);
    try testing.expectEqual(@as(usize, 0), reg.liveEntryCount());
}

test "acquirePath serializes lexical aliases of the same missing file" {
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
    try testing.expectEqual(@as(usize, 0), reg.liveEntryCount());
}
