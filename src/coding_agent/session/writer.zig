const std = @import("std");
const zio_fs = @import("../../zio/file.zig");
const agent = @import("../../agent/root.zig");
const ai = @import("../../ai/root.zig");
const proto = @import("../../session/protocol.zig");
const json = @import("../../session/json.zig");
const time_util = @import("../../lib/time_util.zig");
const message_memory = @import("../../agent/message_memory.zig");

pub const SessionWriter = struct {
    allocator: std.mem.Allocator,
    session_id: []const u8,
    session_file: []const u8,
    cwd: []const u8,
    owns_cwd: bool,
    leaf_id: ?[]const u8,
    ids: std.StringHashMapUnmanaged(void),
    flushed: bool,
    has_assistant: bool,
    buffered_entries: std.ArrayListUnmanaged(proto.FileEntry),

    appended_entries: std.ArrayListUnmanaged(proto.SessionEntry),
    persist: bool,

    pub fn init(allocator: std.mem.Allocator, session_dir: []const u8, cwd: []const u8) SessionWriter {
        var uuid_buf: [36]u8 = undefined;
        generateUuid(&uuid_buf);
        const session_id = allocator.dupe(u8, &uuid_buf) catch @panic("OOM");

        const timestamp = time_util.isoTimestampNow(allocator) catch @panic("OOM");
        const owned_cwd = allocator.dupe(u8, cwd) catch @panic("OOM");
        const header_cwd = allocator.dupe(u8, owned_cwd) catch @panic("OOM");

        std.Io.Dir.cwd().createDirPath(std.Options.debug_io, session_dir) catch {};

        const file_ts = allocator.dupe(u8, timestamp) catch @panic("OOM");
        defer allocator.free(file_ts);
        for (file_ts) |*c| {
            if (c.* == ':' or c.* == '.') c.* = '-';
        }
        const session_file = std.fmt.allocPrint(allocator, "{s}/{s}_{s}.jsonl", .{ session_dir, file_ts, session_id }) catch @panic("OOM");

        const header = proto.SessionHeader{
            .id = session_id,
            .timestamp = timestamp,
            .cwd = header_cwd,
        };
        var buffered: std.ArrayListUnmanaged(proto.FileEntry) = .empty;
        buffered.append(allocator, .{ .header = header }) catch @panic("OOM");

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = session_file,
            .cwd = owned_cwd,
            .owns_cwd = true,
            .leaf_id = null,
            .ids = .{},
            .flushed = false,
            .has_assistant = false,
            .buffered_entries = buffered,
            .appended_entries = .empty,
            .persist = true,
        };
    }

    pub fn initEphemeral(allocator: std.mem.Allocator) SessionWriter {
        var uuid_buf: [36]u8 = undefined;
        generateUuid(&uuid_buf);
        const session_id = allocator.dupe(u8, &uuid_buf) catch @panic("OOM");

        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = "",
            .cwd = "",
            .owns_cwd = false,
            .leaf_id = null,
            .ids = .{},
            .flushed = false,
            .has_assistant = false,
            .buffered_entries = .empty,
            .appended_entries = .empty,
            .persist = false,
        };
    }

    pub fn initContinue(allocator: std.mem.Allocator, session_file: []const u8, session_id: []const u8, cwd: []const u8, leaf_id: ?[]const u8) SessionWriter {
        return .{
            .allocator = allocator,
            .session_id = session_id,
            .session_file = session_file,
            .cwd = cwd,
            .owns_cwd = true,
            .leaf_id = leaf_id,
            .ids = .{},
            .flushed = true,
            .has_assistant = true,
            .buffered_entries = .empty,
            .appended_entries = .empty,
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
        for (self.appended_entries.items) |entry| freeAppendedEntry(self.allocator, entry);
        self.appended_entries.deinit(self.allocator);

        if (self.leaf_id) |leaf_id| {
            if (!leaf_owned_by_ids) self.allocator.free(leaf_id);
        }
        if (self.owns_cwd and self.cwd.len > 0) self.allocator.free(self.cwd);
        self.allocator.free(self.session_id);
        if (self.session_file.len > 0) self.allocator.free(self.session_file);
    }

    pub fn appendMessage(self: *SessionWriter, msg: agent.protocol.AgentMessage) ?[]const u8 {
        var owned_msg = message_memory.cloneMessage(self.allocator, msg) catch return null;
        errdefer message_memory.freeMessage(self.allocator, &owned_msg);

        const entry = self.createEntry(.{ .message = .{ .message = owned_msg } }) orelse return null;
        const entry_id = entry.id;

        switch (msg) {
            .assistant => self.has_assistant = true,
            else => {},
        }

        if (!self.persist) {
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return null;
            if (self.has_assistant) self.flushed = true;
            return entry_id;
        }

        if (!self.has_assistant) {
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return null;
            return entry_id;
        }

        if (!self.flushed) {
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return null;
            self.flushAll() catch return null;
            return entry_id;
        }

        self.appendToFile(entry) catch {
            self.flushed = false;
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return null;
        };
        return entry_id;
    }

    pub fn appendThinkingLevelChange(self: *SessionWriter, level: []const u8) void {
        self.appendEntry(.{ .thinking_level_change = .{ .thinking_level = level } });
    }

    pub fn appendModelChange(self: *SessionWriter, provider: []const u8, model_id: []const u8) void {
        self.appendEntry(.{ .model_change = .{ .provider = provider, .model_id = model_id } });
    }

    pub fn appendCompaction(
        self: *SessionWriter,
        summary: []const u8,
        first_kept_entry_id: []const u8,
        tokens_before: u64,
        details: ?std.json.Value,
        from_hook: ?bool,
    ) void {
        self.appendEntry(.{ .compaction = .{
            .summary = summary,
            .first_kept_entry_id = first_kept_entry_id,
            .tokens_before = tokens_before,
            .details = details,
            .from_hook = from_hook,
        } });
    }

    pub fn appendBranchSummary(self: *SessionWriter, from_id: []const u8, summary: []const u8) void {
        self.appendEntry(.{ .branch_summary = .{ .from_id = from_id, .summary = summary } });
    }

    pub fn appendCustomEntry(self: *SessionWriter, custom_type: []const u8, data: ?std.json.Value) void {
        self.appendEntry(.{ .custom = .{ .custom_type = custom_type, .data = data } });
    }

    pub fn appendCustomMessage(self: *SessionWriter, custom_type: []const u8, content: agent.protocol.AgentMessage.CustomContent, display: bool, details: ?std.json.Value) void {
        self.appendEntry(.{ .custom_message = .{
            .custom_type = custom_type,
            .content = content,
            .display = display,
            .details = details,
        } });
    }

    pub fn appendLabel(self: *SessionWriter, target_id: []const u8, label: ?[]const u8) void {
        const owned_target_id = self.allocator.dupe(u8, target_id) catch return;
        errdefer self.allocator.free(owned_target_id);
        const owned_label = if (label) |value| self.allocator.dupe(u8, value) catch return else null;
        self.appendEntry(.{ .label = .{ .target_id = owned_target_id, .label = owned_label } });
    }

    pub fn appendSessionInfo(self: *SessionWriter, name: ?[]const u8) void {
        const owned_name = if (name) |value| self.allocator.dupe(u8, value) catch return else null;
        const was_flushed = self.flushed;
        defer if (was_flushed) if (owned_name) |value| self.allocator.free(value);
        self.appendEntry(.{ .session_info = .{ .name = owned_name } });
    }

    fn appendEntry(self: *SessionWriter, entry_data: proto.SessionEntry.EntryType) void {
        const entry = self.createEntry(entry_data) orelse return;

        if (!self.persist or !self.flushed) {
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return;
            return;
        }

        self.appendToFile(entry) catch {
            self.flushed = false;
            self.buffered_entries.append(self.allocator, .{ .entry = entry }) catch return;
        };
    }

    fn createEntry(self: *SessionWriter, entry_data: proto.SessionEntry.EntryType) ?proto.SessionEntry {
        const entry_id = self.generateId() catch return null;
        const entry_timestamp = time_util.isoTimestampNow(self.allocator) catch return null;
        const parent_id = if (self.leaf_id) |parent| self.allocator.dupe(u8, parent) catch return null else null;
        const previous_leaf_id = self.leaf_id;

        const entry = proto.SessionEntry{
            .id = entry_id,
            .parent_id = parent_id,
            .timestamp = entry_timestamp,
            .entry = entry_data,
        };

        if (previous_leaf_id) |parent| {
            if (!self.ids.contains(parent)) self.allocator.free(parent);
        }
        self.leaf_id = entry_id;
        self.ids.put(self.allocator, entry_id, {}) catch {};

        return entry;
    }

    fn flushAll(self: *SessionWriter) !void {
        if (!self.persist) {
            self.flushed = true;
            self.buffered_entries.clearRetainingCapacity();
            return;
        }
        const file = try std.Io.Dir.createFileAbsolute(std.Options.debug_io, self.session_file, .{});
        defer file.close(std.Options.debug_io);

        var buf: [4096]u8 = undefined;
        var fw = file.writer(std.Options.debug_io, &buf);
        for (self.buffered_entries.items) |fe| {
            switch (fe) {
                .header => |h| try json.writeHeader(&fw.interface, h),
                .entry => |e| try json.writeEntry(&fw.interface, e),
            }
            try fw.interface.writeAll("\n");
        }
        try fw.end();
        self.flushed = true;
        for (self.buffered_entries.items) |entry| freeBufferedFileEntry(self.allocator, entry, self.session_id);
        self.buffered_entries.clearRetainingCapacity();
    }

    fn appendToFile(self: *SessionWriter, entry: proto.SessionEntry) !void {
        if (!self.persist) return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        try json.writeEntry(&out.writer, entry);
        try out.writer.writeAll("\n");
        try zio_fs.appendFile(std.Options.debug_io, self.session_file, out.written());
        self.appended_entries.append(self.allocator, entry) catch {
            freeAppendedEntry(self.allocator, entry);
        };
    }

    fn generateId(self: *SessionWriter) ![]const u8 {
        var buf: [4]u8 = undefined;

        for (0..100) |_| {
            std.Options.debug_io.randomSecure(&buf) catch std.Options.debug_io.random(&buf);
            const hex = std.fmt.bytesToHex(buf, .lower);
            const id = try self.allocator.dupe(u8, &hex);
            if (!self.ids.contains(id)) {
                return id;
            }
        }
        var big_buf: [16]u8 = undefined;
        std.Options.debug_io.randomSecure(&big_buf) catch std.Options.debug_io.random(&big_buf);
        const hex = std.fmt.bytesToHex(big_buf, .lower);
        return try self.allocator.dupe(u8, &hex);
    }
};

fn freeBufferedFileEntry(allocator: std.mem.Allocator, entry: proto.FileEntry, session_id: []const u8) void {
    switch (entry) {
        .header => |header| {
            if (!std.mem.eql(u8, header.id, session_id)) allocator.free(header.id);
            allocator.free(header.timestamp);
            allocator.free(header.cwd);
            if (header.parent_session) |parent| allocator.free(parent);
        },
        .entry => |session_entry| {
            allocator.free(session_entry.timestamp);
            if (session_entry.parent_id) |parent_id| allocator.free(parent_id);
            switch (session_entry.entry) {
                .session_info => |info| if (info.name) |name| allocator.free(name),
                .label => |label| {
                    allocator.free(label.target_id);
                    if (label.label) |value| allocator.free(value);
                },
                .message => |message| {
                    var owned = message.message;
                    message_memory.freeMessage(allocator, &owned);
                },
                .custom => |custom| if (custom.data) |value| ai.json_util.freeJsonValue(allocator, value),
                else => {},
            }
        },
    }
}

fn freeAppendedEntry(allocator: std.mem.Allocator, entry: proto.SessionEntry) void {
    allocator.free(entry.timestamp);
    if (entry.parent_id) |parent_id| allocator.free(parent_id);
    switch (entry.entry) {
        .session_info => |info| if (info.name) |name| allocator.free(name),
        .compaction => |compaction| {
            allocator.free(compaction.summary);
            allocator.free(compaction.first_kept_entry_id);
            if (compaction.details) |details| ai.json_util.freeJsonValue(allocator, details);
        },
        .label => |label| {
            allocator.free(label.target_id);
            if (label.label) |value| allocator.free(value);
        },
        .message => |message| {
            var owned = message.message;
            message_memory.freeMessage(allocator, &owned);
        },
        .custom => |custom| if (custom.data) |value| ai.json_util.freeJsonValue(allocator, value),
        else => {},
    }
}

fn generateUuid(buf: *[36]u8) void {
    var random_bytes: [16]u8 = undefined;
    std.Options.debug_io.randomSecure(&random_bytes) catch std.Options.debug_io.random(&random_bytes);
    random_bytes[6] = (random_bytes[6] & 0x0f) | 0x40;
    random_bytes[8] = (random_bytes[8] & 0x3f) | 0x80;

    _ = std.fmt.bufPrint(buf, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
        random_bytes[0],  random_bytes[1],  random_bytes[2],  random_bytes[3],
        random_bytes[4],  random_bytes[5],  random_bytes[6],  random_bytes[7],
        random_bytes[8],  random_bytes[9],  random_bytes[10], random_bytes[11],
        random_bytes[12], random_bytes[13], random_bytes[14], random_bytes[15],
    }) catch {};
}
