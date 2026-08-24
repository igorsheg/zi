const std = @import("std");
const SessionIndex = @import("SessionIndex.zig");

pub const Selector = union(enum) {
    latest,
    id: []const u8,
};

pub const Result = union(enum) {
    found: usize,
    not_found,
    ambiguous,
};

/// Resolves a selector against the mtime-ordered session index without
/// allocating. A `.found` value indexes `entries`.
pub fn resolve(entries: []const SessionIndex.Entry, selector: Selector) Result {
    return switch (selector) {
        .latest => if (entries.len == 0) .not_found else .{ .found = 0 },
        .id => |id| resolveId(entries, id),
    };
}

fn resolveId(entries: []const SessionIndex.Entry, requested: []const u8) Result {
    for (entries, 0..) |entry, index| {
        const id = entry.id orelse continue;
        if (std.mem.eql(u8, id, requested)) return .{ .found = index };
    }

    var match: ?usize = null;
    for (entries, 0..) |entry, index| {
        const id = entry.id orelse continue;
        if (!std.mem.startsWith(u8, id, requested)) continue;
        if (match != null) return .ambiguous;
        match = index;
    }
    return if (match) |index| .{ .found = index } else .not_found;
}

fn testEntry(name: []u8, id: ?[]u8) SessionIndex.Entry {
    return .{
        .name = name,
        .path = name,
        .id = id,
        .mtime_nanoseconds = 0,
        .meta = .{},
    };
}

test "latest selects index zero including a nonstandard entry" {
    var entries = [_]SessionIndex.Entry{
        testEntry(@constCast("custom.jsonl"), null),
        testEntry(@constCast("standard.jsonl"), @constCast("abcd")),
    };
    const expected: Result = .{ .found = 0 };
    try std.testing.expectEqual(expected, resolve(&entries, .latest));
    try std.testing.expectEqual(Result.not_found, resolve(&.{}, .latest));
}

test "exact id wins before prefix matching" {
    var entries = [_]SessionIndex.Entry{
        testEntry(@constCast("long"), @constCast("abcde")),
        testEntry(@constCast("exact"), @constCast("abc")),
    };
    const expected: Result = .{ .found = 1 };
    try std.testing.expectEqual(expected, resolve(&entries, .{ .id = "abc" }));
}

test "id matching is case-sensitive and distinguishes ambiguous and missing" {
    var entries = [_]SessionIndex.Entry{
        testEntry(@constCast("first"), @constCast("Alpha-one")),
        testEntry(@constCast("second"), @constCast("Alpha-two")),
        testEntry(@constCast("third"), null),
    };
    const expected: Result = .{ .found = 0 };
    try std.testing.expectEqual(expected, resolve(&entries, .{ .id = "Alpha-o" }));
    try std.testing.expectEqual(Result.ambiguous, resolve(&entries, .{ .id = "Alpha-" }));
    try std.testing.expectEqual(Result.not_found, resolve(&entries, .{ .id = "alpha" }));
    try std.testing.expectEqual(Result.not_found, resolve(&entries, .{ .id = "missing" }));
}
