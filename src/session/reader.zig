const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent2/root.zig");
const proto = @import("protocol.zig");
const json = @import("json.zig");

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
    defer allocator.free(content);
    return parseSessionContent(allocator, content);
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

test "readSessionFile frees raw file buffer after parse" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(.{
        .sub_path = "session.jsonl",
        .data = "{\"type\":\"session\",\"id\":\"abc\",\"timestamp\":\"2025-01-01T00:00:00Z\",\"cwd\":\"/tmp\"}\n" ++
            "{\"type\":\"message\",\"id\":\"1\",\"parentId\":null,\"timestamp\":\"2025-01-01T00:00:01Z\",\"message\":{\"role\":\"user\",\"content\":\"hi\",\"timestamp\":1}}\n",
    });

    const path = try tmp.dir.realpathAlloc(std.testing.allocator, "session.jsonl");
    defer std.testing.allocator.free(path);

    var data = try readSessionFile(std.testing.allocator, path);
    defer data.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), data.entries.len);
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
