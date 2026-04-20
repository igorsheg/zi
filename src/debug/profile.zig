const std = @import("std");

pub const Bucket = enum(u8) {
    publish_conversation_state,
    clone_conversation_view,
    reconcile_from_state,
    build_desired_items,
    markdown_parse,
    markdown_render_document,
    tui_render_frame,
    /// Sub-bucket: component tree walk — root.render + overlays render.
    /// Captures layout, per-component rendering (including markdown
    /// slice renders), cell writes into the `next` buffer.
    tui_render_tree,
    /// Sub-bucket: renderer.end() — cell-by-cell diff between current
    /// and next buffers, ANSI escape construction, and the actual
    /// blocking write to stdout. This is where terminal-emulator
    /// repaint cost shows up.
    tui_renderer_end,
};

pub const Stats = struct {
    name: []const u8,
    total_ns: u64,
    max_ns: u64,
    calls: u64,
    /// Number of calls that took >= half a 60Hz budget (>= 8.3ms).
    /// For frame buckets, this is the "starts to feel" zone.
    near_budget: u64,
    /// Number of calls that took >= a full 60Hz frame budget (>= 16.7ms).
    /// For frame buckets, this is a missed frame.
    over_budget: u64,

    pub fn avgNs(self: Stats) u64 {
        return if (self.calls == 0) 0 else self.total_ns / self.calls;
    }
};

pub const near_budget_ns: u64 = 8_300_000; // 8.3ms = half 60Hz
pub const over_budget_ns: u64 = 16_700_000; // 16.7ms = full 60Hz frame

const bucket_count = @typeInfo(Bucket).@"enum".fields.len;

const Counter = struct {
    total_ns: std.atomic.Value(u64) = .init(0),
    max_ns: std.atomic.Value(u64) = .init(0),
    calls: std.atomic.Value(u64) = .init(0),
    near_budget: std.atomic.Value(u64) = .init(0),
    over_budget: std.atomic.Value(u64) = .init(0),

    fn record(self: *Counter, ns: u64) void {
        _ = self.total_ns.fetchAdd(ns, .monotonic);
        _ = self.calls.fetchAdd(1, .monotonic);
        if (ns >= over_budget_ns) {
            _ = self.over_budget.fetchAdd(1, .monotonic);
        } else if (ns >= near_budget_ns) {
            _ = self.near_budget.fetchAdd(1, .monotonic);
        }
        var current = self.max_ns.load(.monotonic);
        while (ns > current) {
            const result = self.max_ns.cmpxchgWeak(current, ns, .monotonic, .monotonic);
            if (result == null) break;
            current = result.?;
        }
    }

    fn reset(self: *Counter) void {
        self.total_ns.store(0, .monotonic);
        self.max_ns.store(0, .monotonic);
        self.calls.store(0, .monotonic);
        self.near_budget.store(0, .monotonic);
        self.over_budget.store(0, .monotonic);
    }

    fn snapshot(self: *const Counter, name: []const u8) Stats {
        return .{
            .name = name,
            .total_ns = self.total_ns.load(.monotonic),
            .max_ns = self.max_ns.load(.monotonic),
            .calls = self.calls.load(.monotonic),
            .near_budget = self.near_budget.load(.monotonic),
            .over_budget = self.over_budget.load(.monotonic),
        };
    }
};

var enabled_flag: std.atomic.Value(bool) = .init(false);
var counters: [bucket_count]Counter = [_]Counter{.{}} ** bucket_count;

pub fn setEnabled(on: bool) void {
    enabled_flag.store(on, .monotonic);
}

pub fn isEnabled() bool {
    return enabled_flag.load(.monotonic);
}

pub fn initFromEnv() void {
    const value = std.posix.getenv("ZI_PROFILE") orelse return;
    if (value.len == 0) return;
    const on = !(std.mem.eql(u8, value, "0") or
        std.ascii.eqlIgnoreCase(value, "false") or
        std.ascii.eqlIgnoreCase(value, "off") or
        std.ascii.eqlIgnoreCase(value, "no"));
    setEnabled(on);
}

pub fn record(bucket: Bucket, ns: u64) void {
    counters[@intFromEnum(bucket)].record(ns);
}

pub fn reset() void {
    for (&counters) |*c| c.reset();
}

pub fn snapshot(bucket: Bucket) Stats {
    return counters[@intFromEnum(bucket)].snapshot(@tagName(bucket));
}

pub fn snapshotAll(out: *[bucket_count]Stats) void {
    inline for (@typeInfo(Bucket).@"enum".fields, 0..) |field, i| {
        out[i] = counters[i].snapshot(field.name);
    }
}

pub const ScopedTimer = struct {
    bucket: Bucket,
    start_ns: u64,
    active: bool,

    pub fn begin(bucket: Bucket) ScopedTimer {
        if (!isEnabled()) {
            return .{ .bucket = bucket, .start_ns = 0, .active = false };
        }
        return .{
            .bucket = bucket,
            .start_ns = readNowNs(),
            .active = true,
        };
    }

    pub fn end(self: *ScopedTimer) void {
        if (!self.active) return;
        const elapsed = readNowNs() -% self.start_ns;
        record(self.bucket, elapsed);
        self.active = false;
    }
};

fn readNowNs() u64 {
    return @intCast(std.time.nanoTimestamp());
}

pub fn writeDump(writer: *std.Io.Writer) !void {
    try writer.writeAll("zi profile snapshot\n");
    try writer.print("enabled: {s}\n", .{if (isEnabled()) "true" else "false"});
    try writer.writeAll("bucket                          calls          total_ms       avg_us         max_us\n");
    var stats_buf: [bucket_count]Stats = undefined;
    snapshotAll(&stats_buf);
    for (stats_buf) |s| {
        const total_ms: f64 = @as(f64, @floatFromInt(s.total_ns)) / 1_000_000.0;
        const avg_us: f64 = @as(f64, @floatFromInt(s.avgNs())) / 1_000.0;
        const max_us: f64 = @as(f64, @floatFromInt(s.max_ns)) / 1_000.0;
        try writer.print(
            "{s: <32}{d: <15}{d: <15.3}{d: <15.3}{d: <15.3}\n",
            .{ s.name, s.calls, total_ms, avg_us, max_us },
        );
    }
}

pub fn logDumpInfo() void {
    if (!isEnabled()) return;
    var stats_buf: [bucket_count]Stats = undefined;
    snapshotAll(&stats_buf);
    for (stats_buf) |s| {
        if (s.calls == 0) continue;
        const total_ms: f64 = @as(f64, @floatFromInt(s.total_ns)) / 1_000_000.0;
        const avg_us: f64 = @as(f64, @floatFromInt(s.avgNs())) / 1_000.0;
        const max_us: f64 = @as(f64, @floatFromInt(s.max_ns)) / 1_000.0;
        std.log.scoped(.profile).info(
            "{s} calls={d} total_ms={d:.3} avg_us={d:.3} max_us={d:.3} near_8ms={d} over_16ms={d}",
            .{ s.name, s.calls, total_ms, avg_us, max_us, s.near_budget, s.over_budget },
        );
    }
}

var periodic_tick: std.atomic.Value(u64) = .init(0);

/// Cheap no-op when disabled. When enabled, emits a rolling profile summary
/// every `stride` calls. Intended to be called once per frame from the TUI
/// run loop so rolling stats land in the log file even if shutdown is abrupt.
pub fn maybeEmitPeriodic(stride: u64) void {
    if (!isEnabled()) return;
    const n = periodic_tick.fetchAdd(1, .monotonic) + 1;
    if (stride == 0 or n % stride != 0) return;
    logDumpInfo();
}

test "disabled scoped timer records nothing" {
    setEnabled(false);
    reset();
    var t = ScopedTimer.begin(.reconcile_from_state);
    std.Thread.sleep(1_000);
    t.end();
    const s = snapshot(.reconcile_from_state);
    try std.testing.expectEqual(@as(u64, 0), s.calls);
}

test "enabled scoped timer records elapsed" {
    setEnabled(true);
    reset();
    defer {
        reset();
        setEnabled(false);
    }
    var t = ScopedTimer.begin(.reconcile_from_state);
    std.Thread.sleep(1_000_000); // 1ms
    t.end();
    const s = snapshot(.reconcile_from_state);
    try std.testing.expectEqual(@as(u64, 1), s.calls);
    try std.testing.expect(s.total_ns > 0);
    try std.testing.expect(s.max_ns > 0);
}

test "manual record accumulates" {
    setEnabled(true);
    reset();
    defer {
        reset();
        setEnabled(false);
    }
    record(.markdown_parse, 100);
    record(.markdown_parse, 300);
    const s = snapshot(.markdown_parse);
    try std.testing.expectEqual(@as(u64, 2), s.calls);
    try std.testing.expectEqual(@as(u64, 400), s.total_ns);
    try std.testing.expectEqual(@as(u64, 300), s.max_ns);
}
