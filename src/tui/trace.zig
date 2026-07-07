const std = @import("std");

pub const timing_sample_capacity = 256;

pub const TimingStats = struct {
    count: usize = 0,
    total_ns: u128 = 0,
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    samples: [timing_sample_capacity]u64 = undefined,
    sample_start: usize = 0,
    sample_count: usize = 0,

    pub fn record(self: *TimingStats, ns: u64) void {
        self.count += 1;
        self.total_ns += ns;
        self.min_ns = @min(self.min_ns, ns);
        self.max_ns = @max(self.max_ns, ns);
        if (self.sample_count < timing_sample_capacity) {
            self.samples[(self.sample_start + self.sample_count) % timing_sample_capacity] = ns;
            self.sample_count += 1;
        } else {
            self.samples[self.sample_start] = ns;
            self.sample_start = (self.sample_start + 1) % timing_sample_capacity;
        }
    }

    pub fn averageNs(self: *const TimingStats) u64 {
        if (self.count == 0) return 0;
        return @intCast(self.total_ns / self.count);
    }

    pub fn observedMinNs(self: *const TimingStats) u64 {
        return if (self.count == 0) 0 else self.min_ns;
    }

    pub fn percentileNs(self: *const TimingStats, percentile: u8) u64 {
        if (self.sample_count == 0) return 0;
        var sorted: [timing_sample_capacity]u64 = undefined;
        for (0..self.sample_count) |index| {
            sorted[index] = self.samples[(self.sample_start + index) % timing_sample_capacity];
        }
        insertionSort(sorted[0..self.sample_count]);
        const clamped: usize = @min(percentile, 100);
        const rank = @max(@as(usize, 1), (self.sample_count * clamped + 99) / 100);
        return sorted[rank - 1];
    }
};

fn insertionSort(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var insert_at = index;
        while (insert_at > 0 and values[insert_at - 1] > value) : (insert_at -= 1) {
            values[insert_at] = values[insert_at - 1];
        }
        values[insert_at] = value;
    }
}

pub const frame_record_capacity = 512;
pub const input_latency_bucket_count = 12;

pub const FrameRecord = struct {
    wake_ns: u64 = 0,
    input_bytes: usize = 0,
    events_applied: usize = 0,
    apply_us: u64 = 0,
    layout_us: u64 = 0,
    paint_us: u64 = 0,
    flush_us: u64 = 0,
    flush_bytes: usize = 0,

    pub fn totalUs(self: FrameRecord) u64 {
        return self.apply_us +| self.layout_us +| self.paint_us +| self.flush_us;
    }
};

pub const FrameRecords = struct {
    records: [frame_record_capacity]FrameRecord = undefined,
    start: usize = 0,
    count: usize = 0,
    evictions: usize = 0,

    pub fn append(self: *FrameRecords, record: FrameRecord) void {
        if (self.count < frame_record_capacity) {
            self.records[(self.start + self.count) % frame_record_capacity] = record;
            self.count += 1;
        } else {
            self.records[self.start] = record;
            self.start = (self.start + 1) % frame_record_capacity;
            self.evictions += 1;
        }
    }

    pub fn newest(self: *const FrameRecords) ?FrameRecord {
        if (self.count == 0) return null;
        return self.records[(self.start + self.count - 1) % frame_record_capacity];
    }
};

pub const InputLatencyHistogram = struct {
    buckets: [input_latency_bucket_count]usize = .{0} ** input_latency_bucket_count,

    pub fn recordLatencyNs(self: *InputLatencyHistogram, ns: u64) void {
        self.buckets[bucketIndex(ns)] += 1;
    }

    fn bucketIndex(ns: u64) usize {
        const one_ms = std.time.ns_per_ms;
        if (ns <= one_ms) return 0;
        var upper_ns: u64 = 2 * one_ms;
        var index: usize = 1;
        while (index < input_latency_bucket_count - 1) : (index += 1) {
            if (ns <= upper_ns) return index;
            upper_ns *|= 2;
        }
        return input_latency_bucket_count - 1;
    }
};

pub const Stats = struct {
    iterations: TimingStats = .{},
    renders: TimingStats = .{},
    rebuilds: TimingStats = .{},
    frames: FrameRecords = .{},
    input_latency: InputLatencyHistogram = .{},
    input_latency_timing: TimingStats = .{},
    input_actions: usize = 0,
    dropped_input_bytes: usize = 0,

    pub fn recordIteration(self: *Stats, ns: u64) void {
        self.iterations.record(ns);
    }

    pub fn recordRender(self: *Stats, ns: u64) void {
        self.renders.record(ns);
    }

    pub fn recordFrame(self: *Stats, record: FrameRecord) void {
        self.frames.append(record);
    }

    pub fn recordInputLatency(self: *Stats, read_ns: u64, flush_complete_ns: u64) void {
        const latency_ns = flush_complete_ns -| read_ns;
        self.input_latency.recordLatencyNs(latency_ns);
        self.input_latency_timing.record(latency_ns);
    }

    pub fn recordRebuild(self: *Stats, ns: u64) void {
        self.rebuilds.record(ns);
    }

    pub fn recordInputAction(self: *Stats) void {
        self.input_actions += 1;
    }

    pub fn addDroppedInputBytes(self: *Stats, count: usize) void {
        self.dropped_input_bytes += count;
    }

    pub fn writeReport(self: *const Stats, writer: *std.Io.Writer) !void {
        try writer.print(
            "zi tui trace\n" ++
                "iterations count={d} avg_ns={d} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d}\n" ++
                "renders count={d} avg_ns={d} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d}\n" ++
                "frames count={d} evictions={d} max_total_us={d}\n" ++
                "rebuilds count={d} avg_ns={d} max_ns={d}\n" ++
                "input_actions count={d}\n" ++
                "dropped_input_bytes count={d}\n" ++
                "input_latency count={d} p50_ns={d} p90_ns={d} p99_ns={d} max_ns={d}\n" ++
                "input_latency buckets_1ms_to_1024ms_plus=",
            .{
                self.iterations.count,
                self.iterations.averageNs(),
                self.iterations.percentileNs(50),
                self.iterations.percentileNs(90),
                self.iterations.percentileNs(99),
                self.iterations.max_ns,
                self.renders.count,
                self.renders.averageNs(),
                self.renders.percentileNs(50),
                self.renders.percentileNs(90),
                self.renders.percentileNs(99),
                self.renders.max_ns,
                self.frames.count,
                self.frames.evictions,
                self.maxFrameTotalUs(),
                self.rebuilds.count,
                self.rebuilds.averageNs(),
                self.rebuilds.max_ns,
                self.input_actions,
                self.dropped_input_bytes,
                self.input_latency_timing.count,
                self.input_latency_timing.percentileNs(50),
                self.input_latency_timing.percentileNs(90),
                self.input_latency_timing.percentileNs(99),
                self.input_latency_timing.max_ns,
            },
        );
        for (self.input_latency.buckets, 0..) |count, index| {
            if (index != 0) try writer.writeAll(",");
            try writer.print("{d}", .{count});
        }
        try writer.writeAll("\n");
    }

    fn maxFrameTotalUs(self: *const Stats) u64 {
        var max_us: u64 = 0;
        for (0..self.frames.count) |offset| {
            max_us = @max(max_us, self.frames.records[(self.frames.start + offset) % frame_record_capacity].totalUs());
        }
        return max_us;
    }
};

test "timing stats track min max and average" {
    var stats: TimingStats = .{};
    try std.testing.expectEqual(@as(u64, 0), stats.observedMinNs());
    try std.testing.expectEqual(@as(u64, 0), stats.averageNs());

    stats.record(10);
    stats.record(30);
    try std.testing.expectEqual(@as(usize, 2), stats.count);
    try std.testing.expectEqual(@as(u64, 10), stats.observedMinNs());
    try std.testing.expectEqual(@as(u64, 30), stats.max_ns);
    try std.testing.expectEqual(@as(u64, 20), stats.averageNs());
}

test "timing stats keep bounded samples and compute percentiles" {
    var stats: TimingStats = .{};
    for (1..101) |value| stats.record(value);

    try std.testing.expectEqual(@as(u64, 50), stats.percentileNs(50));
    try std.testing.expectEqual(@as(u64, 90), stats.percentileNs(90));
    try std.testing.expectEqual(@as(u64, 99), stats.percentileNs(99));

    for (101..(timing_sample_capacity + 102)) |value| stats.record(value);
    try std.testing.expectEqual(@as(usize, timing_sample_capacity), stats.sample_count);
    try std.testing.expectEqual(@as(u64, 102), stats.percentileNs(0));
}

test "stats count input and dropped bytes explicitly" {
    var stats: Stats = .{};
    stats.recordInputAction();
    stats.addDroppedInputBytes(4);
    stats.recordIteration(5);

    try std.testing.expectEqual(@as(usize, 1), stats.input_actions);
    try std.testing.expectEqual(@as(usize, 4), stats.dropped_input_bytes);
    try std.testing.expectEqual(@as(usize, 1), stats.iterations.count);
}

test "frame records are bounded and overwrite oldest" {
    var records: FrameRecords = .{};
    for (0..frame_record_capacity + 2) |index| {
        records.append(.{ .wake_ns = index, .paint_us = @intCast(index) });
    }

    try std.testing.expectEqual(@as(usize, frame_record_capacity), records.count);
    try std.testing.expectEqual(@as(usize, 2), records.evictions);
    try std.testing.expectEqual(@as(u64, frame_record_capacity + 1), records.newest().?.wake_ns);
}

test "stats record frame latency histogram and rebuild timings" {
    var stats: Stats = .{};
    stats.recordFrame(.{ .apply_us = 1, .layout_us = 2, .paint_us = 3, .flush_us = 4 });
    stats.recordInputLatency(10, 10 + std.time.ns_per_ms);
    stats.recordInputLatency(10, 10 + 2000 * std.time.ns_per_ms);
    stats.recordRebuild(99);

    try std.testing.expectEqual(@as(usize, 1), stats.frames.count);
    try std.testing.expectEqual(@as(usize, 1), stats.input_latency.buckets[0]);
    try std.testing.expectEqual(@as(usize, 1), stats.input_latency.buckets[input_latency_bucket_count - 1]);
    try std.testing.expectEqual(@as(usize, 1), stats.rebuilds.count);
}

test "stats write report includes render and input metrics" {
    var stats: Stats = .{};
    stats.recordIteration(10);
    stats.recordRender(20);
    stats.recordInputAction();
    stats.addDroppedInputBytes(4);

    var out: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&out);
    try stats.writeReport(&writer);
    const text = writer.buffered();

    try std.testing.expect(std.mem.indexOf(u8, text, "zi tui trace") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "renders count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "input_actions count=1") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "dropped_input_bytes count=4") != null);
}
