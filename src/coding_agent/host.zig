const std = @import("std");
const ai = @import("../ai/root.zig");
const agent = @import("../agent/root.zig");
const message_memory = @import("../agent/message_memory.zig");
const json_value = @import("../json/value.zig");
const settings_resolve = @import("../settings/resolve.zig");
const builtin_tools = @import("builtin_tools.zig");
const event_mod = @import("event.zig");
const extension = @import("extension.zig");
const provider_backend = @import("provider_backend.zig");
const provider_runtime_mod = @import("provider_runtime.zig");
const session_mod = @import("session.zig");

pub const AgentHost = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_runtime: ?*provider_runtime_mod.ProviderRuntime = null,

    pub fn init(options: Options) AgentHost {
        return .{
            .allocator = options.allocator,
            .io = options.io,
            .provider_runtime = options.provider_runtime,
        };
    }

    pub fn createSession(self: *AgentHost, options: CreateSessionOptions) extension.InitError!CreateSessionResult {
        var bundle = SessionBundle{ .allocator = self.allocator };
        errdefer bundle.deinit();

        const extension_host = switch (options.tools) {
            .none => extension.Host.disabled,
            .builtins => blk: {
                bundle.builtins = try builtin_tools.Builtins.init(self.allocator, .{ .bash = .{ .io = self.io } });
                break :blk try bundle.builtins.?.host(self.allocator);
            },
        };

        const resolved = switch (try self.resolveExecution(options.model, options.demo_prompt, &bundle)) {
            .ok => |ok| ok,
            .err => |diag| return .{ .err = diag },
        };

        bundle.session = try session_mod.AgentSession.init(self.allocator, .{
            .event_sink = options.event_sink,
            .extension_host = extension_host,
            .policy = .{ .model = resolved.model },
            .execution = .{ .synchronous = resolved.backend },
        });

        return .{ .ok = bundle };
    }

    fn resolveExecution(self: *AgentHost, model_ref: ?[]const u8, demo_prompt: []const u8, bundle: *SessionBundle) error{OutOfMemory}!ResolveExecutionResult {
        const requested = model_ref orelse {
            bundle.demo_backend = try self.allocator.create(DemoBackend);
            bundle.demo_backend.?.* = .{ .prompt = demo_prompt };
            return .{ .ok = .{
                .model = demoModel("demo"),
                .backend = .{
                    .stream = .{ .call_fn = DemoBackend.stream, .ctx = bundle.demo_backend.? },
                    .convert_messages = .{ .call_fn = convertMessages },
                    .io = self.io,
                },
            } };
        };

        const runtime = self.provider_runtime orelse return .{ .err = .missing_model };
        const model = switch (runtime.resolveModel(requested)) {
            .ok => |model| model,
            .unknown_model => return .{ .err = .unknown_model },
            .invalid_settings_model => |diag| return .{ .err = .{ .invalid_settings_model = diag } },
        };
        const resolved_provider = runtime.resolveProvider(model) catch |err| switch (err) {
            error.ProviderUnavailable => return .{ .err = .provider_unavailable },
            error.MissingApiKey => return .{ .err = .missing_api_key },
        };
        bundle.provider = resolved_provider.provider;
        const backend = provider_backend.synchronous(&bundle.provider.?, .{
            .io = self.io,
            .api_key = resolved_provider.api_key,
            .transport = resolved_provider.transport,
        });
        return .{ .ok = .{ .model = model, .backend = backend } };
    }
};

pub const Options = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    provider_runtime: ?*provider_runtime_mod.ProviderRuntime = null,
};

pub const ToolsMode = enum { none, builtins };

pub const CreateSessionOptions = struct {
    model: ?[]const u8 = null,
    tools: ToolsMode = .builtins,
    event_sink: ?event_mod.Sink = null,
    demo_prompt: []const u8 = "",
};

pub const CreateSessionResult = union(enum) {
    ok: SessionBundle,
    err: Diagnostic,
};

pub const Diagnostic = union(enum) {
    missing_model,
    unknown_model,
    invalid_settings_model: settings_resolve.Diagnostic,
    provider_unavailable,
    missing_api_key,
};

pub const SessionBundle = struct {
    allocator: std.mem.Allocator,
    builtins: ?builtin_tools.Builtins = null,
    provider: ?ai.provider.Provider = null,
    demo_backend: ?*DemoBackend = null,
    session: ?session_mod.AgentSession = null,

    pub fn deinit(self: *SessionBundle) void {
        if (self.session) |*session| session.deinit();
        if (self.demo_backend) |demo_backend| self.allocator.destroy(demo_backend);
        if (self.builtins) |*builtins| builtins.deinit();
        self.* = undefined;
    }
};

const ResolvedExecution = struct {
    model: agent.message.Model,
    backend: session_mod.AgentSession.ExecutionBackend,
};

const ResolveExecutionResult = union(enum) {
    ok: ResolvedExecution,
    err: Diagnostic,
};

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
        else => std.debug.panic("unsupported message type in demo backend", .{}),
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
    blocks[0] = .{ .tool_call = .{ .id = try allocator.dupe(u8, "cli-bash-1"), .name = try allocator.dupe(u8, "bash"), .arguments = json_value.OwnedValue.adopt(allocator, .{ .object = args_obj }) } };
    return try baseAssistant(allocator, blocks, .toolUse);
}

fn baseAssistant(allocator: std.mem.Allocator, blocks: []const ai.protocol.AssistantMessage.AssistantContentBlock, reason: ai.protocol.StopReason) !ai.protocol.AssistantMessage {
    return .{ .content = blocks, .api = .openai_responses, .provider = .openai, .model = try allocator.dupe(u8, "demo"), .usage = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total_tokens = 0, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0, .total = 0 } }, .stop_reason = reason, .timestamp = 0 };
}

fn demoModel(id: []const u8) agent.message.Model {
    return .{ .id = id, .name = id, .api = .openai_responses, .provider = .openai, .base_url = "", .reasoning = false, .input = &.{}, .cost = .{ .input = 0, .output = 0, .cache_read = 0, .cache_write = 0 }, .context_window = 0, .max_tokens = 0 };
}
