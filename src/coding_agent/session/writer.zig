const std = @import("std");
const agent = @import("../../agent3/root.zig");
const proto = @import("../../session/protocol.zig");
const json = @import("../../session/json.zig");
const time_util = @import("../../lib/time_util.zig");

/// Manages writing session entries to a JSONL file.
/// Tracks leafId for tree structure and generates unique entry IDs.
///
/// Matches pi-mono's SessionManager persistence behavior:
/// - Entries are buffered until the first assistant message appears
/// - Once flushed, each new entry is appended immediately
/// - This ensures crash durability after first meaningful exchange
pub const SessionWriter = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8,
    session_file: []const u8,
    cwd: []const u8,
    leaf_id: ?[]const u8,
    ids: std.StringHashMapUnmanaged(void),
    flushed: bool,
    has_assistant: bool,
    buffered_entries: std.ArrayListUnmanaged(proto.FileEntry),
    persist: bool,

    /// Construct a new writer. `session_dir` is the already-resolved directory
    /// for this session's files — the sdk layer computes it via
    /// `sdk.resolveSessionDir` BEFORE reaching here so the extension layer can
    /// override session placement before persistence starts. See
    /// `docs/extensions.md`.
    pub fn init(allocator: std.mem.Allocator, session_dir: []const u8, cwd: []const u8) SessionWriter {
        var uuid_buf: [36]u8 = undefined;
        generateUuid(&uuid_buf);
        const session_id = allocator.dupe(u8, &uuid_buf) catch @panic("OOM");

        const timestamp = time_util.isoTimestampNow(allocator) catch @panic("OOM");

        // Ensure directory exists
        std.fs.cwd().makePath(session_dir) catch {};

        const file_ts = allocator.dupe(u8, timestamp) catch @panic("OOM");
        defer allocator.free(file_ts);
        for (file_ts) |*c| {
            if (c.* == ':' or c.* == '.') c.* = '-';
        }
        const session_file = std.fmt.allocPrint(allocator, "{s}/{s}_{s}.jsonl", .{ session_dir, file_ts, session_id }) catch @panic("OOM");

        // Buffer the header as first entry
        const header = proto.SessionHeader{
            .id = session_id,
            .timestamp = timestamp,
            .cwd = cwd,
        };
        var buffered: std.ArrayListUnmanaged(proto.FileEntry) = .empty;
        buffered.append(allocator, .{ .header = header }) catch @panic("OOM");

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = session_file,
            .cwd = cwd,
            .leaf_id = null,
            .ids = .{},
            .flushed = false,
            .has_assistant = false,
            .buffered_entries = buffered,
            .persist = true,
        };
    }

    /// Create an ephemeral writer that tracks state in memory but never writes to disk.
    /// Used for --no-session sub-agents.
    pub fn initEphemeral(allocator: std.mem.Allocator) SessionWriter {
        var uuid_buf: [36]u8 = undefined;
        generateUuid(&uuid_buf);
        const session_id = allocator.dupe(u8, &uuid_buf) catch @panic("OOM");

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = "",
            .cwd = "",
            .leaf_id = null,
            .ids = .{},
            .flushed = false,
            .has_assistant = false,
            .buffered_entries = .empty,
            .persist = false,
        };
    }

    /// Continue writing to an existing session file.
    /// Seeds leaf_id so new entries chain from where the session left off.
    /// Skips header creation — the file already has one.
    /// Marks as already flushed (file exists on disk).
    pub fn initContinue(allocator: std.mem.Allocator, session_file: []const u8, session_id: []const u8, leaf_id: ?[]const u8) SessionWriter {
        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = session_file,
            .cwd = "",
            .leaf_id = leaf_id,
            .ids = .{},
            .flushed = true,
            .has_assistant = true,
            .buffered_entries = .empty,
            .persist = true,
        };
    }

    pub fn deinit(self: *SessionWriter) void {
        const leaf_owned_by_ids = if (self.leaf_id) |leaf_id| self.ids.contains(leaf_id) else false;

        var id_iter = self.ids.iterator();
        while (id_iter.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.ids.deinit(self.allocator);

        for (self.buffered_entries.items) |entry| freeBufferedFileEntry(self.allocator, entry, self.session_id);
        self.buffered_entries.deinit(self.allocator);

        if (self.leaf_id) |leaf_id| {
            if (!leaf_owned_by_ids) self.allocator.free(leaf_id);
        }
        self.allocator.free(self.session_id);
        if (self.session_file.len > 0) self.allocator.free(self.session_file);
    }

    /// Append a message entry. Matches pi-mono's message_end persistence:
    /// - Buffers until first assistant message appears
    /// - Then flushes all buffered entries + appends incrementally
    pub fn appendMessage(self: *SessionWriter, msg: agent.protocol.AgentMessage) void {
        const entry = self.createEntry(.{ .message = .{ .message = msg } }) orelse return;

        // Track if we've seen an assistant message
        switch (msg) {
            .assistant => self.has_assistant = true,
            else => {},
        }

        if (!self.has_assistant) {
            // Buffer until first assistant arrives
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch {};
            return;
        }

        if (!self.flushed) {
            // First assistant seen — flush everything buffered + this entry
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch {};
            self.flushAll();
            return;
        }

        // Already flushed — append incrementally
        self.appendToFile(entry) catch {};
    }

    /// Append a thinking level change entry.
    pub fn appendThinkingLevelChange(self: *SessionWriter, level: []const u8) void {
        self.appendEntry(.{ .thinking_level_change = .{ .thinking_level = level } });
    }

    /// Append a model change entry.
    pub fn appendModelChange(self: *SessionWriter, provider: []const u8, model_id: []const u8) void {
        self.appendEntry(.{ .model_change = .{ .provider = provider, .model_id = model_id } });
    }

    /// Append a compaction entry.
    pub fn appendCompaction(self: *SessionWriter, summary: []const u8, first_kept_entry_id: []const u8, tokens_before: u64) void {
        self.appendEntry(.{ .compaction = .{
            .summary = summary,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = tokens_before,
        } });
    }

    /// Append a branch summary entry.
    pub fn appendBranchSummary(self: *SessionWriter, from_id: []const u8, summary: []const u8) void {
        self.appendEntry(.{ .branch_summary = .{ .from_id = from_id, .summary = summary } });
    }

    /// Append a custom entry (extension state, NOT in LLM context).
    pub fn appendCustomEntry(self: *SessionWriter, custom_type: []const u8, data: ?std.json.Value) void {
        self.appendEntry(.{ .custom = .{ .custom_type = custom_type, .data = data } });
    }

    /// Append a custom message entry (extension message, IN LLM context).
    pub fn appendCustomMessage(self: *SessionWriter, custom_type: []const u8, content: agent.protocol.AgentMessage.CustomContent, display: bool, details: ?std.json.Value) void {
        self.appendEntry(.{ .custom_message = .{
            .custom_type = custom_type,
            .content = content,
            .display = display,
            .details = details,
        } });
    }

    /// Append a label entry (bookmark on another entry).
    pub fn appendLabel(self: *SessionWriter, target_id: []const u8, label: ?[]const u8) void {
        self.appendEntry(.{ .label = .{ .target_id = target_id, .label = label } });
    }

    /// Append a session info entry (display name, etc).
    pub fn appendSessionInfo(self: *SessionWriter, name: ?[]const u8) void {
        self.appendEntry(.{ .session_info = .{ .name = name } });
    }

    /// Shared logic for appending any non-message entry type.
    /// Non-message entries write immediately if flushed, otherwise buffer.
    fn appendEntry(self: *SessionWriter, entry_data: proto.SessionEntry.EntryType) void {
        const entry = self.createEntry(entry_data) orelse return;

        if (!self.flushed) {
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch {};
            return;
        }

        self.appendToFile(entry) catch {};
    }

    /// Create a session entry and update tree state (leaf_id, ids).
    fn createEntry(self: *SessionWriter, entry_data: proto.SessionEntry.EntryType) ?proto.SessionEntry {
        const entry_id = self.generateId() catch return null;
        const entry_timestamp = time_util.isoTimestampNow(self.allocator) catch return null;

        const entry = proto.SessionEntry{
            .id = entry_id,
            .parent_id = self.leaf_id,
            .timestamp = entry_timestamp,
            .entry = entry_data,
        };

        self.leaf_id = entry_id;
        self.ids.put(self.allocator, entry_id, {}) catch {};

        return entry;
    }

    /// Flush all buffered entries to disk (header + entries).
    fn flushAll(self: *SessionWriter) void {
        if (!self.persist) {
            self.flushed = true;
            self.buffered_entries.clearRetainingCapacity();
            return;
        }
        const file = std.fs.createFileAbsolute(self.session_file, .{}) catch return;
        defer file.close();

        var buf: [4096]u8 = undefined;
        var fw = file.writer(&buf);
        for (self.buffered_entries.items) |fe| {
            switch (fe) {
                .header => |h| json.writeHeader(&fw.interface, h) catch continue,
                .entry => |e| json.writeEntry(&fw.interface, e) catch continue,
            }
            fw.interface.writeAll("\n") catch {};
        }
        fw.end() catch {};
        self.flushed = true;
        self.buffered_entries.clearRetainingCapacity();
    }

    /// Append a single entry to the already-flushed file.
    fn appendToFile(self: *SessionWriter, entry: proto.SessionEntry) !void {
        if (!self.persist) return;
        const file = try std.fs.openFileAbsolute(self.session_file, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        var buf: [4096]u8 = undefined;
        var fw = file.writerStreaming(&buf);
        try json.writeEntry(&fw.interface, entry);
        try fw.interface.writeAll("\n");
        try fw.end();
    }

    /// Generate a unique 8-char hex ID, collision-checked.
    fn generateId(self: *SessionWriter) ![]const u8 {
        var buf: [4]u8 = undefined;

        for (0..100) |_| {
            std.crypto.random.bytes(&buf);
            const hex = std.fmt.bytesToHex(buf, .lower);
            const id = try self.allocator.dupe(u8, &hex);
            if (!self.ids.contains(id)) {
                return id;
            }
        }
        var big_buf: [16]u8 = undefined;
        std.crypto.random.bytes(&big_buf);
        const hex = std.fmt.bytesToHex(big_buf, .lower);
        return try self.allocator.dupe(u8, &hex);
    }
};

/// Generate a UUID v4-like string (lowercase hex with dashes).
fn freeBufferedFileEntry(allocator: std.mem.Allocator, entry: proto.FileEntry, session_id: []const u8) void {
    switch (entry) {
        .header => |header| {
            if (!std.mem.eql(u8, header.id, session_id)) allocator.free(header.id);
            allocator.free(header.timestamp);
            if (header.parent_session) |parent| allocator.free(parent);
        },
        .entry => |session_entry| {
            allocator.free(session_entry.id);
            allocator.free(session_entry.timestamp);
        },
    }
}

fn generateUuid(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        random_bytes[0],  random_bytes[1],  random_bytes[2],  random_bytes[3],
        random_bytes[4],  random_bytes[5],  random_bytes[6],  random_bytes[7],
        random_bytes[8],  random_bytes[9],  random_bytes[10], random_bytes[11],
        random_bytes[12], random_bytes[13], random_bytes[14], random_bytes[15],
    }) catch {};
}
