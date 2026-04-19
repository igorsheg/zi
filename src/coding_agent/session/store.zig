const std = @import("std");
const proto = @import("../../session/protocol.zig");
const writer_mod = @import("writer.zig");
const reader_mod = @import("reader.zig");
const context_mod = @import("../../session/context.zig");
const storage = @import("../../storage.zig");
const agent_mod = @import("../../agent3/root.zig");

/// Metadata about a session file, for listing.
pub const SessionInfo = struct {
    path: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    timestamp: []const u8,
    /// File mtime in ns-like stat units. Used for picker ordering so
    /// recently active sessions appear first, even if they were
    /// created long ago.
    modified_at: i128 = 0,
    /// First user message text (preview/summary). Truncated to ~200 chars.
    first_message: []const u8,
    /// Number of message entries.
    message_count: u32,
};

fn freeSessionInfoFields(allocator: std.mem.Allocator, info: SessionInfo) void {
    allocator.free(info.path);
    allocator.free(info.session_id);
    allocator.free(info.cwd);
    allocator.free(info.timestamp);
    allocator.free(info.first_message);
}

pub fn freeSessionInfos(allocator: std.mem.Allocator, sessions: []SessionInfo) void {
    if (sessions.len == 0) return;
    for (sessions) |info| freeSessionInfoFields(allocator, info);
    allocator.free(sessions);
}

/// Facade over session writer/reader/context.
/// Manages a single session's lifecycle: create, open, append, read, build context.
pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    writer: writer_mod.SessionWriter,
    /// Cache backing arena for parsed session-file data. We keep parsed
    /// header/entries in an owned arena so cache invalidation is a single
    /// arena teardown instead of per-field frees against whatever allocator
    /// the session was created with (often the long-lived agent arena).
    cache_arena: ?std.heap.ArenaAllocator = null,
    /// Cached entries from last read (for buildContext). Null until open() or first read.
    cached_entries: ?[]proto.SessionEntry = null,
    cached_header: ?proto.SessionHeader = null,

    /// Create a new session. `session_dir` is the already-resolved directory
    /// (from `sdk.resolveSessionDir`) so v2's `session_directory` extension
    /// hook has a chance to override it before the store exists. Callers
    /// that don't care can pass `storage.getSessionDirForCwd(...)` directly.
    pub fn create(allocator: std.mem.Allocator, session_dir: []const u8, project_cwd: []const u8) SessionStore {
        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.init(allocator, session_dir, project_cwd),
        };
    }

    /// Create an ephemeral session (no disk persistence).
    /// Used for --no-session sub-agents.
    pub fn createEphemeral(allocator: std.mem.Allocator) SessionStore {
        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.initEphemeral(allocator),
        };
    }

    /// Open an existing session file.
    /// Reads entries, seeds the writer for continuation.
    pub fn open(allocator: std.mem.Allocator, path: []const u8) !SessionStore {
        var cache_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer cache_arena.deinit();
        const cache_alloc = cache_arena.allocator();

        const data = try reader_mod.readSessionFile(cache_alloc, path);
        const session_header = data.header orelse return error.InvalidSessionFile;

        const leaf_id: ?[]const u8 = if (data.entries.len > 0)
            data.entries[data.entries.len - 1].id
        else
            null;

        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.initContinue(
                allocator,
                try allocator.dupe(u8, path),
                try allocator.dupe(u8, session_header.id),
                try allocator.dupe(u8, session_header.cwd),
                if (leaf_id) |id| try allocator.dupe(u8, id) else null,
            ),
            .cache_arena = cache_arena,
            .cached_entries = data.entries,
            .cached_header = session_header,
        };
    }

    pub fn deinit(self: *SessionStore) void {
        self.clearCache();
        self.writer.deinit();
    }

    // ── Accessors ────────────────────────────────────────────────

    pub fn sessionId(self: *const SessionStore) []const u8 {
        return self.writer.session_id;
    }

    pub fn sessionFile(self: *const SessionStore) []const u8 {
        return self.writer.session_file;
    }

    pub fn currentEntryId(self: *const SessionStore) ?[]const u8 {
        return self.writer.leaf_id;
    }

    pub fn leafId(self: *const SessionStore) ?[]const u8 {
        return self.currentEntryId();
    }

    pub fn header(self: *const SessionStore) ?proto.SessionHeader {
        if (self.cached_header) |session_header| return session_header;
        if (self.writer.buffered_entries.items.len == 0) return null;
        return switch (self.writer.buffered_entries.items[0]) {
            .header => |session_header| session_header,
            .entry => null,
        };
    }

    pub fn cwd(self: *const SessionStore) []const u8 {
        if (self.cached_header) |session_header| return session_header.cwd;
        return self.writer.cwd;
    }

    // ── Append methods (delegate to writer) ──────────────────────

    pub fn appendMessage(self: *SessionStore, msg: agent_mod.protocol.AgentMessage) void {
        self.invalidateCache();
        self.writer.appendMessage(msg);
    }

    pub fn appendThinkingLevelChange(self: *SessionStore, level: []const u8) void {
        self.invalidateCache();
        self.writer.appendThinkingLevelChange(level);
    }

    pub fn appendModelChange(self: *SessionStore, provider: []const u8, model_id: []const u8) void {
        self.invalidateCache();
        self.writer.appendModelChange(provider, model_id);
    }

    pub fn appendCompaction(self: *SessionStore, summary: []const u8, first_kept_entry_id: []const u8, tokens_before: u64) void {
        self.invalidateCache();
        self.writer.appendCompaction(summary, first_kept_entry_id, tokens_before);
    }

    pub fn appendBranchSummary(self: *SessionStore, from_id: []const u8, summary: []const u8) void {
        self.invalidateCache();
        self.writer.appendBranchSummary(from_id, summary);
    }

    pub fn appendSessionInfo(self: *SessionStore, name: ?[]const u8) void {
        self.invalidateCache();
        self.writer.appendSessionInfo(name);
    }

    pub fn appendCustomEntry(self: *SessionStore, custom_type: []const u8, data: ?std.json.Value) void {
        self.invalidateCache();
        self.writer.appendCustomEntry(custom_type, data);
    }

    pub fn appendCustomMessage(self: *SessionStore, custom_type: []const u8, content: agent_mod.protocol.AgentMessage.CustomContent, display: bool, details: ?std.json.Value) void {
        self.invalidateCache();
        self.writer.appendCustomMessage(custom_type, content, display, details);
    }

    pub fn appendLabel(self: *SessionStore, target_id: []const u8, label: ?[]const u8) void {
        self.invalidateCache();
        self.writer.appendLabel(target_id, label);
    }

    // ── Context building ─────────────────────────────────────────

    /// Build the LLM context from this session's entries.
    /// If the session was opened, uses cached entries.
    /// Otherwise reads the file from disk.
    pub fn buildContext(self: *SessionStore, selection: context_mod.LeafSelection) !context_mod.SessionContext {
        return self.buildContextAlloc(self.allocator, selection);
    }

    pub fn buildCurrentContext(self: *SessionStore) !context_mod.SessionContext {
        return self.buildContext(.current);
    }

    pub fn buildContextAlloc(self: *SessionStore, allocator: std.mem.Allocator, selection: context_mod.LeafSelection) !context_mod.SessionContext {
        if (self.cached_entries) |entries| {
            return context_mod.buildSessionContext(allocator, entries, selection);
        }
        const data = try self.readIntoCache();
        return context_mod.buildSessionContext(allocator, data.entries, selection);
    }

    pub fn buildCurrentContextAlloc(self: *SessionStore, allocator: std.mem.Allocator) !context_mod.SessionContext {
        return self.buildContextAlloc(allocator, .current);
    }

    pub fn buildBranchEntriesAlloc(self: *SessionStore, allocator: std.mem.Allocator, selection: context_mod.LeafSelection) ![]const proto.SessionEntry {
        if (self.cached_entries) |entries| {
            return context_mod.buildBranchEntries(allocator, entries, selection);
        }
        const data = try self.readIntoCache();
        return context_mod.buildBranchEntries(allocator, data.entries, selection);
    }

    pub fn buildCurrentBranchAlloc(self: *SessionStore, allocator: std.mem.Allocator) ![]const proto.SessionEntry {
        return self.buildBranchEntriesAlloc(allocator, .current);
    }

    pub fn readEntries(self: *SessionStore) ![]proto.SessionEntry {
        if (self.cached_entries) |entries| return entries;
        const data = try self.readIntoCache();
        return data.entries;
    }

    fn invalidateCache(self: *SessionStore) void {
        self.clearCache();
    }

    fn readIntoCache(self: *SessionStore) !reader_mod.SessionData {
        var cache_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer cache_arena.deinit();
        const data = try reader_mod.readSessionFile(cache_arena.allocator(), self.writer.session_file);
        self.clearCache();
        self.cache_arena = cache_arena;
        self.cached_entries = data.entries;
        self.cached_header = data.header;
        return data;
    }

    fn clearCache(self: *SessionStore) void {
        if (self.cache_arena) |*arena| {
            arena.deinit();
            self.cache_arena = null;
        }
        self.cached_entries = null;
        self.cached_header = null;
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
    return findMostRecentSessionInDir(allocator, session_dir);
}

/// Find the most recent valid session in a specific directory.
pub fn findMostRecentSessionInDir(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
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

    // Tiny parse helper allocation, freed immediately after header validation.
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
/// Reads each file to extract header + first user message + message count.
pub fn listSessions(allocator: std.mem.Allocator, cwd: []const u8) ![]SessionInfo {
    const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
    defer allocator.free(session_dir);
    return listSessionsInDir(allocator, session_dir);
}

/// List all valid sessions in a specific directory.
/// Returns metadata sorted by most recent first.
pub fn listSessionsInDir(allocator: std.mem.Allocator, session_dir: []const u8) ![]SessionInfo {
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
        const stat = dir.statFile(entry.name) catch {
            allocator.free(full_path);
            continue;
        };

        if (scanSessionFile(allocator, full_path)) |info| {
            var session = info;
            session.modified_at = stat.mtime;
            try results.append(allocator, session);
        } else {
            allocator.free(full_path);
        }
    }

    // Sort by file mtime descending (most recent activity first).
    const items = results.items;
    for (1..items.len) |i| {
        const key = items[i];
        var j: usize = i;
        while (j > 0) {
            if (items[j - 1].modified_at < key.modified_at) {
                items[j] = items[j - 1];
                j -= 1;
            } else break;
        }
        items[j] = key;
    }

    return try results.toOwnedSlice(allocator);
}

/// Read a session file and extract listing metadata.
/// Reads the full file but only JSON-parses the header and first user message.
fn scanSessionFile(allocator: std.mem.Allocator, path: []const u8) ?SessionInfo {
    const content = std.fs.cwd().readFileAlloc(allocator, path, 10 * 1024 * 1024) catch return null;
    defer allocator.free(content);

    var session_id: ?[]const u8 = null;
    var cwd_str: ?[]const u8 = null;
    var ts_str: ?[]const u8 = null;
    var first_message: ?[]const u8 = null;
    var message_count: u32 = 0;
    var found_header = false;
    var success = false;
    defer if (!success) {
        if (session_id) |s| allocator.free(s);
        if (cwd_str) |s| allocator.free(s);
        if (ts_str) |s| allocator.free(s);
        if (first_message) |s| allocator.free(s);
    };

    var line_start: usize = 0;
    while (line_start < content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const line = std.mem.trim(u8, content[line_start..line_end], &std.ascii.whitespace);
        line_start = line_end + 1;

        if (line.len == 0) continue;

        // Quick check: find "type" field without full JSON parse
        if (std.mem.indexOf(u8, line, "\"type\":\"session\"") != null or
            std.mem.indexOf(u8, line, "\"type\": \"session\"") != null)
        {
            // Parse header
            const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
                .allocate = .alloc_always,
            }) catch continue;
            defer parsed.deinit();

            const obj = parsed.value.object;
            session_id = if (obj.get("id")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch null else null) else null;
            cwd_str = if (obj.get("cwd")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch null else null) else null;
            ts_str = if (obj.get("timestamp")) |v| (if (v == .string) allocator.dupe(u8, v.string) catch null else null) else null;
            found_header = session_id != null;
            continue;
        }

        if (std.mem.indexOf(u8, line, "\"type\":\"message\"") != null or
            std.mem.indexOf(u8, line, "\"type\": \"message\"") != null)
        {
            message_count += 1;

            // Extract first user message
            if (first_message == null) {
                if (std.mem.indexOf(u8, line, "\"role\":\"user\"") != null or
                    std.mem.indexOf(u8, line, "\"role\": \"user\"") != null)
                {
                    first_message = extractUserMessageText(allocator, line);
                }
            }
        }
    }

    if (!found_header) return null;

    const result = SessionInfo{
        .path = path,
        .session_id = session_id orelse allocator.dupe(u8, "") catch return null,
        .cwd = cwd_str orelse allocator.dupe(u8, "") catch return null,
        .timestamp = ts_str orelse allocator.dupe(u8, "") catch return null,
        .first_message = first_message orelse allocator.dupe(u8, "(no messages)") catch return null,
        .message_count = message_count,
    };
    success = true;
    return result;
}

/// Extract user message text from a JSONL line. Returns truncated preview.
fn extractUserMessageText(allocator: std.mem.Allocator, line: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, line, .{
        .allocate = .alloc_always,
    }) catch return null;
    defer parsed.deinit();

    const obj = parsed.value.object;
    const msg_val = obj.get("message") orelse return null;
    if (msg_val != .object) return null;
    const msg_obj = msg_val.object;

    const content_val = msg_obj.get("content") orelse return null;

    // String content (simple user message)
    if (content_val == .string) {
        return truncatePreview(allocator, content_val.string);
    }

    // Array content — find first text block
    if (content_val == .array) {
        for (content_val.array.items) |block| {
            if (block != .object) continue;
            const block_obj = block.object;
            const type_v = block_obj.get("type") orelse continue;
            if (type_v != .string or !std.mem.eql(u8, type_v.string, "text")) continue;
            const text_v = block_obj.get("text") orelse continue;
            if (text_v == .string) return truncatePreview(allocator, text_v.string);
        }
    }

    return null;
}

/// Truncate to ~200 chars, collapse whitespace, single line.
fn truncatePreview(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const max_len = 200;
    const cap = @min(text.len, max_len) + 3;
    const scratch = allocator.alloc(u8, cap) catch return null; // +3 for "..."
    defer allocator.free(scratch);

    var pos: usize = 0;
    var prev_ws = false;

    for (text) |c| {
        if (pos >= max_len) break;
        if (c == '\n' or c == '\r' or c == '\t') {
            if (!prev_ws and pos > 0) {
                scratch[pos] = ' ';
                pos += 1;
                prev_ws = true;
            }
        } else {
            scratch[pos] = c;
            pos += 1;
            prev_ws = false;
        }
    }

    if (text.len > max_len and pos > 0 and pos + 3 <= scratch.len) {
        scratch[pos] = '.';
        scratch[pos + 1] = '.';
        scratch[pos + 2] = '.';
        pos += 3;
    }

    return allocator.dupe(u8, scratch[0..pos]) catch null;
}

test "open duplicates writer session and leaf ids from cached session data" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "session.jsonl",
        .data = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
            "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n",
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "session.jsonl");
    defer std.testing.allocator.free(path);

    var store = try SessionStore.open(std.testing.allocator, path);
    defer store.deinit();

    try std.testing.expect(store.cached_header != null);
    try std.testing.expect(store.cached_entries != null);
    try std.testing.expect(store.writer.session_id.len > 0);
    try std.testing.expect(store.writer.session_id.ptr != store.cached_header.?.id.ptr);
    try std.testing.expect(store.writer.leaf_id != null);
    try std.testing.expect(store.writer.leaf_id.?.ptr != store.cached_entries.?[0].id.ptr);

    store.appendSessionInfo("name");
    try std.testing.expect(store.cached_entries == null);
    try std.testing.expect(store.cached_header == null);
}

test "cache invalidation works when store uses arena allocator" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "session.jsonl",
        .data = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
            "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n",
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "session.jsonl");
    defer std.testing.allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = try SessionStore.open(arena.allocator(), path);
    defer store.deinit();

    try std.testing.expect(store.cached_entries != null);
    store.appendSessionInfo("name");
    try std.testing.expect(store.cached_entries == null);
    try std.testing.expect(store.cache_arena == null);
}
