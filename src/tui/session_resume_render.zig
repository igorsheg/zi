const std = @import("std");
const ai_protocol = @import("../ai/protocol.zig");
const agent_protocol = @import("../agent/root.zig").protocol;
const AgentToolResult = agent_protocol.AgentToolResult;
const transcript_mod = @import("transcript.zig");
const tool_display_mod = @import("tool_display.zig");
const editor_iface_mod = @import("editor_iface.zig");
const markdown_mod = @import("components/markdown.zig");
const theme_mod = @import("theme.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const editor_mod = @import("components/editor.zig");

const Transcript = transcript_mod.Transcript;
const TranscriptRenderable = transcript_mod.TranscriptRenderable;
const ToolRendererResolver = tool_display_mod.ToolRendererResolver;
const EditorInterface = editor_iface_mod.EditorInterface;
const Theme = theme_mod.Theme;
const Markdown = markdown_mod.Markdown;
const Buffer = buffer_mod.Buffer;
const Color = cell_mod.Color;
const testing = std.testing;

pub const ApplyOptions = struct {
    theme: *const Theme,
    retry_attempt: u32 = 0,
};

const ExtractedText = union(enum) {
    borrowed: []const u8,
    owned: []u8,

    fn slice(self: ExtractedText) []const u8 {
        return switch (self) {
            .borrowed => |text| text,
            .owned => |text| text,
        };
    }

    fn deinit(self: ExtractedText, allocator: std.mem.Allocator) void {
        switch (self) {
            .borrowed => {},
            .owned => |text| allocator.free(text),
        }
    }
};

pub fn seedEditorHistory(editor: EditorInterface, messages: []const agent_protocol.AgentMessage) void {
    editor.clearHistory();
    for (messages) |message| {
        const text = extractUserMessageText(std.heap.page_allocator, message) orelse continue;
        defer text.deinit(std.heap.page_allocator);
        editor.addToHistory(text.slice());
    }
}

pub fn applySessionMessages(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    messages: []const agent_protocol.AgentMessage,
    options: ApplyOptions,
) void {
    for (messages) |message| {
        switch (message) {
            .user => {
                const text = extractUserMessageText(transcript.allocator, message) orelse continue;
                defer text.deinit(transcript.allocator);
                transcript.addUserMessage(text.slice());
            },
            .assistant => |assistant| applyAssistantMessage(transcript, resolver, assistant, options.retry_attempt),
            .tool_result => |tool_result| applyToolResultMessage(transcript, tool_result),
            .compaction_summary => |summary| addSummaryCard(transcript, options.theme, "Compaction summary", summary.summary),
            .branch_summary => |summary| addSummaryCard(transcript, options.theme, "Branch summary", summary.summary),
            .custom => |custom| {
                if (custom.display) {
                    addCustomMessage(transcript, options.theme, custom) catch {};
                }
            },
        }
    }
    transcript.clearPendingToolRouting();
}

fn applyAssistantMessage(
    transcript: *Transcript,
    resolver: ToolRendererResolver,
    assistant: agent_protocol.AssistantMessage,
    retry_attempt: u32,
) void {
    transcript.beginAssistantMessage();
    for (assistant.content, 0..) |block, idx| {
        switch (block) {
            .text => |text| transcript.appendText(idx, text.text),
            .thinking => |thinking| transcript.appendThinking(idx, thinking.thinking),
            .tool_call => {},
        }
    }
    transcript.endAssistantMessage();

    for (assistant.content) |block| {
        if (block != .tool_call) continue;
        const tool_call = block.tool_call;
        const renderer = resolver.resolve(tool_call.name);
        transcript.addToolExecution(tool_call.id, tool_call.name, renderer);
        transcript.toolSetArgs(tool_call.id, tool_call.arguments);
        transcript.toolSetArgsComplete(tool_call.id);
        if (assistant.stop_reason == .aborted or assistant.stop_reason == .@"error") {
            applyFailedToolResult(transcript, tool_call.id, assistant, retry_attempt);
        }
    }
}

fn applyFailedToolResult(
    transcript: *Transcript,
    tool_call_id: []const u8,
    assistant: agent_protocol.AssistantMessage,
    retry_attempt: u32,
) void {
    var owned_abort_message: ?[]u8 = null;
    defer if (owned_abort_message) |message| transcript.allocator.free(message);

    const error_text = switch (assistant.stop_reason) {
        .aborted => blk: {
            if (retry_attempt == 0) break :blk "Operation aborted";
            owned_abort_message = std.fmt.allocPrint(
                transcript.allocator,
                "Aborted after {d} retry attempt{s}",
                .{ retry_attempt, if (retry_attempt == 1) "" else "s" },
            ) catch null;
            break :blk owned_abort_message orelse "Operation aborted";
        },
        .@"error" => assistant.error_message orelse "Error",
        else => return,
    };

    var content = [_]AgentToolResult.ContentBlock{
        .{ .text = .{ .text = error_text } },
    };
    transcript.toolSetFinalResult(tool_call_id, .{
        .content = &content,
        .is_error = true,
    }, true);
}

fn applyToolResultMessage(transcript: *Transcript, tool_result: agent_protocol.ToolResultMessage) void {
    const blocks = transcript.allocator.alloc(AgentToolResult.ContentBlock, tool_result.content.len) catch return;
    defer transcript.allocator.free(blocks);

    for (tool_result.content, 0..) |block, i| {
        blocks[i] = switch (block) {
            .text => |text| .{ .text = text },
            .image => |image| .{ .image = image },
        };
    }

    transcript.toolSetFinalResult(tool_result.tool_call_id, .{
        .content = blocks,
        .details = if (tool_result.details) |details| details else .null,
        .is_error = tool_result.is_error,
    }, tool_result.is_error);
}

fn extractUserMessageText(
    allocator: std.mem.Allocator,
    message: agent_protocol.AgentMessage,
) ?ExtractedText {
    switch (message) {
        .user => |user| return switch (user.content) {
            .text => |text| if (text.len == 0) null else .{ .borrowed = text },
            .blocks => |blocks| blk: {
                const joined = joinUserBlocksText(allocator, blocks) catch return null;
                if (joined.len == 0) {
                    allocator.free(joined);
                    break :blk null;
                }
                break :blk .{ .owned = joined };
            },
        },
        else => return null,
    }
}

fn addSummaryCard(transcript: *Transcript, theme: *const Theme, label: []const u8, summary: []const u8) void {
    const content = std.fmt.allocPrint(transcript.allocator, "**{s}**\n\n{s}", .{ label, summary }) catch return;
    defer transcript.allocator.free(content);
    addMarkdownCard(transcript, theme, content, theme.fg(.muted), Color.default);
}

fn addCustomMessage(
    transcript: *Transcript,
    theme: *const Theme,
    custom: agent_protocol.AgentMessage.CustomMessage,
) !void {
    const body = try customContentText(transcript.allocator, custom.content);
    defer transcript.allocator.free(body);
    if (body.len == 0) return;

    const content = try std.fmt.allocPrint(transcript.allocator, "**{s}**\n\n{s}", .{ custom.custom_type, body });
    defer transcript.allocator.free(content);
    addMarkdownCard(transcript, theme, content, theme.fg(.custom_message_text), theme.bg(.custom_message_bg));
}

fn addMarkdownCard(
    transcript: *Transcript,
    theme: *const Theme,
    content: []const u8,
    fg: Color,
    bg: Color,
) void {
    const md = transcript.allocator.create(Markdown) catch return;
    errdefer transcript.allocator.destroy(md);
    md.* = Markdown.init(transcript.allocator);
    md.theme = theme;
    md.padding_x = 1;
    md.padding_y = if (bg.eql(Color.default)) 0 else 1;
    md.fg = fg;
    md.bg = bg;
    md.setContent(content);

    if (!transcript.addItem(.{
        .renderable = TranscriptRenderable.init(Markdown, md),
        .extra_height = 1,
        .deinit_ctx = @ptrCast(md),
        .deinit_fn = deinitMarkdown,
    })) {
        md.deinit();
        transcript.allocator.destroy(md);
    }
}

fn deinitMarkdown(ctx: *anyopaque, allocator: std.mem.Allocator) void {
    const md: *Markdown = @ptrCast(@alignCast(ctx));
    md.deinit();
    allocator.destroy(md);
}

fn customContentText(
    allocator: std.mem.Allocator,
    content: agent_protocol.AgentMessage.CustomContent,
) ![]u8 {
    switch (content) {
        .text => |text| return allocator.dupe(u8, text),
        .blocks => |blocks| {
            var out: std.ArrayList(u8) = .empty;
            defer out.deinit(allocator);
            for (blocks, 0..) |block, idx| {
                if (idx > 0) try out.append(allocator, '\n');
                switch (block) {
                    .text => |text| try out.appendSlice(allocator, text.text),
                    .image => |image| try out.writer(allocator).print("[image: {s}]", .{image.mime_type}),
                }
            }
            return out.toOwnedSlice(allocator);
        },
    }
}

fn joinUserBlocksText(
    allocator: std.mem.Allocator,
    blocks: []const ai_protocol.UserMessage.UserMessageContent.Block,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);
    for (blocks) |block| {
        switch (block) {
            .text => |text| try out.appendSlice(allocator, text.text),
            .image => {},
        }
    }
    return out.toOwnedSlice(allocator);
}

fn renderTranscriptText(allocator: std.mem.Allocator, transcript: *Transcript, width: u32) ![]u8 {
    const height = @max(@as(u32, 1), transcript.totalHeight(width));
    var buf = try Buffer.init(allocator, width, height);
    defer buf.deinit();
    transcript.render(buf.region());

    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(allocator);

    var row: u32 = 0;
    while (row < height) : (row += 1) {
        if (row > 0) try out.append(allocator, '\n');
        var end = width;
        while (end > 0 and buf.get(end - 1, row).grapheme.codepoint == ' ') : (end -= 1) {}
        var col: u32 = 0;
        while (col < end) : (col += 1) {
            try out.append(allocator, @intCast(buf.get(col, row).grapheme.codepoint));
        }
    }

    return out.toOwnedSlice(allocator);
}

fn makeUserMessage(text: []const u8) agent_protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .text = text },
        .timestamp = 1,
    } };
}

fn makeUserBlocksMessage(blocks: []const ai_protocol.UserMessage.UserMessageContent.Block) agent_protocol.AgentMessage {
    return .{ .user = .{
        .content = .{ .blocks = blocks },
        .timestamp = 1,
    } };
}

fn makeAssistantMessage(
    content: []const agent_protocol.AssistantMessage.AssistantContentBlock,
    stop_reason: agent_protocol.StopReason,
    error_message: ?[]const u8,
) agent_protocol.AgentMessage {
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
        .stop_reason = stop_reason,
        .error_message = error_message,
        .timestamp = 1,
    } };
}

fn makeToolResultMessage(
    tool_call_id: []const u8,
    tool_name: []const u8,
    content: []const agent_protocol.ToolResultMessage.ContentBlock,
    is_error: bool,
) agent_protocol.AgentMessage {
    return .{ .tool_result = .{
        .tool_call_id = tool_call_id,
        .tool_name = tool_name,
        .content = content,
        .is_error = is_error,
        .timestamp = 1,
    } };
}

test "resumed session reconstructs tool call rows and tool results" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const tool_call = agent_protocol.ToolCall{ .id = "tc-1", .name = "bash", .arguments = .null };
    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "running bash" } },
        .{ .tool_call = tool_call },
    };
    const tool_result_content = [_]agent_protocol.ToolResultMessage.ContentBlock{
        .{ .text = .{ .text = "done" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeUserMessage("do it"),
        makeAssistantMessage(&assistant_content, .toolUse, null),
        makeToolResultMessage("tc-1", "bash", &tool_result_content, false),
    };

    seedEditorHistory(EditorInterface.init(editor_mod.Editor, &editor), &messages);
    applySessionMessages(&transcript, tool_display_mod.empty_resolver, &messages, .{ .theme = &Theme.dark });

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("do it", editor.history.items[0]);
    try testing.expectEqual(@as(usize, 3), transcript.items.items.len);
    try testing.expectEqual(@as(usize, 0), transcript.pending_tools.count());

    const tool_item = transcript.items.items[2];
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(tool_item.deinit_ctx.?));
    try testing.expect(tool.args_complete);
    try testing.expect(!tool.is_partial);
    try testing.expect(!tool.is_error);
    try testing.expect(tool.result != null);
    try testing.expectEqualStrings("done", tool.result.?.content[0].text.text);
}

test "resumed session preserves assistant text thinking and tool call ordering" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .text = .{ .text = "alpha" } },
        .{ .thinking = .{ .thinking = "ponder" } },
        .{ .tool_call = .{ .id = "tc-1", .name = "read", .arguments = .null } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .toolUse, null),
    };

    applySessionMessages(&transcript, tool_display_mod.empty_resolver, &messages, .{ .theme = &Theme.dark });

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 40);
    defer testing.allocator.free(rendered);

    const alpha_idx = std.mem.indexOf(u8, rendered, "alpha") orelse return error.MissingAssistantText;
    const ponder_idx = std.mem.indexOf(u8, rendered, "ponder") orelse return error.MissingThinkingText;
    const tool_idx = std.mem.indexOf(u8, rendered, "read") orelse return error.MissingToolRow;
    try testing.expect(alpha_idx < ponder_idx);
    try testing.expect(ponder_idx < tool_idx);
}

test "resumed aborted assistant renders failed tool rows" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    const assistant_content = [_]agent_protocol.AssistantMessage.AssistantContentBlock{
        .{ .tool_call = .{ .id = "tc-1", .name = "bash", .arguments = .null } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeAssistantMessage(&assistant_content, .aborted, null),
    };

    applySessionMessages(&transcript, tool_display_mod.empty_resolver, &messages, .{
        .theme = &Theme.dark,
        .retry_attempt = 0,
    });

    try testing.expectEqual(@as(usize, 1), transcript.items.items.len);
    const tool: *transcript_mod.ToolExecution = @ptrCast(@alignCast(transcript.items.items[0].deinit_ctx.?));
    try testing.expect(tool.args_complete);
    try testing.expect(tool.is_error);
    try testing.expect(!tool.is_partial);
    try testing.expect(tool.result != null);
    try testing.expectEqualStrings("Operation aborted", tool.result.?.content[0].text.text);
}

test "resumed session includes summaries displayable custom messages and editor history" {
    var transcript = Transcript.init(testing.allocator);
    defer transcript.deinit();

    var editor = editor_mod.Editor.init(testing.allocator);
    defer editor.deinit();

    const user_blocks = [_]ai_protocol.UserMessage.UserMessageContent.Block{
        .{ .text = .{ .text = "hello" } },
        .{ .image = .{ .data = "abc", .mime_type = "image/png" } },
        .{ .text = .{ .text = " world" } },
    };
    const messages = [_]agent_protocol.AgentMessage{
        makeUserBlocksMessage(&user_blocks),
        .{ .compaction_summary = .{ .summary = "kept the recent turns", .tokens_before = 42, .timestamp = 1 } },
        .{ .branch_summary = .{ .summary = "previous branch summary", .from_id = "branch-1", .timestamp = 1 } },
        .{ .custom = .{
            .custom_type = "demo",
            .content = .{ .text = "shown custom" },
            .display = true,
            .timestamp = 1,
        } },
        .{ .custom = .{
            .custom_type = "hidden",
            .content = .{ .text = "do not show" },
            .display = false,
            .timestamp = 1,
        } },
    };

    seedEditorHistory(EditorInterface.init(editor_mod.Editor, &editor), &messages);
    applySessionMessages(&transcript, tool_display_mod.empty_resolver, &messages, .{ .theme = &Theme.dark });

    try testing.expectEqual(@as(usize, 1), editor.history.items.len);
    try testing.expectEqualStrings("hello world", editor.history.items[0]);

    const rendered = try renderTranscriptText(testing.allocator, &transcript, 60);
    defer testing.allocator.free(rendered);

    try testing.expect(std.mem.indexOf(u8, rendered, "kept the recent turns") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "previous branch summary") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "shown custom") != null);
    try testing.expect(std.mem.indexOf(u8, rendered, "do not show") == null);
}
