//! Dev-only benchmark for the agent-agnostic TUI render path.
//!
//! This is intentionally small and deterministic: it measures the concrete
//! product frame transaction (`tui.render.draw` + `vaxis.render`) without a
//! terminal, provider, session, or network. Use it to validate responsiveness
//! claims before adding render caches or event-loop machinery.
const std = @import("std");
const tui = @import("tui");
const vaxis = @import("vaxis");

const default_items: usize = tui.Transcript.item_count_max;
const default_frames: usize = 600;
const default_width: u16 = 100;
const default_height: u16 = 30;
const default_item_bytes: usize = 512;
const stream_chunk = " streaming tail chunk";
const sixty_fps_budget_us: u64 = 16_666;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    const config = try Config.parse(args);

    var env = std.process.Environ.Map.init(gpa);
    defer env.deinit();

    var discard = std.Io.Writer.Discarding.init(&.{});
    var vx = try vaxis.init(init.io, gpa, &env, .{});
    defer vx.deinit(gpa, &discard.writer);
    try vx.resize(gpa, &discard.writer, .{
        .cols = config.width,
        .rows = config.height,
        .x_pixel = 0,
        .y_pixel = 0,
    });

    var app = tui.App.init(config.width, config.height);
    defer app.deinit(gpa);
    try seedTranscript(gpa, &app, config.items, config.item_bytes);

    var scratch: tui.render.RowScratch = undefined;
    const cold_ns = try renderFrames(gpa, init.io, &app, &vx, &scratch, &discard.writer, 1, false);
    const warm_ns = try renderFrames(gpa, init.io, &app, &vx, &scratch, &discard.writer, config.frames, false);
    const stream_ns = try renderFrames(gpa, init.io, &app, &vx, &scratch, &discard.writer, config.frames, true);

    std.debug.print(
        \\
        \\tui render bench
        \\  items={d} resident_bytes={d} total_rows={d} visible_rows={d}
        \\  terminal={d}x{d} frames={d} item_bytes={d}
        \\  cold_draw_render_us={d}
        \\  warm_avg_us={d} 60fps_budget_us={d}
        \\  stream_avg_us={d} 60fps_budget_us={d}
        \\
    , .{
        app.transcript.items.items.len,
        app.transcript.total_size_bytes,
        tui.render.transcriptTotalRows(&app),
        tui.render.transcriptVisibleRows(&app),
        config.width,
        config.height,
        config.frames,
        config.item_bytes,
        nsToUs(cold_ns),
        nsToUs(avgNs(warm_ns, config.frames)),
        sixty_fps_budget_us,
        nsToUs(avgNs(stream_ns, config.frames)),
        sixty_fps_budget_us,
    });
}

const Config = struct {
    items: usize = default_items,
    frames: usize = default_frames,
    width: u16 = default_width,
    height: u16 = default_height,
    item_bytes: usize = default_item_bytes,

    fn parse(args: []const []const u8) !Config {
        if (args.len > 6) return usage(args[0]);
        return .{
            .items = try optionalUsize(args, 1, default_items),
            .frames = try optionalUsize(args, 2, default_frames),
            .width = try optionalU16(args, 3, default_width),
            .height = try optionalU16(args, 4, default_height),
            .item_bytes = try optionalUsize(args, 5, default_item_bytes),
        };
    }
};

fn usage(exe: []const u8) error{InvalidArguments} {
    std.debug.print(
        "usage: {s} [items] [frames] [width] [height] [item-bytes]\n",
        .{exe},
    );
    return error.InvalidArguments;
}

fn optionalUsize(args: []const []const u8, index: usize, default: usize) !usize {
    if (index >= args.len) return default;
    return std.fmt.parseUnsigned(usize, args[index], 10);
}

fn optionalU16(args: []const []const u8, index: usize, default: u16) !u16 {
    const value = try optionalUsize(args, index, default);
    return std.math.cast(u16, value) orelse error.InvalidArguments;
}

fn seedTranscript(
    gpa: std.mem.Allocator,
    app: *tui.App,
    item_count: usize,
    item_bytes: usize,
) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(gpa);
    try text.ensureTotalCapacity(gpa, @max(item_bytes, 1));

    var item_index: usize = 0;
    while (item_index < item_count) : (item_index += 1) {
        text.clearRetainingCapacity();
        try text.print(gpa, "item {d}: ", .{item_index});
        while (text.items.len < item_bytes) {
            try text.appendSlice(gpa, "abcdefghijklmnopqrstuvwxyz ");
        }
        text.shrinkRetainingCapacity(item_bytes);
        _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
            .role = .assistant,
            .text = text.items,
            .mode = .new_item,
        } } });
    }
}

fn renderFrames(
    gpa: std.mem.Allocator,
    io: std.Io,
    app: *tui.App,
    vx: *vaxis.Vaxis,
    scratch: *tui.render.RowScratch,
    writer: *std.Io.Writer,
    frames: usize,
    stream_tail: bool,
) !u64 {
    if (frames == 0) return 0;
    const start_ns = nowNs(io);
    var frame: usize = 0;
    while (frame < frames) : (frame += 1) {
        if (stream_tail) {
            _ = try app.apply(gpa, .{ .append_transcript = .{ .message = .{
                .role = .assistant,
                .text = stream_chunk,
                .mode = .extend_previous_assistant_message,
            } } });
        }
        tui.render.draw(app, vx, scratch);
        try vx.render(writer);
    }
    return @intCast(nowNs(io) - start_ns);
}

fn nowNs(io: std.Io) i128 {
    return @intCast(std.Io.Clock.awake.now(io).nanoseconds);
}

fn avgNs(total_ns: u64, frames: usize) u64 {
    return total_ns / @max(frames, 1);
}

fn nsToUs(ns: u64) u64 {
    return ns / std.time.ns_per_us;
}
