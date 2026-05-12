const std = @import("std");
const store = @import("store.zig");
const storage = @import("../../storage.zig");

pub const Target = union(enum) {
    most_recent,
    reference: []const u8,
};

pub const Diagnostic = union(enum) {
    lookup_failed: []const u8,
    no_recent_session,
    not_found: []const u8,
    ambiguous: []const u8,
};

pub const Resolution = union(enum) {
    ok: []const u8,
    err: Diagnostic,
};

pub fn resolvePath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    target: Target,
) std.mem.Allocator.Error!Resolution {
    const session_dir = storage.getSessionDirForCwd(allocator, cwd, null) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .lookup_failed = @errorName(err) } },
    };
    defer allocator.free(session_dir);
    return resolvePathInDir(allocator, cwd, session_dir, target);
}

fn resolvePathInDir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    session_dir: []const u8,
    target: Target,
) std.mem.Allocator.Error!Resolution {
    return switch (target) {
        .most_recent => resolveMostRecentPathInDir(allocator, session_dir),
        .reference => |ref| resolveReferencePathInDir(allocator, cwd, session_dir, ref),
    };
}

fn resolveMostRecentPathInDir(
    allocator: std.mem.Allocator,
    session_dir: []const u8,
) std.mem.Allocator.Error!Resolution {
    const path = store.findMostRecentSessionInDir(allocator, session_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .lookup_failed = @errorName(err) } },
    };
    return .{ .ok = path orelse return .{ .err = .no_recent_session } };
}

fn resolveReferencePathInDir(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    session_dir: []const u8,
    ref: []const u8,
) std.mem.Allocator.Error!Resolution {
    if (looksLikeSessionPath(ref)) {
        return resolveExplicitPath(allocator, cwd, ref);
    }

    const sessions = store.listSessionsInDir(allocator, session_dir) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .err = .{ .lookup_failed = @errorName(err) } },
    };
    defer store.freeSessionInfos(allocator, sessions);

    var matched_path: ?[]const u8 = null;
    var match_count: usize = 0;
    for (sessions) |session| {
        if (!std.mem.startsWith(u8, session.session_id, ref)) continue;
        matched_path = session.path;
        match_count += 1;
        if (match_count > 1) break;
    }

    if (match_count == 0) return .{ .err = .{ .not_found = ref } };
    if (match_count > 1) return .{ .err = .{ .ambiguous = ref } };
    return .{ .ok = try allocator.dupe(u8, matched_path.?) };
}

fn resolveExplicitPath(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    ref: []const u8,
) std.mem.Allocator.Error!Resolution {
    if (std.fs.path.isAbsolute(ref)) {
        return try resolveAbsolutePath(allocator, ref, ref);
    }

    const joined = try std.fs.path.join(allocator, &.{ cwd, ref });
    defer allocator.free(joined);
    return try resolveAbsolutePath(allocator, joined, ref);
}

fn resolveAbsolutePath(
    allocator: std.mem.Allocator,
    path: []const u8,
    display_ref: []const u8,
) std.mem.Allocator.Error!Resolution {
    const resolved_z = std.Io.Dir.realPathFileAbsoluteAlloc(std.Options.debug_io, path, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .{ .err = .{ .not_found = display_ref } },
        else => return .{ .err = .{ .lookup_failed = @errorName(err) } },
    };
    defer allocator.free(resolved_z);
    return .{ .ok = try allocator.dupe(u8, resolved_z) };
}

fn looksLikeSessionPath(ref: []const u8) bool {
    return std.fs.path.isAbsolute(ref) or
        std.mem.indexOfScalar(u8, ref, '/') != null or
        std.mem.indexOfScalar(u8, ref, '\\') != null or
        std.mem.endsWith(u8, ref, ".jsonl");
}

fn writeSessionFile(dir: std.Io.Dir, sub_path: []const u8, session_id: []const u8) !void {
    const content = try std.fmt.allocPrint(
        std.testing.allocator,
        "{{\"type\":\"session\",\"id\":\"{s}\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}}\n" ++
            "{{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}}}\n",
        .{session_id},
    );
    defer std.testing.allocator.free(content);

    try dir.writeFile(std.Options.debug_io, .{
        .sub_path = sub_path,
        .data = content,
    });
}

test "resolvePath picks the most recent valid session file in a directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first_name = "first.jsonl";
    try writeSessionFile(tmp.dir, first_name, "session-old");
    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(2 * std.time.ns_per_ms)), .awake) catch {};
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "invalid.jsonl", .data = "not json\n" });
    std.Options.debug_io.sleep(.fromNanoseconds(@intCast(2 * std.time.ns_per_ms)), .awake) catch {};
    const second_name = "second.jsonl";
    try writeSessionFile(tmp.dir, second_name, "session-new");

    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try tmp.dir.realPathFileAlloc(std.Options.debug_io, second_name, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    const resolved = try resolvePathInDir(std.testing.allocator, cwd, cwd, .most_recent);
    switch (resolved) {
        .ok => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings(expected, path);
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "resolvePath resolves explicit path references relative to cwd and reports missing files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const file_name = "named-session.jsonl";
    try writeSessionFile(tmp.dir, file_name, "session-path");

    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try tmp.dir.realPathFileAlloc(std.Options.debug_io, file_name, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    const resolved = try resolvePathInDir(std.testing.allocator, cwd, cwd, .{ .reference = file_name });
    switch (resolved) {
        .ok => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings(expected, path);
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const missing = try resolvePathInDir(std.testing.allocator, cwd, cwd, .{ .reference = "missing.jsonl" });
    switch (missing) {
        .err => |diag| switch (diag) {
            .not_found => |ref| try std.testing.expectEqualStrings("missing.jsonl", ref),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

test "resolvePath resolves local session id prefixes and rejects ambiguous matches" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const first_name = "alpha.jsonl";
    const second_name = "beta.jsonl";
    try writeSessionFile(tmp.dir, first_name, "abcdef01");
    try writeSessionFile(tmp.dir, second_name, "abc99999");

    const cwd = try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
    defer std.testing.allocator.free(cwd);
    const expected = try tmp.dir.realPathFileAlloc(std.Options.debug_io, first_name, std.testing.allocator);
    defer std.testing.allocator.free(expected);

    const resolved = try resolvePathInDir(std.testing.allocator, cwd, cwd, .{ .reference = "abcdef" });
    switch (resolved) {
        .ok => |path| {
            defer std.testing.allocator.free(path);
            try std.testing.expectEqualStrings(expected, path);
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const ambiguous = try resolvePathInDir(std.testing.allocator, cwd, cwd, .{ .reference = "abc" });
    switch (ambiguous) {
        .err => |diag| switch (diag) {
            .ambiguous => |ref| try std.testing.expectEqualStrings("abc", ref),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}
