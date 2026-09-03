//! Heap-free one-shot usage statistics rendering.
//!
//! Formatting follows hax v0.4.0's `agent_format_stats_segments` and
//! provider-neutral formatting helpers at the pinned reference revision.

const std = @import("std");
const agent = @import("../agent/root.zig");
const OneShot = @import("OneShot.zig");

const ansi_dim = "\x1b[2m";
const ansi_reset = "\x1b[0m";
const separator = " · ";
const value_len: usize = 48;
const maximum_value_bytes: usize = value_len - 1;

pub const ContextLimitSource = struct {
    context: *const anyopaque,
    resolve_fn: *const fn (*const anyopaque) ?u64,

    pub fn resolve(self: ContextLimitSource) ?u64 {
        return self.resolve_fn(self.context);
    }

    pub fn from(implementation: anytype) ContextLimitSource {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Stats.ContextLimitSource.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn resolve(context: *const anyopaque) ?u64 {
                const self: *const Implementation = @ptrCast(@alignCast(context));
                return self.resolveContextLimit();
            }
        };
        return .{ .context = implementation, .resolve_fn = Adapter.resolve };
    }
};

/// Synchronously renders final one-shot statistics without allocation.
pub const Renderer = struct {
    context_limit: ?u64 = null,
    context_limit_source: ?ContextLimitSource = null,

    pub fn renderer(self: *Renderer) OneShot.StatsRenderer {
        return OneShot.StatsRenderer.from(self);
    }

    /// When styling is enabled, a returned writer error can leave dim styling
    /// open. `OneShot.run` owns the documented best-effort reset in that case.
    pub fn render(
        self: *Renderer,
        writer: *std.Io.Writer,
        stats: *const agent.UsageStats.UsageStats,
        elapsed_ms: u64,
        style_diagnostics: bool,
    ) OneShot.RenderError!void {
        return self.renderTurnSummary(
            writer,
            stats,
            stats.last_ordinary_context_tokens,
            elapsed_ms,
            style_diagnostics,
            0,
        );
    }

    /// Renders an interactive turn summary without allocation. The explicit
    /// context snapshot belongs to the latest turn; spend remains cumulative.
    /// A zero column bound disables wrapping. Otherwise wrapping occurs only
    /// between complete segments, matching hax's `display_stats_line`.
    pub fn renderTurnSummary(
        self: *Renderer,
        writer: *std.Io.Writer,
        stats: *const agent.UsageStats.UsageStats,
        latest_context_tokens: ?u64,
        elapsed_ms: u64,
        style_diagnostics: bool,
        display_columns: usize,
    ) OneShot.RenderError!void {
        errdefer if (style_diagnostics) {
            writer.writeAll(ansi_reset) catch {};
            writer.flush() catch {};
        };
        var segments: Segments = .{};
        segments.addDuration(elapsed_ms);
        if (latest_context_tokens) |context_tokens| {
            const context_limit = if (self.context_limit_source) |source|
                source.resolve()
            else
                self.context_limit;
            segments.addContext(context_tokens, context_limit);
        }
        const spend = sanitizeSpend(stats.spend_usd);
        if (spend > 0) {
            segments.addSpend(
                spend,
                stats.spend_estimated or stats.has_unpriced or stats.spend_unreliable,
            );
        }

        if (style_diagnostics) try writer.writeAll(ansi_dim);
        var column: usize = 0;
        for (segments.slice(), 0..) |segment_value, index| {
            const segment = segment_value.slice();
            if (index > 0) {
                const joined_width = column +| separator.len +| segment.len;
                if (display_columns != 0 and joined_width > display_columns) {
                    try writer.writeByte('\n');
                    column = 0;
                } else {
                    try writer.writeAll(separator);
                    column +|= separator.len;
                }
            }
            try writer.writeAll(segment);
            column +|= segment.len;
        }
        if (style_diagnostics) try writer.writeAll(ansi_reset);
        try writer.writeByte('\n');
    }
};

const segment_count_max = 3;
const segment_len = 64;

const Segment = struct {
    bytes: [segment_len]u8 = undefined,
    len: usize = 0,

    fn writer(self: *Segment) std.Io.Writer {
        return .fixed(&self.bytes);
    }

    fn finish(self: *Segment, output_writer: *const std.Io.Writer) void {
        self.len = output_writer.buffered().len;
    }

    fn slice(self: *const Segment) []const u8 {
        return self.bytes[0..self.len];
    }
};

const Segments = struct {
    values: [segment_count_max]Segment = .{ .{}, .{}, .{} },
    len: usize = 0,

    fn next(self: *Segments) *Segment {
        const segment = &self.values[self.len];
        self.len += 1;
        return segment;
    }

    fn addDuration(self: *Segments, elapsed_ms: u64) void {
        const segment = self.next();
        var writer = segment.writer();
        formatDuration(&writer, elapsed_ms) catch unreachable;
        segment.finish(&writer);
    }

    fn addContext(self: *Segments, context_tokens: u64, context_limit: ?u64) void {
        const segment = self.next();
        var writer = segment.writer();
        formatContext(&writer, context_tokens, context_limit) catch unreachable;
        segment.finish(&writer);
    }

    fn addSpend(self: *Segments, spend: f64, estimated: bool) void {
        const segment = self.next();
        var writer = segment.writer();
        if (estimated) writer.writeByte('~') catch unreachable;
        formatCostBounded(&writer, spend) catch unreachable;
        segment.finish(&writer);
    }

    fn slice(self: *const Segments) []const Segment {
        return self.values[0..self.len];
    }
};

fn sanitizeSpend(spend: f64) f64 {
    if (!std.math.isFinite(spend) or spend <= 0) return 0;
    return spend;
}

fn formatDuration(writer: *std.Io.Writer, duration_ms: u64) std.Io.Writer.Error!void {
    const seconds = duration_ms / std.time.ms_per_s +
        @intFromBool(duration_ms % std.time.ms_per_s >= std.time.ms_per_s / 2);

    if (seconds < 60) {
        try writer.print("{d}s", .{seconds});
    } else if (seconds < 3_600 and seconds % 60 == 0) {
        try writer.print("{d}m", .{seconds / 60});
    } else if (seconds < 3_600) {
        try writer.print("{d}m {d:0>2}s", .{ seconds / 60, seconds % 60 });
    } else if (seconds % 3_600 == 0) {
        try writer.print("{d}h", .{seconds / 3_600});
    } else {
        try writer.print("{d}h {d:0>2}m", .{ seconds / 3_600, seconds % 3_600 / 60 });
    }
}

fn formatTokens(writer: *std.Io.Writer, tokens: u64) std.Io.Writer.Error!void {
    const kilo: u64 = 1_024;
    const mega: u64 = kilo * kilo;
    if (tokens < kilo) {
        try writer.print("{d}", .{tokens});
    } else if (tokens < 10 * kilo) {
        try writer.print("{d:.1}k", .{@as(f64, @floatFromInt(tokens)) / @as(f64, kilo)});
    } else if (tokens < mega) {
        try writer.print("{d}k", .{tokens / kilo + @intFromBool(tokens % kilo >= kilo / 2)});
    } else if (tokens < 10 * mega) {
        try writer.print("{d:.1}M", .{@as(f64, @floatFromInt(tokens)) / @as(f64, mega)});
    } else {
        try writer.print("{d}M", .{tokens / mega + @intFromBool(tokens % mega >= mega / 2)});
    }
}

fn formatContext(writer: *std.Io.Writer, context_tokens: u64, context_limit: ?u64) std.Io.Writer.Error!void {
    const limit = context_limit orelse 0;
    if (limit == 0) {
        try writer.writeAll("context ");
        return formatTokens(writer, context_tokens);
    }

    try formatTokens(writer, context_tokens);
    try writer.writeAll(" / ");
    try formatTokens(writer, limit);
    // Preserve hax's full-domain floating-point rounding before truncation.
    const ratio = @as(f64, @floatFromInt(context_tokens)) * 100.0 /
        @as(f64, @floatFromInt(limit));
    const percentage: u16 = if (ratio > 999.0) 999 else @intFromFloat(ratio);
    try writer.print(" ({d}%)", .{percentage});
}

fn formatCostBounded(writer: *std.Io.Writer, spend: f64) std.Io.Writer.Error!void {
    // A finite f64 rendered in fixed notation fits in this buffer. hax formats
    // the value through a 48-byte buffer, so retain at most its 47 payload bytes.
    var buffer: [384]u8 = undefined;
    var fixed: std.Io.Writer = .fixed(&buffer);
    if (spend < 0.01) {
        fixed.print("${d:.4}", .{spend}) catch unreachable;
    } else if (spend < 1) {
        fixed.print("${d:.3}", .{spend}) catch unreachable;
    } else {
        fixed.print("${d:.2}", .{spend}) catch unreachable;
    }
    const formatted = fixed.buffered();
    try writer.writeAll(formatted[0..@min(formatted.len, maximum_value_bytes)]);
}

fn renderForTest(
    renderer_value: *Renderer,
    stats: *const agent.UsageStats.UsageStats,
    elapsed_ms: u64,
    styled: bool,
    output: []u8,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(output);
    try renderer_value.render(&writer, stats, elapsed_ms, styled);
    return writer.buffered();
}

fn renderTurnForTest(
    renderer_value: *Renderer,
    stats: *const agent.UsageStats.UsageStats,
    latest_context_tokens: ?u64,
    elapsed_ms: u64,
    styled: bool,
    display_columns: usize,
    output: []u8,
) ![]const u8 {
    var writer: std.Io.Writer = .fixed(output);
    try renderer_value.renderTurnSummary(
        &writer,
        stats,
        latest_context_tokens,
        elapsed_ms,
        styled,
        display_columns,
    );
    return writer.buffered();
}

test "pinned hax stats segments render in display order" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    stats.last_ordinary_context_tokens = 9_113;
    stats.spend_usd = 0.042;
    var renderer_value: Renderer = .{ .context_limit = 262_144 };
    var output: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "42s · 8.9k / 256k (3%) · $0.042\n",
        try renderForTest(&renderer_value, &stats, 42_000, false, &output),
    );

    renderer_value.context_limit = 0;
    try std.testing.expectEqualStrings(
        "42s · context 8.9k · $0.042\n",
        try renderForTest(&renderer_value, &stats, 42_000, false, &output),
    );

    stats.last_ordinary_context_tokens = null;
    stats.spend_estimated = true;
    try std.testing.expectEqualStrings(
        "0s · ~$0.042\n",
        try renderForTest(&renderer_value, &stats, 0, false, &output),
    );

    stats.spend_usd = 0;
    try std.testing.expectEqualStrings(
        "42s\n",
        try renderForTest(&renderer_value, &stats, 42_000, false, &output),
    );
}

test "duration follows half-up whole-second minute and hour rules" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;
    const cases = [_]struct { elapsed_ms: u64, expected: []const u8 }{
        .{ .elapsed_ms = 0, .expected = "0s\n" },
        .{ .elapsed_ms = 42_499, .expected = "42s\n" },
        .{ .elapsed_ms = 42_500, .expected = "43s\n" },
        .{ .elapsed_ms = 68_000, .expected = "1m 08s\n" },
        .{ .elapsed_ms = 600_000, .expected = "10m\n" },
        .{ .elapsed_ms = 3_720_000, .expected = "1h 02m\n" },
        .{ .elapsed_ms = 7_200_000, .expected = "2h\n" },
    };
    for (cases) |case| try std.testing.expectEqualStrings(
        case.expected,
        try renderForTest(&renderer_value, &stats, case.elapsed_ms, false, &output),
    );
}

test "binary token thresholds rounding and context percentage are bounded" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{ .context_limit = 1 };
    var output: [160]u8 = undefined;
    const cases = [_]struct { tokens: u64, expected_context: []const u8 }{
        .{ .tokens = 412, .expected_context = "412 / 1 (999%)" },
        .{ .tokens = 5 * 1_024 + 410, .expected_context = "5.4k / 1 (999%)" },
        .{ .tokens = 128 * 1_024, .expected_context = "128k / 1 (999%)" },
        .{ .tokens = 1_228 * 1_024, .expected_context = "1.2M / 1 (999%)" },
        .{ .tokens = 12 * 1_024 * 1_024, .expected_context = "12M / 1 (999%)" },
        .{ .tokens = std.math.maxInt(u64), .expected_context = "17592186044416M / 1 (999%)" },
    };
    for (cases) |case| {
        stats.last_ordinary_context_tokens = case.tokens;
        const rendered = try renderForTest(&renderer_value, &stats, 0, false, &output);
        try std.testing.expect(std.mem.startsWith(u8, rendered, "0s · "));
        try std.testing.expectEqualStrings(
            case.expected_context,
            rendered[("0s" ++ separator).len .. rendered.len - 1],
        );
    }

    renderer_value.context_limit = 262_144;
    stats.last_ordinary_context_tokens = 300_000;
    try std.testing.expectEqualStrings(
        "0s · 293k / 256k (114%)\n",
        try renderForTest(&renderer_value, &stats, 0, false, &output),
    );

    // This full-domain case rounds to 91.0 in hax's binary64 calculation,
    // while exact integer division would floor it to 90.
    renderer_value.context_limit = 5_948_518_208_078_904_005;
    stats.last_ordinary_context_tokens = 5_413_151_569_351_802_639;
    const rounded_ratio = try renderForTest(&renderer_value, &stats, 0, false, &output);
    try std.testing.expect(std.mem.endsWith(u8, rounded_ratio, "(91%)\n"));

    renderer_value.context_limit = 1;
    stats.last_ordinary_context_tokens = std.math.maxInt(u64);
    const capped_ratio = try renderForTest(&renderer_value, &stats, 0, false, &output);
    try std.testing.expect(std.mem.endsWith(u8, capped_ratio, "(999%)\n"));
}

test "cost precision approximation flags and invalid spend sanitation" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;
    const cases = [_]struct { spend: f64, expected: []const u8 }{
        .{ .spend = 0.00421, .expected = "0s · $0.0042\n" },
        .{ .spend = 0.042, .expected = "0s · $0.042\n" },
        .{ .spend = 1.234, .expected = "0s · $1.23\n" },
        .{ .spend = 42.129, .expected = "0s · $42.13\n" },
    };
    for (cases) |case| {
        stats.spend_usd = case.spend;
        try std.testing.expectEqualStrings(
            case.expected,
            try renderForTest(&renderer_value, &stats, 0, false, &output),
        );
    }

    stats.spend_usd = 0.042;
    inline for (.{ "spend_estimated", "has_unpriced", "spend_unreliable" }) |field_name| {
        stats.spend_estimated = false;
        stats.has_unpriced = false;
        stats.spend_unreliable = false;
        @field(stats, field_name) = true;
        try std.testing.expectEqualStrings(
            "0s · ~$0.042\n",
            try renderForTest(&renderer_value, &stats, 0, false, &output),
        );
    }

    stats.spend_estimated = false;
    stats.has_unpriced = false;
    stats.spend_unreliable = false;
    for ([_]f64{ std.math.nan(f64), std.math.inf(f64), -1 }) |invalid| {
        stats.spend_usd = invalid;
        try std.testing.expectEqualStrings(
            "0s\n",
            try renderForTest(&renderer_value, &stats, 0, false, &output),
        );
    }
}

test "renderer exposes erased seam and styling wraps the complete line" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    stats.spend_usd = 0.5;
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try renderer_value.renderer().render(&writer, &stats, 1_500, true);
    try std.testing.expectEqualStrings(
        "\x1b[2m2s · $0.500\x1b[0m\n",
        writer.buffered(),
    );
}

test "extreme spend stays in the pinned bounded value segment" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    stats.spend_usd = std.math.floatMax(f64);
    stats.spend_unreliable = true;
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;
    const rendered = try renderForTest(&renderer_value, &stats, std.math.maxInt(u64), false, &output);
    try std.testing.expect(rendered.len <= 3 + 20 + separator.len + 1 + maximum_value_bytes + 1);
    try std.testing.expect(std.mem.indexOf(u8, rendered, " · ~$") != null);
    try std.testing.expectEqual(@as(u8, '\n'), rendered[rendered.len - 1]);
}

test "writer failures propagate and OneShot owns reset recovery" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{};

    var empty_buffer: [0]u8 = .{};
    var empty_writer: std.Io.Writer = .fixed(&empty_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        renderer_value.render(&empty_writer, &stats, 0, false),
    );

    var style_buffer: [ansi_dim.len]u8 = undefined;
    var style_writer: std.Io.Writer = .fixed(&style_buffer);
    try std.testing.expectError(
        error.WriteFailed,
        renderer_value.render(&style_writer, &stats, 0, true),
    );
    try std.testing.expectEqualStrings(ansi_dim, style_writer.buffered());
}

test "interactive summary wraps only beyond segment boundaries" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{ .context_limit = 262_144 };
    var output: [160]u8 = undefined;

    const exact = "42s · 8.9k / 256k (3%)";
    try std.testing.expectEqualStrings(
        exact ++ "\n",
        try renderTurnForTest(&renderer_value, &stats, 9_113, 42_000, false, exact.len, &output),
    );
    try std.testing.expectEqualStrings(
        "42s\n8.9k / 256k (3%)\n",
        try renderTurnForTest(&renderer_value, &stats, 9_113, 42_000, false, exact.len - 1, &output),
    );

    // The first segment is wider than the terminal but remains intact. The
    // following segment starts on a new line without a leading separator.
    renderer_value.context_limit = null;
    try std.testing.expectEqualStrings(
        "42s\ncontext 1\n",
        try renderTurnForTest(&renderer_value, &stats, 1, 42_000, false, 2, &output),
    );
}

test "interactive summary zero and extreme widths are unbounded" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    stats.spend_usd = 0.042;
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;
    const expected = "0s · context 1 · $0.042\n";

    try std.testing.expectEqualStrings(
        expected,
        try renderTurnForTest(&renderer_value, &stats, 1, 0, false, 0, &output),
    );
    try std.testing.expectEqualStrings(
        expected,
        try renderTurnForTest(
            &renderer_value,
            &stats,
            1,
            0,
            false,
            std.math.maxInt(usize),
            &output,
        ),
    );
}

test "interactive summary uses explicit context and cumulative approximate spend" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    stats.last_ordinary_context_tokens = 999;
    stats.spend_usd = 0.042;
    stats.has_unpriced = true;
    var renderer_value: Renderer = .{};
    var output: [128]u8 = undefined;

    try std.testing.expectEqualStrings(
        "\x1b[2m0s · ~$0.042\x1b[0m\n",
        try renderTurnForTest(&renderer_value, &stats, null, 0, true, 80, &output),
    );
    stats.has_unpriced = false;
    stats.spend_estimated = true;
    try std.testing.expectEqualStrings(
        "0s · context 7 · ~$0.042\n",
        try renderTurnForTest(&renderer_value, &stats, 7, 0, false, 80, &output),
    );
}

test "interactive summary propagates writer failures" {
    var stats = try agent.UsageStats.UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    var renderer_value: Renderer = .{};
    var output: [2]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&output);
    try std.testing.expectError(
        error.WriteFailed,
        renderer_value.renderTurnSummary(&writer, &stats, null, 0, false, 0),
    );
}
