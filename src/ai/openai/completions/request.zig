const std = @import("std");
const protocol = @import("../../protocol.zig");

fn mapReasoningEffort(effort: []const u8, map: ?protocol.OpenAiCompletionsCompat.ReasoningEffortMap) []const u8 {
    const m = map orelse return effort;
    if (std.mem.eql(u8, effort, "minimal")) return m.minimal orelse effort;
    if (std.mem.eql(u8, effort, "low")) return m.low orelse effort;
    if (std.mem.eql(u8, effort, "medium")) return m.medium orelse effort;
    if (std.mem.eql(u8, effort, "high")) return m.high orelse effort;
    if (std.mem.eql(u8, effort, "xhigh")) return m.xhigh orelse effort;
    return effort;
}

pub fn buildRequestJson(
    allocator: std.mem.Allocator,
    out: *std.ArrayListUnmanaged(u8), // ziglint-ignore: Z011
    model: protocol.Model,
    context: protocol.Context,
    reasoning: ?protocol.ThinkingLevel,
) !void {
    var allocating = std.Io.Writer.Allocating.fromArrayList(allocator, out);
    var jw: std.json.Stringify = .{ .writer = &allocating.writer, .options = .{} };

    try jw.beginObject();

    try jw.objectField("model");
    try jw.write(model.requestModel());

    try jw.objectField("stream");
    try jw.write(true);

    try jw.objectField("stream_options");
    try jw.beginObject();
    try jw.objectField("include_usage");
    try jw.write(true);
    try jw.endObject();

    try jw.objectField("messages");
    try jw.beginArray();
    try writeMessages(allocator, &jw, model, context);
    try jw.endArray();

    if (context.tools) |tools| {
        try jw.objectField("tools");
        try jw.beginArray();
        for (tools) |tool| {
            try jw.beginObject();
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tool.name);
            try jw.objectField("description");
            try jw.write(tool.description);
            try jw.objectField("parameters");
            try jw.write(tool.parameters);
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
    }

    if (model.reasoning) {
        if (reasoning) |level| {
            const effort_str = protocol.thinkingLevelToString(level);
            if (model.compat) |compat_union| {
                switch (compat_union) {
                    .openai_completions => |compat| {
                        if (compat.thinking_format) |fmt| {
                            if (fmt == .openrouter) {
                                try jw.objectField("reasoning");
                                try jw.beginObject();
                                try jw.objectField("effort");
                                try jw.write(mapReasoningEffort(effort_str, compat.reasoning_effort_map));
                                try jw.endObject();
                            }
                        } else if (compat.supports_reasoning_effort orelse false) {
                            try jw.objectField("reasoning_effort");
                            try jw.write(mapReasoningEffort(effort_str, compat.reasoning_effort_map));
                        }
                    },
                    else => {},
                }
            }
        } else {
            if (model.compat) |compat_union| {
                switch (compat_union) {
                    .openai_completions => |compat| {
                        if (compat.thinking_format) |fmt| {
                            if (fmt == .openrouter) {
                                try jw.objectField("reasoning");
                                try jw.beginObject();
                                try jw.objectField("effort");
                                try jw.write("none");
                                try jw.endObject();
                            }
                        }
                    },
                    else => {},
                }
            }
        }
    }

    try jw.endObject();
    out.* = allocating.toArrayList();
}

fn writeMessages(
    allocator: std.mem.Allocator,
    jw: *std.json.Stringify,
    model: protocol.Model,
    context: protocol.Context,
) !void {
    if (context.system_prompt) |sys| {
        try jw.beginObject();
        try jw.objectField("role");
        try jw.write("system");
        try jw.objectField("content");
        try jw.write(sys);
        try jw.endObject();
    }

    var i: usize = 0;
    while (i < context.messages.len) : (i += 1) {
        const msg = context.messages[i];
        switch (msg) {
            .user => |u| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("user");
                try jw.objectField("content");
                switch (u.content) {
                    .text => |t| try jw.write(t),
                    .blocks => |blocks| {
                        try jw.beginArray();
                        for (blocks) |b| {
                            try jw.beginObject();
                            switch (b) {
                                .text => |tc| {
                                    try jw.objectField("type");
                                    try jw.write("text");
                                    try jw.objectField("text");
                                    try jw.write(tc.text);
                                },
                                .image => |ic| {
                                    try jw.objectField("type");
                                    try jw.write("image_url");
                                    try jw.objectField("image_url");
                                    try jw.beginObject();
                                    try jw.objectField("url");
                                    const data_url = try std.fmt.allocPrint(
                                        allocator,
                                        "data:{s};base64,{s}",
                                        .{ ic.mime_type, ic.data },
                                    );
                                    defer allocator.free(data_url);
                                    try jw.write(data_url);
                                    try jw.endObject();
                                },
                            }
                            try jw.endObject();
                        }
                        try jw.endArray();
                    },
                }
                try jw.endObject();
            },
            .assistant => |a| {
                try writeAssistantMessage(allocator, jw, a);
            },
            .tool_result => |tr| {
                try jw.beginObject();
                try jw.objectField("role");
                try jw.write("tool");
                try jw.objectField("tool_call_id");
                try jw.write(tr.tool_call_id);
                try jw.objectField("content");
                var concat: std.ArrayList(u8) = .empty;
                defer concat.deinit(allocator);
                for (tr.content) |cb| {
                    switch (cb) {
                        .text => |t| try concat.appendSlice(allocator, t.text),
                        .image => {},
                    }
                }
                if (concat.items.len == 0) {
                    try jw.write("(empty tool result)");
                } else {
                    try jw.write(concat.items);
                }
                try jw.endObject();
            },
        }
    }
    _ = model;
}

fn writeAssistantMessage(allocator: std.mem.Allocator, jw: *std.json.Stringify, a: protocol.AssistantMessage) !void {
    try jw.beginObject();
    try jw.objectField("role");
    try jw.write("assistant");

    var text_concat: std.ArrayList(u8) = .empty;
    defer text_concat.deinit(allocator);
    for (a.content) |b| {
        switch (b) {
            .text => |tc| if (tc.text.len > 0) try text_concat.appendSlice(allocator, tc.text),
            else => {},
        }
    }

    var has_content = false;
    if (text_concat.items.len > 0) {
        try jw.objectField("content");
        try jw.write(text_concat.items);
        has_content = true;
    }

    var tool_count: usize = 0;
    for (a.content) |b| if (b == .tool_call) {
        tool_count += 1;
    };
    if (tool_count > 0) {
        try jw.objectField("tool_calls");
        try jw.beginArray();
        for (a.content) |b| {
            if (b != .tool_call) continue;
            const tc = b.tool_call;
            try jw.beginObject();
            try jw.objectField("id");
            try jw.write(tc.id);
            try jw.objectField("type");
            try jw.write("function");
            try jw.objectField("function");
            try jw.beginObject();
            try jw.objectField("name");
            try jw.write(tc.name);
            try jw.objectField("arguments");
            var args_buf: std.Io.Writer.Allocating = .init(allocator);
            defer args_buf.deinit();
            var inner: std.json.Stringify = .{ .writer = &args_buf.writer, .options = .{} };
            try inner.write(tc.arguments);
            try jw.write(args_buf.written());
            try jw.endObject();
            try jw.endObject();
        }
        try jw.endArray();
        has_content = true;
    }

    if (!has_content) {
        try jw.objectField("content");
        try jw.write("");
    }
    try jw.endObject();
}
