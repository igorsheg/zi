const std = @import("std");

const paths_mod = @import("paths.zig");

pub const SessionListOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    max_sessions: usize = 128,
    max_directory_entries: usize = 512,
};

pub const SessionSelectionOptions = struct {
    cwd: []const u8 = ".",
    agent_dir_override: ?[]const u8 = null,
    dir: std.Io.Dir = .cwd(),
    environ: ?*const std.process.Environ.Map = null,
    selector: ?[]const u8 = null,
    max_sessions: usize = 128,
    max_directory_entries: usize = 512,
};

pub const SessionList = struct {
    file_names: [][]const u8,
    truncated: bool,

    pub fn deinit(self: *SessionList, allocator: std.mem.Allocator) void {
        for (self.file_names) |file_name| allocator.free(file_name);
        allocator.free(self.file_names);
        self.* = undefined;
    }
};

pub const SessionSummary = struct {
    file_name: []const u8,
    title: []const u8,
    detail: []const u8,
    meta: []const u8,
    aux: []const u8,

    pub fn deinit(self: *SessionSummary, allocator: std.mem.Allocator) void {
        allocator.free(self.aux);
        allocator.free(self.meta);
        allocator.free(self.detail);
        allocator.free(self.title);
        allocator.free(self.file_name);
        self.* = undefined;
    }
};

pub const SessionSummaryList = struct {
    items: []SessionSummary,
    truncated: bool,

    pub fn deinit(self: *SessionSummaryList, allocator: std.mem.Allocator) void {
        for (self.items) |*item| item.deinit(allocator);
        allocator.free(self.items);
        self.* = undefined;
    }
};

pub fn listRuntimeSessions(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionListOptions,
) !SessionList {
    const sessions_dir = try runtimeSessionsDir(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
    });
    defer allocator.free(sessions_dir);

    var dir = options.dir.openDir(io, sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return .{
            .file_names = try allocator.alloc([]const u8, 0),
            .truncated = false,
        },
        else => return err,
    };
    defer dir.close(io);

    var files = std.ArrayList(RuntimeSessionFile).empty;
    errdefer {
        for (files.items) |file| allocator.free(file.name);
        files.deinit(allocator);
    }

    var iterator = dir.iterate();
    var directory_entries_seen: usize = 0;
    var truncated = false;
    while (try iterator.next(io)) |entry| {
        if (directory_entries_seen == options.max_directory_entries) {
            truncated = true;
            break;
        }
        directory_entries_seen += 1;
        if (entry.kind != .file) continue;
        if (!paths_mod.isSessionFileLeafName(entry.name)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch |err| switch (err) {
            error.FileNotFound => continue,
            else => return err,
        };
        if (stat.kind != .file) continue;
        const copy = try allocator.dupe(u8, entry.name);
        files.append(allocator, .{ .name = copy, .mtime = stat.mtime }) catch |err| {
            allocator.free(copy);
            return err;
        };
    }

    std.mem.sort(RuntimeSessionFile, files.items, {}, newerSessionFile);
    while (files.items.len > options.max_sessions) {
        allocator.free(files.pop().?.name);
        truncated = true;
    }

    const file_names = try allocator.alloc([]const u8, files.items.len);
    errdefer allocator.free(file_names);
    for (files.items, file_names) |file, *file_name| file_name.* = file.name;
    files.deinit(allocator);
    return .{
        .file_names = file_names,
        .truncated = truncated,
    };
}

pub fn listRuntimeSessionSummaries(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionListOptions,
) !SessionSummaryList {
    const sessions_dir = try runtimeSessionsDir(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
    });
    defer allocator.free(sessions_dir);

    var list = try listRuntimeSessions(allocator, io, options);
    defer list.deinit(allocator);

    var summaries = std.ArrayList(SessionSummary).empty;
    errdefer {
        for (summaries.items) |*item| item.deinit(allocator);
        summaries.deinit(allocator);
    }
    try summaries.ensureTotalCapacity(allocator, list.file_names.len);
    for (list.file_names) |file_name| {
        const summary = loadRuntimeSessionSummary(allocator, io, options.dir, sessions_dir, file_name) catch
            try fallbackRuntimeSessionSummary(allocator, file_name);
        summaries.appendAssumeCapacity(summary);
    }
    return .{ .items = try summaries.toOwnedSlice(allocator), .truncated = list.truncated };
}

pub fn selectRuntimeSession(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionSelectionOptions,
) !?[]const u8 {
    if (options.selector) |selector| {
        if (paths_mod.isSessionFileLeafName(selector)) return selectExistingLeaf(allocator, io, options, selector);
        if (!isSessionIdSelector(selector)) return error.InvalidSessionFileName;
        return selectBySessionIdPrefix(allocator, io, options, selector);
    }

    var list = try listRuntimeSessions(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
        .max_sessions = options.max_sessions,
        .max_directory_entries = options.max_directory_entries,
    });
    defer list.deinit(allocator);

    if (list.truncated) return error.SessionListTruncated;
    if (list.file_names.len == 0) return null;
    const selected = try allocator.dupe(u8, list.file_names[0]);
    return selected;
}

fn selectExistingLeaf(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionSelectionOptions,
    file_name: []const u8,
) !?[]const u8 {
    const sessions_dir = try runtimeSessionsDir(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
    });
    defer allocator.free(sessions_dir);
    const store_file_name = try std.fs.path.join(allocator, &.{ sessions_dir, file_name });
    defer allocator.free(store_file_name);
    options.dir.access(io, store_file_name, .{
        .follow_symlinks = false,
        .read = true,
        .write = false,
        .execute = false,
    }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    const selected = try allocator.dupe(u8, file_name);
    return selected;
}

fn selectBySessionIdPrefix(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: SessionSelectionOptions,
    selector: []const u8,
) !?[]const u8 {
    const sessions_dir = try runtimeSessionsDir(allocator, io, .{
        .cwd = options.cwd,
        .agent_dir_override = options.agent_dir_override,
        .dir = options.dir,
        .environ = options.environ,
    });
    defer allocator.free(sessions_dir);

    var dir = options.dir.openDir(io, sessions_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(io);

    var match: ?[]u8 = null;
    errdefer if (match) |file_name| allocator.free(file_name);
    var iterator = dir.iterate();
    var directory_entries_seen: usize = 0;
    while (try iterator.next(io)) |entry| {
        if (directory_entries_seen == selector_scan_entries_max) return error.SessionListTruncated;
        directory_entries_seen += 1;
        if (entry.kind != .file) continue;
        const id = sessionIdFromLeaf(entry.name) orelse continue;
        if (std.mem.eql(u8, id, selector)) {
            if (match) |file_name| {
                allocator.free(file_name);
                match = null;
            }
            const selected = try allocator.dupe(u8, entry.name);
            return selected;
        }
        if (!std.mem.startsWith(u8, id, selector)) continue;
        if (match != null) return error.AmbiguousSessionSelector;
        match = try allocator.dupe(u8, entry.name);
    }
    const selected = match orelse return null;
    match = null;
    return selected;
}

fn isSessionIdSelector(selector: []const u8) bool {
    if (selector.len == 0) return false;
    if (std.mem.eql(u8, selector, ".") or std.mem.eql(u8, selector, "..")) return false;
    return std.mem.indexOfAny(u8, selector, "/\\") == null;
}

fn sessionIdFromLeaf(file_name: []const u8) ?[]const u8 {
    if (!paths_mod.isSessionFileLeafName(file_name)) return null;
    const underscore = std.mem.indexOfScalar(u8, file_name, '_') orelse return null;
    const end = file_name.len - ".jsonl".len;
    if (underscore + 1 >= end) return null;
    return file_name[underscore + 1 .. end];
}

const selector_scan_entries_max: usize = 100_000;
const summary_scan_bytes_max: usize = 64 * 1024;
const summary_title_bytes_max: usize = 160;
const summary_detail_bytes_max: usize = 160;
const summary_cwd_bytes_max: usize = 96;
const summary_timestamp_bytes_max: usize = 32;

const RuntimeSessionSummaryBuilder = struct {
    cwd: [summary_cwd_bytes_max]u8 = undefined,
    cwd_len: u16 = 0,
    timestamp: [summary_timestamp_bytes_max]u8 = undefined,
    timestamp_len: u8 = 0,
    first_user: [summary_title_bytes_max]u8 = undefined,
    first_user_len: u16 = 0,
    message_count: usize = 0,
    scan_truncated: bool = false,
    header_seen: bool = false,

    fn cwdSlice(self: *const RuntimeSessionSummaryBuilder) []const u8 {
        return self.cwd[0..self.cwd_len];
    }

    fn timestampSlice(self: *const RuntimeSessionSummaryBuilder) []const u8 {
        return self.timestamp[0..self.timestamp_len];
    }

    fn firstUserSlice(self: *const RuntimeSessionSummaryBuilder) []const u8 {
        return self.first_user[0..self.first_user_len];
    }
};

fn loadRuntimeSessionSummary(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sessions_dir: []const u8,
    file_name: []const u8,
) !SessionSummary {
    const path = try std.fs.path.join(allocator, &.{ sessions_dir, file_name });
    defer allocator.free(path);
    var file = try dir.openFile(io, path, .{});
    defer file.close(io);

    const buffer = try allocator.alloc(u8, summary_scan_bytes_max);
    defer allocator.free(buffer);
    var read_count: usize = 0;
    while (read_count < buffer.len) {
        const n = file.readStreaming(io, &.{buffer[read_count..]}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (n == 0) break;
        read_count += n;
    }
    const complete = completeLinePrefix(buffer[0..read_count]);

    var builder: RuntimeSessionSummaryBuilder = .{ .scan_truncated = read_count == buffer.len };
    var lines = std.mem.splitScalar(u8, complete, '\n');
    while (lines.next()) |line| {
        parseSummaryLine(allocator, std.mem.trim(u8, line, " \t\r"), &builder) catch continue;
    }
    return summaryFromBuilder(allocator, file_name, &builder);
}

fn fallbackRuntimeSessionSummary(allocator: std.mem.Allocator, file_name: []const u8) !SessionSummary {
    var builder: RuntimeSessionSummaryBuilder = .{};
    return summaryFromBuilder(allocator, file_name, &builder);
}

fn completeLinePrefix(data: []const u8) []const u8 {
    if (data.len < summary_scan_bytes_max or data.len == 0 or data[data.len - 1] == '\n') return data;
    const last_newline = std.mem.lastIndexOfScalar(u8, data, '\n') orelse return "";
    return data[0 .. last_newline + 1];
}

fn parseSummaryLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    builder: *RuntimeSessionSummaryBuilder,
) !void {
    if (line.len == 0) return;
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const object = parsed.value.object;
    const entry_type = jsonString(object.get("type")) orelse return;
    if (!builder.header_seen) {
        if (!std.mem.eql(u8, entry_type, "session")) return;
        builder.header_seen = true;
        if (jsonString(object.get("cwd"))) |cwd| {
            builder.cwd_len = copyNormalized(summary_cwd_bytes_max, &builder.cwd, cwd);
        }
        if (jsonString(object.get("timestamp"))) |timestamp| {
            builder.timestamp_len = @intCast(copyBounded(summary_timestamp_bytes_max, &builder.timestamp, timestamp));
        }
        return;
    }
    if (!std.mem.eql(u8, entry_type, "message")) return;
    builder.message_count += 1;
    if (builder.first_user_len != 0) return;
    const message = jsonObject(object.get("message")) orelse return;
    const role = jsonString(message.get("role")) orelse return;
    if (!std.mem.eql(u8, role, "user")) return;
    if (firstTextContent(message.get("content"))) |text| {
        builder.first_user_len = copyNormalized(summary_title_bytes_max, &builder.first_user, text);
    }
}

fn summaryFromBuilder(
    allocator: std.mem.Allocator,
    file_name: []const u8,
    builder: *const RuntimeSessionSummaryBuilder,
) !SessionSummary {
    const file_copy = try allocator.dupe(u8, file_name);
    errdefer allocator.free(file_copy);
    const title_source = if (builder.first_user_len > 0) builder.firstUserSlice() else fallbackTitle(file_name);
    const title = try dupeBounded(allocator, summary_title_bytes_max, title_source);
    errdefer allocator.free(title);
    const cwd = builder.cwdSlice();
    const cwd_base = if (cwd.len == 0) "session" else std.fs.path.basename(cwd);
    const detail = try allocator.dupe(u8, cwd_base);
    errdefer allocator.free(detail);
    var meta_buffer: [32]u8 = undefined;
    const meta = try allocator.dupe(u8, formatSummaryMessageCount(&meta_buffer, builder));
    errdefer allocator.free(meta);
    const aux = try allocator.dupe(u8, summaryDate(file_name, builder));
    return .{ .file_name = file_copy, .title = title, .detail = detail, .meta = meta, .aux = aux };
}

fn formatSummaryMessageCount(buffer: []u8, builder: *const RuntimeSessionSummaryBuilder) []const u8 {
    const noun = if (builder.message_count == 1) "msg" else "msgs";
    if (builder.scan_truncated) {
        return std.fmt.bufPrint(buffer, "≥{d} {s}", .{ builder.message_count, noun }) catch "msgs";
    }
    return std.fmt.bufPrint(buffer, "{d} {s}", .{ builder.message_count, noun }) catch "msgs";
}

fn summaryDate(file_name: []const u8, builder: *const RuntimeSessionSummaryBuilder) []const u8 {
    return if (builder.timestamp_len >= 10) builder.timestampSlice()[0..10] else fallbackDate(file_name);
}

fn firstTextContent(value: ?std.json.Value) ?[]const u8 {
    const content = value orelse return null;
    switch (content) {
        .string => |text| return text,
        .array => |items| for (items.items) |item| {
            const object = jsonObject(item) orelse continue;
            const block_type = jsonString(object.get("type")) orelse continue;
            if (!std.mem.eql(u8, block_type, "text")) continue;
            if (jsonString(object.get("text"))) |text| return text;
        },
        else => {},
    }
    return null;
}

fn jsonObject(value: ?std.json.Value) ?std.json.ObjectMap {
    const actual = value orelse return null;
    return switch (actual) {
        .object => |object| object,
        else => null,
    };
}

fn jsonString(value: ?std.json.Value) ?[]const u8 {
    const actual = value orelse return null;
    return switch (actual) {
        .string => |text| text,
        else => null,
    };
}

fn fallbackTitle(file_name: []const u8) []const u8 {
    const stem = if (std.mem.endsWith(u8, file_name, ".jsonl")) file_name[0 .. file_name.len - 6] else file_name;
    if (std.mem.findScalar(u8, stem, '_')) |underscore| {
        if (underscore + 1 < stem.len) return stem[underscore + 1 ..];
    }
    return stem;
}

fn fallbackDate(file_name: []const u8) []const u8 {
    if (file_name.len >= 10) return file_name[0..10];
    return "unknown";
}

fn dupeBounded(allocator: std.mem.Allocator, comptime max: usize, bytes: []const u8) ![]const u8 {
    var buffer: [max]u8 = undefined;
    const len = copyNormalized(max, &buffer, bytes);
    return allocator.dupe(u8, buffer[0..len]);
}

fn copyNormalized(comptime max: usize, dest: *[max]u8, bytes: []const u8) u16 {
    var out: usize = 0;
    var pending_space = false;
    for (bytes) |byte| {
        if (std.ascii.isWhitespace(byte)) {
            pending_space = out > 0;
            continue;
        }
        if (pending_space) {
            if (out == max) break;
            dest[out] = ' ';
            out += 1;
            pending_space = false;
        }
        if (out == max) break;
        dest[out] = byte;
        out += 1;
    }
    while (out > 0 and dest[out - 1] == ' ') out -= 1;
    const safe = utf8Prefix(dest[0..out], out);
    return @intCast(safe.len);
}

fn copyBounded(comptime max: usize, dest: *[max]u8, bytes: []const u8) u16 {
    const prefix = utf8Prefix(bytes, max);
    @memcpy(dest[0..prefix.len], prefix);
    return @intCast(prefix.len);
}

fn utf8Prefix(bytes: []const u8, max: usize) []const u8 {
    var end = @min(bytes.len, max);
    while (end > 0 and !std.unicode.utf8ValidateSlice(bytes[0..end])) end -= 1;
    return bytes[0..end];
}

const RuntimeSessionDirOptions = struct {
    cwd: []const u8,
    agent_dir_override: ?[]const u8,
    dir: std.Io.Dir,
    environ: ?*const std.process.Environ.Map,
};

fn runtimeSessionsDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: RuntimeSessionDirOptions,
) ![]const u8 {
    const resolved_agent_dir = if (options.agent_dir_override) |agent_dir_override|
        agent_dir_override
    else
        try paths_mod.resolveGlobalAgentDirFromEnv(allocator, options.environ);
    defer if (options.agent_dir_override == null) allocator.free(resolved_agent_dir);

    const resolved_cwd = if (std.mem.eql(u8, options.cwd, "."))
        try options.dir.realPathFileAlloc(io, options.cwd, allocator)
    else
        try allocator.dupe(u8, options.cwd);
    defer allocator.free(resolved_cwd);

    const paths: paths_mod.PersistencePaths = .{
        .global_dir = resolved_agent_dir,
        .cwd = resolved_cwd,
    };
    return paths.sessionsDirForCwd(allocator);
}

const RuntimeSessionFile = struct {
    name: []const u8,
    mtime: std.Io.Timestamp,
};

fn newerSessionFile(_: void, left: RuntimeSessionFile, right: RuntimeSessionFile) bool {
    if (left.mtime.nanoseconds != right.mtime.nanoseconds) return left.mtime.nanoseconds > right.mtime.nanoseconds;
    return std.mem.order(u8, left.name, right.name) == .gt;
}

fn createSessionListingTestDirs(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "agent");
    try dir.createDirPath(std.testing.io, "repo");
}

fn writeSessionListingTestFile(dir: std.Io.Dir, file_name: []const u8) !void {
    try dir.createDirPath(std.testing.io, "agent/sessions/--repo--");
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "agent/sessions/--repo--/{s}", .{file_name});
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "{}\n" });
}

fn setSessionListingTestFileMtime(dir: std.Io.Dir, file_name: []const u8, nanoseconds: i96) !void {
    var path_buffer: [128]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "agent/sessions/--repo--/{s}", .{file_name});
    try dir.setTimestamps(std.testing.io, path, .{
        .modify_timestamp = .{ .new = .{ .nanoseconds = nanoseconds } },
    });
}

test "session summaries use first user message and bounded metadata" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try tmp.dir.createDirPath(std.testing.io, "agent/sessions/--repo--");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/2026-05-28T00:00:00Z_second.jsonl",
        .data = "{\"type\":\"session\",\"timestamp\":\"2026-05-28T00:00:00Z\"," ++
            "\"cwd\":\"/tmp/repo\"}\n" ++
            "{\"type\":\"message\",\"message\":{\"role\":\"assistant\"," ++
            "\"content\":\"ignored\"}}\n" ++
            "{\"type\":\"message\",\"message\":{\"role\":\"user\"," ++
            "\"content\":\"Fix\\nresume picker labels\"}}\n",
    });

    var summaries = try listRuntimeSessionSummaries(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer summaries.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), summaries.items.len);
    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", summaries.items[0].file_name);
    try std.testing.expectEqualStrings("Fix resume picker labels", summaries.items[0].title);
    try std.testing.expectEqualStrings("repo", summaries.items[0].detail);
    try std.testing.expectEqualStrings("2 msgs", summaries.items[0].meta);
    try std.testing.expectEqualStrings("2026-05-28", summaries.items[0].aux);
}

test "session listing returns resumable leaf names last updated first" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try setSessionListingTestFileMtime(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl", 1);
    try setSessionListingTestFileMtime(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl", 2);

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), list.file_names.len);
    try std.testing.expect(!list.truncated);
    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_first.jsonl", list.file_names[0]);
    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", list.file_names[1]);
}

test "session listing is bounded and ignores non session files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/sessions/--repo--/notes.txt",
        .data = "ignore",
    });

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .max_sessions = 1,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), list.file_names.len);
    try std.testing.expect(list.truncated);
    try std.testing.expect(std.mem.endsWith(u8, list.file_names[0], ".jsonl"));
}

test "session listing returns empty when session directory is absent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);

    var list = try listRuntimeSessions(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    });
    defer list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), list.file_names.len);
    try std.testing.expect(!list.truncated);
}

test "session selection accepts explicit resumable leaf name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_session.jsonl");

    const selected = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .selector = "2026-05-27T00:00:00Z_session.jsonl",
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_session.jsonl", selected);
}

test "session selection accepts session id prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_tui-1781704148400901000.jsonl");

    const exact = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .selector = "tui-1781704148400901000",
    })).?;
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_tui-1781704148400901000.jsonl", exact);

    const partial = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .selector = "tui-178",
    })).?;
    defer std.testing.allocator.free(partial);
    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_tui-1781704148400901000.jsonl", partial);
}

test "session selection by exact id ignores resident list cap" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_target.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_newer.jsonl");

    const selected = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .selector = "target",
        .max_sessions = 1,
        .max_directory_entries = 1,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-27T00:00:00Z_target.jsonl", selected);
}

test "session selection rejects ambiguous session id prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_tui-a.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_tui-b.jsonl");

    try std.testing.expectError(
        error.AmbiguousSessionSelector,
        selectRuntimeSession(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .selector = "tui-",
        }),
    );
}

test "session selection chooses newest only from complete listing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);
    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");

    const selected = (try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
    })).?;
    defer std.testing.allocator.free(selected);

    try std.testing.expectEqualStrings("2026-05-28T00:00:00Z_second.jsonl", selected);
}

test "session selection rejects traversal and reports absent sessions" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try createSessionListingTestDirs(tmp.dir);

    try std.testing.expectError(
        error.InvalidSessionFileName,
        selectRuntimeSession(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .selector = "../outside.jsonl",
        }),
    );

    const selected = try selectRuntimeSession(std.testing.allocator, std.testing.io, .{
        .cwd = "repo",
        .agent_dir_override = "agent",
        .dir = tmp.dir,
        .selector = "2026-05-27T00:00:00Z_missing.jsonl",
    });

    try std.testing.expect(selected == null);
}

test "session selection fails when newest listing is truncated" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSessionListingTestFile(tmp.dir, "2026-05-27T00:00:00Z_first.jsonl");
    try writeSessionListingTestFile(tmp.dir, "2026-05-28T00:00:00Z_second.jsonl");

    try std.testing.expectError(
        error.SessionListTruncated,
        selectRuntimeSession(std.testing.allocator, std.testing.io, .{
            .cwd = "repo",
            .agent_dir_override = "agent",
            .dir = tmp.dir,
            .max_sessions = 1,
        }),
    );
}
