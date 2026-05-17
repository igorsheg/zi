const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const json_text = @import("../json/text.zig");
const json_value = @import("../json/value.zig");

const Stringify = std.json.Stringify;

const Field = struct {
    const api = "api";
    const arguments = "arguments";
    const cache_read = "cacheRead";
    const cache_write = "cacheWrite";
    const content = "content";
    const cost = "cost";
    const custom_type = "customType";
    const cwd = "cwd";
    const data = "data";
    const details = "details";
    const display = "display";
    const error_message = "errorMessage";
    const failure = "failure";
    const first_kept_entry_id = "firstKeptEntryId";
    const from_hook = "fromHook";
    const http_status = "httpStatus";
    const from_id = "fromId";
    const id = "id";
    const include_in_context = "includeInContext";
    const input = "input";
    const is_error = "isError";
    const kind = "kind";
    const message = "message";
    const model_id = "modelId";
    const mime_type = "mimeType";
    const model = "model";
    const name = "name";
    const output = "output";
    const parent_id = "parentId";
    const parent_session = "parentSession";
    const presentation = "presentation";
    const provider = "provider";
    const provider_code = "providerCode";
    const provider_type = "providerType";
    const redacted = "redacted";
    const response_id = "responseId";
    const retry_after_ms = "retryAfterMs";
    const role = "role";
    const stop_reason = "stopReason";
    const summary = "summary";
    const text = "text";
    const text_signature = "textSignature";
    const thinking = "thinking";
    const thinking_signature = "thinkingSignature";
    const thought_signature = "thoughtSignature";
    const timestamp = "timestamp";
    const tokens_before = "tokensBefore";
    const tool_call_id = "toolCallId";
    const tool_name = "toolName";
    const total = "total";
    const total_tokens = "totalTokens";
    const target_id = "targetId";
    const label = "label";
    const thinking_level = "thinkingLevel";
    const kind_type = "type";
    const usage = "usage";
    const version = "version";
};

const Tag = struct {
    const assistant = "assistant";
    const branch_summary = "branchSummary";
    const compaction_summary = "compactionSummary";
    const custom = "custom";
    const image = "image";
    const message = "message";
    const thinking_level_change = "thinking_level_change";
    const model_change = "model_change";
    const compaction = "compaction";
    const branch_summary_entry = "branch_summary";
    const custom_message = "custom_message";
    const label = "label";
    const session = "session";
    const session_info = "session_info";
    const text = "text";
    const thinking = "thinking";
    const tool_call = "toolCall";
    const tool_result = "toolResult";
    const user = "user";
};

fn headerToOwnedLine(allocator: std.mem.Allocator, header: proto.SessionHeader) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try writeHeader(&out.writer, header);
    return try out.toOwnedSlice();
}

fn entryToOwnedLine(allocator: std.mem.Allocator, entry: proto.SessionEntry) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();

    try writeEntry(allocator, &out.writer, entry);
    return try out.toOwnedSlice();
}

pub fn writeHeader(writer: *std.Io.Writer, header: proto.SessionHeader) !void {
    var jw: Stringify = .{ .writer = writer };

    try jw.beginObject();
    try jw.objectField(Field.kind_type);
    try jw.write(Tag.session);
    try jw.objectField(Field.version);
    try jw.write(header.version);
    try jw.objectField(Field.id);
    try jw.write(header.id);
    try jw.objectField(Field.timestamp);
    try jw.write(header.timestamp);
    try jw.objectField(Field.cwd);
    try jw.write(header.cwd);
    if (header.parent_session) |ps| {
        try jw.objectField(Field.parent_session);
        try jw.write(ps);
    }
    try jw.endObject();
}

pub fn writeEntry(allocator: std.mem.Allocator, writer: *std.Io.Writer, entry: proto.SessionEntry) !void {
    var jw: Stringify = .{ .writer = writer };

    try jw.beginObject();

    try jw.objectField(Field.kind_type);
    try jw.write(switch (entry.entry) {
        .message => Tag.message,
        .thinking_level_change => Tag.thinking_level_change,
        .model_change => Tag.model_change,
        .compaction => Tag.compaction,
        .branch_summary => Tag.branch_summary_entry,
        .custom => Tag.custom,
        .custom_message => Tag.custom_message,
        .label => Tag.label,
        .session_info => Tag.session_info,
    });

    try jw.objectField(Field.id);
    try jw.write(entry.id);
    try jw.objectField(Field.parent_id);
    if (entry.parent_id) |pid| {
        try jw.write(pid);
    } else {
        try jw.write(null);
    }
    try jw.objectField(Field.timestamp);
    try jw.write(entry.timestamp);

    switch (entry.entry) {
        .message => |m| {
            try jw.objectField(Field.message);
            try writeAgentMessage(allocator, &jw, m.message);
        },
        .thinking_level_change => |t| {
            try jw.objectField(Field.thinking_level);
            try jw.write(t.thinking_level);
        },
        .model_change => |m| {
            try jw.objectField(Field.provider);
            try jw.write(m.provider);
            try jw.objectField(Field.model_id);
            try jw.write(m.model_id);
        },
        .compaction => |c| {
            try jw.objectField(Field.summary);
            try jw.write(c.summary);
            try jw.objectField(Field.first_kept_entry_id);
            try jw.write(c.first_kept_entry_id);
            try jw.objectField(Field.tokens_before);
            try jw.write(c.tokens_before);
            if (c.details) |d| {
                try jw.objectField(Field.details);
                try jw.write(d.borrowed());
            }
            if (c.from_hook) |fh| {
                try jw.objectField(Field.from_hook);
                try jw.write(fh);
            }
        },
        .branch_summary => |bs| {
            try jw.objectField(Field.from_id);
            try jw.write(bs.from_id);
            try jw.objectField(Field.summary);
            try jw.write(bs.summary);
            if (bs.details) |d| {
                try jw.objectField(Field.details);
                try jw.write(d.borrowed());
            }
            if (bs.from_hook) |fh| {
                try jw.objectField(Field.from_hook);
                try jw.write(fh);
            }
        },
        .custom => |c| {
            try jw.objectField(Field.custom_type);
            try jw.write(c.custom_type);
            if (c.data) |d| {
                try jw.objectField(Field.data);
                try jw.write(d.borrowed());
            }
        },
        .custom_message => |cm| {
            try jw.objectField(Field.custom_type);
            try jw.write(cm.custom_type);
            try jw.objectField(Field.content);
            try writeCustomContent(allocator, &jw, cm.content);
            if (cm.details) |d| {
                try jw.objectField(Field.details);
                try jw.write(d.borrowed());
            }
            try jw.objectField(Field.display);
            try jw.write(cm.display);
            try jw.objectField(Field.include_in_context);
            try jw.write(cm.include_in_context);
        },
        .label => |l| {
            try jw.objectField(Field.target_id);
            try jw.write(l.target_id);
            if (l.label) |lbl| {
                try jw.objectField(Field.label);
                try jw.write(lbl);
            }
        },
        .session_info => |si| {
            if (si.name) |n| {
                try jw.objectField(Field.name);
                try jw.write(n);
            }
        },
    }

    try jw.endObject();
}

pub fn writeAgentMessage(allocator: std.mem.Allocator, jw: *Stringify, msg: agent.protocol.AgentMessage) !void {
    switch (msg) {
        .user => |u| try writeUserMessage(allocator, jw, u),
        .assistant => |a| try writeAssistantMessage(allocator, jw, a),
        .tool_result => |tr| try writeToolResultMessage(allocator, jw, tr),
        .compaction_summary => |cs| try writeCompactionSummaryMessage(jw, cs),
        .branch_summary => |bs| try writeBranchSummaryMessage(jw, bs),
        .custom => |c| try writeCustomMessage(allocator, jw, c),
    }
}

pub fn writeUserMessage(allocator: std.mem.Allocator, jw: *Stringify, msg: ai.protocol.UserMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.user);
    try jw.objectField(Field.content);
    switch (msg.content) {
        .text => |t| {
            try jw.write(t);
        },
        .blocks => |blocks| {
            try jw.beginArray();
            for (blocks) |block| {
                switch (block) {
                    .text => |tc| try writeTextBlock(allocator, jw, tc),
                    .image => |ic| try writeImageBlock(jw, ic),
                }
            }
            try jw.endArray();
        },
    }
    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeAssistantMessage(allocator: std.mem.Allocator, jw: *Stringify, msg: ai.protocol.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.assistant);

    try jw.objectField(Field.content);
    try jw.beginArray();
    for (msg.content) |block| {
        switch (block) {
            .text => |tc| try writeTextBlock(allocator, jw, tc),
            .thinking => |th| try writeThinkingBlock(jw, th),
            .tool_call => |tc| try writeToolCallBlock(jw, tc),
        }
    }
    try jw.endArray();

    try jw.objectField(Field.api);
    try jw.write(ai.protocol.apiToString(msg.api));
    try jw.objectField(Field.provider);
    try jw.write(ai.protocol.providerToString(msg.provider));
    try jw.objectField(Field.model);
    try jw.write(msg.model);

    if (msg.response_id) |rid| {
        try jw.objectField(Field.response_id);
        try jw.write(rid);
    }

    try jw.objectField(Field.usage);
    try writeUsage(jw, msg.usage);

    try jw.objectField(Field.stop_reason);
    try jw.write(ai.protocol.stopReasonToString(msg.stop_reason));

    if (msg.error_message) |em| {
        try jw.objectField(Field.error_message);
        try jw.write(em);
    }
    if (msg.failure) |failure| {
        try jw.objectField(Field.failure);
        try writeNormalizedFailure(jw, failure);
    }

    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeToolResultMessage(allocator: std.mem.Allocator, jw: *Stringify, msg: ai.protocol.ToolResultMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.tool_result);
    try jw.objectField(Field.tool_call_id);
    try jw.write(msg.tool_call_id);
    try jw.objectField(Field.tool_name);
    try jw.write(msg.tool_name);

    try jw.objectField(Field.content);
    try jw.beginArray();
    for (msg.content) |block| {
        switch (block) {
            .text => |tc| try writeTextBlock(allocator, jw, tc),
            .image => |ic| try writeImageBlock(jw, ic),
        }
    }
    try jw.endArray();

    if (msg.details) |d| {
        try jw.objectField(Field.details);
        try jw.write(d.borrowed());
    }
    if (msg.presentation) |p| {
        try jw.objectField(Field.presentation);
        try jw.write(p.borrowed());
    }
    try jw.objectField(Field.is_error);
    try jw.write(msg.is_error);
    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCompactionSummaryMessage(jw: *Stringify, msg: agent.protocol.AgentMessage.CompactionSummaryMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.compaction_summary);
    try jw.objectField(Field.summary);
    try jw.write(msg.summary);
    try jw.objectField(Field.tokens_before);
    try jw.write(msg.tokens_before);
    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeBranchSummaryMessage(jw: *Stringify, msg: agent.protocol.AgentMessage.BranchSummaryMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.branch_summary);
    try jw.objectField(Field.summary);
    try jw.write(msg.summary);
    try jw.objectField(Field.from_id);
    try jw.write(msg.from_id);
    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCustomMessage(allocator: std.mem.Allocator, jw: *Stringify, msg: agent.protocol.AgentMessage.CustomMessage) !void {
    try jw.beginObject();
    try jw.objectField(Field.role);
    try jw.write(Tag.custom);
    try jw.objectField(Field.custom_type);
    try jw.write(msg.custom_type);
    try jw.objectField(Field.content);
    try writeCustomContent(allocator, jw, msg.content);
    if (msg.details) |d| {
        try jw.objectField(Field.details);
        try jw.write(d.borrowed());
    }
    try jw.objectField(Field.display);
    try jw.write(msg.display);
    try jw.objectField(Field.timestamp);
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCustomContent(allocator: std.mem.Allocator, jw: *Stringify, content: agent.protocol.AgentMessage.CustomContent) !void {
    switch (content) {
        .text => |t| try jw.write(t),
        .blocks => |blocks| {
            try jw.beginArray();
            for (blocks) |block| {
                switch (block) {
                    .text => |tc| try writeTextBlock(allocator, jw, tc),
                    .image => |ic| try writeImageBlock(jw, ic),
                }
            }
            try jw.endArray();
        },
    }
}

pub fn writeTextBlock(allocator: std.mem.Allocator, jw: *Stringify, tc: ai.protocol.TextContent) !void {
    try jw.beginObject();
    try jw.objectField(Field.kind_type);
    try jw.write(Tag.text);
    try jw.objectField(Field.text);
    const sanitized = try json_text.utf8LossyAlloc(allocator, tc.text);
    defer allocator.free(sanitized);
    try jw.write(sanitized);
    if (tc.text_signature) |sig| {
        try jw.objectField(Field.text_signature);
        try jw.write(sig);
    }
    try jw.endObject();
}

pub fn writeThinkingBlock(jw: *Stringify, th: ai.protocol.ThinkingContent) !void {
    try jw.beginObject();
    try jw.objectField(Field.kind_type);
    try jw.write(Tag.thinking);
    try jw.objectField(Field.thinking);
    try jw.write(th.thinking);
    if (th.thinking_signature) |sig| {
        try jw.objectField(Field.thinking_signature);
        try jw.write(sig);
    }
    if (th.redacted) |r| {
        try jw.objectField(Field.redacted);
        try jw.write(r);
    }
    try jw.endObject();
}

pub fn writeToolCallBlock(jw: *Stringify, tc: ai.protocol.ToolCall) !void {
    try jw.beginObject();
    try jw.objectField(Field.kind_type);
    try jw.write(Tag.tool_call);
    try jw.objectField(Field.id);
    try jw.write(tc.id);
    try jw.objectField(Field.name);
    try jw.write(tc.name);
    try jw.objectField(Field.arguments);
    try jw.write(tc.arguments.borrowed());
    if (tc.thought_signature) |sig| {
        try jw.objectField(Field.thought_signature);
        try jw.write(sig);
    }
    try jw.endObject();
}

pub fn writeImageBlock(jw: *Stringify, ic: ai.protocol.ImageContent) !void {
    try jw.beginObject();
    try jw.objectField(Field.kind_type);
    try jw.write(Tag.image);
    try jw.objectField(Field.data);
    try jw.write(ic.data);
    try jw.objectField(Field.mime_type);
    try jw.write(ic.mime_type);
    try jw.endObject();
}

pub fn writeUsage(jw: *Stringify, usage: ai.protocol.Usage) !void {
    try jw.beginObject();
    try jw.objectField(Field.input);
    try jw.write(usage.input);
    try jw.objectField(Field.output);
    try jw.write(usage.output);
    try jw.objectField(Field.cache_read);
    try jw.write(usage.cache_read);
    try jw.objectField(Field.cache_write);
    try jw.write(usage.cache_write);
    try jw.objectField(Field.total_tokens);
    try jw.write(usage.total_tokens);
    try jw.objectField(Field.cost);
    try jw.beginObject();
    try jw.objectField(Field.input);
    try jw.print("{d}", .{usage.cost.input});
    try jw.objectField(Field.output);
    try jw.print("{d}", .{usage.cost.output});
    try jw.objectField(Field.cache_read);
    try jw.print("{d}", .{usage.cost.cache_read});
    try jw.objectField(Field.cache_write);
    try jw.print("{d}", .{usage.cost.cache_write});
    try jw.objectField(Field.total);
    try jw.print("{d}", .{usage.cost.total});
    try jw.endObject();
    try jw.endObject();
}

pub fn parseFileEntry(allocator: std.mem.Allocator, line: []const u8) !proto.FileEntry {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const obj = try expectObject(parsed.value);

    const type_str = try requiredString(obj, Field.kind_type);
    if (std.mem.eql(u8, type_str, Tag.session)) {
        return .{ .header = try parseHeader(allocator, obj) };
    }
    return .{ .entry = try parseEntry(allocator, obj, type_str) };
}

fn parseHeader(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !proto.SessionHeader {
    return .{
        .id = try allocator.dupe(u8, try requiredString(obj, Field.id)),
        .timestamp = try allocator.dupe(u8, try requiredString(obj, Field.timestamp)),
        .cwd = try allocator.dupe(u8, try requiredString(obj, Field.cwd)),
        .version = if (obj.get(Field.version)) |v| try expectU32(v) else 1,
        .parent_session = if (try optionalString(obj, Field.parent_session)) |v| try allocator.dupe(u8, v) else null,
    };
}

fn parseEntry(allocator: std.mem.Allocator, obj: std.json.ObjectMap, type_str: []const u8) !proto.SessionEntry {
    const id = try allocator.dupe(u8, try requiredString(obj, Field.id));
    errdefer allocator.free(id);
    const parent_id = if (try optionalString(obj, Field.parent_id)) |v| try allocator.dupe(u8, v) else null;
    errdefer if (parent_id) |value| allocator.free(value);
    const timestamp = try allocator.dupe(u8, try requiredString(obj, Field.timestamp));
    errdefer allocator.free(timestamp);

    const entry: proto.SessionEntry.EntryType = if (std.mem.eql(u8, type_str, Tag.message))
        .{ .message = .{ .message = try parseAgentMessage(allocator, try requiredValue(obj, Field.message)) } }
    else if (std.mem.eql(u8, type_str, Tag.thinking_level_change))
        .{ .thinking_level_change = .{
            .thinking_level = try allocator.dupe(u8, try requiredString(obj, Field.thinking_level)),
        } }
    else if (std.mem.eql(u8, type_str, Tag.model_change))
        .{ .model_change = .{
            .provider = try allocator.dupe(u8, try requiredString(obj, Field.provider)),
            .model_id = try allocator.dupe(u8, try requiredString(obj, Field.model_id)),
        } }
    else if (std.mem.eql(u8, type_str, Tag.compaction))
        .{ .compaction = .{
            .summary = try allocator.dupe(u8, try requiredString(obj, Field.summary)),
            .first_kept_entry_id = try allocator.dupe(u8, try requiredString(obj, Field.first_kept_entry_id)),
            .tokens_before = try requiredU64(obj, Field.tokens_before),
            .details = if (obj.get(Field.details)) |d| try json_value.OwnedValue.clone(allocator, d) else null,
            .from_hook = try optionalBool(obj, Field.from_hook),
        } }
    else if (std.mem.eql(u8, type_str, Tag.branch_summary_entry))
        .{ .branch_summary = .{
            .from_id = try allocator.dupe(u8, try requiredString(obj, Field.from_id)),
            .summary = try allocator.dupe(u8, try requiredString(obj, Field.summary)),
            .details = if (obj.get(Field.details)) |d| try json_value.OwnedValue.clone(allocator, d) else null,
            .from_hook = try optionalBool(obj, Field.from_hook),
        } }
    else if (std.mem.eql(u8, type_str, Tag.custom))
        .{ .custom = .{
            .custom_type = try allocator.dupe(u8, try requiredString(obj, Field.custom_type)),
            .data = if (obj.get(Field.data)) |d| try json_value.OwnedValue.clone(allocator, d) else null,
        } }
    else if (std.mem.eql(u8, type_str, Tag.custom_message))
        .{ .custom_message = .{
            .custom_type = try allocator.dupe(u8, try requiredString(obj, Field.custom_type)),
            .content = try parseCustomContent(allocator, try requiredValue(obj, Field.content)),
            .details = if (obj.get(Field.details)) |d| try json_value.OwnedValue.clone(allocator, d) else null,
            .display = try requiredBool(obj, Field.display),
            .include_in_context = (try optionalBool(obj, Field.include_in_context)) orelse true,
        } }
    else if (std.mem.eql(u8, type_str, Tag.label))
        .{ .label = .{
            .target_id = try allocator.dupe(u8, try requiredString(obj, Field.target_id)),
            .label = if (try optionalString(obj, Field.label)) |v| try allocator.dupe(u8, v) else null,
        } }
    else if (std.mem.eql(u8, type_str, Tag.session_info))
        .{ .session_info = .{
            .name = if (try optionalString(obj, Field.name)) |v| try allocator.dupe(u8, v) else null,
        } }
    else
        return error.UnknownEntryType;

    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = timestamp,
        .entry = entry,
    };
}

fn parseAgentMessage(allocator: std.mem.Allocator, value: std.json.Value) !agent.protocol.AgentMessage {
    const obj = try expectObject(value);
    const role = try requiredString(obj, Field.role);

    if (std.mem.eql(u8, role, Tag.user)) {
        return .{ .user = try parseUserMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, Tag.assistant)) {
        return .{ .assistant = try parseAssistantMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, Tag.tool_result)) {
        return .{ .tool_result = try parseToolResultMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, Tag.compaction_summary)) {
        return .{ .compaction_summary = .{
            .summary = try allocator.dupe(u8, try requiredString(obj, Field.summary)),
            .tokens_before = try requiredU64(obj, Field.tokens_before),
            .timestamp = try requiredI64(obj, Field.timestamp),
        } };
    } else if (std.mem.eql(u8, role, Tag.branch_summary)) {
        return .{ .branch_summary = .{
            .summary = try allocator.dupe(u8, try requiredString(obj, Field.summary)),
            .from_id = try allocator.dupe(u8, try requiredString(obj, Field.from_id)),
            .timestamp = try requiredI64(obj, Field.timestamp),
        } };
    } else if (std.mem.eql(u8, role, Tag.custom)) {
        return .{ .custom = try parseCustomAgentMessage(allocator, obj) };
    }
    return error.UnknownMessageRole;
}

fn requiredValue(obj: std.json.ObjectMap, field: []const u8) !std.json.Value {
    return obj.get(field) orelse error.MissingField;
}

fn requiredString(obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    return try expectString(try requiredValue(obj, field));
}

fn optionalString(obj: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn requiredInteger(obj: std.json.ObjectMap, field: []const u8) !i64 {
    return try expectInteger(try requiredValue(obj, field));
}

fn requiredI64(obj: std.json.ObjectMap, field: []const u8) !i64 {
    return try requiredInteger(obj, field);
}

fn requiredU64(obj: std.json.ObjectMap, field: []const u8) !u64 {
    const value = try requiredInteger(obj, field);
    if (value < 0) return error.InvalidFieldValue;
    return @intCast(value);
}

fn expectU32(value: std.json.Value) !u32 {
    const integer = try expectInteger(value);
    if (integer < 0) return error.InvalidFieldValue;
    return @intCast(integer);
}

fn optionalInteger(obj: std.json.ObjectMap, field: []const u8) !?i64 {
    const value = obj.get(field) orelse return null;
    if (value == .null) return null;
    return try expectInteger(value);
}

fn requiredBool(obj: std.json.ObjectMap, field: []const u8) !bool {
    return try expectBool(try requiredValue(obj, field));
}

fn optionalBool(obj: std.json.ObjectMap, field: []const u8) !?bool {
    const value = obj.get(field) orelse return null;
    return switch (value) {
        .null => null,
        .bool => |b| b,
        else => error.InvalidFieldType,
    };
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |obj| obj,
        else => error.InvalidFieldType,
    };
}

fn requiredObject(obj: std.json.ObjectMap, field: []const u8) !std.json.ObjectMap {
    return try expectObject(try requiredValue(obj, field));
}

fn expectArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.InvalidFieldType,
    };
}

fn requiredArray(obj: std.json.ObjectMap, field: []const u8) !std.json.Array {
    return try expectArray(try requiredValue(obj, field));
}

fn optionalOwnedString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) !?[]const u8 {
    return if (try optionalString(obj, field)) |value| try allocator.dupe(u8, value) else null;
}

fn requiredOwnedString(allocator: std.mem.Allocator, obj: std.json.ObjectMap, field: []const u8) ![]const u8 {
    return try allocator.dupe(u8, try requiredString(obj, field));
}

fn expectString(value: std.json.Value) ![]const u8 {
    return switch (value) {
        .string => |s| s,
        else => error.InvalidFieldType,
    };
}

fn expectInteger(value: std.json.Value) !i64 {
    return switch (value) {
        .integer => |i| i,
        else => error.InvalidFieldType,
    };
}

fn expectBool(value: std.json.Value) !bool {
    return switch (value) {
        .bool => |b| b,
        else => error.InvalidFieldType,
    };
}

fn parseUserMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.UserMessage {
    const content_val = try requiredValue(obj, Field.content);
    const content: ai.protocol.UserMessage.UserMessageContent = switch (content_val) {
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, arr.items.len);
            for (arr.items, 0..) |item, i| {
                blocks[i] = try parseUserContentBlock(allocator, try expectObject(item));
            }
            break :blk .{ .blocks = blocks };
        },
        else => return error.InvalidUserContent,
    };
    return .{
        .content = content,
        .timestamp = try requiredI64(obj, Field.timestamp),
    };
}

fn parseUserContentBlock(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.UserMessage.UserMessageContent.Block {
    const type_str = try requiredString(obj, Field.kind_type);
    if (std.mem.eql(u8, type_str, Tag.text)) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, try requiredString(obj, Field.text)),
            .text_signature = try optionalOwnedString(allocator, obj, Field.text_signature),
        } };
    } else if (std.mem.eql(u8, type_str, Tag.image)) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, try requiredString(obj, Field.data)),
            .mime_type = try allocator.dupe(u8, try requiredString(obj, Field.mime_type)),
        } };
    }
    return error.UnknownContentBlockType;
}

fn parseAssistantMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.AssistantMessage {
    const content_arr = try requiredArray(obj, Field.content);
    var blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, content_arr.items.len);
    for (content_arr.items, 0..) |item, i| {
        blocks[i] = try parseAssistantContentBlock(allocator, try expectObject(item));
    }

    const usage_obj = try requiredObject(obj, Field.usage);
    const cost_obj = try requiredObject(usage_obj, Field.cost);

    return .{
        .content = blocks,
        .api = ai.protocol.parseApi(try requiredString(obj, Field.api)),
        .provider = ai.protocol.parseProvider(try requiredString(obj, Field.provider)),
        .model = try allocator.dupe(u8, try requiredString(obj, Field.model)),
        .response_id = try optionalOwnedString(allocator, obj, Field.response_id),
        .usage = .{
            .input = try requiredU64(usage_obj, Field.input),
            .output = try requiredU64(usage_obj, Field.output),
            .cache_read = try requiredU64(usage_obj, Field.cache_read),
            .cache_write = try requiredU64(usage_obj, Field.cache_write),
            .total_tokens = try requiredU64(usage_obj, Field.total_tokens),
            .cost = .{
                .input = try json_value.expectNumber(try requiredValue(cost_obj, Field.input)),
                .output = try json_value.expectNumber(try requiredValue(cost_obj, Field.output)),
                .cache_read = try json_value.expectNumber(try requiredValue(cost_obj, Field.cache_read)),
                .cache_write = try json_value.expectNumber(try requiredValue(cost_obj, Field.cache_write)),
                .total = try json_value.expectNumber(try requiredValue(cost_obj, Field.total)),
            },
        },
        .stop_reason = ai.protocol.parseStopReason(try requiredString(obj, Field.stop_reason)),
        .error_message = try optionalOwnedString(allocator, obj, Field.error_message),
        .failure = if (obj.get(Field.failure)) |v| try parseNormalizedFailure(allocator, try expectObject(v)) else null,
        .timestamp = try requiredI64(obj, Field.timestamp),
    };
}

fn writeNormalizedFailure(jw: *Stringify, failure: ai.protocol.NormalizedFailure) !void {
    try jw.beginObject();
    try jw.objectField(Field.kind);
    try jw.write(@tagName(failure.kind));
    if (failure.http_status) |status| {
        try jw.objectField(Field.http_status);
        try jw.write(status);
    }
    if (failure.provider_code) |code| {
        try jw.objectField(Field.provider_code);
        try jw.write(code);
    }
    if (failure.provider_type) |provider_type| {
        try jw.objectField(Field.provider_type);
        try jw.write(provider_type);
    }
    if (failure.retry_after_ms) |retry_after_ms| {
        try jw.objectField(Field.retry_after_ms);
        try jw.write(retry_after_ms);
    }
    try jw.endObject();
}

fn parseNormalizedFailure(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.NormalizedFailure {
    const kind_str = try requiredString(obj, Field.kind);
    const kind: ai.protocol.NormalizedFailure.Kind = if (std.mem.eql(u8, kind_str, "aborted"))
        .aborted
    else if (std.mem.eql(u8, kind_str, "context_overflow"))
        .context_overflow
    else if (std.mem.eql(u8, kind_str, "rate_limited"))
        .rate_limited
    else if (std.mem.eql(u8, kind_str, "transient"))
        .transient
    else if (std.mem.eql(u8, kind_str, "auth"))
        .auth
    else if (std.mem.eql(u8, kind_str, "invalid_request"))
        .invalid_request
    else
        return error.UnknownFailureKind;

    return .{
        .kind = kind,
        .http_status = if (try optionalInteger(obj, Field.http_status)) |v| blk: {
            if (v < 0) return error.InvalidFieldValue;
            break :blk @as(u16, @intCast(v));
        } else null,
        .provider_code = try optionalOwnedString(allocator, obj, Field.provider_code),
        .provider_type = try optionalOwnedString(allocator, obj, Field.provider_type),
        .retry_after_ms = if (try optionalInteger(obj, Field.retry_after_ms)) |v| blk: {
            if (v < 0) return error.InvalidFieldValue;
            break :blk @as(u64, @intCast(v));
        } else null,
    };
}

fn parseAssistantContentBlock(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.AssistantMessage.AssistantContentBlock {
    const type_str = try requiredString(obj, Field.kind_type);
    if (std.mem.eql(u8, type_str, Tag.text)) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, try requiredString(obj, Field.text)),
            .text_signature = try optionalOwnedString(allocator, obj, Field.text_signature),
        } };
    } else if (std.mem.eql(u8, type_str, Tag.thinking)) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, try requiredString(obj, Field.thinking)),
            .thinking_signature = try optionalOwnedString(allocator, obj, Field.thinking_signature),
            .redacted = if (obj.get(Field.redacted)) |v| try expectBool(v) else null,
        } };
    } else if (std.mem.eql(u8, type_str, Tag.tool_call)) {
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, try requiredString(obj, Field.id)),
            .name = try allocator.dupe(u8, try requiredString(obj, Field.name)),
            .arguments = try json_value.OwnedValue.clone(allocator, try requiredValue(obj, Field.arguments)),
            .thought_signature = try optionalOwnedString(allocator, obj, Field.thought_signature),
        } };
    }
    return error.UnknownContentBlockType;
}

fn parseToolResultMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.ToolResultMessage {
    const content_arr = try requiredArray(obj, Field.content);
    var blocks = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, content_arr.items.len);
    for (content_arr.items, 0..) |item, i| {
        const block_obj = try expectObject(item);
        const type_str = try requiredString(block_obj, Field.kind_type);
        if (std.mem.eql(u8, type_str, Tag.text)) {
            blocks[i] = .{ .text = .{
                .text = try allocator.dupe(u8, try requiredString(block_obj, Field.text)),
                .text_signature = try optionalOwnedString(allocator, block_obj, Field.text_signature),
            } };
        } else if (std.mem.eql(u8, type_str, Tag.image)) {
            blocks[i] = .{ .image = .{
                .data = try allocator.dupe(u8, try requiredString(block_obj, Field.data)),
                .mime_type = try allocator.dupe(u8, try requiredString(block_obj, Field.mime_type)),
            } };
        } else {
            return error.UnknownContentBlockType;
        }
    }
    return .{
        .tool_call_id = try allocator.dupe(u8, try requiredString(obj, Field.tool_call_id)),
        .tool_name = try allocator.dupe(u8, try requiredString(obj, Field.tool_name)),
        .content = blocks,
        .details = if (obj.get(Field.details)) |d| try json_value.cloneJsonValue(allocator, d) else null,
        .presentation = if (obj.get(Field.presentation)) |p| try json_value.cloneJsonValue(allocator, p) else null,
        .is_error = try requiredBool(obj, Field.is_error),
        .timestamp = try requiredI64(obj, Field.timestamp),
    };
}

fn parseCustomAgentMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !agent.protocol.AgentMessage.CustomMessage {
    return .{
        .custom_type = try allocator.dupe(u8, try requiredString(obj, Field.custom_type)),
        .content = try parseCustomContent(allocator, try requiredValue(obj, Field.content)),
        .display = if (obj.get(Field.display)) |v| try expectBool(v) else false,
        .details = if (obj.get(Field.details)) |d| try json_value.cloneJsonValue(allocator, d) else null,
        .timestamp = try requiredI64(obj, Field.timestamp),
    };
}

fn parseCustomContent(allocator: std.mem.Allocator, val: std.json.Value) !agent.protocol.AgentMessage.CustomContent {
    return switch (val) {
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, arr.items.len);
            for (arr.items, 0..) |item, i| {
                blocks[i] = try parseUserContentBlock(allocator, try expectObject(item));
            }
            break :blk .{ .blocks = blocks };
        },
        else => error.InvalidCustomContent,
    };
}

fn testArena() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(std.testing.allocator);
}

fn expectJsonContains(json: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, json, needle) != null);
}

fn expectJsonOmits(json: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, json, needle) == null);
}

fn messageEntry(id: []const u8, parent_id: ?[]const u8, message: agent.protocol.AgentMessage) proto.SessionEntry {
    return .{
        .id = id,
        .parent_id = parent_id,
        .timestamp = "2025-01-01T00:00:00.000Z",
        .entry = .{ .message = .{ .message = message } },
    };
}

fn userTextFromMessage(message: agent.protocol.AgentMessage) ![]const u8 {
    return switch (message) {
        .user => |user| switch (user.content) {
            .text => |text| text,
            .blocks => |blocks| blk: {
                try std.testing.expect(blocks.len > 0);
                break :blk switch (blocks[0]) {
                    .text => |text| text.text,
                    else => error.ExpectedTextBlock,
                };
            },
        },
        else => error.ExpectedUserMessage,
    };
}

fn expectUserText(message: agent.protocol.AgentMessage, expected: []const u8) !void {
    try std.testing.expectEqualStrings(expected, try userTextFromMessage(message));
}

fn expectToolCall(message: agent.protocol.AgentMessage, expected_id: []const u8, expected_name: []const u8) !void {
    switch (message) {
        .assistant => |assistant| {
            try std.testing.expectEqual(@as(usize, 1), assistant.content.len);
            switch (assistant.content[0]) {
                .tool_call => |tool_call| {
                    try std.testing.expectEqualStrings(expected_id, tool_call.id);
                    try std.testing.expectEqualStrings(expected_name, tool_call.name);
                },
                else => return error.ExpectedToolCallBlock,
            }
        },
        else => return error.ExpectedAssistantMessage,
    }
}

fn expectToolResultText(message: agent.protocol.AgentMessage, expected_call_id: []const u8, expected_tool_name: []const u8, expected_text: []const u8) !void {
    switch (message) {
        .tool_result => |tool_result| {
            try std.testing.expectEqualStrings(expected_call_id, tool_result.tool_call_id);
            try std.testing.expectEqualStrings(expected_tool_name, tool_result.tool_name);
            try std.testing.expect(!tool_result.is_error);
            try std.testing.expectEqual(@as(usize, 1), tool_result.content.len);
            switch (tool_result.content[0]) {
                .text => |text| try std.testing.expectEqualStrings(expected_text, text.text),
                else => return error.ExpectedTextBlock,
            }
        },
        else => return error.ExpectedToolResultMessage,
    }
}

fn assistantFailureEntry() proto.SessionEntry {
    return messageEntry("ad000001", null, .{ .assistant = .{
        .content = &.{},
        .api = .openai_responses,
        .provider = .openai,
        .model = "gpt-test",
        .usage = .{
            .input = 0,
            .output = 0,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 0,
            .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 },
        },
        .stop_reason = .@"error",
        .error_message = "HTTP 429 Too Many Requests: rate limit exceeded",
        .failure = .{
            .kind = .rate_limited,
            .http_status = 429,
            .provider_code = "rate_limit_exceeded",
            .provider_type = "invalid_request_error",
        },
        .timestamp = 1,
    } });
}

test "header wire format round-trips parent session and version" {
    const allocator = std.testing.allocator;
    const header = proto.SessionHeader{
        .id = "child-uuid",
        .timestamp = "2025-01-01T00:00:00.000Z",
        .cwd = "/tmp",
        .version = 3,
        .parent_session = "parent-uuid",
    };
    const json_str = try headerToOwnedLine(allocator, header);
    defer allocator.free(json_str);

    try expectJsonContains(json_str, "\"type\":\"session\"");
    try expectJsonContains(json_str, "\"parentSession\":\"parent-uuid\"");

    const parsed = try parseFileEntry(allocator, json_str);
    const h = parsed.header;
    defer {
        allocator.free(h.id);
        allocator.free(h.timestamp);
        allocator.free(h.cwd);
        if (h.parent_session) |ps| allocator.free(ps);
    }
    try std.testing.expectEqualStrings("child-uuid", h.id);
    try std.testing.expectEqualStrings("2025-01-01T00:00:00.000Z", h.timestamp);
    try std.testing.expectEqualStrings("/tmp", h.cwd);
    try std.testing.expectEqual(@as(u32, 3), h.version);
    try std.testing.expectEqualStrings("parent-uuid", h.parent_session.?);
}

test "parser rejects missing or non-string file entry type" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingField, parseFileEntry(allocator,
        \\{"id":"s","timestamp":"2025-01-01T00:00:00.000Z","cwd":"/tmp"}
    ));
    try std.testing.expectError(error.InvalidFieldType, parseFileEntry(allocator,
        \\{"type":1,"id":"s","timestamp":"2025-01-01T00:00:00.000Z","cwd":"/tmp"}
    ));
}

test "parser rejects session header with missing id" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingField, parseFileEntry(allocator,
        \\{"type":"session","timestamp":"2025-01-01T00:00:00.000Z","cwd":"/tmp"}
    ));
}

test "parser rejects message with missing or non-string role" {
    const allocator = std.testing.allocator;

    try std.testing.expectError(error.MissingField, parseFileEntry(allocator,
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:00.000Z","message":{"content":"hi","timestamp":1}}
    ));
    try std.testing.expectError(error.InvalidFieldType, parseFileEntry(allocator,
        \\{"type":"message","id":"1","parentId":null,"timestamp":"2025-01-01T00:00:00.000Z","message":{"role":1,"content":"hi","timestamp":1}}
    ));
}

test "assistant message round-trips normalized failure metadata" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();

    const json_str = try entryToOwnedLine(allocator, assistantFailureEntry());
    const parsed = try parseFileEntry(allocator, json_str);
    switch (parsed.entry.entry) {
        .message => |m| switch (m.message) {
            .assistant => |assistant| {
                try std.testing.expectEqual(ai.protocol.NormalizedFailure.Kind.rate_limited, assistant.failure.?.kind);
                try std.testing.expectEqual(@as(?u16, 429), assistant.failure.?.http_status);
                try std.testing.expectEqualStrings("rate_limit_exceeded", assistant.failure.?.provider_code.?);
            },
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
}

test "tool result entry round-trips long identifiers and multiline text" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();

    const long_tool_call_id = try std.fmt.allocPrint(allocator, "call_{s}|fc_{s}", .{
        "0123456789abcdef0123456789abcdef0123456789abcdef",
        "fedcba9876543210fedcba9876543210fedcba9876543210",
    });
    const long_tool_name = try std.fmt.allocPrint(allocator, "tool-{s}", .{"abcdefghijklmnopqrstuvwxyz0123456789"});
    const long_text = try std.fmt.allocPrint(allocator, "{s}\n{s}\n{s}", .{
        "first line with enough text to force JSON writer growth",
        "second line with enough text to force JSON writer growth again",
        "third line with enough text to keep realloc pressure on the scratch buffer",
    });

    var tool_content = [_]ai.protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = long_text } },
    };
    const entry = proto.SessionEntry{
        .id = "arena000",
        .parent_id = null,
        .timestamp = "2025-01-01T00:00:00.000Z",
        .entry = .{ .message = .{ .message = .{ .tool_result = .{
            .tool_call_id = long_tool_call_id,
            .tool_name = long_tool_name,
            .content = &tool_content,
            .is_error = false,
            .timestamp = 1700000002000,
        } } } },
    };

    const line = try entryToOwnedLine(allocator, entry);
    const parsed = try parseFileEntry(allocator, line);
    const tool_result = parsed.entry.entry.message.message.tool_result;

    try std.testing.expectEqualStrings(long_tool_call_id, tool_result.tool_call_id);
    try std.testing.expectEqualStrings(long_tool_name, tool_result.tool_name);
    try std.testing.expectEqualStrings(long_text, tool_result.content[0].text.text);
}

test "tool-result text serializes invalid utf-8 as a json string" {
    const allocator = std.testing.allocator;
    var tool_content = [_]ai.protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "bad\xaa\xfftail" } },
    };
    const entry = proto.SessionEntry{
        .id = "utf80001",
        .parent_id = null,
        .timestamp = "2025-01-01T00:00:00.000Z",
        .entry = .{ .message = .{ .message = .{ .tool_result = .{
            .tool_call_id = "toolu_bad",
            .tool_name = "bash",
            .content = &tool_content,
            .is_error = false,
            .timestamp = 1700000002000,
        } } } },
    };

    const line = try entryToOwnedLine(allocator, entry);
    defer allocator.free(line);

    try expectJsonContains(line, "\"text\":\"bad");
    try expectJsonContains(line, "tail\"");
    try expectJsonOmits(line, "\"text\":[");
}

test "compaction entries preserve metadata and project into context" {
    var arena = testArena();
    defer arena.deinit();
    const allocator = arena.allocator();
    const context = @import("context.zig");

    const lines = [_][]const u8{
        \\{"type":"message","id":"u1","parentId":null,"timestamp":"2025-01-01T00:00:00.000Z","message":{"role":"user","content":[{"type":"text","text":"summarized user"}],"timestamp":1700000000000}}
        ,
        \\{"type":"message","id":"a1","parentId":"u1","timestamp":"2025-01-01T00:00:01.000Z","message":{"role":"assistant","content":[{"type":"text","text":"summarized assistant"}],"api":"anthropic-messages","provider":"anthropic","model":"claude-sonnet-4-5","usage":{"input":4000,"output":1000,"cacheRead":0,"cacheWrite":0,"totalTokens":5000,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0,"total":0}},"stopReason":"stop","timestamp":1700000001000}}
        ,
        \\{"type":"message","id":"u2","parentId":"a1","timestamp":"2025-01-01T00:00:02.000Z","message":{"role":"user","content":[{"type":"text","text":"kept user"}],"timestamp":1700000002000}}
        ,
        \\{"type":"compaction","id":"c1","parentId":"u2","timestamp":"2025-01-01T00:00:03.000Z","summary":"extension summary","firstKeptEntryId":"u2","tokensBefore":5000,"details":{"provider":"custom-compactor","turns":1},"fromHook":true}
        ,
        \\{"type":"message","id":"u3","parentId":"c1","timestamp":"2025-01-01T00:00:04.000Z","message":{"role":"user","content":[{"type":"text","text":"after compaction"}],"timestamp":1700000004000}}
        ,
    };

    var entries: [lines.len]proto.SessionEntry = undefined;
    for (lines, 0..) |line, index| {
        entries[index] = (try parseFileEntry(allocator, line)).entry;
    }

    const compaction = entries[3].entry.compaction;
    try std.testing.expectEqualStrings("extension summary", compaction.summary);
    try std.testing.expectEqualStrings("u2", compaction.first_kept_entry_id);
    try std.testing.expectEqual(@as(u64, 5000), compaction.tokens_before);
    try std.testing.expectEqual(true, compaction.from_hook.?);
    try std.testing.expectEqualStrings("custom-compactor", compaction.details.?.object.get("provider").?.string);

    const serialized = try entryToOwnedLine(std.testing.allocator, entries[3]);
    defer std.testing.allocator.free(serialized);
    try expectJsonContains(serialized, "\"fromHook\":true");
    try expectJsonContains(serialized, "\"provider\":\"custom-compactor\"");

    var ctx = try context.buildSessionContext(allocator, &entries, .current);
    defer ctx.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 3), ctx.messages.len);
    switch (ctx.messages[0]) {
        .compaction_summary => |summary| {
            try std.testing.expectEqualStrings("extension summary", summary.summary);
            try std.testing.expectEqual(@as(u64, 5000), summary.tokens_before);
        },
        else => return error.ExpectedCompactionSummary,
    }
    try expectUserText(ctx.messages[1], "kept user");
    try expectUserText(ctx.messages[2], "after compaction");
}

test "session message entries round-trip through JSON and rebuild context" {
    const allocator = std.testing.allocator;
    const context = @import("context.zig");

    const user_msg = agent.protocol.AgentMessage{ .user = .{
        .content = .{ .text = "what files are here?" },
        .timestamp = 1700000000000,
    } };

    const tool_call = ai.protocol.ToolCall{
        .id = "toolu_abc123",
        .name = "bash",
        .arguments = json_value.OwnedValue.nullValue(),
    };
    var assistant_blocks = [_]ai.protocol.AssistantMessage.AssistantContentBlock{
        .{ .tool_call = tool_call },
    };
    const assistant_msg = agent.protocol.AgentMessage{ .assistant = .{
        .content = &assistant_blocks,
        .api = .anthropic_messages,
        .provider = .anthropic,
        .model = "claude-sonnet-4-5",
        .usage = .{
            .input = 100,
            .output = 50,
            .cache_read = 0,
            .cache_write = 0,
            .total_tokens = 150,
            .cost = .{ .input = 0.001, .output = 0.002, .cache_read = 0, .cache_write = 0, .total = 0.003 },
        },
        .stop_reason = .toolUse,
        .timestamp = 1700000001000,
    } };

    var tool_content = [_]ai.protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "file1.txt\nfile2.txt" } },
    };
    const tool_result_msg = agent.protocol.AgentMessage{ .tool_result = .{
        .tool_call_id = "toolu_abc123",
        .tool_name = "bash",
        .content = &tool_content,
        .is_error = false,
        .timestamp = 1700000002000,
    } };

    const entries_data = [_]struct { msg: agent.protocol.AgentMessage, id: []const u8, parent: ?[]const u8 }{
        .{ .msg = user_msg, .id = "aaaa0001", .parent = null },
        .{ .msg = assistant_msg, .id = "aaaa0002", .parent = "aaaa0001" },
        .{ .msg = tool_result_msg, .id = "aaaa0003", .parent = "aaaa0002" },
    };

    var json_lines: [3][]const u8 = undefined;
    for (entries_data, 0..) |ed, i| {
        json_lines[i] = try entryToOwnedLine(allocator, messageEntry(ed.id, ed.parent, ed.msg));
    }
    defer for (&json_lines) |jl| allocator.free(jl);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var parsed_entries: [3]proto.SessionEntry = undefined;
    for (json_lines, 0..) |line, i| {
        const fe = try parseFileEntry(aa, line);
        parsed_entries[i] = fe.entry;
    }

    var ctx = try context.buildSessionContext(aa, &parsed_entries, .current);
    defer ctx.deinit(aa);

    try std.testing.expectEqual(@as(usize, 3), ctx.messages.len);

    try expectUserText(ctx.messages[0], "what files are here?");
    switch (ctx.messages[1]) {
        .assistant => |assistant| {
            try std.testing.expectEqualStrings("claude-sonnet-4-5", assistant.model);
            try std.testing.expectEqual(ai.protocol.StopReason.toolUse, assistant.stop_reason);
        },
        else => return error.ExpectedAssistantMessage,
    }
    try expectToolCall(ctx.messages[1], "toolu_abc123", "bash");
    try expectToolResultText(ctx.messages[2], "toolu_abc123", "bash", "file1.txt\nfile2.txt");
}
