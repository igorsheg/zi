const std = @import("std");
const action_mod = @import("action.zig");

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
    continue_session: bool = false,
    resume_picker: bool = false,
    session_ref: ?[]const u8 = null,
    no_session: bool = false,
    tools_filter: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,

    pub fn deinit(self: *RawRunArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positionals);
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
pub const RawHelpArgs = struct {};
pub const RawVersionArgs = struct {};

pub const RawCommand = union(Action) {
    run: RawRunArgs,
    help: RawHelpArgs,
    version: RawVersionArgs,
    list_models: RawListModelsArgs,

    pub fn deinit(self: *RawCommand, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .run => |*run| run.deinit(allocator),
            .list_models => |*list_models| list_models.deinit(allocator),
            .help, .version => self.* = undefined,
        }
    }
};

pub const ParseDiagnostic = union(enum) {
    missing_value: []const u8,
    invalid_mode: []const u8,
    unknown_flag: []const u8,
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
        .help => .{ .ok = .{ .help = .{} } },
        .version => .{ .ok = .{ .version = .{} } },
        .list_models => try parseListModels(allocator, argv),
    };
}

fn parseRun(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!ParseResult {
    var raw: RawRunArgs = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (eql(arg, "-p") or eql(arg, "--print")) {
            raw.print_mode = true;
            continue;
        }
        if (eql(arg, "--api-key")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.api_key = value;
            continue;
        }
        if (eql(arg, "--model")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.model_id = value;
            continue;
        }
        if (eql(arg, "--continue") or eql(arg, "-c")) {
            raw.continue_session = true;
            continue;
        }
        if (eql(arg, "--resume") or eql(arg, "-r")) {
            raw.resume_picker = true;
            continue;
        }
        if (eql(arg, "--session")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.session_ref = value;
            continue;
        }
        if (eql(arg, "--mode")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.mode = parseMode(value) orelse return .{ .err = .{ .invalid_mode = value } };
            continue;
        }
        if (eql(arg, "--no-session")) {
            raw.no_session = true;
            continue;
        }
        if (eql(arg, "--tools")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.tools_filter = value;
            continue;
        }
        if (eql(arg, "--append-system-prompt")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.append_system_prompt = value;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .{ .unknown_flag = arg } };
        }

        try positionals.append(allocator, arg);
    }

    raw.positionals = try positionals.toOwnedSlice(allocator);
    return .{ .ok = .{ .run = raw } };
}

fn parseListModels(allocator: std.mem.Allocator, argv: []const []const u8) std.mem.Allocator.Error!ParseResult {
    var raw: RawListModelsArgs = .{};
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(allocator);

    for (argv) |arg| {
        if (eql(arg, "--list-models") or eql(arg, "--help") or eql(arg, "-h")) {
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
    if (eql(value, "text")) return .text;
    if (eql(value, "json")) return .json;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
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

test "run parsing records batch selectors session selectors and positionals without planning them" {
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
                try std.testing.expectEqual(@as(usize, 2), run.positionals.len);
                try std.testing.expectEqualStrings("hello", run.positionals[0]);
                try std.testing.expectEqualStrings("world", run.positionals[1]);
            },
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}
