const std = @import("std");
const resources = @import("resources.zig");
const skills_mod = @import("skills.zig");

pub const max_prompt_bytes = 512 * 1024;
pub const max_tool_snippets = 128;

pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const BuildOptions = struct {
    cwd: []const u8,
    current_date: []const u8,
    selected_tools: []const []const u8 = &.{ "read", "bash", "edit", "write" },
    tool_snippets: []const ToolSnippet = &.{},
    context_files: []const resources.ContextFile = &.{},
    skills: []const skills_mod.Skill = &.{},
    custom_prompt: ?[]const u8 = null,
    append_system_prompt: ?[]const u8 = null,
};

pub fn build(allocator: std.mem.Allocator, options: BuildOptions) ![]u8 {
    if (options.selected_tools.len > max_tool_snippets) return error.ToolSnippetLimitExceeded;
    if (options.tool_snippets.len > max_tool_snippets) return error.ToolSnippetLimitExceeded;

    var writer: std.Io.Writer.Allocating = .init(allocator);
    errdefer writer.deinit();

    if (options.custom_prompt) |custom_prompt| if (custom_prompt.len > 0) {
        try appendBounded(&writer, custom_prompt);
        try appendAppendSystemPrompt(&writer, options.append_system_prompt);
        try appendProjectContext(&writer, options.context_files);
        if (containsString(options.selected_tools, "read")) try appendSkills(&writer, options.skills);
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
    try appendGuidelines(&writer, options.selected_tools);
    try appendAppendSystemPrompt(&writer, options.append_system_prompt);
    try appendProjectContext(&writer, options.context_files);
    if (containsString(options.selected_tools, "read")) try appendSkills(&writer, options.skills);
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
) !void {
    if (containsString(selected_tools, "bash")) {
        try appendGuideline(writer, "Use bash for shell-based file exploration");
    }
    if (containsString(selected_tools, "symbols")) {
        try appendGuideline(
            writer,
            "Use symbols to locate declarations in a .zig file before reading it; " ++
                "then read with the reported line as offset instead of reading the whole file",
        );
    }

    try appendGuideline(writer, "Be concise in your responses");
    try appendGuideline(writer, "Show file paths clearly when working with files");
}

fn appendGuideline(writer: *std.Io.Writer.Allocating, guideline: []const u8) !void {
    try appendBounded(writer, "- ");
    try appendBounded(writer, guideline);
    try appendBounded(writer, "\n");
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

fn appendSkills(writer: *std.Io.Writer.Allocating, loaded_skills: []const skills_mod.Skill) !void {
    if (loaded_skills.len == 0) return;
    try appendBounded(writer, "\n\nThe following skills provide specialized instructions for specific tasks.\n");
    try appendBounded(writer, "Use the read tool to load a skill's file when the task matches its description.\n");
    try appendBounded(
        writer,
        "When a skill file references a relative path, resolve it against the skill directory " ++
            "(parent of SKILL.md / dirname of the path) and use that absolute path in tool commands.\n\n",
    );
    try appendBounded(writer, "<available_skills>\n");
    for (loaded_skills) |skill| {
        try appendBounded(writer, "  <skill>\n    <name>");
        try appendXmlEscaped(writer, skill.name);
        try appendBounded(writer, "</name>\n    <description>");
        try appendXmlEscaped(writer, skill.description);
        try appendBounded(writer, "</description>\n    <location>");
        try appendXmlEscaped(writer, skill.path);
        try appendBounded(writer, "</location>\n  </skill>\n");
    }
    try appendBounded(writer, "</available_skills>");
}

fn appendXmlEscaped(writer: *std.Io.Writer.Allocating, text: []const u8) !void {
    for (text) |char| {
        switch (char) {
            '&' => try appendBounded(writer, "&amp;"),
            '<' => try appendBounded(writer, "&lt;"),
            '>' => try appendBounded(writer, "&gt;"),
            '"' => try appendBounded(writer, "&quot;"),
            '\'' => try appendBounded(writer, "&apos;"),
            else => {
                if (writer.writer.end + 1 > max_prompt_bytes) return error.PromptTooLarge;
                try writer.writer.writeByte(char);
            },
        }
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

test "skills are included only when read tool is selected" {
    const loaded_skills = [_]skills_mod.Skill{.{
        .path = "/repo/.zi/skills/zig/SKILL.md",
        .name = "zig<&",
        .description = "use > zig",
    }};
    const prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{"read"},
        .skills = &loaded_skills,
    });
    defer std.testing.allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "zig&lt;&amp;") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "use &gt; zig") != null);

    const no_read_prompt = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{"bash"},
        .skills = &loaded_skills,
    });
    defer std.testing.allocator.free(no_read_prompt);

    try std.testing.expect(std.mem.indexOf(u8, no_read_prompt, "<available_skills>") == null);
}

test "symbols guideline appears only when symbols is selected" {
    const with_symbols = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{"symbols"},
    });
    defer std.testing.allocator.free(with_symbols);
    try std.testing.expect(std.mem.indexOf(u8, with_symbols, "Use symbols to locate declarations") != null);

    const without_symbols = try build(std.testing.allocator, .{
        .cwd = "/repo",
        .current_date = "2026-05-25",
        .selected_tools = &.{"read"},
    });
    defer std.testing.allocator.free(without_symbols);
    try std.testing.expect(std.mem.indexOf(u8, without_symbols, "Use symbols to locate declarations") == null);
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
