//! Filesystem-backed `@file` completion policy.
//!
//! SessionRuntime owns request coalescing and event delivery. This module owns
//! only the blocking scan, match policy, bounds, and raw result lifetime.

const std = @import("std");

const client_protocol = @import("client_protocol.zig");

pub const item_count_max: usize = client_protocol.completion_item_count_max;

const scan_count_max: usize = 20_000;
const pending_dirs_max: usize = 2_000;
const scope_match_max: usize = 32;

const PendingDir = struct { path: []u8 };
const EntryKind = enum { file, directory };

pub const Item = struct {
    id: [client_protocol.completion_id_bytes_max]u8 = undefined,
    id_len: u16 = 0,
    label: [client_protocol.completion_label_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    detail: [client_protocol.completion_detail_bytes_max]u8 = undefined,
    detail_len: u16 = 0,

    pub fn idSlice(self: *const Item) []const u8 {
        return self.id[0..self.id_len];
    }

    fn source(self: *const Item) client_protocol.CompletionItem.Source {
        return .{
            .id = self.idSlice(),
            .label = self.label[0..self.label_len],
            .detail = self.detail[0..self.detail_len],
        };
    }
};

pub const Result = struct {
    query: [client_protocol.file_completion_query_bytes_max]u8 = undefined,
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
        self.items[index].id_len = copyRawField(client_protocol.completion_id_bytes_max, &self.items[index].id, path);
        self.items[index].label_len = copyRawField(
            client_protocol.completion_label_bytes_max,
            &self.items[index].label,
            pathLabel(path),
        );
        self.items[index].detail_len = copyRawField(client_protocol.completion_detail_bytes_max, &self.items[index].detail, detail);
    }

    fn sort(self: *Result) void {
        std.mem.sort(Item, self.items[0..self.item_len], {}, rawLessThan);
    }

    pub fn sources(
        self: *const Result,
        out: *[item_count_max]client_protocol.CompletionItem.Source,
    ) []const client_protocol.CompletionItem.Source {
        for (self.items[0..self.item_len], 0..) |*item, index| out[index] = item.source();
        return out[0..self.item_len];
    }

    pub fn deinit(self: *Result) void {
        self.* = undefined;
    }

    pub fn destroy(self: *Result) void {
        self.deinit();
        std.heap.page_allocator.destroy(self);
    }
};

pub fn build(root_dir: std.Io.Dir, query: []const u8) !*Result {
    const result = try std.heap.page_allocator.create(Result);
    errdefer std.heap.page_allocator.destroy(result);
    result.* = .{};
    result.query_len = copyRawField(client_protocol.file_completion_query_bytes_max, &result.query, query);
    const bounded_query = result.querySlice();
    const scope_end = if (std.mem.lastIndexOfScalar(u8, bounded_query, '/')) |slash| slash + 1 else 0;
    const scope = bounded_query[0..scope_end];
    const leaf_query = bounded_query[scope_end..];
    if (leaf_query.len == 0) {
        const listed = try collectDirectoryChildren(root_dir.handle, scope, result);
        if (!listed and scope.len > 0) {
            if (try resolveDirectoryAlias(root_dir.handle, scope[0 .. scope.len - 1])) |resolved_scope| {
                _ = try collectDirectoryChildren(root_dir.handle, resolved_scope, result);
            } else {
                try collectDirectoryMatches(root_dir.handle, scope[0 .. scope.len - 1], result);
            }
        }
    } else {
        try collectMatches(root_dir.handle, bounded_query, result);
    }
    result.sort();
    return result;
}

fn rawLessThan(_: void, a: Item, b: Item) bool {
    const a_id = a.idSlice();
    const b_id = b.idSlice();
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

fn collectDirectoryChildren(
    root_fd: std.posix.fd_t,
    scope: []const u8,
    result: *Result,
) !bool {
    const dir_path = scopeDirPath(scope) orelse return false;
    const dir_fd = std.posix.openat(root_fd, dir_path, .{
        .ACCMODE = .RDONLY,
        .DIRECTORY = true,
        .CLOEXEC = true,
    }, 0) catch return false;
    const c_dir = std.c.fdopendir(dir_fd) orelse {
        _ = std.c.close(dir_fd);
        return false;
    };
    defer _ = std.c.closedir(c_dir);

    while (std.c.readdir(c_dir)) |entry_ptr| {
        const entry = entry_ptr.*;
        const entry_name = direntName(&entry);
        if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
        if (!std.unicode.utf8ValidateSlice(entry_name)) continue;
        const kind = entryKind(dir_fd, &entry, entry_name) orelse continue;
        const is_dir = kind == .directory;
        if (is_dir and isIgnoredDir(entry_name)) continue;
        if (!shouldShowHiddenEntry(dir_path, entry_name, scope, "")) continue;

        var path_buffer: [client_protocol.completion_id_bytes_max + 1]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buffer, "{s}{s}{s}", .{
            scope,
            entry_name,
            if (is_dir) "/" else "",
        }) catch {
            result.truncated = true;
            continue;
        };
        if (path.len > client_protocol.completion_id_bytes_max) {
            result.truncated = true;
            continue;
        }
        result.append(path, pathDirname(path));
    }
    return true;
}

fn resolveDirectoryAlias(root_fd: std.posix.fd_t, query: []const u8) !?[]const u8 {
    var scratch: Result = .{};
    try collectDirectoryMatches(root_fd, query, &scratch);
    if (scratch.item_len != 1) return null;
    return scratch.items[0].idSlice();
}

fn collectDirectoryMatches(
    root_fd: std.posix.fd_t,
    query: []const u8,
    result: *Result,
) !void {
    const before = result.item_len;
    try collectMatches(root_fd, query, result);
    var read: usize = before;
    var write: usize = before;
    while (read < result.item_len) : (read += 1) {
        const item = result.items[read];
        if (!std.mem.endsWith(u8, item.idSlice(), "/")) continue;
        result.items[write] = item;
        write += 1;
    }
    result.item_len = @intCast(write);
}

fn collectMatches(
    root_fd: std.posix.fd_t,
    query: []const u8,
    result: *Result,
) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    var pending = std.ArrayList(PendingDir).empty;
    try pending.append(allocator, .{ .path = try allocator.dupe(u8, ".") });
    var entries_seen: usize = 0;
    var scope_matches: usize = 0;

    const scope_end = if (std.mem.lastIndexOfScalar(u8, query, '/')) |slash| slash + 1 else 0;
    const scope = query[0..scope_end];
    const leaf_query = query[scope_end..];

    var index: usize = 0;
    while (index < pending.items.len) : (index += 1) {
        const current = pending.items[index];
        const dir_fd = std.posix.openat(root_fd, current.path, .{
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
            const entry = entry_ptr.*;
            const entry_name = direntName(&entry);
            if (entries_seen == scan_count_max) {
                result.truncated = true;
                return;
            }
            entries_seen += 1;
            if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
            if (!std.unicode.utf8ValidateSlice(entry_name)) continue;
            const kind = entryKind(dir_fd, &entry, entry_name) orelse continue;
            const is_dir = kind == .directory;
            if (is_dir and isIgnoredDir(entry_name)) continue;
            if (!shouldShowHiddenEntry(current.path, entry_name, scope, leaf_query)) continue;

            const path = try joinPath(allocator, current.path, entry_name);
            const completion_path = if (is_dir) try std.fmt.allocPrint(allocator, "{s}/", .{path}) else path;

            if (is_dir) {
                if (pending.items.len == pending_dirs_max) {
                    result.truncated = true;
                } else {
                    try pending.append(allocator, .{ .path = path });
                }
            }

            if (completion_path.len > client_protocol.completion_id_bytes_max) {
                result.truncated = true;
                continue;
            }
            if (!pathMatchesQuery(completion_path, query, scope, leaf_query)) continue;
            if (scope.len > 0 and is_dir and !std.mem.eql(u8, completion_path, scope) and scope_matches >= scope_match_max) {
                result.truncated = true;
                continue;
            }
            if (scope.len > 0 and is_dir) scope_matches += 1;
            result.append(completion_path, pathDirname(completion_path));
        }
    }
}

fn scopeDirPath(scope: []const u8) ?[]const u8 {
    if (scope.len == 0) return ".";
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

fn shouldShowHiddenEntry(
    current_path: []const u8,
    entry_name: []const u8,
    scope: []const u8,
    leaf_query: []const u8,
) bool {
    if (entry_name.len == 0 or entry_name[0] != '.') return true;
    if (std.mem.startsWith(u8, leaf_query, ".")) return true;
    if (!std.mem.eql(u8, current_path, ".")) return false;
    return scope.len > entry_name.len and
        scope[entry_name.len] == '/' and
        std.mem.eql(u8, scope[0..entry_name.len], entry_name);
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
    if (name.len > std.Io.Dir.max_name_bytes) return null;
    var name_z: [std.Io.Dir.max_name_bytes + 1]u8 = undefined;
    @memcpy(name_z[0..name.len], name);
    name_z[name.len] = 0;
    const name_c: [:0]u8 = name_z[0..name.len :0];

    var stat = std.mem.zeroes(std.c.Stat);
    while (true) {
        switch (std.c.errno(std.c.fstatat(dir_fd, name_c.ptr, &stat, std.c.AT.SYMLINK_NOFOLLOW))) {
            .SUCCESS => break,
            .INTR => continue,
            else => return null,
        }
    }

    return switch (stat.mode & std.c.S.IFMT) {
        std.c.S.IFDIR => .directory,
        std.c.S.IFREG => .file,
        else => null,
    };
}

fn pathMatchesQuery(path: []const u8, query: []const u8, scope: []const u8, leaf_query: []const u8) bool {
    if (query.len == 0) return true;
    if (scope.len == 0) return matchPathPart(path, query);
    const scope_start = indexOfAsciiIgnoreCase(path, scope) orelse return false;
    const scoped_tail = path[scope_start + scope.len ..];
    if (leaf_query.len == 0) return true;
    return matchPathPart(pathLeaf(scoped_tail), leaf_query) or matchPathPart(scoped_tail, leaf_query);
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

fn direntName(entry: *const std.c.dirent) []const u8 {
    return entry.name[0..entry.namlen];
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

test "lists direct directory children deterministically" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/agent");
    try tmp.dir.createDirPath(std.testing.io, "src/tui");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/main.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/tui/App.zig", .data = "" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/.secret", .data = "" });

    const result = try build(tmp.dir, "src/");
    defer result.destroy();

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

    const result = try build(tmp.dir, "agent/");
    defer result.destroy();

    try std.testing.expectEqual(@as(u16, 2), result.item_len);
    try std.testing.expectEqualStrings("src/agent/App.zig", result.items[0].idSlice());
    try std.testing.expectEqualStrings("src/agent/root.zig", result.items[1].idSlice());
}

test "manual slash shows directory choices when alias is ambiguous" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/agent");
    try tmp.dir.createDirPath(std.testing.io, "docs/agent");

    const result = try build(tmp.dir, "agent/");
    defer result.destroy();

    try std.testing.expectEqual(@as(u16, 2), result.item_len);
    try std.testing.expectEqualStrings("docs/agent/", result.items[0].idSlice());
    try std.testing.expectEqualStrings("src/agent/", result.items[1].idSlice());
}

test "hides dotfiles until dot is requested" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/.secret", .data = "" });

    const hidden = try build(tmp.dir, "src/");
    defer hidden.destroy();
    try std.testing.expectEqual(@as(u16, 0), hidden.item_len);

    const shown = try build(tmp.dir, "src/.");
    defer shown.destroy();
    try std.testing.expectEqual(@as(u16, 1), shown.item_len);
    try std.testing.expectEqualStrings("src/.secret", shown.items[0].idSlice());
}
