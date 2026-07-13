const std = @import("std");

const argument_count_max = 32;
const message_count_max = 4;
const unknown_flag_count_max = 8;
pub const extension_count_max = 8;

pub const ParseError = error{
    TooManyArguments,
    TooManyMessages,
    TooManyUnknownFlags,
    TooManyExtensions,
    MissingOptionValue,
    UnknownOption,
    InvalidOptionValue,
};

pub const AppMode = enum {
    interactive,
    text,
    json,
    rpc,
};

const OutputMode = enum {
    text,
    json,
    rpc,
};

pub const AppArgs = struct {
    help: bool = false,
    version: bool = false,
    print: bool = false,
    no_session: bool = false,
    mode: ?OutputMode = null,
    session_selector: ?[]const u8 = null,
    continue_latest: bool = false,
    resume_picker: bool = false,
    messages: MessageList = .{},
    extensions: ExtensionList = .{},
    extensions_enabled: bool = true,
    project_trust: ?bool = null,
    unknown_flags: UnknownFlagList = .{},
};

const AuthCommand = struct {
    action: Action,
    provider: []const u8,

    pub const Action = enum {
        login,
        logout,
        status,
    };
};

pub const Command = union(enum) {
    app: AppArgs,
    auth: AuthCommand,
};

const UnknownFlag = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        boolean: bool,
        string: []const u8,
    };
};

const MessageList = BoundedList([]const u8, message_count_max, ParseError.TooManyMessages);
const ExtensionList = BoundedList([]const u8, extension_count_max, ParseError.TooManyExtensions);
const UnknownFlagList = BoundedList(UnknownFlag, unknown_flag_count_max, ParseError.TooManyUnknownFlags);

fn BoundedList(comptime T: type, comptime capacity: usize, comptime full_error: ParseError) type {
    return struct {
        const Self = @This();

        items: [capacity]T = undefined,
        count: usize = 0,

        pub fn append(self: *Self, value: T) ParseError!void {
            if (self.count == capacity) return full_error;
            self.items[self.count] = value;
            self.count += 1;
        }

        pub fn slice(self: *const Self) []const T {
            return self.items[0..self.count];
        }
    };
}

const FlagValueMode = enum {
    none,
    required,
};

const AppFlagTarget = enum {
    help,
    version,
    print,
    no_session,
    mode,
    resume_picker,
    session,
    continue_latest,
    extension,
    approve_project,
    deny_project,
    no_extensions,
};

const AppFlagSpec = struct {
    long: []const u8,
    short: ?[]const u8 = null,
    value: FlagValueMode = .none,
    target: AppFlagTarget,
    value_name: []const u8 = "",
    help: []const u8,
};

const app_flags = [_]AppFlagSpec{
    .{
        .long = "print",
        .short = "p",
        .target = .print,
        .help = "Non-interactive mode: process prompt and exit",
    },
    .{
        .long = "no-session",
        .target = .no_session,
        .help = "Do not save session history",
    },
    .{
        .long = "mode",
        .value = .required,
        .target = .mode,
        .value_name = "mode",
        .help = "Output mode: text, json, or rpc",
    },
    .{
        .long = "resume",
        .short = "r",
        .target = .resume_picker,
        .help = "Select a session to resume",
    },
    .{
        .long = "session",
        .value = .required,
        .target = .session,
        .value_name = "session",
        .help = "Use specific session file or id prefix",
    },
    .{
        .long = "continue",
        .short = "c",
        .target = .continue_latest,
        .help = "Continue the newest session for this cwd",
    },
    .{
        .long = "no-extensions",
        .target = .no_extensions,
        .help = "Disable extension discovery and loading",
    },
    .{
        .long = "approve",
        .short = "a",
        .target = .approve_project,
        .help = "Trust project-local extensions for this run",
    },
    .{
        .long = "no-approve",
        .short = "na",
        .target = .deny_project,
        .help = "Ignore project-local extensions for this run",
    },
    .{
        .long = "extension",
        .short = "e",
        .value = .required,
        .target = .extension,
        .value_name = "path",
        .help = "Load a trusted TypeScript extension (repeatable)",
    },
    .{
        .long = "version",
        .target = .version,
        .help = "Show zi version",
    },
    .{
        .long = "help",
        .short = "h",
        .target = .help,
        .help = "Show this help",
    },
};

const CommandHelp = struct {
    name: []const u8,
    usage: []const u8,
    description: []const u8,
};

const command_help = [_]CommandHelp{
    .{
        .name = "auth login openai-codex",
        .usage = "zi auth login openai-codex",
        .description = "Authenticate OpenAI Codex",
    },
    .{
        .name = "auth logout openai-codex",
        .usage = "zi auth logout openai-codex",
        .description = "Remove stored OpenAI Codex credentials",
    },
    .{
        .name = "auth status openai-codex",
        .usage = "zi auth status openai-codex",
        .description = "Show OpenAI Codex authentication status",
    },
};

pub fn parseIterator(args: *std.process.Args.Iterator) ParseError!Command {
    var values: [argument_count_max][]const u8 = undefined;
    var count: usize = 0;
    _ = args.next();
    while (args.next()) |arg| {
        if (count == values.len) return error.TooManyArguments;
        values[count] = arg;
        count += 1;
    }
    return parse(values[0..count]);
}

pub fn parse(args: []const []const u8) ParseError!Command {
    if (args.len > 0 and std.mem.eql(u8, args[0], "auth")) return .{ .auth = try parseAuth(args[1..]) };
    return .{ .app = try parseApp(args) };
}

pub fn resolveAppMode(args: AppArgs, stdin_is_tty: bool) AppMode {
    if (args.mode) |mode| {
        return switch (mode) {
            .text => .text,
            .json => .json,
            .rpc => .rpc,
        };
    }
    if (args.print or !stdin_is_tty) return .text;
    return .interactive;
}

fn parseAuth(args: []const []const u8) ParseError!AuthCommand {
    if (args.len != 2) return error.MissingOptionValue;
    const action = std.meta.stringToEnum(AuthCommand.Action, args[0]) orelse return error.UnknownOption;
    return .{ .action = action, .provider = args[1] };
}

fn parseApp(args: []const []const u8) ParseError!AppArgs {
    var result: AppArgs = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.startsWith(u8, arg, "--")) {
            try parseLongAppFlag(&result, args, &i);
        } else if (std.mem.startsWith(u8, arg, "-")) {
            try parseShortAppFlag(&result, args, &i);
        } else {
            try result.messages.append(arg);
        }
    }
    return result;
}

fn parseLongAppFlag(result: *AppArgs, args: []const []const u8, index: *usize) ParseError!void {
    const arg = args[index.*];
    const raw = arg[2..];
    const eq_index = std.mem.findScalar(u8, raw, '=');
    const name = if (eq_index) |eq| raw[0..eq] else raw;
    const inline_value = if (eq_index) |eq| raw[eq + 1 ..] else null;

    if (findLongAppFlag(name)) |spec| {
        const value = try readFlagValue(spec.value, inline_value, args, index);
        return applyAppFlag(result, spec, value);
    }

    if (inline_value) |value| {
        try result.unknown_flags.append(.{ .name = name, .value = .{ .string = value } });
    } else if (canUseNextAsUnknownFlagValue(args, index.*)) {
        index.* += 1;
        try result.unknown_flags.append(.{ .name = name, .value = .{ .string = args[index.*] } });
    } else {
        try result.unknown_flags.append(.{ .name = name, .value = .{ .boolean = true } });
    }
}

fn canUseNextAsUnknownFlagValue(args: []const []const u8, index: usize) bool {
    return index + 1 < args.len and
        !std.mem.startsWith(u8, args[index + 1], "-") and
        !std.mem.startsWith(u8, args[index + 1], "@");
}

fn parseShortAppFlag(result: *AppArgs, args: []const []const u8, index: *usize) ParseError!void {
    const arg = args[index.*];
    const name = arg[1..];
    const spec = findShortAppFlag(name) orelse return error.UnknownOption;
    const value = try readFlagValue(spec.value, null, args, index);
    try applyAppFlag(result, spec, value);
}

fn readFlagValue(
    mode: FlagValueMode,
    inline_value: ?[]const u8,
    args: []const []const u8,
    index: *usize,
) ParseError!?[]const u8 {
    return switch (mode) {
        .none => if (inline_value == null) null else error.InvalidOptionValue,
        .required => blk: {
            if (inline_value) |value| break :blk value;
            if (index.* + 1 >= args.len) return error.MissingOptionValue;
            index.* += 1;
            break :blk args[index.*];
        },
    };
}

fn hasResumePolicy(result: AppArgs) bool {
    return result.session_selector != null or result.continue_latest or result.resume_picker;
}

fn hasSessionConflict(result: AppArgs) bool {
    return result.no_session or hasResumePolicy(result);
}

fn applyAppFlag(result: *AppArgs, spec: AppFlagSpec, value: ?[]const u8) ParseError!void {
    switch (spec.target) {
        .help => result.help = true,
        .version => result.version = true,
        .print => result.print = true,
        .no_session => {
            if (hasResumePolicy(result.*)) return error.InvalidOptionValue;
            result.no_session = true;
        },
        .mode => result.mode = std.meta.stringToEnum(OutputMode, value orelse return error.MissingOptionValue) orelse
            return error.InvalidOptionValue,
        .resume_picker => {
            if (hasSessionConflict(result.*)) return error.InvalidOptionValue;
            result.resume_picker = true;
        },
        .session => {
            if (hasSessionConflict(result.*)) return error.InvalidOptionValue;
            const session = value orelse return error.MissingOptionValue;
            if (session.len == 0) return error.InvalidOptionValue;
            result.session_selector = session;
        },
        .continue_latest => {
            if (hasSessionConflict(result.*)) return error.InvalidOptionValue;
            result.continue_latest = true;
        },
        .extension => {
            if (!result.extensions_enabled) return error.InvalidOptionValue;
            const path = value orelse return error.MissingOptionValue;
            if (path.len == 0) return error.InvalidOptionValue;
            try result.extensions.append(path);
        },
        .approve_project => {
            if (result.project_trust != null) return error.InvalidOptionValue;
            result.project_trust = true;
        },
        .deny_project => {
            if (result.project_trust != null) return error.InvalidOptionValue;
            result.project_trust = false;
        },
        .no_extensions => {
            if (result.extensions.count != 0 or !result.extensions_enabled) return error.InvalidOptionValue;
            result.extensions_enabled = false;
        },
    }
}

fn findLongAppFlag(name: []const u8) ?AppFlagSpec {
    for (app_flags) |spec| {
        if (std.mem.eql(u8, spec.long, name)) return spec;
    }
    return null;
}

fn findShortAppFlag(name: []const u8) ?AppFlagSpec {
    for (app_flags) |spec| {
        if (spec.short) |short| {
            if (std.mem.eql(u8, short, name)) return spec;
        }
    }
    return null;
}

pub fn writeHelp(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\zi - AI coding assistant with read, bash, edit, write tools
        \\
        \\Usage:
        \\  zi [options] [prompt]
        \\
        \\Commands:
        \\
    );
    for (command_help) |command| {
        try writer.print("  {s}", .{command.usage});
        try writePadding(writer, command.usage.len, 34);
        try writer.print("{s}\n", .{command.description});
    }
    try writer.writeAll(
        \\
        \\Options:
        \\
    );
    for (app_flags) |flag| {
        try writeFlagHelp(writer, flag);
    }
    try writer.writeAll(
        \\
        \\Examples:
        \\  zi
        \\  zi "explain this repo"
        \\  zi -p "hello"
        \\  zi --mode json "explain this repo"
        \\  zi --resume
        \\  zi --continue
        \\  zi auth status openai-codex
        \\
    );
    try writer.flush();
}

pub fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: zi [options] [prompt]
        \\       zi --resume
        \\       zi --session <session> [prompt]
        \\       zi --continue [prompt]
        \\       zi auth login openai-codex
        \\       zi auth logout openai-codex
        \\       zi auth status openai-codex
        \\
    );
    try writer.flush();
}

fn writeFlagHelp(writer: *std.Io.Writer, flag: AppFlagSpec) !void {
    try writer.writeAll("  ");
    if (flag.short) |short| {
        try writer.print("-{s}, ", .{short});
    } else {
        try writer.writeAll("    ");
    }
    try writer.print("--{s}", .{flag.long});
    switch (flag.value) {
        .none => {},
        .required => try writer.print(" <{s}>", .{flag.value_name}),
    }
    const width = 36;
    const short_len = if (flag.short) |short| short.len + 4 else 4;
    const value_len = switch (flag.value) {
        .none => 0,
        .required => flag.value_name.len + 3,
    };
    try writePadding(writer, short_len + flag.long.len + 2 + value_len, width);
    try writer.print("{s}\n", .{flag.help});
}

fn writePadding(writer: *std.Io.Writer, used: usize, target: usize) !void {
    const count = target -| used;
    for (0..count) |_| try writer.writeByte(' ');
}

test "parses print prompt" {
    const command = try parse(&.{ "-p", "hello" });
    const app = command.app;
    try std.testing.expect(app.print);
    try std.testing.expectEqualStrings("hello", app.messages.slice()[0]);
}

test "parses resume picker" {
    const app = (try parse(&.{"--resume"})).app;
    try std.testing.expect(app.resume_picker);
    try std.testing.expect(app.session_selector == null);
    try std.testing.expect(!app.continue_latest);
}

test "resume flag does not consume a session argument" {
    const app = (try parse(&.{ "--resume", "hello" })).app;
    try std.testing.expect(app.resume_picker);
    try std.testing.expect(app.session_selector == null);
    try std.testing.expectEqualStrings("hello", app.messages.slice()[0]);
}

test "parses explicit session selector" {
    const app = (try parse(&.{ "--session", "t_session.jsonl" })).app;
    try std.testing.expectEqualStrings("t_session.jsonl", app.session_selector.?);
    try std.testing.expect(!app.resume_picker);
    try std.testing.expect(!app.continue_latest);
}

test "parses continue latest" {
    const app = (try parse(&.{"--continue"})).app;
    try std.testing.expect(app.continue_latest);
    try std.testing.expect(app.session_selector == null);
    try std.testing.expect(!app.resume_picker);
}

test "parses no-session" {
    const app = (try parse(&.{"--no-session"})).app;
    try std.testing.expect(app.no_session);
}

test "parses resume and continue short flags" {
    try std.testing.expect((try parse(&.{"-r"})).app.resume_picker);
    try std.testing.expect((try parse(&.{"-c"})).app.continue_latest);
}

test "rejects duplicate resume policy" {
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--session", "a.jsonl", "--continue" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--continue", "--session", "a.jsonl" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--session", "a.jsonl", "--session", "b.jsonl" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--continue", "--continue" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--resume", "--continue" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--resume", "--session", "a.jsonl" }));
}

test "rejects no-session with resume policy" {
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--no-session", "--session", "a.jsonl" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--session", "a.jsonl", "--no-session" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--no-session", "--continue" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--resume", "--no-session" }));
}

test "usage includes session forms" {
    var buffer: [512]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeUsage(&writer);

    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "zi --resume") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "zi --session <session> [prompt]") != null);
    try std.testing.expect(std.mem.indexOf(u8, writer.buffered(), "zi --continue [prompt]") != null);
}

test "parses bounded repeatable extension paths" {
    const app = (try parse(&.{ "--extension", "one.ts", "--extension=two.ts", "-e", "three.ts" })).app;
    try std.testing.expectEqual(@as(usize, 3), app.extensions.count);
    try std.testing.expectEqualStrings("one.ts", app.extensions.slice()[0]);
    try std.testing.expectEqualStrings("two.ts", app.extensions.slice()[1]);
    try std.testing.expectEqualStrings("three.ts", app.extensions.slice()[2]);

    var too_many: [extension_count_max * 2 + 2][]const u8 = undefined;
    for (0..extension_count_max + 1) |index| {
        too_many[index * 2] = "--extension";
        too_many[index * 2 + 1] = "extension.ts";
    }
    try std.testing.expectError(error.TooManyExtensions, parse(&too_many));
}

test "no-extensions disables all loading and conflicts with explicit paths" {
    try std.testing.expect(!(try parse(&.{"--no-extensions"})).app.extensions_enabled);
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--no-extensions", "--extension", "one.ts" }));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--extension", "one.ts", "--no-extensions" }));
}

test "parses one-run project trust overrides" {
    try std.testing.expectEqual(true, (try parse(&.{"--approve"})).app.project_trust.?);
    try std.testing.expectEqual(true, (try parse(&.{"-a"})).app.project_trust.?);
    try std.testing.expectEqual(false, (try parse(&.{"--no-approve"})).app.project_trust.?);
    try std.testing.expectEqual(false, (try parse(&.{"-na"})).app.project_trust.?);
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--approve", "--no-approve" }));
}

test "parses help" {
    const app = (try parse(&.{"--help"})).app;
    try std.testing.expect(app.help);
}

test "parses version" {
    const app = (try parse(&.{"--version"})).app;
    try std.testing.expect(app.version);
}

test "unknown option fails" {
    try std.testing.expectError(error.UnknownOption, parse(&.{"-x"}));
}

test "parses output mode from spec" {
    const app = (try parse(&.{ "--mode", "json", "hello" })).app;
    try std.testing.expectEqual(.json, app.mode.?);
    try std.testing.expectEqual(.json, resolveAppMode(app, true));
    try std.testing.expectError(error.InvalidOptionValue, parse(&.{ "--mode", "yaml" }));
}

test "captures unknown long flags for future extension ownership" {
    const app = (try parse(&.{ "--plan", "--shape=fast", "--owner", "cli", "hello" })).app;
    try std.testing.expectEqual(@as(usize, 3), app.unknown_flags.count);
    try std.testing.expectEqualStrings("plan", app.unknown_flags.slice()[0].name);
    try std.testing.expect(app.unknown_flags.slice()[0].value.boolean);
    try std.testing.expectEqualStrings("shape", app.unknown_flags.slice()[1].name);
    try std.testing.expectEqualStrings("fast", app.unknown_flags.slice()[1].value.string);
    try std.testing.expectEqualStrings("owner", app.unknown_flags.slice()[2].name);
    try std.testing.expectEqualStrings("cli", app.unknown_flags.slice()[2].value.string);
}

test "resolves app mode from flags and stdin" {
    try std.testing.expectEqual(.text, resolveAppMode((try parse(&.{"-p"})).app, true));
    try std.testing.expectEqual(.text, resolveAppMode((try parse(&.{})).app, false));
    try std.testing.expectEqual(.interactive, resolveAppMode((try parse(&.{})).app, true));
}

test "parses auth command" {
    const auth = (try parse(&.{ "auth", "status", "openai-codex" })).auth;
    try std.testing.expectEqual(.status, auth.action);
    try std.testing.expectEqualStrings("openai-codex", auth.provider);
}

test "writes generated help from specs" {
    var buffer: [2048]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeHelp(&writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.indexOf(u8, output, "zi [options] [prompt]") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--print") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "--no-session") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zi auth status openai-codex") != null);
}

test "writes usage without exiting" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeUsage(&writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, output, "usage: zi [options] [prompt]"));
}
