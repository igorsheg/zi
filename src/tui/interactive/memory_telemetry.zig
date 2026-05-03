const std = @import("std");

const Interactive = @import("../interactive.zig").Interactive;
const session_reader = @import("../../coding_agent/session/reader.zig");

pub const log_interval_ns: i128 = 5 * std.time.ns_per_s;

const ByteSize = struct {
    bytes: usize,

    pub fn format(self: ByteSize, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const b: f64 = @floatFromInt(self.bytes);
        if (self.bytes >= 1024 * 1024) return writer.print("{d:.1}MiB", .{b / (1024.0 * 1024.0)});
        if (self.bytes >= 1024) return writer.print("{d:.1}KiB", .{b / 1024.0});
        return writer.print("{d}B", .{self.bytes});
    }
};

const Duration = struct {
    ns: u64,

    pub fn format(self: Duration, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        const n: f64 = @floatFromInt(self.ns);
        if (self.ns >= std.time.ns_per_s) return writer.print("{d:.2}s", .{n / @as(f64, @floatFromInt(std.time.ns_per_s))});
        if (self.ns >= std.time.ns_per_ms) return writer.print("{d:.1}ms", .{n / @as(f64, @floatFromInt(std.time.ns_per_ms))});
        if (self.ns >= std.time.ns_per_us) return writer.print("{d:.1}us", .{n / @as(f64, @floatFromInt(std.time.ns_per_us))});
        return writer.print("{d}ns", .{self.ns});
    }
};

pub const Snapshot = struct {
    transcript_items: usize = 0,
    committed_messages: usize = 0,
    committed_segments: usize = 0,
    in_flight_tools: usize = 0,
    snapshot_queue_pending: usize = 0,
    snapshot_queue_high_water: usize = 0,
    snapshot_queue_dropped: usize = 0,
    snapshot_coalesced_dropped: usize = 0,
    snapshot_capacity_dropped: usize = 0,
    lifecycle_queue_pending: usize = 0,
    request_queue_pending: usize = 0,
    renderer_output_capacity: usize = 0,
    renderer_cells: usize = 0,
    projection_cache_items: usize = 0,
    projection_cache_hits: u32 = 0,
    projection_cache_misses: u32 = 0,
    projection_cache_fallbacks: u32 = 0,
    projection_full_rebuilds: u32 = 0,
    projection_transient_rebuilds: u32 = 0,
    projection_miss_no_cache: u32 = 0,
    projection_miss_committed_changed: u32 = 0,
    projection_miss_retry_changed: u32 = 0,
    projection_queued_reconciles: u32 = 0,
    session_reads: u64 = 0,
    session_last_bytes: usize = 0,
    session_last_entries: usize = 0,
    session_last_parse_ns: u64 = 0,
    session_last_total_ns: u64 = 0,
    session_total_bytes: u64 = 0,
    session_total_parse_ns: u64 = 0,
};

pub fn enabledFromEnv() bool {
    const env = @import("env");
    const value = env.get("ZI_MEMORY_LOG") orelse return false;
    return value.len != 0 and !std.mem.eql(u8, value, "0") and !std.ascii.eqlIgnoreCase(value, "false");
}

pub fn collect(self: *Interactive) Snapshot {
    const snapshot_stats = self.snapshot_event_queue.stats();
    const lifecycle_stats = self.lifecycle_event_queue.stats();
    const request_stats = self.request_queue.stats();

    const reader_stats = session_reader.telemetrySnapshot();
    var out = Snapshot{
        .transcript_items = self.transcript.items.items.len,
        .snapshot_queue_pending = snapshot_stats.pending_depth,
        .snapshot_queue_high_water = snapshot_stats.high_water_depth,
        .snapshot_queue_dropped = snapshot_stats.dropped_count,
        .snapshot_coalesced_dropped = self.snapshot_coalesced_dropped,
        .snapshot_capacity_dropped = snapshot_stats.dropped_count -| self.snapshot_coalesced_dropped,
        .lifecycle_queue_pending = lifecycle_stats.pending_depth,
        .request_queue_pending = request_stats.pending_depth,
        .renderer_output_capacity = self.tui.renderer.output.capacity,
        .renderer_cells = self.tui.renderer.current.cells.len + self.tui.renderer.next.cells.len,
        .projection_cache_hits = self.conversation_projection.committed_cache_hits,
        .projection_cache_misses = self.conversation_projection.committed_cache_misses,
        .projection_cache_fallbacks = self.conversation_projection.committed_cache_fallbacks,
        .projection_full_rebuilds = self.conversation_projection.full_rebuilds,
        .projection_transient_rebuilds = self.conversation_projection.transient_rebuilds,
        .projection_miss_no_cache = self.conversation_projection.cache_miss_no_cache,
        .projection_miss_committed_changed = self.conversation_projection.cache_miss_committed_changed,
        .projection_miss_retry_changed = self.conversation_projection.cache_miss_retry_changed,
        .projection_queued_reconciles = self.conversation_projection.queued_reconciles,
        .session_reads = reader_stats.read_count,
        .session_last_bytes = reader_stats.last_bytes,
        .session_last_entries = reader_stats.last_entries,
        .session_last_parse_ns = reader_stats.last_parse_ns,
        .session_last_total_ns = reader_stats.last_total_ns,
        .session_total_bytes = reader_stats.total_bytes,
        .session_total_parse_ns = reader_stats.total_parse_ns,
    };

    if (self.conversation_projection.view_snapshot) |snapshot| {
        out.committed_messages = snapshot.view.committed.flat.len;
        out.committed_segments = snapshot.view.committed.segments.len;
        if (snapshot.view.in_flight) |turn| {
            out.in_flight_tools = turn.tool_executions.len;
        }
    }
    if (self.conversation_projection.committed_cache) |cache| {
        out.projection_cache_items = cache.items.len;
    }
    return out;
}

pub fn log(self: *Interactive, label: []const u8) void {
    const s = collect(self);
    std.log.scoped(.memory).info(
        "{s}: tr={d} cm={d} seg={d} tools={d} sq={d}/{d} drop={d} coal={d} capdrop={d} lq={d} rq={d} rout={d} cells={d} pc={d} hit={d} miss={d} nc={d} cc={d} rc={d} fb={d} full={d} trans={d} qr={d} sr={d} sbytes={d} sent={d} sparsens={d} stotalns={d} stbytes={d} stparsens={d}",
        .{
            label,
            s.transcript_items,
            s.committed_messages,
            s.committed_segments,
            s.in_flight_tools,
            s.snapshot_queue_pending,
            s.snapshot_queue_high_water,
            s.snapshot_queue_dropped,
            s.snapshot_coalesced_dropped,
            s.snapshot_capacity_dropped,
            s.lifecycle_queue_pending,
            s.request_queue_pending,
            s.renderer_output_capacity,
            s.renderer_cells,
            s.projection_cache_items,
            s.projection_cache_hits,
            s.projection_cache_misses,
            s.projection_miss_no_cache,
            s.projection_miss_committed_changed,
            s.projection_miss_retry_changed,
            s.projection_cache_fallbacks,
            s.projection_full_rebuilds,
            s.projection_transient_rebuilds,
            s.projection_queued_reconciles,
            s.session_reads,
            s.session_last_bytes,
            s.session_last_entries,
            s.session_last_parse_ns,
            s.session_last_total_ns,
            s.session_total_bytes,
            s.session_total_parse_ns,
        },
    );
}

pub fn format(allocator: std.mem.Allocator, self: *Interactive) ![]u8 {
    const s = collect(self);
    return std.fmt.allocPrint(
        allocator,
        "memory:\n" ++
            "  session: reads={d} last={f}/{d} entries parse={f} total={f}\n" ++
            "  transcript: rows={d} committed={d} msgs/{d} segs projection_cache={d}\n" ++
            "  projection: hits={d} misses={d} full_rebuilds={d} transient_rebuilds={d}\n" ++
            "  queues: snapshot={d}/{d} dropped={d} coalesced={d} capacity_dropped={d}\n" ++
            "  renderer: output_cap={f} cells={d}",
        .{
            s.session_reads,
            ByteSize{ .bytes = s.session_last_bytes },
            s.session_last_entries,
            Duration{ .ns = s.session_last_parse_ns },
            Duration{ .ns = s.session_last_total_ns },
            s.transcript_items,
            s.committed_messages,
            s.committed_segments,
            s.projection_cache_items,
            s.projection_cache_hits,
            s.projection_cache_misses,
            s.projection_full_rebuilds,
            s.projection_transient_rebuilds,
            s.snapshot_queue_pending,
            s.snapshot_queue_high_water,
            s.snapshot_queue_dropped,
            s.snapshot_coalesced_dropped,
            s.snapshot_capacity_dropped,
            ByteSize{ .bytes = s.renderer_output_capacity },
            s.renderer_cells,
        },
    );
}
