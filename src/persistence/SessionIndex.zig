const std = @import("std");
const ItemJson = @import("ItemJson.zig");
const Paths = @import("Paths.zig");
const SessionFile = @import("SessionFile.zig");

pub const default_max_scan_entries: usize = 4096;
pub const default_max_results: usize = 4096;

pub const Limits = struct {
    max_scan_entries: usize = default_max_scan_entries,
    max_results: usize = default_max_results,
    max_buckets: usize = default_max_scan_entries,
    max_entries_total: usize = default_max_scan_entries,
    max_path_bytes: usize = Paths.default_max_path_bytes,
    session_file: SessionFile.Limits = .{},
};

pub const Recovery = struct {
    noncanonical: usize = 0,
    nonregular: usize = 0,
    unreadable: usize = 0,
    busy: usize = 0,
    malformed: usize = 0,
    pruned: usize = 0,
    busy_kept: usize = 0,
};

pub const Entry = struct {
    name: []u8,
    path: []u8,
    id: ?[]u8,
    mtime_nanoseconds: i96,
    meta: SessionFile.Meta,

    pub fn deinit(self: *Entry, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        if (self.id) |id| allocator.free(id);
        self.meta.deinit(allocator);
        self.* = undefined;
    }
};

pub const Index = struct {
    entries: []Entry,
    recovery: Recovery,

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        for (self.entries) |*entry| entry.deinit(allocator);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

pub const PruneReport = struct {
    buckets: usize = 0,
    scanned: usize = 0,
    candidates: usize = 0,
    recovery: Recovery = .{},
};

pub const Error = error{
    OutOfMemory,
    InvalidLimits,
    InvalidPath,
    PathTooLong,
    TooManyBuckets,
    TooManyEntries,
    TooManyResults,
    IoFailure,
};

/// The state root and every existing parent component are a trusted private
/// boundary. The final bucket is opened without following a symlink. Entries
/// are then opened without following final symlinks. Stream payload metadata
/// is owned by the returned Index.
pub fn list(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    cwd: []const u8,
    cutoff_epoch_seconds: i64,
    limits: Limits,
) Error!Index {
    try validateLimits(limits);
    const directory_path = Paths.sessionDirectory(allocator, state_root, cwd, pathLimits(limits)) catch |err|
        return mapPathError(err);
    defer allocator.free(directory_path);

    var result: Index = .{ .entries = &.{}, .recovery = .{} };
    var entries: std.ArrayList(Entry) = .empty;
    errdefer {
        for (entries.items) |*entry| entry.deinit(allocator);
        entries.deinit(allocator);
    }

    const directory = openBucket(io, directory_path) catch |err| switch (err) {
        error.FileNotFound => return result,
        else => return error.IoFailure,
    };
    defer directory.close(io);

    var iterator = directory.iterate();
    var scanned: usize = 0;
    while (iterator.next(io) catch return error.IoFailure) |directory_entry| {
        scanned += 1;
        if (scanned > limits.max_scan_entries) return error.TooManyEntries;
        if (!std.mem.endsWith(u8, directory_entry.name, ".jsonl")) continue;
        const standard = isHaxStandardName(directory_entry.name);
        if (!standard) result.recovery.noncanonical += 1;
        const stat = directory.statFile(io, directory_entry.name, .{ .follow_symlinks = false }) catch {
            result.recovery.unreadable += 1;
            continue;
        };
        if (stat.kind != .file or stat.nlink == 0) {
            result.recovery.nonregular += 1;
            continue;
        }
        if (standard and cutoff_epoch_seconds != 0) {
            const cutoff_ns = std.math.mul(i96, cutoff_epoch_seconds, std.time.ns_per_s) catch
                if (cutoff_epoch_seconds < 0)
                    @as(i96, std.math.minInt(i96))
                else
                    @as(i96, std.math.maxInt(i96));
            if (stat.mtime.nanoseconds < cutoff_ns) continue;
        }

        const path = try joinPath(
            allocator,
            directory_path,
            directory_entry.name,
            limits.max_path_bytes,
        );
        errdefer allocator.free(path);
        var session_limits = limits.session_file;
        session_limits.paths = pathLimits(limits);
        var meta = SessionFile.readMetaAt(
            allocator,
            io,
            directory,
            directory_entry.name,
            session_limits,
        ) catch |err| meta_recovery: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            switch (err) {
                error.OutOfMemory => unreachable,
                error.SessionBusy => result.recovery.busy += 1,
                error.NotRegular, error.Removed => result.recovery.nonregular += 1,
                error.InvalidHeader,
                error.UnsupportedVersion,
                error.FileTooLarge,
                error.LineTooLarge,
                error.TooManyItems,
                error.ResourceLimit,
                => result.recovery.malformed += 1,
                else => result.recovery.unreadable += 1,
            }
            break :meta_recovery SessionFile.Meta{};
        };
        errdefer meta.deinit(allocator);
        if (entries.items.len >= limits.max_results) return error.TooManyResults;
        const name = allocator.dupe(u8, directory_entry.name) catch return error.OutOfMemory;
        errdefer allocator.free(name);
        const id = if (standard)
            allocator.dupe(u8, directory_entry.name[21..57]) catch return error.OutOfMemory
        else
            null;
        errdefer if (id) |value| allocator.free(value);
        entries.append(allocator, .{
            .name = name,
            .path = path,
            .id = id,
            .mtime_nanoseconds = stat.mtime.nanoseconds,
            .meta = meta,
        }) catch return error.OutOfMemory;
    }

    std.mem.sort(Entry, entries.items, {}, entryDescending);
    result.entries = entries.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return result;
}

/// Prunes canonical sessions older than `cutoff_epoch_seconds` from every
/// bucket below `<state_root>/sessions`. Existing parents are a trusted
/// private boundary. No uncoordinated writer may replace bucket entries while
/// pruning. Both bucket directories and session files are opened without
/// following their final symlink. Marker election and background
/// scheduling belong to a higher layer.
pub fn pruneBefore(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    cutoff_epoch_seconds: i64,
    exclude_path: ?[]const u8,
    limits: Limits,
) Error!PruneReport {
    try validateLimits(limits);
    if (exclude_path) |path| try validateAbsolutePath(path, limits.max_path_bytes);
    const sessions_path = try sessionsDirectory(allocator, state_root, limits.max_path_bytes);
    defer allocator.free(sessions_path);
    const cutoff_nanoseconds = std.math.mul(i96, cutoff_epoch_seconds, std.time.ns_per_s) catch
        if (cutoff_epoch_seconds < 0)
            @as(i96, std.math.minInt(i96))
        else
            @as(i96, std.math.maxInt(i96));

    var report: PruneReport = .{};
    const sessions = openBucket(io, sessions_path) catch |err| switch (err) {
        error.FileNotFound => return report,
        else => return error.IoFailure,
    };
    defer sessions.close(io);
    var buckets = sessions.iterate();
    while (buckets.next(io) catch return error.IoFailure) |bucket_entry| {
        report.buckets += 1;
        if (report.buckets > limits.max_buckets) return error.TooManyBuckets;
        const bucket_stat = sessions.statFile(io, bucket_entry.name, .{ .follow_symlinks = false }) catch {
            report.recovery.unreadable += 1;
            continue;
        };
        if (bucket_stat.kind != .directory) {
            report.recovery.nonregular += 1;
            continue;
        }
        {
            const bucket = sessions.openDir(io, bucket_entry.name, .{
                .iterate = true,
                .follow_symlinks = false,
            }) catch {
                report.recovery.unreadable += 1;
                continue;
            };
            defer bucket.close(io);
            var entries = bucket.iterate();
            while (entries.next(io) catch return error.IoFailure) |entry| {
                report.scanned += 1;
                if (report.scanned > limits.max_entries_total) return error.TooManyEntries;
                if (!isHaxStandardName(entry.name)) {
                    report.recovery.noncanonical += 1;
                    continue;
                }
                const observed = bucket.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                if (observed.kind != .file or observed.nlink == 0) {
                    report.recovery.nonregular += 1;
                    continue;
                }
                if (observed.mtime.nanoseconds >= cutoff_nanoseconds) continue;
                report.candidates += 1;
                if (exclude_path) |excluded| {
                    if (pathMatches(excluded, sessions_path, bucket_entry.name, entry.name)) continue;
                }
                const file = bucket.openFile(io, entry.name, .{
                    .mode = .read_only,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                defer file.close(io);
                const locked = file.tryLock(io, .exclusive) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                if (!locked) {
                    report.recovery.busy += 1;
                    report.recovery.busy_kept += 1;
                    continue;
                }
                const locked_stat = file.stat(io) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                if (locked_stat.kind != .file or locked_stat.nlink == 0 or
                    locked_stat.inode != observed.inode or
                    locked_stat.mtime.nanoseconds >= cutoff_nanoseconds)
                {
                    report.recovery.nonregular += 1;
                    continue;
                }
                const named_stat = bucket.statFile(io, entry.name, .{ .follow_symlinks = false }) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                if (named_stat.kind != .file or named_stat.nlink == 0 or
                    named_stat.inode != locked_stat.inode or
                    named_stat.mtime.nanoseconds >= cutoff_nanoseconds)
                {
                    report.recovery.nonregular += 1;
                    continue;
                }
                bucket.deleteFile(io, entry.name) catch {
                    report.recovery.unreadable += 1;
                    continue;
                };
                report.recovery.pruned += 1;
            }
        }
        sessions.deleteDir(io, bucket_entry.name) catch |err| switch (err) {
            error.DirNotEmpty => {},
            else => report.recovery.unreadable += 1,
        };
    }
    return report;
}

fn validateAbsolutePath(path: []const u8, max_path_bytes: usize) Error!void {
    if (path.len > max_path_bytes) return error.PathTooLong;
    if (path.len == 0 or path[0] != '/' or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path))
    {
        return error.InvalidPath;
    }
}

fn sessionsDirectory(
    allocator: std.mem.Allocator,
    state_root: []const u8,
    max_path_bytes: usize,
) Error![]u8 {
    try validateAbsolutePath(state_root, max_path_bytes);
    var root_len = state_root.len;
    while (root_len > 1 and state_root[root_len - 1] == '/') root_len -= 1;
    const separator_len: usize = if (root_len == 1) 0 else 1;
    const size = std.math.add(usize, root_len, separator_len + "sessions".len) catch
        return error.PathTooLong;
    if (size > max_path_bytes) return error.PathTooLong;
    const result = allocator.alloc(u8, size) catch return error.OutOfMemory;
    var cursor = root_len;
    @memcpy(result[0..root_len], state_root[0..root_len]);
    if (separator_len != 0) {
        result[cursor] = '/';
        cursor += 1;
    }
    @memcpy(result[cursor..], "sessions");
    return result;
}

fn pathMatches(
    path: []const u8,
    sessions_path: []const u8,
    bucket: []const u8,
    name: []const u8,
) bool {
    const size = std.math.add(usize, sessions_path.len, bucket.len + name.len + 2) catch return false;
    if (path.len != size or !std.mem.eql(u8, path[0..sessions_path.len], sessions_path)) return false;
    var cursor = sessions_path.len;
    if (path[cursor] != '/') return false;
    cursor += 1;
    if (!std.mem.eql(u8, path[cursor..][0..bucket.len], bucket)) return false;
    cursor += bucket.len;
    if (path[cursor] != '/') return false;
    cursor += 1;
    return std.mem.eql(u8, path[cursor..], name);
}

fn validateLimits(limits: Limits) Error!void {
    const session = limits.session_file;
    const json = session.item_json;
    if (limits.max_scan_entries == 0 or limits.max_scan_entries > default_max_scan_entries or
        limits.max_results == 0 or limits.max_results > limits.max_scan_entries or
        limits.max_buckets == 0 or limits.max_buckets > default_max_scan_entries or
        limits.max_entries_total == 0 or limits.max_entries_total > default_max_scan_entries or
        limits.max_path_bytes == 0 or limits.max_path_bytes > Paths.hard_max_bytes or
        session.max_file_bytes == 0 or session.max_file_bytes > 8 * 1024 * 1024 or
        session.max_line_bytes == 0 or session.max_line_bytes > session.max_file_bytes or
        session.max_items == 0 or session.max_items > 4096 or session.retained_bytes == 0 or
        session.retained_bytes > 64 * 1024 * 1024 or session.max_images == 0 or
        session.max_images > 4096 or session.max_image_base64_bytes == 0 or
        session.max_image_base64_bytes > 256 * 1024 * 1024 or
        session.paths.max_cwd_bytes == 0 or session.paths.max_cwd_bytes > Paths.hard_max_bytes or
        json.max_line_bytes == 0 or json.max_line_bytes > ItemJson.default_max_line_bytes or
        json.max_nesting == 0 or json.max_nesting > ItemJson.default_max_nesting or
        json.max_fields == 0 or json.max_fields > ItemJson.default_max_fields or
        json.max_tokens == 0 or json.max_tokens > ItemJson.default_max_tokens)
    {
        return error.InvalidLimits;
    }
}

fn pathLimits(limits: Limits) Paths.Limits {
    var value = limits.session_file.paths;
    value.max_path_bytes = limits.max_path_bytes;
    return value;
}

fn openBucket(io: std.Io, path: []const u8) std.Io.Dir.OpenError!std.Io.Dir {
    return std.Io.Dir.openDir(.cwd(), io, path, .{
        .iterate = true,
        .follow_symlinks = false,
    });
}

fn joinPath(
    allocator: std.mem.Allocator,
    directory: []const u8,
    name: []const u8,
    max_path_bytes: usize,
) Error![]u8 {
    const size = std.math.add(usize, directory.len, name.len + 1) catch return error.PathTooLong;
    if (size > max_path_bytes) return error.PathTooLong;
    const path = allocator.alloc(u8, size) catch return error.OutOfMemory;
    @memcpy(path[0..directory.len], directory);
    path[directory.len] = '/';
    @memcpy(path[directory.len + 1 ..], name);
    return path;
}

fn mapPathError(err: Paths.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.PathTooLong, error.CwdTooLong => error.PathTooLong,
        error.InvalidLimits => error.InvalidLimits,
        else => error.InvalidPath,
    };
}

fn entryDescending(_: void, left: Entry, right: Entry) bool {
    if (left.mtime_nanoseconds != right.mtime_nanoseconds)
        return left.mtime_nanoseconds > right.mtime_nanoseconds;
    return std.mem.order(u8, left.path, right.path) == .gt;
}

fn isHaxStandardName(name: []const u8) bool {
    if (name.len != Paths.canonical_name_bytes or name[20] != '_' or
        !std.mem.eql(u8, name[57..], ".jsonl")) return false;
    const shape = "dddd-dd-ddTdd-dd-ddZ";
    for (shape, name[0..shape.len]) |expected, actual| {
        if (expected == 'd') {
            if (!std.ascii.isDigit(actual)) return false;
        } else if (expected != actual) return false;
    }
    for (name[21..57], 0..) |byte, index| {
        if (index == 8 or index == 13 or index == 18 or index == 23) {
            if (byte != '-') return false;
        } else if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn testName(epoch: i64, suffix: u8) ![Paths.canonical_name_bytes]u8 {
    var uuid = [_]u8{
        0x55, 0x0e, 0x84, 0x00, 0xe2, 0x9b, 0x41, 0xd4,
        0xa7, 0x16, 0x44, 0x66, 0x55, 0x44, 0x00, 0x00,
    };
    uuid[15] = suffix;
    return Paths.canonicalNameFromEpoch(epoch, uuid);
}

fn writeTestSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: []const u8,
    name: []const u8,
    model: []const u8,
) !void {
    const path = try joinPath(allocator, directory, name, Paths.default_max_path_bytes);
    defer allocator.free(path);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    try output.writer.print(
        "{{\"type\":\"session\",\"id\":\"id\",\"model\":\"old\"}}\n" ++
            "{{\"type\":\"selection\",\"model\":\"{s}\"}}\n",
        .{model},
    );
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = path, .data = output.written() });
}

fn makeTestDirectory(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    cwd: []const u8,
) ![]u8 {
    const directory = try Paths.sessionDirectory(allocator, state_root, cwd, .{});
    errdefer allocator.free(directory);
    try std.Io.Dir.createDirPath(.cwd(), io, directory);
    return directory;
}

test "list uses mtime order, retains nonstandard jsonl, and filters expired standard sessions" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(state_root);
    const directory = try makeTestDirectory(allocator, io, state_root, "/work");
    defer allocator.free(directory);

    const older = try testName(0, 1);
    const newer_low = try testName(1, 1);
    const newer_high = try testName(1, 2);
    try writeTestSession(allocator, io, directory, &older, "older");
    try writeTestSession(allocator, io, directory, &newer_low, "low");
    try writeTestSession(allocator, io, directory, &newer_high, "high");
    const junk_path = try joinPath(allocator, directory, "junk.jsonl", Paths.default_max_path_bytes);
    defer allocator.free(junk_path);
    try std.Io.Dir.writeFile(.cwd(), io, .{ .sub_path = junk_path, .data = "junk" });
    const directory_name = try testName(2, 3);
    const canonical_dir_path = try joinPath(
        allocator,
        directory,
        &directory_name,
        Paths.default_max_path_bytes,
    );
    defer allocator.free(canonical_dir_path);
    try std.Io.Dir.createDir(.cwd(), io, canonical_dir_path, .default_dir);
    const link_name = try testName(3, 4);
    const link_path = try joinPath(allocator, directory, &link_name, Paths.default_max_path_bytes);
    defer allocator.free(link_path);
    try std.Io.Dir.symLink(.cwd(), io, &older, link_path, .{});
    const bucket = try std.Io.Dir.openDir(.cwd(), io, directory, .{});
    defer bucket.close(io);
    try setTestMtime(io, bucket, &older, 100);
    try setTestMtime(io, bucket, &newer_low, 200);
    try setTestMtime(io, bucket, &newer_high, 200);
    try setTestMtime(io, bucket, "junk.jsonl", 50);

    var index = try list(allocator, io, state_root, "/work", 0, .{});
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 4), index.entries.len);
    try std.testing.expectEqualStrings(&newer_high, index.entries[0].name);
    try std.testing.expectEqualStrings(&newer_low, index.entries[1].name);
    try std.testing.expectEqualStrings(&older, index.entries[2].name);
    try std.testing.expectEqualStrings("junk.jsonl", index.entries[3].name);
    try std.testing.expectEqualStrings("high", index.entries[0].meta.selection.model.?);
    try std.testing.expect(index.entries[0].id != null);
    try std.testing.expect(index.entries[3].id == null);
    try std.testing.expectEqual(@as(usize, 1), index.recovery.noncanonical);
    try std.testing.expectEqual(@as(usize, 2), index.recovery.nonregular);

    var retained = try list(allocator, io, state_root, "/work", 150, .{});
    defer retained.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), retained.entries.len);
    try std.testing.expectEqualStrings("junk.jsonl", retained.entries[2].name);

    var missing = try list(allocator, io, state_root, "/missing", 0, .{});
    defer missing.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), missing.entries.len);
    try std.testing.expectError(
        error.TooManyEntries,
        list(allocator, io, state_root, "/work", 0, .{ .max_scan_entries = 1, .max_results = 1 }),
    );
}

fn setTestMtime(io: std.Io, directory: std.Io.Dir, name: []const u8, seconds: i64) !void {
    const file = try directory.openFile(io, name, .{ .mode = .read_write });
    defer file.close(io);
    try file.setTimestamps(io, .{
        .modify_timestamp = .{ .new = .fromNanoseconds(@as(i96, seconds) * std.time.ns_per_s) },
    });
}

test "prune before uses strict cutoff, exclusion, locks, and two-level nofollow traversal" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(state_root);
    const bucket_path = try makeTestDirectory(allocator, io, state_root, "/work");
    defer allocator.free(bucket_path);
    const old = try testName(0, 1);
    const equal = try testName(1, 1);
    const newer = try testName(2, 1);
    const excluded = try testName(3, 1);
    const busy = try testName(4, 1);
    try writeTestSession(allocator, io, bucket_path, &old, "old");
    try writeTestSession(allocator, io, bucket_path, &equal, "equal");
    try writeTestSession(allocator, io, bucket_path, &newer, "new");
    try writeTestSession(allocator, io, bucket_path, &excluded, "excluded");
    try writeTestSession(allocator, io, bucket_path, &busy, "busy");
    const liberal = "9999-99-99T99-99-99Z_00000000-0000-0000-0000-000000000000.jsonl";
    try writeTestSession(allocator, io, bucket_path, liberal, "liberal");
    const bucket = try std.Io.Dir.openDir(.cwd(), io, bucket_path, .{ .follow_symlinks = false });
    defer bucket.close(io);
    try setTestMtime(io, bucket, &old, 99);
    try setTestMtime(io, bucket, &equal, 100);
    try setTestMtime(io, bucket, &newer, 101);
    try setTestMtime(io, bucket, &excluded, 99);
    try setTestMtime(io, bucket, &busy, 99);
    try setTestMtime(io, bucket, liberal, 99);
    const unrelated = try bucket.createFile(io, "keep.txt", .{});
    unrelated.close(io);
    const link_name = try testName(5, 1);
    try bucket.symLink(io, &old, &link_name, .{});
    const busy_file = try bucket.openFile(io, &busy, .{ .mode = .read_write });
    defer busy_file.close(io);
    try std.testing.expect(try busy_file.tryLock(io, .exclusive));
    const excluded_path = try joinPath(allocator, bucket_path, &excluded, Paths.default_max_path_bytes);
    defer allocator.free(excluded_path);

    const empty_bucket_path = try makeTestDirectory(allocator, io, state_root, "/empty-after");
    defer allocator.free(empty_bucket_path);
    const lone = try testName(0, 2);
    try writeTestSession(allocator, io, empty_bucket_path, &lone, "lone");
    const empty_bucket = try std.Io.Dir.openDir(.cwd(), io, empty_bucket_path, .{});
    try setTestMtime(io, empty_bucket, &lone, 99);
    empty_bucket.close(io);

    const sessions_path = try sessionsDirectory(allocator, state_root, Paths.default_max_path_bytes);
    defer allocator.free(sessions_path);
    const symlink_bucket = try joinPath(allocator, sessions_path, "linked-bucket", Paths.default_max_path_bytes);
    defer allocator.free(symlink_bucket);
    try std.Io.Dir.symLink(.cwd(), io, bucket_path, symlink_bucket, .{ .is_directory = true });

    const report = try pruneBefore(allocator, io, state_root, 100, excluded_path, .{});
    try std.testing.expectEqual(@as(usize, 3), report.recovery.pruned);
    try std.testing.expectEqual(@as(usize, 1), report.recovery.busy_kept);
    try std.testing.expect(report.recovery.nonregular >= 2);
    try std.testing.expectError(error.FileNotFound, bucket.openFile(io, &old, .{}));
    try std.testing.expectError(error.FileNotFound, bucket.openFile(io, liberal, .{}));
    const equal_file = try bucket.openFile(io, &equal, .{});
    equal_file.close(io);
    const newer_file = try bucket.openFile(io, &newer, .{});
    newer_file.close(io);
    const excluded_file = try bucket.openFile(io, &excluded, .{});
    excluded_file.close(io);
    const unrelated_file = try bucket.openFile(io, "keep.txt", .{});
    unrelated_file.close(io);
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.openDir(.cwd(), io, empty_bucket_path, .{}),
    );
}

fn exerciseListAllocationFailures(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
) !void {
    var index = try list(allocator, io, state_root, "/work", 0, .{});
    defer index.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), index.entries.len);
}

test "list releases every partial allocation" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const state_root = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(state_root);
    const directory = try makeTestDirectory(allocator, io, state_root, "/work");
    defer allocator.free(directory);
    const name = try testName(0, 1);
    try writeTestSession(allocator, io, directory, &name, "model");
    try std.testing.checkAllAllocationFailures(
        allocator,
        exerciseListAllocationFailures,
        .{ io, state_root },
    );
}
