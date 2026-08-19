const std = @import("std");

const max_arguments = 64;
const max_argument_bytes = 256 * 1024;
const max_total_bytes = 1024 * 1024;

/// Terminal facts used to resolve pi-compatible automatic launch behavior.
pub const Terminal = struct {
    stdin_is_tty: bool,
    stdout_is_tty: bool,
};

/// One admitted durable-session choice whose path remains borrowed from argv.
pub const SessionIntent = union(enum) {
    new,
    continue_recent,
    open: []const u8,
};

/// Process-boundary system-prompt intent whose text remains borrowed from argv.
pub const PromptIntent = union(enum) {
    default,
    append: []const u8,
    replace: []const u8,
};

/// One print launch whose strings remain borrowed from argv for its execution.
pub const LaunchRequest = struct {
    session: SessionIntent = .new,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
    system_prompt: PromptIntent = .default,
    message_buffer: [max_arguments][]const u8 = undefined,
    message_count: usize = 0,

    pub fn messages(self: *const LaunchRequest) []const []const u8 {
        return self.message_buffer[0..self.message_count];
    }
};

/// One semantically valid CLI operation.
pub const Invocation = union(enum) {
    help,
    version,
    launch: LaunchRequest,
};

pub const Mode = enum {
    interactive,
    json,
    rpc,
};

/// One process-boundary argument rejection without secret values.
pub const Diagnostic = union(enum) {
    too_many_arguments,
    arguments_too_large,
    argument_too_large: usize,
    invalid_utf8: usize,
    missing_value: []const u8,
    invalid_mode: []const u8,
    unavailable_mode: Mode,
    invalid_auth_command: []const u8,
    conflicting_session_option: []const u8,
    conflicting_system_prompt_option: []const u8,
    too_many_file_inputs,
    unknown_option: []const u8,
};

pub const Rejection = struct {
    buffer: [max_arguments]Diagnostic = undefined,
    count: usize = 0,

    pub fn diagnostics(self: *const Rejection) []const Diagnostic {
        return self.buffer[0..self.count];
    }

    fn add(self: *Rejection, diagnostic: Diagnostic) void {
        self.buffer[self.count] = diagnostic;
        self.count += 1;
    }
};

/// CLI admission either yields exactly one invocation or bounded diagnostics.
pub const ParseResult = union(enum) {
    admitted: Invocation,
    rejected: Rejection,
};

const RequestedMode = enum {
    automatic,
    text,
    json,
    rpc,
};

/// Parses and admits bounded argv; admitted strings borrow from argv.
pub fn parseInvocation(argv: []const []const u8, terminal: Terminal) ParseResult {
    var rejection: Rejection = .{};
    if (!validateArguments(argv, &rejection)) return .{ .rejected = rejection };
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "auth")) {
        rejection.add(.{ .invalid_auth_command = if (argv.len > 1) argv[1] else "" });
        return .{ .rejected = rejection };
    }

    var launch: LaunchRequest = .{};
    var requested_mode: RequestedMode = .automatic;
    var print_requested = false;
    var help_requested = false;
    var version_requested = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            help_requested = true;
        } else if (std.mem.eql(u8, argument, "--version") or std.mem.eql(u8, argument, "-v")) {
            version_requested = true;
        } else if (std.mem.eql(u8, argument, "--print") or std.mem.eql(u8, argument, "-p")) {
            print_requested = true;
            if (index + 1 < argv.len and isPrintPrompt(argv[index + 1])) {
                index += 1;
                appendMessage(&launch, argv[index]);
            }
        } else if (std.mem.eql(u8, argument, "--mode")) {
            const value = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
            requested_mode = parseMode(value) orelse {
                rejection.add(.{ .invalid_mode = value });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--continue") or std.mem.eql(u8, argument, "-c")) {
            admitSessionIntent(&launch, .continue_recent, argument, &rejection);
        } else if (std.mem.eql(u8, argument, "--session")) {
            const value = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
            admitSessionIntent(&launch, .{ .open = value }, argument, &rejection);
        } else if (std.mem.eql(u8, argument, "--rules") or
            std.mem.eql(u8, argument, "--append-system-prompt"))
        {
            const value = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
            admitSystemPrompt(&launch, .{ .append = value }, argument, &rejection);
        } else if (std.mem.eql(u8, argument, "--system-prompt") or
            std.mem.eql(u8, argument, "--system-prompt-override"))
        {
            const value = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
            admitSystemPrompt(&launch, .{ .replace = value }, argument, &rejection);
        } else if (std.mem.eql(u8, argument, "--provider")) {
            launch.provider = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--model")) {
            launch.model = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--api-key")) {
            launch.api_key = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
        } else if (std.mem.startsWith(u8, argument, "@")) {
            if (launch.file_path != null) {
                rejection.add(.too_many_file_inputs);
            } else {
                launch.file_path = argument[1..];
            }
        } else if (std.mem.startsWith(u8, argument, "-")) {
            rejection.add(.{ .unknown_option = argument });
        } else {
            appendMessage(&launch, argument);
        }
    }

    if (rejection.count > 0) return .{ .rejected = rejection };
    if (help_requested) return .{ .admitted = .help };
    if (version_requested) return .{ .admitted = .version };
    switch (requested_mode) {
        .json => rejection.add(.{ .unavailable_mode = .json }),
        .rpc => rejection.add(.{ .unavailable_mode = .rpc }),
        .automatic, .text => if (!print_requested and terminal.stdin_is_tty and terminal.stdout_is_tty) {
            rejection.add(.{ .unavailable_mode = .interactive });
        },
    }
    if (rejection.count > 0) return .{ .rejected = rejection };
    return .{ .admitted = .{ .launch = launch } };
}

fn validateArguments(argv: []const []const u8, rejection: *Rejection) bool {
    if (argv.len > max_arguments) {
        rejection.add(.too_many_arguments);
        return false;
    }
    var total_bytes: usize = 0;
    for (argv, 0..) |argument, index| {
        if (argument.len > max_argument_bytes) {
            rejection.add(.{ .argument_too_large = index });
            continue;
        }
        if (argument.len > max_total_bytes - total_bytes) {
            rejection.add(.arguments_too_large);
            return false;
        }
        total_bytes += argument.len;
        if (!std.unicode.utf8ValidateSlice(argument)) {
            rejection.add(.{ .invalid_utf8 = index });
        }
    }
    return rejection.count == 0;
}

fn valueAfter(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    return argv[index.*];
}

fn parseMode(value: []const u8) ?RequestedMode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "rpc")) return .rpc;
    return null;
}

fn admitSessionIntent(
    launch: *LaunchRequest,
    intent: SessionIntent,
    option: []const u8,
    rejection: *Rejection,
) void {
    if (launch.session != .new) {
        rejection.add(.{ .conflicting_session_option = option });
        return;
    }
    launch.session = intent;
}

fn admitSystemPrompt(
    launch: *LaunchRequest,
    intent: PromptIntent,
    option: []const u8,
    rejection: *Rejection,
) void {
    if (launch.system_prompt != .default) {
        rejection.add(.{ .conflicting_system_prompt_option = option });
        return;
    }
    launch.system_prompt = intent;
}

fn appendMessage(launch: *LaunchRequest, message: []const u8) void {
    launch.message_buffer[launch.message_count] = message;
    launch.message_count += 1;
}

fn isPrintPrompt(value: []const u8) bool {
    return !std.mem.startsWith(u8, value, "@") and
        (!std.mem.startsWith(u8, value, "-") or std.mem.startsWith(u8, value, "---"));
}

test "CLI surface admits one typed launch invocation" {
    const parsed = parseInvocation(&.{
        "-p",
        "first",
        "@prompt.md",
        "--provider",
        "openai",
        "--model",
        "gpt-5",
        "--api-key",
        "secret",
        "second",
    }, .{ .stdin_is_tty = true, .stdout_is_tty = true });
    try std.testing.expect(parsed == .admitted);
    const launch = parsed.admitted.launch;
    try std.testing.expect(launch.session == .new);
    try std.testing.expectEqualStrings("openai", launch.provider.?);
    try std.testing.expectEqualStrings("gpt-5", launch.model.?);
    try std.testing.expectEqualStrings("secret", launch.api_key.?);
    try std.testing.expectEqualStrings("prompt.md", launch.file_path.?);
    try std.testing.expectEqual(@as(usize, 2), launch.messages().len);
    try std.testing.expectEqualStrings("first", launch.messages()[0]);
    try std.testing.expectEqualStrings("second", launch.messages()[1]);
}

test "CLI surface admits appended and replacement system prompts" {
    const appended = parseInvocation(&.{ "--print", "--rules", "Prefer focused tests.", "fix it" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(appended == .admitted);
    try std.testing.expect(appended.admitted.launch.system_prompt == .append);
    try std.testing.expectEqualStrings(
        "Prefer focused tests.",
        appended.admitted.launch.system_prompt.append,
    );

    const replaced = parseInvocation(&.{ "--print", "--system-prompt", "Answer briefly.", "question" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(replaced == .admitted);
    try std.testing.expect(replaced.admitted.launch.system_prompt == .replace);
    try std.testing.expectEqualStrings("Answer briefly.", replaced.admitted.launch.system_prompt.replace);
}

test "CLI surface rejects conflicting system prompt controls" {
    const parsed = parseInvocation(&.{
        "--print",
        "--rules",
        "Prefer focused tests.",
        "--system-prompt-override",
        "Answer briefly.",
    }, .{ .stdin_is_tty = true, .stdout_is_tty = true });
    try std.testing.expect(parsed == .rejected);
    try std.testing.expectEqualStrings(
        "--system-prompt-override",
        parsed.rejected.diagnostics()[0].conflicting_system_prompt_option,
    );
}

test "CLI surface admits recent and exact durable session continuation" {
    const recent = parseInvocation(&.{ "--print", "--continue", "follow up" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(recent == .admitted);
    try std.testing.expect(recent.admitted.launch.session == .continue_recent);

    const exact = parseInvocation(&.{ "--print", "--session", "session.jsonl", "follow up" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(exact == .admitted);
    try std.testing.expect(exact.admitted.launch.session == .open);
    try std.testing.expectEqualStrings("session.jsonl", exact.admitted.launch.session.open);
}

test "CLI surface rejects conflicting durable session choices" {
    const parsed = parseInvocation(&.{ "--print", "-c", "--session", "session.jsonl" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(parsed == .rejected);
    try std.testing.expectEqualStrings(
        "--session",
        parsed.rejected.diagnostics()[0].conflicting_session_option,
    );
}

test "CLI surface resolves automatic presentation only at the process edge" {
    const piped = parseInvocation(&.{"prompt"}, .{ .stdin_is_tty = false, .stdout_is_tty = true });
    try std.testing.expect(piped == .admitted);
    try std.testing.expect(piped.admitted == .launch);

    const terminal = parseInvocation(&.{"prompt"}, .{ .stdin_is_tty = true, .stdout_is_tty = true });
    try std.testing.expect(terminal == .rejected);
    try std.testing.expectEqual(Mode.interactive, terminal.rejected.diagnostics()[0].unavailable_mode);
}

test "CLI surface routes help and version before launch admission" {
    const terminal: Terminal = .{ .stdin_is_tty = true, .stdout_is_tty = true };
    const help = parseInvocation(&.{ "prompt", "--help" }, terminal);
    try std.testing.expect(help == .admitted);
    try std.testing.expect(help.admitted == .help);
    const version = parseInvocation(&.{"--version"}, terminal);
    try std.testing.expect(version == .admitted);
    try std.testing.expect(version.admitted == .version);
}

test "CLI surface reserves pi auth commands without admitting login ceremonies" {
    const login = parseInvocation(&.{ "auth", "login", "openai-codex" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(login == .rejected);
    try std.testing.expectEqualStrings("login", login.rejected.diagnostics()[0].invalid_auth_command);
}

test "CLI surface rejects options outside their command grammar" {
    const extension_flag = parseInvocation(&.{ "-p", "--plan=careful" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(extension_flag == .rejected);
    try std.testing.expectEqualStrings("--plan=careful", extension_flag.rejected.diagnostics()[0].unknown_option);
}

test "CLI surface bounds arguments before admission" {
    var too_many: [max_arguments + 1][]const u8 = undefined;
    @memset(&too_many, "prompt");
    const count = parseInvocation(&too_many, .{ .stdin_is_tty = false, .stdout_is_tty = true });
    try std.testing.expect(count == .rejected);
    try std.testing.expect(count.rejected.diagnostics()[0] == .too_many_arguments);

    const argument = try std.testing.allocator.alloc(u8, max_argument_bytes);
    defer std.testing.allocator.free(argument);
    @memset(argument, 'x');
    const exact = parseInvocation(&.{ argument, argument, argument, argument }, .{
        .stdin_is_tty = false,
        .stdout_is_tty = true,
    });
    try std.testing.expect(exact == .admitted);
    const total = parseInvocation(&.{ argument, argument, argument, argument, argument }, .{
        .stdin_is_tty = false,
        .stdout_is_tty = true,
    });
    try std.testing.expect(total == .rejected);
    try std.testing.expect(total.rejected.diagnostics()[0] == .arguments_too_large);

    const oversized = try std.testing.allocator.alloc(u8, max_argument_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    const bytes = parseInvocation(&.{oversized}, .{ .stdin_is_tty = false, .stdout_is_tty = true });
    try std.testing.expect(bytes == .rejected);
    try std.testing.expectEqual(@as(usize, 0), bytes.rejected.diagnostics()[0].argument_too_large);

    const invalid_utf8 = parseInvocation(&.{"\xff"}, .{ .stdin_is_tty = false, .stdout_is_tty = true });
    try std.testing.expect(invalid_utf8 == .rejected);
    try std.testing.expectEqual(@as(usize, 0), invalid_utf8.rejected.diagnostics()[0].invalid_utf8);
}
