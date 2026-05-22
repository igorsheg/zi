const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent_json = @import("../../agent/json.zig");
const agent = @import("../../agent/root.zig");
const coding_agent = @import("../root.zig");
const provider_runtime = @import("../provider_runtime.zig");
const plan_mod = @import("plan.zig");
const result_mod = @import("result.zig");
const message_memory = @import("../../agent/message_memory.zig");

const final_text_size_max: usize = 1024 * 1024;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    runtime: ?*provider_runtime.ProviderRuntime = null,
};

const EventCapture = struct {
    allocator: std.mem.Allocator,
    output: Output,
    terminal: ?TerminalStatus = null,
    saw_tool: bool = false,

    const Output = union(enum) {
        final_text: FinalTextOutput,
        jsonl_events: JsonlOutput,

        fn deinit(self: *Output, allocator: std.mem.Allocator) void {
            switch (self.*) {
                .final_text => |*final_text| final_text.deinit(allocator),
                .jsonl_events => {},
            }
        }
    };

    const TerminalStatus = enum {
        completed,
        failed,
        aborted,
    };

    const FinalTextOutput = struct {
        text: std.ArrayList(u8) = .empty,
        out_of_memory: bool = false,
        too_large: bool = false,

        fn deinit(self: *FinalTextOutput, allocator: std.mem.Allocator) void {
            self.text.deinit(allocator);
            self.* = undefined;
        }
    };

    const JsonlOutput = struct {
        writer: *std.Io.Writer,
        write_failed: bool = false,
    };

    fn deinit(self: *EventCapture) void {
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    fn emit(event: coding_agent.event.Event, ctx: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.writeJsonLine(event);
        switch (event) {
            .agent => |agent_event| switch (agent_event) {
                .message => |message_event| switch (message_event) {
                    .finished => |assistant| self.captureAssistantText(assistant),
                    else => {},
                },
                .tool => self.saw_tool = true,
                .lifecycle => |lifecycle| switch (lifecycle) {
                    .run_finished => |terminal| self.terminal = terminalStatus(terminal),
                    else => {},
                },
            },
            else => {},
        }
    }

    fn writeJsonLine(self: *EventCapture, event: coding_agent.event.Event) void {
        if (self.output != .jsonl_events) return;
        switch (event) {
            .agent => |agent_event| return self.writeAgentJson(agent_event),
            .command => |command_event| switch (command_event) {
                .accepted => self.writeJson("{{\"type\":\"command.accepted\"}}\n", .{}),
                .rejected => self.writeJson("{{\"type\":\"command.rejected\"}}\n", .{}),
            },
            .control => |control_event| switch (control_event) {
                .follow_up_queued => self.writeJson("{{\"type\":\"control.follow_up_queued\"}}\n", .{}),
                .abort_requested => self.writeJson("{{\"type\":\"control.abort_requested\"}}\n", .{}),
            },
            .session => |session_event| switch (session_event) {
                .appended => self.writeJson("{{\"type\":\"session.appended\"}}\n", .{}),
                .append_rejected => self.writeJson("{{\"type\":\"session.append_rejected\"}}\n", .{}),
                .append_failed => self.writeJson("{{\"type\":\"session.append_failed\"}}\n", .{}),
            },
        }
    }

    fn writeJson(self: *EventCapture, comptime format: []const u8, args: anytype) void {
        std.debug.assert(self.output == .jsonl_events);
        const jsonl = &self.output.jsonl_events;
        jsonl.writer.print(format, args) catch {
            jsonl.write_failed = true;
            return;
        };
        jsonl.writer.flush() catch {
            jsonl.write_failed = true;
        };
    }

    fn writeAgentJson(self: *EventCapture, agent_event: agent.AgentEvent) void {
        std.debug.assert(self.output == .jsonl_events);
        const jsonl = &self.output.jsonl_events;
        var jw: std.json.Stringify = .{ .writer = jsonl.writer };
        agent_json.writeEvent(&jw, agent_event) catch {
            jsonl.write_failed = true;
            return;
        };
        jsonl.writer.writeAll("\n") catch {
            jsonl.write_failed = true;
            return;
        };
        jsonl.writer.flush() catch {
            jsonl.write_failed = true;
        };
    }

    fn captureAssistantText(self: *EventCapture, assistant: agent.message.AssistantMessage) void {
        if (self.output != .final_text) return;
        for (assistant.content) |block| switch (block) {
            .text => |text| self.appendFinalText(text.text),
            else => {},
        };
    }

    fn appendFinalText(self: *EventCapture, text: []const u8) void {
        std.debug.assert(self.output == .final_text);
        const final_text = &self.output.final_text;
        if (final_text.too_large) return;
        if (text.len > final_text_size_max - final_text.text.items.len) {
            final_text.too_large = true;
            return;
        }
        final_text.text.appendSlice(self.allocator, text) catch {
            final_text.out_of_memory = true;
        };
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

    var jsonl_buf: [1024]u8 = undefined;
    var jsonl_file_writer = std.Io.File.stdout().writerStreaming(ctx.io, &jsonl_buf);
    var events = EventCapture{
        .allocator = ctx.allocator,
        .output = switch (run_plan.output) {
            .final_text => .{ .final_text = .{} },
            .jsonl_events => .{ .jsonl_events = .{ .writer = &jsonl_file_writer.interface } },
        },
    };
    defer events.deinit();
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
    switch (events.output) {
        .jsonl_events => |jsonl| if (jsonl.write_failed) return .{ .err = .run_failed },
        .final_text => |final_text| {
            if (final_text.out_of_memory) return error.OutOfMemory;
            if (final_text.too_large) return .{ .err = .final_text_too_large };
        },
    }

    const terminal = events.terminal orelse return .{ .err = .run_failed };
    if (terminal != .completed) return .{ .err = .run_failed };
    switch (run_plan.output) {
        .jsonl_events => {},
        .final_text => try writeFinalText(ctx, events.output.final_text.text.items),
    }
    return .ok;
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

fn writeFinalText(ctx: Context, text: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(ctx.io, &buf);
    try writeFinalTextToWriter(&writer.interface, text);
    try writer.interface.flush();
}

fn writeFinalTextToWriter(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeAll(text);
    if (text.len == 0 or text[text.len - 1] != '\n') try writer.writeAll("\n");
}

fn terminalName(terminal: EventCapture.TerminalStatus) []const u8 {
    return switch (terminal) { .completed => "completed", .aborted => "aborted", .failed => "failed" };
}

fn terminalStatus(terminal: agent.event.RunTerminal) EventCapture.TerminalStatus {
    return switch (terminal) {
        .completed => .completed,
        .failed => .failed,
        .aborted => .aborted,
    };
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

test "batch capture accumulates assistant text within explicit bound" {
    var capture = EventCapture{ .allocator = std.testing.allocator, .output = .{ .final_text = .{} } };
    defer capture.deinit();

    const assistant = agent.message.AssistantMessage{
        .content = &.{ .{ .text = .{ .text = "hello" } }, .{ .text = .{ .text = " world" } } },
        .api = .openai_responses,
        .provider = .openai,
        .model = "demo",
        .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } },
        .stop_reason = .stop,
        .timestamp = 0,
    };

    capture.captureAssistantText(assistant);
    try std.testing.expect(!capture.output.final_text.out_of_memory);
    try std.testing.expect(!capture.output.final_text.too_large);
    try std.testing.expectEqualStrings("hello world", capture.output.final_text.text.items);
}

test "batch capture rejects final text beyond explicit bound" {
    var capture = EventCapture{ .allocator = std.testing.allocator, .output = .{ .final_text = .{} } };
    defer capture.deinit();

    try capture.output.final_text.text.appendNTimes(std.testing.allocator, 'x', final_text_size_max);
    capture.appendFinalText("x");

    try std.testing.expect(capture.output.final_text.too_large);
    try std.testing.expectEqual(@as(usize, final_text_size_max), capture.output.final_text.text.items.len);
}

test "final text writer appends missing trailing newline only" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();

    try writeFinalTextToWriter(&out.writer, "hello");
    try std.testing.expectEqualStrings("hello\n", out.written());

    out.clearRetainingCapacity();
    try writeFinalTextToWriter(&out.writer, "hello\n");
    try std.testing.expectEqualStrings("hello\n", out.written());
}
