const std = @import("std");
const proto = @import("protocol.zig");
const json = @import("json.zig");
const reader = @import("reader.zig");

pub const Store = struct {
    allocator: std.mem.Allocator,
    path: []const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        path: []const u8,
        header: proto.SessionHeader,
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

        return .{ .allocator = allocator, .path = owned_path };
    }

    pub fn open(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !Store {
        var log = try reader.readFile(allocator, io, path, .strict);
        log.deinit();

        return .{
            .allocator = allocator,
            .path = try allocator.dupe(u8, path),
        };
    }

    pub fn deinit(self: *Store) void {
        self.allocator.free(self.path);
        self.* = undefined;
    }

    pub fn append(self: *Store, io: std.Io, entry: proto.SessionEntry) !void {
        try self.validateAppend(io, entry);

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
    }

    pub fn readAll(self: *const Store, allocator: std.mem.Allocator, io: std.Io) !reader.SessionLog {
        return reader.readFile(allocator, io, self.path, .strict);
    }

    fn validateAppend(self: *const Store, io: std.Io, entry: proto.SessionEntry) !void {
        if (entry.id.len == 0) return error.EmptyEntryId;

        var log = try self.readAll(self.allocator, io);
        defer log.deinit();

        var parent_seen = entry.parent_id == null;
        for (log.entries) |existing| {
            if (std.mem.eql(u8, existing.id, entry.id)) return error.DuplicateEntryId;
            if (entry.parent_id) |parent_id| {
                if (parent_id.len == 0) return error.EmptyParentEntryId;
                if (std.mem.eql(u8, existing.id, parent_id)) parent_seen = true;
            }
        }
        if (!parent_seen) return error.UnknownParentEntryId;
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
        .entry = .{ .message = .{ .message = .{ .user = .{ .content = .{ .text = "hello" }, .timestamp = 1 } } } },
    });
    try store.append(std.Options.debug_io, .{
        .id = "2",
        .parent_id = "1",
        .timestamp = "2025-01-01T00:00:02Z",
        .entry = .{ .message = .{ .message = .{ .user = .{ .content = .{ .text = "again" }, .timestamp = 2 } } } },
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
