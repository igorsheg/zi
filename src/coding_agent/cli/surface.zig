const std = @import("std");

const max_arguments = 64;
const max_argument_bytes = 256 * 1024;
const max_total_bytes = 1024 * 1024;

/// Terminal facts used to resolve pi-compatible automatic launch behavior.
pub const Terminal = struct {
    stdin_is_tty: bool,
    stdout_is_tty: bool,
};

pub const AuthMethod = enum {
    browser,
    device_code,
};

/// One admitted credential command with provider identifiers borrowed from argv.
pub const AuthCommand = union(enum) {
    login: struct {
        provider_id: []const u8,
        method: AuthMethod,
    },
    logout: struct {
        provider_id: []const u8,
    },
};

/// One print launch whose strings remain borrowed from argv for its execution.
pub const LaunchRequest = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    file_path: ?[]const u8 = null,
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
    auth: AuthCommand,
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
    invalid_auth_method: []const u8,
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
        return parseAuthInvocation(argv, rejection);
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

fn parseAuthInvocation(argv: []const []const u8, rejection_value: Rejection) ParseResult {
    var rejection = rejection_value;
    if (argv.len < 2) {
        rejection.add(.{ .invalid_auth_command = "" });
        return .{ .rejected = rejection };
    }
    const action = argv[1];
    if (std.mem.eql(u8, action, "login")) return parseLogin(argv[2..], rejection);
    if (std.mem.eql(u8, action, "logout")) return parseLogout(argv[2..], rejection);
    rejection.add(.{ .invalid_auth_command = action });
    return .{ .rejected = rejection };
}

fn parseLogin(argv: []const []const u8, rejection_value: Rejection) ParseResult {
    var rejection = rejection_value;
    var provider_id: []const u8 = "openai-codex";
    var provider_set = false;
    var method: AuthMethod = .browser;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "--method")) {
            const value = valueAfter(argv, &index) orelse {
                rejection.add(.{ .missing_value = argument });
                continue;
            };
            method = parseAuthMethod(value) orelse {
                rejection.add(.{ .invalid_auth_method = value });
                continue;
            };
        } else if (std.mem.startsWith(u8, argument, "-")) {
            rejection.add(.{ .unknown_option = argument });
        } else if (!provider_set) {
            provider_id = argument;
            provider_set = true;
        } else {
            rejection.add(.{ .unknown_option = argument });
        }
    }
    if (rejection.count > 0) return .{ .rejected = rejection };
    return .{ .admitted = .{ .auth = .{ .login = .{
        .provider_id = provider_id,
        .method = method,
    } } } };
}

fn parseLogout(argv: []const []const u8, rejection_value: Rejection) ParseResult {
    var rejection = rejection_value;
    var provider_id: []const u8 = "openai-codex";
    var provider_set = false;
    for (argv) |argument| {
        if (std.mem.startsWith(u8, argument, "-")) {
            rejection.add(.{ .unknown_option = argument });
        } else if (!provider_set) {
            provider_id = argument;
            provider_set = true;
        } else {
            rejection.add(.{ .unknown_option = argument });
        }
    }
    if (rejection.count > 0) return .{ .rejected = rejection };
    return .{ .admitted = .{ .auth = .{ .logout = .{ .provider_id = provider_id } } } };
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

fn parseAuthMethod(value: []const u8) ?AuthMethod {
    if (std.mem.eql(u8, value, "browser")) return .browser;
    if (std.mem.eql(u8, value, "device-code")) return .device_code;
    return null;
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
    try std.testing.expectEqualStrings("openai", launch.provider.?);
    try std.testing.expectEqualStrings("gpt-5", launch.model.?);
    try std.testing.expectEqualStrings("secret", launch.api_key.?);
    try std.testing.expectEqualStrings("prompt.md", launch.file_path.?);
    try std.testing.expectEqual(@as(usize, 2), launch.messages().len);
    try std.testing.expectEqualStrings("first", launch.messages()[0]);
    try std.testing.expectEqualStrings("second", launch.messages()[1]);
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

test "CLI surface admits provider-scoped login and logout" {
    const login = parseInvocation(&.{
        "auth",
        "login",
        "openai-codex",
        "--method",
        "device-code",
    }, .{ .stdin_is_tty = true, .stdout_is_tty = true });
    try std.testing.expect(login == .admitted);
    try std.testing.expect(login.admitted.auth == .login);
    try std.testing.expectEqualStrings("openai-codex", login.admitted.auth.login.provider_id);
    try std.testing.expectEqual(AuthMethod.device_code, login.admitted.auth.login.method);

    const logout = parseInvocation(&.{ "auth", "logout" }, .{ .stdin_is_tty = true, .stdout_is_tty = true });
    try std.testing.expect(logout == .admitted);
    try std.testing.expect(logout.admitted.auth == .logout);
    try std.testing.expectEqualStrings("openai-codex", logout.admitted.auth.logout.provider_id);
}

test "CLI surface rejects options outside their command grammar" {
    const extension_flag = parseInvocation(&.{ "-p", "--plan=careful" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(extension_flag == .rejected);
    try std.testing.expectEqualStrings("--plan=careful", extension_flag.rejected.diagnostics()[0].unknown_option);

    const logout_method = parseInvocation(&.{ "auth", "logout", "--method", "browser" }, .{
        .stdin_is_tty = true,
        .stdout_is_tty = true,
    });
    try std.testing.expect(logout_method == .rejected);
    try std.testing.expectEqualStrings("--method", logout_method.rejected.diagnostics()[0].unknown_option);
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
