const std = @import("std");
const ai_message = @import("../ai/message.zig");
const ai_model = @import("../ai/model.zig");
const Agent = @import("../agent/Agent.zig");
const agent_limits = @import("../agent/limits.zig");
const tool_api = @import("../agent/Tool.zig");
const ReadTool = @import("tools/ReadTool.zig");
const WriteTool = @import("tools/WriteTool.zig");
const EditTool = @import("tools/EditTool.zig");
const BashTool = @import("tools/BashTool.zig");

const AgentSession = @This();

pub const Event = Agent.Event;
pub const EventSink = Agent.EventSink;
pub const RunControl = Agent.RunControl;
pub const RunError = Agent.RunError;
pub const State = Agent.State;
pub const StreamEvent = Agent.StreamEvent;
pub const StreamSink = Agent.StreamSink;

const coding_instructions = [_][]const u8{
    "You are a coding agent. Inspect relevant files before drawing conclusions. " ++
        "Use read instead of cat, sed, or guessing file contents, and continue truncated reads with offset. " ++
        "Read an existing file before editing it. Use edit for precise changes, combine disjoint changes " ++
        "to one file in one call, keep each oldText small but unique and exact, and never overlap replacements. " ++
        "Use write only for new files or complete rewrites. Use bash for builds, tests, repository inspection, " ++
        "and commands. Bash calls are non-interactive and cannot create managed background jobs.",
};

const Tools = struct {
    read: ReadTool,
    write: WriteTool,
    edit: EditTool,
    bash: BashTool,
};

allocator: std.mem.Allocator,
tools: *Tools,
agent: Agent,

pub fn init(
    allocator: std.mem.Allocator,
    io: std.Io,
    model: ai_model.Model,
    cwd: std.Io.Dir,
    limits: agent_limits.RunLimits,
    events: ?Agent.EventSink,
) tool_api.Error!AgentSession {
    const tools = try allocator.create(Tools);
    errdefer allocator.destroy(tools);
    tools.* = .{
        .read = .{ .cwd = cwd },
        .write = .{ .cwd = cwd },
        .edit = .{ .cwd = cwd },
        .bash = .{ .cwd = cwd },
    };
    const admitted = [_]tool_api.Tool{
        tools.read.asTool(),
        tools.write.asTool(),
        tools.edit.asTool(),
        tools.bash.asTool(),
    };
    return .{
        .allocator = allocator,
        .tools = tools,
        .agent = try Agent.init(
            allocator,
            io,
            model,
            &coding_instructions,
            &admitted,
            limits,
            events,
        ),
    };
}

pub fn deinit(self: *AgentSession) void {
    self.agent.deinit();
    self.allocator.destroy(self.tools);
    self.* = undefined;
}

pub fn prompt(self: *AgentSession, input: []const u8) Agent.RunError![]const u8 {
    return self.agent.run(input);
}

pub fn promptWithControl(
    self: *AgentSession,
    input: []const u8,
    control: Agent.RunControl,
) Agent.RunError![]const u8 {
    return self.agent.runWithControl(input, control);
}

pub fn promptStream(
    self: *AgentSession,
    input: []const u8,
    sink: Agent.StreamSink,
) Agent.RunError![]const u8 {
    return self.agent.runStream(input, sink);
}

pub fn messages(self: *const AgentSession) []const ai_message.Message {
    return self.agent.messages();
}

pub fn state(self: *const AgentSession) Agent.State {
    return self.agent.state();
}

const ai_testing = @import("../ai/testing.zig");
const ai_stream = @import("../ai/stream.zig");

const IgnoreStream = struct {
    fn emit(_: *anyopaque, _: Agent.StreamEvent) ai_stream.StreamSinkError!void {}
};

const RequestRecorder = struct {
    count: usize = 0,
    instructions_valid: bool = true,
    write_result_seen: bool = false,
    read_result_seen: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *RequestRecorder = @ptrCast(@alignCast(context));
        self.count += 1;
        self.instructions_valid = self.instructions_valid and
            request.instructions.len == coding_instructions.len and
            std.mem.eql(u8, request.instructions[0], coding_instructions[0]);
        if (index != 1 and index != 2) return;
        for (request.messages) |entry| switch (entry) {
            .response => {},
            .request => |message| for (message.parts) |part| switch (part) {
                .user, .retry_prompt => {},
                .tool_result => |result| for (result.content) |content| switch (content) {
                    .image => {},
                    .text => |text| {
                        if (index == 1 and result.outcome == .success and
                            std.mem.eql(u8, result.name, "write") and
                            std.mem.eql(u8, text, "Successfully wrote 22 bytes to src/main.zig"))
                        {
                            self.write_result_seen = true;
                        }
                        if (index == 2 and result.outcome == .success and
                            std.mem.eql(u8, result.name, "read") and
                            std.mem.eql(u8, text, "pub fn main() void {}\n"))
                        {
                            self.read_result_seen = true;
                        }
                    },
                },
            },
        };
    }
};

const EditRequestRecorder = struct {
    count: usize = 0,
    instructions_valid: bool = true,
    original_seen: bool = false,
    edit_seen: bool = false,
    updated_seen: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *EditRequestRecorder = @ptrCast(@alignCast(context));
        self.count += 1;
        self.instructions_valid = self.instructions_valid and
            request.instructions.len == coding_instructions.len and
            std.mem.eql(u8, request.instructions[0], coding_instructions[0]);
        for (request.messages) |entry| switch (entry) {
            .response => {},
            .request => |message| for (message.parts) |part| switch (part) {
                .user, .retry_prompt => {},
                .tool_result => |result| for (result.content) |content| switch (content) {
                    .image => {},
                    .text => |text| {
                        if (index == 1 and result.outcome == .success and
                            std.mem.eql(u8, result.name, "read") and
                            std.mem.eql(u8, text, "const enabled = false;\n"))
                        {
                            self.original_seen = true;
                        }
                        if (index == 2 and result.outcome == .success and
                            std.mem.eql(u8, result.name, "edit") and
                            std.mem.eql(u8, text, "Successfully replaced 1 block(s) in config.zig."))
                        {
                            self.edit_seen = true;
                        }
                        if (index == 3 and result.outcome == .success and
                            std.mem.eql(u8, result.name, "read") and
                            std.mem.eql(u8, text, "const enabled = true;\n"))
                        {
                            self.updated_seen = true;
                        }
                    },
                },
            },
        };
    }
};

test "coding-agent session writes and reads a workspace file before a later prompt" {
    var request_recorder: RequestRecorder = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "coding-write-read" },
        .steps = &.{
            .{ .tool_call = .{
                .id = "call-1",
                .name = "write",
                .arguments_json = "{\"path\":\"src/main.zig\",\"content\":\"pub fn main() void {}\\n\"}",
            } },
            .{ .tool_call = .{
                .id = "call-2",
                .name = "read",
                .arguments_json = "{\"path\":\"src/main.zig\"}",
            } },
            .{ .text = "Created and verified the entrypoint." },
            .{ .text = "No additional work." },
        },
        .request_observer = .{ .context = &request_recorder, .observeFn = RequestRecorder.observe },
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var sink_context: u8 = 0;

    const text = try session.promptStream("Create and verify the entrypoint.", .{
        .context = &sink_context,
        .emitFn = IgnoreStream.emit,
    });

    try std.testing.expectEqualStrings("Created and verified the entrypoint.", text);
    try std.testing.expect(request_recorder.instructions_valid);
    try std.testing.expect(request_recorder.write_result_seen);
    try std.testing.expect(request_recorder.read_result_seen);
    try std.testing.expectEqual(@as(usize, 3), request_recorder.count);
    try std.testing.expect(session.state() == .completed);
    try std.testing.expectEqual(@as(usize, 6), session.messages().len);
    try std.testing.expectEqualStrings(
        "Successfully wrote 22 bytes to src/main.zig",
        session.messages()[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings(
        "pub fn main() void {}\n",
        session.messages()[4].request.parts[0].tool_result.content[0].text,
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "src/main.zig",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("pub fn main() void {}\n", bytes);

    const follow_up = try session.prompt("Anything else?");
    try std.testing.expectEqualStrings("No additional work.", follow_up);
    try std.testing.expect(request_recorder.instructions_valid);
    try std.testing.expectEqual(@as(usize, 4), request_recorder.count);
    const history = session.messages();
    try std.testing.expectEqual(@as(usize, 8), history.len);
    try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[0]));
    try std.testing.expectEqualStrings("Create and verify the entrypoint.", history[0].request.parts[0].user.text);
    try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[1]));
    try std.testing.expectEqualStrings("write", history[1].response.parts[0].tool_call.name);
    try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[2]));
    try std.testing.expectEqualStrings("write", history[2].request.parts[0].tool_result.name);
    try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[3]));
    try std.testing.expectEqualStrings("read", history[3].response.parts[0].tool_call.name);
    try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[4]));
    try std.testing.expectEqualStrings("read", history[4].request.parts[0].tool_result.name);
    try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[5]));
    try std.testing.expectEqualStrings(
        "Created and verified the entrypoint.",
        history[5].response.parts[0].text.text,
    );
    try std.testing.expectEqual(ai_message.Message.request, std.meta.activeTag(history[6]));
    try std.testing.expectEqualStrings("Anything else?", history[6].request.parts[0].user.text);
    try std.testing.expectEqual(ai_message.Message.response, std.meta.activeTag(history[7]));
    try std.testing.expectEqualStrings("No additional work.", history[7].response.parts[0].text.text);
}

fn cancelAfterBashStarts(
    io: std.Io,
    cwd: std.Io.Dir,
    token: *ai_model.CancellationToken,
) !void {
    const delay: std.Io.Timeout = .{ .duration = .{
        .raw = .fromMilliseconds(1),
        .clock = .awake,
    } };
    while (true) {
        cwd.access(io, "started", .{}) catch |failure| switch (failure) {
            error.FileNotFound => {
                try delay.sleep(io);
                continue;
            },
            else => return failure,
        };
        token.cancel();
        return;
    }
}

const BashRequestRecorder = struct {
    count: usize = 0,
    instructions_valid: bool = true,
    result_seen: bool = false,

    fn observe(context: *anyopaque, index: usize, request: ai_model.ModelRequest) void {
        const self: *BashRequestRecorder = @ptrCast(@alignCast(context));
        self.count += 1;
        self.instructions_valid = self.instructions_valid and
            request.instructions.len == coding_instructions.len and
            std.mem.eql(u8, request.instructions[0], coding_instructions[0]);
        if (index != 1) return;
        for (request.messages) |entry| switch (entry) {
            .response => {},
            .request => |message| for (message.parts) |part| switch (part) {
                .user, .retry_prompt => {},
                .tool_result => |result| for (result.content) |content| switch (content) {
                    .image => {},
                    .text => |text| if (result.outcome == .success and
                        std.mem.eql(u8, result.name, "bash") and
                        std.mem.eql(u8, text, "cwd-ok\n\nCommand exited with code 0"))
                    {
                        self.result_seen = true;
                    },
                },
            },
        };
    }
};

test "coding-agent session reads, edits, and verifies an existing file" {
    var request_recorder: EditRequestRecorder = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "config.zig",
        .data = "const enabled = false;\n",
    });
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "coding-edit" },
        .steps = &.{
            .{ .tool_call = .{
                .id = "call-1",
                .name = "read",
                .arguments_json = "{\"path\":\"config.zig\"}",
            } },
            .{ .tool_call = .{
                .id = "call-2",
                .name = "edit",
                .arguments_json = "{\"path\":\"config.zig\",\"edits\":[" ++
                    "{\"oldText\":\"false\",\"newText\":\"true\"}]}",
            } },
            .{ .tool_call = .{
                .id = "call-3",
                .name = "read",
                .arguments_json = "{\"path\":\"config.zig\"}",
            } },
            .{ .text = "Enabled and verified the configuration." },
        },
        .request_observer = .{ .context = &request_recorder, .observeFn = EditRequestRecorder.observe },
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();

    const text = try session.prompt("Enable the configuration.");
    try std.testing.expectEqualStrings("Enabled and verified the configuration.", text);
    try std.testing.expect(request_recorder.instructions_valid);
    try std.testing.expect(request_recorder.original_seen);
    try std.testing.expect(request_recorder.edit_seen);
    try std.testing.expect(request_recorder.updated_seen);
    try std.testing.expectEqual(@as(usize, 4), request_recorder.count);
    const history = session.messages();
    try std.testing.expectEqual(@as(usize, 8), history.len);
    try std.testing.expectEqualStrings("call-1", history[1].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("read", history[1].response.parts[0].tool_call.name);
    try std.testing.expect(history[2].request.parts[0].tool_result.outcome == .success);
    try std.testing.expectEqualStrings("call-1", history[2].request.parts[0].tool_result.call_id);
    try std.testing.expectEqualStrings(
        "const enabled = false;\n",
        history[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings("call-2", history[3].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("edit", history[3].response.parts[0].tool_call.name);
    try std.testing.expect(history[4].request.parts[0].tool_result.outcome == .success);
    try std.testing.expectEqualStrings("call-2", history[4].request.parts[0].tool_result.call_id);
    try std.testing.expectEqualStrings(
        "Successfully replaced 1 block(s) in config.zig.",
        history[4].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings("call-3", history[5].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("read", history[5].response.parts[0].tool_call.name);
    try std.testing.expect(history[6].request.parts[0].tool_result.outcome == .success);
    try std.testing.expectEqualStrings("call-3", history[6].request.parts[0].tool_result.call_id);
    try std.testing.expectEqualStrings(
        "const enabled = true;\n",
        history[6].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings(
        "Enabled and verified the configuration.",
        history[7].response.parts[0].text.text,
    );
    const bytes = try temporary.dir.readFileAlloc(
        std.testing.io,
        "config.zig",
        std.testing.allocator,
        .unlimited,
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("const enabled = true;\n", bytes);
}

test "coding-agent session executes bash in the workspace and continues" {
    var request_recorder: BashRequestRecorder = .{};
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "marker", .data = "" });
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "coding-bash" },
        .steps = &.{
            .{ .tool_call = .{
                .id = "call-1",
                .name = "bash",
                .arguments_json = "{\"command\":\"test -f marker && printf cwd-ok\"}",
            } },
            .{ .text = "The workspace command passed." },
        },
        .request_observer = .{ .context = &request_recorder, .observeFn = BashRequestRecorder.observe },
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();

    const text = try session.prompt("Verify the workspace marker.");
    try std.testing.expectEqualStrings("The workspace command passed.", text);
    try std.testing.expect(request_recorder.instructions_valid);
    try std.testing.expect(request_recorder.result_seen);
    try std.testing.expectEqual(@as(usize, 2), request_recorder.count);
    const history = session.messages();
    try std.testing.expectEqual(@as(usize, 4), history.len);
    try std.testing.expectEqualStrings("call-1", history[1].response.parts[0].tool_call.id);
    try std.testing.expectEqualStrings("bash", history[1].response.parts[0].tool_call.name);
    try std.testing.expect(history[2].request.parts[0].tool_result.outcome == .success);
    try std.testing.expectEqualStrings(
        "cwd-ok\n\nCommand exited with code 0",
        history[2].request.parts[0].tool_result.content[0].text,
    );
    try std.testing.expectEqualStrings("The workspace command passed.", history[3].response.parts[0].text.text);
}

test "coding-agent cancellation settles a running bash process" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "coding-bash-cancel" },
        .steps = &.{.{ .tool_call = .{
            .id = "call-1",
            .name = "bash",
            .arguments_json = "{\"command\":\": > started; end=$((SECONDS+1)); " ++
                "while (( SECONDS < end )); do :; done; : > late\"}",
        } }},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        temporary.dir,
        .{},
        null,
    );
    defer session.deinit();
    var cancellation: ai_model.CancellationToken = .{};
    var cancel_future = std.testing.io.async(
        cancelAfterBashStarts,
        .{ std.testing.io, temporary.dir, &cancellation },
    );
    const prompt_result = session.promptWithControl("Run until cancelled.", .{ .cancellation = &cancellation });
    try cancel_future.await(std.testing.io);
    try std.testing.expectError(error.Cancelled, prompt_result);
    try temporary.dir.access(std.testing.io, "started", .{});
    try std.testing.expectError(error.FileNotFound, temporary.dir.access(std.testing.io, "late", .{}));
    try std.testing.expect(session.state() == .cancelled);
}
