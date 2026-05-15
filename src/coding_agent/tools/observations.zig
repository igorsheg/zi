const std = @import("std");
const zio_fs = @import("../../zio/root.zig").file;

pub const HASH_HEX_LEN: usize = 64;
pub const MAX_OBSERVATIONS: usize = 2048;

pub const Source = enum { read, grep, edit, write, patch, compaction_restore };

pub const Observation = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i96,
    hash: [32]u8,
    source: Source,
    generation: u64,

    pub fn deinit(self: *Observation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const Event = struct {
    path: []const u8,
    size: u64,
    mtime_ns: i96,
    hash: [32]u8,
    source: Source,

    pub fn deinit(self: *Event, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

pub const PendingEvents = struct {
    mu: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    events: std.ArrayListUnmanaged(Event) = .empty,

    pub fn init(allocator: std.mem.Allocator) PendingEvents {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PendingEvents, _: std.mem.Allocator) void {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        for (self.events.items) |*event| event.deinit(self.allocator);
        self.events.deinit(self.allocator);
        self.events = .empty;
    }

    pub fn recordBytes(self: *PendingEvents, _: std.mem.Allocator, path: []const u8, stat: std.Io.File.Stat, bytes: []const u8, source: Source) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        const owned_path = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned_path);
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        try self.events.append(self.allocator, .{ .path = owned_path, .size = stat.size, .mtime_ns = stat.mtime.nanoseconds, .hash = digest, .source = source });
    }

    pub fn recordFile(self: *PendingEvents, allocator: std.mem.Allocator, path: []const u8, source: Source) !void {
        const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
        var input = try zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 16 * 1024 * 1024 });
        defer input.deinit(allocator);
        try self.recordBytes(allocator, path, stat, input.bytes(), source);
    }

    pub fn drainApply(self: *PendingEvents, store: *Store) !void {
        self.mu.lockUncancelable(std.Options.debug_io);
        var drained = self.events;
        self.events = .empty;
        self.mu.unlock(std.Options.debug_io);
        defer {
            for (drained.items) |*event| event.deinit(self.allocator);
            drained.deinit(self.allocator);
        }
        for (drained.items) |event| try store.applyEvent(event);
    }
};

const Snapshot = struct {
    size: u64,
    mtime_ns: i96,
    hash: [32]u8,
    source: Source,
    generation: u64,
};

pub const Store = struct {
    mu: std.Io.Mutex = .init,
    allocator: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Observation) = .empty,
    next_generation: u64 = 1,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Store, _: std.mem.Allocator) void {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        var it = self.map.iterator();
        while (it.next()) |e| e.value_ptr.deinit(self.allocator);
        self.map.deinit(self.allocator);
        self.map = .empty;
    }

    pub fn recordBytes(self: *Store, _: std.mem.Allocator, path: []const u8, stat: std.Io.File.Stat, bytes: []const u8, source: Source) !void {
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(bytes, &digest, .{});
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        try self.recordHashLocked(path, stat.size, stat.mtime.nanoseconds, digest, source);
    }

    pub fn applyEvent(self: *Store, event: Event) !void {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        try self.recordHashLocked(event.path, event.size, event.mtime_ns, event.hash, event.source);
    }

    pub fn recordFile(self: *Store, allocator: std.mem.Allocator, path: []const u8, source: Source) !void {
        const stat = try std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{});
        var input = try zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 16 * 1024 * 1024 });
        defer input.deinit(allocator);
        try self.recordBytes(allocator, path, stat, input.bytes(), source);
    }

    pub fn validateFile(self: *Store, allocator: std.mem.Allocator, path: []const u8) !Validation {
        const snap = self.snapshot(path) orelse return .missing_observation;

        const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path, .{}) catch return .path_not_comparable;
        var input = zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 16 * 1024 * 1024 }) catch return .path_not_comparable;
        defer input.deinit(allocator);
        var digest: [32]u8 = undefined;
        std.crypto.hash.Blake3.hash(input.bytes(), &digest, .{});

        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        const current = self.map.get(path) orelse return .missing_observation;
        if (current.generation != snap.generation or !std.mem.eql(u8, &current.hash, &snap.hash)) return .content_changed;
        if (!std.mem.eql(u8, &digest, &snap.hash)) return .content_changed;
        if (snap.size != stat.size or snap.mtime_ns != stat.mtime.nanoseconds) {
            try self.recordHashLocked(path, stat.size, stat.mtime.nanoseconds, digest, snap.source);
            return .refreshed_metadata;
        }
        return .ok;
    }

    pub fn getHash(self: *Store, path: []const u8) ?[32]u8 {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        const obs = self.map.get(path) orelse return null;
        return obs.hash;
    }

    pub fn appendJsonArray(self: *Store, allocator: std.mem.Allocator, arr: *std.json.Array) !void {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        var it = self.map.iterator();
        while (it.next()) |e| {
            const obs = e.value_ptr.*;
            var obj: std.json.ObjectMap = .{};
            errdefer obj.deinit(allocator);
            try obj.put(allocator, try allocator.dupe(u8, "path"), .{ .string = try allocator.dupe(u8, obs.path) });
            try obj.put(allocator, try allocator.dupe(u8, "size"), .{ .integer = @intCast(obs.size) });
            try obj.put(allocator, try allocator.dupe(u8, "mtime_ns"), .{ .integer = @intCast(obs.mtime_ns) });
            try obj.put(allocator, try allocator.dupe(u8, "hash"), .{ .string = try hashHex(allocator, obs.hash) });
            try obj.put(allocator, try allocator.dupe(u8, "line_hash_scheme"), .{ .string = try allocator.dupe(u8, "zi-line-v1") });
            try obj.put(allocator, try allocator.dupe(u8, "observed_by"), .{ .string = try allocator.dupe(u8, @tagName(obs.source)) });
            try arr.append(.{ .object = obj });
            obj = .{};
        }
    }

    pub fn restoreJsonArray(self: *Store, allocator: std.mem.Allocator, value: std.json.Value) !void {
        if (value != .array) return;
        for (value.array.items) |item| {
            if (item != .object) continue;
            const path_v = item.object.get("path") orelse continue;
            const hash_v = item.object.get("hash") orelse continue;
            if (path_v != .string or hash_v != .string) continue;
            const expected = parseHashHex(hash_v.string) catch continue;
            const stat = std.Io.Dir.cwd().statFile(std.Options.debug_io, path_v.string, .{}) catch continue;
            var input = zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path_v.string, .{ .max_bytes = 16 * 1024 * 1024 }) catch continue;
            defer input.deinit(allocator);
            var actual: [32]u8 = undefined;
            std.crypto.hash.Blake3.hash(input.bytes(), &actual, .{});
            if (!std.mem.eql(u8, &expected, &actual)) continue;
            self.mu.lockUncancelable(std.Options.debug_io);
            defer self.mu.unlock(std.Options.debug_io);
            try self.recordHashLocked(path_v.string, stat.size, stat.mtime.nanoseconds, actual, .compaction_restore);
        }
    }

    fn snapshot(self: *Store, path: []const u8) ?Snapshot {
        self.mu.lockUncancelable(std.Options.debug_io);
        defer self.mu.unlock(std.Options.debug_io);
        const obs = self.map.get(path) orelse return null;
        return .{ .size = obs.size, .mtime_ns = obs.mtime_ns, .hash = obs.hash, .source = obs.source, .generation = obs.generation };
    }

    fn recordHashLocked(self: *Store, path: []const u8, size: u64, mtime_ns: i96, digest: [32]u8, source: Source) !void {
        if (self.map.count() >= MAX_OBSERVATIONS and !self.map.contains(path)) {
            var it = self.map.iterator();
            if (it.next()) |e| {
                var old = e.value_ptr.*;
                _ = self.map.remove(e.key_ptr.*);
                old.deinit(self.allocator);
            }
        }
        if (self.map.fetchRemove(path)) |kv| {
            var old = kv.value;
            old.deinit(self.allocator);
        }
        const owned = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(owned);
        const generation = self.next_generation;
        self.next_generation +%= 1;
        try self.map.put(self.allocator, owned, .{ .path = owned, .size = size, .mtime_ns = mtime_ns, .hash = digest, .source = source, .generation = generation });
    }
};

pub const Validation = enum { ok, refreshed_metadata, missing_observation, path_not_comparable, content_changed };

pub fn hashHex(allocator: std.mem.Allocator, hash: [32]u8) ![]u8 {
    const out = try allocator.alloc(u8, HASH_HEX_LEN);
    const alphabet = "0123456789abcdef";
    for (hash, 0..) |b, i| {
        out[i * 2] = alphabet[b >> 4];
        out[i * 2 + 1] = alphabet[b & 0x0f];
    }
    return out;
}

pub fn validationMessage(v: Validation, op: []const u8, path: []const u8) []const u8 {
    _ = path;
    return switch (v) {
        .ok, .refreshed_metadata => "",
        .missing_observation => if (std.mem.eql(u8, op, "write")) "write rejected: refusing to overwrite an existing file that has not been observed" else "edit rejected: file has not been observed in this session. read or grep the file before editing",
        .path_not_comparable => "mutation rejected: file cannot be compared to observed version",
        .content_changed => "mutation rejected: file changed since zi observed it. read the file again before editing",
    };
}

fn parseHashHex(s: []const u8) ![32]u8 {
    if (s.len != 64) return error.InvalidHash;
    var out: [32]u8 = undefined;
    for (&out, 0..) |*b, i| {
        b.* = (try hexNibble(s[i * 2]) << 4) | try hexNibble(s[i * 2 + 1]);
    }
    return out;
}

fn hexNibble(c: u8) !u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => error.InvalidHash,
    };
}
