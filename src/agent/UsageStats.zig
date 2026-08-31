const std = @import("std");
const ai = @import("../ai/root.zig");
const Loop = @import("Loop.zig");

pub const maximum_retained_attempts: usize = 50_500;

pub const InitError = error{ OutOfMemory, InvalidCapacity };

/// Allocation-free session totals. Arithmetic saturates at the integer bounds.
pub const UsageStats = struct {
    allocator: std.mem.Allocator,
    attempts: std.ArrayList(ai.Usage.StreamUsage),
    attempt_limit: usize,
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

    /// The OneShot worst case is 100 turns, each with one ordinary request and
    /// four compaction attempts, times 101 physical transport attempts: 50,500.
    /// Capacity is allocated before any provider request; observation never allocates.
    pub fn init(allocator: std.mem.Allocator, max_attempts: usize) InitError!UsageStats {
        if (max_attempts == 0 or max_attempts > maximum_retained_attempts) return error.InvalidCapacity;
        return .{
            .allocator = allocator,
            .attempts = try std.ArrayList(ai.Usage.StreamUsage).initCapacity(allocator, max_attempts),
            .attempt_limit = max_attempts,
        };
    }

    pub fn deinit(self: *UsageStats) void {
        self.attempts.deinit(self.allocator);
        self.* = undefined;
    }

    /// Clears all conversation usage while retaining the preallocated attempt capacity.
    pub fn reset(self: *UsageStats) void {
        self.attempts.clearRetainingCapacity();
        self.input_tokens = 0;
        self.output_tokens = 0;
        self.cached_tokens = 0;
        self.cache_write_tokens = 0;
        self.cache_write_1h_tokens = 0;
        self.uncached_input_tokens = 0;
        self.spend_usd = 0;
        self.spend_estimated = false;
        self.spend_unreliable = false;
        self.has_unpriced = false;
        self.last_ordinary_context_tokens = null;
    }

    /// Invalidates only the context snapshot associated with the current branch.
    pub fn invalidateContext(self: *UsageStats) void {
        self.last_ordinary_context_tokens = null;
    }

    /// Consumes the same typed payload delivered by Loop and CompactRunner.
    pub fn observe(self: *UsageStats, observation: Loop.UsageObservation) Loop.UsageObserverError!void {
        if (observation.attempts.len > self.attempt_limit - self.attempts.items.len) {
            return error.CapacityExceeded;
        }
        self.attempts.appendSliceAssumeCapacity(observation.attempts);
        self.accountTokens(observation.footer);
        self.accountSpend(observation.spend);
        if (observation.kind == .ordinary) {
            if (observation.terminal_context_tokens) |tokens| {
                self.last_ordinary_context_tokens = tokens;
            }
        }
    }

    /// Reprices retained physical attempts after catalog metadata changes.
    /// Token totals and the latest ordinary context snapshot are unchanged.
    pub fn reprice(self: *UsageStats, metadata: *const ai.ModelMeta.Metadata) void {
        var repriced: ai.UsagePricing.Spend = .{};
        for (self.attempts.items) |attempt| {
            const resolution = ai.UsagePricing.resolveAttempts(&.{}, attempt, null, metadata);
            mergeSpend(&repriced, resolution.spend);
        }
        self.spend_usd = repriced.known_usd;
        self.has_unpriced = repriced.has_unpriced;
        self.spend_estimated = repriced.estimated;
        self.spend_unreliable = repriced.unreliable;
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

fn mergeSpend(total: *ai.UsagePricing.Spend, extra: ai.UsagePricing.Spend) void {
    const sum = total.known_usd + extra.known_usd;
    if (std.math.isFinite(sum)) {
        total.known_usd = sum;
    } else {
        total.known_usd = std.math.floatMax(f64);
        total.unreliable = true;
        total.estimated = true;
    }
    total.has_unpriced = total.has_unpriced or extra.has_unpriced;
    total.estimated = total.estimated or extra.estimated;
    total.unreliable = total.unreliable or extra.unreliable;
}

test "observation uses terminal ordinary context rather than aggregate retry context" {
    var stats = try UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    try stats.observe(.{
        .footer = .{
            .stream = .{ .input_tokens = 141, .output_tokens = 20 },
            .uncached_input_tokens = 121,
            .cost_total_usd = 1.5,
        },
        .spend = .{ .known_usd = 1.5 },
        .attempts = &.{.{ .input_tokens = 141, .output_tokens = 20, .cost_usd = 1.5 }},
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
        .attempts = &.{.{ .input_tokens = 40, .output_tokens = 5, .cost_usd = 0.5 }},
        .kind = .ordinary,
        .terminal_context_tokens = null,
    });
    try std.testing.expectEqual(@as(?u64, 120), stats.last_ordinary_context_tokens);

    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 10 }, .cost_total_usd = 0.25 },
        .spend = .{ .known_usd = 0.25 },
        .attempts = &.{.{ .input_tokens = 10, .cost_usd = 0.25 }},
        .kind = .compaction,
    });
    try std.testing.expectEqual(@as(?u64, 120), stats.last_ordinary_context_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 2.25), stats.spend_usd, 1e-15);
    try std.testing.expect(stats.spend_estimated);
    try std.testing.expect(!stats.has_unpriced);
}

test "unpriced token and floating spend overflow remain bounded and unreliable" {
    var stats = try UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    stats.input_tokens = std.math.maxInt(u64) - 1;
    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 10 } },
        .spend = .{ .has_unpriced = true, .estimated = true },
        .attempts = &.{.{ .input_tokens = 10 }},
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
        .attempts = &.{.{ .cost_usd = std.math.floatMax(f64) }},
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
    var stats = try UsageStats.init(std.testing.allocator, 16);
    defer stats.deinit();
    const attempts = [_]ai.Usage.StreamUsage{
        .{ .input_tokens = 10 },
        .{ .input_tokens = 3, .cost_usd = 1 },
    };
    try stats.observe(.{
        .footer = resolution.footer,
        .spend = resolution.spend,
        .attempts = &attempts,
        .kind = .ordinary,
        .terminal_context_tokens = null,
    });
    try std.testing.expect(resolution.footer.cost_total_usd == null);
    try std.testing.expectEqual(@as(f64, 1), stats.spend_usd);
    try std.testing.expect(stats.has_unpriced);
    try std.testing.expect(stats.spend_estimated);
}

test "reprice applies nonlinear tiers and cache rates to retained physical attempts" {
    var stats = try UsageStats.init(std.testing.allocator, 4);
    defer stats.deinit();
    const attempts = [_]ai.Usage.StreamUsage{
        .{ .input_tokens = 200, .cached_tokens = 100 },
        .{ .input_tokens = 100, .cost_usd = 1 },
    };
    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 300 }, .cost_total_usd = null },
        .spend = .{ .known_usd = 1, .has_unpriced = true, .estimated = true },
        .attempts = &attempts,
        .kind = .ordinary,
        .terminal_context_tokens = 100,
    });
    const input_before = stats.input_tokens;
    const context_before = stats.last_ordinary_context_tokens;
    const metadata: ai.ModelMeta.Metadata = .{
        .rates = .{ .input = 1, .output = 1, .cache_read = 0.5 },
        .tiers = try ai.ModelMeta.Tiers.init(&.{.{
            .context_threshold = 150,
            .rates = .{ .input = 3, .cache_read = 1 },
        }}),
    };
    stats.reprice(&metadata);
    try std.testing.expectApproxEqAbs(1.0004, stats.spend_usd, 1e-15);
    try std.testing.expect(!stats.has_unpriced);
    try std.testing.expect(stats.spend_estimated);
    try std.testing.expectEqual(input_before, stats.input_tokens);
    try std.testing.expectEqual(context_before, stats.last_ordinary_context_tokens);
}

test "reset clears totals and attempts while retaining capacity" {
    var stats = try UsageStats.init(std.testing.allocator, 4);
    defer stats.deinit();
    try stats.observe(.{
        .footer = .{
            .stream = .{
                .input_tokens = 10,
                .output_tokens = 2,
                .cached_tokens = 3,
                .cache_write_tokens = 4,
                .cache_write_1h_tokens = 5,
            },
            .uncached_input_tokens = 7,
        },
        .spend = .{ .known_usd = 1, .has_unpriced = true, .estimated = true, .unreliable = true },
        .attempts = &.{.{ .input_tokens = 10 }},
        .kind = .ordinary,
        .terminal_context_tokens = 9,
    });
    const capacity = stats.attempts.capacity;

    stats.reset();

    try std.testing.expectEqual(@as(usize, 0), stats.attempts.items.len);
    try std.testing.expectEqual(capacity, stats.attempts.capacity);
    try std.testing.expectEqual(@as(u64, 0), stats.input_tokens);
    try std.testing.expectEqual(@as(u64, 0), stats.output_tokens);
    try std.testing.expectEqual(@as(u64, 0), stats.cached_tokens);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_write_tokens);
    try std.testing.expectEqual(@as(u64, 0), stats.cache_write_1h_tokens);
    try std.testing.expectEqual(@as(u64, 0), stats.uncached_input_tokens);
    try std.testing.expectEqual(@as(f64, 0), stats.spend_usd);
    try std.testing.expect(!stats.spend_estimated);
    try std.testing.expect(!stats.spend_unreliable);
    try std.testing.expect(!stats.has_unpriced);
    try std.testing.expect(stats.last_ordinary_context_tokens == null);
}

test "invalidate context preserves cumulative usage" {
    var stats = try UsageStats.init(std.testing.allocator, 2);
    defer stats.deinit();
    try stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 10 }, .cost_total_usd = 1 },
        .spend = .{ .known_usd = 1 },
        .attempts = &.{.{ .input_tokens = 10, .cost_usd = 1 }},
        .kind = .ordinary,
        .terminal_context_tokens = 9,
    });

    stats.invalidateContext();

    try std.testing.expectEqual(@as(usize, 1), stats.attempts.items.len);
    try std.testing.expectEqual(@as(u64, 10), stats.input_tokens);
    try std.testing.expectEqual(@as(f64, 1), stats.spend_usd);
    try std.testing.expect(stats.last_ordinary_context_tokens == null);
}

test "capacity failure leaves retained attempts and totals unchanged" {
    var stats = try UsageStats.init(std.testing.allocator, 1);
    defer stats.deinit();
    const attempts = [_]ai.Usage.StreamUsage{
        .{ .input_tokens = 1 },
        .{ .output_tokens = 1 },
    };
    try std.testing.expectError(error.CapacityExceeded, stats.observe(.{
        .footer = .{ .stream = .{ .input_tokens = 1, .output_tokens = 1 } },
        .spend = .{ .known_usd = 2 },
        .attempts = &attempts,
        .kind = .ordinary,
        .terminal_context_tokens = 2,
    }));
    try std.testing.expectEqual(@as(usize, 0), stats.attempts.items.len);
    try std.testing.expectEqual(@as(u64, 0), stats.input_tokens);
    try std.testing.expectEqual(@as(f64, 0), stats.spend_usd);
    try std.testing.expect(stats.last_ordinary_context_tokens == null);
}

test "init reports allocation failure and rejects unusable capacity" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, UsageStats.init(failing.allocator(), 1));
    try std.testing.expectError(error.InvalidCapacity, UsageStats.init(std.testing.allocator, 0));
    try std.testing.expectError(
        error.InvalidCapacity,
        UsageStats.init(std.testing.allocator, maximum_retained_attempts + 1),
    );
}
