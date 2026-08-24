const std = @import("std");
const ai = @import("../../ai/root.zig");

pub const max_identifier_bytes = 512;

pub const Kind = enum {
    login,
    model,
    thinking,
};

pub const Category = enum {
    account,
    model,

    pub fn label(self: Category) []const u8 {
        return switch (self) {
            .account => "Account",
            .model => "Model",
        };
    }
};

pub const Spec = struct {
    kind: Kind,
    command: []const u8,
    usage: []const u8,
    description: []const u8,
    category: Category,
    requires_args: bool,
};

pub const specs = [_]Spec{
    .{
        .kind = .login,
        .command = "/login",
        .usage = "/login <provider> [--device]",
        .description = "sign in to a provider",
        .category = .account,
        .requires_args = true,
    },
    .{
        .kind = .model,
        .command = "/model",
        .usage = "/model <provider/model>",
        .description = "select the session model",
        .category = .model,
        .requires_args = true,
    },
    .{
        .kind = .thinking,
        .command = "/thinking",
        .usage = "/thinking <off|minimal|low|medium|high|xhigh|max>",
        .description = "set the thinking level",
        .category = .model,
        .requires_args = true,
    },
};

pub const Invocation = struct {
    spec: *const Spec,
    arguments: []const u8,
};

pub const Parsed = union(enum) {
    ordinary,
    command: Invocation,
};

pub const ParseError = error{
    InvalidCommand,
    IdentifierTooLong,
};

pub const Login = struct {
    provider: []const u8,
    method: ai.oauth.LoginMethod,

    pub fn parse(arguments: []const u8) ParseError!Login {
        var words = std.mem.tokenizeAny(u8, arguments, " \t\r\n");
        const provider = words.next() orelse return error.InvalidCommand;
        try validateIdentifier(provider);
        const option = words.next();
        if (words.next() != null) return error.InvalidCommand;
        const method: ai.oauth.LoginMethod = if (option) |value| method: {
            if (!std.mem.eql(u8, value, "--device")) return error.InvalidCommand;
            break :method .device_code;
        } else .browser;
        return .{ .provider = provider, .method = method };
    }
};

pub const Thinking = struct {
    level: ai.ThinkingLevel,

    pub fn parse(arguments: []const u8) ParseError!Thinking {
        var words = std.mem.tokenizeAny(u8, arguments, " \t\r\n");
        const value = words.next() orelse return error.InvalidCommand;
        if (words.next() != null) return error.InvalidCommand;
        return .{ .level = std.meta.stringToEnum(ai.ThinkingLevel, value) orelse
            return error.InvalidCommand };
    }
};

pub const Model = struct {
    selection: ai.ModelIdentity,

    pub fn parse(arguments: []const u8) ParseError!Model {
        var words = std.mem.tokenizeAny(u8, arguments, " \t\r\n");
        const target = words.next() orelse return error.InvalidCommand;
        if (words.next() != null) return error.InvalidCommand;
        const slash = std.mem.findScalar(u8, target, '/') orelse return error.InvalidCommand;
        if (slash == 0 or slash + 1 == target.len) return error.InvalidCommand;
        const selection: ai.ModelIdentity = .{
            .provider = target[0..slash],
            .model = target[slash + 1 ..],
        };
        try validateIdentifier(selection.provider);
        try validateIdentifier(selection.model);
        return .{ .selection = selection };
    }
};

/// Recognizes one catalog command and borrows its unparsed argument text.
/// Command owners interpret that text through their focused parsers.
pub fn parse(text: []const u8) Parsed {
    const source = std.mem.trim(u8, text, " \t\r\n");
    if (source.len == 0) return .ordinary;
    const token_end = for (source, 0..) |byte, index| {
        if (byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n') break index;
    } else source.len;
    const command = source[0..token_end];
    for (&specs) |*spec| {
        if (!std.mem.eql(u8, command, spec.command)) continue;
        return .{ .command = .{
            .spec = spec,
            .arguments = std.mem.trim(u8, source[token_end..], " \t\r\n"),
        } };
    }
    return .ordinary;
}

/// Returns the leading slash token through the cursor while it is still a
/// command-name completion. Arguments and ordinary text have no projection.
pub fn completionPrefix(input: []const u8, cursor: usize) ?[]const u8 {
    if (cursor > input.len) return null;
    const before_cursor = input[0..cursor];
    const trimmed = std.mem.trimStart(u8, before_cursor, " \t\r\n");
    if (trimmed.len == 0 or trimmed[0] != '/') return null;
    for (trimmed) |byte| if (std.ascii.isWhitespace(byte)) return null;
    return trimmed;
}

pub fn completionCount(prefix: []const u8) usize {
    var count: usize = 0;
    for (0..3) |rank| {
        for (specs) |spec| if (matchRank(spec.command, prefix) == rank) {
            count += 1;
        };
    }
    return count;
}

pub fn completionAt(prefix: []const u8, completion_index: usize) ?*const Spec {
    var index: usize = 0;
    for (0..3) |rank| {
        for (&specs) |*spec| {
            if (matchRank(spec.command, prefix) != rank) continue;
            if (index == completion_index) return spec;
            index += 1;
        }
    }
    return null;
}

fn matchRank(command: []const u8, prefix: []const u8) ?usize {
    if (std.ascii.eqlIgnoreCase(command, prefix)) return 0;
    if (prefix.len <= command.len and std.ascii.startsWithIgnoreCase(command, prefix)) return 1;
    const command_name = if (command.len != 0 and command[0] == '/') command[1..] else command;
    const query = if (prefix.len != 0 and prefix[0] == '/') prefix[1..] else prefix;
    if (containsIgnoreCase(command_name, query)) return 2;
    return null;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |start| {
        if (std.ascii.eqlIgnoreCase(haystack[start..][0..needle.len], needle)) return true;
    }
    return false;
}

fn validateIdentifier(value: []const u8) ParseError!void {
    if (value.len == 0 or value.len > max_identifier_bytes) return error.IdentifierTooLong;
}

test "catalog ranks exact prefix and substring matches deterministically" {
    try std.testing.expectEqual(@as(usize, 3), completionCount("/"));
    try std.testing.expectEqualStrings("/login", completionAt("/", 0).?.command);
    try std.testing.expectEqualStrings("/model", completionAt("/", 1).?.command);
    try std.testing.expectEqualStrings("/thinking", completionAt("/", 2).?.command);
    try std.testing.expectEqualStrings("/model", completionAt("/model", 0).?.command);
    try std.testing.expectEqualStrings("/login", completionAt("/og", 0).?.command);
    try std.testing.expectEqual(@as(usize, 0), completionCount("/missing"));
}

test "completion prefix admits only a leading command token" {
    try std.testing.expectEqualStrings("/mo", completionPrefix(" \t/mo", 5).?);
    try std.testing.expect(completionPrefix("question /mo", 12) == null);
    try std.testing.expect(completionPrefix("/model ", 7) == null);
    try std.testing.expect(completionPrefix("/model", 99) == null);
}

test "parser recognizes catalog commands without interpreting arguments" {
    const login = parse("  /login openai-codex --device  ").command;
    try std.testing.expect(login.spec.kind == .login);
    try std.testing.expectEqualStrings("openai-codex --device", login.arguments);

    const model = parse("/model openai/gpt-5.6-sol").command;
    try std.testing.expect(model.spec.kind == .model);
    try std.testing.expectEqualStrings("openai/gpt-5.6-sol", model.arguments);
    try std.testing.expect(parse("/unknown value") == .ordinary);
    try std.testing.expect(parse("/modelish provider/model") == .ordinary);
}

test "focused command parsers preserve login and model grammar" {
    try std.testing.expectEqual(
        ai.oauth.LoginMethod.browser,
        (try Login.parse("openai-codex")).method,
    );
    try std.testing.expectEqual(
        ai.oauth.LoginMethod.device_code,
        (try Login.parse("openai-codex --device")).method,
    );
    const selection = (try Model.parse("openai/gpt-5.6-sol")).selection;
    try std.testing.expectEqualStrings("openai", selection.provider);
    try std.testing.expectEqualStrings("gpt-5.6-sol", selection.model);
    try std.testing.expectError(error.InvalidCommand, Model.parse("missing-slash"));
    try std.testing.expectError(error.InvalidCommand, Login.parse("provider --bad"));
    try std.testing.expectEqual(ai.ThinkingLevel.high, (try Thinking.parse("high")).level);
    try std.testing.expectError(error.InvalidCommand, Thinking.parse(""));
    try std.testing.expectError(error.InvalidCommand, Thinking.parse("extreme"));
}
