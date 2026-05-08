const std = @import("std");
const ai = @import("../../ai/root.zig");
const protocol = @import("../../agent/types.zig");
const session_core = @import("../../session/root.zig");
const session_proto = session_core.protocol;
const message_conversion = @import("message_conversion.zig");

pub fn infoGet(self: anytype, allocator: std.mem.Allocator) ?std.json.Value {
    var obj: std.json.ObjectMap = .{};
    obj.put(allocator, allocator.dupe(u8, "id") catch return null, .{ .string = allocator.dupe(u8, self.session_store.sessionId()) catch return null }) catch return null;
    obj.put(allocator, allocator.dupe(u8, "cwd") catch return null, .{ .string = allocator.dupe(u8, self.resource_loader.cwd) catch return null }) catch return null;
    const session_file = self.session_store.sessionFile();
    obj.put(allocator, allocator.dupe(u8, "file") catch return null, if (session_file.len > 0) .{ .string = allocator.dupe(u8, session_file) catch return null } else .null) catch return null;
    const name = latestName(self, allocator);
    defer if (name) |value| allocator.free(value);
    obj.put(allocator, allocator.dupe(u8, "name") catch return null, if (name) |value| .{ .string = allocator.dupe(u8, value) catch return null } else .null) catch return null;
    return .{ .object = obj };
}

pub fn latestName(self: anytype, allocator: std.mem.Allocator) ?[]const u8 {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var i = branch.len;
    while (i > 0) {
        i -= 1;
        const info = switch (branch[i].entry) {
            .session_info => |si| si,
            else => continue,
        };
        return if (info.name) |name| allocator.dupe(u8, name) catch null else null;
    }
    return null;
}

pub fn toolResultsGet(self: anytype, allocator: std.mem.Allocator, tool_name: []const u8) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var arr = std.json.Array.init(allocator);
    for (branch) |entry| {
        const msg = switch (entry.entry) {
            .message => |m| m.message,
            else => continue,
        };
        if (msg != .tool_result) continue;
        const tr = msg.tool_result;
        if (!std.mem.eql(u8, tr.tool_name, tool_name)) continue;
        arr.append(sessionToolResultJson(allocator, entry.id, tr) catch return null) catch return null;
    }
    return .{ .array = arr };
}

pub fn noteAppend(self: anytype, kind: []const u8, title: ?[]const u8, body: []const u8, source_entry_id: ?[]const u8) !void {
    const allocator = self.session_store.writer.allocator;
    var obj: std.json.ObjectMap = .{};
    errdefer ai.json_util.freeJsonValue(allocator, .{ .object = obj });
    try obj.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, kind) });
    if (title) |value| try obj.put(allocator, try allocator.dupe(u8, "title"), .{ .string = try allocator.dupe(u8, value) });
    if (source_entry_id) |value| try obj.put(allocator, try allocator.dupe(u8, "source_entry_id"), .{ .string = try allocator.dupe(u8, value) });
    try obj.put(allocator, try allocator.dupe(u8, "body"), .{ .string = try allocator.dupe(u8, body) });
    self.session_store.appendCustomEntry("extension_note", .{ .object = obj });
}

pub fn notesGet(self: anytype, allocator: std.mem.Allocator, kind: ?[]const u8, source_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var all = std.json.Array.init(allocator);
    for (branch) |entry| {
        const custom = switch (entry.entry) {
            .custom => |c| c,
            else => continue,
        };
        if (!std.mem.eql(u8, custom.custom_type, "extension_note")) continue;
        const data = custom.data orelse continue;
        if (data != .object) continue;
        if (kind) |wanted| {
            const value = data.object.get("kind") orelse continue;
            if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
        }
        if (source_entry_id) |wanted| {
            const value = data.object.get("source_entry_id") orelse continue;
            if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
        }
        var note = ai.json_util.cloneJsonValue(allocator, data) catch return null;
        if (note == .object) {
            note.object.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, entry.id) catch return null }) catch return null;
        }
        all.append(note) catch return null;
    }
    return limitedArray(allocator, all, limit);
}

pub fn artifactAppend(self: anytype, owner_id: []const u8, kind: []const u8, key: ?[]const u8, title: ?[]const u8, data: std.json.Value) !void {
    const allocator = self.session_store.writer.allocator;
    var obj: std.json.ObjectMap = .{};
    errdefer ai.json_util.freeJsonValue(allocator, .{ .object = obj });
    try obj.put(allocator, try allocator.dupe(u8, "owner_id"), .{ .string = try allocator.dupe(u8, owner_id) });
    try obj.put(allocator, try allocator.dupe(u8, "kind"), .{ .string = try allocator.dupe(u8, kind) });
    if (key) |value| try obj.put(allocator, try allocator.dupe(u8, "key"), .{ .string = try allocator.dupe(u8, value) });
    if (title) |value| try obj.put(allocator, try allocator.dupe(u8, "title"), .{ .string = try allocator.dupe(u8, value) });
    try obj.put(allocator, try allocator.dupe(u8, "data"), try ai.json_util.cloneJsonValue(allocator, data));
    self.session_store.appendCustomEntry("extension_artifact", .{ .object = obj });
}

pub fn artifactsGet(self: anytype, allocator: std.mem.Allocator, owner_id: []const u8, kind: ?[]const u8, key: ?[]const u8, limit: usize) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var all = std.json.Array.init(allocator);
    for (branch) |entry| {
        const custom = switch (entry.entry) {
            .custom => |c| c,
            else => continue,
        };
        if (!std.mem.eql(u8, custom.custom_type, "extension_artifact")) continue;
        const data = custom.data orelse continue;
        if (data != .object) continue;
        const owner_value = data.object.get("owner_id") orelse continue;
        if (owner_value != .string or !std.mem.eql(u8, owner_value.string, owner_id)) continue;
        if (kind) |wanted| {
            const value = data.object.get("kind") orelse continue;
            if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
        }
        if (key) |wanted| {
            const value = data.object.get("key") orelse continue;
            if (value != .string or !std.mem.eql(u8, value.string, wanted)) continue;
        }
        var artifact = ai.json_util.cloneJsonValue(allocator, data) catch return null;
        if (artifact == .object) {
            artifact.object.put(allocator, allocator.dupe(u8, "entry_id") catch return null, .{ .string = allocator.dupe(u8, entry.id) catch return null }) catch return null;
        }
        all.append(artifact) catch return null;
    }
    return limitedArray(allocator, all, limit);
}

pub fn messagesGet(self: anytype, allocator: std.mem.Allocator, limit: usize, include_tools: bool) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var all = std.json.Array.init(allocator);
    for (branch) |entry| {
        const msg = switch (entry.entry) {
            .message => |m| m.message,
            else => continue,
        };
        appendSessionMessageJson(allocator, &all, entry.id, msg, include_tools) catch return null;
    }
    return limitedArray(allocator, all, limit);
}

pub fn contextGet(self: anytype, allocator: std.mem.Allocator, max_messages: usize, include_tools: bool) ?std.json.Value {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const session_context = self.session_store.buildCurrentContextAlloc(aa) catch return null;
    const llm_messages = message_conversion.convertToLlm(aa, session_context.messages, null);

    var obj: std.json.ObjectMap = .{};
    obj.put(allocator, allocator.dupe(u8, "system_prompt") catch return null, .{ .string = allocator.dupe(u8, self.agent.systemPrompt()) catch return null }) catch return null;
    obj.put(allocator, allocator.dupe(u8, "messages") catch return null, contextMessagesJson(allocator, llm_messages, max_messages, include_tools) catch return null) catch return null;
    if (include_tools) {
        obj.put(allocator, allocator.dupe(u8, "tools") catch return null, contextToolsJson(allocator, self.tools) catch return null) catch return null;
    }
    return .{ .object = obj };
}

fn contextMessagesJson(allocator: std.mem.Allocator, messages: []const ai.protocol.Message, max_messages: usize, include_tools: bool) !std.json.Value {
    var all = std.json.Array.init(allocator);
    for (messages) |msg| {
        if (try contextMessageJson(allocator, msg, include_tools)) |value| try all.append(value);
    }
    return limitedArray(allocator, all, max_messages);
}

fn contextMessageJson(allocator: std.mem.Allocator, msg: ai.protocol.Message, include_tools: bool) !?std.json.Value {
    switch (msg) {
        .user => |user| return try contextUserMessageJson(allocator, user),
        .assistant => |assistant| return try contextAssistantMessageJson(allocator, assistant, include_tools),
        .tool_result => |tr| return if (include_tools) try contextToolResultJson(allocator, tr) else null,
    }
}

fn contextUserMessageJson(allocator: std.mem.Allocator, user: ai.protocol.UserMessage) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "user") });
    try obj.put(allocator, try allocator.dupe(u8, "content"), try userContentJson(allocator, user.content));
    try obj.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = user.timestamp });
    return .{ .object = obj };
}

fn contextAssistantMessageJson(allocator: std.mem.Allocator, assistant: ai.protocol.AssistantMessage, include_tools: bool) !?std.json.Value {
    var content = std.json.Array.init(allocator);
    for (assistant.content) |block| switch (block) {
        .text => |text| try content.append(try textBlockJson(allocator, text.text)),
        .thinking => |thinking| {
            var block_obj: std.json.ObjectMap = .{};
            try block_obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "thinking") });
            try block_obj.put(allocator, try allocator.dupe(u8, "thinking"), .{ .string = try allocator.dupe(u8, thinking.thinking) });
            try content.append(.{ .object = block_obj });
        },
        .tool_call => |call| if (include_tools) try content.append(try toolCallBlockJson(allocator, call)),
    };
    if (content.items.len == 0) return null;
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "assistant") });
    try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    try obj.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = assistant.timestamp });
    try obj.put(allocator, try allocator.dupe(u8, "model"), .{ .string = try allocator.dupe(u8, assistant.model) });
    return .{ .object = obj };
}

fn contextToolResultJson(allocator: std.mem.Allocator, tr: ai.protocol.ToolResultMessage) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool_result") });
    try obj.put(allocator, try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, tr.tool_call_id) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_name"), .{ .string = try allocator.dupe(u8, tr.tool_name) });
    try obj.put(allocator, try allocator.dupe(u8, "content"), try toolResultContentJson(allocator, tr.content));
    try obj.put(allocator, try allocator.dupe(u8, "is_error"), .{ .bool = tr.is_error });
    try obj.put(allocator, try allocator.dupe(u8, "timestamp"), .{ .integer = tr.timestamp });
    return .{ .object = obj };
}

fn userContentJson(allocator: std.mem.Allocator, content: ai.protocol.UserMessage.UserMessageContent) !std.json.Value {
    switch (content) {
        .text => |text| return .{ .string = try allocator.dupe(u8, text) },
        .blocks => |blocks| {
            var arr = std.json.Array.init(allocator);
            for (blocks) |block| switch (block) {
                .text => |text| try arr.append(try textBlockJson(allocator, text.text)),
                .image => {},
            };
            return .{ .array = arr };
        },
    }
}

fn toolResultContentJson(allocator: std.mem.Allocator, blocks: []const ai.protocol.ToolResultMessage.ContentBlock) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    for (blocks) |block| switch (block) {
        .text => |text| try arr.append(try textBlockJson(allocator, text.text)),
        .image => {},
    };
    return .{ .array = arr };
}

fn textBlockJson(allocator: std.mem.Allocator, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
    try obj.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    return .{ .object = obj };
}

fn toolCallBlockJson(allocator: std.mem.Allocator, call: ai.protocol.ToolCall) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "tool_call") });
    try obj.put(allocator, try allocator.dupe(u8, "id"), .{ .string = try allocator.dupe(u8, call.id) });
    try obj.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, call.name) });
    try obj.put(allocator, try allocator.dupe(u8, "arguments"), try ai.json_util.cloneJsonValue(allocator, call.arguments));
    return .{ .object = obj };
}

fn contextToolsJson(allocator: std.mem.Allocator, tools: anytype) !std.json.Value {
    var arr = std.json.Array.init(allocator);
    for (tools) |tool| {
        var obj: std.json.ObjectMap = .{};
        try obj.put(allocator, try allocator.dupe(u8, "name"), .{ .string = try allocator.dupe(u8, tool.name) });
        try obj.put(allocator, try allocator.dupe(u8, "description"), .{ .string = try allocator.dupe(u8, tool.description) });
        try obj.put(allocator, try allocator.dupe(u8, "parameters"), try ai.json_util.cloneJsonValue(allocator, tool.parameters));
        try arr.append(.{ .object = obj });
    }
    return .{ .array = arr };
}

pub fn entryGet(self: anytype, allocator: std.mem.Allocator, entry_id: []const u8) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    for (branch) |entry| {
        if (!std.mem.eql(u8, entry.id, entry_id)) continue;
        return sessionEntryJson(allocator, entry) catch return null;
    }
    return null;
}

pub fn labelSet(self: anytype, target_entry_id: []const u8, label: ?[]const u8) void {
    self.session_store.appendLabel(target_entry_id, label);
}

pub fn entriesGet(self: anytype, allocator: std.mem.Allocator, label: ?[]const u8, limit: usize) ?std.json.Value {
    const wanted = label orelse return .{ .array = std.json.Array.init(allocator) };
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);

    var latest_labels: std.StringHashMapUnmanaged(?[]const u8) = .{};
    defer latest_labels.deinit(allocator);
    for (branch) |entry| {
        const label_entry = switch (entry.entry) {
            .label => |value| value,
            else => continue,
        };
        latest_labels.put(allocator, label_entry.target_id, label_entry.label) catch return null;
    }

    var all = std.json.Array.init(allocator);
    for (branch) |entry| {
        const current = latest_labels.get(entry.id) orelse continue;
        const current_label = current orelse continue;
        if (!std.mem.eql(u8, current_label, wanted)) continue;
        all.append(sessionEntryJson(allocator, entry) catch return null) catch return null;
    }
    return limitedArray(allocator, all, limit);
}

pub fn labelsGet(self: anytype, allocator: std.mem.Allocator, target_entry_id: ?[]const u8, limit: usize) ?std.json.Value {
    const branch = self.session_store.buildCurrentVisibleBranchAlloc(allocator) catch return null;
    defer allocator.free(branch);
    var all = std.json.Array.init(allocator);
    for (branch) |entry| {
        const label_entry = switch (entry.entry) {
            .label => |label| label,
            else => continue,
        };
        if (target_entry_id) |wanted| {
            if (!std.mem.eql(u8, label_entry.target_id, wanted)) continue;
        }
        all.append(sessionLabelJson(allocator, entry.id, label_entry) catch return null) catch return null;
    }
    return limitedArray(allocator, all, limit);
}

fn limitedArray(allocator: std.mem.Allocator, all: std.json.Array, limit: usize) std.json.Value {
    var values = all;
    if (values.items.len <= limit) return .{ .array = values };
    const start = values.items.len - limit;
    for (values.items[0..start]) |value| ai.json_util.freeJsonValue(allocator, value);
    var out = std.json.Array.init(allocator);
    for (values.items[start..]) |value| out.append(value) catch return .{ .array = out };
    values.deinit();
    return .{ .array = out };
}

fn appendSessionMessageJson(allocator: std.mem.Allocator, arr: *std.json.Array, entry_id: []const u8, msg: protocol.AgentMessage, include_tools: bool) !void {
    switch (msg) {
        .user => |user| try arr.append(try sessionUserMessageJson(allocator, entry_id, user)),
        .assistant => |assistant| {
            var text = std.ArrayList(u8).empty;
            defer text.deinit(allocator);
            for (assistant.content) |block| switch (block) {
                .text => |t| {
                    if (text.items.len > 0) try text.append(allocator, '\n');
                    try text.appendSlice(allocator, t.text);
                },
                .tool_call => |call| if (include_tools) try arr.append(try sessionToolCallJson(allocator, entry_id, call)),
                .thinking => {},
            };
            if (text.items.len > 0) try arr.append(try sessionRoleTextJson(allocator, entry_id, "assistant", text.items));
        },
        .tool_result => |tr| if (include_tools) try arr.append(try sessionToolResultMessageJson(allocator, entry_id, tr)),
        .compaction_summary, .branch_summary, .custom => {},
    }
}

fn sessionUserMessageJson(allocator: std.mem.Allocator, entry_id: []const u8, user: ai.protocol.UserMessage) !std.json.Value {
    const text = switch (user.content) {
        .text => |text| text,
        .blocks => |blocks| blk: {
            for (blocks) |block| switch (block) {
                .text => |text| break :blk text.text,
                .image => {},
            };
            break :blk "";
        },
    };
    return sessionRoleTextJson(allocator, entry_id, "user", text);
}

fn sessionRoleTextJson(allocator: std.mem.Allocator, entry_id: []const u8, role: []const u8, text: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, role) });
    try obj.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text) });
    return .{ .object = obj };
}

fn sessionToolCallJson(allocator: std.mem.Allocator, entry_id: []const u8, call: ai.protocol.ToolCall) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool_call") });
    try obj.put(allocator, try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, call.id) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_name"), .{ .string = try allocator.dupe(u8, call.name) });
    try obj.put(allocator, try allocator.dupe(u8, "args"), try ai.json_util.cloneJsonValue(allocator, call.arguments));
    return .{ .object = obj };
}

fn sessionToolResultMessageJson(allocator: std.mem.Allocator, entry_id: []const u8, tr: ai.protocol.ToolResultMessage) !std.json.Value {
    var value = try sessionToolResultJson(allocator, entry_id, tr);
    try value.object.put(allocator, try allocator.dupe(u8, "role"), .{ .string = try allocator.dupe(u8, "tool_result") });
    return value;
}

fn sessionToolResultJson(allocator: std.mem.Allocator, entry_id: []const u8, tr: ai.protocol.ToolResultMessage) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_call_id"), .{ .string = try allocator.dupe(u8, tr.tool_call_id) });
    try obj.put(allocator, try allocator.dupe(u8, "tool_name"), .{ .string = try allocator.dupe(u8, tr.tool_name) });
    try obj.put(allocator, try allocator.dupe(u8, "is_error"), .{ .bool = tr.is_error });
    if (tr.details) |details| {
        try obj.put(allocator, try allocator.dupe(u8, "details"), try ai.json_util.cloneJsonValue(allocator, details));
    } else {
        try obj.put(allocator, try allocator.dupe(u8, "details"), .null);
    }
    var content = std.json.Array.init(allocator);
    for (tr.content) |block| switch (block) {
        .text => |text| {
            var block_obj: std.json.ObjectMap = .{};
            try block_obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "text") });
            try block_obj.put(allocator, try allocator.dupe(u8, "text"), .{ .string = try allocator.dupe(u8, text.text) });
            try content.append(.{ .object = block_obj });
        },
        .image => {},
    };
    try obj.put(allocator, try allocator.dupe(u8, "content"), .{ .array = content });
    return .{ .object = obj };
}

fn sessionEntryJson(allocator: std.mem.Allocator, entry: session_proto.SessionEntry) !std.json.Value {
    switch (entry.entry) {
        .message => |message| return sessionMessageEntryJson(allocator, entry.id, message.message),
        .custom => |custom| {
            if (std.mem.eql(u8, custom.custom_type, "extension_note") or std.mem.eql(u8, custom.custom_type, "extension_artifact")) {
                const data = custom.data orelse return sessionCustomEntryJson(allocator, entry.id, custom);
                if (data == .object) {
                    var value = try ai.json_util.cloneJsonValue(allocator, data);
                    try value.object.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry.id) });
                    try value.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, custom.custom_type) });
                    return value;
                }
            }
            return sessionCustomEntryJson(allocator, entry.id, custom);
        },
        .label => |label| return sessionLabelJson(allocator, entry.id, label),
        else => return sessionTypedEntryJson(allocator, entry.id, @tagName(entry.entry)),
    }
}

fn sessionMessageEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, msg: protocol.AgentMessage) !std.json.Value {
    var messages = std.json.Array.init(allocator);
    try appendSessionMessageJson(allocator, &messages, entry_id, msg, true);
    if (messages.items.len == 1) {
        var value = messages.items[0];
        messages.deinit();
        try value.object.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
        return value;
    }
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "message") });
    try obj.put(allocator, try allocator.dupe(u8, "messages"), .{ .array = messages });
    return .{ .object = obj };
}

fn sessionCustomEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, custom: session_proto.CustomEntry) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "custom") });
    try obj.put(allocator, try allocator.dupe(u8, "custom_type"), .{ .string = try allocator.dupe(u8, custom.custom_type) });
    try obj.put(allocator, try allocator.dupe(u8, "data"), if (custom.data) |data| try ai.json_util.cloneJsonValue(allocator, data) else .null);
    return .{ .object = obj };
}

fn sessionTypedEntryJson(allocator: std.mem.Allocator, entry_id: []const u8, entry_type: []const u8) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, entry_type) });
    return .{ .object = obj };
}

fn sessionLabelJson(allocator: std.mem.Allocator, entry_id: []const u8, label_entry: session_proto.LabelEntry) !std.json.Value {
    var obj: std.json.ObjectMap = .{};
    try obj.put(allocator, try allocator.dupe(u8, "entry_id"), .{ .string = try allocator.dupe(u8, entry_id) });
    try obj.put(allocator, try allocator.dupe(u8, "type"), .{ .string = try allocator.dupe(u8, "label") });
    try obj.put(allocator, try allocator.dupe(u8, "target_entry_id"), .{ .string = try allocator.dupe(u8, label_entry.target_id) });
    try obj.put(allocator, try allocator.dupe(u8, "label"), if (label_entry.label) |value| .{ .string = try allocator.dupe(u8, value) } else .null);
    return .{ .object = obj };
}

const testing = std.testing;
const session_runtime = @import("../session/root.zig");

const TestRuntimeSession = struct {
    session_store: session_runtime.store.SessionStore,
};

fn testSessionDir(tmp: *std.testing.TmpDir) ![:0]u8 {
    return try tmp.dir.realPathFileAlloc(std.Options.debug_io, ".", testing.allocator);
}

fn testUserMessage(text: []const u8, timestamp: i64) protocol.AgentMessage {
    return .{ .user = .{ .content = .{ .text = text }, .timestamp = timestamp } };
}

fn testAssistantMessage(allocator: std.mem.Allocator, text: []const u8, timestamp: i64) !protocol.AgentMessage {
    const content = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    content[0] = .{ .text = .{ .text = text } };
    return .{ .assistant = .{
        .content = content,
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "claude-test",
        .usage = .{
            .input = 1,
            .output = 1,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 2,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .stop,
        .timestamp = timestamp,
    } };
}

test "extension artifacts are owner-scoped branch entries and survive resume" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const session_dir = try testSessionDir(&tmp);
    defer testing.allocator.free(session_dir);

    var rt = TestRuntimeSession{ .session_store = session_runtime.store.SessionStore.create(testing.allocator, session_dir, "/tmp/project") };
    defer rt.session_store.deinit();

    var artifact_data: std.json.ObjectMap = .{};
    try artifact_data.put(testing.allocator, try testing.allocator.dupe(u8, "count"), .{ .integer = 2 });
    try artifactAppend(&rt, "owner-a", "state", "main", "Main", .{ .object = artifact_data });
    ai.json_util.freeJsonValue(testing.allocator, .{ .object = artifact_data });

    const visible = artifactsGet(&rt, testing.allocator, "owner-a", "state", "main", 10) orelse return error.MissingArtifact;
    defer ai.json_util.freeJsonValue(testing.allocator, visible);
    try testing.expectEqual(@as(usize, 1), visible.array.items.len);
    const first = visible.array.items[0].object;
    try testing.expectEqualStrings("owner-a", first.get("owner_id").?.string);
    try testing.expectEqualStrings("state", first.get("kind").?.string);
    try testing.expectEqualStrings("main", first.get("key").?.string);
    try testing.expectEqual(@as(i64, 2), first.get("data").?.object.get("count").?.integer);

    const other_owner = artifactsGet(&rt, testing.allocator, "owner-b", null, null, 10) orelse return error.MissingArtifactQuery;
    defer ai.json_util.freeJsonValue(testing.allocator, other_owner);
    try testing.expectEqual(@as(usize, 0), other_owner.array.items.len);

    _ = rt.session_store.appendMessage(testUserMessage("hi", 1)) orelse return error.MissingMessageId;
    const assistant = try testAssistantMessage(testing.allocator, "ok", 2);
    defer testing.allocator.free(assistant.assistant.content);
    _ = rt.session_store.appendMessage(assistant) orelse return error.MissingMessageId;

    const session_path = try testing.allocator.dupe(u8, rt.session_store.sessionFile());
    defer testing.allocator.free(session_path);

    rt.session_store.deinit();
    rt.session_store = try session_runtime.store.SessionStore.open(testing.allocator, session_path);

    const restored = artifactsGet(&rt, testing.allocator, "owner-a", "state", "main", 10) orelse return error.MissingRestoredArtifact;
    defer ai.json_util.freeJsonValue(testing.allocator, restored);
    try testing.expectEqual(@as(usize, 1), restored.array.items.len);
    try testing.expectEqualStrings("Main", restored.array.items[0].object.get("title").?.string);
}
