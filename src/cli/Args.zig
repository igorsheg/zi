const std = @import("std");
const DiagnosticText = @import("DiagnosticText.zig");

pub const max_arguments: usize = 256;
pub const max_argument_bytes: usize = 1024 * 1024;
pub const max_prompt_bytes: usize = 1024 * 1024;

pub const Mode = enum { interactive, print };
pub const Action = enum { run, help, version };

pub const Resume = union(enum) {
    absent,
    latest,
    select,
    id: []const u8,
};

pub const Selection = struct {
    provider: ?[]const u8 = null,
    model: ?[]const u8 = null,
    effort: ?[]const u8 = null,
    preset: ?[]const u8 = null,
};

/// All slices borrow from the argv passed to parse.
pub const Options = struct {
    action: Action = .run,
    mode: Mode = .interactive,
    continue_conversation: bool = false,
    resume_state: Resume = .absent,
    no_session: bool = false,
    raw: bool = false,
    bare: bool = false,
    selection: Selection = .{},
    prompt_fragments: [max_arguments][]const u8 = undefined,
    prompt_indexes: [max_arguments]usize = undefined,
    prompt_fragment_count: usize = 0,

    pub fn promptFragments(options: *const Options) []const []const u8 {
        return options.prompt_fragments[0..options.prompt_fragment_count];
    }
};

pub const ParseErrorKind = enum {
    too_many_arguments,
    arguments_too_large,
    unknown_option,
    option_does_not_take_value,
    missing_value,
    empty_value,
    conflicting_resume,
    print_resume_needs_id,
    interactive_prompt,
};

/// Error slices borrow from the argument byte storage passed to `parse`.
pub const ParseError = struct {
    kind: ParseErrorKind,
    /// Zero-based index in argv (which excludes the program name).
    index: usize,
    option: []const u8 = "",

    pub fn render(problem: ParseError, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        switch (problem.kind) {
            .too_many_arguments => try writer.print("too many arguments (maximum {d})", .{max_arguments}),
            .arguments_too_large => try writer.print(
                "arguments exceed the {d}-byte limit",
                .{max_argument_bytes},
            ),
            .unknown_option => {
                try writer.writeAll("unknown option '");
                try DiagnosticText.write(writer, problem.option);
                try writer.writeAll("'\nTry 'zi --help' for usage.");
            },
            .option_does_not_take_value => {
                try DiagnosticText.write(writer, problem.option);
                try writer.writeAll(" does not take a value\nTry 'zi --help' for usage.");
            },
            .missing_value => {
                try DiagnosticText.write(writer, problem.option);
                try writer.writeAll(" requires a value\nTry 'zi --help' for usage.");
            },
            .empty_value => if (std.mem.eql(u8, problem.option, "--resume=")) {
                try writer.writeAll("--resume= requires a session id");
            } else {
                try DiagnosticText.write(writer, problem.option);
                try writer.writeAll(" requires a value");
            },
            .conflicting_resume => try writer.writeAll("use only one of --continue / --resume"),
            .print_resume_needs_id => try writer.writeAll(
                "-p with --resume requires a session id (e.g. --resume=ID)",
            ),
            .interactive_prompt => try writer.writeAll(
                "positional arguments require -p / --print\nTry 'zi --help' for usage.",
            ),
        }
    }
};

/// Both variants borrow argument byte storage; keep it alive while using the result.
pub const ParseResult = union(enum) {
    options: Options,
    err: ParseError,
};

const LongOption = enum {
    help,
    version,
    print,
    continue_conversation,
    resume_option,
    no_session,
    raw,
    bare,
    provider,
    model,
    effort,
    preset,

    fn name(option: LongOption) []const u8 {
        return switch (option) {
            .help => "help",
            .version => "version",
            .print => "print",
            .continue_conversation => "continue",
            .resume_option => "resume",
            .no_session => "no-session",
            .raw => "raw",
            .bare => "bare",
            .provider => "provider",
            .model => "model",
            .effort => "effort",
            .preset => "preset",
        };
    }

    fn valueMode(option: LongOption) enum { none, required, optional } {
        return switch (option) {
            .resume_option => .optional,
            .provider, .model, .effort, .preset => .required,
            else => .none,
        };
    }
};

const SelectionIndexes = struct {
    provider: usize = 0,
    model: usize = 0,
    effort: usize = 0,
    preset: usize = 0,
};

const long_options = [_]LongOption{
    .help, .version, .print,    .continue_conversation, .resume_option, .no_session,
    .raw,  .bare,    .provider, .model,                 .effort,        .preset,
};

/// Parses argv without the program name. It matches getopt_long permutation,
/// including unique long-option abbreviations and short-option clusters.
pub fn parse(argv: []const []const u8) ParseResult {
    if (argv.len > max_arguments) return fail(.too_many_arguments, max_arguments, argv[max_arguments]);
    var total_bytes: usize = 0;
    for (argv, 0..) |argument, index| {
        total_bytes = std.math.add(usize, total_bytes, argument.len) catch
            return fail(.arguments_too_large, index, argument);
        if (total_bytes > max_argument_bytes) return fail(.arguments_too_large, index, argument);
    }

    var options: Options = .{};
    var saw_continue = false;
    var saw_resume = false;
    var continue_index: usize = 0;
    var resume_index: usize = 0;
    var selection_indexes: SelectionIndexes = .{};
    var terminated = false;
    var index: usize = 0;
    while (index < argv.len) : (index += 1) {
        const argument = argv[index];
        if (terminated or argument.len == 0 or argument[0] != '-' or std.mem.eql(u8, argument, "-")) {
            appendPrompt(&options, argument, index);
            continue;
        }
        if (std.mem.eql(u8, argument, "--")) {
            terminated = true;
            continue;
        }
        if (std.mem.startsWith(u8, argument, "--")) {
            const body = argument[2..];
            const equals_at = std.mem.findScalar(u8, body, '=');
            const candidate = if (equals_at) |at| body[0..at] else body;
            const matched = matchLong(candidate) orelse return fail(.unknown_option, index, argument);
            const value_mode = matched.valueMode();
            const option_index = index;
            var value: ?[]const u8 = if (equals_at) |at| body[at + 1 ..] else null;
            if (value_mode == .none and value != null) {
                return fail(.option_does_not_take_value, index, argument[0 .. 2 + candidate.len]);
            }
            if (value_mode == .required and value == null) {
                if (index + 1 >= argv.len) {
                    return fail(.missing_value, index, longSpelling(matched));
                }
                index += 1;
                value = argv[index];
            }
            if (applyLong(
                &options,
                matched,
                value,
                option_index,
                &saw_continue,
                &saw_resume,
                &continue_index,
                &resume_index,
                &selection_indexes,
            )) |result| return result;
            continue;
        }

        var short_index: usize = 1;
        while (short_index < argument.len) : (short_index += 1) {
            switch (argument[short_index]) {
                'h' => {
                    options.action = .help;
                    return .{ .options = options };
                },
                'v' => {
                    options.action = .version;
                    return .{ .options = options };
                },
                'p' => options.mode = .print,
                'c' => {
                    saw_continue = true;
                    continue_index = index;
                    options.continue_conversation = true;
                    options.resume_state = .latest;
                },
                else => return fail(.unknown_option, index, argument),
            }
        }
    }

    if (saw_continue and saw_resume) {
        return fail(.conflicting_resume, @max(continue_index, resume_index), "--resume");
    }
    if (emptySelection(&options.selection)) |empty| {
        return fail(.empty_value, selectionIndex(selection_indexes, empty), emptySpelling(empty));
    }
    switch (options.resume_state) {
        .id => |id| if (id.len == 0) return fail(.empty_value, resume_index, "--resume="),
        else => {},
    }
    if (options.mode == .print and options.resume_state == .select) {
        return fail(.print_resume_needs_id, resume_index, "--resume");
    }
    if (options.mode == .interactive and options.prompt_fragment_count != 0) {
        return fail(.interactive_prompt, options.prompt_indexes[0], options.prompt_fragments[0]);
    }
    return .{ .options = options };
}

fn matchLong(candidate: []const u8) ?LongOption {
    if (candidate.len == 0) return null;
    var match: ?LongOption = null;
    for (long_options) |option| {
        const option_name = option.name();
        if (std.mem.eql(u8, candidate, option_name)) return option;
        if (std.mem.startsWith(u8, option_name, candidate)) {
            if (match != null) return null;
            match = option;
        }
    }
    return match;
}

fn longSpelling(option: LongOption) []const u8 {
    return switch (option) {
        .provider => "--provider",
        .model => "--model",
        .effort => "--effort",
        .preset => "--preset",
        .resume_option => "--resume",
        else => unreachable,
    };
}

fn applyLong(
    options: *Options,
    option: LongOption,
    value: ?[]const u8,
    index: usize,
    saw_continue: *bool,
    saw_resume: *bool,
    continue_index: *usize,
    resume_index: *usize,
    selection_indexes: *SelectionIndexes,
) ?ParseResult {
    switch (option) {
        .help => {
            options.action = .help;
            return .{ .options = options.* };
        },
        .version => {
            options.action = .version;
            return .{ .options = options.* };
        },
        .print => options.mode = .print,
        .continue_conversation => {
            saw_continue.* = true;
            continue_index.* = index;
            options.continue_conversation = true;
            options.resume_state = .latest;
        },
        .resume_option => {
            saw_resume.* = true;
            resume_index.* = index;
            if (value) |id| {
                options.resume_state = .{ .id = id };
            } else options.resume_state = .select;
        },
        .no_session => options.no_session = true,
        .raw => options.raw = true,
        .bare => options.bare = true,
        .provider, .model, .effort, .preset => {
            const non_null_value = value.?;
            switch (option) {
                .provider => {
                    options.selection.provider = non_null_value;
                    selection_indexes.provider = index;
                },
                .model => {
                    options.selection.model = non_null_value;
                    selection_indexes.model = index;
                },
                .effort => {
                    options.selection.effort = non_null_value;
                    selection_indexes.effort = index;
                },
                .preset => {
                    options.selection.preset = non_null_value;
                    selection_indexes.preset = index;
                },
                else => unreachable,
            }
        },
    }
    return null;
}

fn emptySelection(selection: *const Selection) ?LongOption {
    if (selection.provider) |value| if (value.len == 0) return .provider;
    if (selection.model) |value| if (value.len == 0) return .model;
    if (selection.effort) |value| if (value.len == 0) return .effort;
    if (selection.preset) |value| if (value.len == 0) return .preset;
    return null;
}

fn selectionIndex(indexes: SelectionIndexes, option: LongOption) usize {
    return switch (option) {
        .provider => indexes.provider,
        .model => indexes.model,
        .effort => indexes.effort,
        .preset => indexes.preset,
        else => unreachable,
    };
}

fn emptySpelling(option: LongOption) []const u8 {
    return switch (option) {
        .provider => "--provider=",
        .model => "--model=",
        .effort => "--effort=",
        .preset => "--preset=",
        else => unreachable,
    };
}

fn appendPrompt(options: *Options, fragment: []const u8, index: usize) void {
    options.prompt_fragments[options.prompt_fragment_count] = fragment;
    options.prompt_indexes[options.prompt_fragment_count] = index;
    options.prompt_fragment_count += 1;
}

fn fail(kind: ParseErrorKind, index: usize, option: []const u8) ParseResult {
    return .{ .err = .{ .kind = kind, .index = index, .option = option } };
}

pub const OwnedPrompt = struct {
    bytes: []u8,

    pub fn deinit(prompt: *OwnedPrompt, allocator: std.mem.Allocator) void {
        allocator.free(prompt.bytes);
        prompt.* = undefined;
    }

    /// Joins fragments with one ASCII space. The result is not NUL-terminated.
    pub fn join(
        allocator: std.mem.Allocator,
        fragments: []const []const u8,
    ) (std.mem.Allocator.Error || error{ Overflow, TooLarge })!OwnedPrompt {
        var length: usize = if (fragments.len == 0) 0 else fragments.len - 1;
        for (fragments) |fragment| length = try std.math.add(usize, length, fragment.len);
        if (length > max_prompt_bytes) return error.TooLarge;
        const bytes = try allocator.alloc(u8, length);
        var offset: usize = 0;
        for (fragments, 0..) |fragment, fragment_index| {
            if (fragment_index != 0) {
                bytes[offset] = ' ';
                offset += 1;
            }
            @memcpy(bytes[offset..][0..fragment.len], fragment);
            offset += fragment.len;
        }
        return .{ .bytes = bytes };
    }
};

pub const StdinFacts = struct {
    stdin_is_tty: bool,
    /// Already-read stdin bytes, capped again by `choosePrompt` at
    /// `max_prompt_bytes`. Ignored when positionals exist or stdin is a TTY.
    bytes: []const u8 = "",
};

pub const PromptError = enum { missing, empty, too_large };
pub const ChoosePromptResult = union(enum) { none, prompt: OwnedPrompt, err: PromptError };

/// Selects a prompt without process I/O. Positional fragments take priority over
/// non-TTY stdin. Stdin loses one final LF and then one preceding CR, as hax does.
pub fn choosePrompt(
    allocator: std.mem.Allocator,
    options: *const Options,
    stdin: StdinFacts,
) (std.mem.Allocator.Error || error{Overflow})!ChoosePromptResult {
    if (options.mode == .interactive) return .none;
    var prompt = if (options.prompt_fragment_count != 0)
        OwnedPrompt.join(allocator, options.promptFragments()) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Overflow => return error.Overflow,
            error.TooLarge => return .{ .err = .too_large },
        }
    else if (!stdin.stdin_is_tty) stdin_prompt: {
        const sanitized = sanitizeStdin(stdin.bytes);
        if (sanitized.len > max_prompt_bytes) return .{ .err = .too_large };
        break :stdin_prompt OwnedPrompt{ .bytes = try allocator.dupe(u8, sanitized) };
    } else return .{ .err = .missing };
    if (prompt.bytes.len == 0) {
        prompt.deinit(allocator);
        return .{ .err = .empty };
    }
    return .{ .prompt = prompt };
}

fn sanitizeStdin(bytes: []const u8) []const u8 {
    var end = bytes.len;
    if (end != 0 and bytes[end - 1] == '\n') end -= 1;
    if (end != 0 and bytes[end - 1] == '\r') end -= 1;
    return bytes[0..end];
}

test "selection flags and prompt arguments" {
    const result = parse(&.{
        "--print",         "--raw",         "--bare",          "--no-session", "--provider=test",
        "--model=model-a", "--effort=high", "--preset=review", "hello",        "world",
    });
    try std.testing.expect(result == .options);
    const options = result.options;
    try std.testing.expectEqual(Mode.print, options.mode);
    try std.testing.expect(options.raw);
    try std.testing.expect(options.bare);
    try std.testing.expect(options.no_session);
    try std.testing.expectEqualStrings("test", options.selection.provider.?);
    try std.testing.expectEqualStrings("model-a", options.selection.model.?);
    try std.testing.expectEqualStrings("high", options.selection.effort.?);
    try std.testing.expectEqualStrings("review", options.selection.preset.?);
    try std.testing.expectEqualSlices([]const u8, &.{ "hello", "world" }, options.promptFragments());
}

test "resume modes and incompatible forms" {
    try std.testing.expect(parse(&.{"--continue"}).options.resume_state == .latest);
    try std.testing.expect(parse(&.{"--resume"}).options.resume_state == .select);
    try std.testing.expectEqualStrings("abc123", parse(&.{"--resume=abc123"}).options.resume_state.id);
    try std.testing.expect(parse(&.{ "--continue", "--resume=id" }).err.kind == .conflicting_resume);
    try std.testing.expect(parse(&.{ "--resume=id", "--continue" }).err.kind == .conflicting_resume);
    try std.testing.expect(parse(&.{ "-p", "--resume" }).err.kind == .print_resume_needs_id);
    try std.testing.expect(parse(&.{"--resume="}).err.kind == .empty_value);
}

test "getopt forms permutation terminator and early actions" {
    var result = parse(&.{ "hello", "--print", "world", "--raw" });
    try std.testing.expect(result == .options);
    try std.testing.expect(result.options.raw);
    try std.testing.expectEqualSlices([]const u8, &.{ "hello", "world" }, result.options.promptFragments());
    result = parse(&.{ "-pc", "question" });
    try std.testing.expect(result.options.mode == .print);
    try std.testing.expect(result.options.resume_state == .latest);
    result = parse(&.{ "-p", "--", "--raw", "-x", "" });
    try std.testing.expectEqualSlices(
        []const u8,
        &.{ "--raw", "-x", "" },
        result.options.promptFragments(),
    );
    try std.testing.expect(parse(&.{ "--help", "--bad" }).options.action == .help);
    try std.testing.expect(parse(&.{"--ver"}).options.action == .version);
    try std.testing.expect(parse(&.{"--p"}).err.kind == .unknown_option);
}

test "required values match getopt_long" {
    var result = parse(&.{ "--provider", "test", "-p", "hello" });
    try std.testing.expectEqualStrings("test", result.options.selection.provider.?);
    result = parse(&.{ "--provider", "--raw" });
    try std.testing.expectEqualStrings("--raw", result.options.selection.provider.?);
    try std.testing.expect(!result.options.raw);
    try std.testing.expect(parse(&.{"--model"}).err.kind == .missing_value);
    try std.testing.expect(parse(&.{"--effort="}).err.kind == .empty_value);
    try std.testing.expect(parse(&.{"--raw=yes"}).err.kind == .option_does_not_take_value);
    try std.testing.expect(parse(&.{ "--provider=", "--help" }).options.action == .help);
    result = parse(&.{ "--provider=", "--provider=final" });
    try std.testing.expectEqualStrings("final", result.options.selection.provider.?);
}

test "prompt joining precedence sanitation empty unicode and OOM" {
    var parsed = parse(&.{ "-p", "héllo", "世界" }).options;
    var chosen = try choosePrompt(std.testing.allocator, &parsed, .{
        .stdin_is_tty = false,
        .bytes = "ignored\n",
    });
    try std.testing.expectEqualStrings("héllo 世界", chosen.prompt.bytes);
    chosen.prompt.deinit(std.testing.allocator);

    parsed = parse(&.{"-p"}).options;
    chosen = try choosePrompt(std.testing.allocator, &parsed, .{
        .stdin_is_tty = false,
        .bytes = "first\nsecond\r\n",
    });
    try std.testing.expectEqualStrings("first\nsecond", chosen.prompt.bytes);
    chosen.prompt.deinit(std.testing.allocator);
    chosen = try choosePrompt(std.testing.allocator, &parsed, .{
        .stdin_is_tty = false,
        .bytes = "first\n\n",
    });
    try std.testing.expectEqualStrings("first\n", chosen.prompt.bytes);
    chosen.prompt.deinit(std.testing.allocator);
    try std.testing.expect((try choosePrompt(std.testing.allocator, &parsed, .{
        .stdin_is_tty = true,
    })) == .err);
    try std.testing.expect((try choosePrompt(std.testing.allocator, &parsed, .{
        .stdin_is_tty = false,
        .bytes = "\n",
    })).err == .empty);

    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, choosePrompt(fixed.allocator(), &parsed, .{
        .stdin_is_tty = false,
        .bytes = "x",
    }));
}

test "argument bounds" {
    const too_many: [max_arguments + 1][]const u8 = @splat("");
    try std.testing.expect(parse(&too_many).err.kind == .too_many_arguments);
    const too_large = "x" ** (max_argument_bytes + 1);
    try std.testing.expect(parse(&.{too_large}).err.kind == .arguments_too_large);
}

test "error indexes and prompt caps are exact" {
    try std.testing.expectEqual(@as(usize, 1), parse(&.{ "--raw", "prompt" }).err.index);
    const excess: [max_arguments + 1][]const u8 = @splat("x");
    try std.testing.expectEqual(max_arguments, parse(&excess).err.index);

    var options = parse(&.{"-p"}).options;
    const exact_stdin = "x" ** max_prompt_bytes;
    var exact = try choosePrompt(std.testing.allocator, &options, .{
        .stdin_is_tty = false,
        .bytes = exact_stdin,
    });
    defer exact.prompt.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_prompt_bytes, exact.prompt.bytes.len);

    const oversized_stdin = "x" ** (max_prompt_bytes + 1);
    try std.testing.expect((try choosePrompt(std.testing.allocator, &options, .{
        .stdin_is_tty = false,
        .bytes = oversized_stdin,
    })).err == .too_large);

    var exact_join = try OwnedPrompt.join(std.testing.allocator, &.{exact_stdin});
    defer exact_join.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_prompt_bytes, exact_join.bytes.len);
    try std.testing.expectError(
        error.TooLarge,
        OwnedPrompt.join(std.testing.allocator, &.{ exact_stdin[0 .. exact_stdin.len - 1], "x" }),
    );

    const chunk = "x" ** ((max_argument_bytes - 2) / (max_arguments - 1));
    var argv: [max_arguments][]const u8 = @splat(chunk);
    argv[0] = "-p";
    options = parse(&argv).options;
    try std.testing.expect((try choosePrompt(std.testing.allocator, &options, .{
        .stdin_is_tty = true,
    })).err == .too_large);
}

test "positional prompt join propagates allocation failure" {
    const options = parse(&.{ "-p", "hello" }).options;
    var storage: [0]u8 = .{};
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    try std.testing.expectError(error.OutOfMemory, choosePrompt(fixed.allocator(), &options, .{
        .stdin_is_tty = true,
    }));
}

test "parse diagnostics visibly escape untrusted argv controls" {
    const result = parse(&.{"--bad\n\r\t\x1b\x00"});
    var storage: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&storage);
    try result.err.render(&writer);
    try std.testing.expectEqualStrings(
        "unknown option '--bad\\n\\r\\t\\x1b\\x00'\nTry 'zi --help' for usage.",
        writer.buffered(),
    );
}
