const std = @import("std");
const proto = @import("protocol.zig");
const json = @import("json.zig");

const max_session_file_bytes: usize = 100 * 1024 * 1024;

pub const ReadPolicy = enum {
    strict,
    allow_final_partial_line,
};

/// Arena-owned parsed session log.
///
/// Owner: `Log` owns all header and entry memory through `arena`.
/// Ingress: complete file bytes through `parseContent` or a file path through
/// `readFile`.
/// Egress: validated header and append-order entries.
/// Bounds: `readFile` limits file bytes; validation rejects duplicate IDs,
/// missing headers, future versions, and unknown parents.
pub const Log = struct {
    arena: std.heap.ArenaAllocator,
    header: proto.SessionHeader,
    entries: []proto.SessionEntry,

    pub fn deinit(self: *Log) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn readFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    policy: ReadPolicy,
) !Log {
    const content = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_session_file_bytes));
    defer allocator.free(content);
    return parseContent(allocator, content, policy);
}

pub fn parseContent(allocator: std.mem.Allocator, content: []const u8, policy: ReadPolicy) !Log {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aa = arena.allocator();

    var header: ?proto.SessionHeader = null;
    var entries: std.ArrayList(proto.SessionEntry) = .empty;

    var line_start: usize = 0;
    var line_no: usize = 1;
    while (line_start < content.len) : (line_no += 1) {
        const maybe_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n');
        const line_end = maybe_end orelse content.len;
        const final_without_newline = maybe_end == null;
        const raw_line = content[line_start..line_end];
        const line = std.mem.trim(u8, raw_line, &std.ascii.whitespace);

        if (line.len > 0) {
            const file_entry = json.parseFileEntry(aa, line) catch |err| switch (policy) {
                .allow_final_partial_line => if (final_without_newline) break else return err,
                .strict => return err,
            };
            switch (file_entry) {
                .header => |h| {
                    if (header != null) return error.DuplicateSessionHeader;
                    header = h;
                },
                .entry => |entry| {
                    if (header == null) return error.EntryBeforeHeader;
                    try entries.append(aa, entry);
                },
            }
        }

        if (maybe_end == null) break;
        line_start = line_end + 1;
    }

    const session_header = header orelse return error.MissingSessionHeader;
    try validateVersion(session_header.version);
    try validateEntries(aa, entries.items);

    return .{
        .arena = arena,
        .header = session_header,
        .entries = try entries.toOwnedSlice(aa),
    };
}

fn validateVersion(version: u32) !void {
    if (version > proto.CURRENT_SESSION_VERSION) return error.UnsupportedFutureSessionVersion;
    if (version == 0) return error.UnsupportedSessionVersion;
}

fn validateEntries(allocator: std.mem.Allocator, entries: []const proto.SessionEntry) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (entries) |entry| {
        if (entry.id.len == 0) return error.EmptyEntryId;
        if (seen.contains(entry.id)) return error.DuplicateEntryId;
        if (entry.parent_id) |parent_id| {
            if (parent_id.len == 0) return error.EmptyParentEntryId;
            if (!seen.contains(parent_id)) return error.UnknownParentEntryId;
        }
        try seen.put(entry.id, {});
    }
}

test "strict reader rejects malformed content and missing header" {
    try std.testing.expectError(error.MissingSessionHeader, parseContent(std.testing.allocator, "", .strict));
    try std.testing.expectError(error.SyntaxError, parseContent(std.testing.allocator, "not json\n", .strict));
}

test "reader preserves order and validates parent links" {
    const content =
        \\{"type":"session","version":3,"id":"s1","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"first","timestamp":1}}
        \\{"type":"message","id":"2","parentId":"1","timestamp":"2025-01-01T00:00:02Z","message":{"role":"user","content":"second","timestamp":2}}
        \\
    ;

    var log = try parseContent(std.testing.allocator, content, .strict);
    defer log.deinit();

    try std.testing.expectEqualStrings("s1", log.header.id);
    try std.testing.expectEqual(@as(usize, 2), log.entries.len);
    try std.testing.expectEqualStrings("1", log.entries[0].id);
    try std.testing.expectEqualStrings("2", log.entries[1].id);
}

test "reader rejects duplicate IDs and unknown parents" {
    const duplicate =
        \\{"type":"session","version":3,"id":"s1","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"first","timestamp":1}}
        \\{"type":"message","id":"1","parentId":"1","timestamp":"2025-01-01T00:00:02Z","message":{"role":"user","content":"second","timestamp":2}}
        \\
    ;
    try std.testing.expectError(error.DuplicateEntryId, parseContent(std.testing.allocator, duplicate, .strict));

    const unknown_parent =
        \\{"type":"session","version":3,"id":"s1","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"2","parentId":"missing","timestamp":"2025-01-01T00:00:02Z","message":{"role":"user","content":"second","timestamp":2}}
        \\
    ;
    try std.testing.expectError(error.UnknownParentEntryId, parseContent(std.testing.allocator, unknown_parent, .strict));
}

test "reader can ignore only a malformed final partial line" {
    const content =
        \\{"type":"session","version":3,"id":"s1","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"first","timestamp":1}}
        \\{"type":"message","id":"2","parentId":"1","timestamp":"2025-01-01T00:00:02Z","message":{"role":"user"
    ;

    try std.testing.expectError(error.SyntaxError, parseContent(std.testing.allocator, content, .strict));

    var log = try parseContent(std.testing.allocator, content, .allow_final_partial_line);
    defer log.deinit();

    try std.testing.expectEqualStrings("s1", log.header.id);
    try std.testing.expectEqual(@as(usize, 1), log.entries.len);
    try std.testing.expectEqualStrings("1", log.entries[0].id);
}
