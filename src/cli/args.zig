const std = @import("std");

pub const Mode = enum {
    text,
    json,
};

pub const RunOptions = struct {
    print_mode: bool = false,
    api_key: ?[]const u8 = null,
    model_id: ?[]const u8 = null,
    prompt_text: ?[]const u8 = null,
    continue_path: ?[]const u8 = null,
    mode: Mode = .text,
    no_session: bool = false,
    tools_filter: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub const Command = union(enum) {
    help,
    version,
    list_models,
    run: RunOptions,
};

pub const Diagnostic = union(enum) {
    missing_value: []const u8,
    invalid_mode: []const u8,
    unknown_flag: []const u8,
};

pub const ParseResult = union(enum) {
    ok: Command,
    err: Diagnostic,
};

pub fn parse(argv: []const []const u8) ParseResult {
    var run: RunOptions = .{};
    var show_help = false;
    var show_version = false;
    var list_models = false;

    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        const arg = argv[i];

        if (eql(arg, "-p") or eql(arg, "--print")) {
            run.print_mode = true;
            continue;
        }
        if (eql(arg, "-h") or eql(arg, "--help")) {
            show_help = true;
            continue;
        }
        if (eql(arg, "-v") or eql(arg, "--version")) {
            show_version = true;
            continue;
        }
        if (eql(arg, "--api-key")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.api_key = value;
            continue;
        }
        if (eql(arg, "--model")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.model_id = value;
            continue;
        }
        if (eql(arg, "--list-models")) {
            list_models = true;
            continue;
        }
        if (eql(arg, "--continue")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.continue_path = value;
            continue;
        }
        if (eql(arg, "--mode")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.mode = parseMode(value) orelse return .{ .err = .{ .invalid_mode = value } };
            continue;
        }
        if (eql(arg, "--no-session")) {
            run.no_session = true;
            continue;
        }
        if (eql(arg, "--tools")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.tools_filter = value;
            continue;
        }
        if (eql(arg, "--append-system-prompt")) {
            const value = consumeValue(argv, &i, arg) orelse return .{ .err = .{ .missing_value = arg } };
            run.append_system_prompt = value;
            continue;
        }
        if (arg.len > 0 and arg[0] == '-') {
            return .{ .err = .{ .unknown_flag = arg } };
        }

        run.prompt_text = arg;
    }

    if (show_version) return .{ .ok = .version };
    if (show_help) return .{ .ok = .help };
    if (list_models) return .{ .ok = .list_models };
    return .{ .ok = .{ .run = run } };
}

fn consumeValue(argv: []const []const u8, index: *usize, _: []const u8) ?[]const u8 {
    if (index.* + 1 >= argv.len) return null;
    index.* += 1;
    const value = argv[index.*];
    if (value.len > 0 and value[0] == '-') return null;
    return value;
}

fn parseMode(value: []const u8) ?Mode {
    if (eql(value, "text")) return .text;
    if (eql(value, "json")) return .json;
    return null;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

test "parse run options preserves batch flags" {
    const result = parse(&.{ "--mode", "json", "--model", "gpt-4o", "-p", "hello" });
    switch (result) {
        .ok => |cmd| switch (cmd) {
            .run => |run| {
                try std.testing.expect(run.print_mode);
                try std.testing.expectEqual(Mode.json, run.mode);
                try std.testing.expectEqualStrings("gpt-4o", run.model_id.?);
                try std.testing.expectEqualStrings("hello", run.prompt_text.?);
            },
            else => return error.UnexpectedCommand,
        },
        .err => return error.UnexpectedDiagnostic,
    }
}

test "parse prioritizes version over help and run" {
    const result = parse(&.{ "--help", "--version", "hello" });
    switch (result) {
        .ok => |cmd| try std.testing.expect(cmd == .version),
        .err => return error.UnexpectedDiagnostic,
    }
}

test "parse reports invalid mode" {
    const result = parse(&.{ "--mode", "rpc" });
    switch (result) {
        .err => |diag| switch (diag) {
            .invalid_mode => |value| try std.testing.expectEqualStrings("rpc", value),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}

test "parse reports missing value for valued flags" {
    const result = parse(&.{"--model"});
    switch (result) {
        .err => |diag| switch (diag) {
            .missing_value => |flag| try std.testing.expectEqualStrings("--model", flag),
            else => return error.UnexpectedDiagnostic,
        },
        .ok => return error.ExpectedDiagnostic,
    }
}
