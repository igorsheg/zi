const std = @import("std");
const ai = @import("../../ai/root.zig");
const agent_json = ai.event_json;
const agent = @import("../../agent/root.zig");
const coding_agent = @import("../root.zig");
const session_mod = @import("../session.zig");
const provider_runtime_mod = @import("../provider_runtime.zig");
const plan_mod = @import("plan.zig");
const result_mod = @import("result.zig");

const final_text_size_max: usize = 1024 * 1024;

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_runtime: ?*provider_runtime_mod.ProviderRuntime = null,
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
                .message_end => |message_end| switch (message_end.message) {
                    .assistant => |assistant| self.captureAssistantText(assistant),
                    else => {},
                },
                .tool_execution_start, .tool_execution_update, .tool_execution_end => self.saw_tool = true,
                .agent_end => |terminal| self.terminal = terminalStatus(terminal),
                else => {},
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
    var session = switch (try session_mod.AgentSession.initManaged(.{
        .allocator = ctx.allocator,
        .io = ctx.io,
        .provider_runtime = ctx.provider_runtime,
        .model = run_plan.model,
        .tools = toolsMode(run_plan.tools),
        .event_sink = .{ .emit_fn = EventCapture.emit, .ctx = &events },
        .demo_prompt = run_plan.prompt,
    })) {
        .ok => |created| created,
        .err => |diag| return .{ .err = sessionDiagnostic(diag) },
    };
    defer session.deinit();

    const user = agent.AgentMessage{ .user = .{ .content = .{ .text = run_plan.prompt }, .timestamp = 0 } };
    const submit = try session.submit(.{ .submit_prompt = .{ .messages = &.{user} } });
    if (submit != .accepted) return .{ .err = .submit_rejected };
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
    return switch (terminal) {
        .completed => "completed",
        .aborted => "aborted",
        .failed => "failed",
    };
}

fn terminalStatus(terminal: ai.protocol.AgentEnd) EventCapture.TerminalStatus {
    return switch (terminal) {
        .completed => .completed,
        .failed => .failed,
        .aborted => .aborted,
    };
}

fn toolsMode(value: plan_mod.ToolsMode) session_mod.ToolsMode {
    return switch (value) {
        .none => .none,
        .builtins => .builtins,
    };
}

fn sessionDiagnostic(value: session_mod.Diagnostic) result_mod.Diagnostic {
    return switch (value) {
        .missing_model => .missing_model,
        .unknown_model => .unknown_model,
        .invalid_settings_model => |diag| .{ .invalid_settings_model = diag },
        .provider_unavailable => .provider_unavailable,
        .missing_api_key => .missing_api_key,
    };
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
