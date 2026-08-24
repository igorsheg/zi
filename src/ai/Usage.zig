const std = @import("std");

/// Accounting reported directly by one provider response or failed attempt.
pub const StreamUsage = struct {
    input_tokens: ?u64 = null,
    output_tokens: ?u64 = null,
    cached_tokens: ?u64 = null,
    cache_write_tokens: ?u64 = null,
    cache_write_1h_tokens: ?u64 = null,
    cost_usd: ?f64 = null,
};

/// Returns true when hax would retain this usage as a response accounting record.
/// Cache-only counters do not establish that a provider reported billable usage.
pub fn usageReported(usage: StreamUsage) bool {
    return usage.input_tokens != null or
        usage.output_tokens != null or
        usage.cost_usd != null;
}

/// Adds one provider attempt into an aggregate. Optional counters are independent:
/// a field stays null only while neither side reports it. Exact cost is retained only
/// when every side that reports input or output tokens also reports its cost.
pub fn add(sum: *StreamUsage, extra: StreamUsage) void {
    const has_unpriced_tokens = unpricedTokens(sum.*) or unpricedTokens(extra);

    inline for (.{
        "input_tokens",
        "output_tokens",
        "cached_tokens",
        "cache_write_tokens",
        "cache_write_1h_tokens",
    }) |field_name| {
        @field(sum, field_name) = addOptional(@field(sum, field_name), @field(extra, field_name));
    }

    if (has_unpriced_tokens) {
        sum.cost_usd = null;
    } else if (extra.cost_usd != null) {
        if (validCost(extra.cost_usd)) |cost| {
            const total = (validCost(sum.cost_usd) orelse 0) + cost;
            sum.cost_usd = if (std.math.isFinite(total)) total else null;
        } else {
            sum.cost_usd = null;
        }
    } else if (sum.cost_usd != null) {
        sum.cost_usd = validCost(sum.cost_usd);
    }
}

fn addOptional(sum: ?u64, extra: ?u64) ?u64 {
    const value = extra orelse return sum;
    return (sum orelse 0) +| value;
}

fn validCost(cost: ?f64) ?f64 {
    const value = cost orelse return null;
    return if (std.math.isFinite(value) and value >= 0) value else null;
}

fn unpricedTokens(usage: StreamUsage) bool {
    return validCost(usage.cost_usd) == null and
        (usage.input_tokens != null or usage.output_tokens != null);
}

/// Owned identity and routing facts recorded with one completed model request.
pub const Provenance = struct {
    provider_label: ?[]u8 = null,
    model_label: ?[]u8 = null,
    effort: ?[]u8 = null,
    served_model: ?[]u8 = null,
    route: ?[]u8 = null,
    response_id: ?[]u8 = null,

    pub fn clone(self: Provenance, allocator: std.mem.Allocator) error{OutOfMemory}!Provenance {
        var result: Provenance = .{};
        errdefer result.deinit(allocator);
        inline for (.{
            "provider_label",
            "model_label",
            "effort",
            "served_model",
            "route",
            "response_id",
        }) |field_name| {
            if (@field(self, field_name)) |value| {
                @field(result, field_name) = try allocator.dupe(u8, value);
            }
        }
        return result;
    }

    pub fn deinit(self: *Provenance, allocator: std.mem.Allocator) void {
        inline for (.{
            "provider_label",
            "model_label",
            "effort",
            "served_model",
            "route",
            "response_id",
        }) |field_name| {
            if (@field(self, field_name)) |value| allocator.free(value);
        }
        self.* = undefined;
    }
};

/// Owned footer for one model request. Optional counts and costs are unreported.
pub const TurnUsage = struct {
    stream: StreamUsage = .{},
    elapsed_ms: ?u64 = null,
    uncached_input_tokens: ?u64 = null,
    cost_input_usd: ?f64 = null,
    cost_cache_read_usd: ?f64 = null,
    cost_cache_write_usd: ?f64 = null,
    cost_output_usd: ?f64 = null,
    cost_total_usd: ?f64 = null,
    cost_estimated: bool = false,
    provenance: Provenance = .{},

    pub fn clone(self: TurnUsage, allocator: std.mem.Allocator) error{OutOfMemory}!TurnUsage {
        var result = self;
        result.provenance = try self.provenance.clone(allocator);
        return result;
    }

    pub fn deinit(self: *TurnUsage, allocator: std.mem.Allocator) void {
        self.provenance.deinit(allocator);
        self.* = undefined;
    }
};

test "turn usage owns complete response provenance" {
    const allocator = std.testing.allocator;
    var usage: TurnUsage = .{
        .stream = .{ .input_tokens = 10, .cache_write_1h_tokens = 4 },
        .elapsed_ms = 25,
        .cost_total_usd = 0.5,
        .cost_estimated = true,
        .provenance = .{
            .provider_label = try allocator.dupe(u8, "Provider"),
            .model_label = try allocator.dupe(u8, "Model"),
            .effort = try allocator.dupe(u8, "high"),
            .served_model = try allocator.dupe(u8, "served"),
            .route = try allocator.dupe(u8, "route"),
            .response_id = try allocator.dupe(u8, "response"),
        },
    };
    defer usage.deinit(allocator);

    try std.testing.expectEqual(@as(?u64, 4), usage.stream.cache_write_1h_tokens);
    try std.testing.expectEqualStrings("response", usage.provenance.response_id.?);
}

test "usage reported follows hax token and cost semantics" {
    const cases = [_]struct { usage: StreamUsage, reported: bool }{
        .{ .usage = .{}, .reported = false },
        .{ .usage = .{ .input_tokens = 0 }, .reported = true },
        .{ .usage = .{ .output_tokens = 0 }, .reported = true },
        .{ .usage = .{ .cost_usd = 0 }, .reported = true },
        .{ .usage = .{ .cached_tokens = 1 }, .reported = false },
        .{ .usage = .{ .cache_write_tokens = 1 }, .reported = false },
        .{ .usage = .{ .cache_write_1h_tokens = 1 }, .reported = false },
    };
    for (cases) |case| try std.testing.expectEqual(case.reported, usageReported(case.usage));
}

test "usage add independently sums optional counters" {
    var sum: StreamUsage = .{
        .output_tokens = 3,
        .cached_tokens = 0,
        .cache_write_1h_tokens = 7,
    };
    add(&sum, .{
        .input_tokens = 40,
        .cached_tokens = 5,
        .cache_write_tokens = 2,
    });

    try std.testing.expectEqual(@as(?u64, 40), sum.input_tokens);
    try std.testing.expectEqual(@as(?u64, 3), sum.output_tokens);
    try std.testing.expectEqual(@as(?u64, 5), sum.cached_tokens);
    try std.testing.expectEqual(@as(?u64, 2), sum.cache_write_tokens);
    try std.testing.expectEqual(@as(?u64, 7), sum.cache_write_1h_tokens);
}

test "usage add preserves exact cost only when it covers all token reports" {
    const Case = struct {
        initial: StreamUsage,
        extra: StreamUsage,
        expected_cost: ?f64,
    };
    const cases = [_]Case{
        .{
            .initial = .{ .input_tokens = 100, .output_tokens = 20, .cost_usd = 0.5 },
            .extra = .{ .input_tokens = 40 },
            .expected_cost = null,
        },
        .{
            .initial = .{ .input_tokens = 100, .output_tokens = 20, .cost_usd = 0.5 },
            .extra = .{ .input_tokens = 40, .output_tokens = 5, .cost_usd = 0.25 },
            .expected_cost = 0.75,
        },
        .{
            .initial = .{ .input_tokens = 100, .cost_usd = 0.5 },
            .extra = .{},
            .expected_cost = 0.5,
        },
        .{
            .initial = .{ .input_tokens = 80, .output_tokens = 10 },
            .extra = .{ .cost_usd = 0.25 },
            .expected_cost = null,
        },
        .{
            .initial = .{},
            .extra = .{ .cost_usd = 0 },
            .expected_cost = 0,
        },
        .{
            .initial = .{ .cost_usd = 0.5 },
            .extra = .{ .cached_tokens = 2, .cache_write_tokens = 3 },
            .expected_cost = 0.5,
        },
    };

    for (cases) |case| {
        var sum = case.initial;
        add(&sum, case.extra);
        try std.testing.expectEqual(case.expected_cost, sum.cost_usd);
    }
}

test "usage arithmetic saturates untrusted provider counters" {
    var usage: StreamUsage = .{ .input_tokens = std.math.maxInt(u64) };
    add(&usage, .{ .input_tokens = 1 });
    try std.testing.expectEqual(@as(?u64, std.math.maxInt(u64)), usage.input_tokens);
}

test "usage arithmetic drops non-finite exact costs" {
    var usage: StreamUsage = .{ .cost_usd = 1.0 };
    add(&usage, .{ .cost_usd = std.math.inf(f64) });
    try std.testing.expect(usage.cost_usd == null);
    usage = .{ .cost_usd = std.math.nan(f64) };
    add(&usage, .{});
    try std.testing.expect(usage.cost_usd == null);
}

test "negative sentinel costs are unreported" {
    var usage: StreamUsage = .{ .cost_usd = -1 };
    add(&usage, .{});
    try std.testing.expect(usage.cost_usd == null);
    usage = .{ .input_tokens = 1, .cost_usd = -1 };
    add(&usage, .{ .cost_usd = 2 });
    try std.testing.expect(usage.cost_usd == null);
}
