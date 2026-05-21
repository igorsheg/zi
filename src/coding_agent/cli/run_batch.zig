const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent = @import("../../agent/root.zig");
const coding_agent = @import("../root.zig");
const plan_mod = @import("plan.zig");
const result_mod = @import("result.zig");
const cli_runtime = @import("runtime.zig");
const message_memory = @import("../../agent/message_memory.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: ?*cli_runtime.Runtime = null,
};

const EventCapture = struct {
    terminal: ?coding_agent.event.RunTerminal = null,
    saw_tool: bool = false,

    fn emit(event: coding_agent.event.Event, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        switch (event) {
            .run => |run_event| switch (run_event) {
                .tool_started, .tool_updated, .tool_finished => self.saw_tool = true,
                .finished => |finished| self.terminal = finished.terminal,
                else => {},
            },
            else => {},
        }
    }
};

pub fn run(ctx: Context, run_plan: plan_mod.RunPlan) !result_mod.ExecutionResult {
    var builtins: ?coding_agent.builtin_tools.Builtins = null;
    // extension_host contains tool ctx pointers into builtins. AgentSession owns
    // and deinits the host, so session.deinit must run before builtins.deinit.
    defer if (builtins) |*bundle| bundle.deinit();
    const extension_host = if (run_plan.tools == .builtins) blk: {
        builtins = try coding_agent.builtin_tools.Builtins.init(ctx.allocator, .{ .bash = .{ .io = ctx.io } });
        break :blk try builtins.?.host(ctx.allocator);
    } else coding_agent.extension.Host.disabled;

    var events = EventCapture{};
    var demo_backend = DemoBackend{ .prompt = run_plan.prompt };
    const resolved = switch (try resolveExecution(ctx, run_plan, &demo_backend)) {
        .ok => |ok| ok,
        .err => |diag| return .{ .err = diag },
    };
    var session = try coding_agent.AgentSession.init(ctx.allocator, .{
        .event_sink = .{ .emit_fn = EventCapture.emit, .ctx = &events },
        .extension_host = extension_host,
        .policy = .{ .model = resolved.model },
        .execution = .{ .synchronous = resolved.backend },
    });
    defer session.deinit();

    const user = agent.AgentMessage{ .user = .{ .content = .{ .text = run_plan.prompt }, .timestamp = 0 } };
    const submit = try session.submit(.{ .submit_prompt = .{ .messages = &.{user} } });
    if (submit != .accepted) return .{ .err = .submit_rejected };
    session.drainCommands();

    const terminal = events.terminal orelse return .{ .err = .run_failed };
    switch (run_plan.output) {
        .jsonl_events => try writeJsonLine(ctx, terminal, events.saw_tool),
        .text, .final_text => try writeText(ctx, terminal, events.saw_tool),
    }
    return switch (terminal) {
        .completed => .ok,
        .failed, .aborted => .{ .err = .run_failed },
    };
}

const ResolvedExecution = struct {
    model: agent.message.Model,
    backend: coding_agent.AgentSession.ExecutionBackend,
};

const ResolveExecutionResult = union(enum) {
    ok: ResolvedExecution,
    err: result_mod.Diagnostic,
};

fn resolveExecution(ctx: Context, run_plan: plan_mod.RunPlan, demo_backend: *DemoBackend) !ResolveExecutionResult {
    const model_ref = run_plan.model orelse return .{
        .ok = .{
            .model = demoModel("demo"),
            .backend = .{
            .stream = .{ .call_fn = DemoBackend.stream, .ctx = demo_backend },
            .convert_messages = .{ .call_fn = convertMessages },
            .io = ctx.io,
            },
        },
    };

    const runtime = ctx.runtime orelse return .{ .err = .missing_model };
    const model = switch (runtime.resolveModel(model_ref)) {
        .ok => |model| model,
        .unknown_model => return .{ .err = .unknown_model },
        .invalid_settings_model => |diag| return .{ .err = .{ .invalid_settings_model = diag } },
    };
    const backend = runtime.executionBackend(model) catch |err| switch (err) {
        error.ProviderUnavailable => return .{ .err = .provider_unavailable },
        error.MissingApiKey => return .{ .err = .missing_api_key },
    };
    return .{ .ok = .{ .model = model, .backend = backend } };
}

fn writeText(ctx: Context, terminal: coding_agent.event.RunTerminal, saw_tool: bool) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    switch (terminal) {
        .completed => try writer.interface.print("completed{s}\n", .{if (saw_tool) " with tools" else ""}),
        .aborted => try writer.interface.writeAll("aborted\n"),
        .failed => |kind| try writer.interface.print("failed: {s}\n", .{@tagName(kind)}),
    }
    try writer.interface.flush();
}

fn writeJsonLine(ctx: Context, terminal: coding_agent.event.RunTerminal, saw_tool: bool) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    try writer.interface.print("{{\"terminal\":\"{s}\",\"saw_tool\":{s}}}\n", .{ terminalName(terminal), if (saw_tool) "true" else "false" });
    try writer.interface.flush();
}

fn terminalName(terminal: coding_agent.event.RunTerminal) []const u8 {
    return switch (terminal) { .completed => "completed", .aborted => "aborted", .failed => "failed" };
}

const DemoBackend = struct {
    prompt: []const u8,

    fn stream(ctx: ?*anyopaque, allocator: std.mem.Allocator, model: agent.message.Model, context: ai.protocol.Context, _: ai.protocol.SimpleStreamOptions, sink: ai.provider.StreamEventSink) error{OutOfMemory}!void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        _ = model;
        if (lastToolResult(context)) |tool_result| {
            const text = if (tool_result.content.len > 0 and tool_result.content[0] == .text) tool_result.content[0].text.text else "tool completed";
            const assistant = try assistantText(allocator, text, .stop);
            defer message_memory.freeAssistant(allocator, assistant);
            sink.emit(.{ .done = .{ .reason = .stop, .message = assistant } });
            return;
        }
        if (std.mem.startsWith(u8, self.prompt, "bash:")) {
            const cmd = std.mem.trim(u8, self.prompt[5..], " \t");
            const assistant = try assistantToolCall(allocator, cmd);
            defer message_memory.freeAssistant(allocator, assistant);
            sink.emit(.{ .done = .{ .reason = .toolUse, .message = assistant } });
            return;
        }
        const assistant = try assistantText(allocator, "demo response", .stop);
        defer message_memory.freeAssistant(allocator, assistant);
        sink.emit(.{ .done = .{ .reason = .stop, .message = assistant } });
    }
};

fn lastToolResult(context: ai.protocol.Context) ?ai.protocol.ToolResultMessage {
    if (context.messages.len == 0) return null;
    return switch (context.messages[context.messages.len - 1]) { .tool_result => |tool| tool, else => null };
}

fn convertMessages(_: ?*anyopaque, allocator: std.mem.Allocator, messages: []const agent.AgentMessage) error{OutOfMemory}![]const ai.protocol.Message {
    const out = try allocator.alloc(ai.protocol.Message, messages.len);
    for (messages, 0..) |message, i| out[i] = switch (message) {
        .user => |user| .{ .user = user },
        .assistant => |assistant| .{ .assistant = assistant },
        .tool_result => |tool| .{ .tool_result = tool },
        else => std.debug.panic("unsupported message type in CLI demo backend", .{}),
    };
    return out;
}

fn assistantText(allocator: std.mem.Allocator, text: []const u8, reason: ai.protocol.StopReason) !ai.protocol.AssistantMessage {
    const blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    blocks[0] = .{ .text = .{ .text = try allocator.dupe(u8, text) } };
    return try baseAssistant(allocator, blocks, reason);
}

fn assistantToolCall(allocator: std.mem.Allocator, cmd: []const u8) !ai.protocol.AssistantMessage {
    var args_obj: std.json.ObjectMap = .{};
    try args_obj.put(allocator, try allocator.dupe(u8, "cmd"), .{ .string = try allocator.dupe(u8, cmd) });
    const blocks = try allocator.alloc(ai.protocol.AssistantMessage.AssistantContentBlock, 1);
    blocks[0] = .{ .tool_call = .{ .id = try allocator.dupe(u8, "cli-bash-1"), .name = try allocator.dupe(u8, "bash"), .arguments = @import("../../json/value.zig").OwnedValue.adopt(allocator, .{ .object = args_obj }) } };
    return try baseAssistant(allocator, blocks, .toolUse);
}

fn baseAssistant(allocator: std.mem.Allocator, blocks: []const ai.protocol.AssistantMessage.AssistantContentBlock, reason: ai.protocol.StopReason) !ai.protocol.AssistantMessage {
    return .{ .content = blocks, .api = .openai_responses, .provider = .openai, .model = try allocator.dupe(u8, "demo"), .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, .stop_reason = reason, .timestamp = 0 };
}

fn demoModel(id: []const u8) agent.message.Model {
    return .{ .id = id, .name = id, .api = .openai_responses, .provider = .openai, .base_url = "", .reasoning = false, .input = &.{}, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 }, .context_window = 0, .max_tokens = 0 };
}
