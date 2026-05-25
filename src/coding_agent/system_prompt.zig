const std = @import("std");
const resources = @import("resources.zig");

pub const max_prompt_bytes = 512 * 1024;
pub const max_tool_snippets = 128;
pub const max_guidelines = 128;

pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const BuildOptions = struct {
    cwd: []const u8,
    current_date: []const u8,
    selected_tools: []const []const u8 = &.{ "read", "bash", "edit", "write" },
    tool_snippets: []const ToolSnippet = &.{},
    prompt_guidelines: []const []const u8 = &.{},
    context_files: []const resources.ContextFile = &.{},
    custom_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
    readme_path: []const u8 = "README.md",
    docs_path: []const u8 = "docs",
    examples_path: []const u8 = "examples",
};

pub fn build(allocator: std.mem.Allocator, options: BuildOptions) ![]u8 {
    if (options.selected_tools.len > max_tool_snippets) return error.ToolSnippetLimitExceeded;
    if (options.tool_snippets.len > max_tool_snippets) return error.ToolSnippetLimitExceeded;
    if (options.prompt_guidelines.len > max_guidelines) return error.GuidelineLimitExceeded;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    if (options.custom_prompt) |custom_prompt| if (custom_prompt.len > 0) {
        try appendBounded(&writer, custom_prompt);
        try appendAppendSystemPrompt(&writer, options.append_system_prompt);
        try appendProjectContext(&writer, options.context_files);
        try appendDateAndCwd(&writer, options.current_date, options.cwd);
        return writer.toOwnedSlice();
    };

    try appendBounded(
        &writer,
        "You are an expert coding assistant operating inside zi, a coding agent harness. " ++
            "You help users by reading files, executing commands, editing code, and writing new files.\n\n",
    );
    try appendBounded(&writer, "Available tools:\n");
    try appendTools(&writer, options.selected_tools, options.tool_snippets);
    try appendBounded(
        &writer,
        "\n\nIn addition to the tools above, you may have access to other custom tools depending on the project.\n\n",
    );
    try appendBounded(&writer, "Guidelines:\n");
    try appendGuidelines(&writer, options.selected_tools, options.prompt_guidelines);
    try appendPiDocumentation(&writer, options);
    try appendAppendSystemPrompt(&writer, options.append_system_prompt);
    try appendProjectContext(&writer, options.context_files);
    try appendDateAndCwd(&writer, options.current_date, options.cwd);
    return writer.toOwnedSlice();
}

fn appendTools(
    writer: *std.Io.Writer.Allocating,
    selected_tools: []const []const u8,
    tool_snippets: []const ToolSnippet,
) !void {
    var visible: usize = 0;
    for (selected_tools) |tool_name| {
        if (findSnippet(tool_snippets, tool_name)) |snippet| {
            if (visible > 0) try appendBounded(writer, "\n");
            try appendBounded(writer, "- ");
            try appendBounded(writer, tool_name);
            try appendBounded(writer, ": ");
            try appendBounded(writer, snippet);
            visible += 1;
        }
    }
    if (visible == 0) try appendBounded(writer, "(none)");
}

fn appendGuidelines(
    writer: *std.Io.Writer.Allocating,
    selected_tools: []const []const u8,
    prompt_guidelines: []const []const u8,
) !void {
    var guidelines: [max_guidelines][]const u8 = undefined;
    var len: usize = 0;

    const has_bash = containsString(selected_tools, "bash");
    const has_grep = containsString(selected_tools, "grep");
    const has_find = containsString(selected_tools, "find");
    const has_ls = containsString(selected_tools, "ls");
    if (has_bash and !has_grep and !has_find and !has_ls) {
        try appendGuideline(&guidelines, &len, "Use bash for file operations like ls, rg, find");
    } else if (has_bash and (has_grep or has_find or has_ls)) {
        try appendGuideline(
            &guidelines,
            &len,
            "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)",
        );
    }

    for (prompt_guidelines) |guideline| {
        const trimmed = std.mem.trim(u8, guideline, " \t\r\n");
        if (trimmed.len > 0) try appendGuideline(&guidelines, &len, trimmed);
    }

    try appendGuideline(&guidelines, &len, "Be concise in your responses");
    try appendGuideline(&guidelines, &len, "Show file paths clearly when working with files");

    for (guidelines[0..len]) |guideline| {
        try appendBounded(writer, "- ");
        try appendBounded(writer, guideline);
        try appendBounded(writer, "\n");
    }
}

fn appendGuideline(guidelines: *[max_guidelines][]const u8, len: *usize, guideline: []const u8) !void {
    for (guidelines[0..len.*]) |existing| {
        if (std.mem.eql(u8, existing, guideline)) return;
    }
    if (len.* == max_guidelines) return error.GuidelineLimitExceeded;
    guidelines[len.*] = guideline;
    len.* += 1;
}

fn appendPiDocumentation(writer: *std.Io.Writer.Allocating, options: BuildOptions) !void {
    try appendBounded(
        writer,
        "\nZi documentation (read only when the user asks about zi itself, " ++
            "its SDK, extensions, themes, skills, or TUI):\n",
    );
    try appendBounded(writer, "- Main documentation: ");
    try appendBounded(writer, options.readme_path);
    try appendBounded(writer, "\n- Additional docs: ");
    try appendBounded(writer, options.docs_path);
    try appendBounded(writer, "\n- Examples: ");
    try appendBounded(writer, options.examples_path);
    try appendBounded(writer, " (extensions, custom tools, SDK)\n");
    try appendBounded(
        writer,
        "- When asked about: extensions (docs/extensions.md, examples/extensions/), " ++
            "themes (docs/themes.md), skills (docs/skills.md), prompt templates (docs/prompt-templates.md), " ++
            "TUI components (docs/tui.md), keybindings (docs/keybindings.md), SDK integrations (docs/sdk.md), " ++
            "custom providers (docs/custom-provider.md), adding models (docs/models.md), " ++
            "zi packages (docs/packages.md)\n",
    );
    try appendBounded(
        writer,
        "- When working on zi topics, read the docs and examples, " ++
            "and follow .md cross-references before implementing\n",
    );
    try appendBounded(
        writer,
        "- Always read zi .md files completely and follow links to related docs " ++
            "(e.g., tui.md for TUI API details)\n",
    );
}

fn appendAppendSystemPrompt(writer: *std.Io.Writer.Allocating, append_system_prompt: ?[]const u8) !void {
    if (append_system_prompt) |append| {
        if (append.len == 0) return;
        try appendBounded(writer, "\n\n");
        try appendBounded(writer, append);
    }
}

fn appendProjectContext(writer: *std.Io.Writer.Allocating, context_files: []const resources.ContextFile) !void {
    if (context_files.len == 0) return;
    try appendBounded(writer, "\n\n# Project Context\n\n");
    try appendBounded(writer, "Project-specific instructions and guidelines:\n\n");
    for (context_files) |file| {
        try appendBounded(writer, "## ");
        try appendBounded(writer, file.path);
        try appendBounded(writer, "\n\n");
        try appendBounded(writer, file.content);
        try appendBounded(writer, "\n\n");
    }
}

fn appendDateAndCwd(writer: *std.Io.Writer.Allocating, current_date: []const u8, cwd: []const u8) !void {
    try appendBounded(writer, "\nCurrent date: ");
    try appendBounded(writer, current_date);
    try appendBounded(writer, "\nCurrent working directory: ");
    for (cwd) |char| {
        if (writer.writer.end + 1 > max_prompt_bytes) return error.PromptTooLarge;
        try writer.writer.writeByte(if (char == '\\') '/' else char);
    }
}

fn appendBounded(writer: *std.Io.Writer.Allocating, text: []const u8) !void {
    if (writer.writer.end + text.len > max_prompt_bytes) return error.PromptTooLarge;
    try writer.writer.writeAll(text);
}

fn findSnippet(snippets: []const ToolSnippet, name: []const u8) ?[]const u8 {
    for (snippets) |snippet| {
        if (std.mem.eql(u8, snippet.name, name)) return snippet.snippet;
    }
    return null;
}

fn containsString(values: []const []const u8, needle: []const u8) bool {
    for (values) |value| {
        if (std.mem.eql(u8, value, needle)) return true;
    }
    return false;
}

test "empty tools shows none and default guidelines" {
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{},
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Available tools:\n(none)") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Show file paths clearly") != null);
}

test "tool snippets are shown only for selected tools with snippets" {
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{ "read", "dynamic" },
        .tool_snippets = &.{.{ .name = "dynamic", .snippet = "Run dynamic behavior" }},
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "- dynamic: Run dynamic behavior") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "- read:") == null);
}

test "guidelines dedupe and trim" {
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{"read"},
        .prompt_guidelines = &.{ "Use read carefully.", "  Use read carefully.  ", "   " },
    });
    defer std.testing.allocator.free(prompt);

    const first = std.mem.indexOf(u8, prompt, "- Use read carefully.") orelse return error.TestExpectedEqual;
    try std.testing.expect(std.mem.indexOfPos(u8, prompt, first + 1, "- Use read carefully.") == null);
}

test "default prompt includes pi documentation paths" {
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{},
        .readme_path = "/zi/README.md",
        .docs_path = "/zi/docs",
        .examples_path = "/zi/examples",
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "Main documentation: /zi/README.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Additional docs: /zi/docs") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Examples: /zi/examples") != null);
}

test "empty custom and append prompts are ignored" {
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{},
        .custom_prompt = "",
        .append_system_prompt = "",
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "You are an expert coding assistant"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "\n\n\nCurrent date") == null);
}

test "custom prompt appends context date and cwd" {
    const context = [_]resources.ContextFile{.{ .path = "/repo/AGENTS.md", .content = "rules" }};
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{},
        .context_files = &context,
        .custom_prompt = "custom",
        .append_system_prompt = "append",
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.startsWith(u8, prompt, "custom\n\nappend"));
    try std.testing.expect(std.mem.indexOf(u8, prompt, "## /repo/AGENTS.md\n\nrules") != null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "Current working directory: /repo"));
}
