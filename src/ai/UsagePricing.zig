const std = @import("std");
const ModelMeta = @import("ModelMeta.zig");
const Usage = @import("Usage.zig");

/// Resolve one provider-neutral usage footer before transcript admission.
/// The returned value borrows no data and performs no allocation.
pub fn resolve(
    stream_value: Usage.StreamUsage,
    elapsed_ms: ?u64,
    metadata: *const ModelMeta.Metadata,
) Usage.TurnUsage {
    var stream = stream_value;
    stream.cost_usd = validMoney(stream.cost_usd);
    var result: Usage.TurnUsage = .{
        .stream = stream,
        .elapsed_ms = elapsed_ms,
        .uncached_input_tokens = defaultUncachedInput(stream),
        .cost_total_usd = stream.cost_usd,
    };

    // As in hax, unknown token counts are priced as zero. Rates still must be
    // complete, so a cost-only response does not invent a category split.
    if (stream.input_tokens == null and stream.output_tokens == null) return result;
    const estimate = ModelMeta.estimateCost(metadata, .{
        .input = stream.input_tokens orelse 0,
        .output = stream.output_tokens orelse 0,
        .cache_read = stream.cached_tokens orelse 0,
        .cache_write = stream.cache_write_tokens orelse 0,
        .cache_write_1h = stream.cache_write_1h_tokens orelse 0,
    }) orelse return result;

    result.uncached_input_tokens = estimate.uncached_input_tokens;
    result.cost_input_usd = estimate.input;
    result.cost_cache_read_usd = estimate.cache_read;
    result.cost_cache_write_usd = estimate.cache_write;
    result.cost_output_usd = estimate.output;
    if (result.cost_total_usd == null) {
        result.cost_total_usd = estimate.total;
        result.cost_estimated = true;
    }
    return result;
}

pub const Spend = struct {
    known_usd: f64 = 0,
    has_unpriced: bool = false,
    estimated: bool = false,
    unreliable: bool = false,
};

pub const Resolution = struct {
    footer: Usage.TurnUsage,
    spend: Spend,
};

/// Resolve retry attempts and the terminal attempt independently, then fold
/// their pricing into one aggregate footer and a richer live spend observation.
pub fn resolveAttempts(
    retry_usages: []const Usage.StreamUsage,
    terminal_usage: Usage.StreamUsage,
    elapsed_ms: ?u64,
    metadata: *const ModelMeta.Metadata,
) Resolution {
    var combined_stream = terminal_usage;
    for (retry_usages) |retry_usage| Usage.add(&combined_stream, retry_usage);
    var result: Resolution = .{
        .footer = .{ .stream = combined_stream, .elapsed_ms = elapsed_ms },
        .spend = .{},
    };
    var input_cost: f64 = 0;
    var cache_read_cost: f64 = 0;
    var cache_write_cost: f64 = 0;
    var output_cost: f64 = 0;
    var uncached: u64 = 0;
    var all_priced = true;
    var all_split = true;
    var any_reported = false;

    for (0..retry_usages.len + 1) |index| {
        const stream = if (index < retry_usages.len) retry_usages[index] else terminal_usage;
        if (!Usage.usageReported(stream)) continue;
        any_reported = true;
        const priced = resolve(stream, null, metadata);
        const record_total = priced.cost_total_usd orelse {
            all_priced = false;
            all_split = false;
            result.spend.has_unpriced = true;
            result.spend.estimated = true;
            continue;
        };
        addSpend(&result.spend, record_total);
        result.spend.estimated = result.spend.estimated or priced.cost_estimated;
        uncached +|= priced.uncached_input_tokens orelse 0;
        if (priced.cost_input_usd == null or priced.cost_cache_read_usd == null or
            priced.cost_cache_write_usd == null or priced.cost_output_usd == null)
        {
            all_split = false;
            continue;
        }
        input_cost = addMoney(input_cost, priced.cost_input_usd.?) orelse {
            all_split = false;
            continue;
        };
        cache_read_cost = addMoney(cache_read_cost, priced.cost_cache_read_usd.?) orelse {
            all_split = false;
            continue;
        };
        cache_write_cost = addMoney(cache_write_cost, priced.cost_cache_write_usd.?) orelse {
            all_split = false;
            continue;
        };
        output_cost = addMoney(output_cost, priced.cost_output_usd.?) orelse {
            all_split = false;
            continue;
        };
    }
    result.footer.uncached_input_tokens = uncached;
    if (result.spend.unreliable) {
        all_priced = false;
        all_split = false;
    }
    if (any_reported and all_priced) {
        result.footer.cost_total_usd = result.spend.known_usd;
        result.footer.cost_estimated = result.spend.estimated;
    }
    if (any_reported and all_split) {
        result.footer.cost_input_usd = input_cost;
        result.footer.cost_cache_read_usd = cache_read_cost;
        result.footer.cost_cache_write_usd = cache_write_cost;
        result.footer.cost_output_usd = output_cost;
    }
    return result;
}

fn addSpend(spend: *Spend, amount: f64) void {
    const sum = spend.known_usd + amount;
    if (std.math.isFinite(sum)) {
        spend.known_usd = sum;
    } else {
        spend.known_usd = std.math.floatMax(f64);
        spend.estimated = true;
        spend.unreliable = true;
    }
}

fn addMoney(a: f64, b: f64) ?f64 {
    const sum = a + b;
    return if (std.math.isFinite(sum)) sum else null;
}

fn validMoney(value: ?f64) ?f64 {
    const amount = value orelse return null;
    return if (amount >= 0 and std.math.isFinite(amount)) amount else null;
}

/// Unknown rates use hax's common replacement policy for cache writes.
fn defaultUncachedInput(stream: Usage.StreamUsage) u64 {
    var uncached = stream.input_tokens orelse 0;
    uncached -|= stream.cached_tokens orelse 0;
    uncached -|= stream.cache_write_tokens orelse 0;
    return uncached;
}

test "pricing selects tiers strictly above their threshold" {
    const metadata: ModelMeta.Metadata = .{
        .rates = .{ .input = 1, .output = 2 },
        .tiers = try ModelMeta.Tiers.init(&.{.{
            .context_threshold = 100,
            .rates = .{ .input = 3, .output = 4 },
        }}),
    };
    const exact = resolve(.{ .input_tokens = 100 }, null, &metadata);
    const above = resolve(.{ .input_tokens = 101 }, null, &metadata);
    try std.testing.expectApproxEqAbs(0.0001, exact.cost_input_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(0.000303, above.cost_input_usd.?, 1e-15);
}

test "pricing decomposes every cache category and saturates overlaps" {
    const metadata: ModelMeta.Metadata = .{ .rates = .{
        .input = 2,
        .output = 8,
        .cache_read = 0.5,
        .cache_write = 2.5,
        .cache_write_1h = 6,
    } };
    const priced = resolve(.{
        .input_tokens = 100,
        .output_tokens = 10,
        .cached_tokens = 40,
        .cache_write_tokens = 80,
        .cache_write_1h_tokens = 20,
    }, null, &metadata);
    try std.testing.expectEqual(@as(?u64, 0), priced.uncached_input_tokens);
    try std.testing.expectApproxEqAbs(0.0, priced.cost_input_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(0.00002, priced.cost_cache_read_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(0.00027, priced.cost_cache_write_usd.?, 1e-15);
    try std.testing.expectApproxEqAbs(0.00008, priced.cost_output_usd.?, 1e-15);
    try std.testing.expect(priced.cost_estimated);
}

test "reported total wins while category estimates remain available" {
    const metadata: ModelMeta.Metadata = .{ .rates = .{ .input = 2, .output = 8 } };
    const priced = resolve(.{
        .input_tokens = 1_000_000,
        .output_tokens = 1_000_000,
        .cost_usd = 7,
    }, null, &metadata);
    try std.testing.expectEqual(@as(?f64, 7), priced.cost_total_usd);
    try std.testing.expectEqual(@as(?f64, 2), priced.cost_input_usd);
    try std.testing.expectEqual(@as(?f64, 8), priced.cost_output_usd);
    try std.testing.expect(!priced.cost_estimated);
}

test "missing and invalid rates leave token reports unpriced" {
    const cases = [_]ModelMeta.Metadata{
        .{ .rates = .{ .input = 2 } },
        .{ .rates = .{ .input = -1, .output = 8 } },
        .{ .rates = .{ .input = std.math.nan(f64), .output = 8 } },
        .{ .rates = .{ .input = std.math.inf(f64), .output = 8 } },
        .{ .rates = .{ .input = std.math.floatMax(f64), .output = 8 } },
    };
    for (cases, 0..) |metadata, index| {
        const input: u64 = if (index == cases.len - 1) std.math.maxInt(u64) else 1;
        const unpriced = resolve(.{ .input_tokens = input }, null, &metadata);
        try std.testing.expect(unpriced.cost_total_usd == null);
        try std.testing.expect(unpriced.cost_input_usd == null);
        try std.testing.expect(!unpriced.cost_estimated);
    }
}

test "invalid provider totals fall back only when valid rates can price them" {
    const priced_metadata: ModelMeta.Metadata = .{ .rates = .{ .input = 2, .output = 8 } };
    const missing_metadata: ModelMeta.Metadata = .{};
    const estimated = resolve(.{ .input_tokens = 10, .cost_usd = std.math.nan(f64) }, null, &priced_metadata);
    const unpriced = resolve(.{ .input_tokens = 10, .cost_usd = std.math.inf(f64) }, null, &missing_metadata);
    try std.testing.expect(estimated.cost_estimated);
    try std.testing.expect(estimated.cost_total_usd != null);
    try std.testing.expect(unpriced.cost_total_usd == null);
}

test "attempt spend retains known exact subtotal when another attempt is unpriced" {
    const metadata: ModelMeta.Metadata = .{};
    const forward = resolveAttempts(
        &.{
            .{ .input_tokens = 10 },
            .{ .cost_usd = 0.5 },
        },
        .{ .input_tokens = 3, .cost_usd = 1 },
        null,
        &metadata,
    );
    try std.testing.expect(forward.footer.cost_total_usd == null);
    try std.testing.expectEqual(@as(f64, 1.5), forward.spend.known_usd);
    try std.testing.expect(forward.spend.has_unpriced);
    try std.testing.expect(forward.spend.estimated);
    try std.testing.expect(!forward.spend.unreliable);

    const reverse = resolveAttempts(
        &.{
            .{ .cost_usd = 0.5 },
            .{ .input_tokens = 10 },
        },
        .{ .input_tokens = 3, .cost_usd = 1 },
        null,
        &metadata,
    );
    try std.testing.expectEqual(forward.spend, reverse.spend);
    try std.testing.expect(reverse.footer.cost_total_usd == null);
}

test "attempt spend overflow saturates and makes aggregate footer unreliable" {
    const metadata: ModelMeta.Metadata = .{};
    const resolution = resolveAttempts(
        &.{.{ .cost_usd = std.math.floatMax(f64) }},
        .{ .cost_usd = std.math.floatMax(f64) },
        null,
        &metadata,
    );
    try std.testing.expectEqual(std.math.floatMax(f64), resolution.spend.known_usd);
    try std.testing.expect(resolution.spend.unreliable);
    try std.testing.expect(resolution.spend.estimated);
    try std.testing.expect(resolution.footer.cost_total_usd == null);
}
