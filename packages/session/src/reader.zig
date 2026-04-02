const std = @import("std");
const ai = @import("ai");
const proto = @import("protocol.zig");
const json = @import("json.zig");

/// Result of reading a session file.
pub const SessionData = struct {
    header: ?proto.SessionHeader,
    entries: []proto.SessionEntry,
};

/// Parse a JSONL session file content into header + entries.
/// All returned data is owned by the provided allocator.
pub fn parseSessionContent(allocator: std.mem.Allocator, content: []const u8) !SessionData {
    var header: ?proto.SessionHeader = null;
    var entries: std.ArrayListUnmanaged(proto.SessionEntry) = .{};

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
    return .{ .header = header, .entries = entries.items };
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
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(allocator, 100 * 1024 * 1024); // 100MB max
    return parseSessionContent(allocator, content);
}

// ─── Conformance tests ported from pi-mono file-operations.test.ts ──

test "parse empty content returns no header and no entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseSessionContent(arena.allocator(), "");
    try std.testing.expect(result.header == null);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "parse content without valid session header returns empty" {
    // pi-mono: loadEntriesFromFile returns [] for file without valid session header
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseSessionContent(arena.allocator(),
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:00Z","message":{"role":"user","content":"hi","timestamp":1}}
        \\
    );
    // pi-mono returns empty when no session header — zi should match
    try std.testing.expect(result.header == null);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "parse malformed JSON skips bad lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try parseSessionContent(arena.allocator(), "not json\n");
    try std.testing.expect(result.header == null);
    try std.testing.expectEqual(@as(usize, 0), result.entries.len);
}

test "parse valid session file with header + user message" {
    // Uses pi-mono's exact JSONL wire format as fixture string
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\{"type":"session","id":"abc","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:01Z","message":{"role":"user","content":"hi","timestamp":1}}
        \\
    ;
    const result = try parseSessionContent(arena.allocator(), content);
    try std.testing.expect(result.header != null);
    try std.testing.expectEqualStrings("abc", result.header.?.id);
    try std.testing.expectEqualStrings("/tmp", result.header.?.cwd);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
    switch (result.entries[0].entry) {
        .message => |m| {
            switch (m.message) {
                .user => |u| {
                    switch (u.content) {
                        .text => |t| try std.testing.expectEqualStrings("hi", t),
                        else => return error.ExpectedTextContent,
                    }
                },
                else => return error.ExpectedUserMessage,
            }
        },
        else => return error.ExpectedMessageEntry,
    }
}

test "parse skips malformed lines but keeps valid ones" {
    // pi-mono: skips malformed lines, keeps valid header + entries
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
        "not valid json\n" ++
        "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n";

    const result = try parseSessionContent(arena.allocator(), content);
    try std.testing.expect(result.header != null);
    try std.testing.expectEqual(@as(usize, 1), result.entries.len);
}

test "parse assistant message from pi-mono wire format" {
    // Tests that zi can parse the exact JSON that pi-mono produces for assistant messages
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const content =
        \\{"type":"session","id":"test","timestamp":"2025-01-01T00:00:00Z","cwd":"/tmp"}
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:00Z","message":{"role":"user","content":"hello","timestamp":1}}
        \\{"type":"message","id":"2","parentId":"1","timestamp":"2025-01-01T00:00:01Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"toolu_abc","name":"bash","arguments":{"command":"ls"}},{"type":"text","text":"done"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":100,"output":50,"cacheRead":0,"cacheWrite":0,"totalTokens":150,"cost":{"input":0.001,"output":0.002,"cacheRead":0,"cacheWrite":0,"total":0.003}},"stopReason":"toolUse","timestamp":2}}
        \\{"type":"message","id":"3","parentId":"2","timestamp":"2025-01-01T00:00:02Z","message":{"role":"toolResult","toolCallId":"toolu_abc","toolName":"bash","content":[{"type":"text","text":"file1.txt"}],"isError":false,"timestamp":3}}
        \\
    ;
    const result = try parseSessionContent(arena.allocator(), content);
    try std.testing.expect(result.header != null);
    try std.testing.expectEqual(@as(usize, 3), result.entries.len);

    // Verify assistant message parsed correctly
    const entry2 = result.entries[1];
    try std.testing.expectEqualStrings("2", entry2.id);
    try std.testing.expectEqualStrings("1", entry2.parent_id.?);
    switch (entry2.entry) {
        .message => |m| switch (m.message) {
            .assistant => |a| {
                try std.testing.expectEqualStrings("claude-sonnet-4-5", a.model);
                try std.testing.expectEqual(@as(u64, 150), a.usage.total_tokens);
                try std.testing.expectEqual(ai.protocol.StopReason.toolUse, a.stop_reason);
                try std.testing.expectEqual(@as(usize, 2), a.content.len);
                // First block: toolCall
                switch (a.content[0]) {
                    .tool_call => |tc| {
                        try std.testing.expectEqualStrings("toolu_abc", tc.id);
                        try std.testing.expectEqualStrings("bash", tc.name);
                    },
                    else => return error.ExpectedToolCall,
                }
                // Second block: text
                switch (a.content[1]) {
                    .text => |tc| try std.testing.expectEqualStrings("done", tc.text),
                    else => return error.ExpectedText,
                }
            },
            else => return error.ExpectedAssistantMessage,
        },
        else => return error.ExpectedMessageEntry,
    }

    // Verify tool result parsed correctly
    const entry3 = result.entries[2];
    switch (entry3.entry) {
        .message => |m| switch (m.message) {
            .tool_result => |tr| {
                try std.testing.expectEqualStrings("toolu_abc", tr.tool_call_id);
                try std.testing.expectEqualStrings("bash", tr.tool_name);
                try std.testing.expect(!tr.is_error);
            },
            else => return error.ExpectedToolResult,
        },
        else => return error.ExpectedMessageEntry,
    }
}
