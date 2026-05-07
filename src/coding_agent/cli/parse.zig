const std = @import("std");
const action_mod = @import("action.zig");
const spec = @import("spec.zig");

pub const Action = action_mod.Action;

pub const OutputMode = enum {
    text,
    json,
};

pub const RawRunArgs = struct {
    print_mode: bool = false,
    mode: ?OutputMode = null,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    positionals: []const []const u8 = &.{},
    file_args: []const []const u8 = &.{},
    continue_session: bool = false,
    resume_picker: bool = false,
    session_ref: ?[]const u8 = null,
    no_session: bool = false,
    tools_filter: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,

    pub fn deinit(self: *RawRunArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positionals);
        allocator.free(self.file_args);
        self.* = undefined;
    }
};

pub const RawListModelsArgs = struct {
    positionals: []const []const u8 = &.{},

    pub fn deinit(self: *RawListModelsArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positionals);
        self.* = undefined;
    }
};
pub const RawDocsArgs = struct { query: []const u8 };
pub const RawManArgs = struct { topic: ?[]const u8 = null };
pub const RawHelpArgs = struct {};
pub const RawVersionArgs = struct {};

pub const RawCommand = union(Action) {
    run: RawRunArgs,
    help: RawHelpArgs,
    version: RawVersionArgs,
    list_models: RawListModelsArgs,
    docs: RawDocsArgs,
    man: RawManArgs,

    pub fn deinit(self: *RawCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*run| run.deinit(allocator),
            .list_models => |*list_models| list_models.deinit(allocator),
            .help, .version, .docs, .man => self.* = undefined,
        }
    }
};

pub const ParseDiagnostic = union(enum) {
    missing_value: []const u8,
    invalid_mode: []const u8,
    unknown_flag: []const u8,
    unexpected_argument: []const u8,
};

pub const ParseResult = union(enum) {
    ok: RawCommand,
    err: ParseDiagnostic,
};

pub fn parse(
    allocator: std.mem.Allocator,
    action: Action,
    argv: []const []const u8,
) std.mem.Allocator.Error!ParseResult {
    return switch (action) {
        .run => try parseRun(allocator, argv),
        .help => try parseUtilityAction(.help, argv),
        .version => try parseUtilityAction(.version, argv),
        .list_models => try parseListModels(allocator, argv),
        .docs => parseDocs(argv),
        .man => parseMan(argv),
    };
}

fn parseRun(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!ParseResult {
    var raw: RawRunArgs = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);
    var file_args: std.ArrayList([]const u8) = .empty;
    defer file_args.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (arg.len > 0 and arg[0] == '@') {
            try file_args.append(allocator, arg[1..]);
            continue;
        }
        if (spec.findForAction(.run, arg)) |flag| {
            switch (flag.id) {
                .print_mode => raw.print_mode = true,
                .api_key => raw.api_key = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } },
                .model_id => raw.model_id = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } },
                .continue_session => raw.continue_session = true,
                .resume_picker => raw.resume_picker = true,
                .session_ref => raw.session_ref = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } },
                .mode => {
                    const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
                    raw.mode = parseMode(value) orelse return .{ .err = .{ .invalid_mode = value } };
                },
                .no_session => raw.no_session = true,
                .tools_filter => raw.tools_filter = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } },
                .append_system_prompt => raw.append_system_prompt = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } },
                .list_models, .docs, .man, .help, .version => unreachable,
            }
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .{ .unknown_flag = arg } };
        }

        try positionals.append(allocator, arg);
    }

    raw.positionals = try positionals.toOwnedSlice(allocator);
    errdefer allocator.free(raw.positionals);
    raw.file_args = try file_args.toOwnedSlice(allocator);
    return .{ .ok = .{ .run = raw } };
}

fn parseUtilityAction(comptime action: spec.ActionScope, argv: []const []const u8) std.mem.Allocator.Error!ParseResult {
    for (argv) |arg| {
        if (spec.findForAction(action, arg) != null) continue;
        if (arg.len > 0 and arg[0] == '-') return .{ .err = .{ .unknown_flag = arg } };
        return .{ .err = .{ .unexpected_argument = arg } };
    }

    return switch (action) {
        .help => .{ .ok = .{ .help = .{} } },
        .version => .{ .ok = .{ .version = .{} } },
        .run, .list_models, .docs, .man => unreachable,
    };
}

fn parseDocs(argv: []const []const u8) ParseResult {
    var query: ?[]const u8 = null;
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];
        if (spec.findForAction(.docs, arg)) |flag| {
            if (flag.id != .docs) continue;
            query = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') return .{ .err = .{ .unknown_flag = arg } };
        return .{ .err = .{ .unexpected_argument = arg } };
    }
    return .{ .ok = .{ .docs = .{ .query = query orelse return .{ .err = .{ .missing_value = "--docs" } } } } };
}

fn parseMan(argv: []const []const u8) ParseResult {
    var topic: ?[]const u8 = null;
    var saw_man = false;
    for (argv) |arg| {
        if (spec.findForAction(.man, arg)) |flag| {
            if (flag.id == .man) {
                saw_man = true;
                continue;
            }
        }
        if (arg.len > 0 and arg[0] == '-') return .{ .err = .{ .unknown_flag = arg } };
        if (topic != null) return .{ .err = .{ .unexpected_argument = arg } };
        topic = arg;
    }
    if (!saw_man) return .{ .err = .{ .missing_value = "--man" } };
    return .{ .ok = .{ .man = .{ .topic = topic } } };
}

fn parseListModels(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!ParseResult {
    var raw: RawListModelsArgs = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    for (argv) |arg| {
        if (spec.findForAction(.list_models, arg) != null) {
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .{ .unknown_flag = arg } };
        }
        try positionals.append(allocator, arg);
    }

    raw.positionals = try positionals.toOwnedSlice(allocator);
    return .{ .ok = .{ .list_models = raw } };
}

fn consumeValue(argv: []const []const u8, index: *usize, _: []const u8) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    const value = argv[index.*];
    if (value.len > 0 and value[0] == '-') return null;
    return value;
}

fn parseMode(value: []const u8) ?OutputMode {
    if (std.mem.eql(u8, value, "text")) return .text;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

test "list-models parsing keeps its optional search positional and rejects unrelated flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const search_result = try parse(arena.allocator(), .list_models, &.{ "--list-models", "claude" });
    switch (search_result) {
        .ok => |cmd| switch (cmd) {
            .list_models => |list_models| {
                try std.testing.expectEqual(@as(usize, 1), list_models.positionals.len);
                try std.testing.expectEqualStrings("claude", list_models.positionals[0]);
            },
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const bad_flag = try parse(arena.allocator(), .list_models, &.{ "--list-models", "--model", "gpt-4o" });
    switch (bad_flag) {
        .err => |diag| switch (diag) {
            .unknown_flag => |flag| try std.testing.expectEqualStrings("--model", flag),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

test "utility action parsing rejects unsupported flags and swallowed positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const help_ok = try parse(arena.allocator(), .help, &.{"--help"});
    switch (help_ok) {
        .ok => |cmd| switch (cmd) {
            .help => {},
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }

    const help_bad_flag = try parse(arena.allocator(), .help, &.{ "--help", "--model", "gpt-4o" });
    switch (help_bad_flag) {
        .err => |diag| switch (diag) {
            .unknown_flag => |flag| try std.testing.expectEqualStrings("--model", flag),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }

    const version_bad_positional = try parse(arena.allocator(), .version, &.{ "--version", "hello" });
    switch (version_bad_positional) {
        .err => |diag| switch (diag) {
            .unexpected_argument => |arg| try std.testing.expectEqualStrings("hello", arg),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

test "run parsing records batch selectors file args session selectors and positionals without planning them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), .run, &.{
        "--mode",
        "json",
        "--model",
        "gpt-4o",
        "-p",
        "--continue",
        "--resume",
        "--session",
        "session-1234",
        "@docs/README.md",
        "@assets/screenshot.png",
        "hello",
        "world",
    });
    switch (result) {
        .ok => |cmd| switch (cmd) {
            .run => |run| {
                try std.testing.expect(run.print_mode);
                try std.testing.expectEqual(OutputMode.json, run.mode.?);
                try std.testing.expectEqualStrings("gpt-4o", run.model_id.?);
                try std.testing.expect(run.continue_session);
                try std.testing.expect(run.resume_picker);
                try std.testing.expectEqualStrings("session-1234", run.session_ref.?);
                try std.testing.expectEqual(@as(usize, 2), run.file_args.len);
                try std.testing.expectEqualStrings("docs/README.md", run.file_args[0]);
                try std.testing.expectEqualStrings("assets/screenshot.png", run.file_args[1]);
                try std.testing.expectEqual(@as(usize, 2), run.positionals.len);
                try std.testing.expectEqualStrings("hello", run.positionals[0]);
                try std.testing.expectEqualStrings("world", run.positionals[1]);
            },
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}
