const std = @import("std");
const event = @import("event.zig");
const json = @import("json.zig");
const reader = @import("reader.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    index: AppendIndex,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        header: event.Header,
    ) !Store {
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .truncate = true });
        defer file.close(io);

        var buf: [4096]u8 = undefined;
        var writer = file.writer(io, &buf);
        try json.writeHeader(&writer.interface, header);
        try writer.interface.writeAll("\n");
        try writer.end();

        return .{ .allocator = allocator, .path = owned_path, .index = AppendIndex.init(allocator) };
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var log = try reader.readFile(allocator, io, path, .strict);
        defer log.deinit();

        var index = try AppendIndex.fromEntries(allocator, log.entries);
        errdefer index.deinit();

        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);

        return .{
            .allocator = allocator,
            .path = owned_path,
            .index = index,
        };
    }

    pub fn deinit(self: *Store) void {
        self.index.deinit();
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn append(self: *Store, io: std.Io, entry: event.Event) !void {
        try self.index.validateAppend(entry);
        const indexed_id = try self.index.prepareAppend(entry);
        errdefer self.allocator.free(indexed_id);

        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();

        try json.writeEntry(self.allocator, &out.writer, entry);
        try out.writer.writeAll("\n");

        const file = try std.Io.Dir.cwd().openFile(io, self.path, .{ .mode = .write_only });
        defer file.close(io);

        var buf: [256]u8 = undefined;
        var writer = file.writer(io, &buf);
        try writer.seekFromEnd(0);
        try writer.interface.writeAll(out.written());
        try writer.end();

        self.index.commitPrepared(indexed_id);
    }

    pub fn appendPayload(
        self: *Store,
        io: std.Io,
        random: std.Random,
        parent_id: ?[]const u8,
        timestamp: []const u8,
        payload: event.Payload,
    ) !event.EventId {
        const id = event.randomEventId(random);
        try self.append(io, .{
            .id = &id,
            .parent_id = parent_id,
            .timestamp = timestamp,
            .payload = payload,
        });
        return id;
    }

    pub fn readAll(self: *const Store, allocator: std.mem.Allocator, io: std.Io) !reader.SessionLog {
        return reader.readFile(allocator, io, self.path, .strict);
    }

};

const AppendIndex = struct {
    allocator: std.mem.Allocator,
    ids: std.StringHashMap(void),

    fn init(allocator: std.mem.Allocator) AppendIndex {
        return .{
            .allocator = allocator,
            .ids = std.StringHashMap(void).init(allocator),
        };
    }

    fn fromEntries(allocator: std.mem.Allocator, entries: []const event.Event) !AppendIndex {
        var index = AppendIndex.init(allocator);
        errdefer index.deinit();

        for (entries) |entry| {
            const indexed_id = try index.prepareAppend(entry);
            index.commitPrepared(indexed_id);
        }
        return index;
    }

    fn deinit(self: *AppendIndex) void {
        var it = self.ids.keyIterator();
        while (it.next()) |key| self.allocator.free(key.*);
        self.ids.deinit();
        self.* = undefined;
    }

    fn validateAppend(self: *const AppendIndex, entry: event.Event) !void {
        if (entry.id.len == 0) return error.EmptyEntryId;
        if (self.ids.contains(entry.id)) return error.DuplicateEntryId;

        if (entry.parent_id) |parent_id| {
            if (parent_id.len == 0) return error.EmptyParentEntryId;
            if (!self.ids.contains(parent_id)) return error.UnknownParentEntryId;
        }
    }

    fn prepareAppend(self: *AppendIndex, entry: event.Event) ![]u8 {
        try self.validateAppend(entry);
        const owned_id = try self.allocator.dupe(u8, entry.id);
        errdefer self.allocator.free(owned_id);
        try self.ids.ensureUnusedCapacity(1);
        return owned_id;
    }

    fn commitPrepared(self: *AppendIndex, owned_id: []u8) void {
        self.ids.putAssumeCapacityNoClobber(owned_id, {});
    }
};

test "store creates appends and reads a session log" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "session.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var store = try Store.create(std.testing.allocator, std.Options.debug_io, path, .{
        .id = "s1",
        .timestamp = "2025-01-01T00:00:00Z",
        .cwd = "/tmp",
    });
    defer store.deinit();

    try store.append(std.Options.debug_io, .{
        .id = "1",
        .parent_id = null,
        .timestamp = "2025-01-01T00:00:01Z",
        .payload = .{ .message = .{ .message = .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } } } },
    });
    try store.append(std.Options.debug_io, .{
        .id = "2",
        .parent_id = "1",
        .timestamp = "2025-01-01T00:00:02Z",
        .payload = .{ .message = .{ .message = .{ .user = .{ .content = .{ .text = "again" }, .timestamp = 2 } } } },
    });

    var log = try store.readAll(std.testing.allocator, std.Options.debug_io);
    defer log.deinit();

    try std.testing.expectEqualStrings("s1", log.header.id);
    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expectEqualStrings("1", log.entries[0].id);
    try std.testing.expectEqualStrings("2", log.entries[1].id);
}

test "store open rejects invalid existing logs" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{ .sub_path = "bad.jsonl", .data = "not json\n" });
    const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "bad.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);

    try std.testing.expectError(error.SyntaxError, Store.open(std.testing.allocator, std.Options.debug_io, path));
}

test "store appendPayload owns event id generation and parent validation" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "session.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var store = try Store.create(std.testing.allocator, std.Options.debug_io, path, .{
        .id = "s1",
        .timestamp = "2025-01-01T00:00:00Z",
        .cwd = "/tmp",
    });
    defer store.deinit();

    var prng = std.Random.DefaultPrng.init(42);
    const first_id = try store.appendPayload(std.Options.debug_io, prng.random(), null, "2025-01-01T00:00:01Z", .{ .message = .{ .message = .{ .user = .{
        .content = .{ .text = "hello" },
        .timestamp = 1,
    } } } });
    const second_id = try store.appendPayload(std.Options.debug_io, prng.random(), &first_id, "2025-01-01T00:00:02Z", .{ .message = .{ .message = .{ .user = .{
        .content = .{ .text = "again" },
        .timestamp = 2,
    } } } });

    try std.testing.expect(!std.mem.eql(u8, &first_id, &second_id));

    var log = try store.readAll(std.testing.allocator, std.Options.debug_io);
    defer log.deinit();

    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expectEqualStrings(&first_id, log.entries[0].id);
    try std.testing.expectEqualStrings(&second_id, log.entries[1].id);
    try std.testing.expectEqualStrings(&first_id, log.entries[1].parent_id.?);

    try std.testing.expectError(error.UnknownParentEntryId, store.appendPayload(std.Options.debug_io, prng.random(), "missing", "2025-01-01T00:00:03Z", .{ .session_info = .{ .name = "bad" } }));
}
