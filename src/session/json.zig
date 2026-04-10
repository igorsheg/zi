const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const proto = @import("protocol.zig");
const json_util = ai.json_util;
const json_write = @import("../json/write.zig");

const Stringify = std.json.Stringify;

// ─── Serialization ──────────────────────────────────────────────────

pub fn writeHeader(writer: *std.io.Writer, header: proto.SessionHeader) !void {
    var jw: Stringify = .{ .writer = writer };

    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("session");
    try jw.objectField("version");
    try jw.write(header.version);
    try jw.objectField("id");
    try jw.write(header.id);
    try jw.objectField("timestamp");
    try jw.write(header.timestamp);
    try jw.objectField("cwd");
    try jw.write(header.cwd);
    if (header.parent_session) |ps| {
        try jw.objectField("parentSession");
        try jw.write(ps);
    }
    try jw.endObject();
}

pub fn writeEntry(writer: *std.io.Writer, entry: proto.SessionEntry) !void {
    var jw: Stringify = .{ .writer = writer };

    try jw.beginObject();

    try jw.objectField("type");
    try jw.write(switch (entry.entry) {
        .message => "message",
        .thinking_level_change => "thinking_level_change",
        .model_change => "model_change",
        .compaction => "compaction",
        .branch_summary => "branch_summary",
        .custom => "custom",
        .custom_message => "custom_message",
        .label => "label",
        .session_info => "session_info",
    });

    try jw.objectField("id");
    try jw.write(entry.id);
    try jw.objectField("parentId");
    if (entry.parent_id) |pid| {
        try jw.write(pid);
    } else {
        try jw.write(null);
    }
    try jw.objectField("timestamp");
    try jw.write(entry.timestamp);

    switch (entry.entry) {
        .message => |m| {
            try jw.objectField("message");
            try writeAgentMessage(&jw, m.message);
        },
        .thinking_level_change => |t| {
            try jw.objectField("thinkingLevel");
            try jw.write(t.thinking_level);
        },
        .model_change => |m| {
            try jw.objectField("provider");
            try jw.write(m.provider);
            try jw.objectField("modelId");
            try jw.write(m.model_id);
        },
        .compaction => |c| {
            try jw.objectField("summary");
            try jw.write(c.summary);
            try jw.objectField("firstKeptEntryId");
            try jw.write(c.first_kept_entry_id);
            try jw.objectField("tokensBefore");
            try jw.write(c.tokens_before);
            if (c.details) |d| {
                try jw.objectField("details");
                try jw.write(d);
            }
            if (c.from_hook) |fh| {
                try jw.objectField("fromHook");
                try jw.write(fh);
            }
        },
        .branch_summary => |bs| {
            try jw.objectField("fromId");
            try jw.write(bs.from_id);
            try jw.objectField("summary");
            try jw.write(bs.summary);
            if (bs.details) |d| {
                try jw.objectField("details");
                try jw.write(d);
            }
            if (bs.from_hook) |fh| {
                try jw.objectField("fromHook");
                try jw.write(fh);
            }
        },
        .custom => |c| {
            try jw.objectField("customType");
            try jw.write(c.custom_type);
            if (c.data) |d| {
                try jw.objectField("data");
                try jw.write(d);
            }
        },
        .custom_message => |cm| {
            try jw.objectField("customType");
            try jw.write(cm.custom_type);
            try jw.objectField("content");
            try writeCustomContent(&jw, cm.content);
            if (cm.details) |d| {
                try jw.objectField("details");
                try jw.write(d);
            }
            try jw.objectField("display");
            try jw.write(cm.display);
        },
        .label => |l| {
            try jw.objectField("targetId");
            try jw.write(l.target_id);
            if (l.label) |lbl| {
                try jw.objectField("label");
                try jw.write(lbl);
            }
        },
        .session_info => |si| {
            if (si.name) |n| {
                try jw.objectField("name");
                try jw.write(n);
            }
        },
    }

    try jw.endObject();
}

// ─── Message writers ────────────────────────────────────────────────

pub fn writeAgentMessage(jw: *Stringify, msg: agent.protocol.AgentMessage) !void {
    switch (msg) {
        .user => |u| try writeUserMessage(jw, u),
        .assistant => |a| try writeAssistantMessage(jw, a),
        .tool_result => |tr| try writeToolResultMessage(jw, tr),
        .compaction_summary => |cs| try writeCompactionSummaryMessage(jw, cs),
        .branch_summary => |bs| try writeBranchSummaryMessage(jw, bs),
        .custom => |c| try writeCustomMessage(jw, c),
    }
}

pub fn writeUserMessage(jw: *Stringify, msg: ai.protocol.UserMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    switch (msg.content) {
        .text => |t| {
            try jw.write(t);
        },
        .blocks => |blocks| {
            try jw.beginArray();
            for (blocks) |block| {
                switch (block) {
                    .text => |tc| try writeTextBlock(jw, tc),
                    .image => |ic| try writeImageBlock(jw, ic),
                }
            }
            try jw.endArray();
        },
    }
    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeAssistantMessage(jw: *Stringify, msg: ai.protocol.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");

    try jw.objectField("content");
    try jw.beginArray();
    for (msg.content) |block| {
        switch (block) {
            .text => |tc| try writeTextBlock(jw, tc),
            .thinking => |th| try writeThinkingBlock(jw, th),
            .tool_call => |tc| try writeToolCallBlock(jw, tc),
        }
    }
    try jw.endArray();

    try jw.objectField("api");
    try jw.write(ai.provider.apiToString(msg.api));
    try jw.objectField("provider");
    try jw.write(json_util.providerToString(msg.provider));
    try jw.objectField("model");
    try jw.write(msg.model);

    if (msg.response_id) |rid| {
        try jw.objectField("responseId");
        try jw.write(rid);
    }

    try jw.objectField("usage");
    try writeUsage(jw, msg.usage);

    try jw.objectField("stopReason");
    try jw.write(json_util.stopReasonToString(msg.stop_reason));

    if (msg.error_message) |em| {
        try jw.objectField("errorMessage");
        try jw.write(em);
    }
    if (msg.failure) |failure| {
        try jw.objectField("failure");
        try writeNormalizedFailure(jw, failure);
    }

    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeToolResultMessage(jw: *Stringify, msg: ai.protocol.ToolResultMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("toolResult");
    try jw.objectField("toolCallId");
    try jw.write(msg.tool_call_id);
    try jw.objectField("toolName");
    try jw.write(msg.tool_name);

    try jw.objectField("content");
    try jw.beginArray();
    for (msg.content) |block| {
        switch (block) {
            .text => |tc| try writeTextBlock(jw, tc),
            .image => |ic| try writeImageBlock(jw, ic),
        }
    }
    try jw.endArray();

    if (msg.details) |d| {
        try jw.objectField("details");
        try jw.write(d);
    }
    try jw.objectField("isError");
    try jw.write(msg.is_error);
    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCompactionSummaryMessage(jw: *Stringify, msg: agent.protocol.AgentMessage.CompactionSummaryMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("compactionSummary");
    try jw.objectField("summary");
    try jw.write(msg.summary);
    try jw.objectField("tokensBefore");
    try jw.write(msg.tokens_before);
    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeBranchSummaryMessage(jw: *Stringify, msg: agent.protocol.AgentMessage.BranchSummaryMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("branchSummary");
    try jw.objectField("summary");
    try jw.write(msg.summary);
    try jw.objectField("fromId");
    try jw.write(msg.from_id);
    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCustomMessage(jw: *Stringify, msg: agent.protocol.AgentMessage.CustomMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("custom");
    try jw.objectField("customType");
    try jw.write(msg.custom_type);
    try jw.objectField("content");
    try writeCustomContent(jw, msg.content);
    if (msg.details) |d| {
        try jw.objectField("details");
        try jw.write(d);
    }
    try jw.objectField("display");
    try jw.write(msg.display);
    try jw.objectField("timestamp");
    try jw.write(msg.timestamp);
    try jw.endObject();
}

pub fn writeCustomContent(jw: *Stringify, content: agent.protocol.AgentMessage.CustomContent) !void {
    switch (content) {
        .text => |t| try jw.write(t),
        .blocks => |blocks| {
            try jw.beginArray();
            for (blocks) |block| {
                switch (block) {
                    .text => |tc| try writeTextBlock(jw, tc),
                    .image => |ic| try writeImageBlock(jw, ic),
                }
            }
            try jw.endArray();
        },
    }
}

// ─── Content block writers ──────────────────────────────────────────

pub fn writeTextBlock(jw: *Stringify, tc: ai.protocol.TextContent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("text");
    try jw.objectField("text");
    try jw.write(tc.text);
    if (tc.text_signature) |sig| {
        try jw.objectField("textSignature");
        try jw.write(sig);
    }
    try jw.endObject();
}

pub fn writeThinkingBlock(jw: *Stringify, th: ai.protocol.ThinkingContent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("thinking");
    try jw.objectField("thinking");
    try jw.write(th.thinking);
    if (th.thinking_signature) |sig| {
        try jw.objectField("thinkingSignature");
        try jw.write(sig);
    }
    if (th.redacted) |r| {
        try jw.objectField("redacted");
        try jw.write(r);
    }
    try jw.endObject();
}

pub fn writeToolCallBlock(jw: *Stringify, tc: ai.protocol.ToolCall) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("toolCall");
    try jw.objectField("id");
    try jw.write(tc.id);
    try jw.objectField("name");
    try jw.write(tc.name);
    try jw.objectField("arguments");
    try jw.write(tc.arguments);
    if (tc.thought_signature) |sig| {
        try jw.objectField("thoughtSignature");
        try jw.write(sig);
    }
    try jw.endObject();
}

pub fn writeImageBlock(jw: *Stringify, ic: ai.protocol.ImageContent) !void {
    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("image");
    try jw.objectField("data");
    try jw.write(ic.data);
    try jw.objectField("mimeType");
    try jw.write(ic.mime_type);
    try jw.endObject();
}

pub fn writeUsage(jw: *Stringify, usage: ai.protocol.Usage) !void {
    try jw.beginObject();
    try jw.objectField("input");
    try jw.write(usage.input);
    try jw.objectField("output");
    try jw.write(usage.output);
    try jw.objectField("cacheRead");
    try jw.write(usage.cache_read);
    try jw.objectField("cacheWrite");
    try jw.write(usage.cache_write);
    try jw.objectField("totalTokens");
    try jw.write(usage.total_tokens);
    try jw.objectField("cost");
    try jw.beginObject();
    try jw.objectField("input");
    try jw.print("{d}", .{usage.cost.input});
    try jw.objectField("output");
    try jw.print("{d}", .{usage.cost.output});
    try jw.objectField("cacheRead");
    try jw.print("{d}", .{usage.cost.cache_read});
    try jw.objectField("cacheWrite");
    try jw.print("{d}", .{usage.cost.cache_write});
    try jw.objectField("total");
    try jw.print("{d}", .{usage.cost.total});
    try jw.endObject();
    try jw.endObject();
}

// ─── Deserialization ────────────────────────────────────────────────

pub fn parseFileEntry(allocator: std.mem.Allocator, line: []const u8) !proto.FileEntry {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, line, .{ .allocate = .alloc_always });
    defer parsed.deinit();
    const obj = parsed.value.object;

    const type_str = obj.get("type").?.string;
    if (std.mem.eql(u8, type_str, "session")) {
        return .{ .header = try parseHeader(allocator, obj) };
    }
    return .{ .entry = try parseEntry(allocator, obj, type_str) };
}

fn parseHeader(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !proto.SessionHeader {
    return .{
        .id = try allocator.dupe(u8, obj.get("id").?.string),
        .timestamp = try allocator.dupe(u8, obj.get("timestamp").?.string),
        .cwd = try allocator.dupe(u8, obj.get("cwd").?.string),
        .version = if (obj.get("version")) |v| @intCast(v.integer) else 1,
        .parent_session = if (obj.get("parentSession")) |v| try allocator.dupe(u8, v.string) else null,
    };
}

fn parseEntry(allocator: std.mem.Allocator, obj: std.json.ObjectMap, type_str: []const u8) !proto.SessionEntry {
    const id = try allocator.dupe(u8, obj.get("id").?.string);
    const parent_id = if (obj.get("parentId")) |v| switch (v) {
        .string => |s| try allocator.dupe(u8, s),
        else => null,
    } else null;
    const timestamp = try allocator.dupe(u8, obj.get("timestamp").?.string);

    const entry: proto.SessionEntry.EntryType = if (std.mem.eql(u8, type_str, "message"))
        .{ .message = .{ .message = try parseAgentMessage(allocator, obj.get("message").?) } }
    else if (std.mem.eql(u8, type_str, "thinking_level_change"))
        .{ .thinking_level_change = .{
            .thinking_level = try allocator.dupe(u8, obj.get("thinkingLevel").?.string),
        } }
    else if (std.mem.eql(u8, type_str, "model_change"))
        .{ .model_change = .{
            .provider = try allocator.dupe(u8, obj.get("provider").?.string),
            .model_id = try allocator.dupe(u8, obj.get("modelId").?.string),
        } }
    else if (std.mem.eql(u8, type_str, "compaction"))
        .{ .compaction = .{
            .summary = try allocator.dupe(u8, obj.get("summary").?.string),
            .first_kept_entry_id = try allocator.dupe(u8, obj.get("firstKeptEntryId").?.string),
            .tokens_before = @intCast(obj.get("tokensBefore").?.integer),
            .details = if (obj.get("details")) |d| try json_util.cloneJsonValue(allocator, d) else null,
            .from_hook = if (obj.get("fromHook")) |v| v.bool else null,
        } }
    else if (std.mem.eql(u8, type_str, "branch_summary"))
        .{ .branch_summary = .{
            .from_id = try allocator.dupe(u8, obj.get("fromId").?.string),
            .summary = try allocator.dupe(u8, obj.get("summary").?.string),
            .details = if (obj.get("details")) |d| try json_util.cloneJsonValue(allocator, d) else null,
            .from_hook = if (obj.get("fromHook")) |v| v.bool else null,
        } }
    else if (std.mem.eql(u8, type_str, "custom"))
        .{ .custom = .{
            .custom_type = try allocator.dupe(u8, obj.get("customType").?.string),
            .data = if (obj.get("data")) |d| try json_util.cloneJsonValue(allocator, d) else null,
        } }
    else if (std.mem.eql(u8, type_str, "custom_message"))
        .{ .custom_message = .{
            .custom_type = try allocator.dupe(u8, obj.get("customType").?.string),
            .content = try parseCustomContent(allocator, obj.get("content").?),
            .details = if (obj.get("details")) |d| try json_util.cloneJsonValue(allocator, d) else null,
            .display = obj.get("display").?.bool,
        } }
    else if (std.mem.eql(u8, type_str, "label"))
        .{ .label = .{
            .target_id = try allocator.dupe(u8, obj.get("targetId").?.string),
            .label = if (obj.get("label")) |v| switch (v) {
                .string => |s| try allocator.dupe(u8, s),
                else => null,
            } else null,
        } }
    else if (std.mem.eql(u8, type_str, "session_info"))
        .{ .session_info = .{
            .name = if (obj.get("name")) |v| try allocator.dupe(u8, v.string) else null,
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
    const obj = value.object;
    const role = obj.get("role").?.string;

    if (std.mem.eql(u8, role, "user")) {
        return .{ .user = try parseUserMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, "assistant")) {
        return .{ .assistant = try parseAssistantMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, "toolResult")) {
        return .{ .tool_result = try parseToolResultMessage(allocator, obj) };
    } else if (std.mem.eql(u8, role, "compactionSummary")) {
        return .{ .compaction_summary = .{
            .summary = try allocator.dupe(u8, obj.get("summary").?.string),
            .tokens_before = @intCast(obj.get("tokensBefore").?.integer),
            .timestamp = @intCast(obj.get("timestamp").?.integer),
        } };
    } else if (std.mem.eql(u8, role, "branchSummary")) {
        return .{ .branch_summary = .{
            .summary = try allocator.dupe(u8, obj.get("summary").?.string),
            .from_id = try allocator.dupe(u8, obj.get("fromId").?.string),
            .timestamp = @intCast(obj.get("timestamp").?.integer),
        } };
    } else if (std.mem.eql(u8, role, "custom")) {
        return .{ .custom = try parseCustomAgentMessage(allocator, obj) };
    }
    return error.UnknownMessageRole;
}

fn parseUserMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.UserMessage {
    const content_val = obj.get("content").?;
    const content: ai.protocol.UserMessage.UserMessageContent = switch (content_val) {
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, arr.items.len);
            for (arr.items, 0..) |item, i| {
                blocks[i] = try parseUserContentBlock(allocator, item.object);
            }
            break :blk .{ .blocks = blocks };
        },
        else => return error.InvalidUserContent,
    };
    return .{
        .content = content,
        .timestamp = @intCast(obj.get("timestamp").?.integer),
    };
}

fn parseUserContentBlock(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.UserMessage.UserMessageContent.Block {
    const type_str = obj.get("type").?.string;
    if (std.mem.eql(u8, type_str, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, obj.get("text").?.string),
            .text_signature = if (obj.get("textSignature")) |v| try allocator.dupe(u8, v.string) else null,
        } };
    } else if (std.mem.eql(u8, type_str, "image")) {
        return .{ .image = .{
            .data = try allocator.dupe(u8, obj.get("data").?.string),
            .mime_type = try allocator.dupe(u8, obj.get("mimeType").?.string),
        } };
    }
    return error.UnknownContentBlockType;
}

fn parseAssistantMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.AssistantMessage {
    const content_arr = obj.get("content").?.array;
    var blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, content_arr.items.len);
    for (content_arr.items, 0..) |item, i| {
        blocks[i] = try parseAssistantContentBlock(allocator, item.object);
    }

    const usage_obj = obj.get("usage").?.object;
    const cost_obj = usage_obj.get("cost").?.object;

    return .{
        .content = blocks,
        .api = json_util.parseApi(obj.get("api").?.string),
        .provider = json_util.parseProvider(obj.get("provider").?.string),
        .model = try allocator.dupe(u8, obj.get("model").?.string),
        .response_id = if (obj.get("responseId")) |v| try allocator.dupe(u8, v.string) else null,
        .usage = .{
            .input = @intCast(usage_obj.get("input").?.integer),
            .output = @intCast(usage_obj.get("output").?.integer),
            .cache_read = @intCast(usage_obj.get("cacheRead").?.integer),
            .cache_write = @intCast(usage_obj.get("cacheWrite").?.integer),
            .total_tokens = @intCast(usage_obj.get("totalTokens").?.integer),
            .cost = .{
                .input = json_util.jsonToFloat(cost_obj.get("input").?),
                .output = json_util.jsonToFloat(cost_obj.get("output").?),
                .cache_read = json_util.jsonToFloat(cost_obj.get("cacheRead").?),
                .cache_write = json_util.jsonToFloat(cost_obj.get("cacheWrite").?),
                .total = json_util.jsonToFloat(cost_obj.get("total").?),
            },
        },
        .stop_reason = json_util.parseStopReason(obj.get("stopReason").?.string),
        .error_message = if (obj.get("errorMessage")) |v| try allocator.dupe(u8, v.string) else null,
        .failure = if (obj.get("failure")) |v| try parseNormalizedFailure(allocator, v.object) else null,
        .timestamp = @intCast(obj.get("timestamp").?.integer),
    };
}

fn writeNormalizedFailure(jw: *Stringify, failure: ai.protocol.NormalizedFailure) !void {
    try jw.beginObject();
    try jw.objectField("kind");
    try jw.write(@tagName(failure.kind));
    if (failure.http_status) |status| {
        try jw.objectField("httpStatus");
        try jw.write(status);
    }
    if (failure.provider_code) |code| {
        try jw.objectField("providerCode");
        try jw.write(code);
    }
    if (failure.provider_type) |provider_type| {
        try jw.objectField("providerType");
        try jw.write(provider_type);
    }
    if (failure.retry_after_ms) |retry_after_ms| {
        try jw.objectField("retryAfterMs");
        try jw.write(retry_after_ms);
    }
    try jw.endObject();
}

fn parseNormalizedFailure(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.NormalizedFailure {
    const kind_str = obj.get("kind").?.string;
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
        .fatal;

    return .{
        .kind = kind,
        .http_status = if (obj.get("httpStatus")) |v| @intCast(v.integer) else null,
        .provider_code = if (obj.get("providerCode")) |v| try allocator.dupe(u8, v.string) else null,
        .provider_type = if (obj.get("providerType")) |v| try allocator.dupe(u8, v.string) else null,
        .retry_after_ms = if (obj.get("retryAfterMs")) |v| @intCast(v.integer) else null,
    };
}

fn parseAssistantContentBlock(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.AssistantMessage.AssistantContentBlock {
    const type_str = obj.get("type").?.string;
    if (std.mem.eql(u8, type_str, "text")) {
        return .{ .text = .{
            .text = try allocator.dupe(u8, obj.get("text").?.string),
            .text_signature = if (obj.get("textSignature")) |v| try allocator.dupe(u8, v.string) else null,
        } };
    } else if (std.mem.eql(u8, type_str, "thinking")) {
        return .{ .thinking = .{
            .thinking = try allocator.dupe(u8, obj.get("thinking").?.string),
            .thinking_signature = if (obj.get("thinkingSignature")) |v| try allocator.dupe(u8, v.string) else null,
            .redacted = if (obj.get("redacted")) |v| v.bool else null,
        } };
    } else if (std.mem.eql(u8, type_str, "toolCall")) {
        return .{ .tool_call = .{
            .id = try allocator.dupe(u8, obj.get("id").?.string),
            .name = try allocator.dupe(u8, obj.get("name").?.string),
            .arguments = try json_util.cloneJsonValue(allocator, obj.get("arguments").?),
            .thought_signature = if (obj.get("thoughtSignature")) |v| try allocator.dupe(u8, v.string) else null,
        } };
    }
    return error.UnknownContentBlockType;
}

fn parseToolResultMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !ai.protocol.ToolResultMessage {
    const content_arr = obj.get("content").?.array;
    var blocks = try allocator.alloc(ai.protocol.ToolResultMessage.ContentBlock, content_arr.items.len);
    for (content_arr.items, 0..) |item, i| {
        const block_obj = item.object;
        const type_str = block_obj.get("type").?.string;
        if (std.mem.eql(u8, type_str, "text")) {
            blocks[i] = .{ .text = .{
                .text = try allocator.dupe(u8, block_obj.get("text").?.string),
                .text_signature = if (block_obj.get("textSignature")) |v| try allocator.dupe(u8, v.string) else null,
            } };
        } else if (std.mem.eql(u8, type_str, "image")) {
            blocks[i] = .{ .image = .{
                .data = try allocator.dupe(u8, block_obj.get("data").?.string),
                .mime_type = try allocator.dupe(u8, block_obj.get("mimeType").?.string),
            } };
        } else {
            return error.UnknownContentBlockType;
        }
    }
    return .{
        .tool_call_id = try allocator.dupe(u8, obj.get("toolCallId").?.string),
        .tool_name = try allocator.dupe(u8, obj.get("toolName").?.string),
        .content = blocks,
        .details = if (obj.get("details")) |d| try json_util.cloneJsonValue(allocator, d) else null,
        .is_error = obj.get("isError").?.bool,
        .timestamp = @intCast(obj.get("timestamp").?.integer),
    };
}

fn parseCustomAgentMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !agent.protocol.AgentMessage.CustomMessage {
    return .{
        .custom_type = try allocator.dupe(u8, obj.get("customType").?.string),
        .content = try parseCustomContent(allocator, obj.get("content").?),
        .display = if (obj.get("display")) |v| v.bool else false,
        .details = if (obj.get("details")) |d| try json_util.cloneJsonValue(allocator, d) else null,
        .timestamp = @intCast(obj.get("timestamp").?.integer),
    };
}

fn parseCustomContent(allocator: std.mem.Allocator, val: std.json.Value) !agent.protocol.AgentMessage.CustomContent {
    return switch (val) {
        .string => |s| .{ .text = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var blocks = try allocator.alloc(ai.protocol.UserMessage.UserMessageContent.Block, arr.items.len);
            for (arr.items, 0..) |item, i| {
                blocks[i] = try parseUserContentBlock(allocator, item.object);
            }
            break :blk .{ .blocks = blocks };
        },
        else => error.InvalidCustomContent,
    };
}

// ─── Tests ──────────────────────────────────────────────────────────

test "header round-trip" {
    const allocator = std.testing.allocator;
    const header = proto.SessionHeader{
        .id = "test-uuid",
        .timestamp = "2025-01-01T00:00:00.000Z",
        .cwd = "/home/user",
        .version = 3,
        .parent_session = null,
    };
    const json_str = try json_write.toOwnedSlice(allocator, header, writeHeader);
    defer allocator.free(json_str);

    const parsed = try parseFileEntry(allocator, json_str);
    const h = parsed.header;
    defer {
        allocator.free(h.id);
        allocator.free(h.timestamp);
        allocator.free(h.cwd);
    }
    try std.testing.expectEqualStrings("test-uuid", h.id);
    try std.testing.expectEqualStrings("2025-01-01T00:00:00.000Z", h.timestamp);
    try std.testing.expectEqualStrings("/home/user", h.cwd);
    try std.testing.expectEqual(@as(u32, 3), h.version);
    try std.testing.expect(h.parent_session == null);
}

test "header with parentSession" {
    const allocator = std.testing.allocator;
    const header = proto.SessionHeader{
        .id = "child-uuid",
        .timestamp = "2025-01-01T00:00:00.000Z",
        .cwd = "/tmp",
        .parent_session = "parent-uuid",
    };
    const json_str = try json_write.toOwnedSlice(allocator, header, writeHeader);
    defer allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"parentSession\":\"parent-uuid\"") != null);

    const parsed = try parseFileEntry(allocator, json_str);
    const h = parsed.header;
    defer {
        allocator.free(h.id);
        allocator.free(h.timestamp);
        allocator.free(h.cwd);
        if (h.parent_session) |ps| allocator.free(ps);
    }
    try std.testing.expectEqualStrings("parent-uuid", h.parent_session.?);
}

test "message entry round-trip with user message" {
    const allocator = std.testing.allocator;
    const entry = proto.SessionEntry{
        .id = "abcd1234",
        .parent_id = null,
        .timestamp = "2025-01-01T00:00:00.000Z",
        .entry = .{ .message = .{
            .message = .{ .user = .{
                .content = .{ .text = "hello world" },
                .timestamp = 1700000000000,
            } },
        } },
    };
    const json_str = try json_write.toOwnedSlice(allocator, entry, writeEntry);
    defer allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"message\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"parentId\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"role\":\"user\"") != null);
    // pi-mono serializes plain text user content as a JSON string, not a blocks array
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"content\":\"hello world\"") != null);
}

test "model_change entry wire format" {
    const allocator = std.testing.allocator;
    const entry = proto.SessionEntry{
        .id = "ef567890",
        .parent_id = "abcd1234",
        .timestamp = "2025-01-01T00:00:01.000Z",
        .entry = .{ .model_change = .{
            .provider = "anthropic",
            .model_id = "claude-sonnet-4-5",
        } },
    };
    const json_str = try json_write.toOwnedSlice(allocator, entry, writeEntry);
    defer allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"type\":\"model_change\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"modelId\":\"claude-sonnet-4-5\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"parentId\":\"abcd1234\"") != null);
}

test "compaction entry wire format" {
    const allocator = std.testing.allocator;
    const entry = proto.SessionEntry{
        .id = "cc000000",
        .parent_id = "bb000000",
        .timestamp = "2025-06-01T00:00:00.000Z",
        .entry = .{ .compaction = .{
            .summary = "summarized context",
            .first_kept_entry_id = "aa000000",
            .tokens_before = 50000,
            .from_hook = true,
        } },
    };
    const json_str = try json_write.toOwnedSlice(allocator, entry, writeEntry);
    defer allocator.free(json_str);

    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"firstKeptEntryId\":\"aa000000\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"tokensBefore\":50000") != null);
    try std.testing.expect(std.mem.indexOf(u8, json_str, "\"fromHook\":true") != null);
}

test "assistant message round-trips normalized failure metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const entry = proto.SessionEntry{
        .id = "ad000001",
        .parent_id = null,
        .timestamp = "2025-06-01T00:00:00.000Z",
        .entry = .{ .message = .{ .message = .{ .assistant = .{
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
        } } } },
    };

    const json_str = try json_write.toOwnedSlice(allocator, entry, writeEntry);
    defer allocator.free(json_str);
    const parsed = try parseEntry(allocator, json_str);
    switch (parsed.entry) {
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

test "serializeEntry works when caller allocator is an arena" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
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

    const line = try json_write.toOwnedSlice(allocator, entry, writeEntry);
    try std.testing.expect(std.mem.indexOf(u8, line, long_tool_call_id) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, long_tool_name) != null);
}

test "session write-read-buildContext round-trip" {
    const allocator = std.testing.allocator;
    const context = @import("context.zig");

    const user_msg = agent.protocol.AgentMessage{ .user = .{
        .content = .{ .text = "what files are here?" },
        .timestamp = 1700000000000,
    } };

    const tool_call = ai.protocol.ToolCall{
        .id = "toolu_abc123",
        .name = "bash",
        .arguments = .null,
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
        const entry = proto.SessionEntry{
            .id = ed.id,
            .parent_id = ed.parent,
            .timestamp = "2025-01-01T00:00:00.000Z",
            .entry = .{ .message = .{ .message = ed.msg } },
        };
        json_lines[i] = try json_write.toOwnedSlice(allocator, entry, writeEntry);
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

    const ctx = try context.buildSessionContext(aa, &parsed_entries, null);

    try std.testing.expectEqual(@as(usize, 3), ctx.messages.len);

    switch (ctx.messages[0]) {
        .user => |u| {
            switch (u.content) {
                .blocks => |b| {
                    try std.testing.expectEqual(@as(usize, 1), b.len);
                    switch (b[0]) {
                        .text => |tc| try std.testing.expectEqualStrings("what files are here?", tc.text),
                        else => return error.UnexpectedBlock,
                    }
                },
                .text => |t| try std.testing.expectEqualStrings("what files are here?", t),
            }
        },
        else => return error.ExpectedUserMessage,
    }

    switch (ctx.messages[1]) {
        .assistant => |a| {
            try std.testing.expectEqualStrings("claude-sonnet-4-5", a.model);
            try std.testing.expectEqual(ai.protocol.StopReason.toolUse, a.stop_reason);
            try std.testing.expectEqual(@as(usize, 1), a.content.len);
            switch (a.content[0]) {
                .tool_call => |tc| {
                    try std.testing.expectEqualStrings("toolu_abc123", tc.id);
                    try std.testing.expectEqualStrings("bash", tc.name);
                },
                else => return error.ExpectedToolCallBlock,
            }
        },
        else => return error.ExpectedAssistantMessage,
    }

    switch (ctx.messages[2]) {
        .tool_result => |tr| {
            try std.testing.expectEqualStrings("toolu_abc123", tr.tool_call_id);
            try std.testing.expectEqualStrings("bash", tr.tool_name);
            try std.testing.expect(!tr.is_error);
            try std.testing.expectEqual(@as(usize, 1), tr.content.len);
            switch (tr.content[0]) {
                .text => |tc| try std.testing.expectEqualStrings("file1.txt\nfile2.txt", tc.text),
                else => return error.ExpectedTextBlock,
            }
        },
        else => return error.ExpectedToolResultMessage,
    }
}
