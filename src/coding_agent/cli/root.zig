const std = @import("std");
const ai = @import("../../ai/root.zig");
const AgentSession = @import("../AgentSession.zig").AgentSession;
const Credentials = @import("../Credentials.zig");
const CredentialManager = Credentials.Manager;
const Model = @import("../Model.zig");
const ModelConfigSnapshot = Model.Snapshot;
const ProjectTrust = @import("../ProjectTrust.zig");
const Runtime = @import("../Runtime.zig");
const ReopenInputs = Runtime.ReopenInputs;
const RuntimeServices = Runtime.Services;
const SessionFormat = @import("../SessionFormat.zig");
const Prompt = @import("../Prompt.zig");
const SystemPrompt = Prompt.SystemPrompt;
const ZiPaths = @import("../ZiPaths.zig");
const interactive = @import("../interactive/root.zig");
const surface = @import("surface.zig");

const ai_message = ai.message;
const ai_model = ai.model;
const ai_testing = ai.testing;

const version = "0.1.0";

/// Adapts the process once, dispatches one admitted invocation, and returns its exit code.
pub fn run(init: std.process.Init, frontend: interactive.Frontend) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file = std.Io.File.Writer.init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_file.interface;
    var stderr_buffer: [4096]u8 = undefined;
    var stderr_file = std.Io.File.Writer.init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_file.interface;
    defer stdout.flush() catch {};
    defer stderr.flush() catch {};

    var argument_iterator = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer argument_iterator.deinit();
    _ = argument_iterator.next();
    var arguments: std.ArrayList([]const u8) = .empty;
    defer arguments.deinit(allocator);
    while (argument_iterator.next()) |argument| try arguments.append(allocator, argument);

    const stdin_is_tty = std.Io.File.stdin().isTty(io) catch false;
    const stdout_is_tty = std.Io.File.stdout().isTty(io) catch false;
    const parsed = surface.parseInvocation(arguments.items, .{
        .stdin_is_tty = stdin_is_tty,
        .stdout_is_tty = stdout_is_tty,
    });
    switch (parsed) {
        .rejected => |rejection| {
            try writeCliDiagnostics(stderr, rejection.diagnostics());
            return 2;
        },
        .admitted => |invocation| switch (invocation) {
            .help => {
                try writeCliHelp(stdout);
                return 0;
            },
            .version => {
                try stdout.print("zi {s}\n", .{version});
                return 0;
            },
            .trust => |request| return runTrustInvocation(init, request, stdout, stderr),
            .auth => |request| return runAuthInvocation(init, request, stdout, stderr),
            .launch => |request| return runLaunchInvocation(
                init,
                &request,
                frontend,
                stdin_is_tty,
                stdout,
                stderr,
            ),
        },
    }
}

fn runTrustInvocation(
    init: std.process.Init,
    request: surface.TrustRequest,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to manage project trust: HOME is not set.\n");
        return 1;
    };
    return executeTrust(request, .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .stdout = stdout,
        .stderr = stderr,
    });
}

fn runAuthInvocation(
    init: std.process.Init,
    request: surface.AuthRequest,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to log in: HOME is not set.\n");
        return 1;
    };
    var stdin_buffer: [auth_input_buffer_bytes]u8 = undefined;
    defer wipeAuthInputBuffer(&stdin_buffer);
    var stdin_file = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    return executeAuth(request, .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .input = &stdin_file.interface,
        .output = stdout,
        .error_output = stderr,
    });
}

fn runLaunchInvocation(
    init: std.process.Init,
    request: *const surface.LaunchRequest,
    frontend: interactive.Frontend,
    stdin_is_tty: bool,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) !u8 {
    const allocator = init.gpa;
    const io = init.io;
    const cwd = try std.process.currentPathAlloc(io, allocator);
    defer allocator.free(cwd);
    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("Unable to start: HOME is not set.\n");
        return 1;
    };
    var stdin_buffer: [64 * 1024]u8 = undefined;
    var stdin_file = std.Io.File.Reader.init(.stdin(), io, &stdin_buffer);
    var sources: Sources = .{ .io = io };
    const context: LaunchContext = .{
        .allocator = allocator,
        .io = io,
        .cwd = cwd,
        .home = home,
        .openai_api_key = init.environ_map.get("OPENAI_API_KEY"),
        .sources = sources.view(),
        .stdin_is_tty = stdin_is_tty,
        .stdin = &stdin_file.interface,
        .stdout = stdout,
        .stderr = stderr,
    };
    const result = switch (request.mode) {
        .interactive => try runInteractiveLaunch(request, context, frontend),
        .print => try runPrintLaunch(request, context),
    };
    return @intFromEnum(result);
}

fn writeCliDiagnostics(writer: *std.Io.Writer, diagnostics: []const surface.Diagnostic) !void {
    for (diagnostics) |diagnostic| switch (diagnostic) {
        .too_many_arguments => try writer.writeAll("Too many command-line arguments.\n"),
        .arguments_too_large => try writer.writeAll("Command-line arguments exceed the size limit.\n"),
        .argument_too_large => |index| try writer.print("Argument {d} exceeds the size limit.\n", .{index}),
        .invalid_utf8 => |index| try writer.print("Argument {d} is not valid UTF-8.\n", .{index}),
        .missing_value => |option| try writer.print("{s} requires a value.\n", .{option}),
        .invalid_mode => |mode| try writer.print("Unsupported mode: {s}.\n", .{mode}),
        .unavailable_mode => |mode| switch (mode) {
            .json => try writer.writeAll("JSON mode is not available yet.\n"),
            .rpc => try writer.writeAll("RPC mode is not available yet.\n"),
        },
        .invalid_auth_command => |command| try writer.print("Unsupported auth command: {s}.\n", .{command}),
        .invalid_trust_command => |command| try writer.print("Unsupported trust command: {s}.\n", .{command}),
        .too_many_trust_arguments => try writer.writeAll("Trust commands accept at most one path.\n"),
        .conflicting_session_option => |option| try writer.print(
            "Session selection is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .conflicting_project_trust_option => |option| try writer.print(
            "Project trust is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .conflicting_system_prompt_option => |option| try writer.print(
            "System prompt customization is already set; {s} cannot be combined with it.\n",
            .{option},
        ),
        .too_many_file_inputs => try writer.writeAll("Print mode accepts at most one @file input.\n"),
        .unknown_option => |option| try writer.print("Unknown option: {s}.\n", .{option}),
    };
}

fn writeCliHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\Usage:
        \\  zi [PROMPT]
        \\  zi --provider PROVIDER --model MODEL [PROMPT]
        \\  zi (--continue | --session PATH) [PROMPT]
        \\  zi --print --provider PROVIDER --model MODEL [PROMPT]
        \\  zi --print (--continue | --session PATH) [PROMPT]
        \\  zi trust (status | allow | deny | remove) [PATH]
        \\  zi auth login PROVIDER [--device]
        \\
        \\Options:
        \\  -p, --print          Run prompts and print the final response
        \\                       Without --print, a terminal starts interactive mode
        \\  -c, --continue       Continue the most recent session for this directory
        \\  --session PATH       Continue an exact session journal
        \\  --provider VALUE     Select a provider
        \\  --model VALUE        Select a model
        \\  --api-key VALUE      Use an explicit API key
        \\  -a, --approve        Trust project prompt files for this launch
        \\  -na, --no-approve    Ignore project prompt files for this launch
        \\  --rules TEXT         Append session rules to the default system prompt
        \\  --system-prompt TEXT Replace the default system prompt
        \\  -h, --help           Show help
        \\  -v, --version        Show the version
        \\  auth login           Start the provider-owned OAuth login ceremony
        \\
        \\Interactive commands:
        \\  Type / to browse, then press Enter or Tab to complete a command
        \\  /login PROVIDER [--device]  Log in without leaving the TUI
        \\  /model PROVIDER/MODEL       Switch models while idle
        \\  /thinking LEVEL              Set thinking while idle (Ctrl-T cycles)
        \\  Without an authenticated model, Zi opens a model-less session
        \\  Assistant prose and thinking render as ordered Markdown blocks
        \\  Footer status shows model, effective thinking level, and session working directory
        \\  Running tools use the footer; completed tools append compact results
        \\
        \\Persistent project trust:
        \\  zi trust status [PATH]  Show the nearest saved decision
        \\  zi trust allow [PATH]   Save a trusted decision
        \\  zi trust deny [PATH]    Save an untrusted decision
        \\  zi trust remove [PATH]  Remove the exact saved decision
        \\
        \\Prompt files:
        \\  $HOME/.zi/agent/SYSTEM.md         Replace the composed prompt base
        \\  $HOME/.zi/agent/APPEND_SYSTEM.md  Append persistent rules
        \\  $CWD/.zi/SYSTEM.md                Replace the base when trusted
        \\  $CWD/.zi/APPEND_SYSTEM.md         Replace persistent rules when trusted
        \\
        \\Context files:
        \\  $HOME/.zi/agent/AGENTS.md         Add global coding instructions
        \\  Ancestor AGENTS.md or CLAUDE.md   Add broad-to-narrow project instructions
        \\
    );
}

const max_initial_prompts = 64;

/// Takes ownership of the created runtime on successful worker admission, then
/// runs the frontend selected by the process composition root.
fn runInteractiveLaunch(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
    frontend: interactive.Frontend,
) !ExitCode {
    var prepared = (try prepareInitial(request, context, false)) orelse return .failure;
    defer prepared.deinit();
    var runtime = (try prepareInteractiveRuntime(request, context)) orelse return .failure;
    var runtime_live = true;
    defer if (runtime_live) runtime.deinit();
    runtime_live = false;
    const host = interactive.InteractiveSessionHost.init(
        context.allocator,
        context.io,
        &runtime.inputs,
        &runtime.lifecycle,
        .{},
    ) catch |failure| {
        try context.stderr.print("Unable to start interactive behavior: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    defer host.deinit();
    var prompt_buffer: [max_initial_prompts][]const u8 = undefined;
    const prompts = collectInitialPrompts(&prepared.value, &prompt_buffer);
    return runFrontend(context, frontend, host, host.transcript(), prompts);
}

fn runFrontend(
    context: LaunchContext,
    frontend: interactive.Frontend,
    host: *interactive.InteractiveSessionHost,
    transcript: *const interactive.SessionTranscript,
    prompts: []const []const u8,
) !ExitCode {
    const cause = frontend.run(.{
        .allocator = context.allocator,
        .io = context.io,
        .host = host,
        .transcript = transcript,
        .initial_prompts = prompts,
        .input = std.Io.File.stdin(),
        .output = std.Io.File.stdout(),
        .writer = context.stdout,
    }) catch |failure| {
        try context.stderr.print("Interactive frontend failed: {s}.\n", .{@errorName(failure)});
        return .failure;
    };
    return switch (cause) {
        .requested => .success,
        .input_closed => closed: {
            try context.stderr.writeAll("Interactive terminal input closed unexpectedly.\n");
            break :closed .failure;
        },
    };
}

fn collectInitialPrompts(
    initial: *const InitialMessage,
    buffer: *[max_initial_prompts][]const u8,
) []const []const u8 {
    var count: usize = 0;
    if (initial.text) |text| {
        buffer[count] = text;
        count += 1;
    }
    for (initial.remaining_messages) |message| {
        buffer[count] = message;
        count += 1;
    }
    return buffer[0..count];
}

const max_input_bytes = 8 * 1024 * 1024;

/// Process-owned inputs shared by admitted launch modes.
const LaunchContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    openai_api_key: ?[]const u8,
    sources: SessionFormat.Sources,
    stdin_is_tty: bool,
    stdin: *std.Io.Reader,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

const Sources = struct {
    io: std.Io,

    fn nextId(context: *anyopaque) [16]u8 {
        const self: *Sources = @ptrCast(@alignCast(context));
        var value: [16]u8 = undefined;
        self.io.random(&value);
        return value;
    }

    fn nowMs(context: *anyopaque) u64 {
        const self: *Sources = @ptrCast(@alignCast(context));
        const value = std.Io.Timestamp.now(self.io, .real).toMilliseconds();
        return if (value > 0) @intCast(value) else 0;
    }

    pub fn view(self: *Sources) SessionFormat.Sources {
        return .{
            .id_context = self,
            .nextIdFn = nextId,
            .clock_context = self,
            .nowMsFn = nowMs,
        };
    }
};

const PreparedInitial = struct {
    allocator: std.mem.Allocator,
    stdin_content: ?[]u8,
    file_content: ?[]u8,
    value: InitialMessage,

    pub fn deinit(self: *PreparedInitial) void {
        self.value.deinit();
        if (self.file_content) |content| self.allocator.free(content);
        if (self.stdin_content) |content| self.allocator.free(content);
        self.* = undefined;
    }
};

fn prepareInitial(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
    include_piped_stdin: bool,
) !?PreparedInitial {
    const stdin_content = if (include_piped_stdin and !context.stdin_is_tty)
        try context.stdin.allocRemaining(context.allocator, .limited(max_input_bytes))
    else
        null;
    const file_content = if (request.file_path) |path|
        std.Io.Dir.cwd().readFileAlloc(
            context.io,
            path,
            context.allocator,
            .limited(max_input_bytes),
        ) catch |failure| {
            if (stdin_content) |content| context.allocator.free(content);
            try context.stderr.print("Unable to read {s}: {s}.\n", .{ path, @errorName(failure) });
            return null;
        }
    else
        null;
    const initial = buildInitialMessage(
        context.allocator,
        request.messages(),
        stdin_content,
        file_content,
    ) catch |failure| {
        if (file_content) |content| context.allocator.free(content);
        if (stdin_content) |content| context.allocator.free(content);
        try context.stderr.print("Unable to compose the prompt: {s}.\n", .{@errorName(failure)});
        return null;
    };
    return .{
        .allocator = context.allocator,
        .stdin_content = stdin_content,
        .file_content = file_content,
        .value = initial,
    };
}

fn runtimeInputs(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
    environment_entries: *[1]ai.auth.EnvironmentEntry,
    prompt_rules: *[1][]const u8,
) RuntimeServices.Inputs {
    const environment_count: usize = if (context.openai_api_key) |key| count: {
        environment_entries[0] = .{ .name = "OPENAI_API_KEY", .value = key };
        break :count 1;
    } else 0;
    const prompt_policy: SystemPrompt.Policy = switch (request.system_prompt) {
        .default => .{ .composed = .{} },
        .append => |value| policy: {
            prompt_rules[0] = value;
            break :policy .{ .composed = .{ .rules = prompt_rules } };
        },
        .replace => |value| .{ .verbatim = value },
    };
    return .{
        .startup_cwd = context.cwd,
        .home = context.home,
        .session = switch (request.session) {
            .new => .new,
            .continue_recent => .continue_recent,
            .open => |path| .{ .open = path },
        },
        .sources = context.sources,
        .requested_provider = request.provider,
        .requested_model = request.model,
        .cli_api_key = request.api_key,
        .project_trust = request.project_trust,
        .environment = .{ .entries = environment_entries[0..environment_count] },
        .options = .{ .prompt = .{ .policy = prompt_policy } },
    };
}

/// Creates one runtime or reports an expected launch failure to stderr.
fn createRuntime(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !?*RuntimeServices {
    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    var prompt_rules: [1][]const u8 = undefined;
    return RuntimeServices.create(
        context.allocator,
        context.io,
        runtimeInputs(request, context, &environment_entries, &prompt_rules),
    ) catch |failure| {
        if (failure == error.SelectionRequired) {
            try context.stderr.writeAll(
                "No model is available. Run `zi auth login PROVIDER` or pass --provider and --model.\n",
            );
        } else {
            try context.stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        }
        return null;
    };
}

const PreparedInteractiveRuntime = struct {
    inputs: ReopenInputs,
    lifecycle: RuntimeServices.Interactive,

    pub fn deinit(self: *PreparedInteractiveRuntime) void {
        self.lifecycle.deinit();
        self.inputs.deinit();
        self.* = undefined;
    }
};

fn prepareInteractiveRuntime(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !?PreparedInteractiveRuntime {
    var environment_entries: [1]ai.auth.EnvironmentEntry = undefined;
    var prompt_rules: [1][]const u8 = undefined;
    var inputs = ReopenInputs.init(
        context.allocator,
        runtimeInputs(request, context, &environment_entries, &prompt_rules),
    ) catch |failure| {
        try context.stderr.print("Unable to retain interactive launch inputs: {s}.\n", .{@errorName(failure)});
        return null;
    };
    errdefer inputs.deinit();
    const lifecycle = RuntimeServices.createInteractive(
        context.allocator,
        context.io,
        inputs.initial(),
    ) catch |failure| {
        try context.stderr.print("Unable to start the coding agent: {s}.\n", .{@errorName(failure)});
        inputs.deinit();
        return null;
    };
    return .{ .inputs = inputs, .lifecycle = lifecycle };
}

/// Runs one admitted print launch and maps expected failures to process output.
fn runPrintLaunch(
    request: *const surface.LaunchRequest,
    context: LaunchContext,
) !ExitCode {
    var prepared = (try prepareInitial(request, context, true)) orelse return .failure;
    defer prepared.deinit();
    var runtime = (try createRuntime(request, context)) orelse return .failure;
    defer runtime.deinit();
    return runPrintMode(
        runtime.session(),
        .{
            .initial_message = prepared.value.text,
            .messages = prepared.value.remaining_messages,
        },
        context.stdout,
        context.stderr,
    );
}

const max_initial_message_bytes = 8 * 1024 * 1024;
const max_messages = 64;

const Error = error{
    OutOfMemory,
    MessageTooLarge,
    TooManyMessages,
    InvalidUtf8,
};

const InitialMessage = struct {
    allocator: std.mem.Allocator,
    text: ?[]const u8,
    remaining_messages: []const []const u8,

    pub fn deinit(self: *InitialMessage) void {
        if (self.text) |text| self.allocator.free(text);
        self.* = undefined;
    }
};

fn buildInitialMessage(
    allocator: std.mem.Allocator,
    messages: []const []const u8,
    stdin_content: ?[]const u8,
    file_text: ?[]const u8,
) Error!InitialMessage {
    if (messages.len > max_messages) return error.TooManyMessages;
    const first_message = if (messages.len > 0) messages[0] else null;
    const remaining_messages = if (messages.len > 0) messages[1..] else messages;
    if (stdin_content) |text| if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    if (file_text) |text| if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
    for (messages) |text| {
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidUtf8;
        if (text.len > max_initial_message_bytes) return error.MessageTooLarge;
    }
    var length: usize = 0;
    if (stdin_content) |text| length = try addLength(length, text.len);
    if (file_text) |text| {
        if (text.len > 0) length = try addLength(length, text.len);
    }
    if (first_message) |text| length = try addLength(length, text.len);

    if (stdin_content == null and (file_text == null or file_text.?.len == 0) and first_message == null) {
        return .{ .allocator = allocator, .text = null, .remaining_messages = remaining_messages };
    }

    const combined = allocator.alloc(u8, length) catch return error.OutOfMemory;
    var offset: usize = 0;
    if (stdin_content) |text| appendPart(combined, &offset, text);
    if (file_text) |text| {
        if (text.len > 0) appendPart(combined, &offset, text);
    }
    if (first_message) |text| appendPart(combined, &offset, text);
    return .{ .allocator = allocator, .text = combined, .remaining_messages = remaining_messages };
}

fn addLength(current: usize, additional: usize) error{MessageTooLarge}!usize {
    if (additional > max_initial_message_bytes - current) return error.MessageTooLarge;
    return current + additional;
}

fn appendPart(output: []u8, offset: *usize, part: []const u8) void {
    @memcpy(output[offset.*..][0..part.len], part);
    offset.* += part.len;
}

const max_prompt_bytes = 8 * 1024 * 1024;
const max_prompts = 64;

const ExitCode = enum(u8) {
    success = 0,
    failure = 1,
};

const PrintModeOptions = struct {
    initial_message: ?[]const u8 = null,
    messages: []const []const u8 = &.{},
};

fn runPrintMode(
    session: *AgentSession,
    options: PrintModeOptions,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!ExitCode {
    const prompt_count = options.messages.len + @intFromBool(options.initial_message != null);
    if (prompt_count > max_prompts) {
        try stderr.writeAll("Print mode accepts at most 64 prompts.\n");
        return .failure;
    }
    if (options.initial_message) |message| {
        if (!try validatePrompt(message, stderr)) return .failure;
    }
    for (options.messages) |message| {
        if (!try validatePrompt(message, stderr)) return .failure;
    }

    var final_text: ?[]const u8 = null;
    if (options.initial_message) |message| {
        final_text = try prompt(session, message, stderr) orelse return .failure;
    }
    for (options.messages) |message| {
        final_text = try prompt(session, message, stderr) orelse return .failure;
    }
    if (final_text) |text| try stdout.print("{s}\n", .{text});
    return .success;
}

fn validatePrompt(message: []const u8, stderr: *std.Io.Writer) std.Io.Writer.Error!bool {
    if (message.len > max_prompt_bytes) {
        try stderr.writeAll("Prompt exceeds the 8.0MB input limit.\n");
        return false;
    }
    if (!std.unicode.utf8ValidateSlice(message)) {
        try stderr.writeAll("Prompt is not valid UTF-8.\n");
        return false;
    }
    return true;
}

fn prompt(
    session: *AgentSession,
    message: []const u8,
    stderr: *std.Io.Writer,
) std.Io.Writer.Error!?[]const u8 {
    return session.prompt(message) catch |failure| {
        try writeFailure(session, stderr, failure);
        return null;
    };
}

fn writeFailure(
    session: *const AgentSession,
    stderr: *std.Io.Writer,
    failure: AgentSession.RunError,
) std.Io.Writer.Error!void {
    if (session.providerFailure()) |provider_failure| {
        try stderr.print("Request failed: {s} (HTTP {d}: {s})\n", .{
            @errorName(failure),
            provider_failure.status,
            provider_failure.message,
        });
        return;
    }
    try stderr.print("Request failed: {s}\n", .{@errorName(failure)});
}

const max_auth_prompt_bytes = 16 * 1024;
const auth_input_buffer_bytes = 64 * 1024;

const AuthContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
    error_output: *std.Io.Writer,
};

fn executeAuth(request: surface.AuthRequest, context: AuthContext) !u8 {
    var paths = try ZiPaths.init(context.allocator, context.cwd, context.home);
    defer paths.deinit();
    var snapshot = ModelConfigSnapshot.load(context.allocator, context.io, &paths) catch |failure| {
        try context.error_output.print("Unable to load model configuration: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer snapshot.deinit();

    var interaction_context: InteractionContext = .{
        .allocator = context.allocator,
        .input = context.input,
        .output = context.output,
    };
    var transport = ai.transport.HttpTransport.init(context.allocator);
    CredentialManager.login(
        context.allocator,
        context.io,
        &paths,
        transport.transport(),
        snapshot.view(),
        .{
            .provider_id = request.provider,
            .method = request.method,
            .interaction = .{
                .context = &interaction_context,
                .vtable = &.{ .notify = notify, .prompt = oauthPrompt },
            },
            .now_ms = oauthNowMs(context.io),
        },
    ) catch |failure| {
        try context.error_output.print("Unable to log in: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    try context.output.print("Logged in to {s}.\n", .{request.provider});
    return 0;
}

const InteractionContext = struct {
    allocator: std.mem.Allocator,
    input: *std.Io.Reader,
    output: *std.Io.Writer,
};

fn notify(context: *anyopaque, event: ai.oauth.Event) anyerror!void {
    const self: *InteractionContext = @ptrCast(@alignCast(context));
    switch (event) {
        .auth_url => |value| try self.output.print("{s}\n{s}\n", .{ value.instructions, value.url }),
        .device_code => |value| try self.output.print(
            "Open {s}\nEnter code: {s}\n",
            .{ value.verification_uri, value.user_code },
        ),
    }
    try self.output.flush();
}

// Context leads because this callback implements the erased OAuth interaction ABI.
// ziglint-ignore: Z023
fn oauthPrompt(context: *anyopaque, allocator: std.mem.Allocator, request: ai.oauth.Prompt) anyerror![]u8 {
    const self: *InteractionContext = @ptrCast(@alignCast(context));
    try self.output.writeAll(request.message);
    if (request.placeholder) |placeholder| try self.output.print(" ({s})", .{placeholder});
    try self.output.writeAll(": ");
    try self.output.flush();
    const line = (try self.input.takeDelimiter('\n')) orelse return error.ConsumerStopped;
    defer std.crypto.secureZero(u8, @constCast(line));
    if (line.len > max_auth_prompt_bytes) return error.ConsumerStopped;
    const value = std.mem.trim(u8, line, " \t\r\n");
    if (value.len == 0) return error.ConsumerStopped;
    return allocator.dupe(u8, value);
}

fn wipeAuthInputBuffer(buffer: *[auth_input_buffer_bytes]u8) void {
    std.crypto.secureZero(u8, buffer);
}

fn oauthNowMs(io: std.Io) u64 {
    const value = std.Io.Timestamp.now(io, .real).toMilliseconds();
    return if (value > 0) @intCast(value) else 0;
}

const TrustContext = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

fn executeTrust(request: surface.TrustRequest, context: TrustContext) !u8 {
    const target_path = std.fs.path.resolve(
        context.allocator,
        &.{ context.cwd, request.path orelse context.cwd },
    ) catch {
        try context.stderr.writeAll("Unable to resolve the project path: OutOfMemory.\n");
        return 1;
    };
    defer context.allocator.free(target_path);
    var paths = ZiPaths.init(context.allocator, target_path, context.home) catch |failure| {
        try context.stderr.print("Unable to resolve the project path: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer paths.deinit();
    var identity = ProjectTrust.Identity.init(context.allocator, context.io, target_path) catch |failure| {
        try context.stderr.print("Unable to identify the project: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer identity.deinit();

    return switch (request.action) {
        .status => status(context, &paths, &identity),
        .allow => update(context, &paths, &identity, .trusted),
        .deny => update(context, &paths, &identity, .untrusted),
        .remove => remove(context, &paths, &identity),
    };
}

fn status(
    context: TrustContext,
    paths: *const ZiPaths,
    identity: *const ProjectTrust.Identity,
) !u8 {
    var snapshot = ProjectTrust.load(context.allocator, context.io, paths) catch |failure| {
        try writeStoreFailure(context.stderr, "read", failure);
        return 1;
    };
    defer snapshot.deinit();
    if (snapshot.nearest(identity)) |entry| {
        try context.stdout.print(
            "Project trust: {s} (saved at {s}).\n",
            .{ @tagName(entry.decision), entry.path },
        );
    } else {
        try context.stdout.print("Project trust: unset for {s}.\n", .{identity.path()});
    }
    return 0;
}

fn update(
    context: TrustContext,
    paths: *const ZiPaths,
    identity: *const ProjectTrust.Identity,
    decision: ProjectTrust.Decision,
) !u8 {
    ProjectTrust.put(
        context.allocator,
        context.io,
        paths,
        identity,
        decision,
    ) catch |failure| {
        try writeStoreFailure(context.stderr, "update", failure);
        return 1;
    };
    try context.stdout.print(
        "Saved project trust: {s} for {s}.\n",
        .{ @tagName(decision), identity.path() },
    );
    return 0;
}

fn remove(
    context: TrustContext,
    paths: *const ZiPaths,
    identity: *const ProjectTrust.Identity,
) !u8 {
    const removed = ProjectTrust.remove(
        context.allocator,
        context.io,
        paths,
        identity,
    ) catch |failure| {
        try writeStoreFailure(context.stderr, "update", failure);
        return 1;
    };
    if (removed) {
        try context.stdout.print("Removed project trust for {s}.\n", .{identity.path()});
    } else {
        try context.stdout.print("No exact project trust decision exists for {s}.\n", .{identity.path()});
    }
    return 0;
}

fn writeStoreFailure(writer: *std.Io.Writer, operation: []const u8, failure: anyerror) !void {
    try writer.print("Unable to {s} project trust: {s}.\n", .{ operation, @errorName(failure) });
}

fn testContext(
    root: []const u8,
    project: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) TrustContext {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = project,
        .home = root,
        .stdout = stdout,
        .stderr = stderr,
    };
}

test "CLI core parses, composes, runs sequential prompts, and prints only the final response" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-print" },
        .steps = &.{
            .{ .text = "first response" },
            .{ .text = "final response" },
        },
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        try temporary.dir.openDir(std.testing.io, ".", .{}),
        .{},
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const parsed = surface.parseInvocation(&.{ "-p", "first prompt", "second prompt" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(parsed == .admitted);
    const request = parsed.admitted.launch;
    var initial = try buildInitialMessage(
        std.testing.allocator,
        request.messages(),
        "stdin\n",
        null,
    );
    defer initial.deinit();
    const exit = try runPrintMode(
        &session,
        .{ .initial_message = initial.text, .messages = initial.remaining_messages },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .success);
    try std.testing.expectEqualStrings("final response\n", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 2), scripted.calls);
    const history = session.messages();
    try std.testing.expectEqual(@as(usize, 4), history.len);
    try std.testing.expectEqualStrings("stdin\nfirst prompt", history[0].request.parts[0].user.text);
    try std.testing.expectEqualStrings("first response", history[1].response.parts[0].text.text);
    try std.testing.expectEqualStrings("second prompt", history[2].request.parts[0].user.text);
    try std.testing.expectEqualStrings("final response", history[3].response.parts[0].text.text);
}

test "text print mode routes a settled agent failure only to stderr" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-failure" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        try temporary.dir.openDir(std.testing.io, ".", .{}),
        .{},
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try runPrintMode(
        &session,
        .{ .initial_message = "fail" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .failure);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("Request failed: InvalidRequest\n", stderr.written());
    try std.testing.expect(session.state() == .ready);
}

test "text print mode reports bounded provider failure details" {
    const RejectingModel = struct {
        const Self = @This();

        pub fn invoke(
            _: *Self,
            _: std.mem.Allocator,
            _: std.mem.Allocator,
            _: std.Io,
            _: ai_message.ModelIdentity,
            request: ai_model.ModelRequest,
            _: ai_model.Delivery,
        ) ai_model.ModelError!ai_message.ResponseMessage {
            request.failure_sink.?.observe(.{
                .provider = "openai-codex",
                .status = 400,
                .code = "bad_request",
                .message = "Unsupported content type",
                .request_id = "request-123",
                .retry_after_ms = 3000,
            });
            return error.ProviderRejectedRequest;
        }
    };
    var implementation: RejectingModel = .{};
    var profile: ai_model.ModelProfile = .{};
    profile.capabilities.insert(.tools);
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        ai_model.Model.from(
            &implementation,
            .{ .provider = "openai-codex", .model = "rejecting" },
            profile,
        ),
        try temporary.dir.openDir(std.testing.io, ".", .{}),
        .{},
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try runPrintMode(
        &session,
        .{ .initial_message = "fail" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .failure);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings(
        "Request failed: ProviderRejectedRequest (HTTP 400: Unsupported content type)\n",
        stderr.written(),
    );
    try std.testing.expectEqualStrings("request-123", session.providerFailure().?.request_id.?);
    try std.testing.expectEqual(@as(?u64, 3000), session.providerFailure().?.retry_after_ms);
}

test "text print mode rejects invalid and excessive prompts before model admission" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-invalid" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        try temporary.dir.openDir(std.testing.io, ".", .{}),
        .{},
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try runPrintMode(
        &session,
        .{ .initial_message = "\xff" },
        &stdout.writer,
        &stderr.writer,
    );
    try std.testing.expect(exit == .failure);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("Prompt is not valid UTF-8.\n", stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(session.state() == .ready);

    var later_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer later_stdout.deinit();
    var later_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer later_stderr.deinit();
    const later_exit = try runPrintMode(
        &session,
        .{ .initial_message = "valid", .messages = &.{"\xff"} },
        &later_stdout.writer,
        &later_stderr.writer,
    );
    try std.testing.expect(later_exit == .failure);
    try std.testing.expectEqualStrings("", later_stdout.written());
    try std.testing.expectEqualStrings("Prompt is not valid UTF-8.\n", later_stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);

    var messages: [65][]const u8 = undefined;
    @memset(&messages, "");
    var count_stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count_stdout.deinit();
    var count_stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer count_stderr.deinit();
    const count_exit = try runPrintMode(
        &session,
        .{ .messages = &messages },
        &count_stdout.writer,
        &count_stderr.writer,
    );
    try std.testing.expect(count_exit == .failure);
    try std.testing.expectEqualStrings("", count_stdout.written());
    try std.testing.expectEqualStrings(
        "Print mode accepts at most 64 prompts.\n",
        count_stderr.written(),
    );
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
}

test "text print mode succeeds silently without a prompt" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var scripted: ai_testing.ScriptedModel = .{
        .identity = .{ .provider = "script", .model = "cli-empty" },
        .steps = &.{},
    };
    var session = try AgentSession.init(
        std.testing.allocator,
        std.testing.io,
        scripted.asModel(),
        try temporary.dir.openDir(std.testing.io, ".", .{}),
        .{},
    );
    defer session.deinit();
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const exit = try runPrintMode(&session, .{}, &stdout.writer, &stderr.writer);
    try std.testing.expect(exit == .success);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());
    try std.testing.expectEqual(@as(usize, 0), scripted.calls);
    try std.testing.expect(session.state() == .ready);
}

test "print launch reopens recent and exact sessions with their restored model" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    const Fixture = struct {
        fn run(
            request: *const surface.LaunchRequest,
            root_path: []const u8,
            stdout_writer: *std.Io.Writer,
            stderr_writer: *std.Io.Writer,
        ) !ExitCode {
            var stdin = std.Io.Reader.fixed("");
            var sources: Sources = .{ .io = std.testing.io };
            return runPrintLaunch(request, .{
                .allocator = std.testing.allocator,
                .io = std.testing.io,
                .cwd = root_path,
                .home = root_path,
                .openai_api_key = null,
                .sources = sources.view(),
                .stdin_is_tty = true,
                .stdin = &stdin,
                .stdout = stdout_writer,
                .stderr = stderr_writer,
            });
        }
    };

    const created: surface.LaunchRequest = .{
        .provider = "openai",
        .model = "gpt-5.6-sol",
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&created, root, &stdout.writer, &stderr.writer) == .success);

    var sessions = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
    defer sessions.close(std.testing.io);
    var iterator = sessions.iterateAssumeFirstIteration();
    const entry = (try iterator.next(std.testing.io)).?;
    const session_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, ".zi/agent/sessions", entry.name });
    defer std.testing.allocator.free(session_path);
    try std.testing.expect(try iterator.next(std.testing.io) == null);

    const recent: surface.LaunchRequest = .{
        .session = .continue_recent,
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&recent, root, &stdout.writer, &stderr.writer) == .success);

    const exact: surface.LaunchRequest = .{
        .session = .{ .open = session_path },
        .api_key = "test-secret",
    };
    try std.testing.expect(try Fixture.run(&exact, root, &stdout.writer, &stderr.writer) == .success);
    try std.testing.expectEqualStrings("", stdout.written());
    try std.testing.expectEqualStrings("", stderr.written());

    var verify = try temporary.dir.openDir(std.testing.io, ".zi/agent/sessions", .{ .iterate = true });
    defer verify.close(std.testing.io);
    var verify_iterator = verify.iterateAssumeFirstIteration();
    try std.testing.expect(try verify_iterator.next(std.testing.io) != null);
    try std.testing.expect(try verify_iterator.next(std.testing.io) == null);
}

test "buildInitialMessage combines pi inputs without inventing separators" {
    const messages = [_][]const u8{ "Explain it", "Second message" };
    var initial = try buildInitialMessage(
        std.testing.allocator,
        &messages,
        "stdin\n",
        "file\n",
    );
    defer initial.deinit();

    try std.testing.expectEqualStrings("stdin\nfile\nExplain it", initial.text.?);
    try std.testing.expectEqual(@as(usize, 1), initial.remaining_messages.len);
    try std.testing.expectEqualStrings("Second message", initial.remaining_messages[0]);
}

test "buildInitialMessage distinguishes absent and empty stdin" {
    var absent = try buildInitialMessage(std.testing.allocator, &.{}, null, null);
    defer absent.deinit();
    try std.testing.expect(absent.text == null);

    var empty = try buildInitialMessage(std.testing.allocator, &.{}, "", null);
    defer empty.deinit();
    try std.testing.expect(empty.text != null);
    try std.testing.expectEqualStrings("", empty.text.?);
}

test "buildInitialMessage rejects invalid UTF-8 input" {
    try std.testing.expectError(
        error.InvalidUtf8,
        buildInitialMessage(std.testing.allocator, &.{}, "\xff", null),
    );
    try std.testing.expectError(
        error.InvalidUtf8,
        buildInitialMessage(std.testing.allocator, &.{ "valid", "\xff" }, null, null),
    );
}

test "buildInitialMessage bounds message count and bytes" {
    var messages: [max_messages + 1][]const u8 = undefined;
    @memset(&messages, "");
    try std.testing.expectError(
        error.TooManyMessages,
        buildInitialMessage(std.testing.allocator, &messages, null, null),
    );

    const oversized = try std.testing.allocator.alloc(u8, max_initial_message_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(
        error.MessageTooLarge,
        buildInitialMessage(std.testing.allocator, &.{oversized}, null, null),
    );
    try std.testing.expectError(
        error.MessageTooLarge,
        buildInitialMessage(std.testing.allocator, &.{ "valid", oversized }, null, null),
    );
}

test "interactive launch preserves composed initial prompt order" {
    var initial = try buildInitialMessage(
        std.testing.allocator,
        &.{ "first", "second", "third" },
        null,
        "file:",
    );
    defer initial.deinit();
    var buffer: [max_initial_prompts][]const u8 = undefined;
    const prompts = collectInitialPrompts(&initial, &buffer);
    try std.testing.expectEqual(@as(usize, 3), prompts.len);
    try std.testing.expectEqualStrings("file:first", prompts[0]);
    try std.testing.expectEqualStrings("second", prompts[1]);
    try std.testing.expectEqualStrings("third", prompts[2]);
}

test "OAuth callbacks flush borrowed output and wipe consumed answers" {
    const FlushRecorder = struct {
        const Self = @This();

        writer: std.Io.Writer = .{ .vtable = &vtable, .buffer = &.{} },
        flushes: usize = 0,

        fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
            _ = writer;
            var consumed: usize = 0;
            for (data[0 .. data.len - 1]) |bytes| consumed += bytes.len;
            consumed += data[data.len - 1].len * splat;
            return consumed;
        }
        fn flush(writer: *std.Io.Writer) std.Io.Writer.Error!void {
            const self: *Self = @fieldParentPtr("writer", writer);
            self.flushes += 1;
        }
        const vtable: std.Io.Writer.VTable = .{ .drain = drain, .flush = flush };
    };

    var output: FlushRecorder = .{};
    var answer = [_]u8{ 's', 'e', 'c', 'r', 'e', 't', '\n' };
    var input = std.Io.Reader.fixed(&answer);
    var interaction: InteractionContext = .{
        .allocator = std.testing.allocator,
        .input = &input,
        .output = &output.writer,
    };
    try notify(&interaction, .{ .auth_url = .{ .url = "https://example.test", .instructions = "Open" } });
    try std.testing.expectEqual(@as(usize, 1), output.flushes);
    try notify(&interaction, .{ .device_code = .{
        .user_code = "ABCD-EFGH",
        .verification_uri = "https://example.test/device",
        .interval_seconds = 1,
        .expires_in_seconds = 60,
    } });
    try std.testing.expectEqual(@as(usize, 2), output.flushes);
    const owned = try oauthPrompt(&interaction, std.testing.allocator, .{ .message = "Token" });
    defer {
        std.crypto.secureZero(u8, owned);
        std.testing.allocator.free(owned);
    }
    try std.testing.expectEqual(@as(usize, 3), output.flushes);
    try std.testing.expectEqualStrings("secret", owned);
    for (answer[0 .. answer.len - 1]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);

    var backing: [auth_input_buffer_bytes]u8 = @splat(0xa5);
    wipeAuthInputBuffer(&backing);
    for (backing) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "OAuth prompt wipes rejected and closed input" {
    var output_buffer: [64]u8 = undefined;
    var output = std.Io.Writer.fixed(&output_buffer);
    var rejected = [_]u8{ ' ', '\n' };
    var rejected_reader = std.Io.Reader.fixed(&rejected);
    var interaction: InteractionContext = .{
        .allocator = std.testing.allocator,
        .input = &rejected_reader,
        .output = &output,
    };
    try std.testing.expectError(
        error.ConsumerStopped,
        oauthPrompt(&interaction, std.testing.allocator, .{ .message = "Token" }),
    );
    try std.testing.expectEqual(@as(u8, 0), rejected[0]);

    var closed_reader = std.Io.Reader.fixed("");
    interaction.input = &closed_reader;
    try std.testing.expectError(
        error.ConsumerStopped,
        oauthPrompt(&interaction, std.testing.allocator, .{ .message = "Token" }),
    );
}

test "auth parser inputs retain provider and login method" {
    const request: surface.AuthRequest = .{ .provider = "openai-codex", .method = .device_code };
    try std.testing.expectEqualStrings("openai-codex", request.provider);
    try std.testing.expectEqual(ai.oauth.LoginMethod.device_code, request.method);
}

test "trust command manages exact decisions and reports effective status" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "project", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const project = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project);
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .allow }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Saved project trust: trusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: trusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .deny }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: untrusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .remove }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 0),
        try executeTrust(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: unset") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}
