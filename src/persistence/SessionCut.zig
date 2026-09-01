const std = @import("std");
const agent = @import("../agent/root.zig");
const ItemJson = @import("ItemJson.zig");

pub const default_max_file_bytes: usize = 8 * 1024 * 1024;
pub const default_max_line_bytes: usize = 8 * 1024 * 1024;
pub const default_max_tokens: usize = 262_144;
pub const default_max_nesting: usize = 64;
pub const default_max_turns: usize = 4096;

pub const Limits = struct {
    max_file_bytes: usize = default_max_file_bytes,
    max_line_bytes: usize = default_max_line_bytes,
    max_tokens: usize = default_max_tokens,
    max_nesting: usize = default_max_nesting,
    max_turns: usize = default_max_turns,
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    FileTooLarge,
    LineTooLarge,
    TooManyTokens,
    TooDeep,
    TooManyTurns,
};

pub const Fingerprint = [32]u8;

pub const Plan = struct {
    original_size: u64,
    cut_offset: u64,
    original_typed_turns: usize,
    retained_typed_turns: usize,
    retained_item_records: usize,
    original_fingerprint: Fingerprint,
    retained_fingerprint: Fingerprint,
};

const Kind = union(enum) {
    other,
    boundary,
    typed,
    tool_call: Fingerprint,
    tool_result: Fingerprint,
};

const Summary = struct {
    offset: usize,
    kind: Kind,
};

/// Decodes each accepted item only long enough to retain its cut-relevant scalar summary.
pub fn plan(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
    retained_typed_turns: usize,
    limits: Limits,
) Error!Plan {
    try validateLimits(limits);
    if (jsonl.len > limits.max_file_bytes) return error.FileTooLarge;

    const item_limits: ItemJson.Limits = .{
        .max_line_bytes = limits.max_line_bytes,
        .max_nesting = limits.max_nesting,
        .max_tokens = limits.max_tokens,
    };
    var summaries: std.ArrayList(Summary) = .empty;
    defer summaries.deinit(allocator);

    var cursor: usize = 0;
    var typed_turns: usize = 0;
    var cut_offset: ?usize = null;
    var retained_record_limit: usize = 0;
    while (cursor < jsonl.len) {
        const line_offset = cursor;
        const newline = std.mem.findScalarPos(u8, jsonl, cursor, '\n');
        const line_end = newline orelse jsonl.len;
        const line = jsonl[cursor..line_end];
        cursor = if (newline != null) line_end + 1 else jsonl.len;
        if (line.len > limits.max_line_bytes) return error.LineTooLarge;
        if (line.len == 0) continue;

        var item = ItemJson.decode(allocator, line, item_limits) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.LineTooLarge => return error.LineTooLarge,
            error.TooDeep => return error.TooDeep,
            error.TooMuchWork => return error.TooManyTokens,
            else => continue,
        };
        defer item.deinit(allocator);
        if (summaries.items.len >= limits.max_turns) return error.TooManyTurns;

        const typed_item = agent.Session.isTypedTurn(item);
        if (typed_item) {
            if (typed_turns == retained_typed_turns and cut_offset == null) {
                if (summaries.items.len != 0 and summaries.items[summaries.items.len - 1].kind == .boundary) {
                    cut_offset = summaries.items[summaries.items.len - 1].offset;
                    retained_record_limit = summaries.items.len - 1;
                } else {
                    cut_offset = line_offset;
                    retained_record_limit = summaries.items.len;
                }
            }
            typed_turns += 1;
        }
        const kind: Kind = if (typed_item)
            .typed
        else switch (item) {
            .turn_boundary => .boundary,
            .tool_call => |call| .{ .tool_call = fingerprint(call.id) },
            .tool_result => |result| .{ .tool_result = fingerprint(result.call_id) },
            else => .other,
        };
        summaries.append(allocator, .{ .offset = line_offset, .kind = kind }) catch return error.OutOfMemory;
    }

    const actual_cut = cut_offset orelse jsonl.len;
    if (cut_offset == null) retained_record_limit = summaries.items.len;
    const retained_count = try countRecovered(allocator, summaries.items[0..retained_record_limit], null);
    return .{
        .original_size = @intCast(jsonl.len),
        .cut_offset = @intCast(actual_cut),
        .original_typed_turns = typed_turns,
        .retained_typed_turns = @min(retained_typed_turns, typed_turns),
        .retained_item_records = retained_count,
        .original_fingerprint = fingerprint(jsonl),
        .retained_fingerprint = fingerprint(jsonl[0..actual_cut]),
    };
}

/// Compatibility wrapper for the legacy fork path.
pub fn findCut(
    allocator: std.mem.Allocator,
    jsonl: []const u8,
    keep_turns: usize,
    limits: Limits,
) Error!usize {
    return @intCast((try plan(allocator, jsonl, keep_turns, limits)).cut_offset);
}

fn countRecovered(
    allocator: std.mem.Allocator,
    summaries: []const Summary,
    work: ?*usize,
) error{OutOfMemory}!usize {
    var results = std.AutoHashMap(Fingerprint, void).init(allocator);
    defer results.deinit();
    for (summaries) |summary| {
        if (work) |counter| counter.* += 1;
        if (summary.kind == .tool_result) {
            results.put(summary.kind.tool_result, {}) catch return error.OutOfMemory;
        }
    }
    var count: usize = 0;
    for (summaries) |summary| {
        if (work) |counter| counter.* += 1;
        if (summary.kind == .tool_call and !results.contains(summary.kind.tool_call)) continue;
        count += 1;
    }
    return count;
}

fn fingerprint(bytes: []const u8) Fingerprint {
    var result: Fingerprint = undefined;
    std.crypto.hash.Blake3.hash(bytes, &result, .{});
    return result;
}

fn validateLimits(limits: Limits) Error!void {
    if (limits.max_file_bytes == 0 or limits.max_file_bytes > default_max_file_bytes or
        limits.max_line_bytes == 0 or limits.max_line_bytes > default_max_line_bytes or
        limits.max_line_bytes > limits.max_file_bytes or
        limits.max_tokens == 0 or limits.max_tokens > default_max_tokens or
        limits.max_nesting == 0 or limits.max_nesting > default_max_nesting or
        limits.max_turns == 0 or limits.max_turns > default_max_turns)
    {
        return error.InvalidLimits;
    }
}

const header = "{\"type\":\"session\"}\n";
const boundary = "{\"kind\":\"turn_boundary\"}\n";
const user = "{\"kind\":\"user\",\"text\":\"u\"}\n";
const assistant = "{\"kind\":\"assistant\",\"text\":\"a\"}\n";

fn offsetOf(haystack: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, haystack, needle).?;
}

test "plan fingerprints exact prefix and counts recovered item records" {
    const call = "{\"kind\":\"tool_call\",\"call_id\":\"c\",\"tool_name\":\"read\",\"arguments\":\"{}\"}\n";
    const result = "{\"kind\":\"tool_result\",\"call_id\":\"c\",\"output\":\"ok\"}\n";
    const dangling = "{\"kind\":\"tool_call\",\"call_id\":\"d\",\"tool_name\":\"read\",\"arguments\":\"{}\"}\n";
    const data = header ++ user ++ assistant ++ call ++ result ++ dangling ++ boundary ++ user;
    const value = try plan(std.testing.allocator, data, 1, .{});
    try std.testing.expectEqual(@as(u64, data.len), value.original_size);
    try std.testing.expectEqual(@as(u64, offsetOf(data, boundary)), value.cut_offset);
    try std.testing.expectEqual(@as(usize, 2), value.original_typed_turns);
    try std.testing.expectEqual(@as(usize, 1), value.retained_typed_turns);
    try std.testing.expectEqual(@as(usize, 4), value.retained_item_records);
    try std.testing.expectEqualSlices(u8, &fingerprint(data), &value.original_fingerprint);
    try std.testing.expectEqualSlices(
        u8,
        &fingerprint(data[0..@intCast(value.cut_offset)]),
        &value.retained_fingerprint,
    );
}

test "escaped tool identities match after transient decoding" {
    const call = "{\"kind\":\"tool_call\",\"call_id\":\"a\\u0062\",\"tool_name\":\"read\",\"arguments\":\"{}\"}\n";
    const result = "{\"kind\":\"tool_result\",\"call_id\":\"ab\",\"output\":\"ok\"}\n";
    const value = try plan(std.testing.allocator, header ++ user ++ call ++ result, 1, .{});
    try std.testing.expectEqual(@as(usize, 3), value.retained_item_records);
}

test "alternating unmatched calls and results recover in two linear passes" {
    var summaries: [default_max_turns]Summary = undefined;
    for (&summaries, 0..) |*summary, index| {
        var bytes: [16]u8 = undefined;
        const id = try std.fmt.bufPrint(&bytes, "id-{d}", .{index});
        const id_fingerprint = fingerprint(id);
        summary.* = .{
            .offset = index,
            .kind = if (index % 2 == 0) .{ .tool_call = id_fingerprint } else .{ .tool_result = id_fingerprint },
        };
    }
    var work: usize = 0;
    try std.testing.expectEqual(@as(usize, default_max_turns / 2), try countRecovered(
        std.testing.allocator,
        &summaries,
        &work,
    ));
    try std.testing.expectEqual(2 * summaries.len, work);
}

test "every user origin shares the public memory predicate" {
    const data = header ++
        "{\"kind\":\"user\",\"text\":\"a\",\"origin\":\"compact_seed\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"b\",\"origin\":\"continuation\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"c\",\"origin\":\"task_note\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"d\",\"origin\":\"future\"}\n" ++ user;
    const value = try plan(std.testing.allocator, data, 1, .{});
    try std.testing.expectEqual(@as(usize, 2), value.original_typed_turns);
    try std.testing.expectEqual(@as(usize, 4), value.retained_item_records);
    try std.testing.expectEqual(offsetOf(data, user), @as(usize, @intCast(value.cut_offset)));
}

test "malformed torn CRLF metadata and rich items follow loader acceptance" {
    const data = "{\"type\":\"session\"}\r\n" ++
        "{broken\n" ++
        "{\"type\":\"selection\",\"provider\":\"p\"}\n" ++
        "{\"kind\":\"user\",\"text\":\"u\",\"images\":[{\"mime\":\"image/png\",\"data\":\"AAAA\"}]}\r\n" ++
        "{\"kind\":\"reasoning\",\"text\":\"r\"}\n" ++
        "{\"kind\":\"turn_usage\",\"usage\":{}}\n" ++
        "{\"kind\":\"user\",\"text\":\"later\"}";
    const value = try plan(std.testing.allocator, data, 1, .{});
    try std.testing.expectEqual(@as(usize, 2), value.original_typed_turns);
    try std.testing.expectEqual(@as(usize, 3), value.retained_item_records);
}

test "bounds and allocation failures are explicit" {
    try std.testing.expectError(error.FileTooLarge, plan(std.testing.allocator, "12345", 0, .{
        .max_file_bytes = 4,
        .max_line_bytes = 4,
    }));
    try std.testing.expectError(error.LineTooLarge, plan(std.testing.allocator, "12345", 0, .{
        .max_file_bytes = 5,
        .max_line_bytes = 4,
    }));
    try std.testing.expectError(error.InvalidLimits, plan(std.testing.allocator, "", 0, .{ .max_turns = 0 }));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const call = "{\"kind\":\"tool_call\",\"call_id\":\"c\",\"tool_name\":\"read\",\"arguments\":\"{}\"}\n";
    const result = "{\"kind\":\"tool_result\",\"call_id\":\"c\",\"output\":\"ok\"}\n";
    _ = try plan(allocator, header ++ user ++ assistant ++ call ++ result ++ user, 1, .{});
}

test "allocation failures return without leaks" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseAllocationFailures, .{});
}
