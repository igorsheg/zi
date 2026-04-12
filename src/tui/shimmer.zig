const std = @import("std");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme_mod = @import("grapheme.zig");

const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;

pub const Config = struct {
    /// Quantized animation cadence. 33ms ≈ 30 FPS.
    step_ns: i128 = 33_333_333,
    /// Invisible padding before the text so the band can sweep in naturally.
    lead_pad_cols: u32 = 6,
    /// Invisible padding after the text so the band can sweep out naturally.
    tail_pad_cols: u32 = 10,
    /// Half-width of the highlight band in terminal columns.
    band_half_width: u32 = 2,

    base_fg: Color,
    edge_fg: Color,
    peak_fg: Color,

    base_attrs: Attributes = .{ .dim = true },
    edge_attrs: Attributes = .{},
    peak_attrs: Attributes = .{ .bold = true },
};

pub const Bucket = enum {
    base,
    edge,
    peak,
};

pub fn nextDeadline(now_ns: i128, cfg: Config) i128 {
    if (cfg.step_ns <= 0) return now_ns;
    const current_step = @divFloor(now_ns, cfg.step_ns);
    return (current_step + 1) * cfg.step_ns;
}

pub fn phaseForTime(now_ns: i128, cfg: Config, text: []const u8) u32 {
    const period = shimmerPeriod(cfg, text);
    if (period == 0 or cfg.step_ns <= 0) return 0;
    const current_step = @divFloor(now_ns, cfg.step_ns);
    return @intCast(@mod(current_step, @as(i128, period)));
}

pub fn write(region: Region, x: u32, y: u32, text: []const u8, cfg: Config, phase: u32) u32 {
    if (text.len == 0 or y >= region.height or x >= region.width) return 0;

    var written_cols: u32 = 0;
    var visual_col: u32 = 0;
    var run_start: usize = 0;
    var run_bucket: ?Bucket = null;

    var i: usize = 0;
    while (i < text.len) {
        const char_start = i;
        const width = decodeWidth(text, &i);
        const bucket = bucketForColumn(cfg, phase, visual_col);

        if (run_bucket == null) {
            run_bucket = bucket;
        } else if (run_bucket.? != bucket) {
            written_cols += flushRun(region, x + written_cols, y, text[run_start..char_start], cfg, run_bucket.?);
            run_start = char_start;
            run_bucket = bucket;
        }

        visual_col += width;
    }

    if (run_bucket) |bucket| {
        written_cols += flushRun(region, x + written_cols, y, text[run_start..], cfg, bucket);
    }

    return written_cols;
}

fn shimmerPeriod(cfg: Config, text: []const u8) u32 {
    const text_cols: u32 = @intCast(grapheme_mod.strWidth(text));
    return text_cols + cfg.lead_pad_cols + cfg.tail_pad_cols;
}

pub fn bucketForColumn(cfg: Config, phase: u32, visual_col: u32) Bucket {
    const text_pos = @as(i64, cfg.lead_pad_cols) + @as(i64, visual_col);
    const center = @as(i64, phase);
    const dist = if (text_pos >= center) text_pos - center else center - text_pos;
    const half_width = @as(i64, cfg.band_half_width);

    if (dist == 0) return .peak;
    if (half_width == 0 or dist > half_width) return .base;
    if (dist * 2 <= half_width) return .peak;
    return .edge;
}

fn flushRun(region: Region, x: u32, y: u32, text: []const u8, cfg: Config, bucket: Bucket) u32 {
    return switch (bucket) {
        .base => region.writeStr(x, y, text, cfg.base_fg, Color.default, cfg.base_attrs),
        .edge => region.writeStr(x, y, text, cfg.edge_fg, Color.default, cfg.edge_attrs),
        .peak => region.writeStr(x, y, text, cfg.peak_fg, Color.default, cfg.peak_attrs),
    };
}

fn decodeWidth(text: []const u8, i: *usize) u32 {
    const start = i.*;
    const byte_len = std.unicode.utf8ByteSequenceLength(text[start]) catch {
        i.* += 1;
        return 1;
    };
    if (start + byte_len > text.len) {
        i.* = text.len;
        return 1;
    }
    const cp = std.unicode.utf8Decode(text[start .. start + byte_len]) catch {
        i.* += 1;
        return 1;
    };
    i.* += byte_len;
    return grapheme_mod.charWidth(cp);
}

test "phaseForTime advances on quantized cadence" {
    const cfg = Config{
        .step_ns = 10,
        .lead_pad_cols = 2,
        .tail_pad_cols = 2,
        .band_half_width = 1,
        .base_fg = Color.default,
        .edge_fg = Color.default,
        .peak_fg = Color.default,
    };

    try std.testing.expectEqual(@as(u32, 0), phaseForTime(0, cfg, "abc"));
    try std.testing.expectEqual(@as(u32, 1), phaseForTime(10, cfg, "abc"));
    try std.testing.expectEqual(@as(u32, 0), phaseForTime(70, cfg, "abc"));
}

test "write groups contiguous shimmer buckets into styled runs" {
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 16, 1);
    defer buf.deinit();

    const cfg = Config{
        .step_ns = 10,
        .lead_pad_cols = 0,
        .tail_pad_cols = 0,
        .band_half_width = 1,
        .base_fg = Color.rgb(1, 1, 1),
        .edge_fg = Color.rgb(2, 2, 2),
        .peak_fg = Color.rgb(3, 3, 3),
    };

    _ = write(buf.region(), 0, 0, "abc", cfg, 1);
    try std.testing.expect(buf.get(0, 0).fg.eql(cfg.edge_fg));
    try std.testing.expect(buf.get(1, 0).fg.eql(cfg.peak_fg));
    try std.testing.expect(buf.get(2, 0).fg.eql(cfg.edge_fg));
}
