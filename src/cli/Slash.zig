const std = @import("std");

pub const maximum_commands: usize = 32;
pub const maximum_name_bytes: usize = 64;

pub const ArgumentPolicy = enum {
    none,
    optional,
};

pub const DisplayPolicy = enum {
    ordinary,
    managed,
};

pub const HandlerOutcome = union(enum) {
    handled,
    history_changed,
    exit,
    /// Borrowed only through synchronous command-outcome delivery.
    preseed: []const u8,
};

pub const Call = struct {
    spec: *const Spec,
    argument: ?[]const u8,
};

pub const HandlerFn = *const fn (*anyopaque, Call) anyerror!HandlerOutcome;

/// Static command declaration. `handler_fn` borrows the registry context only
/// for its synchronous call.
pub const Spec = struct {
    name: []const u8,
    alias: ?[]const u8 = null,
    summary: []const u8,
    arguments: ArgumentPolicy = .none,
    display: DisplayPolicy = .ordinary,
    handler_fn: HandlerFn,
};

pub const Parsed = struct {
    name: []const u8,
    argument: ?[]const u8,
};

pub const Parse = union(enum) {
    prompt,
    command: Parsed,
};

pub const Usage = enum {
    valid,
    unknown,
    bad_usage,
};

pub const ClassifiedCommand = struct {
    registry_index: ?usize,
    name: []const u8,
    argument: ?[]const u8,
    usage: Usage,
};

pub const Classification = union(enum) {
    prompt,
    command: ClassifiedCommand,
};

pub const ValidationError = union(enum) {
    too_many,
    invalid_name: usize,
    invalid_alias: usize,
    empty_summary: usize,
    collision: struct { first: usize, second: usize },
};

/// Synchronous command diagnostics. Parsed names contain only safe ASCII.
pub const Output = struct {
    context: *anyopaque,
    begin_fn: *const fn (*anyopaque) anyerror!void,
    unknown_fn: *const fn (*anyopaque, []const u8) anyerror!void,
    bad_usage_fn: *const fn (*anyopaque, []const u8) anyerror!void,

    pub fn begin(self: Output) !void {
        return self.begin_fn(self.context);
    }

    pub fn unknown(self: Output, name: []const u8) !void {
        return self.unknown_fn(self.context, name);
    }

    pub fn badUsage(self: Output, name: []const u8) !void {
        return self.bad_usage_fn(self.context, name);
    }

    pub fn from(implementation: anytype) Output {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("Slash.Output.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn begin(context: *anyopaque) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.beginCommandOutput();
            }

            fn unknown(context: *anyopaque, name: []const u8) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.unknownCommand(name);
            }

            fn badUsage(context: *anyopaque, name: []const u8) anyerror!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.badCommandUsage(name);
            }
        };
        return .{
            .context = implementation,
            .begin_fn = Adapter.begin,
            .unknown_fn = Adapter.unknown,
            .bad_usage_fn = Adapter.badUsage,
        };
    }
};

/// Parses only command-shaped input. Malformed slash input remains a prompt.
pub fn parse(line: []const u8) Parse {
    if (line.len < 2 or line[0] != '/') return .prompt;

    var cursor: usize = 1;
    while (cursor < line.len and !std.ascii.isWhitespace(line[cursor])) : (cursor += 1) {
        if (!isNameByte(line[cursor])) return .prompt;
    }
    if (cursor == 1) return .prompt;

    const name = line[1..cursor];
    while (cursor < line.len and std.ascii.isWhitespace(line[cursor])) cursor += 1;
    return .{ .command = .{
        .name = name,
        .argument = if (cursor < line.len) line[cursor..] else null,
    } };
}

pub fn validateSpecs(specs: []const Spec) ?ValidationError {
    if (specs.len > maximum_commands) return .too_many;
    for (specs, 0..) |spec, index| {
        if (!validName(spec.name)) return .{ .invalid_name = index };
        if (spec.alias) |alias| if (!validName(alias)) return .{ .invalid_alias = index };
        if (spec.summary.len == 0) return .{ .empty_summary = index };

        for (specs[0..index], 0..) |earlier, earlier_index| {
            if (namesCollide(spec.name, earlier) or
                (spec.alias != null and namesCollide(spec.alias.?, earlier)))
            {
                return .{ .collision = .{ .first = earlier_index, .second = index } };
            }
        }
    }
    return null;
}

pub fn assertValidSpecs(comptime specs: []const Spec) void {
    if (validateSpecs(specs)) |problem| switch (problem) {
        .too_many => @compileError("slash command registry exceeds maximum_commands"),
        .invalid_name => @compileError("slash command registry contains an invalid name"),
        .invalid_alias => @compileError("slash command registry contains an invalid alias"),
        .empty_summary => @compileError("slash command registry contains an empty summary"),
        .collision => @compileError("slash command registry contains duplicate names or aliases"),
    };
}

/// Classifies borrowed input without allocation, output, or handler calls.
pub fn classify(line: []const u8, specs: []const Spec) Classification {
    const parsed = switch (parse(line)) {
        .prompt => return .prompt,
        .command => |command| command,
    };
    const registry_index = findSpecIndex(specs, parsed.name) orelse return .{ .command = .{
        .registry_index = null,
        .name = parsed.name,
        .argument = parsed.argument,
        .usage = .unknown,
    } };
    const spec = specs[registry_index];
    return .{ .command = .{
        .registry_index = registry_index,
        .name = parsed.name,
        .argument = parsed.argument,
        .usage = if (parsed.argument != null and spec.arguments == .none) .bad_usage else .valid,
    } };
}

/// Starts command output, then renders a classification diagnostic or invokes
/// the handler at the stable registry index.
pub fn execute(
    command: ClassifiedCommand,
    specs: []const Spec,
    handler_context: *anyopaque,
    output: Output,
) !HandlerOutcome {
    const spec: ?*const Spec = switch (command.usage) {
        .unknown => if (command.registry_index == null) null else return error.InvalidCommandClassification,
        .valid, .bad_usage => spec: {
            const index = command.registry_index orelse return error.InvalidCommandClassification;
            if (index >= specs.len or !specMatchesName(specs[index], command.name)) {
                return error.InvalidCommandClassification;
            }
            if (command.usage == .valid and command.argument != null and specs[index].arguments == .none) {
                return error.InvalidCommandClassification;
            }
            if (command.usage == .bad_usage and
                (command.argument == null or specs[index].arguments != .none))
            {
                return error.InvalidCommandClassification;
            }
            break :spec &specs[index];
        },
    };

    try output.begin();
    switch (command.usage) {
        .unknown => {
            try output.unknown(command.name);
            return .handled;
        },
        .bad_usage => {
            try output.badUsage(command.name);
            return .handled;
        },
        .valid => return spec.?.handler_fn(handler_context, .{
            .spec = spec.?,
            .argument = if (spec.?.arguments == .optional) command.argument else null,
        }),
    }
}

fn findSpecIndex(specs: []const Spec, name: []const u8) ?usize {
    for (specs, 0..) |spec, index| if (specMatchesName(spec, name)) return index;
    return null;
}

fn specMatchesName(spec: Spec, name: []const u8) bool {
    if (std.mem.eql(u8, spec.name, name)) return true;
    return if (spec.alias) |alias| std.mem.eql(u8, alias, name) else false;
}

fn namesCollide(name: []const u8, spec: Spec) bool {
    if (std.mem.eql(u8, name, spec.name)) return true;
    return if (spec.alias) |alias| std.mem.eql(u8, name, alias) else false;
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > maximum_name_bytes) return false;
    for (name) |byte| if (!isNameByte(byte)) return false;
    return true;
}

fn isNameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_' or byte == '-';
}

const TestHandler = struct {
    calls: usize = 0,
    argument: ?[]const u8 = null,
    fail: bool = false,

    fn call(context: *anyopaque, call_value: Call) anyerror!HandlerOutcome {
        const self: *TestHandler = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.argument = call_value.argument;
        if (self.fail) return error.HandlerFailed;
        if (call_value.argument) |argument| {
            if (std.mem.eql(u8, argument, "seed")) return .{ .preseed = argument };
            return .history_changed;
        }
        return .handled;
    }
};

const test_specs = [_]Spec{
    .{
        .name = "help",
        .alias = "h",
        .summary = "show help",
        .handler_fn = TestHandler.call,
    },
    .{
        .name = "new",
        .summary = "new conversation",
        .arguments = .optional,
        .handler_fn = TestHandler.call,
    },
};

comptime {
    assertValidSpecs(&test_specs);
}

const TestOutput = struct {
    began: usize = 0,
    unknown_name: ?[]const u8 = null,
    bad_name: ?[]const u8 = null,

    fn beginCommandOutput(self: *TestOutput) !void {
        self.began += 1;
    }

    fn unknownCommand(self: *TestOutput, name: []const u8) !void {
        self.unknown_name = name;
    }

    fn badCommandUsage(self: *TestOutput, name: []const u8) !void {
        self.bad_name = name;
    }
};

test "parser matches hax command-shaped input" {
    const commands = [_]struct {
        line: []const u8,
        name: []const u8,
        argument: ?[]const u8,
    }{
        .{ .line = "/help", .name = "help", .argument = null },
        .{ .line = "/help   ", .name = "help", .argument = null },
        .{ .line = "/new focus here ", .name = "new", .argument = "focus here " },
        .{ .line = "/a_b-2\targ", .name = "a_b-2", .argument = "arg" },
    };
    for (commands) |expected| switch (parse(expected.line)) {
        .prompt => return error.TestUnexpectedResult,
        .command => |actual| {
            try std.testing.expectEqualStrings(expected.name, actual.name);
            if (expected.argument) |argument| {
                try std.testing.expectEqualStrings(argument, actual.argument.?);
            } else {
                try std.testing.expect(actual.argument == null);
            }
        },
    };

    const prompts = [_][]const u8{
        "",             "help", "/", "//tmp", "/help.txt", "/help/now", " /help",
        "/hé",
        "/help\x1b[2J",
    };
    for (prompts) |line| try std.testing.expect(parse(line) == .prompt);
}

test "classification is exhaustive and has no callback side effects" {
    const handler: TestHandler = .{};
    const output: TestOutput = .{};

    try std.testing.expect(classify("/help.txt", &test_specs) == .prompt);

    const alias = classify("/h", &test_specs).command;
    try std.testing.expectEqual(@as(?usize, 0), alias.registry_index);
    try std.testing.expectEqualStrings("h", alias.name);
    try std.testing.expect(alias.argument == null);
    try std.testing.expectEqual(Usage.valid, alias.usage);

    const optional = classify("/new focus", &test_specs).command;
    try std.testing.expectEqual(@as(?usize, 1), optional.registry_index);
    try std.testing.expectEqualStrings("focus", optional.argument.?);
    try std.testing.expectEqual(Usage.valid, optional.usage);

    const unknown = classify("/Help arg", &test_specs).command;
    try std.testing.expect(unknown.registry_index == null);
    try std.testing.expectEqualStrings("Help", unknown.name);
    try std.testing.expectEqualStrings("arg", unknown.argument.?);
    try std.testing.expectEqual(Usage.unknown, unknown.usage);

    const bad_usage = classify("/help extra", &test_specs).command;
    try std.testing.expectEqual(@as(?usize, 0), bad_usage.registry_index);
    try std.testing.expectEqual(Usage.bad_usage, bad_usage.usage);

    try std.testing.expectEqual(@as(usize, 0), handler.calls);
    try std.testing.expectEqual(@as(usize, 0), output.began);
    try std.testing.expect(output.unknown_name == null);
    try std.testing.expect(output.bad_name == null);
}

fn expectHandlerOutcome(expected: std.meta.Tag(HandlerOutcome), actual: HandlerOutcome) !void {
    try std.testing.expectEqual(expected, std.meta.activeTag(actual));
}

test "execution begins output and handles every usage" {
    var handler: TestHandler = .{};
    var output: TestOutput = .{};
    const sink = Output.from(&output);

    try expectHandlerOutcome(
        .handled,
        try execute(classify("/h", &test_specs).command, &test_specs, &handler, sink),
    );
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
    try std.testing.expect(handler.argument == null);

    try expectHandlerOutcome(
        .history_changed,
        try execute(classify("/new focus", &test_specs).command, &test_specs, &handler, sink),
    );
    try std.testing.expectEqualStrings("focus", handler.argument.?);

    try expectHandlerOutcome(
        .handled,
        try execute(classify("/Help", &test_specs).command, &test_specs, &handler, sink),
    );
    try std.testing.expectEqualStrings("Help", output.unknown_name.?);

    try expectHandlerOutcome(
        .handled,
        try execute(classify("/help extra", &test_specs).command, &test_specs, &handler, sink),
    );
    try std.testing.expectEqualStrings("help", output.bad_name.?);

    const seeded = try execute(classify("/new seed", &test_specs).command, &test_specs, &handler, sink);
    switch (seeded) {
        .preseed => |bytes| try std.testing.expectEqualStrings("seed", bytes),
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 5), output.began);
}

test "handler failure occurs only during execution after output begins" {
    var handler: TestHandler = .{ .fail = true };
    var output: TestOutput = .{};
    const command = classify("/help", &test_specs).command;

    try std.testing.expectEqual(@as(usize, 0), handler.calls);
    try std.testing.expectEqual(@as(usize, 0), output.began);
    try std.testing.expectError(error.HandlerFailed, execute(
        command,
        &test_specs,
        &handler,
        Output.from(&output),
    ));
    try std.testing.expectEqual(@as(usize, 1), output.began);
    try std.testing.expectEqual(@as(usize, 1), handler.calls);
}

test "execution rejects stale registry classifications before output" {
    var handler: TestHandler = .{};
    var output: TestOutput = .{};
    var command = classify("/help", &test_specs).command;
    command.registry_index = 1;

    try std.testing.expectError(error.InvalidCommandClassification, execute(
        command,
        &test_specs,
        &handler,
        Output.from(&output),
    ));
    try std.testing.expectEqual(@as(usize, 0), output.began);
    try std.testing.expectEqual(@as(usize, 0), handler.calls);
}

test "registry validation rejects invalid declarations and collisions" {
    const invalid = [_]Spec{.{
        .name = "bad/name",
        .summary = "bad",
        .handler_fn = TestHandler.call,
    }};
    try std.testing.expect(validateSpecs(&invalid).? == .invalid_name);

    const duplicate = [_]Spec{
        .{ .name = "one", .alias = "shared", .summary = "one", .handler_fn = TestHandler.call },
        .{ .name = "shared", .summary = "two", .handler_fn = TestHandler.call },
    };
    try std.testing.expect(validateSpecs(&duplicate).? == .collision);
}
