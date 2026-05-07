const std = @import("std");
const buffer_mod = @import("primitives/surface.zig");
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
    width_method: grapheme_mod.WidthMethod = .wcwidth,
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
    var effective_cfg = cfg;
    effective_cfg.width_method = region.buf.width_method;

    var written_cols: u32 = 0;
    var visual_col: u32 = 0;
    var run_start: usize = 0;
    var run_bucket: ?Bucket = null;

    var i: usize = 0;
    while (i < text.len) {
        const char_start = i;
        const width = decodeWidth(text, &i, effective_cfg.width_method);
        const bucket = bucketForColumn(effective_cfg, phase, visual_col);

        if (run_bucket == null) {
            run_bucket = bucket;
        } else if (run_bucket.? != bucket) {
            written_cols += flushRun(region, x + written_cols, y, text[run_start..char_start], effective_cfg, run_bucket.?);
            run_start = char_start;
            run_bucket = bucket;
        }

        visual_col += width;
    }

    if (run_bucket) |bucket| {
        written_cols += flushRun(region, x + written_cols, y, text[run_start..], effective_cfg, bucket);
    }

    return written_cols;
}

fn shimmerPeriod(cfg: Config, text: []const u8) u32 {
    const text_cols: u32 = @intCast(grapheme_mod.strWidth(text, cfg.width_method));
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

pub fn strengthForColumn(cfg: Config, phase: u32, visual_col: u32) u8 {
    const text_pos = @as(i64, cfg.lead_pad_cols) + @as(i64, visual_col);
    const center = @as(i64, phase);
    const dist = if (text_pos >= center) text_pos - center else center - text_pos;
    const radius = @as(i64, cfg.band_half_width);
    if (radius <= 0) return if (dist == 0) 255 else 0;
    if (dist > radius) return 0;

    const numerator = (radius - dist + 1) * 255;
    const denominator = radius + 1;
    return @intCast(@min(@divTrunc(numerator, denominator), 255));
}

pub fn floorStrength(raw_strength: u8, floor: u8) u8 {
    const raw: i32 = raw_strength;
    const floor_i: i32 = floor;
    if (raw <= floor_i) return 0;

    const numer = (raw - floor_i) * 255;
    const denom = 255 - floor_i;
    return @intCast(@divTrunc(numer, denom));
}

pub fn lerpColor(from: Color, to: Color, t: u8) Color {
    return switch (from) {
        .default_color => if (t == 0) from else to,
        .rgb24 => |from_rgb| switch (to) {
            .default_color => if (t == 255) to else from,
            .rgb24 => |to_rgb| Color.rgb(
                lerpChannel(from_rgb.r, to_rgb.r, t),
                lerpChannel(from_rgb.g, to_rgb.g, t),
                lerpChannel(from_rgb.b, to_rgb.b, t),
            ),
            .index => if (t < 128) from else to,
        },
        .index => switch (to) {
            .default_color => if (t == 255) to else from,
            .rgb24, .index => if (t < 128) from else to,
        },
    };
}

pub fn writeSmooth(region: Region, x: u32, y: u32, text: []const u8, cfg: Config, phase: u32, floor: u8) u32 {
    if (text.len == 0 or y >= region.height or x >= region.width) return 0;
    var effective_cfg = cfg;
    effective_cfg.width_method = region.buf.width_method;

    var written_cols: u32 = 0;
    var visual_col: u32 = 0;
    var i: usize = 0;
    while (i < text.len) {
        const char_start = i;
        const width = decodeWidth(text, &i, effective_cfg.width_method);
        const strength = floorStrength(strengthForColumn(effective_cfg, phase, visual_col), floor);
        const fg = if (strength == 0) effective_cfg.base_fg else lerpColor(effective_cfg.base_fg, effective_cfg.peak_fg, strength);
        const attrs = if (strength >= 224) mergeAttrs(effective_cfg.base_attrs, effective_cfg.peak_attrs) else effective_cfg.base_attrs;
        written_cols += region.writeStr(x + written_cols, y, text[char_start..i], fg, Color.default, attrs);
        visual_col += width;
    }

    return written_cols;
}

fn flushRun(region: Region, x: u32, y: u32, text: []const u8, cfg: Config, bucket: Bucket) u32 {
    return switch (bucket) {
        .base => region.writeStr(x, y, text, cfg.base_fg, Color.default, cfg.base_attrs),
        .edge => region.writeStr(x, y, text, cfg.edge_fg, Color.default, cfg.edge_attrs),
        .peak => region.writeStr(x, y, text, cfg.peak_fg, Color.default, cfg.peak_attrs),
    };
}

fn lerpChannel(from: u8, to: u8, t: u8) u8 {
    const from_i: i32 = from;
    const to_i: i32 = to;
    const delta = to_i - from_i;
    const value = from_i + @divTrunc(delta * @as(i32, t), 255);
    return @intCast(@max(0, @min(value, 255)));
}

fn mergeAttrs(base: Attributes, overlay: Attributes) Attributes {
    return .{
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .italic = base.italic or overlay.italic,
        .underline = base.underline or overlay.underline,
        .blink = base.blink or overlay.blink,
        .inverse = base.inverse or overlay.inverse,
        .hidden = base.hidden or overlay.hidden,
        .strikethrough = base.strikethrough or overlay.strikethrough,
    };
}

fn decodeWidth(text: []const u8, i: *usize, width_method: grapheme_mod.WidthMethod) u32 {
    const cluster = grapheme_mod.nextCluster(text, i.*, width_method) orelse return 0;
    if (cluster.bytes.len == 0) return 0;
    i.* += cluster.bytes.len;
    return cluster.width;
}

test "writeSmooth keeps grapheme clusters atomic" {
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 12, 1, .wcwidth);
    defer buf.deinit();

    const cfg = Config{
        .base_fg = Color.default,
        .edge_fg = Color.rgb(120, 120, 120),
        .peak_fg = Color.rgb(255, 255, 255),
    };
    _ = writeSmooth(buf.region(), 0, 0, "e\u{0301}👩‍🚀", cfg, 0, 0);

    try std.testing.expect(buf.get(0, 0).grapheme == .pooled);
    try std.testing.expect(buf.get(1, 0).grapheme == .pooled);
    try std.testing.expectEqual(@as(u2, 2), buf.get(1, 0).width);
    try std.testing.expectEqual(@as(u2, 0), buf.get(2, 0).width);
}

test "write groups contiguous shimmer buckets into styled runs" {
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 16, 1, .wcwidth);
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
