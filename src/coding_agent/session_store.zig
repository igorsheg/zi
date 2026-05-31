const std = @import("std");
const agent = @import("../agent/root.zig");
const ai = @import("../ai/root.zig");
const mem = @import("../runtime/root.zig");
const session_manager = @import("session_manager.zig");

pub const max_session_file_bytes = 64 * 1024 * 1024;
pub const max_session_line_bytes = 1024 * 1024;

pub const SessionStore = struct {
    dir: std.Io.Dir,
    file_name: []const u8,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        dir: std.Io.Dir,
        cwd: []const u8,
        session_id: []const u8,
        timestamp: []const u8,
    ) !SessionStore {
        const file_name = try std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ timestamp, session_id });
        errdefer allocator.free(file_name);
        var manager = try session_manager.SessionManager.init(allocator, cwd, session_id, timestamp);
        defer manager.deinit();
        const line = try formatHeaderLine(allocator, manager.header);
        defer allocator.free(line);
        try writeFileAtomic(io, dir, file_name, line);
        return .{ .dir = dir, .file_name = file_name };
    }

    pub fn deinit(self: *SessionStore, allocator: std.mem.Allocator) void {
        allocator.free(self.file_name);
        self.* = undefined;
    }

    pub fn appendEntry(
        self: SessionStore,
        allocator: std.mem.Allocator,
        io: std.Io,
        entry: session_manager.SessionEntry,
    ) !void {
        const line = try formatEntryLine(allocator, entry);
        defer allocator.free(line);
        try appendLine(io, self.dir, self.file_name, line);
    }

    pub fn load(self: SessionStore, allocator: std.mem.Allocator, io: std.Io) !session_manager.SessionManager {
        const data = try self.dir.readFileAlloc(io, self.file_name, allocator, .limited(max_session_file_bytes));
        defer allocator.free(data);
        return parseSession(allocator, data);
    }
};

fn writeFileAtomic(io: std.Io, dir: std.Io.Dir, file_name: []const u8, data: []const u8) !void {
    var tmp_name_buffer: [256]u8 = undefined;
    const tmp_name = try std.fmt.bufPrint(&tmp_name_buffer, ".{s}.tmp", .{file_name});
    try dir.writeFile(io, .{ .sub_path = tmp_name, .data = data });
    try std.Io.Dir.rename(dir, tmp_name, dir, file_name, io);
}

fn appendLine(io: std.Io, dir: std.Io.Dir, file_name: []const u8, line: []const u8) !void {
    if (line.len > max_session_line_bytes) return error.LineTooLong;
    const file = try dir.openFile(io, file_name, .{ .mode = .read_write });
    defer file.close(io);
    const offset = try file.length(io);
    try file.writePositionalAll(io, line, offset);
}

fn formatHeaderLine(allocator: std.mem.Allocator, header: session_manager.SessionHeader) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    try writer.writer.writeAll("{\"type\":\"session\",\"version\":");
    try writer.writer.print("{}", .{header.version});
    try writer.writer.writeAll(",\"id\":");
    try std.json.Stringify.value(header.id, .{}, &writer.writer);
    try writer.writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(header.timestamp, .{}, &writer.writer);
    try writer.writer.writeAll(",\"cwd\":");
    try std.json.Stringify.value(header.cwd, .{}, &writer.writer);
    if (header.parent_session) |parent_session| {
        try writer.writer.writeAll(",\"parentSession\":");
        try std.json.Stringify.value(parent_session, .{}, &writer.writer);
    }
    try writer.writer.writeAll("}\n");
    return writer.toOwnedSlice();
}

fn formatEntryLine(allocator: std.mem.Allocator, entry: session_manager.SessionEntry) ![]const u8 {
    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();
    switch (entry) {
        .message => |message| {
            try writeEntryBase("message", &writer.writer, message.base);
            try writer.writer.writeAll(",\"message\":");
            try writeAgentMessage(&writer.writer, message.message);
        },
        .thinking_level_change => |thinking| {
            try writeEntryBase("thinking_level_change", &writer.writer, thinking.base);
            try writer.writer.writeAll(",\"thinkingLevel\":");
            try std.json.Stringify.value(thinking.thinking_level, .{}, &writer.writer);
        },
        .model_change => |model| {
            try writeEntryBase("model_change", &writer.writer, model.base);
            try writer.writer.writeAll(",\"provider\":");
            try std.json.Stringify.value(model.provider, .{}, &writer.writer);
            try writer.writer.writeAll(",\"modelId\":");
            try std.json.Stringify.value(model.model_id, .{}, &writer.writer);
        },
    }
    try writer.writer.writeAll("}\n");
    return writer.toOwnedSlice();
}

fn writeEntryBase(
    comptime entry_type: []const u8,
    writer: *std.Io.Writer,
    base: session_manager.SessionEntry.Base,
) !void {
    try writer.writeAll("{\"type\":\"");
    try writer.writeAll(entry_type);
    try writer.writeAll("\",\"id\":");
    try std.json.Stringify.value(base.id, .{}, writer);
    try writer.writeAll(",\"parentId\":");
    if (base.parent_id) |parent_id| {
        try std.json.Stringify.value(parent_id, .{}, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(",\"timestamp\":");
    try std.json.Stringify.value(base.timestamp, .{}, writer);
}

fn writeAgentMessage(writer: *std.Io.Writer, message: agent.AgentMessage) !void {
    switch (message) {
        .user => |user| {
            try writer.writeAll("{\"role\":\"user\",\"content\":");
            switch (user.content) {
                .string => |text| try std.json.Stringify.value(text, .{}, writer),
                .blocks => |blocks| try writeUserContent(writer, blocks),
            }
            try writer.print(",\"timestamp\":{}", .{user.timestamp});
            try writer.writeAll("}");
        },
        .assistant => |assistant| {
            try writer.writeAll("{\"role\":\"assistant\",\"content\":");
            try writeAssistantContent(writer, assistant.content);
            try writer.writeAll(",\"api\":");
            try std.json.Stringify.value(assistant.api, .{}, writer);
            try writer.writeAll(",\"provider\":");
            try std.json.Stringify.value(assistant.provider, .{}, writer);
            try writer.writeAll(",\"model\":");
            try std.json.Stringify.value(assistant.model, .{}, writer);
            if (assistant.response_id) |response_id| {
                try writer.writeAll(",\"responseId\":");
                try std.json.Stringify.value(response_id, .{}, writer);
            }
            try writer.writeAll(",\"usage\":");
            try writeUsage(writer, assistant.usage);
            try writer.writeAll(",\"stopReason\":");
            try std.json.Stringify.value(stopReasonString(assistant.stop_reason), .{}, writer);
            if (assistant.error_message) |error_message| {
                try writer.writeAll(",\"errorMessage\":");
                try std.json.Stringify.value(error_message, .{}, writer);
            }
            try writer.print(",\"timestamp\":{}", .{assistant.timestamp});
            try writer.writeAll("}");
        },
        .tool_result => |tool_result| {
            try writer.writeAll("{\"role\":\"toolResult\",\"toolCallId\":");
            try std.json.Stringify.value(tool_result.tool_call_id, .{}, writer);
            try writer.writeAll(",\"toolName\":");
            try std.json.Stringify.value(tool_result.tool_name, .{}, writer);
            try writer.writeAll(",\"content\":");
            try writeToolResultContent(writer, tool_result.content);
            if (tool_result.details) |details| {
                try writer.writeAll(",\"details\":");
                try std.json.Stringify.value(details, .{}, writer);
            }
            try writer.print(",\"isError\":{},\"timestamp\":{}", .{ tool_result.is_error, tool_result.timestamp });
            try writer.writeAll("}");
        },
        .custom => |custom| {
            try writer.writeAll("{\"role\":\"custom\",\"customType\":");
            try std.json.Stringify.value(custom.kind, .{}, writer);
            try writer.writeAll(",\"payload\":");
            try std.json.Stringify.value(custom.payload, .{}, writer);
            try writer.print(",\"timestamp\":{}", .{custom.timestamp});
            try writer.writeAll("}");
        },
    }
}

fn writeUserContent(writer: *std.Io.Writer, content: []const ai.UserContent) !void {
    try writer.writeAll("[");
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        switch (block) {
            .text => |text| {
                try writeTextContent(writer, text);
            },
            .image => |image| try writeImageContent(writer, image),
        }
    }
    try writer.writeAll("]");
}

fn writeAssistantContent(writer: *std.Io.Writer, content: []const ai.AssistantContent) !void {
    try writer.writeAll("[");
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        switch (block) {
            .text => |text| {
                try writeTextContent(writer, text);
            },
            .thinking => |thinking| {
                try writer.writeAll("{\"type\":\"thinking\",\"thinking\":");
                try std.json.Stringify.value(thinking.thinking, .{}, writer);
                if (thinking.thinking_signature) |signature| {
                    try writer.writeAll(",\"thinkingSignature\":");
                    try std.json.Stringify.value(signature, .{}, writer);
                }
                try writer.print(",\"redacted\":{}", .{thinking.redacted});
                try writer.writeAll("}");
            },
            .tool_call => |tool_call| {
                try writer.writeAll("{\"type\":\"toolCall\",\"id\":");
                try std.json.Stringify.value(tool_call.id, .{}, writer);
                try writer.writeAll(",\"name\":");
                try std.json.Stringify.value(tool_call.name, .{}, writer);
                try writer.writeAll(",\"arguments\":");
                try std.json.Stringify.value(tool_call.arguments, .{}, writer);
                if (tool_call.thought_signature) |signature| {
                    try writer.writeAll(",\"thoughtSignature\":");
                    try std.json.Stringify.value(signature, .{}, writer);
                }
                try writer.writeAll("}");
            },
        }
    }
    try writer.writeAll("]");
}

fn writeToolResultContent(writer: *std.Io.Writer, content: []const ai.ToolResultContent) !void {
    try writer.writeAll("[");
    for (content, 0..) |block, index| {
        if (index > 0) try writer.writeAll(",");
        switch (block) {
            .text => |text| {
                try writeTextContent(writer, text);
            },
            .image => |image| try writeImageContent(writer, image),
        }
    }
    try writer.writeAll("]");
}

fn writeTextContent(writer: *std.Io.Writer, text: ai.TextContent) !void {
    try writer.writeAll("{\"type\":\"text\",\"text\":");
    try std.json.Stringify.value(text.text, .{}, writer);
    if (text.text_signature) |signature| {
        try writer.writeAll(",\"textSignature\":");
        try std.json.Stringify.value(signature, .{}, writer);
    }
    try writer.writeAll("}");
}

fn writeImageContent(writer: *std.Io.Writer, image: ai.ImageContent) !void {
    try writer.writeAll("{\"type\":\"image\",\"data\":");
    try std.json.Stringify.value(image.data, .{}, writer);
    try writer.writeAll(",\"mimeType\":");
    try std.json.Stringify.value(image.mime_type, .{}, writer);
    try writer.writeAll("}");
}

fn writeUsage(writer: *std.Io.Writer, usage: ai.Usage) !void {
    try writer.writeAll("{\"input\":");
    try writer.print("{}", .{usage.input});
    try writer.writeAll(",\"output\":");
    try writer.print("{}", .{usage.output});
    try writer.writeAll(",\"cacheRead\":");
    try writer.print("{}", .{usage.cache_read});
    try writer.writeAll(",\"cacheWrite\":");
    try writer.print("{}", .{usage.cache_write});
    try writer.writeAll(",\"totalTokens\":");
    try writer.print("{}", .{usage.total_tokens});
    try writer.writeAll(",\"cost\":{\"input\":");
    try writer.print("{}", .{usage.cost.input});
    try writer.writeAll(",\"output\":");
    try writer.print("{}", .{usage.cost.output});
    try writer.writeAll(",\"cacheRead\":");
    try writer.print("{}", .{usage.cost.cache_read});
    try writer.writeAll(",\"cacheWrite\":");
    try writer.print("{}", .{usage.cost.cache_write});
    try writer.writeAll(",\"total\":");
    try writer.print("{}", .{usage.cost.total});
    try writer.writeAll("}}");
}

fn stopReasonString(reason: ai.StopReason) []const u8 {
    return switch (reason) {
        .stop => "stop",
        .length => "length",
        .tool_use => "toolUse",
        .error_ => "error",
        .aborted => "aborted",
    };
}

fn parseSession(allocator: std.mem.Allocator, data: []const u8) !session_manager.SessionManager {
    var lines = std.mem.splitScalar(u8, data, '\n');
    const header_line = lines.next() orelse return error.MissingHeader;
    var parsed_header = try mem.JsonOwned(std.json.Value).parseJson(allocator, header_line, .{});
    defer parsed_header.deinit();
    const header = try jsonObject(parsed_header.value, error.InvalidHeader);
    if (!std.mem.eql(u8, try jsonString(header.get("type") orelse return error.InvalidHeader), "session")) {
        return error.InvalidHeader;
    }
    const version = try jsonInteger(header.get("version") orelse return error.InvalidHeader);
    if (version != session_manager.current_session_version) return error.UnsupportedVersion;
    var manager = try session_manager.SessionManager.init(
        allocator,
        try jsonString(header.get("cwd") orelse return error.InvalidHeader),
        try jsonString(header.get("id") orelse return error.InvalidHeader),
        try jsonString(header.get("timestamp") orelse return error.InvalidHeader),
    );
    errdefer manager.deinit();
    if (header.get("parentSession")) |parent_session| {
        manager.header.parent_session = try allocator.dupe(u8, try jsonString(parent_session));
    }

    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \t\r").len == 0) continue;
        if (line.len > max_session_line_bytes) return error.LineTooLong;
        try parseEntryLine(allocator, &manager, line);
    }
    return manager;
}

fn parseEntryLine(allocator: std.mem.Allocator, manager: *session_manager.SessionManager, line: []const u8) !void {
    var parsed = try mem.JsonOwned(std.json.Value).parseJson(allocator, line, .{});
    defer parsed.deinit();
    const object = try jsonObject(parsed.value, error.InvalidEntry);
    const entry_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
    const loaded_base: session_manager.SessionManager.LoadedEntry = .{
        .id = try jsonString(object.get("id") orelse return error.InvalidEntry),
        .parent_id = try jsonOptionalString(object.get("parentId") orelse return error.InvalidEntry),
        .timestamp = try jsonString(object.get("timestamp") orelse return error.InvalidEntry),
        .value = undefined,
    };
    if (std.mem.eql(u8, entry_type, "message")) {
        const message = try parseMessage(allocator, object.get("message") orelse return error.InvalidEntry);
        defer deinitParsedMessageContainers(allocator, message);
        var loaded = loaded_base;
        loaded.value = .{ .message = message };
        _ = try manager.appendLoadedEntry(loaded);
    } else if (std.mem.eql(u8, entry_type, "thinking_level_change")) {
        var loaded = loaded_base;
        loaded.value = .{
            .thinking_level_change = try jsonString(object.get("thinkingLevel") orelse return error.InvalidEntry),
        };
        _ = try manager.appendLoadedEntry(loaded);
    } else if (std.mem.eql(u8, entry_type, "model_change")) {
        var loaded = loaded_base;
        loaded.value = .{ .model_change = .{
            .provider = try jsonString(object.get("provider") orelse return error.InvalidEntry),
            .model_id = try jsonString(object.get("modelId") orelse return error.InvalidEntry),
        } };
        _ = try manager.appendLoadedEntry(loaded);
    } else {
        return error.InvalidEntry;
    }
}

fn parseMessage(allocator: std.mem.Allocator, value: std.json.Value) !agent.AgentMessage {
    const object = try jsonObject(value, error.InvalidEntry);
    const role = try jsonString(object.get("role") orelse return error.InvalidEntry);
    if (std.mem.eql(u8, role, "user")) {
        const raw_content = object.get("content") orelse return error.InvalidEntry;
        const content: ai.UserMessage.Content = switch (raw_content) {
            .string => |text| .{ .string = text },
            .array => |array| .{ .blocks = try parseUserContent(allocator, array.items) },
            else => return error.InvalidEntry,
        };
        errdefer switch (content) {
            .string => {},
            .blocks => |blocks| allocator.free(blocks),
        };
        return .{ .user = .{
            .content = content,
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "assistant")) {
        const content = try parseAssistantContent(
            allocator,
            try jsonArray(object.get("content") orelse return error.InvalidEntry),
        );
        errdefer allocator.free(content);
        return .{ .assistant = .{
            .content = content,
            .api = try jsonString(object.get("api") orelse return error.InvalidEntry),
            .provider = try jsonString(object.get("provider") orelse return error.InvalidEntry),
            .model = try jsonString(object.get("model") orelse return error.InvalidEntry),
            .response_id = try jsonOptionalFieldString(object.get("responseId")),
            .usage = try parseUsage(object.get("usage") orelse return error.InvalidEntry),
            .stop_reason = try parseStopReason(
                try jsonString(object.get("stopReason") orelse return error.InvalidEntry),
            ),
            .error_message = try jsonOptionalFieldString(object.get("errorMessage")),
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "toolResult")) {
        const content = try parseToolResultContent(
            allocator,
            try jsonArray(object.get("content") orelse return error.InvalidEntry),
        );
        errdefer allocator.free(content);
        return .{ .tool_result = .{
            .tool_call_id = try jsonString(object.get("toolCallId") orelse return error.InvalidEntry),
            .tool_name = try jsonString(object.get("toolName") orelse return error.InvalidEntry),
            .content = content,
            .details = object.get("details"),
            .is_error = try jsonBool(object.get("isError") orelse return error.InvalidEntry),
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    if (std.mem.eql(u8, role, "custom")) {
        return .{ .custom = .{
            .kind = try jsonString(object.get("customType") orelse return error.InvalidEntry),
            .payload = object.get("payload") orelse return error.InvalidEntry,
            .timestamp = try jsonInteger(object.get("timestamp") orelse return error.InvalidEntry),
        } };
    }
    return error.InvalidEntry;
}

fn parseUserContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.UserContent {
    const out = try allocator.alloc(ai.UserContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "image")) {
            content.* = .{ .image = try parseImageContent(object) };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseAssistantContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.AssistantContent {
    const out = try allocator.alloc(ai.AssistantContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "thinking")) {
            content.* = .{ .thinking = .{
                .thinking = try jsonString(object.get("thinking") orelse return error.InvalidEntry),
                .thinking_signature = try jsonOptionalFieldString(object.get("thinkingSignature")),
                .redacted = if (object.get("redacted")) |redacted| try jsonBool(redacted) else false,
            } };
        } else if (std.mem.eql(u8, block_type, "toolCall")) {
            content.* = .{ .tool_call = .{
                .id = try jsonString(object.get("id") orelse return error.InvalidEntry),
                .name = try jsonString(object.get("name") orelse return error.InvalidEntry),
                .arguments = object.get("arguments") orelse return error.InvalidEntry,
                .thought_signature = try jsonOptionalFieldString(object.get("thoughtSignature")),
            } };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseToolResultContent(allocator: std.mem.Allocator, values: []const std.json.Value) ![]const ai.ToolResultContent {
    const out = try allocator.alloc(ai.ToolResultContent, values.len);
    errdefer allocator.free(out);
    for (values, out) |value, *content| {
        const object = try jsonObject(value, error.InvalidEntry);
        const block_type = try jsonString(object.get("type") orelse return error.InvalidEntry);
        if (std.mem.eql(u8, block_type, "text")) {
            content.* = .{ .text = .{
                .text = try jsonString(object.get("text") orelse return error.InvalidEntry),
                .text_signature = try jsonOptionalFieldString(object.get("textSignature")),
            } };
        } else if (std.mem.eql(u8, block_type, "image")) {
            content.* = .{ .image = try parseImageContent(object) };
        } else {
            return error.InvalidEntry;
        }
    }
    return out;
}

fn parseImageContent(object: std.json.ObjectMap) !ai.ImageContent {
    return .{
        .data = try jsonString(object.get("data") orelse return error.InvalidEntry),
        .mime_type = try jsonString(object.get("mimeType") orelse return error.InvalidEntry),
    };
}

fn parseUsage(value: std.json.Value) !ai.Usage {
    const object = try jsonObject(value, error.InvalidEntry);
    const cost = try jsonObject(object.get("cost") orelse return error.InvalidEntry, error.InvalidEntry);
    return .{
        .input = try jsonNonNegativeInteger(object.get("input") orelse return error.InvalidEntry),
        .output = try jsonNonNegativeInteger(object.get("output") orelse return error.InvalidEntry),
        .cache_read = try jsonNonNegativeInteger(object.get("cacheRead") orelse return error.InvalidEntry),
        .cache_write = try jsonNonNegativeInteger(object.get("cacheWrite") orelse return error.InvalidEntry),
        .total_tokens = try jsonNonNegativeInteger(object.get("totalTokens") orelse return error.InvalidEntry),
        .cost = .{
            .input = try jsonFloat(cost.get("input") orelse return error.InvalidEntry),
            .output = try jsonFloat(cost.get("output") orelse return error.InvalidEntry),
            .cache_read = try jsonFloat(cost.get("cacheRead") orelse return error.InvalidEntry),
            .cache_write = try jsonFloat(cost.get("cacheWrite") orelse return error.InvalidEntry),
            .total = try jsonFloat(cost.get("total") orelse return error.InvalidEntry),
        },
    };
}

fn parseStopReason(value: []const u8) !ai.StopReason {
    if (std.mem.eql(u8, value, "stop")) return .stop;
    if (std.mem.eql(u8, value, "length")) return .length;
    if (std.mem.eql(u8, value, "toolUse")) return .tool_use;
    if (std.mem.eql(u8, value, "error")) return .error_;
    if (std.mem.eql(u8, value, "aborted")) return .aborted;
    return error.InvalidEntry;
}

fn deinitParsedMessageContainers(allocator: std.mem.Allocator, message: agent.AgentMessage) void {
    switch (message) {
        .user => |user| switch (user.content) {
            .string => {},
            .blocks => |blocks| allocator.free(blocks),
        },
        .assistant => |assistant| allocator.free(assistant.content),
        .tool_result => |tool_result| allocator.free(tool_result.content),
        .custom => {},
    }
}

fn jsonObject(value: std.json.Value, err: anyerror) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => err,
    };
}

fn jsonArray(value: std.json.Value) ![]const std.json.Value {
    return switch (value) {
        .array => |array| array.items,
        else => error.InvalidEntry,
    };
}

fn jsonOptionalFieldString(value: ?std.json.Value) !?[]const u8 {
    return if (value) |actual| try jsonOptionalString(actual) else null;
}

fn jsonInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |actual| @intCast(actual),
        else => error.InvalidEntry,
    };
}

fn jsonNonNegativeInteger(value: std.json.Value) !u64 {
    const integer = try jsonInteger(value);
    if (integer < 0) return error.InvalidEntry;
    return @intCast(integer);
}

fn jsonBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |actual| actual,
        else => error.InvalidEntry,
    };
}

fn jsonFloat(value: std.json.Value) !f64 {
    return switch (value) {
        .float => |actual| actual,
        .integer => |actual| @floatFromInt(actual),
        else => error.InvalidEntry,
    };
}

fn jsonOptionalString(value: std.json.Value) !?[]const u8 {
    return switch (value) {
        .null => null,
        .string => |text| text,
        else => error.InvalidEntry,
    };
}

fn jsonString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |text| text,
        else => error.InvalidEntry,
    };
}

test "session parser rejects malformed json shapes" {
    try std.testing.expectError(error.InvalidHeader, parseSession(std.testing.allocator, "[]\n"));
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n[]\n",
        ),
    );
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
                "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
                "{\"role\":\"assistant\",\"content\":123}}\n",
        ),
    );
}

test "session parser rejects negative usage" {
    try std.testing.expectError(
        error.InvalidEntry,
        parseSession(
            std.testing.allocator,
            "{\"type\":\"session\",\"version\":3,\"id\":\"s\",\"timestamp\":\"t\",\"cwd\":\"/repo\"}\n" ++
                "{\"type\":\"message\",\"id\":\"00000001\",\"parentId\":null,\"timestamp\":\"t\",\"message\":" ++
                "{\"role\":\"assistant\",\"content\":[],\"api\":\"openai-responses\",\"provider\":\"openai\"," ++
                "\"model\":\"gpt\",\"usage\":{\"input\":-1,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0," ++
                "\"totalTokens\":0,\"cost\":{\"input\":0,\"output\":0,\"cacheRead\":0,\"cacheWrite\":0," ++
                "\"total\":0}},\"stopReason\":\"stop\",\"timestamp\":0}}\n",
        ),
    );
}

test "session store creates header file and loads empty manager" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, "/repo", "session-1", "t0");
    defer store.deinit(std.testing.allocator);

    var loaded = try store.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqualStrings("session-1", loaded.header.id);
    try std.testing.expectEqual(@as(usize, 0), loaded.entries.items.len);
}

test "session store appends entries and round trips context" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, "/repo", "session-1", "t0");
    defer store.deinit(std.testing.allocator);
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendModelChange("openai", "gpt", "t1");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[0]);
    _ = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "hello" }, .timestamp = 0 } }, "t2");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[1]);

    var loaded = try store.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 1), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content.string);
    try std.testing.expectEqualStrings("openai", context.model.?.provider);
}

test "session store round trips agent message variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, "/repo", "session-1", "t0");
    defer store.deinit(std.testing.allocator);
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    _ = try manager.appendMessage(.{ .user = .{
        .content = .{ .blocks = &.{.{ .text = .{ .text = "hello" } }} },
        .timestamp = 11,
    } }, "t1");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[0]);
    _ = try manager.appendMessage(.{ .assistant = .{
        .content = &.{
            .{ .text = .{ .text = "hi" } },
            .{ .thinking = .{ .thinking = "hmm", .redacted = true } },
            .{ .tool_call = .{ .id = "call-1", .name = "bash", .arguments = .{ .object = .empty } } },
        },
        .api = ai.KnownApi.anthropic_messages,
        .provider = "anthropic",
        .model = "claude",
        .usage = ai.protocol.emptyUsage(),
        .stop_reason = .tool_use,
        .timestamp = 12,
    } }, "t2");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[1]);
    _ = try manager.appendMessage(.{ .tool_result = .{
        .tool_call_id = "call-1",
        .tool_name = "bash",
        .content = &.{.{ .text = .{ .text = "ok" } }},
        .details = .{ .string = "detail" },
        .is_error = false,
        .timestamp = 13,
    } }, "t3");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[2]);
    _ = try manager.appendMessage(.{ .custom = .{
        .kind = "extension",
        .payload = .{ .string = "payload" },
        .timestamp = 14,
    } }, "t4");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[3]);

    var loaded = try store.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();
    const context = try loaded.buildSessionContext(std.testing.allocator);
    defer loaded.deinitSessionContext(std.testing.allocator, context);

    try std.testing.expectEqual(@as(usize, 4), context.messages.len);
    try std.testing.expectEqualStrings("hello", context.messages[0].user.content.blocks[0].text.text);
    try std.testing.expectEqualStrings("hi", context.messages[1].assistant.content[0].text.text);
    try std.testing.expectEqualStrings("call-1", context.messages[1].assistant.content[2].tool_call.id);
    try std.testing.expectEqualStrings("ok", context.messages[2].tool_result.content[0].text.text);
    try std.testing.expectEqualStrings("extension", context.messages[3].custom.kind);
}

test "session store load preserves entry ids and parent links" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var store = try SessionStore.create(std.testing.allocator, std.testing.io, tmp.dir, "/repo", "session-1", "t0");
    defer store.deinit(std.testing.allocator);
    var manager = try session_manager.SessionManager.init(std.testing.allocator, "/repo", "session-1", "t0");
    defer manager.deinit();

    const root = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "root" }, .timestamp = 0 } }, "t1");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[0]);
    const child = try manager.appendMessage(.{ .user = .{ .content = .{ .string = "child" }, .timestamp = 0 } }, "t2");
    try store.appendEntry(std.testing.allocator, std.testing.io, manager.entries.items[1]);

    var loaded = try store.load(std.testing.allocator, std.testing.io);
    defer loaded.deinit();

    try std.testing.expectEqualStrings(root, loaded.entries.items[0].id());
    try std.testing.expectEqualStrings(child, loaded.entries.items[1].id());
    try std.testing.expectEqualStrings(root, loaded.entries.items[1].parentId().?);

    _ = try loaded.appendMessage(.{ .user = .{ .content = .{ .string = "next" }, .timestamp = 0 } }, "t3");
    try std.testing.expectEqualStrings("00000003", loaded.entries.items[2].id());
}
