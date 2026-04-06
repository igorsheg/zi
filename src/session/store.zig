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
    /// First user message text (preview/summary). Truncated to ~200 chars.
    first_message: []const u8,
    /// Number of message entries.
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
/// Reads each file to extract header + first user message + message count.
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

        if (scanSessionFile(allocator, full_path)) |info| {
            try results.append(allocator, info);
        } else {
            allocator.free(full_path);
        }
    }

    // Sort by timestamp descending (most recent first)
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

    return .{
        .path = path,
        .session_id = session_id orelse "",
        .cwd = cwd_str orelse "",
        .timestamp = ts_str orelse "",
        .first_message = first_message orelse "(no messages)",
        .message_count = message_count,
    };
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
    var buf = allocator.alloc(u8, @min(text.len, max_len) + 3) catch return null; // +3 for "..."
    var pos: usize = 0;
    var prev_ws = false;

    for (text) |c| {
        if (pos >= max_len) break;
        if (c == '\n' or c == '\r' or c == '\t') {
            if (!prev_ws and pos > 0) {
                buf[pos] = ' ';
                pos += 1;
                prev_ws = true;
            }
        } else {
            buf[pos] = c;
            pos += 1;
            prev_ws = false;
        }
    }

    if (text.len > max_len and pos > 0) {
        if (pos + 3 <= buf.len) {
            buf[pos] = '.';
            buf[pos + 1] = '.';
            buf[pos + 2] = '.';
            pos += 3;
        }
    }

    return buf[0..pos];
}
