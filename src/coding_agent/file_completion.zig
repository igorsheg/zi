//! Filesystem-backed `@file` completion policy.
//!
//! Engine owns request coalescing, index lifetime, and ViewModel delivery.
//! This module owns bounded index construction, immutable queries, ranking, and
//! raw result lifetime.

const std = @import("std");
const builtin = @import("builtin");

pub const item_count_max: usize = 64;
pub const index_entry_count_max: usize = 20_000;
pub const index_path_bytes_max: usize = 2 * 1024 * 1024;
pub const completion_id_bytes_max = 256;
pub const completion_label_bytes_max = 160;
pub const completion_detail_bytes_max = 160;
pub const file_completion_query_bytes_max = 256;
pub const index_path_bytes_per_entry_max: usize = completion_id_bytes_max;

const pending_dirs_max: usize = index_entry_count_max;
const scope_match_max: usize = 32;

const PendingDir = struct { path: []u8 };
const EntryKind = enum { file, directory };

pub const Source = struct { id: []const u8, label: []const u8, detail: []const u8 };

pub const Item = struct {
    id: [completion_id_bytes_max]u8 = undefined,
    id_len: u16 = 0,
    label: [completion_label_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    detail: [completion_detail_bytes_max]u8 = undefined,
    detail_len: u16 = 0,

    pub fn idSlice(self: *const Item) []const u8 {
        return self.id[0..self.id_len];
    }

    fn source(self: *const Item) Source {
        return .{
            .id = self.idSlice(),
            .label = self.label[0..self.label_len],
            .detail = self.detail[0..self.detail_len],
        };
    }
};

pub const Result = struct {
    query: [file_completion_query_bytes_max]u8 = undefined,
    query_len: u16 = 0,
    items: [item_count_max]Item = undefined,
    item_len: u16 = 0,
    truncated: bool = false,

    pub fn querySlice(self: *const Result) []const u8 {
        return self.query[0..self.query_len];
    }

    fn append(self: *Result, path: []const u8, detail: []const u8) void {
        if (self.item_len == self.items.len) {
            self.truncated = true;
            return;
        }
        const index = self.item_len;
        self.item_len += 1;
        self.items[index].id_len = copyRawField(
            completion_id_bytes_max,
            &self.items[index].id,
            path,
        );
        self.items[index].label_len = copyRawField(
            completion_label_bytes_max,
            &self.items[index].label,
            pathLabel(path),
        );
        self.items[index].detail_len = copyRawField(
            completion_detail_bytes_max,
            &self.items[index].detail,
            detail,
        );
    }

    fn appendUnique(self: *Result, path: []const u8, detail: []const u8) void {
        for (self.items[0..self.item_len]) |*item| {
            if (std.mem.eql(u8, item.idSlice(), path)) return;
        }
        self.append(path, detail);
    }

    fn sort(self: *Result) void {
        std.mem.sort(Item, self.items[0..self.item_len], {}, itemLessThan);
    }

    pub fn sources(
        self: *const Result,
        out: *[item_count_max]Source,
    ) []const Source {
        for (self.items[0..self.item_len], 0..) |*item, index| out[index] = item.source();
        return out[0..self.item_len];
    }

    pub fn deinit(self: *Result) void {
        self.* = undefined;
    }

    pub fn destroy(self: *Result, allocator: std.mem.Allocator) void {
        self.deinit();
        allocator.destroy(self);
    }
};

pub const Index = struct {
    entries: []Entry,
    path_bytes: []u8,
    truncated: bool = false,

    const Entry = struct {
        path_start: u32,
        path_len: u16,
        kind: EntryKind,
    };

    pub fn build(allocator: std.mem.Allocator, root_dir: std.Io.Dir) !Index {
        var entries = std.ArrayList(Entry).empty;
        errdefer entries.deinit(allocator);
        var path_bytes = std.ArrayList(u8).empty;
        errdefer path_bytes.deinit(allocator);
        var truncated = false;

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const arena_allocator = arena.allocator();
        var pending = std.ArrayList(PendingDir).empty;
        try pending.append(arena_allocator, .{ .path = try arena_allocator.dupe(u8, ".") });

        var index: usize = 0;
        walk: while (index < pending.items.len) : (index += 1) {
            const current = pending.items[index];
            const dir_fd = std.posix.openat(root_dir.handle, current.path, .{
                .ACCMODE = .RDONLY,
                .DIRECTORY = true,
                .CLOEXEC = true,
            }, 0) catch continue;
            const c_dir = std.c.fdopendir(dir_fd) orelse {
                _ = std.c.close(dir_fd);
                continue;
            };
            defer _ = std.c.closedir(c_dir);

            while (std.c.readdir(c_dir)) |entry_ptr| {
                const dir_entry = entry_ptr.*;
                const entry_name = direntName(&dir_entry);
                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
                if (!std.unicode.utf8ValidateSlice(entry_name)) continue;
                const kind = entryKind(dir_fd, &dir_entry, entry_name) orelse continue;
                const is_dir = kind == .directory;
                if (is_dir and isIgnoredDir(entry_name)) continue;

                const entry_path = try joinPath(arena_allocator, current.path, entry_name);
                const added = try appendIndexEntry(allocator, &entries, &path_bytes, entry_path, kind, &truncated);
                if (!added) break :walk;

                if (is_dir) {
                    if (pending.items.len == pending_dirs_max) {
                        truncated = true;
                    } else {
                        try pending.append(arena_allocator, .{ .path = entry_path });
                    }
                }
            }
        }

        const owned_entries = try entries.toOwnedSlice(allocator);
        errdefer allocator.free(owned_entries);
        const owned_path_bytes = try path_bytes.toOwnedSlice(allocator);
        return .{
            .entries = owned_entries,
            .path_bytes = owned_path_bytes,
            .truncated = truncated,
        };
    }

    pub fn deinit(self: *Index, allocator: std.mem.Allocator) void {
        allocator.free(self.path_bytes);
        allocator.free(self.entries);
        self.* = undefined;
    }

    pub fn query(self: *const Index, allocator: std.mem.Allocator, raw_query: []const u8) !*Result {
        const result = try allocator.create(Result);
        errdefer allocator.destroy(result);
        result.* = .{};
        result.truncated = self.truncated;
        result.query_len = copyRawField(file_completion_query_bytes_max, &result.query, raw_query);

        const bounded_query = result.querySlice();
        const scope_end = if (std.mem.findScalarLast(u8, bounded_query, '/')) |slash| slash + 1 else 0;
        const scope = bounded_query[0..scope_end];
        const leaf_query = bounded_query[scope_end..];

        if (leaf_query.len == 0) {
            const listed = try self.collectDirectChildren(scope, result);
            if (!listed and scope.len > 0) {
                try self.collectDirectoryAlias(scope[0 .. scope.len - 1], result);
            }
        } else {
            try self.collectSearchMatches(bounded_query, scope, leaf_query, result);
        }
        result.sort();
        return result;
    }

    fn entryPath(self: *const Index, entry: Entry) []const u8 {
        const start: usize = entry.path_start;
        return self.path_bytes[start .. start + entry.path_len];
    }

    fn hasDirectory(self: *const Index, dir_path: []const u8) bool {
        if (dir_path.len == 0) return true;
        for (self.entries) |entry| {
            if (entry.kind == .directory and std.mem.eql(u8, self.entryPath(entry), dir_path)) return true;
        }
        return false;
    }

    fn collectDirectChildren(self: *const Index, scope: []const u8, result: *Result) !bool {
        const scope_path = scopePath(scope) orelse return false;
        if (!self.hasDirectory(scope_path)) return false;

        for (self.entries) |entry| {
            const entry_path = self.entryPath(entry);
            var path_buffer: [completion_id_bytes_max + 1]u8 = undefined;
            const child = directChildPath(&path_buffer, scope_path, entry_path, entry.kind) orelse continue;
            if (!shouldShowPath(child, scope, "")) continue;
            result.appendUnique(child, pathDirname(child));
        }
        return true;
    }

    fn collectDirectoryAlias(self: *const Index, alias_query: []const u8, result: *Result) !void {
        const exact_count = self.countDirectoryAliasMatches(alias_query, true);
        if (exact_count == 1) {
            const resolved = self.firstDirectoryAliasMatch(alias_query, true).?;
            var scope_buffer: [completion_id_bytes_max + 1]u8 = undefined;
            const resolved_scope = std.fmt.bufPrint(&scope_buffer, "{s}/", .{resolved}) catch return;
            _ = try self.collectDirectChildren(resolved_scope, result);
            return;
        }
        if (exact_count > 1) {
            self.appendDirectoryAliasChoices(alias_query, true, result);
            return;
        }

        const fuzzy_count = self.countDirectoryAliasMatches(alias_query, false);
        if (fuzzy_count == 1) {
            const resolved = self.firstDirectoryAliasMatch(alias_query, false).?;
            var scope_buffer: [completion_id_bytes_max + 1]u8 = undefined;
            const resolved_scope = std.fmt.bufPrint(&scope_buffer, "{s}/", .{resolved}) catch return;
            _ = try self.collectDirectChildren(resolved_scope, result);
            return;
        }
        if (fuzzy_count > 1) self.appendDirectoryAliasChoices(alias_query, false, result);
    }

    fn countDirectoryAliasMatches(self: *const Index, alias_query: []const u8, exact: bool) usize {
        var count: usize = 0;
        for (self.entries) |entry| {
            if (entry.kind != .directory) continue;
            const entry_path = self.entryPath(entry);
            if (!shouldShowPath(entry_path, "", alias_query)) continue;
            if (!directoryAliasMatches(entry_path, alias_query, exact)) continue;
            count += 1;
            if (count > scope_match_max) return count;
        }
        return count;
    }

    fn firstDirectoryAliasMatch(self: *const Index, alias_query: []const u8, exact: bool) ?[]const u8 {
        for (self.entries) |entry| {
            if (entry.kind != .directory) continue;
            const entry_path = self.entryPath(entry);
            if (!shouldShowPath(entry_path, "", alias_query)) continue;
            if (directoryAliasMatches(entry_path, alias_query, exact)) return entry_path;
        }
        return null;
    }

    fn appendDirectoryAliasChoices(self: *const Index, alias_query: []const u8, exact: bool, result: *Result) void {
        for (self.entries) |entry| {
            if (entry.kind != .directory) continue;
            const entry_path = self.entryPath(entry);
            if (!shouldShowPath(entry_path, "", alias_query)) continue;
            if (!directoryAliasMatches(entry_path, alias_query, exact)) continue;
            var path_buffer: [completion_id_bytes_max + 1]u8 = undefined;
            const completion_path = std.fmt.bufPrint(&path_buffer, "{s}/", .{entry_path}) catch {
                result.truncated = true;
                continue;
            };
            result.append(completion_path, pathDirname(completion_path));
        }
    }

    fn collectSearchMatches(
        self: *const Index,
        raw_query: []const u8,
        scope: []const u8,
        leaf_query: []const u8,
        result: *Result,
    ) !void {
        var candidates: [item_count_max]ScoredPath = undefined;
        var candidate_len: usize = 0;
        var matched_count: usize = 0;

        for (self.entries) |entry| {
            const entry_path = self.entryPath(entry);
            if (!shouldShowPath(entry_path, scope, leaf_query)) continue;
            const score = scorePath(entry_path, entry.kind == .directory, raw_query, scope, leaf_query) orelse continue;
            matched_count += 1;
            const candidate: ScoredPath = .{
                .path = entry_path,
                .kind = entry.kind,
                .score = score,
            };
            if (candidate_len < candidates.len) {
                candidates[candidate_len] = candidate;
                candidate_len += 1;
            } else if (candidateBetter(candidate, worstCandidate(candidates[0..candidate_len]))) |replace_index| {
                candidates[replace_index] = candidate;
            }
        }
        if (matched_count > candidate_len) result.truncated = true;

        std.mem.sort(ScoredPath, candidates[0..candidate_len], {}, scoredPathLessThan);
        for (candidates[0..candidate_len]) |candidate| {
            var path_buffer: [completion_id_bytes_max + 1]u8 = undefined;
            const completion_path = if (candidate.kind == .directory)
                std.fmt.bufPrint(&path_buffer, "{s}/", .{candidate.path}) catch {
                    result.truncated = true;
                    continue;
                }
            else
                candidate.path;
            result.append(completion_path, pathDirname(completion_path));
        }
    }
};

const ScoredPath = struct {
    path: []const u8,
    kind: EntryKind,
    score: i32,
};

fn appendIndexEntry(
    allocator: std.mem.Allocator,
    entries: *std.ArrayList(Index.Entry),
    path_bytes: *std.ArrayList(u8),
    path: []const u8,
    kind: EntryKind,
    truncated: *bool,
) !bool {
    if (path.len > index_path_bytes_per_entry_max) {
        truncated.* = true;
        return true;
    }
    if (entries.items.len == index_entry_count_max) {
        truncated.* = true;
        return false;
    }
    if (path_bytes.items.len + path.len > index_path_bytes_max) {
        truncated.* = true;
        return false;
    }
    const start = path_bytes.items.len;
    try path_bytes.appendSlice(allocator, path);
    try entries.append(allocator, .{
        .path_start = @intCast(start),
        .path_len = @intCast(path.len),
        .kind = kind,
    });
    return true;
}

fn itemLessThan(_: void, a: Item, b: Item) bool {
    return rawPathLessThan(a.idSlice(), b.idSlice());
}

fn rawPathLessThan(a_id: []const u8, b_id: []const u8) bool {
    const a_dir = std.mem.endsWith(u8, a_id, "/");
    const b_dir = std.mem.endsWith(u8, b_id, "/");
    if (a_dir != b_dir) return a_dir;
    return std.mem.lessThan(u8, a_id, b_id);
}

fn copyRawField(comptime max: usize, dest: *[max]u8, bytes: []const u8) u16 {
    const prefix = utf8Prefix(bytes, max);
    @memcpy(dest[0..prefix.len], prefix);
    return @intCast(prefix.len);
}

fn utf8Prefix(bytes: []const u8, max: usize) []const u8 {
    if (bytes.len <= max) return bytes;
    var end = max;
    while (end > 0 and (bytes[end] & 0xc0) == 0x80) : (end -= 1) {}
    return bytes[0..end];
}

fn scopePath(scope: []const u8) ?[]const u8 {
    if (scope.len == 0) return "";
    if (scope[0] == '/') return null;
    const trimmed = if (std.mem.endsWith(u8, scope, "/")) scope[0 .. scope.len - 1] else scope;
    if (trimmed.len == 0 or hasUnsafePathSegment(trimmed)) return null;
    return trimmed;
}

fn hasUnsafePathSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len == 0) return true;
        if (std.mem.eql(u8, segment, ".") or std.mem.eql(u8, segment, "..")) return true;
        if (isIgnoredDir(segment)) return true;
    }
    return false;
}

fn directChildPath(
    buffer: *[completion_id_bytes_max + 1]u8,
    scope: []const u8,
    entry_path: []const u8,
    kind: EntryKind,
) ?[]const u8 {
    const rest = if (scope.len == 0) blk: {
        break :blk entry_path;
    } else blk: {
        if (std.mem.eql(u8, entry_path, scope)) return null;
        if (!std.mem.startsWith(u8, entry_path, scope)) return null;
        if (entry_path.len <= scope.len or entry_path[scope.len] != '/') return null;
        break :blk entry_path[scope.len + 1 ..];
    };
    if (rest.len == 0) return null;

    if (std.mem.findScalar(u8, rest, '/')) |slash| {
        const child_len = entry_path.len - rest.len + slash;
        return std.fmt.bufPrint(buffer, "{s}/", .{entry_path[0..child_len]}) catch null;
    }
    if (kind == .directory) return std.fmt.bufPrint(buffer, "{s}/", .{entry_path}) catch null;
    return entry_path;
}

fn directoryAliasMatches(entry_path: []const u8, query: []const u8, exact: bool) bool {
    const leaf = pathLeaf(entry_path);
    if (exact) return asciiEqlIgnoreCase(leaf, query);
    return matchPathPart(leaf, query) or matchPathPart(entry_path, query);
}

fn shouldShowPath(path: []const u8, scope: []const u8, leaf_query: []const u8) bool {
    if (!pathHasHiddenSegment(path)) return true;
    if (std.mem.startsWith(u8, leaf_query, ".")) return true;
    return scopeHasHiddenSegment(scope);
}

fn pathHasHiddenSegment(path: []const u8) bool {
    var segments = std.mem.splitScalar(u8, path, '/');
    while (segments.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return true;
    }
    return false;
}

fn scopeHasHiddenSegment(scope: []const u8) bool {
    const trimmed = if (std.mem.endsWith(u8, scope, "/")) scope[0 .. scope.len - 1] else scope;
    var segments = std.mem.splitScalar(u8, trimmed, '/');
    while (segments.next()) |segment| {
        if (segment.len > 0 and segment[0] == '.') return true;
    }
    return false;
}

fn scorePath(path: []const u8, is_dir: bool, query: []const u8, scope: []const u8, leaf_query: []const u8) ?i32 {
    if (query.len == 0) return 1;
    const scoped_tail = if (scope.len == 0) path else blk: {
        const scope_start = indexOfAsciiIgnoreCase(path, scope) orelse return null;
        break :blk path[scope_start + scope.len ..];
    };
    if (leaf_query.len == 0) return 1;
    const leaf = pathLeaf(scoped_tail);
    var score: i32 = if (asciiEqlIgnoreCase(leaf, leaf_query))
        1000
    else if (asciiStartsWithIgnoreCase(leaf, leaf_query))
        900
    else if (boundaryPrefixMatch(scoped_tail, leaf_query))
        850
    else if (indexOfAsciiIgnoreCase(leaf, leaf_query) != null)
        700
    else if (fuzzySubsequence(leaf, leaf_query))
        550
    else if (indexOfAsciiIgnoreCase(scoped_tail, leaf_query) != null)
        450
    else if (fuzzySubsequence(scoped_tail, leaf_query))
        300
    else
        return null;

    const len_bonus: i32 = @intCast(@max(0, 200 - @min(path.len, 200)));
    score += len_bonus;
    if (is_dir) score += 20;
    return score;
}

fn matchPathPart(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    return indexOfAsciiIgnoreCase(text, query) != null or fuzzySubsequence(text, query);
}

fn fuzzySubsequence(text: []const u8, query: []const u8) bool {
    var qi: usize = 0;
    for (text) |byte| {
        if (qi < query.len and std.ascii.toLower(byte) == std.ascii.toLower(query[qi])) qi += 1;
    }
    return qi == query.len;
}

fn boundaryPrefixMatch(text: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    var index: usize = 0;
    while (index < text.len) : (index += 1) {
        if (!isBoundary(text, index)) continue;
        if (asciiStartsWithIgnoreCase(text[index..], query)) return true;
    }
    return false;
}

fn isBoundary(text: []const u8, index: usize) bool {
    if (index == 0) return true;
    const previous = text[index - 1];
    const current = text[index];
    return previous == '/' or previous == '_' or previous == '-' or previous == '.' or
        (std.ascii.isLower(previous) and std.ascii.isUpper(current));
}

fn indexOfAsciiIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0) return 0;
    if (needle.len > haystack.len) return null;
    var index: usize = 0;
    while (index + needle.len <= haystack.len) : (index += 1) {
        for (needle, 0..) |byte, offset| {
            if (std.ascii.toLower(haystack[index + offset]) != std.ascii.toLower(byte)) break;
        } else return index;
    }
    return null;
}

fn asciiStartsWithIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    return asciiEqlIgnoreCase(haystack[0..needle.len], needle);
}

fn asciiEqlIgnoreCase(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |a_byte, b_byte| {
        if (std.ascii.toLower(a_byte) != std.ascii.toLower(b_byte)) return false;
    }
    return true;
}

fn candidateBetter(candidate: ScoredPath, current_worst: WorstCandidate) ?usize {
    if (scoredPathLessThan({}, candidate, current_worst.path)) return current_worst.index;
    return null;
}

const WorstCandidate = struct { index: usize, path: ScoredPath };

fn worstCandidate(candidates: []const ScoredPath) WorstCandidate {
    std.debug.assert(candidates.len > 0);
    var worst: WorstCandidate = .{ .index = 0, .path = candidates[0] };
    for (candidates[1..], 1..) |candidate, index| {
        if (scoredPathLessThan({}, worst.path, candidate)) {
            worst = .{ .index = index, .path = candidate };
        }
    }
    return worst;
}

fn scoredPathLessThan(_: void, a: ScoredPath, b: ScoredPath) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.kind != b.kind) return a.kind == .directory;
    return std.mem.lessThan(u8, a.path, b.path);
}

fn direntName(entry: *const std.c.dirent) []const u8 {
    return switch (builtin.os.tag) {
        .linux => std.mem.sliceTo(entry.name[0..], 0),
        else => entry.name[0..entry.namlen],
    };
}

fn joinPath(allocator: std.mem.Allocator, dir_path: []const u8, name: []const u8) ![]u8 {
    if (std.mem.eql(u8, dir_path, ".")) return allocator.dupe(u8, name);
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, name });
}

fn pathDirname(path: []const u8) []const u8 {
    const trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    const index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return "";
    return trimmed[0..index];
}

fn pathLabel(path: []const u8) []const u8 {
    const trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    const index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return path;
    return path[index + 1 ..];
}

fn pathLeaf(path: []const u8) []const u8 {
    const trimmed = if (std.mem.endsWith(u8, path, "/")) path[0 .. path.len - 1] else path;
    const index = std.mem.lastIndexOfScalar(u8, trimmed, '/') orelse return trimmed;
    return trimmed[index + 1 ..];
}

fn isIgnoredDir(name: []const u8) bool {
    const ignored = [_][]const u8{
        ".git",   ".zig-cache", "zig-cache", "zig-out", "node_modules",
        ".cache", ".direnv",    ".venv",     "vendor",
    };
    for (ignored) |entry| {
        if (std.mem.eql(u8, name, entry)) return true;
    }
    return false;
}

fn entryKind(
    dir_fd: std.posix.fd_t,
    entry: *const std.c.dirent,
    name: []const u8,
) ?EntryKind {
    if (entry.type == std.c.DT.DIR) return .directory;
    if (entry.type == std.c.DT.REG) return .file;
    if (entry.type != std.c.DT.UNKNOWN) return null;
    return statEntryKind(dir_fd, name);
}

fn statEntryKind(dir_fd: std.posix.fd_t, name: []const u8) ?EntryKind {
    if (builtin.os.tag == .linux) return linuxStatEntryKind(dir_fd, name);
    return libcStatEntryKind(dir_fd, name);
}

fn linuxStatEntryKind(dir_fd: std.posix.fd_t, name: []const u8) ?EntryKind {
    const linux = std.os.linux;
    if (name.len > std.Io.Dir.max_name_bytes) return null;
    var name_z: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const name_c: [:0]u8 = name_z[0..name.len :0];

    var statx = std.mem.zeroes(linux.Statx);
    while (true) {
        switch (linux.errno(linux.statx(
            dir_fd,
            name_c.ptr,
            linux.AT.SYMLINK_NOFOLLOW,
            .{ .TYPE = true },
            &statx,
        ))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        }
    }

    const mode = statx.mode & linux.S.IFMT;
    if (mode == linux.S.IFDIR) return .directory;
    if (mode == linux.S.IFREG) return .file;
    return null;
}

fn libcStatEntryKind(dir_fd: std.posix.fd_t, name: []const u8) ?EntryKind {
    if (name.len > std.Io.Dir.max_name_bytes) return null;
    var name_z: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const name_c: [:0]u8 = name_z[0..name.len :0];

    var stat: std.posix.Stat = undefined;
    while (true) {
        switch (std.posix.errno(std.posix.system.fstatat(
            dir_fd,
            name_c.ptr,
            &stat,
            std.posix.AT.SYMLINK_NOFOLLOW,
        ))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        }
    }

    const mode = stat.mode & std.posix.S.IFMT;
    if (mode == std.posix.S.IFDIR) return .directory;
    if (mode == std.posix.S.IFREG) return .file;
    return null;
}

fn buildAndQuery(allocator: std.mem.Allocator, dir: std.Io.Dir, query: []const u8) !*Result {
    var index = try Index.build(allocator, dir);
    defer index.deinit(allocator);
    return index.query(allocator, query);
}

test "lists direct directory children deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/agent");
    try tmp.dir.createDirPath(std.testing.io, "src/tui");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/tui/App.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/.secret", .data = "" });

    const result = try buildAndQuery(std.testing.allocator, tmp.dir, "src/");
    defer result.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 3), result.item_len);
    try std.testing.expectEqualStrings("src/agent/", result.items[0].idSlice());
    try std.testing.expectEqualStrings("agent/", result.items[0].label[0..result.items[0].label_len]);
    try std.testing.expectEqualStrings("src", result.items[0].detail[0..result.items[0].detail_len]);
    try std.testing.expectEqualStrings("src/tui/", result.items[1].idSlice());
    try std.testing.expectEqualStrings("src/main.zig", result.items[2].idSlice());
    try std.testing.expectEqualStrings("main.zig", result.items[2].label[0..result.items[2].label_len]);
}

test "manual slash descends into a unique directory alias" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/agent");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/agent/root.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/agent/App.zig", .data = "" });

    const result = try buildAndQuery(std.testing.allocator, tmp.dir, "agent/");
    defer result.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), result.item_len);
    try std.testing.expectEqualStrings("src/agent/App.zig", result.items[0].idSlice());
    try std.testing.expectEqualStrings("src/agent/root.zig", result.items[1].idSlice());
}

test "manual slash shows directory choices when alias is ambiguous" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/agent");
    try tmp.dir.createDirPath(std.testing.io, "docs/agent");

    const result = try buildAndQuery(std.testing.allocator, tmp.dir, "agent/");
    defer result.destroy(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 2), result.item_len);
    try std.testing.expectEqualStrings("docs/agent/", result.items[0].idSlice());
    try std.testing.expectEqualStrings("src/agent/", result.items[1].idSlice());
}

test "hides dotfiles until dot is requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/.secret", .data = "" });

    const hidden = try buildAndQuery(std.testing.allocator, tmp.dir, "src/");
    defer hidden.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 0), hidden.item_len);

    const shown = try buildAndQuery(std.testing.allocator, tmp.dir, "src/.");
    defer shown.destroy(std.testing.allocator);
    try std.testing.expectEqual(@as(u16, 1), shown.item_len);
    try std.testing.expectEqualStrings("src/.secret", shown.items[0].idSlice());
}

test "ignored directories do not enter the index" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git/hooks");
    try tmp.dir.createDirPath(std.testing.io, "node_modules/pkg");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/config", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "node_modules/pkg/index.js", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "" });

    var index = try Index.build(std.testing.allocator, tmp.dir);
    defer index.deinit(std.testing.allocator);

    for (index.entries) |entry| {
        const path = index.entryPath(entry);
        try std.testing.expect(std.mem.indexOf(u8, path, ".git") == null);
        try std.testing.expect(std.mem.indexOf(u8, path, "node_modules") == null);
    }
}
