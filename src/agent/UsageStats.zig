const std = @import("std");
const ai = @import("../ai/root.zig");
const Loop = @import("Loop.zig");

/// Allocation-free session totals. Arithmetic saturates at the integer bounds.
pub const UsageStats = struct {
    input_tokens: u64 = 0,
    output_tokens: u64 = 0,
    cached_tokens: u64 = 0,
    cache_write_tokens: u64 = 0,
    cache_write_1h_tokens: u64 = 0,
    uncached_input_tokens: u64 = 0,
    spend_usd: f64 = 0,
    spend_estimated: bool = false,
    spend_unreliable: bool = false,
    has_unpriced: bool = false,
    last_ordinary_context_tokens: ?u64 = null,

    /// Consumes the same typed payload delivered by Loop and CompactRunner.
    pub fn observe(self: *UsageStats, observation: Loop.UsageObservation) Loop.HookError!void {
        self.accountTokens(observation.footer);
        self.accountSpend(observation.spend);
        if (observation.kind == .ordinary) {
            if (observation.terminal_context_tokens) |tokens| {
                self.last_ordinary_context_tokens = tokens;
            }
        }
    }

    fn accountTokens(self: *UsageStats, usage: ai.Usage.TurnUsage) void {
        self.input_tokens +|= usage.stream.input_tokens orelse 0;
        self.output_tokens +|= usage.stream.output_tokens orelse 0;
        self.cached_tokens +|= usage.stream.cached_tokens orelse 0;
        self.cache_write_tokens +|= usage.stream.cache_write_tokens orelse 0;
        self.cache_write_1h_tokens +|= usage.stream.cache_write_1h_tokens orelse 0;
        self.uncached_input_tokens +|= usage.uncached_input_tokens orelse 0;
    }

    fn accountSpend(self: *UsageStats, spend: ai.UsagePricing.Spend) void {
        const sum = self.spend_usd + spend.known_usd;
        if (std.math.isFinite(sum)) {
            self.spend_usd = sum;
        } else {
            self.spend_usd = std.math.floatMax(f64);
            self.spend_estimated = true;
            self.spend_unreliable = true;
        }
        self.has_unpriced = self.has_unpriced or spend.has_unpriced;
        self.spend_estimated = self.spend_estimated or spend.estimated or spend.has_unpriced;
        self.spend_unreliable = self.spend_unreliable or spend.unreliable;
    }
};

test "observation uses terminal ordinary context rather than aggregate retry context" {
    var stats: UsageStats = .{};
    try stats.observe(.{
        .footer = .{
            .stream = .{ .input_tokens = 141, .output_tokens = 20 },
            .uncached_input_tokens = 121,
            .cost_total_usd = 1.5,
        },
        .spend = .{ .known_usd = 1.5 },
        .kind = .ordinary,
        .terminal_context_tokens = 120,
    });
    try std.testing.expectEqual(@as(u64, 141), stats.input_tokens);
    try std.testing.expectEqual(@as(?u64, 120), stats.last_ordinary_context_tokens);

    // A partial terminal attempt has no complete context snapshot. Its aggregate
    // footer still counts, but cannot erase the last complete ordinary context.
    try stats.observe(.{
        .footer = .{
            .stream = .{ .input_tokens = 40, .output_tokens = 5 },
            .cost_total_usd = 0.5,
            .cost_estimated = true,
        },
        .spend = .{ .known_usd = 0.5, .estimated = true },
        .kind = .ordinary,
        .terminal_context_tokens = null,
    });
    try std.testing.expectEqual(@as(?u64, 120), stats.last_ordinary_context_tokens);

    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 10 }, .cost_total_usd = 0.25 },
        .spend = .{ .known_usd = 0.25 },
        .kind = .compaction,
    });
    try std.testing.expectEqual(@as(?u64, 120), stats.last_ordinary_context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), stats.spend_usd, 1e-15);
    try std.testing.expect(stats.spend_estimated);
    try std.testing.expect(!stats.has_unpriced);
}

test "unpriced token and floating spend overflow remain bounded and unreliable" {
    var stats: UsageStats = .{ .input_tokens = std.math.maxInt(u64) - 1 };
    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 10 } },
        .spend = .{ .has_unpriced = true, .estimated = true },
        .kind = .compaction,
    });
    try std.testing.expectEqual(std.math.maxInt(u64), stats.input_tokens);
    try std.testing.expect(stats.has_unpriced);
    try std.testing.expect(stats.spend_estimated);

    stats.spend_usd = std.math.floatMax(f64);
    try stats.observe(.{
        .footer = .{
            .stream = .{ .cost_usd = std.math.floatMax(f64) },
            .cost_total_usd = std.math.floatMax(f64),
        },
        .spend = .{ .known_usd = std.math.floatMax(f64) },
        .kind = .ordinary,
    });
    try std.testing.expectEqual(std.math.floatMax(f64), stats.spend_usd);
    try std.testing.expect(stats.spend_unreliable);
    try std.testing.expect(stats.spend_estimated);
}

test "known spend survives an unpriced aggregate footer" {
    const metadata: ai.ModelMeta.Metadata = .{};
    const resolution = ai.UsagePricing.resolveAttempts(
        &.{.{ .input_tokens = 10 }},
        .{ .input_tokens = 3, .cost_usd = 1 },
        null,
        &metadata,
    );
    var stats: UsageStats = .{};
    try stats.observe(.{
        .footer = resolution.footer,
        .spend = resolution.spend,
        .kind = .ordinary,
        .terminal_context_tokens = null,
    });
    try std.testing.expect(resolution.footer.cost_total_usd == null);
    try std.testing.expectEqual(@as(f64, 1), stats.spend_usd);
    try std.testing.expect(stats.has_unpriced);
    try std.testing.expect(stats.spend_estimated);
}
