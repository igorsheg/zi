const std = @import("std");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const json = @import("json.zig");
const storage = @import("../storage.zig");

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

    pub fn init(allocator: std.mem.Allocator, cwd: []const u8) SessionWriter {
        var uuid_buf: [36]u8 = undefined;
        generateUuid(&uuid_buf);
        const session_id = allocator.dupe(u8, &uuid_buf) catch @panic("OOM");

        const timestamp = isoTimestamp(allocator) catch @panic("OOM");

        const session_dir = storage.getSessionDirForCwd(allocator, cwd, null) catch @panic("OOM");

        // Ensure directory exists
        std.fs.cwd().makePath(session_dir) catch {};

        const file_ts = allocator.dupe(u8, timestamp) catch @panic("OOM");
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
        };
    }

    /// Append a message entry. Matches pi-mono's message_end persistence:
    /// - Buffers until first assistant message appears
    /// - Then flushes all buffered entries + appends incrementally
    pub fn appendMessage(self: *SessionWriter, msg: agent.protocol.AgentMessage) void {
        const entry_id = self.generateId() catch return;
        const entry_timestamp = isoTimestamp(self.allocator) catch return;

        const entry = proto.SessionEntry{
            .id = entry_id,
            .parent_id = self.leaf_id,
            .timestamp = entry_timestamp,
            .entry = .{ .message = .{ .message = msg } },
        };

        self.leaf_id = entry_id;
        self.ids.put(self.allocator, entry_id, {}) catch {};

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

    /// Flush all buffered entries to disk (header + entries).
    fn flushAll(self: *SessionWriter) void {
        const file = std.fs.createFileAbsolute(self.session_file, .{}) catch return;
        defer file.close();

        for (self.buffered_entries.items) |fe| {
            const line = switch (fe) {
                .header => |h| json.serializeHeader(self.allocator, h) catch continue,
                .entry => |e| json.serializeEntry(self.allocator, e) catch continue,
            };
            file.writeAll(line) catch {};
            file.writeAll("\n") catch {};
        }
        self.flushed = true;
        self.buffered_entries.clearRetainingCapacity();
    }

    /// Append a single entry to the already-flushed file.
    fn appendToFile(self: *SessionWriter, entry: proto.SessionEntry) !void {
        const line = try json.serializeEntry(self.allocator, entry);
        const file = try std.fs.openFileAbsolute(self.session_file, .{ .mode = .read_write });
        defer file.close();
        try file.seekFromEnd(0);
        try file.writeAll(line);
        try file.writeAll("\n");
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

/// Generate an ISO 8601 timestamp string.
fn isoTimestamp(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const day = epoch_secs.getDaySeconds();
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();

    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}.000Z", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
        day.getHoursIntoDay(),
        day.getMinutesIntoHour(),
        day.getSecondsIntoMinute(),
    });
}

/// Generate a UUID v4-like string (lowercase hex with dashes).
fn generateUuid(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        random_bytes[0],  random_bytes[1],  random_bytes[2],  random_bytes[3],
        random_bytes[4],  random_bytes[5],
        random_bytes[6],  random_bytes[7],
        random_bytes[8],  random_bytes[9],
        random_bytes[10], random_bytes[11], random_bytes[12], random_bytes[13], random_bytes[14], random_bytes[15],
    }) catch {};
}


