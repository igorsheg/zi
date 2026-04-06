const std = @import("std");
const proto = @import("protocol.zig");
const writer_mod = @import("writer.zig");
const reader_mod = @import("reader.zig");
const context_mod = @import("context.zig");
const storage = @import("../storage.zig");
const agent_mod = @import("../agent/root.zig");

/// Metadata about a session file, for listing.
pub const SessionInfo = struct {
    path: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    timestamp: []const u8,
    /// Number of message entries (rough indicator of session length).
    message_count: u32,
};

/// Facade over session writer/reader/context.
/// Manages a single session's lifecycle: create, open, append, read, build context.
pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    writer: writer_mod.SessionWriter,
    /// Cached entries from last read (for buildContext). Null until open() or first read.
    cached_entries: ?[]proto.SessionEntry = null,
    cached_header: ?proto.SessionHeader = null,

    /// Create a new session for the given cwd.
    pub fn create(allocator: std.mem.Allocator, cwd: []const u8) SessionStore {
        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.init(allocator, cwd),
        };
    }

    /// Open an existing session file.
    /// Reads entries, seeds the writer for continuation.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SessionStore {
        const data = try reader_mod.readSessionFile(allocator, path);
        const header = data.header orelse return error.InvalidSessionFile;

        const leaf_id: ?[]const u8 = if (data.entries.len > 0)
            data.entries[data.entries.len - 1].id
        else
            null;

        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.initContinue(
                allocator,
                try allocator.dupe(u8, path),
                header.id,
                leaf_id,
            ),
            .cached_entries = data.entries,
            .cached_header = header,
        };
    }

    // ── Accessors ────────────────────────────────────────────────

    pub fn sessionId(self: *const SessionStore) []const u8 {
        return self.writer.session_id;
    }

    pub fn sessionFile(self: *const SessionStore) []const u8 {
        return self.writer.session_file;
    }

    pub fn leafId(self: *const SessionStore) ?[]const u8 {
        return self.writer.leaf_id;
    }

    // ── Append methods (delegate to writer) ──────────────────────

    pub fn appendMessage(self: *SessionStore, msg: agent_mod.protocol.AgentMessage) void {
        self.writer.appendMessage(msg);
    }

    pub fn appendThinkingLevelChange(self: *SessionStore, level: []const u8) void {
        self.writer.appendThinkingLevelChange(level);
    }

    pub fn appendModelChange(self: *SessionStore, provider: []const u8, model_id: []const u8) void {
        self.writer.appendModelChange(provider, model_id);
    }

    pub fn appendCompaction(self: *SessionStore, summary: []const u8, first_kept_entry_id: []const u8, tokens_before: u64) void {
        self.writer.appendCompaction(summary, first_kept_entry_id, tokens_before);
    }

    pub fn appendBranchSummary(self: *SessionStore, from_id: []const u8, summary: []const u8) void {
        self.writer.appendBranchSummary(from_id, summary);
    }

    pub fn appendSessionInfo(self: *SessionStore, name: ?[]const u8) void {
        self.writer.appendSessionInfo(name);
    }

    // ── Context building ─────────────────────────────────────────

    /// Build the LLM context from this session's entries.
    /// If the session was opened, uses cached entries.
    /// Otherwise reads the file from disk.
    pub fn buildContext(self: *SessionStore, leaf_id: ?[]const u8) !context_mod.SessionContext {
        if (self.cached_entries) |entries| {
            return context_mod.buildSessionContext(self.allocator, entries, leaf_id);
        }
        const data = try reader_mod.readSessionFile(self.allocator, self.writer.session_file);
        self.cached_entries = data.entries;
        self.cached_header = data.header;
        return context_mod.buildSessionContext(self.allocator, data.entries, leaf_id);
    }
};

// ── Session discovery ────────────────────────────────────────────────

/// Find the most recent valid session file for a cwd.
/// Scans the session directory for .jsonl files, validates headers,
/// returns the path of the most recently modified valid session.
/// pi-mono: session-manager.ts:476-489 (findMostRecentSession)
pub fn findMostRecentSession(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
    defer allocator.free(session_dir);
    return findMostRecentInDir(allocator, session_dir);
}

/// Find the most recent valid session in a specific directory.
fn findMostRecentInDir(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    var dir = std.fs.openDirAbsolute(dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close();

    var best_path: ?[]const u8 = null;
    var best_mtime: i128 = 0;

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (isValidSessionFile(full_path)) {
            const stat = dir.statFile(entry.name) catch {
                allocator.free(full_path);
                continue;
            };
            if (best_path == null or stat.mtime > best_mtime) {
                if (best_path) |old| allocator.free(old);
                best_path = full_path;
                best_mtime = stat.mtime;
            } else {
                allocator.free(full_path);
            }
        } else {
            allocator.free(full_path);
        }
    }

    return best_path;
}

/// Check if a file starts with a valid session header.
/// Reads only the first line (up to 4KB) to minimize I/O.
fn isValidSessionFile(path: []const u8) bool {
    const file = std.fs.openFileAbsolute(path, .{}) catch return false;
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.read(&buf) catch return false;
    if (n == 0) return false;

    const first_line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
    const first_line = buf[0..first_line_end];

    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, first_line, .{
        .allocate = .alloc_always,
    }) catch return false;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const type_val = obj.get("type") orelse return false;
    if (type_val != .string) return false;
    if (!std.mem.eql(u8, type_val.string, "session")) return false;
    const id_val = obj.get("id") orelse return false;
    return id_val == .string;
}

/// List all valid sessions for a cwd.
/// Returns metadata sorted by most recent first.
pub fn listSessions(allocator: std.mem.Allocator, cwd: []const u8) ![]SessionInfo {
    const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
    defer allocator.free(session_dir);

    var dir = std.fs.openDirAbsolute(session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close();

    var results: std.ArrayListUnmanaged(SessionInfo) = .empty;
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });

        const file = std.fs.openFileAbsolute(full_path, .{}) catch {
            allocator.free(full_path);
            continue;
        };
        defer file.close();

        var buf: [4096]u8 = undefined;
        const n = file.read(&buf) catch {
            allocator.free(full_path);
            continue;
        };
        if (n == 0) {
            allocator.free(full_path);
            continue;
        }

        const first_line_end = std.mem.indexOfScalar(u8, buf[0..n], '\n') orelse n;
        const parsed = std.json.parseFromSlice(std.json.Value, allocator, buf[0..first_line_end], .{
            .allocate = .alloc_always,
        }) catch {
            allocator.free(full_path);
            continue;
        };
        defer parsed.deinit();

        const obj = parsed.value.object;
        const type_val = obj.get("type") orelse {
            allocator.free(full_path);
            continue;
        };
        if (type_val != .string or !std.mem.eql(u8, type_val.string, "session")) {
            allocator.free(full_path);
            continue;
        }

        const id_str = if (obj.get("id")) |v| (if (v == .string) v.string else null) else null;
        const cwd_str = if (obj.get("cwd")) |v| (if (v == .string) v.string else null) else null;
        const ts_str = if (obj.get("timestamp")) |v| (if (v == .string) v.string else null) else null;

        if (id_str == null) {
            allocator.free(full_path);
            continue;
        }

        try results.append(allocator, .{
            .path = full_path,
            .session_id = try allocator.dupe(u8, id_str.?),
            .cwd = try allocator.dupe(u8, cwd_str orelse ""),
            .timestamp = try allocator.dupe(u8, ts_str orelse ""),
            .message_count = 0,
        });
    }

    const items = results.items;
    for (1..items.len) |i| {
        const key = items[i];
        var j: usize = i;
        while (j > 0) {
            if (std.mem.lessThan(u8, items[j - 1].timestamp, key.timestamp)) {
                items[j] = items[j - 1];
                j -= 1;
            } else break;
        }
        items[j] = key;
    }

    return items;
}
