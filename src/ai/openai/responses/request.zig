const std = @import("std");
const protocol = @import("../../protocol.zig");
const json_text = @import("../../../json/text.zig");
const replay = @import("replay.zig");
const runtime_env = @import("../../../runtime/env.zig");

pub fn writeBaseFields(jw: *std.json.Stringify, model: protocol.Model) !void {
    try jw.objectField("model");
    try jw.write(model.requestModel());

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("store");
    try jw.write(false);
}

pub const ToolStrictMode = enum {
    omit,
    false_value,
    null_value,
};

pub fn writeTools(jw: *std.json.Stringify, tools: []const protocol.Tool, strict_mode: ToolStrictMode) !void {
    try jw.objectField("tools");
    try jw.beginArray();
    for (tools) |tool| {
        try jw.beginObject();
        try jw.objectField("type");
        try jw.write("function");
        try jw.objectField("name");
        try jw.write(tool.name);
        try jw.objectField("description");
        try jw.write(tool.description);
        try jw.objectField("parameters");
        try jw.write(tool.parameters);
        switch (strict_mode) {
            .omit => {},
            .false_value => {
                try jw.objectField("strict");
                try jw.write(false);
            },
            .null_value => {
                try jw.objectField("strict");
                try jw.write(null);
            },
        }
        try jw.endObject();
    }
    try jw.endArray();
}

fn resolveCacheRetention(
    env: runtime_env.Env,
    cache_retention: ?protocol.CacheRetention,
) protocol.CacheRetention {
    if (cache_retention) |retention| return retention;
    const value = env.get("PI_CACHE_RETENTION") orelse return .short;
    if (std.mem.eql(u8, value, "long")) return .long;
    return .short;
}

fn getPromptCacheRetention(base_url: []const u8, cache_retention: protocol.CacheRetention) ?[]const u8 {
    if (cache_retention != .long) return null;
    if (std.mem.indexOf(u8, base_url, "api.openai.com") != null) return "24h";
    return null;
}

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8), // ziglint-ignore: Z011
    model: protocol.Model,
    context: protocol.Context,
    options: protocol.StreamOptions,
    reasoning_effort: ?[]const u8,
    reasoning_summary: ?[]const u8,
) !void {
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    var jw: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try writeBaseFields(&jw, model);

    try jw.objectField("input");
    try jw.beginArray();
    try writeInput(allocator, options.io, &jw, model, context);
    try jw.endArray();

    const cache_retention = resolveCacheRetention(options.env, options.cache_retention);
    if (cache_retention != .none) {
        if (options.session_id) |sid| {
            try jw.objectField("prompt_cache_key");
            try jw.write(sid);
        }
    }
    if (getPromptCacheRetention(model.base_url, cache_retention)) |retention| {
        try jw.objectField("prompt_cache_retention");
        try jw.write(retention);
    }

    if (options.max_tokens) |max_tokens| {
        try jw.objectField("max_output_tokens");
        try jw.write(max_tokens);
    }

    if (options.temperature) |temperature| {
        try jw.objectField("temperature");
        try jw.write(temperature);
    }

    if (context.tools) |tools| {
        try writeTools(&jw, tools, .false_value);
    }

    if (model.reasoning) {
        if (reasoning_effort) |effort| {
            try jw.objectField("reasoning");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write(effort);
            try jw.objectField("summary");
            try jw.write(reasoning_summary orelse "auto");
            try jw.endObject();
            try jw.objectField("include");
            try jw.beginArray();
            try jw.write("reasoning.encrypted_content");
            try jw.endArray();
        } else if (model.provider != .github_copilot) {
            try jw.objectField("reasoning");
            try jw.beginObject();
            try jw.objectField("effort");
            try jw.write("none");
            try jw.endObject();
        }
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

pub fn writeInput(
    allocator: std.mem.Allocator,
    io: std.Io,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
) !void {
    try writeInputOpts(allocator, io, jw, model, context, true);
}

pub fn writeInputOpts(
    allocator: std.mem.Allocator,
    io: std.Io,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
    include_system_prompt: bool,
) !void {
    try replay.writeResponsesInput(
        allocator,
        io,
        jw,
        model,
        context,
        .{ .include_system_prompt = include_system_prompt },
    );
}

const ToolCallIdMapping = struct {
    original_id: []const u8,
    mapped_id: []const u8,

    fn deinit(self: ToolCallIdMapping, allocator: std.mem.Allocator) void {
        allocator.free(self.original_id);
        allocator.free(self.mapped_id);
    }
};

const PendingToolCall = struct {
    id: []const u8,
    name: []const u8,

    fn deinit(self: PendingToolCall, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.name);
    }
};

fn writeUserMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    u: protocol.UserMessage,
) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("user");
    try jw.objectField("content");
    try jw.beginArray();
    switch (u.content) {
        .text => |text| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("input_text");
            try jw.objectField("text");
            try jw.write(text);
            try jw.endObject();
        },
        .blocks => |blocks| for (blocks) |b| switch (b) {
            .text => |tc| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_text");
                try jw.objectField("text");
                try jw.write(tc.text);
                try jw.endObject();
            },
            .image => |ic| {
                try jw.beginObject();
                try jw.objectField("type");
                try jw.write("input_image");
                try jw.objectField("detail");
                try jw.write("auto");
                try jw.objectField("image_url");
                const url = try std.fmt.allocPrint(
                    allocator,
                    "data:{s};base64,{s}",
                    .{ ic.mime_type, ic.data },
                );
                defer allocator.free(url);
                try jw.write(url);
                try jw.endObject();
            },
        },
    }
    try jw.endArray();
    try jw.endObject();
}

fn writeToolResultMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    tr: protocol.ToolResultMessage,
    mapped_tool_call_id: []const u8,
) !void {
    var concat: std.ArrayList(u8) = .empty;
    defer concat.deinit(allocator);
    var saw_text = false;
    for (tr.content) |cb| switch (cb) {
        .text => |text| {
            if (saw_text) try concat.appendSlice(allocator, "\n");
            try concat.appendSlice(allocator, text.text);
            saw_text = true;
        },
        .image => {},
    };

    try jw.beginObject();
    try jw.objectField("type");
    try jw.write("function_call_output");
    try jw.objectField("call_id");
    const call_id = if (std.mem.findScalar(u8, mapped_tool_call_id, '|')) |i|
        mapped_tool_call_id[0..i]
    else
        mapped_tool_call_id;
    try jw.write(call_id);
    try jw.objectField("output");
    if (concat.items.len == 0) {
        try jw.write("(empty tool result)");
    } else {
        const sanitized = try json_text.utf8LossyAlloc(allocator, concat.items);
        defer allocator.free(sanitized);
        try jw.write(sanitized);
    }
    try jw.endObject();
}

fn getMappedToolCallId(
    allocator: std.mem.Allocator,
    mappings: []const ToolCallIdMapping,
    tool_call_id: []const u8,
) ![]const u8 {
    for (mappings) |mapping| {
        if (std.mem.eql(u8, mapping.original_id, tool_call_id)) {
            return allocator.dupe(u8, mapping.mapped_id);
        }
    }
    return allocator.dupe(u8, tool_call_id);
}

fn recordToolCallIdMapping(
    allocator: std.mem.Allocator,
    tool_id_map: *std.ArrayList(ToolCallIdMapping),
    original_id: []const u8,
    normalized: NormalizedToolCallId,
) !void {
    var mapped: std.ArrayList(u8) = .empty;
    defer mapped.deinit(allocator);
    try mapped.appendSlice(allocator, normalized.call_id);
    if (normalized.item_id) |item_id| {
        try mapped.append(allocator, '|');
        try mapped.appendSlice(allocator, item_id);
    }
    const mapped_id = try mapped.toOwnedSlice(allocator);
    errdefer allocator.free(mapped_id);

    for (tool_id_map.items) |*mapping| {
        if (std.mem.eql(u8, mapping.original_id, original_id)) {
            allocator.free(mapping.mapped_id);
            mapping.mapped_id = mapped_id;
            return;
        }
    }

    try tool_id_map.append(allocator, .{
        .original_id = try allocator.dupe(u8, original_id),
        .mapped_id = mapped_id,
    });
}

fn flushPendingSyntheticToolResults(
    allocator: std.mem.Allocator,
    io: std.Io,
    jw: *std.json.Stringify,
    pending_tool_calls: *std.ArrayList(PendingToolCall),
    existing_tool_result_ids: []const []const u8,
    tool_id_map: *std.ArrayList(ToolCallIdMapping),
) !void {
    for (pending_tool_calls.items) |pending| {
        var found = false;
        for (existing_tool_result_ids) |existing| {
            if (std.mem.eql(u8, existing, pending.id)) {
                found = true;
                break;
            }
        }
        if (found) continue;

        const synthetic: protocol.ToolResultMessage = .{
            .tool_call_id = pending.id,
            .tool_name = pending.name,
            .content = &.{.{ .text = .{ .text = "No result provided" } }},
            .details = null,
            .is_error = true,
            .timestamp = std.Io.Timestamp.now(io, .real).toMilliseconds(),
        };
        const mapped_id = try getMappedToolCallId(allocator, tool_id_map.items, pending.id);
        defer allocator.free(mapped_id);
        try writeToolResultMessage(allocator, jw, synthetic, mapped_id);
    }
}

fn writeAssistantMessage(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    target_model: protocol.Model,
    a: protocol.AssistantMessage,
    msg_index: usize,
    tool_id_map: *std.ArrayList(ToolCallIdMapping),
) !void {
    for (a.content) |b| switch (b) {
        .thinking => |th| {
            if (th.thinking_signature) |sig| {
                const parsed = std.json.parseFromSlice(std.json.Value, allocator, sig, .{}) catch continue;
                defer parsed.deinit();
                try jw.write(parsed.value);
            }
        },
        .text => |tc| {
            var msg_id: []const u8 = "";
            var msg_id_alloc: ?[]const u8 = null;
            var msg_phase: ?[]const u8 = null;
            var msg_phase_alloc: ?[]const u8 = null;
            defer if (msg_id_alloc) |p| allocator.free(p);
            defer if (msg_phase_alloc) |p| allocator.free(p);
            if (tc.text_signature) |sig| {
                if (sig.len > 0 and sig[0] == '{') {
                    if (std.json.parseFromSlice(std.json.Value, allocator, sig, .{})) |parsed| {
                        defer parsed.deinit();
                        if (parsed.value == .object) {
                            if (parsed.value.object.get("id")) |id| if (id == .string) {
                                msg_id_alloc = try allocator.dupe(u8, id.string);
                                msg_id = msg_id_alloc.?;
                            };
                            if (parsed.value.object.get("phase")) |phase| if (phase == .string) {
                                msg_phase_alloc = try allocator.dupe(u8, phase.string);
                                msg_phase = msg_phase_alloc.?;
                            };
                        }
                    } else |_| {}
                }
            }
            if (msg_id.len == 0) {
                const fallback = try std.fmt.allocPrint(allocator, "msg_{d}", .{msg_index});
                msg_id_alloc = fallback;
                msg_id = fallback;
            }
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("message");
            try jw.objectField("role");
            try jw.write("assistant");
            try jw.objectField("status");
            try jw.write("completed");
            try jw.objectField("id");
            try jw.write(msg_id);
            if (msg_phase) |phase| {
                try jw.objectField("phase");
                try jw.write(phase);
            }
            try jw.objectField("content");
            try jw.beginArray();
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("output_text");
            try jw.objectField("text");
            try jw.write(tc.text);
            try jw.objectField("annotations");
            try jw.beginArray();
            try jw.endArray();
            try jw.endObject();
            try jw.endArray();
            try jw.endObject();
        },
        .tool_call => |tcall| {
            var normalized = try normalizeResponsesToolCallId(allocator, target_model, a, tcall.id);
            defer normalized.deinit(allocator);
            try recordToolCallIdMapping(allocator, tool_id_map, tcall.id, normalized);
            const is_different_model = !std.mem.eql(u8, a.model, target_model.id) and
                providersEqual(a.provider, target_model.provider) and
                apisEqual(a.api, target_model.api);
            const include_item_id = if (normalized.item_id) |iid|
                !(is_different_model and std.mem.startsWith(u8, iid, "fc_"))
            else
                false;

            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function_call");
            if (include_item_id) {
                try jw.objectField("id");
                try jw.write(normalized.item_id.?);
            }
            try jw.objectField("call_id");
            try jw.write(normalized.call_id);
            try jw.objectField("name");
            try jw.write(tcall.name);
            try jw.objectField("arguments");
            var args_buf: std.Io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            try std.json.Stringify.value(tcall.arguments, .{}, &args_buf.writer);
            try jw.write(args_buf.written());
            try jw.endObject();
        },
    };
}

const NormalizedToolCallId = struct {
    call_id: []const u8,
    item_id: ?[]const u8,

    fn deinit(self: *NormalizedToolCallId, allocator: std.mem.Allocator) void {
        allocator.free(self.call_id);
        if (self.item_id) |item_id| allocator.free(item_id);
        self.* = undefined;
    }
};

fn normalizeResponsesToolCallId(
    allocator: std.mem.Allocator,
    target_model: protocol.Model,
    source: protocol.AssistantMessage,
    id: []const u8,
) !NormalizedToolCallId {
    const same_model = providersEqual(source.provider, target_model.provider) and
        apisEqual(source.api, target_model.api) and
        std.mem.eql(u8, source.model, target_model.id);
    if (!targetUsesResponsesToolCallNormalization(target_model.provider)) {
        return .{ .call_id = try normalizeIdPart(allocator, id), .item_id = null };
    }
    if (std.mem.findScalar(u8, id, '|')) |sep| {
        if (same_model) {
            return .{
                .call_id = try allocator.dupe(u8, id[0..sep]),
                .item_id = try allocator.dupe(u8, id[sep + 1 ..]),
            };
        }
        const call_id = try normalizeIdPart(allocator, id[0..sep]);
        const item_part = id[sep + 1 ..];
        var item_id = if (!providersEqual(source.provider, target_model.provider) or
            !apisEqual(source.api, target_model.api))
            try buildForeignResponsesItemId(allocator, item_part)
        else
            try normalizeIdPart(allocator, item_part);
        if (!std.mem.startsWith(u8, item_id, "fc_")) {
            const prefixed = try std.fmt.allocPrint(allocator, "fc_{s}", .{item_id});
            allocator.free(item_id);
            item_id = try normalizeIdPart(allocator, prefixed);
            allocator.free(prefixed);
        }
        return .{ .call_id = call_id, .item_id = item_id };
    }
    if (same_model) {
        return .{ .call_id = try allocator.dupe(u8, id), .item_id = null };
    }
    return .{ .call_id = try normalizeIdPart(allocator, id), .item_id = null };
}

fn targetUsesResponsesToolCallNormalization(provider: protocol.Provider) bool {
    return switch (provider) {
        .openai, .openai_codex, .opencode, .opencode_go => true,
        else => false,
    };
}

fn normalizeIdPart(allocator: std.mem.Allocator, part: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (part) |c| {
        const normalized = switch (c) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '-' => c,
            else => '_',
        };
        try out.append(allocator, normalized);
        if (out.items.len >= 64) break;
    }
    while (out.items.len > 0 and out.items[out.items.len - 1] == '_') {
        _ = out.pop();
    }
    return if (out.items.len == 0) allocator.dupe(u8, "id") else out.toOwnedSlice(allocator);
}

fn buildForeignResponsesItemId(allocator: std.mem.Allocator, item_id: []const u8) ![]const u8 {
    const hash = std.hash.Wyhash.hash(0, item_id);
    const raw = try std.fmt.allocPrint(allocator, "fc_{x}", .{hash});
    defer allocator.free(raw);
    return normalizeIdPart(allocator, raw);
}

fn providersEqual(a: protocol.Provider, b: protocol.Provider) bool {
    return std.meta.eql(a, b);
}

fn apisEqual(a: protocol.Api, b: protocol.Api) bool {
    return std.meta.eql(a, b);
}
