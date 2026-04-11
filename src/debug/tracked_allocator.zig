const std = @import("std");
const storage = @import("../storage.zig");

pub const Snapshot = struct {
    name: []const u8,
    live_bytes: usize,
    peak_bytes: usize,
    active_allocations: usize,
    alloc_calls: u64,
    resize_calls: u64,
    remap_calls: u64,
    free_calls: u64,
    tracking_failures: u64,
    untracked_frees: u64,
};

pub const TrackedAllocator = struct {
    name: []const u8,
    child_allocator: std.mem.Allocator,
    metadata_allocator: std.mem.Allocator,
    allocations: std.AutoHashMap(usize, usize),
    live_bytes: usize = 0,
    peak_bytes: usize = 0,
    alloc_calls: u64 = 0,
    resize_calls: u64 = 0,
    remap_calls: u64 = 0,
    free_calls: u64 = 0,
    tracking_failures: u64 = 0,
    untracked_frees: u64 = 0,
    mutex: std.Thread.Mutex = .{},

    pub fn init(name: []const u8, child_allocator: std.mem.Allocator, metadata_allocator: std.mem.Allocator) TrackedAllocator {
        return .{
            .name = name,
            .child_allocator = child_allocator,
            .metadata_allocator = metadata_allocator,
            .allocations = std.AutoHashMap(usize, usize).init(metadata_allocator),
        };
    }

    pub fn deinit(self: *TrackedAllocator) void {
        self.allocations.deinit();
    }

    pub fn allocator(self: *TrackedAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    pub fn snapshot(self: *TrackedAllocator) Snapshot {
        self.mutex.lock();
        defer self.mutex.unlock();

        return .{
            .name = self.name,
            .live_bytes = self.live_bytes,
            .peak_bytes = self.peak_bytes,
            .active_allocations = self.allocations.count(),
            .alloc_calls = self.alloc_calls,
            .resize_calls = self.resize_calls,
            .remap_calls = self.remap_calls,
            .free_calls = self.free_calls,
            .tracking_failures = self.tracking_failures,
            .untracked_frees = self.untracked_frees,
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        const memory = self.child_allocator.rawAlloc(len, alignment, ret_addr) orelse return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.alloc_calls += 1;
        self.allocations.put(@intFromPtr(memory), len) catch {
            self.tracking_failures += 1;
            return memory;
        };
        self.live_bytes += len;
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return memory;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child_allocator.rawResize(memory, alignment, new_len, ret_addr)) return false;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.resize_calls += 1;
        const key = @intFromPtr(memory.ptr);
        const old_len = self.allocations.get(key) orelse return true;
        self.allocations.put(key, new_len) catch {
            self.tracking_failures += 1;
            return true;
        };

        if (new_len >= old_len) {
            self.live_bytes += new_len - old_len;
        } else {
            self.live_bytes -= old_len - new_len;
        }
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));
        const new_memory = self.child_allocator.vtable.remap(self.child_allocator.ptr, memory, alignment, new_len, ret_addr) orelse return null;

        self.mutex.lock();
        defer self.mutex.unlock();

        self.remap_calls += 1;
        const old_key = @intFromPtr(memory.ptr);
        const old_len = self.allocations.get(old_key) orelse return new_memory;
        const new_key = @intFromPtr(new_memory);

        if (new_key != old_key) {
            _ = self.allocations.remove(old_key);
            self.allocations.put(new_key, new_len) catch {
                self.tracking_failures += 1;
                return new_memory;
            };
        } else {
            self.allocations.put(old_key, new_len) catch {
                self.tracking_failures += 1;
                return new_memory;
            };
        }

        if (new_len >= old_len) {
            self.live_bytes += new_len - old_len;
        } else {
            self.live_bytes -= old_len - new_len;
        }
        self.peak_bytes = @max(self.peak_bytes, self.live_bytes);
        return new_memory;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *TrackedAllocator = @ptrCast(@alignCast(ctx));

        self.mutex.lock();
        defer self.mutex.unlock();

        self.free_calls += 1;
        if (self.allocations.fetchRemove(@intFromPtr(memory.ptr))) |entry| {
            self.live_bytes -= entry.value;
        } else {
            self.untracked_frees += 1;
        }
        self.child_allocator.rawFree(memory, alignment, ret_addr);
    }
};

pub const Diagnostics = struct {
    root: *TrackedAllocator,
    agent: *TrackedAllocator,
    tui: *TrackedAllocator,
    msg: *TrackedAllocator,

    pub fn writeSnapshotFile(
        self: *const Diagnostics,
        allocator: std.mem.Allocator,
        cwd: []const u8,
        agent_dir_override: ?[]const u8,
    ) ![]const u8 {
        const dir = try storage.getMemoryDiagnosticsDir(allocator, agent_dir_override);
        errdefer allocator.free(dir);
        try std.fs.cwd().makePath(dir);

        const file_name = try std.fmt.allocPrint(allocator, "memory-{d}.txt", .{std.time.milliTimestamp()});
        defer allocator.free(file_name);
        const path = try std.fs.path.join(allocator, &.{ dir, file_name });
        errdefer allocator.free(path);

        const file = try std.fs.createFileAbsolute(path, .{});
        defer file.close();

        var buf: [4096]u8 = undefined;
        var fw = file.writer(&buf);
        try self.writeReport(cwd, &fw.interface);
        try fw.end();
        return path;
    }

    pub fn writeReport(self: *const Diagnostics, cwd: []const u8, writer: *std.Io.Writer) !void {
        const root = self.root.snapshot();
        const agent = self.agent.snapshot();
        const tui = self.tui.snapshot();
        const msg = self.msg.snapshot();

        try writer.writeAll("zi memory diagnostics\n");
        try writer.print("generated_at_unix_ms: {d}\n", .{std.time.milliTimestamp()});
        try writer.print("cwd: {s}\n\n", .{cwd});
        try writer.writeAll("notes:\n");
        try writer.writeAll("- root includes allocations made by the child trackers below\n");
        try writer.writeAll("- agent and tui track backing allocations, so retained arena capacity stays live here\n\n");

        try writeSnapshot(writer, root);
        try writer.writeByte('\n');
        try writeSnapshot(writer, agent);
        try writer.writeByte('\n');
        try writeSnapshot(writer, tui);
        try writer.writeByte('\n');
        try writeSnapshot(writer, msg);
    }
};

fn writeSnapshot(writer: *std.Io.Writer, snapshot: Snapshot) !void {
    var live_buf: [32]u8 = undefined;
    var peak_buf: [32]u8 = undefined;
    try writer.print("tracker: {s}\n", .{snapshot.name});
    try writer.print("  live_bytes: {d} ({s})\n", .{ snapshot.live_bytes, formatBytes(&live_buf, snapshot.live_bytes) });
    try writer.print("  peak_bytes: {d} ({s})\n", .{ snapshot.peak_bytes, formatBytes(&peak_buf, snapshot.peak_bytes) });
    try writer.print("  active_allocations: {d}\n", .{snapshot.active_allocations});
    try writer.print("  alloc_calls: {d}\n", .{snapshot.alloc_calls});
    try writer.print("  resize_calls: {d}\n", .{snapshot.resize_calls});
    try writer.print("  remap_calls: {d}\n", .{snapshot.remap_calls});
    try writer.print("  free_calls: {d}\n", .{snapshot.free_calls});
    try writer.print("  tracking_failures: {d}\n", .{snapshot.tracking_failures});
    try writer.print("  untracked_frees: {d}\n", .{snapshot.untracked_frees});
}

fn formatBytes(buf: *[32]u8, bytes: usize) []const u8 {
    const units = [_][]const u8{ "B", "KiB", "MiB", "GiB", "TiB" };
    var value = @as(f64, @floatFromInt(bytes));
    var unit_index: usize = 0;
    while (value >= 1024.0 and unit_index + 1 < units.len) : (unit_index += 1) {
        value /= 1024.0;
    }
    return std.fmt.bufPrint(buf, "{d:.2} {s}", .{ value, units[unit_index] }) catch "<format error>";
}

test "tracked allocator updates live and peak bytes" {
    var tracker = TrackedAllocator.init("test", std.testing.allocator, std.testing.allocator);
    defer tracker.deinit();
    const alloc = tracker.allocator();

    const a = try alloc.alloc(u8, 128);
    const b = try alloc.alloc(u8, 64);
    var snapshot = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 192), snapshot.live_bytes);
    try std.testing.expectEqual(@as(usize, 192), snapshot.peak_bytes);
    try std.testing.expectEqual(@as(usize, 2), snapshot.active_allocations);

    alloc.free(a);
    snapshot = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 64), snapshot.live_bytes);
    try std.testing.expectEqual(@as(usize, 192), snapshot.peak_bytes);

    alloc.free(b);
    snapshot = tracker.snapshot();
    try std.testing.expectEqual(@as(usize, 0), snapshot.live_bytes);
    try std.testing.expectEqual(@as(usize, 192), snapshot.peak_bytes);
}
