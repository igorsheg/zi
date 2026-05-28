const std = @import("std");

pub const argument_count_max = 16;
pub const message_count_max = 4;

pub const ParseError = error{
    TooManyArguments,
    TooManyMessages,
    MissingOptionValue,
    UnknownOption,
};

pub const AppMode = enum {
    interactive,
    print,
};

pub const AppArgs = struct {
    help: bool = false,
    print: bool = false,
    messages: MessageList = .{},
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

const MessageList = BoundedList([]const u8, message_count_max, ParseError.TooManyMessages);

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
    if (args.print or !stdin_is_tty) return .print;
    return .interactive;
}

fn parseAuth(args: []const []const u8) ParseError!AuthCommand {
    if (args.len != 2) return error.MissingOptionValue;
    const action = std.meta.stringToEnum(AuthCommand.Action, args[0]) orelse return error.UnknownOption;
    return .{ .action = action, .provider = args[1] };
}

fn parseApp(args: []const []const u8) ParseError!AppArgs {
    var result: AppArgs = .{};
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            result.help = true;
        } else if (std.mem.eql(u8, arg, "--print") or std.mem.eql(u8, arg, "-p")) {
            result.print = true;
        } else if (std.mem.startsWith(u8, arg, "-")) {
            return error.UnknownOption;
        } else {
            try result.messages.append(arg);
        }
    }
    return result;
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
    try std.testing.expectError(error.UnknownOption, parse(&.{"--mode"}));
    try std.testing.expectError(error.UnknownOption, parse(&.{"-x"}));
}

test "resolves app mode from flags and stdin" {
    try std.testing.expectEqual(.print, resolveAppMode((try parse(&.{"-p"})).app, true));
    try std.testing.expectEqual(.print, resolveAppMode((try parse(&.{})).app, false));
    try std.testing.expectEqual(.interactive, resolveAppMode((try parse(&.{})).app, true));
}

test "parses auth command" {
    const auth = (try parse(&.{ "auth", "status", "openai-codex" })).auth;
    try std.testing.expectEqual(.status, auth.action);
    try std.testing.expectEqualStrings("openai-codex", auth.provider);
}
