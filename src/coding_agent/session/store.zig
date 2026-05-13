const std = @import("std");
const proto = @import("../../session/protocol.zig");
const writer_mod = @import("writer.zig");
const reader_mod = @import("reader.zig");
const context_mod = @import("../../session/context.zig");
const context_usage = @import("../../session/context_usage.zig");
const storage = @import("../../storage.zig");
const agent_mod = @import("../../agent/root.zig");
const zio_fs = @import("../../zio/root.zig").file;

pub const SessionInfo = struct {
    path: []const u8,
    session_id: []const u8,
    cwd: []const u8,
    timestamp: []const u8,

    modified_at: i128 = 0,

    first_message: []const u8,

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

pub const OpenSessionResult = struct {
    store: ?SessionStore,
    context_arena: std.heap.ArenaAllocator,
    messages: []agent_mod.protocol.AgentMessage,
    model: ?context_mod.SessionContext.ModelInfo,
    thinking_level: []const u8,

    pub fn deinit(self: *OpenSessionResult) void {
        self.context_arena.deinit();
        if (self.store) |*store| {
            store.deinit();
            self.store = null;
        }
    }

    pub fn takeStore(self: *OpenSessionResult) SessionStore {
        const store = self.store orelse @panic("OpenSessionResult.takeStore called twice");
        self.store = null;
        return store;
    }
};

pub const SessionStore = struct {
    allocator: std.mem.Allocator,
    writer: writer_mod.SessionWriter,

    cache_arena: ?std.heap.ArenaAllocator = null,

    cached_entries: ?[]proto.SessionEntry = null,
    cached_header: ?proto.SessionHeader = null,

    pub fn create(allocator: std.mem.Allocator, session_dir: []const u8, project_cwd: []const u8) SessionStore {
        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.init(allocator, session_dir, project_cwd),
        };
    }

    pub fn createForCwd(allocator: std.mem.Allocator, project_cwd: []const u8, agent_dir_override: ?[]const u8) !SessionStore {
        const session_dir = try storage.getSessionDirForCwd(allocator, project_cwd, agent_dir_override);
        defer allocator.free(session_dir);
        return SessionStore.create(allocator, session_dir, project_cwd);
    }

    pub fn createEphemeral(allocator: std.mem.Allocator) SessionStore {
        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.initEphemeral(allocator),
        };
    }

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

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const owned_session_id = try allocator.dupe(u8, session_header.id);
        errdefer allocator.free(owned_session_id);
        const owned_cwd = try allocator.dupe(u8, session_header.cwd);
        errdefer allocator.free(owned_cwd);
        const owned_leaf_id = if (leaf_id) |id| try allocator.dupe(u8, id) else null;
        errdefer if (owned_leaf_id) |id| allocator.free(id);

        return .{
            .allocator = allocator,
            .writer = writer_mod.SessionWriter.initContinue(
                allocator,
                owned_path,
                owned_session_id,
                owned_cwd,
                owned_leaf_id,
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

    pub fn appendMessage(self: *SessionStore, msg: agent_mod.protocol.AgentMessage) ?[]const u8 {
        self.invalidateCache();
        return self.writer.appendMessage(msg);
    }

    pub fn appendThinkingLevelChange(self: *SessionStore, level: []const u8) void {
        self.invalidateCache();
        self.writer.appendThinkingLevelChange(level);
    }

    pub fn appendModelChange(self: *SessionStore, provider: []const u8, model_id: []const u8) void {
        self.invalidateCache();
        self.writer.appendModelChange(provider, model_id);
    }

    pub fn appendCompaction(
        self: *SessionStore,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        details: ?std.json.Value,
        from_hook: ?bool,
    ) void {
        self.invalidateCache();
        self.writer.appendCompaction(summary, first_kept_entry_id, tokens_before, details, from_hook);
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

    pub fn appendRuntimeDefaults(self: *SessionStore, provider: []const u8, model_id: []const u8, thinking_level: []const u8) void {
        self.appendModelChange(provider, model_id);
        self.appendThinkingLevelChange(thinking_level);
    }

    pub fn openForResume(allocator: std.mem.Allocator, session_path: []const u8) !OpenSessionResult {
        var store = try SessionStore.open(allocator, session_path);
        errdefer store.deinit();

        var context_arena = std.heap.ArenaAllocator.init(allocator);
        errdefer context_arena.deinit();

        const ctx = try store.buildContextAlloc(context_arena.allocator(), .current);
        return .{
            .store = store,
            .context_arena = context_arena,
            .messages = ctx.messages,
            .model = ctx.model,
            .thinking_level = ctx.thinking_level,
        };
    }

    pub fn buildContextAlloc(self: *SessionStore, allocator: std.mem.Allocator, selection: context_mod.LeafSelection) !context_mod.SessionContext {
        if (self.cached_entries) |entries| {
            const merged = try self.cachedEntriesWithAppends(allocator, entries);
            defer if (merged.ptr != entries.ptr) allocator.free(merged);
            return context_mod.buildSessionContext(allocator, merged, selection);
        }
        const data = try self.readIntoCache();
        return context_mod.buildSessionContext(allocator, data.entries, selection);
    }

    pub fn buildBranchEntriesAlloc(self: *SessionStore, allocator: std.mem.Allocator, selection: context_mod.LeafSelection) ![]const proto.SessionEntry {
        if (self.cached_entries) |entries| {
            const merged = try self.cachedEntriesWithAppends(allocator, entries);
            defer if (merged.ptr != entries.ptr) allocator.free(merged);
            return context_mod.buildBranchEntries(allocator, merged, selection);
        }
        const data = try self.readIntoCache();
        return context_mod.buildBranchEntries(allocator, data.entries, selection);
    }

    pub fn buildCurrentVisibleBranchAlloc(self: *SessionStore, allocator: std.mem.Allocator) ![]const proto.SessionEntry {
        const persisted = self.buildBranchEntriesAlloc(allocator, .current) catch |err| switch (err) {
            error.FileNotFound => &.{},
            else => return err,
        };
        defer allocator.free(persisted);

        var buffered_count: usize = 0;
        for (self.writer.buffered_entries.items) |item| switch (item) {
            .entry => buffered_count += 1,
            .header => {},
        };

        if (buffered_count == 0) return try allocator.dupe(proto.SessionEntry, persisted);

        const all = try allocator.alloc(proto.SessionEntry, persisted.len + buffered_count);
        @memcpy(all[0..persisted.len], persisted);
        var index = persisted.len;
        for (self.writer.buffered_entries.items) |item| switch (item) {
            .entry => |entry| {
                all[index] = entry;
                index += 1;
            },
            .header => {},
        };
        const visible = try context_mod.buildBranchEntries(allocator, all, .current);
        allocator.free(all);
        return visible;
    }

    pub fn applyCompaction(
        self: *SessionStore,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        details: ?std.json.Value,
        from_hook: ?bool,
    ) !context_mod.SessionContext {
        self.appendCompaction(summary, first_kept_entry_id, tokens_before, details, from_hook);
        return self.buildContextAlloc(self.allocator, .current);
    }

    pub fn contextUsageUnknownAfterCompaction(self: *SessionStore, allocator: std.mem.Allocator) bool {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const branch = self.buildBranchEntriesAlloc(arena.allocator(), .current) catch return false;
        if (context_mod.getLatestCompactionEntry(branch) == null) return false;
        return !hasPostCompactionUsage(branch);
    }

    pub fn readEntries(self: *SessionStore) ![]proto.SessionEntry {
        if (self.cached_entries) |entries| return entries;
        const data = try self.readIntoCache();
        return data.entries;
    }

    fn invalidateCache(self: *SessionStore) void {
        if (self.cached_entries != null and self.writer.persist and self.writer.flushed) return;
        self.clearCache();
    }

    fn cachedEntriesWithAppends(self: *SessionStore, allocator: std.mem.Allocator, entries: []proto.SessionEntry) ![]proto.SessionEntry {
        const appended = self.writer.appended_entries.items;
        if (appended.len == 0) return entries;
        const merged = try allocator.alloc(proto.SessionEntry, entries.len + appended.len);
        @memcpy(merged[0..entries.len], entries);
        @memcpy(merged[entries.len..], appended);
        return merged;
    }

    fn readIntoCache(self: *SessionStore) !reader_mod.SessionData {
        var cache_arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer cache_arena.deinit();
        const cache_alloc = cache_arena.allocator();

        const data = if (self.writer.session_file.len == 0) blk: {
            const buffered = self.writer.buffered_entries.items;
            var entry_count: usize = 0;
            for (buffered) |item| switch (item) {
                .entry => entry_count += 1,
                .header => {},
            };

            const entries = try cache_alloc.alloc(proto.SessionEntry, entry_count);
            var index: usize = 0;
            var buffered_header: ?proto.SessionHeader = null;
            for (buffered) |item| switch (item) {
                .header => |value| buffered_header = value,
                .entry => |value| {
                    entries[index] = value;
                    index += 1;
                },
            };
            break :blk reader_mod.SessionData{ .header = buffered_header, .entries = entries };
        } else try reader_mod.readSessionFile(cache_alloc, self.writer.session_file);

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

fn hasPostCompactionUsage(branch: []const proto.SessionEntry) bool {
    var i: usize = branch.len;
    scan: while (i > 0) {
        i -= 1;
        switch (branch[i].entry) {
            .compaction => break :scan,
            .message => |m| switch (m.message) {
                .assistant => |assistant| switch (assistant.stop_reason) {
                    .aborted, .@"error" => {},
                    else => return context_usage.calculateContextTokens(assistant.usage) > 0,
                },
                else => {},
            },
            else => {},
        }
    }
    return false;
}

pub fn findMostRecentSession(allocator: std.mem.Allocator, cwd: []const u8) !?[]const u8 {
    const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
    defer allocator.free(session_dir);
    return findMostRecentSessionInDir(allocator, session_dir);
}

pub fn findMostRecentSessionInDir(allocator: std.mem.Allocator, dir_path: []const u8) !?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, dir_path, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer dir.close(std.Options.debug_io);

    var best_path: ?[]const u8 = null;
    var best_mtime: std.Io.Timestamp = .zero;

    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        if (isValidSessionFile(full_path)) {
            const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch {
                allocator.free(full_path);
                continue;
            };
            if (best_path == null or stat.mtime.toNanoseconds() > best_mtime.toNanoseconds()) {
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

fn isValidSessionFile(path: []const u8) bool {
    const file = std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{}) catch return false;
    defer file.close(std.Options.debug_io);

    var buf: [4096]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &buf);
    const first_chunk = file_reader.interface.allocRemaining(std.heap.smp_allocator, .limited(buf.len)) catch return false;
    defer std.heap.smp_allocator.free(first_chunk);
    if (first_chunk.len == 0) return false;

    const first_line_end = std.mem.indexOfScalar(u8, first_chunk, '\n') orelse first_chunk.len;
    const first_line = first_chunk[0..first_line_end];

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

pub fn listSessions(allocator: std.mem.Allocator, cwd: []const u8) ![]SessionInfo {
    const session_dir = try storage.getSessionDirForCwd(allocator, cwd, null);
    defer allocator.free(session_dir);
    return listSessionsInDir(allocator, session_dir);
}

pub fn listSessionsInDir(allocator: std.mem.Allocator, session_dir: []const u8) ![]SessionInfo {
    var dir = std.Io.Dir.openDirAbsolute(std.Options.debug_io, session_dir, .{ .iterate = true }) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer dir.close(std.Options.debug_io);

    var results: std.ArrayListUnmanaged(SessionInfo) = .empty;
    var iter = dir.iterate();
    while (try iter.next(std.Options.debug_io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;

        const full_path = try std.fs.path.join(allocator, &.{ session_dir, entry.name });
        const stat = dir.statFile(std.Options.debug_io, entry.name, .{}) catch {
            allocator.free(full_path);
            continue;
        };

        if (scanSessionFile(allocator, full_path)) |info| {
            var session = info;
            session.modified_at = stat.mtime.toNanoseconds();
            try results.append(allocator, session);
        } else {
            allocator.free(full_path);
        }
    }

    std.sort.pdq(SessionInfo, results.items, {}, newerSessionFirst);

    return try results.toOwnedSlice(allocator);
}

fn newerSessionFirst(_: void, a: SessionInfo, b: SessionInfo) bool {
    return a.modified_at > b.modified_at;
}

fn scanSessionFile(allocator: std.mem.Allocator, path: []const u8) ?SessionInfo {
    var input = zio_fs.readOnlyBytes(std.Options.debug_io, allocator, path, .{ .max_bytes = 10 * 1024 * 1024 }) catch return null;
    defer input.deinit(allocator);
    const content = input.bytes();

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

        if (std.mem.indexOf(u8, line, "\"type\":\"session\"") != null or
            std.mem.indexOf(u8, line, "\"type\": \"session\"") != null)
        {
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

    if (content_val == .string) {
        return truncatePreview(allocator, content_val.string);
    }

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

fn truncatePreview(allocator: std.mem.Allocator, text: []const u8) ?[]const u8 {
    const max_len = 200;
    const cap = @min(text.len, max_len) + 3;
    const scratch = allocator.alloc(u8, cap) catch return null;
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

fn testUserMessage(text: []const u8, timestamp: i64) agent_mod.protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = timestamp,
    } };
}

fn testAssistantMessageWithUsage(allocator: std.mem.Allocator, text: []const u8, total_tokens: u64, timestamp: i64) !agent_mod.protocol.AgentMessage {
    const content = try allocator.alloc(@import("../../ai/root.zig").protocol.AssistantMessage.AssistantContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .assistant = .{
        .content = content,
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "claude-test",
        .usage = .{
            .input = total_tokens,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = total_tokens,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

const test_session_json = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n";

fn testSessionDir(tmp: *std.testing.TmpDir) ![:0]u8 {
    return try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", std.testing.allocator);
}

fn writeTestSession(tmp: *std.testing.TmpDir, data: []const u8) ![:0]u8 {
    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "session.jsonl", .data = data });
    return try tmp.dir.realPathFileAlloc(std.Options.debug_io, "session.jsonl", std.testing.allocator);
}

fn appendMessageOrFail(store: *SessionStore, msg: agent_mod.protocol.AgentMessage) ![]const u8 {
    return store.appendMessage(msg) orelse error.MissingAppendedEntry;
}

fn expectUserText(msg: agent_mod.protocol.AgentMessage, expected: []const u8) !void {
    try std.testing.expect(msg == .user);
    try std.testing.expectEqualStrings(expected, msg.user.content.text);
}

fn expectAssistantText(msg: agent_mod.protocol.AgentMessage, expected: []const u8) !void {
    try std.testing.expect(msg == .assistant);
    try std.testing.expectEqualStrings(expected, msg.assistant.content[0].text.text);
}

test "visible branch includes buffered metadata before first flush" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try testSessionDir(&tmp);
    defer std.testing.allocator.free(session_dir);

    var store = SessionStore.create(std.testing.allocator, session_dir, "/tmp/project");
    defer store.deinit();

    store.appendSessionInfo("test1");

    const branch = try store.buildCurrentVisibleBranchAlloc(std.testing.allocator);
    defer std.testing.allocator.free(branch);

    try std.testing.expectEqual(@as(usize, 1), branch.len);
    try std.testing.expect(branch[0].entry == .session_info);
    try std.testing.expectEqualStrings("test1", branch[0].entry.session_info.name.?);
}

test "openForResume builds context and lets caller take the store" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeTestSession(&tmp, test_session_json ++
        "{\"type\":\"model_change\",\"id\":\"m0\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:00Z\",\"provider\":\"anthropic\",\"modelId\":\"claude\"}\n" ++
        "{\"type\":\"thinking_level_change\",\"id\":\"t0\",\"parentId\":\"m0\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"thinkingLevel\":\"high\"}\n" ++
        "{\"type\":\"message\",\"id\":\"u1\",\"parentId\":\"t0\",\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n");
    defer std.testing.allocator.free(path);

    var opened = try SessionStore.openForResume(std.testing.allocator, path);
    defer opened.deinit();

    try std.testing.expectEqual(@as(usize, 1), opened.messages.len);
    try std.testing.expectEqualStrings("high", opened.thinking_level);
    try std.testing.expect(opened.model != null);
    try std.testing.expectEqualStrings("anthropic", opened.model.?.provider);
    try std.testing.expectEqualStrings("claude", opened.model.?.model_id);
    try expectUserText(opened.messages[0], "hi");

    var resumed_store = opened.takeStore();
    defer resumed_store.deinit();
    try std.testing.expectEqualStrings("abc", resumed_store.sessionId());
    try std.testing.expectEqualStrings("u1", resumed_store.currentEntryId().?);
}

test "flushed sessions persist large appended messages" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try testSessionDir(&tmp);
    defer std.testing.allocator.free(session_dir);

    var store = SessionStore.create(std.testing.allocator, session_dir, "/tmp/project");
    errdefer store.deinit();

    _ = try appendMessageOrFail(&store, testUserMessage("first", 1));

    const first_assistant = try testAssistantMessageWithUsage(std.testing.allocator, "ok", 10, 2);
    defer std.testing.allocator.free(first_assistant.assistant.content);
    _ = try appendMessageOrFail(&store, first_assistant);

    const large_text = try std.testing.allocator.alloc(u8, 8192);
    defer std.testing.allocator.free(large_text);
    @memset(large_text, 'x');

    const large_assistant = try testAssistantMessageWithUsage(std.testing.allocator, large_text, 20, 3);
    defer std.testing.allocator.free(large_assistant.assistant.content);
    const large_id = try appendMessageOrFail(&store, large_assistant);
    const large_id_copy = try std.testing.allocator.dupe(u8, large_id);
    defer std.testing.allocator.free(large_id_copy);

    _ = try appendMessageOrFail(&store, testUserMessage("after large", 4));

    const path = try std.testing.allocator.dupe(u8, store.sessionFile());
    defer std.testing.allocator.free(path);
    store.deinit();

    var opened = try SessionStore.openForResume(std.testing.allocator, path);
    defer opened.deinit();

    try std.testing.expectEqual(@as(usize, 4), opened.messages.len);
    try expectUserText(opened.messages[0], "first");
    try expectAssistantText(opened.messages[1], "ok");
    try std.testing.expectEqual(@as(usize, large_text.len), opened.messages[2].assistant.content[0].text.text.len);
    try expectUserText(opened.messages[3], "after large");

    const branch = try opened.store.?.buildBranchEntriesAlloc(std.testing.allocator, .current);
    defer std.testing.allocator.free(branch);
    try std.testing.expectEqualStrings(large_id_copy, branch[branch.len - 2].id);
    try std.testing.expectEqualStrings(large_id_copy, branch[branch.len - 1].parent_id.?);
}

test "applyCompaction stores artifact fields and rebuilds compacted context" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = SessionStore.createEphemeral(allocator);
    defer store.deinit();

    _ = store.appendMessage(testUserMessage("first", 1));
    _ = store.appendMessage(testUserMessage("second", 2));

    var details_obj: std.json.ObjectMap = .{};
    try details_obj.put(allocator, "artifact", .{ .string = "file-index" });

    const first_kept_id = store.currentEntryId().?;
    const rebuilt = try store.applyCompaction("summary", first_kept_id, 42, .{ .object = details_obj }, true);

    const entry = store.writer.buffered_entries.items[2].entry.entry.compaction;
    try std.testing.expectEqualStrings("summary", entry.summary);
    try std.testing.expectEqualStrings(first_kept_id, entry.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 42), entry.tokens_before);
    try std.testing.expectEqual(true, entry.from_hook.?);
    try std.testing.expectEqualStrings("file-index", entry.details.?.object.get("artifact").?.string);

    try std.testing.expectEqual(@as(usize, 2), rebuilt.messages.len);
    try std.testing.expect(rebuilt.messages[0] == .compaction_summary);
    try std.testing.expectEqualStrings("summary", rebuilt.messages[0].compaction_summary.summary);
    try std.testing.expect(rebuilt.messages[1] == .user);
    try std.testing.expectEqualStrings("second", rebuilt.messages[1].user.content.text);

    _ = store.appendMessage(testUserMessage("third", 3));
    const rebuilt_with_later = try store.buildContextAlloc(store.allocator, .current);
    try std.testing.expectEqual(@as(usize, 3), rebuilt_with_later.messages.len);
    try std.testing.expectEqualStrings("third", rebuilt_with_later.messages[2].user.content.text);
}

test "contextUsageUnknownAfterCompaction is true until assistant reports usage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var store = SessionStore.createEphemeral(allocator);
    defer store.deinit();

    _ = store.appendMessage(testUserMessage("first", 1));
    _ = store.appendMessage(try testAssistantMessageWithUsage(allocator, "response1", 180_000, 2));
    _ = store.appendMessage(testUserMessage("second", 3));
    const kept_user_id = store.currentEntryId().?;
    _ = store.appendMessage(try testAssistantMessageWithUsage(allocator, "response2", 195_000, 4));
    store.appendCompaction("summary", kept_user_id, 195_000, null, null);
    _ = store.appendMessage(testUserMessage("third", 5));

    try std.testing.expect(store.contextUsageUnknownAfterCompaction(allocator));

    _ = store.appendMessage(try testAssistantMessageWithUsage(allocator, "response3", 25_000, 6));
    try std.testing.expect(!store.contextUsageUnknownAfterCompaction(allocator));
}

test "open keeps cache and writer state alive after caller arena changes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try writeTestSession(&tmp, test_session_json ++
        "{\"type\":\"message\",\"id\":\"m1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n");
    defer std.testing.allocator.free(path);

    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    var store = try SessionStore.open(arena.allocator(), path);
    defer store.deinit();

    try std.testing.expectEqualStrings("abc", store.sessionId());
    try std.testing.expectEqualStrings("m1", store.currentEntryId().?);
    try std.testing.expect(store.cached_entries != null);

    store.appendSessionInfo("name");

    try std.testing.expect(store.cached_entries != null);
    try std.testing.expect(store.cached_header != null);
    try std.testing.expect(store.cache_arena != null);
    try std.testing.expectEqualStrings("abc", store.sessionId());
    try std.testing.expect(store.currentEntryId() != null);
}
