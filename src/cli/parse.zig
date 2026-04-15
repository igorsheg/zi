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
    continue_path: ?[]const u8 = null,
    no_session: bool = false,
    tools_filter: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,

    pub fn deinit(self: *RawRunArgs, allocator: std.mem.Allocator) void {
        allocator.free(self.positionals);
        self.* = undefined;
    }
};

pub const RawListModelsArgs = struct {};
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
            .help, .version, .list_models => self.* = undefined,
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
        .list_models => .{ .ok = .{ .list_models = .{} } },
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
        if (eql(arg, "--continue")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            raw.continue_path = value;
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

test "run parsing preserves syntax-only flags and all positionals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const result = try parse(arena.allocator(), .run, &.{
        "--mode",
        "json",
        "--model",
        "gpt-4o",
        "-p",
        "hello",
        "world",
    });
    switch (result) {
        .ok => |cmd| switch (cmd) {
            .run => |run| {
                try std.testing.expect(run.print_mode);
                try std.testing.expectEqual(OutputMode.json, run.mode.?);
                try std.testing.expectEqualStrings("gpt-4o", run.model_id.?);
                try std.testing.expectEqual(@as(usize, 2), run.positionals.len);
                try std.testing.expectEqualStrings("hello", run.positionals[0]);
                try std.testing.expectEqualStrings("world", run.positionals[1]);
            },
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}
