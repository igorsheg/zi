const std = @import("std");

pub const maximum_json_bytes: usize = 256 * 1024;
pub const maximum_depth: usize = 64;
pub const maximum_fields: usize = 4096;
pub const maximum_work: usize = 16 * 1024;
pub const maximum_string_bytes: usize = 4096;

pub const Limits = struct {
    max_json_bytes: usize = maximum_json_bytes,
    max_depth: usize = maximum_depth,
    max_fields: usize = maximum_fields,
    max_work: usize = maximum_work,
    max_string_bytes: usize = maximum_string_bytes,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    JsonTooLarge,
    InvalidJson,
    TooDeep,
    TooManyFields,
    TooMuchWork,
    StringTooLarge,
};

/// One Codex rate-limit window. A null field means that the server omitted it
/// or explicitly sent JSON null. `reset_at` follows hax's conversion of a JSON
/// number to whole Unix seconds by truncating toward zero.
pub const Window = struct {
    used_percent: ?f64 = null,
    reset_at: ?i64 = null,
    limit_window_seconds: ?i64 = null,
};

pub const Windows = struct {
    primary: ?Window = null,
    secondary: ?Window = null,
};

/// Preserves whether the outer rate-limit object was reported. Hax renders a
/// missing or null outer value differently from a reported object with no windows.
pub const RateLimit = union(enum) {
    absent,
    reported: Windows,
};

/// Owned data from Codex's `/backend-api/wham/usage` response.
pub const Usage = struct {
    plan_type: ?[]u8 = null,
    rate_limit: RateLimit = .absent,

    pub fn deinit(self: *Usage, allocator: std.mem.Allocator) void {
        if (self.plan_type) |value| allocator.free(value);
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, json: []const u8, limits: Limits) Error!Usage {
    try validateLimits(limits);
    if (json.len > limits.max_json_bytes) return error.JsonTooLarge;
    if (json.len == 0) return error.InvalidJson;
    try scanBounds(allocator, json, limits);

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{
        .duplicate_field_behavior = .use_last,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidJson,
    };
    defer parsed.deinit();
    var result: Usage = .{};
    if (parsed.value != .object) return result;
    errdefer result.deinit(allocator);
    const root = parsed.value.object;
    if (root.get("plan_type")) |value| switch (value) {
        .null => {},
        .string => |plan_type| {
            if (plan_type.len > limits.max_string_bytes) return error.StringTooLarge;
            result.plan_type = try allocator.dupe(u8, plan_type);
        },
        else => {},
    };

    if (root.get("rate_limit")) |rate_limit| switch (rate_limit) {
        .null => {},
        .object => |object| {
            result.rate_limit = .{ .reported = .{
                .primary = parseOptionalWindow(object.get("primary_window")),
                .secondary = parseOptionalWindow(object.get("secondary_window")),
            } };
        },
        else => result.rate_limit = .{ .reported = .{} },
    };
    return result;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_json_bytes == 0 or limits.max_json_bytes > maximum_json_bytes or
        limits.max_depth == 0 or limits.max_depth > maximum_depth or
        limits.max_fields == 0 or limits.max_fields > maximum_fields or
        limits.max_work == 0 or limits.max_work > maximum_work or
        limits.max_string_bytes == 0 or limits.max_string_bytes > maximum_string_bytes)
    {
        return error.InvalidLimits;
    }
}

fn scanBounds(allocator: std.mem.Allocator, json: []const u8, limits: Limits) Error!void {
    var scanner = std.json.Scanner.initCompleteInput(allocator, json);
    defer scanner.deinit();
    var depth: usize = 0;
    var fields: usize = 0;
    var work: usize = 0;
    while (true) {
        const token = scanner.nextAllocMax(
            allocator,
            .alloc_if_needed,
            limits.max_string_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ValueTooLong => return error.StringTooLarge,
            else => return error.InvalidJson,
        };
        defer switch (token) {
            .allocated_string => |value| allocator.free(value),
            .allocated_number => |value| allocator.free(value),
            else => {},
        };
        work += 1;
        if (work > limits.max_work) return error.TooMuchWork;
        switch (token) {
            .object_begin, .array_begin => {
                depth += 1;
                if (depth > limits.max_depth) return error.TooDeep;
            },
            .object_end, .array_end => {
                if (depth == 0) return error.InvalidJson;
                depth -= 1;
            },
            .number => |value| {
                const number = std.fmt.parseFloat(f64, value) catch return error.InvalidJson;
                if (!std.math.isFinite(number)) return error.InvalidJson;
            },
            .allocated_number => |value| {
                const number = std.fmt.parseFloat(f64, value) catch return error.InvalidJson;
                if (!std.math.isFinite(number)) return error.InvalidJson;
            },
            .string => |value| {
                if (value.len > limits.max_string_bytes) return error.StringTooLarge;
                if (scanner.string_is_object_key) {
                    fields += 1;
                    if (fields > limits.max_fields) return error.TooManyFields;
                }
            },
            .allocated_string => |value| {
                if (value.len > limits.max_string_bytes) return error.StringTooLarge;
                if (scanner.string_is_object_key) {
                    fields += 1;
                    if (fields > limits.max_fields) return error.TooManyFields;
                }
            },
            .end_of_document => if (depth == 0) return else return error.InvalidJson,
            else => {},
        }
    }
}

fn parseOptionalWindow(value: ?std.json.Value) ?Window {
    const present = value orelse return null;
    return switch (present) {
        .null => null,
        .object => |object| .{
            .used_percent = optionalFiniteNumber(object.get("used_percent")),
            .reset_at = optionalTimestamp(object.get("reset_at")),
            .limit_window_seconds = optionalInteger(object.get("limit_window_seconds")),
        },
        else => .{},
    };
}

fn optionalFiniteNumber(value: ?std.json.Value) ?f64 {
    const present = value orelse return null;
    const number: f64 = switch (present) {
        .integer => |integer| @floatFromInt(integer),
        .float => |float| float,
        else => return null,
    };
    return if (std.math.isFinite(number)) number else null;
}

fn optionalTimestamp(value: ?std.json.Value) ?i64 {
    const number = optionalFiniteNumber(value) orelse return null;
    const minimum: f64 = @floatFromInt(std.math.minInt(i64));
    const upper_exclusive: f64 = 0x1p63;
    if (number < minimum or number >= upper_exclusive) return null;
    return @intFromFloat(number);
}

fn optionalInteger(value: ?std.json.Value) ?i64 {
    const present = value orelse return null;
    return if (present == .integer) present.integer else null;
}

test "normal usage response owns plan and both windows" {
    const allocator = std.testing.allocator;
    const json =
        "{\"plan_type\":\"plus\",\"rate_limit\":{" ++
        "\"primary_window\":{\"used_percent\":12.5,\"reset_at\":1730000000.9," ++
        "\"limit_window_seconds\":18000},\"secondary_window\":{" ++
        "\"used_percent\":42,\"reset_at\":1730100000,\"limit_window_seconds\":604800}}}";
    var usage = try parse(allocator, json, .{});
    defer usage.deinit(allocator);

    try std.testing.expectEqualStrings("plus", usage.plan_type.?);
    try std.testing.expectEqual(@as(?f64, 12.5), usage.rate_limit.reported.primary.?.used_percent);
    try std.testing.expectEqual(@as(?i64, 1_730_000_000), usage.rate_limit.reported.primary.?.reset_at);
    try std.testing.expectEqual(@as(?i64, 18_000), usage.rate_limit.reported.primary.?.limit_window_seconds);
    try std.testing.expectEqual(@as(?f64, 42), usage.rate_limit.reported.secondary.?.used_percent);
}

test "null and missing values preserve outer rate-limit absence" {
    const allocator = std.testing.allocator;
    for ([_][]const u8{
        "{}",
        \\{"plan_type":null,"rate_limit":null}
        ,
    }) |json| {
        var usage = try parse(allocator, json, .{});
        defer usage.deinit(allocator);
        try std.testing.expect(usage.plan_type == null);
        try std.testing.expect(usage.rate_limit == .absent);
    }
    var reported = try parse(allocator,
        \\{"rate_limit":{"primary_window":null}}
    , .{});
    defer reported.deinit(allocator);
    try std.testing.expect(reported.rate_limit == .reported);
    try std.testing.expect(reported.rate_limit.reported.primary == null);
    try std.testing.expect(reported.rate_limit.reported.secondary == null);
}

test "partial window retains independently reported fields" {
    var usage = try parse(std.testing.allocator,
        \\{"rate_limit":{"primary_window":{"used_percent":null,"reset_at":-1},"secondary_window":{}}}
    , .{});
    defer usage.deinit(std.testing.allocator);
    try std.testing.expect(usage.rate_limit.reported.primary != null);
    try std.testing.expect(usage.rate_limit.reported.primary.?.used_percent == null);
    try std.testing.expectEqual(@as(?i64, -1), usage.rate_limit.reported.primary.?.reset_at);
    try std.testing.expect(usage.rate_limit.reported.secondary != null);
}

test "usage treats wrong-shaped recognized fields as absent or unrecognized like hax" {
    inline for (.{
        "1",
        "{\"plan_type\":1}",
        "{\"rate_limit\":[]}",
        "{\"rate_limit\":{\"primary_window\":\"no\"}}",
        "{\"rate_limit\":{\"primary_window\":{\"used_percent\":\"12\"}}}",
        "{\"rate_limit\":{\"primary_window\":{\"reset_at\":9.223372036854776e18}}}",
        "{\"rate_limit\":{\"primary_window\":{\"limit_window_seconds\":1.5}}}",
    }) |json| {
        var usage = try parse(std.testing.allocator, json, .{});
        usage.deinit(std.testing.allocator);
    }
    var primitive_rate = try parse(std.testing.allocator, "{\"rate_limit\":true}", .{});
    defer primitive_rate.deinit(std.testing.allocator);
    try std.testing.expect(primitive_rate.rate_limit == .reported);

    try std.testing.expectError(error.InvalidJson, parse(std.testing.allocator, "{", .{}));
    try std.testing.expectError(
        error.InvalidJson,
        parse(std.testing.allocator, "{\"used_percent\":1e999}", .{}),
    );
}

test "unknown fields are ignored but all input remains bounded" {
    var usage = try parse(std.testing.allocator,
        \\{"unknown":{"nested":[1,true,null]},"rate_limit":{"other":"ok","primary_window":{"extra":3}}}
    , .{});
    defer usage.deinit(std.testing.allocator);
    try std.testing.expect(usage.rate_limit.reported.primary != null);

    try std.testing.expectError(error.JsonTooLarge, parse(std.testing.allocator, "{}", .{ .max_json_bytes = 1 }));
    try std.testing.expectError(error.TooDeep, parse(std.testing.allocator, "[[[]]]", .{ .max_depth = 2 }));
    try std.testing.expectError(error.TooManyFields, parse(std.testing.allocator,
        \\{"a":1,"b":2}
    , .{ .max_fields = 1 }));
    try std.testing.expectError(error.TooMuchWork, parse(std.testing.allocator, "[1]", .{ .max_work = 2 }));
    try std.testing.expectError(error.StringTooLarge, parse(std.testing.allocator,
        \\{"x":"long"}
    , .{ .max_string_bytes = 3 }));
}

test "allocation failure is reported without leaking" {
    var storage: [1]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, parse(fixed.allocator(),
        \\{"plan_type":"plus"}
    , .{}));
}
