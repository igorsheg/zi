const std = @import("std");

const max_arguments = 64;
const max_argument_bytes = 256 * 1024;
const max_total_bytes = 1024 * 1024;

pub const Mode = enum {
    text,
    json,
    rpc,
};

pub const AppMode = enum {
    interactive,
    print,
    json,
    rpc,
};

pub const AuthMethod = enum {
    browser,
    device_code,
};

pub const AuthCommand = union(enum) {
    login: struct {
        provider_id: []const u8,
        method: AuthMethod,
    },
    logout: struct {
        provider_id: []const u8,
    },
};

pub const UnknownFlagValue = union(enum) {
    boolean: bool,
    string: []const u8,
};

pub const UnknownFlag = struct {
    name: []const u8,
    value: UnknownFlagValue,
};

pub const DiagnosticSeverity = enum {
    warning,
    @"error",
};

pub const DiagnosticDetail = union(enum) {
    too_many_arguments,
    arguments_too_large,
    argument_too_large: usize,
    invalid_utf8: usize,
    missing_value: []const u8,
    invalid_mode: []const u8,
    invalid_auth_command: []const u8,
    invalid_auth_method: []const u8,
    unknown_option: []const u8,
};

pub const Diagnostic = struct {
    severity: DiagnosticSeverity = .@"error",
    detail: DiagnosticDetail,
};

pub const Args = struct {
    allocator: std.mem.Allocator,
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    api_key: ?[]const u8 = null,
    auth: ?AuthCommand = null,
    mode: ?Mode = null,
    print: bool = false,
    help: bool = false,
    version: bool = false,
    messages: []const []const u8,
    file_args: []const []const u8,
    unknown_flags: []const UnknownFlag,
    diagnostics: []const Diagnostic,

    pub fn deinit(self: *Args) void {
        self.allocator.free(self.messages);
        self.allocator.free(self.file_args);
        self.allocator.free(self.unknown_flags);
        self.allocator.free(self.diagnostics);
        self.* = undefined;
    }

    pub fn hasErrors(self: *const Args) bool {
        for (self.diagnostics) |diagnostic| {
            if (diagnostic.severity == .@"error") return true;
        }
        return false;
    }
};

pub fn parseArgs(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
) error{OutOfMemory}!Args {
    var messages: std.ArrayList([]const u8) = .empty;
    defer messages.deinit(allocator);
    var file_args: std.ArrayList([]const u8) = .empty;
    defer file_args.deinit(allocator);
    var unknown_flags: std.ArrayList(UnknownFlag) = .empty;
    defer unknown_flags.deinit(allocator);
    var diagnostics: std.ArrayList(Diagnostic) = .empty;
    defer diagnostics.deinit(allocator);

    var result: Args = .{
        .allocator = allocator,
        .messages = &.{},
        .file_args = &.{},
        .unknown_flags = &.{},
        .diagnostics = &.{},
    };
    if (argv.len > max_arguments) {
        try diagnostics.append(allocator, .{ .detail = .too_many_arguments });
        return finish(allocator, result, &messages, &file_args, &unknown_flags, &diagnostics);
    }

    var total_bytes: usize = 0;
    for (argv, 0..) |argument, index| {
        if (argument.len > max_argument_bytes) {
            try diagnostics.append(allocator, .{ .detail = .{ .argument_too_large = index } });
            continue;
        }
        if (argument.len > max_total_bytes - total_bytes) {
            try diagnostics.append(allocator, .{ .detail = .arguments_too_large });
            return finish(allocator, result, &messages, &file_args, &unknown_flags, &diagnostics);
        }
        total_bytes += argument.len;
        if (!std.unicode.utf8ValidateSlice(argument)) {
            try diagnostics.append(allocator, .{ .detail = .{ .invalid_utf8 = index } });
        }
    }
    if (diagnostics.items.len > 0) {
        return finish(allocator, result, &messages, &file_args, &unknown_flags, &diagnostics);
    }
    if (argv.len > 0 and std.mem.eql(u8, argv[0], "auth")) {
        try parseAuthCommand(argv, &result, &diagnostics);
        return finish(allocator, result, &messages, &file_args, &unknown_flags, &diagnostics);
    }

    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, argument, "--version") or std.mem.eql(u8, argument, "-v")) {
            result.version = true;
        } else if (std.mem.eql(u8, argument, "--print") or std.mem.eql(u8, argument, "-p")) {
            result.print = true;
            if (index + 1 < argv.len and isPrintPrompt(argv[index + 1])) {
                index += 1;
                try messages.append(allocator, argv[index]);
            }
        } else if (std.mem.eql(u8, argument, "--mode")) {
            const value = valueAfter(argv, &index) orelse {
                try diagnostics.append(allocator, .{ .detail = .{ .missing_value = argument } });
                continue;
            };
            result.mode = parseMode(value) orelse {
                try diagnostics.append(allocator, .{ .detail = .{ .invalid_mode = value } });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--provider")) {
            result.provider = valueAfter(argv, &index) orelse {
                try diagnostics.append(allocator, .{ .detail = .{ .missing_value = argument } });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--model")) {
            result.model = valueAfter(argv, &index) orelse {
                try diagnostics.append(allocator, .{ .detail = .{ .missing_value = argument } });
                continue;
            };
        } else if (std.mem.eql(u8, argument, "--api-key")) {
            result.api_key = valueAfter(argv, &index) orelse {
                try diagnostics.append(allocator, .{ .detail = .{ .missing_value = argument } });
                continue;
            };
        } else if (std.mem.startsWith(u8, argument, "@")) {
            try file_args.append(allocator, argument[1..]);
        } else if (std.mem.startsWith(u8, argument, "--")) {
            try appendUnknownFlag(allocator, &unknown_flags, argv, &index);
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try diagnostics.append(allocator, .{ .detail = .{ .unknown_option = argument } });
        } else {
            try messages.append(allocator, argument);
        }
    }

    return finish(allocator, result, &messages, &file_args, &unknown_flags, &diagnostics);
}

pub fn resolveAppMode(args: *const Args, stdin_is_tty: bool, stdout_is_tty: bool) AppMode {
    if (args.mode == .rpc) return .rpc;
    if (args.mode == .json) return .json;
    if (args.print or !stdin_is_tty or !stdout_is_tty) return .print;
    return .interactive;
}

fn parseAuthCommand(
    argv: []const []const u8,
    result: *Args,
    diagnostics: *std.ArrayList(Diagnostic),
) error{OutOfMemory}!void {
    if (argv.len < 2) {
        try diagnostics.append(result.allocator, .{ .detail = .{ .invalid_auth_command = "" } });
        return;
    }
    const action = argv[1];
    var provider_id: []const u8 = "openai-codex";
    var provider_set = false;
    var method: AuthMethod = .browser;
    var index: usize = 2;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (std.mem.eql(u8, argument, "--method")) {
            const value = valueAfter(argv, &index) orelse {
                try diagnostics.append(result.allocator, .{ .detail = .{ .missing_value = argument } });
                continue;
            };
            method = if (std.mem.eql(u8, value, "browser"))
                .browser
            else if (std.mem.eql(u8, value, "device-code"))
                .device_code
            else {
                try diagnostics.append(result.allocator, .{ .detail = .{ .invalid_auth_method = value } });
                continue;
            };
        } else if (std.mem.startsWith(u8, argument, "-")) {
            try diagnostics.append(result.allocator, .{ .detail = .{ .unknown_option = argument } });
        } else if (!provider_set) {
            provider_id = argument;
            provider_set = true;
        } else {
            try diagnostics.append(result.allocator, .{ .detail = .{ .unknown_option = argument } });
        }
    }
    if (std.mem.eql(u8, action, "login")) {
        result.auth = .{ .login = .{ .provider_id = provider_id, .method = method } };
    } else if (std.mem.eql(u8, action, "logout")) {
        result.auth = .{ .logout = .{ .provider_id = provider_id } };
    } else {
        try diagnostics.append(result.allocator, .{ .detail = .{ .invalid_auth_command = action } });
    }
}

fn finish(
    allocator: std.mem.Allocator,
    result_value: Args,
    messages: *std.ArrayList([]const u8),
    file_args: *std.ArrayList([]const u8),
    unknown_flags: *std.ArrayList(UnknownFlag),
    diagnostics: *std.ArrayList(Diagnostic),
) error{OutOfMemory}!Args {
    var result = result_value;
    result.messages = messages.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(result.messages);
    result.file_args = file_args.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(result.file_args);
    result.unknown_flags = unknown_flags.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(result.unknown_flags);
    result.diagnostics = diagnostics.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return result;
}

fn valueAfter(argv: []const []const u8, index: *usize) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    const value = argv[index.* + 1];
    if (std.mem.startsWith(u8, value, "-") or std.mem.startsWith(u8, value, "@")) return null;
    index.* += 1;
    return value;
}

fn parseMode(value: []const u8) ?Mode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    if (std.mem.eql(u8, value, "rpc")) return .rpc;
    return null;
}

fn isPrintPrompt(value: []const u8) bool {
    return !std.mem.startsWith(u8, value, "@") and
        (!std.mem.startsWith(u8, value, "-") or std.mem.startsWith(u8, value, "---"));
}

fn appendUnknownFlag(
    allocator: std.mem.Allocator,
    unknown_flags: *std.ArrayList(UnknownFlag),
    argv: []const []const u8,
    index: *usize,
) error{OutOfMemory}!void {
    const argument = argv[index.*][2..];
    if (std.mem.findScalar(u8, argument, '=')) |equals| {
        try setUnknownFlag(
            allocator,
            unknown_flags,
            argument[0..equals],
            .{ .string = argument[equals + 1 ..] },
        );
        return;
    }
    if (index.* + 1 < argv.len) {
        const next = argv[index.* + 1];
        if (!std.mem.startsWith(u8, next, "-") and !std.mem.startsWith(u8, next, "@")) {
            index.* += 1;
            try setUnknownFlag(allocator, unknown_flags, argument, .{ .string = argv[index.*] });
            return;
        }
    }
    try setUnknownFlag(allocator, unknown_flags, argument, .{ .boolean = true });
}

fn setUnknownFlag(
    allocator: std.mem.Allocator,
    unknown_flags: *std.ArrayList(UnknownFlag),
    name: []const u8,
    value: UnknownFlagValue,
) error{OutOfMemory}!void {
    for (unknown_flags.items) |*flag| {
        if (std.mem.eql(u8, flag.name, name)) {
            flag.value = value;
            return;
        }
    }
    try unknown_flags.append(allocator, .{ .name = name, .value = value });
}

test "parseArgs admits OAuth login and logout commands" {
    var login = try parseArgs(std.testing.allocator, &.{
        "auth",
        "login",
        "openai-codex",
        "--method",
        "device-code",
    });
    defer login.deinit();
    try std.testing.expect(login.auth.? == .login);
    try std.testing.expectEqualStrings("openai-codex", login.auth.?.login.provider_id);
    try std.testing.expect(login.auth.?.login.method == .device_code);

    var logout = try parseArgs(std.testing.allocator, &.{ "auth", "logout" });
    defer logout.deinit();
    try std.testing.expect(logout.auth.? == .logout);
    try std.testing.expectEqualStrings("openai-codex", logout.auth.?.logout.provider_id);
}

test "parseArgs preserves pi print, prompt, file, and extension flag behavior" {
    var parsed = try parseArgs(std.testing.allocator, &.{
        "-p",
        "---\ntitle: hello\n---\nSay hi.",
        "-h",
        "-v",
        "@prompt.md",
        "--provider",
        "first",
        "--provider",
        "openai",
        "--model",
        "gpt-5",
        "--api-key",
        "secret",
        "--mode",
        "text",
        "second message",
        "--plan=careful",
        "--label",
        "old",
        "--label",
        "work",
        "--flag",
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.print);
    try std.testing.expect(parsed.help);
    try std.testing.expect(parsed.version);
    try std.testing.expectEqualStrings("openai", parsed.provider.?);
    try std.testing.expectEqualStrings("gpt-5", parsed.model.?);
    try std.testing.expectEqualStrings("secret", parsed.api_key.?);
    try std.testing.expect(parsed.mode == .text);
    try std.testing.expectEqual(@as(usize, 2), parsed.messages.len);
    try std.testing.expectEqualStrings("---\ntitle: hello\n---\nSay hi.", parsed.messages[0]);
    try std.testing.expectEqualStrings("second message", parsed.messages[1]);
    try std.testing.expectEqualStrings("prompt.md", parsed.file_args[0]);
    try std.testing.expectEqual(@as(usize, 3), parsed.unknown_flags.len);
    try std.testing.expectEqualStrings("plan", parsed.unknown_flags[0].name);
    try std.testing.expectEqualStrings("careful", parsed.unknown_flags[0].value.string);
    try std.testing.expectEqualStrings("work", parsed.unknown_flags[1].value.string);
    try std.testing.expect(parsed.unknown_flags[2].value.boolean);
    try std.testing.expectEqual(@as(usize, 0), parsed.diagnostics.len);
}

test "parseArgs does not consume an option following print" {
    var parsed = try parseArgs(std.testing.allocator, &.{ "-p", "--provider", "openai", "Say hi." });
    defer parsed.deinit();
    try std.testing.expect(parsed.print);
    try std.testing.expectEqualStrings("openai", parsed.provider.?);
    try std.testing.expectEqual(@as(usize, 1), parsed.messages.len);
    try std.testing.expectEqualStrings("Say hi.", parsed.messages[0]);
}

test "parseArgs records malformed admitted arguments without exposing values" {
    var parsed = try parseArgs(std.testing.allocator, &.{
        "--mode",
        "yaml",
        "--model",
        "-x",
        "\xff",
    });
    defer parsed.deinit();

    try std.testing.expect(parsed.hasErrors());
    try std.testing.expectEqual(@as(usize, 1), parsed.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 4), parsed.diagnostics[0].detail.invalid_utf8);

    var syntax = try parseArgs(
        std.testing.allocator,
        &.{ "-x", "--mode", "yaml", "--model", "--provider", "openai" },
    );
    defer syntax.deinit();
    try std.testing.expectEqual(@as(usize, 3), syntax.diagnostics.len);
    try std.testing.expectEqualStrings("-x", syntax.diagnostics[0].detail.unknown_option);
    try std.testing.expectEqualStrings("yaml", syntax.diagnostics[1].detail.invalid_mode);
    try std.testing.expectEqualStrings("--model", syntax.diagnostics[2].detail.missing_value);
    try std.testing.expectEqualStrings("openai", syntax.provider.?);
}

test "parseArgs admits exact byte and count bounds" {
    const argument = try std.testing.allocator.alloc(u8, max_argument_bytes);
    defer std.testing.allocator.free(argument);
    @memset(argument, 'x');
    var exact_bytes = try parseArgs(std.testing.allocator, &.{ argument, argument, argument, argument });
    defer exact_bytes.deinit();
    try std.testing.expectEqual(@as(usize, 0), exact_bytes.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 4), exact_bytes.messages.len);

    var over_bytes = try parseArgs(std.testing.allocator, &.{ argument, argument, argument, argument, argument });
    defer over_bytes.deinit();
    try std.testing.expectEqual(@as(usize, 1), over_bytes.diagnostics.len);
    try std.testing.expect(over_bytes.diagnostics[0].detail == .arguments_too_large);

    const too_large = try std.testing.allocator.alloc(u8, max_argument_bytes + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'x');
    var oversized = try parseArgs(std.testing.allocator, &.{too_large});
    defer oversized.deinit();
    try std.testing.expectEqual(@as(usize, 1), oversized.diagnostics.len);
    try std.testing.expectEqual(@as(usize, 0), oversized.diagnostics[0].detail.argument_too_large);

    const arguments = try std.testing.allocator.alloc([]const u8, max_arguments);
    defer std.testing.allocator.free(arguments);
    @memset(arguments, "");
    var exact_count = try parseArgs(std.testing.allocator, arguments);
    defer exact_count.deinit();
    try std.testing.expectEqual(max_arguments, exact_count.messages.len);

    const extra_arguments = try std.testing.allocator.alloc([]const u8, max_arguments + 1);
    defer std.testing.allocator.free(extra_arguments);
    @memset(extra_arguments, "");
    var over_count = try parseArgs(std.testing.allocator, extra_arguments);
    defer over_count.deinit();
    try std.testing.expectEqual(@as(usize, 1), over_count.diagnostics.len);
    try std.testing.expect(over_count.diagnostics[0].detail == .too_many_arguments);
}

test "resolveAppMode follows pi precedence" {
    var parsed = try parseArgs(std.testing.allocator, &.{});
    defer parsed.deinit();
    try std.testing.expect(resolveAppMode(&parsed, true, true) == .interactive);
    try std.testing.expect(resolveAppMode(&parsed, false, true) == .print);
    try std.testing.expect(resolveAppMode(&parsed, true, false) == .print);

    parsed.print = true;
    parsed.mode = .text;
    try std.testing.expect(resolveAppMode(&parsed, true, true) == .print);
    parsed.mode = .json;
    try std.testing.expect(resolveAppMode(&parsed, true, true) == .json);
    parsed.mode = .rpc;
    try std.testing.expect(resolveAppMode(&parsed, false, false) == .rpc);

    parsed.print = false;
    parsed.mode = .text;
    try std.testing.expect(resolveAppMode(&parsed, true, true) == .interactive);
}
