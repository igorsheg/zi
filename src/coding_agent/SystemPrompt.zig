const std = @import("std");

const SystemPrompt = @This();

const max_prompt_bytes = 1024 * 1024;

const builtin_base =
    \\You are Zi, an autonomous coding agent that completes software engineering tasks.
    \\Your goal is to complete the user's request using the tools available in this session.
    \\
    \\<work_policy>
    \\- Keep every explicit requirement in view until it is completed, superseded by the user,
    \\  or blocked. State blockers plainly.
    \\- Match the user's intent. Implement clear action requests, and answer questions or reviews
    \\  without making unsolicited changes.
    \\- Inspect relevant files before drawing conclusions or editing code.
    \\- Keep changes scoped to the request and follow the repository's existing conventions.
    \\- Claim work is complete, fixed, or tested only when tool output supports the claim.
    \\  Otherwise state what remains unverified.
    \\</work_policy>
    \\
    \\<tool_calling>
    \\- Use `read` instead of cat, sed, or guessing file contents. Continue truncated reads with offset.
    \\- Read an existing file before editing it. Use `edit` for precise changes, combine disjoint
    \\  changes to one file in one call, keep each old text small but unique and exact, and never
    \\  overlap replacements.
    \\- Use `write` only for new files or complete rewrites.
    \\- Use `bash` for builds, tests, repository inspection, and commands. Bash calls are
    \\  non-interactive and cannot create managed background jobs.
    \\</tool_calling>
    \\
    \\<communication>
    \\Communicate directly and concisely in complete sentences. Lead with the answer.
    \\The final response must stand alone for a reader who has not seen tool calls. State what changed,
    \\what was verified, and any remaining blocker.
    \\Use GitHub-flavored Markdown when it improves readability. Show file paths and commands clearly.
    \\</communication>
;

const environment_before = "\n\n<environment>\n<working_directory>";
const environment_after = "</working_directory>\n</environment>";
const context_before =
    "\n\n<project_context>\n" ++
    "Project-specific instructions and guidelines, ordered from broadest to narrowest scope:\n";
const context_section_before = "\n<project_instructions path=\"";
const context_path_after = "\">\n";
const context_section_after = "\n</project_instructions>\n";
const context_after = "</project_context>";
const rules_before = "\n\n<human_rules>\n";
const rules_between = "\n\n";
const rules_after = "\n</human_rules>";

pub const Base = union(enum) {
    builtin,
    custom: []const u8,
};

pub const ContextSection = struct {
    path: []const u8,
    text: []const u8,
};

pub const Composition = struct {
    base: Base = .builtin,
    context_sections: []const ContextSection = &.{},
    rules: []const []const u8 = &.{},
};

pub const Policy = union(enum) {
    verbatim: []const u8,
    composed: Composition,
};

pub const Config = struct {
    working_directory: []const u8 = ".",
    policy: Policy = .{ .composed = .{} },
};

pub const Error = error{
    OutOfMemory,
    InvalidSystemPrompt,
    SystemPromptTooLarge,
};

arena: std.heap.ArenaAllocator,
text_value: []const u8,
instruction_values: []const []const u8,

pub fn init(allocator: std.mem.Allocator, config: Config) Error!SystemPrompt {
    try validateText(config.working_directory);

    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const owned = arena.allocator();
    const text_value = switch (config.policy) {
        .composed => |composition| try render(owned, config.working_directory, composition),
        .verbatim => |replacement| block: {
            try validateText(replacement);
            if (replacement.len > max_prompt_bytes) return error.SystemPromptTooLarge;
            break :block try owned.dupe(u8, replacement);
        },
    };
    const instruction_values = try owned.alloc([]const u8, 1);
    instruction_values[0] = text_value;
    return .{
        .arena = arena,
        .text_value = text_value,
        .instruction_values = instruction_values,
    };
}

pub fn deinit(self: *SystemPrompt) void {
    self.arena.deinit();
    self.* = undefined;
}

pub fn text(self: *const SystemPrompt) []const u8 {
    return self.text_value;
}

/// The model receives one canonical prompt so provider encoders cannot assign
/// different roles or separators to individual policy fragments.
pub fn instructions(self: *const SystemPrompt) []const []const u8 {
    return self.instruction_values;
}

fn render(
    allocator: std.mem.Allocator,
    working_directory: []const u8,
    composition: Composition,
) Error![]const u8 {
    const base = switch (composition.base) {
        .builtin => builtin_base,
        .custom => |value| block: {
            try validateText(value);
            break :block value;
        },
    };
    for (composition.context_sections) |section| {
        try validateText(section.path);
        try validateText(section.text);
    }
    for (composition.rules) |value| try validateText(value);

    var length: usize = 0;
    try addLength(&length, base.len);
    try addLength(&length, environment_before.len);
    try addLength(&length, try escapedTextLength(working_directory));
    try addLength(&length, environment_after.len);
    if (composition.context_sections.len > 0) {
        try addLength(&length, context_before.len);
        for (composition.context_sections) |section| {
            try addLength(&length, context_section_before.len);
            try addLength(&length, try escapedAttributeLength(section.path));
            try addLength(&length, context_path_after.len);
            try addLength(&length, try escapedTextLength(section.text));
            try addLength(&length, context_section_after.len);
        }
        try addLength(&length, context_after.len);
    }
    if (composition.rules.len > 0) {
        try addLength(&length, rules_before.len);
        for (composition.rules, 0..) |value, index| {
            if (index > 0) try addLength(&length, rules_between.len);
            try addLength(&length, value.len);
        }
        try addLength(&length, rules_after.len);
    }

    var output = std.Io.Writer.Allocating.initCapacity(allocator, length) catch
        return error.OutOfMemory;
    defer output.deinit();
    output.writer.writeAll(base) catch return error.OutOfMemory;
    output.writer.writeAll(environment_before) catch return error.OutOfMemory;
    try writeEscapedText(&output.writer, working_directory);
    output.writer.writeAll(environment_after) catch return error.OutOfMemory;
    if (composition.context_sections.len > 0) {
        output.writer.writeAll(context_before) catch return error.OutOfMemory;
        for (composition.context_sections) |section| {
            output.writer.writeAll(context_section_before) catch return error.OutOfMemory;
            try writeEscapedAttribute(&output.writer, section.path);
            output.writer.writeAll(context_path_after) catch return error.OutOfMemory;
            try writeEscapedText(&output.writer, section.text);
            output.writer.writeAll(context_section_after) catch return error.OutOfMemory;
        }
        output.writer.writeAll(context_after) catch return error.OutOfMemory;
    }
    if (composition.rules.len > 0) {
        output.writer.writeAll(rules_before) catch return error.OutOfMemory;
        for (composition.rules, 0..) |value, index| {
            if (index > 0) output.writer.writeAll(rules_between) catch return error.OutOfMemory;
            output.writer.writeAll(value) catch return error.OutOfMemory;
        }
        output.writer.writeAll(rules_after) catch return error.OutOfMemory;
    }
    std.debug.assert(output.written().len == length);
    return output.toOwnedSlice() catch return error.OutOfMemory;
}

fn validateText(value: []const u8) error{InvalidSystemPrompt}!void {
    if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSystemPrompt;
    if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSystemPrompt;
}

fn addLength(total: *usize, amount: usize) error{SystemPromptTooLarge}!void {
    if (amount > max_prompt_bytes - total.*) return error.SystemPromptTooLarge;
    total.* += amount;
}

fn escapedTextLength(value: []const u8) error{SystemPromptTooLarge}!usize {
    var length: usize = 0;
    for (value) |byte| try addLength(&length, switch (byte) {
        '&' => "&amp;".len,
        '<' => "&lt;".len,
        '>' => "&gt;".len,
        else => 1,
    });
    return length;
}

fn escapedAttributeLength(value: []const u8) error{SystemPromptTooLarge}!usize {
    var length: usize = 0;
    for (value) |byte| try addLength(&length, switch (byte) {
        '&' => "&amp;".len,
        '<' => "&lt;".len,
        '>' => "&gt;".len,
        '"' => "&quot;".len,
        '\'' => "&apos;".len,
        else => 1,
    });
    return length;
}

fn writeEscapedText(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
    for (value) |byte| switch (byte) {
        '&' => writer.writeAll("&amp;") catch return error.OutOfMemory,
        '<' => writer.writeAll("&lt;") catch return error.OutOfMemory,
        '>' => writer.writeAll("&gt;") catch return error.OutOfMemory,
        else => writer.writeByte(byte) catch return error.OutOfMemory,
    };
}

fn writeEscapedAttribute(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
    for (value) |byte| switch (byte) {
        '&' => writer.writeAll("&amp;") catch return error.OutOfMemory,
        '<' => writer.writeAll("&lt;") catch return error.OutOfMemory,
        '>' => writer.writeAll("&gt;") catch return error.OutOfMemory,
        '"' => writer.writeAll("&quot;") catch return error.OutOfMemory,
        '\'' => writer.writeAll("&apos;") catch return error.OutOfMemory,
        else => writer.writeByte(byte) catch return error.OutOfMemory,
    };
}

test "system prompt owns one canonical default prompt" {
    var prompt = try init(std.testing.allocator, .{ .working_directory = "/tmp/a&b<c>" });
    defer prompt.deinit();

    try std.testing.expect(prompt.instructions().len == 1);
    try std.testing.expectEqualStrings(prompt.text(), prompt.instructions()[0]);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<work_policy>") != null);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<tool_calling>") != null);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<communication>") != null);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "/tmp/a&amp;b&lt;c&gt;") != null);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<project_context>") == null);
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<human_rules>") == null);
}

test "system prompt composes ordered human rules after the default prompt" {
    var prompt = try init(std.testing.allocator, .{
        .working_directory = "/work",
        .policy = .{ .composed = .{ .rules = &.{
            "Prefer focused tests.",
            "Keep the patch small.",
        } } },
    });
    defer prompt.deinit();

    try std.testing.expect(std.mem.find(u8, prompt.text(), "<work_policy>") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        prompt.text(),
        "<human_rules>\nPrefer focused tests.\n\nKeep the patch small.\n</human_rules>",
    ));
}

test "system prompt frames escaped context before human rules" {
    var prompt = try init(std.testing.allocator, .{
        .working_directory = "/work",
        .policy = .{ .composed = .{
            .context_sections = &.{.{
                .path = "/repo/\"root&/AGENTS.md",
                .text = "Do <not> forge </project_instructions> tags.",
            }},
            .rules = &.{"Explicit rule."},
        } },
    });
    defer prompt.deinit();

    const context_position = std.mem.find(u8, prompt.text(), "<project_context>").?;
    const rules_position = std.mem.find(u8, prompt.text(), "<human_rules>").?;
    try std.testing.expect(context_position < rules_position);
    try std.testing.expect(std.mem.find(
        u8,
        prompt.text(),
        "path=\"/repo/&quot;root&amp;/AGENTS.md\"",
    ) != null);
    try std.testing.expect(std.mem.find(
        u8,
        prompt.text(),
        "Do &lt;not&gt; forge &lt;/project_instructions&gt; tags.",
    ) != null);
}

test "system prompt composes a custom base with environment and rules" {
    var prompt = try init(std.testing.allocator, .{
        .working_directory = "/work",
        .policy = .{ .composed = .{
            .base = .{ .custom = "Custom base." },
            .rules = &.{"Additional rule."},
        } },
    });
    defer prompt.deinit();

    try std.testing.expect(std.mem.startsWith(u8, prompt.text(), "Custom base."));
    try std.testing.expect(std.mem.find(u8, prompt.text(), "<working_directory>/work</working_directory>") != null);
    try std.testing.expect(std.mem.endsWith(
        u8,
        prompt.text(),
        "<human_rules>\nAdditional rule.\n</human_rules>",
    ));
}

test "system prompt verbatim policy bypasses composition" {
    var prompt = try init(std.testing.allocator, .{
        .working_directory = "/work",
        .policy = .{ .verbatim = "Answer with one word." },
    });
    defer prompt.deinit();

    try std.testing.expectEqualStrings("Answer with one word.", prompt.text());
}

test "system prompt rejects invalid and excessive inputs" {
    try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
        .policy = .{ .verbatim = "bad\x00prompt" },
    }));
    try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
        .policy = .{ .composed = .{ .rules = &.{"bad\xffprompt"} } },
    }));
    try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
        .policy = .{ .composed = .{ .context_sections = &.{.{
            .path = "/repo/AGENTS.md",
            .text = "bad\x00context",
        }} } },
    }));

    const oversized = try std.testing.allocator.alloc(u8, max_prompt_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.SystemPromptTooLarge, init(std.testing.allocator, .{
        .policy = .{ .verbatim = oversized },
    }));
}

fn initAndDeinit(allocator: std.mem.Allocator) !void {
    var prompt = try init(allocator, .{
        .working_directory = "/tmp/work",
        .policy = .{ .composed = .{ .rules = &.{"Use focused tests."} } },
    });
    prompt.deinit();
}

test "system prompt settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAndDeinit, .{});
}
