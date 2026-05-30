const std = @import("std");

pub const argument_count_max = 16;
pub const message_count_max = 4;
pub const unknown_flag_count_max = 8;

pub const ParseError = error{
    TooManyArguments,
    TooManyMessages,
    TooManyUnknownFlags,
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

pub const OutputMode = enum {
    text,
    json,
    rpc,
};

pub const AppArgs = struct {
    help: bool = false,
    print: bool = false,
    mode: ?OutputMode = null,
    messages: MessageList = .{},
    unknown_flags: UnknownFlagList = .{},
};

pub const AuthCommand = struct {
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

pub const UnknownFlag = struct {
    name: []const u8,
    value: Value,

    pub const Value = union(enum) {
        boolean: bool,
        string: []const u8,
    };
};

const MessageList = BoundedList([]const u8, message_count_max, ParseError.TooManyMessages);
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
    print,
    mode,
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
        .long = "mode",
        .value = .required,
        .target = .mode,
        .value_name = "mode",
        .help = "Output mode: text, json, or rpc",
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

fn applyAppFlag(result: *AppArgs, spec: AppFlagSpec, value: ?[]const u8) ParseError!void {
    switch (spec.target) {
        .help => result.help = true,
        .print => result.print = true,
        .mode => result.mode = std.meta.stringToEnum(OutputMode, value orelse return error.MissingOptionValue) orelse
            return error.InvalidOptionValue,
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
        \\  zi auth status openai-codex
        \\
    );
    try writer.flush();
}

pub fn writeUsage(writer: *std.Io.Writer) !void {
    try writer.writeAll(
        \\usage: zi [options] [prompt]
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
    if (flag.value == .required) try writer.print(" <{s}>", .{flag.value_name});
    const width = 36;
    const short_len = if (flag.short) |short| short.len + 4 else 4;
    const value_len = if (flag.value == .required) flag.value_name.len + 3 else 0;
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

test "parses help" {
    const app = (try parse(&.{"--help"})).app;
    try std.testing.expect(app.help);
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
    try std.testing.expect(std.mem.indexOf(u8, output, "zi auth status openai-codex") != null);
}

test "writes usage without exiting" {
    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);

    try writeUsage(&writer);
    const output = writer.buffered();
    try std.testing.expect(std.mem.startsWith(u8, output, "usage: zi [options] [prompt]"));
}
