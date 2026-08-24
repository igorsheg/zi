const std = @import("std");
const Effort = @import("Effort.zig");
const Wire = @import("Wire.zig").Wire;

pub const maximum_tiers: usize = 4;

/// A provider capability can be absent from metadata, explicitly unsupported,
/// or explicitly supported.
pub const Support = enum {
    unknown,
    no,
    yes,
};

/// USD per million tokens. `null` means that the rate is unknown.
pub const Rates = struct {
    input: ?f64 = null,
    output: ?f64 = null,
    cache_read: ?f64 = null,
    cache_write: ?f64 = null,
    cache_write_1h: ?f64 = null,
};

pub const Tier = struct {
    /// This tier applies only when total input is strictly greater than this value.
    context_threshold: u64,
    rates: Rates = .{},
};

pub const TierError = error{
    InvalidThreshold,
    TooManyTiers,
};

/// A bounded, allocation-free tier list. `known` distinguishes an absent list
/// from an explicitly empty list.
pub const Tiers = struct {
    known: bool = false,
    count: u8 = 0,
    values: [maximum_tiers]Tier = undefined,

    pub fn init(values: []const Tier) TierError!Tiers {
        var result: Tiers = .{ .known = true };
        for (values) |value| try result.add(value);
        return result;
    }

    pub fn add(self: *Tiers, value: Tier) TierError!void {
        self.known = true;
        if (value.context_threshold == 0) return error.InvalidThreshold;
        if (self.count >= maximum_tiers) return error.TooManyTiers;
        self.values[self.count] = value;
        self.count += 1;
    }

    pub fn at(self: *const Tiers, index: usize) Tier {
        std.debug.assert(index < self.count);
        return self.values[index];
    }
};

/// The only Chat Completions fields hax round-trips for interleaved reasoning.
pub const ReasoningField = enum {
    reasoning,
    reasoning_content,
};

/// `none` is a declared-off hint. It must not fall back to a lower-priority
/// catalog hint. `unknown` may fall back.
pub const ReasoningRoundtrip = union(enum) {
    unknown,
    none,
    field: ReasoningField,
};

/// Provider-neutral model facts. All storage is inline or enum-valued.
pub const Metadata = struct {
    /// Token limits use zero for unknown, matching hax.
    context_window: u64 = 0,
    max_output: u64 = 0,
    image_input: Support = .unknown,
    tools: Support = .unknown,
    efforts: Effort.Set = .{},
    wire: ?Wire = null,
    reasoning_roundtrip: ReasoningRoundtrip = .unknown,
    rates: Rates = .{},
    tiers: Tiers = .{},
};

/// Merge provider-reported facts over catalog facts. Either source may be
/// absent. Lists replace whole lists. Provider base rates cannot be combined
/// with tiers from a different billing source.
pub fn merge(reported: ?*const Metadata, catalog: ?*const Metadata) Metadata {
    var result: Metadata = if (reported) |value| value.* else .{};
    const fallback = catalog orelse return result;

    if (result.context_window == 0) result.context_window = fallback.context_window;
    if (result.max_output == 0) result.max_output = fallback.max_output;
    if (result.image_input == .unknown) result.image_input = fallback.image_input;
    if (result.tools == .unknown) result.tools = fallback.tools;
    if (!result.efforts.known) result.efforts = fallback.efforts;
    if (result.wire == null) result.wire = fallback.wire;
    if (result.reasoning_roundtrip == .unknown) {
        result.reasoning_roundtrip = fallback.reasoning_roundtrip;
    }

    fillUnknownRates(&result.rates, fallback.rates);

    if (!result.tiers.known) {
        if (reportedHasBaseRates(reported)) {
            // A declared empty list records the cross-source tier barrier.
            result.tiers = .{ .known = true };
        } else {
            result.tiers = fallback.tiers;
        }
    }
    return result;
}

/// Resolve the provider's actual categorical vocabulary. Provider reports win
/// over catalog metadata and may extend the provider ladder. Catalog metadata
/// can only narrow it. The result is always known, including known-empty.
pub fn resolveEfforts(
    provider_ladder: *const Effort.Set,
    reported: *const Effort.Set,
    catalog: *const Effort.Set,
) Effort.Set {
    var result: Effort.Set = .{ .known = true };
    if (!provider_ladder.known or provider_ladder.count == 0) return result;

    const accepted = if (reported.known) reported else catalog;
    if (!accepted.known) return provider_ladder.*;
    if (accepted.count == 0) return result;

    for (0..provider_ladder.count) |index| {
        const value = provider_ladder.valueAt(index);
        if (accepted.has(value)) result.add(value) catch unreachable;
    }

    if (reported.known) {
        for (0..accepted.count) |index| {
            result.add(accepted.valueAt(index)) catch unreachable;
        }
    }
    return result;
}

pub const CacheWriteMode = enum {
    /// Cache writes replace the ordinary input charge for those tokens.
    replacement,
    /// Cache writes are an extra storage surcharge on ordinary input.
    surcharge,
};

/// A known write rate below input is a surcharge. Unknown rates use hax's more
/// common replacement policy.
pub fn cacheWriteMode(rates: Rates) CacheWriteMode {
    const input_rate = rates.input orelse return .replacement;
    const write_rate = rates.cache_write orelse return .replacement;
    if (!validRate(input_rate) or !validRate(write_rate)) return .replacement;
    return if (write_rate < input_rate) .surcharge else .replacement;
}

pub const TokenCounts = struct {
    input: u64 = 0,
    output: u64 = 0,
    /// Cache reads and writes are subsets of input. Providers can still report
    /// overlapping counts; uncached input saturates at zero.
    cache_read: u64 = 0,
    cache_write: u64 = 0,
    /// This is a subset of `cache_write` and is clamped to it.
    cache_write_1h: u64 = 0,
};

pub const Estimate = struct {
    total: f64,
    input: f64,
    cache_read: f64,
    cache_write: f64,
    output: f64,
    uncached_input_tokens: u64,
};

/// Estimate one request in USD. Returns `null` unless base input and output
/// rates are known and every effective rate and intermediate cost is finite.
pub fn estimateCost(metadata: *const Metadata, tokens: TokenCounts) ?Estimate {
    const rates = ratesForInput(metadata, tokens.input);
    const input_rate = checkedRate(rates.input) orelse return null;
    const output_rate = checkedRate(rates.output) orelse return null;
    const cache_read_rate = checkedRate(rates.cache_read orelse input_rate) orelse return null;
    const mode = cacheWriteMode(rates);
    const cache_write_rate = checkedRate(rates.cache_write orelse input_rate) orelse return null;
    const default_1h_rate = input_rate * 2.0;
    if (!std.math.isFinite(default_1h_rate)) return null;
    const cache_write_1h_rate = checkedRate(rates.cache_write_1h orelse default_1h_rate) orelse return null;

    const cache_write_1h = @min(tokens.cache_write_1h, tokens.cache_write);
    var charged_input = tokens.input;
    charged_input -|= tokens.cache_read;
    if (mode == .replacement) charged_input -|= tokens.cache_write;

    const ordinary_write_tokens = tokens.cache_write - cache_write_1h;
    const input_cost = tokenCost(charged_input, input_rate) orelse return null;
    const cache_read_cost = tokenCost(tokens.cache_read, cache_read_rate) orelse return null;
    const ordinary_write_cost = tokenCost(ordinary_write_tokens, cache_write_rate) orelse return null;
    const one_hour_write_cost = tokenCost(cache_write_1h, cache_write_1h_rate) orelse return null;
    const cache_write_cost = addFinite(ordinary_write_cost, one_hour_write_cost) orelse return null;
    const output_cost = tokenCost(tokens.output, output_rate) orelse return null;
    var total = addFinite(input_cost, cache_read_cost) orelse return null;
    total = addFinite(total, cache_write_cost) orelse return null;
    total = addFinite(total, output_cost) orelse return null;

    return .{
        .total = total,
        .input = input_cost,
        .cache_read = cache_read_cost,
        .cache_write = cache_write_cost,
        .output = output_cost,
        .uncached_input_tokens = charged_input,
    };
}

/// Select the highest positive threshold strictly exceeded by total input.
/// Unknown fields in that tier fall back to base rates.
pub fn ratesForInput(metadata: *const Metadata, input_tokens: u64) Rates {
    var selected = metadata.rates;
    var matched_threshold: u64 = 0;
    for (0..metadata.tiers.count) |index| {
        const tier = metadata.tiers.at(index);
        if (input_tokens <= tier.context_threshold or tier.context_threshold <= matched_threshold) continue;
        matched_threshold = tier.context_threshold;
        selected = withBaseFallback(tier.rates, metadata.rates);
    }
    return selected;
}

fn fillUnknownRates(destination: *Rates, fallback: Rates) void {
    if (destination.input == null) destination.input = fallback.input;
    if (destination.output == null) destination.output = fallback.output;
    if (destination.cache_read == null) destination.cache_read = fallback.cache_read;
    if (destination.cache_write == null) destination.cache_write = fallback.cache_write;
    if (destination.cache_write_1h == null) destination.cache_write_1h = fallback.cache_write_1h;
}

fn withBaseFallback(overrides: Rates, base: Rates) Rates {
    var result = overrides;
    fillUnknownRates(&result, base);
    return result;
}

fn reportedHasBaseRates(reported: ?*const Metadata) bool {
    const value = reported orelse return false;
    return value.rates.input != null or value.rates.output != null;
}

fn validRate(value: f64) bool {
    return value >= 0 and std.math.isFinite(value);
}

fn checkedRate(value: ?f64) ?f64 {
    const rate = value orelse return null;
    return if (validRate(rate)) rate else null;
}

fn tokenCost(tokens: u64, rate: f64) ?f64 {
    const cost = @as(f64, @floatFromInt(tokens)) * rate / 1_000_000.0;
    return if (std.math.isFinite(cost)) cost else null;
}

fn addFinite(a: f64, b: f64) ?f64 {
    const sum = a + b;
    return if (std.math.isFinite(sum)) sum else null;
}

test "tier storage is bounded and rejects unusable thresholds" {
    const empty = try Tiers.init(&.{});
    try std.testing.expect(empty.known);
    try std.testing.expectEqual(@as(u8, 0), empty.count);

    var tiers: Tiers = .{};
    try std.testing.expectError(error.InvalidThreshold, tiers.add(.{ .context_threshold = 0 }));
    for (1..maximum_tiers + 1) |threshold| {
        try tiers.add(.{ .context_threshold = threshold });
    }
    try std.testing.expectEqual(@as(u8, maximum_tiers), tiers.count);
    try std.testing.expectError(error.TooManyTiers, tiers.add(.{ .context_threshold = 9 }));
}

test "metadata merge is fieldwise and preserves explicit negative facts" {
    const reported: Metadata = .{
        .context_window = 32_000,
        .image_input = .no,
        .efforts = try Effort.Set.init(&.{}),
        .reasoning_roundtrip = .none,
        .rates = .{ .input = 3, .cache_write = 3.75 },
    };
    const catalog: Metadata = .{
        .context_window = 64_000,
        .max_output = 8_192,
        .image_input = .yes,
        .tools = .yes,
        .efforts = try Effort.Set.init(&.{ "low", "high" }),
        .wire = .openai_responses,
        .reasoning_roundtrip = .{ .field = .reasoning_content },
        .rates = .{ .input = 2, .output = 8, .cache_read = 0.5, .cache_write_1h = 6 },
        .tiers = try Tiers.init(&.{.{ .context_threshold = 200_000 }}),
    };

    const result = merge(&reported, &catalog);
    try std.testing.expectEqual(@as(u64, 32_000), result.context_window);
    try std.testing.expectEqual(@as(u64, 8_192), result.max_output);
    try std.testing.expectEqual(Support.no, result.image_input);
    try std.testing.expectEqual(Support.yes, result.tools);
    try std.testing.expect(result.efforts.known);
    try std.testing.expectEqual(@as(u8, 0), result.efforts.count);
    try std.testing.expectEqual(Wire.openai_responses, result.wire.?);
    try std.testing.expect(result.reasoning_roundtrip == .none);
    try std.testing.expectEqual(@as(f64, 3), result.rates.input.?);
    try std.testing.expectEqual(@as(f64, 8), result.rates.output.?);
    try std.testing.expectEqual(@as(f64, 0.5), result.rates.cache_read.?);
    try std.testing.expectEqual(@as(f64, 3.75), result.rates.cache_write.?);
    try std.testing.expectEqual(@as(f64, 6), result.rates.cache_write_1h.?);
    try std.testing.expect(result.tiers.known);
    try std.testing.expectEqual(@as(u8, 0), result.tiers.count);
}

test "metadata merge copies catalog tiers only when billing sources are compatible" {
    const catalog: Metadata = .{
        .tiers = try Tiers.init(&.{.{ .context_threshold = 200_000, .rates = .{ .input = 4 } }}),
    };
    const no_report_rates: Metadata = .{ .rates = .{ .cache_read = 0.2 } };
    const compatible = merge(&no_report_rates, &catalog);
    try std.testing.expectEqual(@as(u8, 1), compatible.tiers.count);

    const report_tiers: Metadata = .{
        .rates = .{ .input = 3 },
        .tiers = try Tiers.init(&.{.{ .context_threshold = 99_999, .rates = .{ .input = 6 } }}),
    };
    const reported_wins = merge(&report_tiers, &catalog);
    try std.testing.expectEqual(@as(u8, 1), reported_wins.tiers.count);
    try std.testing.expectEqual(@as(u64, 99_999), reported_wins.tiers.at(0).context_threshold);

    const only_catalog = merge(null, &catalog);
    try std.testing.expectEqual(@as(u8, 1), only_catalog.tiers.count);
    const only_report = merge(&report_tiers, null);
    try std.testing.expectEqual(@as(u64, 99_999), only_report.tiers.at(0).context_threshold);
}

test "effort resolution preserves provider order and source widening rules" {
    const provider = try Effort.Set.init(&.{ "none", "low", "medium", "high", "xhigh" });
    const unknown: Effort.Set = .{};
    const fallback = resolveEfforts(&provider, &unknown, &unknown);
    try std.testing.expectEqual(@as(u8, 5), fallback.count);
    try std.testing.expectEqualStrings("none", fallback.valueAt(0));

    const reported = try Effort.Set.init(&.{ "max", "high", "medium", "low" });
    const report_result = resolveEfforts(&provider, &reported, &unknown);
    try std.testing.expectEqual(@as(u8, 4), report_result.count);
    try std.testing.expectEqualStrings("low", report_result.valueAt(0));
    try std.testing.expectEqualStrings("max", report_result.valueAt(3));

    const catalog = try Effort.Set.init(&.{ "minimal", "low", "high" });
    const catalog_result = resolveEfforts(&provider, &unknown, &catalog);
    try std.testing.expectEqual(@as(u8, 2), catalog_result.count);
    try std.testing.expectEqualStrings("low", catalog_result.valueAt(0));
    try std.testing.expectEqualStrings("high", catalog_result.valueAt(1));
}

test "effort resolution honors known empty and providers without a sender" {
    const provider = try Effort.Set.init(&.{ "low", "high" });
    const empty = try Effort.Set.init(&.{});
    const unknown: Effort.Set = .{};
    const removed = resolveEfforts(&provider, &empty, &unknown);
    try std.testing.expect(removed.known);
    try std.testing.expectEqual(@as(u8, 0), removed.count);

    const no_sender = try Effort.Set.init(&.{});
    const reported = try Effort.Set.init(&.{"low"});
    const unavailable = resolveEfforts(&no_sender, &reported, &unknown);
    try std.testing.expect(unavailable.known);
    try std.testing.expectEqual(@as(u8, 0), unavailable.count);

    const unknown_sender: Effort.Set = .{};
    const unavailable_unknown = resolveEfforts(&unknown_sender, &reported, &unknown);
    try std.testing.expect(unavailable_unknown.known);
    try std.testing.expectEqual(@as(u8, 0), unavailable_unknown.count);
}

test "pricing selects highest strictly exceeded tier with base field fallback" {
    const metadata: Metadata = .{
        .rates = .{ .input = 2, .output = 8, .cache_read = 0.5, .cache_write = 2.5 },
        .tiers = try Tiers.init(&.{
            .{ .context_threshold = 800_000, .rates = .{ .input = 6 } },
            .{ .context_threshold = 200_000, .rates = .{ .input = 4, .output = 16, .cache_read = 1 } },
        }),
    };

    const exact = ratesForInput(&metadata, 200_000);
    try std.testing.expectEqual(@as(f64, 2), exact.input.?);
    const middle = ratesForInput(&metadata, 300_000);
    try std.testing.expectEqual(@as(f64, 4), middle.input.?);
    try std.testing.expectEqual(@as(f64, 16), middle.output.?);
    try std.testing.expectEqual(@as(f64, 2.5), middle.cache_write.?);
    const highest = ratesForInput(&metadata, 1_000_000);
    try std.testing.expectEqual(@as(f64, 6), highest.input.?);
    try std.testing.expectEqual(@as(f64, 8), highest.output.?);
}

test "estimated cost matches hax cache accounting" {
    const metadata: Metadata = .{
        .rates = .{
            .input = 2,
            .output = 8,
            .cache_read = 0.5,
            .cache_write = 2.5,
        },
    };
    const basic = estimateCost(&metadata, .{ .input = 1_000_000, .output = 1_000_000 }).?;
    try std.testing.expectEqual(@as(f64, 10), basic.total);

    const cached = estimateCost(&metadata, .{
        .input = 1_000_000,
        .cache_read = 500_000,
        .cache_write = 250_000,
        .cache_write_1h = 100_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1.525), cached.total, 1e-12);
    try std.testing.expectEqual(@as(u64, 250_000), cached.uncached_input_tokens);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), cached.input, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), cached.cache_read, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.775), cached.cache_write, 1e-12);
}

test "cache write surcharge retains ordinary input and one hour count is bounded" {
    const surcharge: Metadata = .{
        .rates = .{ .input = 1.1, .output = 4.4, .cache_read = 0.2, .cache_write = 0.375 },
    };
    try std.testing.expectEqual(CacheWriteMode.surcharge, cacheWriteMode(surcharge.rates));
    const cost = estimateCost(&surcharge, .{
        .input = 7_047,
        .cache_read = 3_524,
        .cache_write = 3_524,
    }).?;
    try std.testing.expectEqual(@as(u64, 3_523), cost.uncached_input_tokens);
    try std.testing.expectApproxEqAbs(3_523 * 1.1 / 1e6, cost.input, 1e-12);
    try std.testing.expectApproxEqAbs(3_524 * 0.375 / 1e6, cost.cache_write, 1e-12);

    const replacement: Metadata = .{
        .rates = .{ .input = 2, .output = 8, .cache_write = 3.75, .cache_write_1h = 6 },
    };
    try std.testing.expectEqual(CacheWriteMode.replacement, cacheWriteMode(replacement.rates));
    const clamped = estimateCost(&replacement, .{
        .input = 1_000_000,
        .cache_write = 100_000,
        .cache_write_1h = 200_000,
    }).?;
    try std.testing.expectApproxEqAbs(@as(f64, 2.4), clamped.total, 1e-12);
}

test "estimated cost rejects missing invalid and nonfinite rates safely" {
    const missing: Metadata = .{ .rates = .{ .input = 2 } };
    try std.testing.expect(estimateCost(&missing, .{}) == null);

    const negative: Metadata = .{ .rates = .{ .input = -1, .output = 8 } };
    try std.testing.expect(estimateCost(&negative, .{}) == null);
    const nan: Metadata = .{ .rates = .{ .input = std.math.nan(f64), .output = 8 } };
    try std.testing.expect(estimateCost(&nan, .{}) == null);
    const infinite: Metadata = .{ .rates = .{ .input = std.math.inf(f64), .output = 8 } };
    try std.testing.expect(estimateCost(&infinite, .{}) == null);

    const overflow: Metadata = .{ .rates = .{ .input = std.math.floatMax(f64), .output = 1 } };
    try std.testing.expect(estimateCost(&overflow, .{ .input = std.math.maxInt(u64) }) == null);
}

test "token subtraction saturates for overlapping provider counts" {
    const metadata: Metadata = .{ .rates = .{ .input = 2, .output = 8 } };
    const estimate = estimateCost(&metadata, .{
        .input = 10,
        .cache_read = std.math.maxInt(u64),
        .cache_write = std.math.maxInt(u64),
    }).?;
    try std.testing.expectEqual(@as(u64, 0), estimate.uncached_input_tokens);
    try std.testing.expect(std.math.isFinite(estimate.total));
}
