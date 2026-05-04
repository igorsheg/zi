const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const proto = @import("../../session/protocol.zig");
const json = @import("../../session/json.zig");

pub const TelemetrySnapshot = struct {
    read_count: u64 = 0,
    last_bytes: usize = 0,
    last_entries: usize = 0,
    last_parse_ns: u64 = 0,
    last_total_ns: u64 = 0,
    total_bytes: u64 = 0,
    total_parse_ns: u64 = 0,
};

const Telemetry = struct {
    read_count: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_bytes: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    last_entries: std.atomic.Value(usize) = std.atomic.Value(usize).init(0),
    last_parse_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    last_total_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_bytes: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    total_parse_ns: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

var telemetry: Telemetry = .{};

pub fn telemetrySnapshot() TelemetrySnapshot {
    return .{
        .read_count = telemetry.read_count.load(.monotonic),
        .last_bytes = telemetry.last_bytes.load(.monotonic),
        .last_entries = telemetry.last_entries.load(.monotonic),
        .last_parse_ns = telemetry.last_parse_ns.load(.monotonic),
        .last_total_ns = telemetry.last_total_ns.load(.monotonic),
        .total_bytes = telemetry.total_bytes.load(.monotonic),
        .total_parse_ns = telemetry.total_parse_ns.load(.monotonic),
    };
}

/// Result of reading a session file.
pub const SessionData = struct {
    header: ?proto.SessionHeader,
    entries: []proto.SessionEntry,

    pub fn deinit(self: *SessionData, allocator: std.mem.Allocator) void {
        if (self.header) |header| freeSessionHeader(allocator, header);
        for (self.entries) |entry| freeSessionEntry(allocator, entry);
        if (self.entries.len > 0) allocator.free(self.entries);
        self.header = null;
        self.entries = &.{};
    }
};

/// Parse a JSONL session file content into header + entries.
/// All returned data is owned by the provided allocator.
pub fn parseSessionContent(allocator: std.mem.Allocator, content: []const u8) !SessionData {
    var header: ?proto.SessionHeader = null;
    var entries: std.ArrayListUnmanaged(proto.SessionEntry) = .empty;

    var line_start: usize = 0;
    for (content, 0..) |c, i| {
        if (c == '\n') {
            const line = std.mem.trim(u8, content[line_start..i], &std.ascii.whitespace);
            if (line.len > 0) {
                parseLine(allocator, line, &header, &entries) catch {};
            }
            line_start = i + 1;
        }
    }
    // Handle last line without trailing newline
    if (line_start < content.len) {
        const line = std.mem.trim(u8, content[line_start..], &std.ascii.whitespace);
        if (line.len > 0) {
            parseLine(allocator, line, &header, &entries) catch {};
        }
    }

    // pi-mono: loadEntriesFromFile returns [] if no valid session header exists
    if (header == null) {
        return .{ .header = null, .entries = &.{} };
    }
    return .{ .header = header, .entries = try entries.toOwnedSlice(allocator) };
}

fn parseLine(
    allocator: std.mem.Allocator,
    line: []const u8,
    header: *?proto.SessionHeader,
    entries: *std.ArrayListUnmanaged(proto.SessionEntry),
) !void {
    const file_entry = try json.parseFileEntry(allocator, line);
    switch (file_entry) {
        .header => |h| header.* = h,
        .entry => |e| try entries.append(allocator, e),
    }
}

/// Read and parse a session file from disk.
pub fn readSessionFile(allocator: std.mem.Allocator, path: []const u8) !SessionData {
    const total_start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
    const file = try std.Io.Dir.openFileAbsolute(std.Options.debug_io, path, .{});
    defer file.close(std.Options.debug_io);
    var read_buf: [4096]u8 = undefined;
    var file_reader = file.reader(std.Options.debug_io, &read_buf);
    const content = try file_reader.interface.allocRemaining(allocator, .limited(100 * 1024 * 1024)); // 100MB max
    defer allocator.free(content);

    const parse_start = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
    const data = try parseSessionContent(allocator, content);
    const parse_end = std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds();
    const total_end = parse_end;

    const parse_ns: u64 = @intCast(@max(parse_end - parse_start, 0));
    const total_ns: u64 = @intCast(@max(total_end - total_start, 0));
    _ = telemetry.read_count.fetchAdd(1, .monotonic);
    telemetry.last_bytes.store(content.len, .monotonic);
    telemetry.last_entries.store(data.entries.len, .monotonic);
    telemetry.last_parse_ns.store(parse_ns, .monotonic);
    telemetry.last_total_ns.store(total_ns, .monotonic);
    _ = telemetry.total_bytes.fetchAdd(content.len, .monotonic);
    _ = telemetry.total_parse_ns.fetchAdd(parse_ns, .monotonic);
    return data;
}

fn freeSessionHeader(allocator: std.mem.Allocator, header: proto.SessionHeader) void {
    allocator.free(header.id);
    allocator.free(header.timestamp);
    allocator.free(header.cwd);
    if (header.parent_session) |parent| allocator.free(parent);
}

fn freeSessionEntry(allocator: std.mem.Allocator, entry: proto.SessionEntry) void {
    allocator.free(entry.id);
    allocator.free(entry.timestamp);
    if (entry.parent_id) |parent_id| allocator.free(parent_id);
    freeEntryType(allocator, entry.entry);
}

fn freeEntryType(allocator: std.mem.Allocator, entry: proto.SessionEntry.EntryType) void {
    switch (entry) {
        .message => |msg| freeAgentMessage(allocator, msg.message),
        .thinking_level_change => |tc| allocator.free(tc.thinking_level),
        .model_change => |mc| {
            allocator.free(mc.provider);
            allocator.free(mc.model_id);
        },
        .compaction => |c| {
            allocator.free(c.summary);
            allocator.free(c.first_kept_entry_id);
            if (c.details) |details| ai.json_util.freeJsonValue(allocator, details);
        },
        .branch_summary => |b| {
            allocator.free(b.from_id);
            allocator.free(b.summary);
            if (b.details) |details| ai.json_util.freeJsonValue(allocator, details);
        },
        .custom => |c| {
            allocator.free(c.custom_type);
            if (c.data) |data| ai.json_util.freeJsonValue(allocator, data);
        },
        .custom_message => |cm| {
            allocator.free(cm.custom_type);
            freeCustomContent(allocator, cm.content);
            if (cm.details) |details| ai.json_util.freeJsonValue(allocator, details);
        },
        .label => |l| {
            allocator.free(l.target_id);
            if (l.label) |label| allocator.free(label);
        },
        .session_info => |info| {
            if (info.name) |name| allocator.free(name);
        },
    }
}

fn freeAgentMessage(allocator: std.mem.Allocator, msg: agent.protocol.AgentMessage) void {
    switch (msg) {
        .user => |u| freeUserMessage(allocator, u),
        .assistant => |a| freeAssistantMessage(allocator, a),
        .tool_result => |tr| freeToolResultMessage(allocator, tr),
        .compaction_summary => |summary| allocator.free(summary.summary),
        .branch_summary => |summary| {
            allocator.free(summary.summary);
            allocator.free(summary.from_id);
        },
        .custom => |custom| {
            allocator.free(custom.custom_type);
            freeCustomContent(allocator, custom.content);
            if (custom.details) |details| ai.json_util.freeJsonValue(allocator, details);
        },
    }
}

fn freeUserMessage(allocator: std.mem.Allocator, msg: ai.protocol.UserMessage) void {
    switch (msg.content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| switch (block) {
                .text => |t| {
                    allocator.free(t.text);
                    if (t.text_signature) |sig| allocator.free(sig);
                },
                .image => |img| {
                    allocator.free(img.data);
                    allocator.free(img.mime_type);
                },
            };
            allocator.free(blocks);
        },
    }
}

fn freeAssistantMessage(allocator: std.mem.Allocator, msg: ai.protocol.AssistantMessage) void {
    for (msg.content) |block| switch (block) {
        .text => |t| {
            allocator.free(t.text);
            if (t.text_signature) |sig| allocator.free(sig);
        },
        .thinking => |thinking| {
            allocator.free(thinking.thinking);
            if (thinking.thinking_signature) |sig| allocator.free(sig);
        },
        .tool_call => |call| {
            allocator.free(call.id);
            allocator.free(call.name);
            ai.json_util.freeJsonValue(allocator, call.arguments);
            if (call.thought_signature) |sig| allocator.free(sig);
        },
    };
    allocator.free(msg.content);
    freeApi(allocator, msg.api);
    freeProvider(allocator, msg.provider);
    allocator.free(msg.model);
    if (msg.response_id) |response_id| allocator.free(response_id);
    if (msg.error_message) |error_message| allocator.free(error_message);
    if (msg.failure) |failure| {
        if (failure.provider_code) |provider_code| allocator.free(provider_code);
        if (failure.provider_type) |provider_type| allocator.free(provider_type);
    }
}

fn freeToolResultMessage(allocator: std.mem.Allocator, msg: ai.protocol.ToolResultMessage) void {
    allocator.free(msg.tool_call_id);
    allocator.free(msg.tool_name);
    for (msg.content) |block| switch (block) {
        .text => |t| {
            allocator.free(t.text);
            if (t.text_signature) |sig| allocator.free(sig);
        },
        .image => |img| {
            allocator.free(img.data);
            allocator.free(img.mime_type);
        },
    };
    allocator.free(msg.content);
    if (msg.details) |details| ai.json_util.freeJsonValue(allocator, details);
    if (msg.presentation) |presentation| ai.json_util.freeJsonValue(allocator, presentation);
}

fn freeCustomContent(allocator: std.mem.Allocator, content: agent.protocol.AgentMessage.CustomContent) void {
    switch (content) {
        .text => |text| allocator.free(text),
        .blocks => |blocks| {
            for (blocks) |block| switch (block) {
                .text => |t| {
                    allocator.free(t.text);
                    if (t.text_signature) |sig| allocator.free(sig);
                },
                .image => |img| {
                    allocator.free(img.data);
                    allocator.free(img.mime_type);
                },
            };
            allocator.free(blocks);
        },
    }
}

fn freeApi(allocator: std.mem.Allocator, api: ai.protocol.Api) void {
    switch (api) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

fn freeProvider(allocator: std.mem.Allocator, provider: ai.protocol.Provider) void {
    switch (provider) {
        .custom => |value| allocator.free(value),
        else => {},
    }
}

// ─── Session reader behavior tests ──

test "parse boundaries without a valid session header return empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const cases = [_][]const u8{
        "",
        "\n\t  \n",
        "not json\n",
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:00Z","message":{"role":"user","content":"hi","timestamp":1}}
        \\
        ,
    };

    for (cases) |content| {
        const result = try parseSessionContent(arena.allocator(), content);
        try std.testing.expect(result.header == null);
        try std.testing.expectEqual(@as(usize, 0), result.entries.len);
    }
}

test "parse keeps valid entries in file order and skips malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        \\{"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp","parentSession":"parent"}
        \\not valid json
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"first","timestamp":1}}
        \\{"type":"message","id":"2","parentId":"1","timestamp":"2025-01-01T00:00:02Z","message":{"role":"user","content":"second","timestamp":2}}
    ;

    const result = try parseSessionContent(arena.allocator(), content);
    try std.testing.expect(result.header != null);
    try std.testing.expectEqualStrings("abc", result.header.?.id);
    try std.testing.expectEqualStrings("/tmp", result.header.?.cwd);
    try std.testing.expectEqualStrings("parent", result.header.?.parent_session.?);
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);

    try std.testing.expectEqualStrings("1", result.entries[0].id);
    try std.testing.expect(result.entries[0].parent_id == null);
    try std.testing.expectEqualStrings("2", result.entries[1].id);
    try std.testing.expectEqualStrings("1", result.entries[1].parent_id.?);

    switch (result.entries[0].entry) {
        .message => |m| switch (m.message) {
            .user => |u| switch (u.content) {
                .text => |text| try std.testing.expectEqualStrings("first", text),
                else => return error.ExpectedTextContent,
            },
            else => return error.ExpectedUserMessage,
        },
        else => return error.ExpectedMessageEntry,
    }
}

test "parse branch summary and label entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const content =
        \\{"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"branch_summary","id":"b1","parentId":"m2","timestamp":"2025-01-01T00:00:03Z","fromId":"branch-start","summary":"explored alternate approach"}
        \\{"type":"label","id":"l1","parentId":"b1","timestamp":"2025-01-01T00:00:04Z","targetId":"m2","label":"checkpoint"}
        \\
    ;

    const result = try parseSessionContent(arena.allocator(), content);
    try std.testing.expect(result.header != null);
    try std.testing.expectEqual(@as(usize, 2), result.entries.len);

    switch (result.entries[0].entry) {
        .branch_summary => |b| {
            try std.testing.expectEqualStrings("branch-start", b.from_id);
            try std.testing.expectEqualStrings("explored alternate approach", b.summary);
        },
        else => return error.ExpectedBranchSummary,
    }
    switch (result.entries[1].entry) {
        .label => |label| {
            try std.testing.expectEqualStrings("m2", label.target_id);
            try std.testing.expectEqualStrings("checkpoint", label.label.?);
        },
        else => return error.ExpectedLabel,
    }
}

test "readSessionFile reads a session from disk" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.Options.debug_io, .{
        .sub_path = "session.jsonl",
        .data = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
            "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n",
    });

    const path = try tmp.dir.realPathFileAlloc(std.Options.debug_io, "session.jsonl", std.testing.allocator);
    defer std.testing.allocator.free(path);

    var data = try readSessionFile(std.testing.allocator, path);
    defer data.deinit(std.testing.allocator);
    try std.testing.expect(data.header != null);
    try std.testing.expectEqual(@as(usize, 1), data.entries.len);
}
