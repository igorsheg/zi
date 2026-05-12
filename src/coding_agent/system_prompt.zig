const std = @import("std");
const resource_types = @import("resources/types.zig");
const time_util = @import("../lib/time_util.zig");

pub const ContextFile = resource_types.AgentsFile;

const default_tool_names = [_][]const u8{ "read", "bash", "edit", "write" };

pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const Options = struct {
    custom_prompt: ?[]const u8 = null,
    tool_names: []const []const u8 = &.{},
    tool_snippets: []const ToolSnippet = &.{},
    guidelines: []const []const u8 = &.{},

    skills_section: ?[]const u8 = null,

    append_system_prompt: []const []const u8 = &.{},
    cwd: []const u8 = ".",

    context_files: []const ContextFile = &.{},
};

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn effectiveToolNames(tool_names: []const []const u8) []const []const u8 {
    return if (tool_names.len > 0) tool_names else default_tool_names[0..];
}

fn normalizeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, cwd);
    for (result) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return result;
}

pub fn buildSystemPrompt(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    const date = try time_util.isoDateNow(allocator);
    defer allocator.free(date);

    const cwd = try normalizeCwd(allocator, options.cwd);
    defer allocator.free(cwd);

    const tool_names = effectiveToolNames(options.tool_names);
    const has_read = containsStr(tool_names, "read");

    if (options.custom_prompt) |custom| {
        try w.writeAll(custom);
        try writeAppendSystemPrompt(w, options.append_system_prompt);
        try writeContextFiles(w, options.context_files);
        if (has_read) {
            try writeSkillsSection(w, options.skills_section);
        }
        try w.print("\nCurrent date: {s}", .{date});
        try w.print("\nCurrent working directory: {s}", .{cwd});
        return try aw.toOwnedSlice();
    }

    try w.writeAll(
        "You are an expert coding assistant operating inside zi, a coding agent harness." ++
            " You help users by reading files, executing commands, editing code, and writing new files.",
    );

    try w.writeAll("\n\nAvailable tools:\n");
    var visible_count: usize = 0;
    for (tool_names) |name| {
        if (findSnippet(options.tool_snippets, name)) |snippet| {
            try w.print("- {s}: {s}\n", .{ name, snippet });
            visible_count += 1;
        }
    }
    if (visible_count == 0) {
        try w.writeAll("(none)\n");
    }

    try w.writeAll(
        "\nIn addition to the tools above, you may have access to other custom tools depending on the project.\n",
    );

    try w.writeAll("\nGuidelines:\n");

    var guideline_list: std.ArrayList([]const u8) = .empty;
    defer guideline_list.deinit(allocator);

    const has_bash = containsStr(tool_names, "bash");
    const has_grep = containsStr(tool_names, "grep");
    const has_find = containsStr(tool_names, "find");
    const has_ls = containsStr(tool_names, "ls");

    if (has_bash and !has_grep and !has_find and !has_ls) {
        try guideline_list.append(allocator, "Use bash for file operations like ls, rg, find");
    } else if (has_bash and (has_grep or has_find or has_ls)) {
        try guideline_list.append(allocator, "Prefer grep/find/ls tools over bash for file exploration (faster, respects .gitignore)");
    }

    for (options.guidelines) |g| {
        const trimmed = std.mem.trim(u8, g, " \t\r\n");
        if (trimmed.len > 0 and !containsGuideline(guideline_list.items, trimmed)) {
            try guideline_list.append(allocator, trimmed);
        }
    }

    const always = [_][]const u8{
        "Be concise in your responses",
        "Show file paths clearly when working with files",
    };
    for (&always) |g| {
        if (!containsGuideline(guideline_list.items, g)) {
            try guideline_list.append(allocator, g);
        }
    }

    for (guideline_list.items) |g| {
        try w.print("- {s}\n", .{g});
    }

    try writeZiDocsSection(w);
    try writeAppendSystemPrompt(w, options.append_system_prompt);
    try writeContextFiles(w, options.context_files);
    if (has_read) {
        try writeSkillsSection(w, options.skills_section);
    }

    try w.print("\nCurrent date: {s}", .{date});
    try w.print("\nCurrent working directory: {s}", .{cwd});

    return try aw.toOwnedSlice();
}

fn findSnippet(snippets: []const ToolSnippet, name: []const u8) ?[]const u8 {
    for (snippets) |s| {
        if (std.mem.eql(u8, s.name, name)) return s.snippet;
    }
    return null;
}

fn containsGuideline(list: []const []const u8, needle: []const u8) bool {
    for (list) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

fn writeZiDocsSection(w: *std.Io.Writer) !void {
    try w.writeAll(
        "\nZi documentation (read only when the user asks about zi itself, its CLI, settings, resources, tools, sessions, skills, prompts, themes, agent context, extensions, or TUI):\n" ++
            "- Search documentation: `zi --docs <query>`\n" ++
            "- Read documentation topics: `zi --man [topic]`\n" ++
            "- CLI usage and actions: `zi --help`\n" ++
            "- Topics: `intro`, `cli`, `settings`, `resources`, `skills`, `prompts`, `themes`, `agent-context`, `extensions`, `api`, `context`, `guidance`\n" ++
            "- When asked about: CLI usage, configuration, resource discovery, skills, prompts, themes, AGENTS.md/CLAUDE.md, tools, sessions, providers, adding models, or zi internals\n" ++
            "- When working on zi topics, use `zi --docs <query>` and `zi --man [topic]` before implementing\n" ++
            "- Follow cross-references from `zi --man` topics to related embedded docs\n" ++
            "- Prefer the docs over memory. Stale assumptions are bugs with better posture.\n",
    );
}

fn writeSkillsSection(w: *std.Io.Writer, section: ?[]const u8) !void {
    const value = section orelse return;
    if (value.len == 0) return;
    try w.writeAll(value);
}

fn writeAppendSystemPrompt(w: *std.Io.Writer, prompts: []const []const u8) !void {
    if (prompts.len == 0) return;
    for (prompts) |prompt| {
        try w.writeAll("\n\n");
        try w.writeAll(prompt);
    }
}

fn writeContextFiles(w: *std.Io.Writer, files: []const ContextFile) !void {
    if (files.len == 0) return;
    try w.writeAll("\n\n# Project Context\n\n");
    try w.writeAll("Project-specific instructions and guidelines:\n\n");
    for (files) |f| {
        try w.print("## {s}\n\n{s}\n\n", .{ f.path, f.content });
    }
}

fn expectOrderedSubstrings(haystack: []const u8, needles: []const []const u8) !void {
    var previous_index: usize = 0;
    var have_previous = false;
    for (needles) |needle| {
        const index = std.mem.indexOf(u8, haystack, needle) orelse return error.MissingSubstring;
        if (have_previous) {
            try std.testing.expect(previous_index < index);
        }
        previous_index = index;
        have_previous = true;
    }
}

test "default prompt includes zi identity help and cwd" {
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .cwd = "/home/user/project",
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "operating inside zi, a coding agent harness") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Zi documentation (read only when the user asks about zi itself") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "`settings`, `resources`, `skills`, `prompts`, `themes`, `agent-context`") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "docs/README.md") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Current working directory: /home/user/project") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Be concise in your responses") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Available tools:") != null);
}

test "custom prompt orders append context skills and footer like pi-mono" {
    const files = [_]ContextFile{.{ .path = "AGENTS.md", .content = "be nice" }};
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .custom_prompt = "You are a pirate.",
        .append_system_prompt = &.{"appended guidance"},
        .context_files = &files,
        .skills_section = "\n\n<available_skills>\n  <skill><name>caveman</name></skill>\n</available_skills>",
        .cwd = "/tmp",
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "You are a pirate.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "operating inside zi") == null);
    try expectOrderedSubstrings(result, &.{
        "You are a pirate.",
        "appended guidance",
        "# Project Context",
        "<available_skills>",
        "Current date:",
        "Current working directory: /tmp",
    });
}

test "default prompt falls back to pi-mono default tool set" {
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .tool_snippets = &.{
            .{ .name = "read", .snippet = "Read files" },
            .{ .name = "bash", .snippet = "Run commands" },
            .{ .name = "grep", .snippet = "Search files" },
        },
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "- read: Read files") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "- bash: Run commands") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "- grep: Search files") == null);
}

test "tool guidelines adapt to available tools" {
    const bash_only = try buildSystemPrompt(std.testing.allocator, .{
        .tool_names = &.{"bash"},
    });
    defer std.testing.allocator.free(bash_only);
    try std.testing.expect(std.mem.indexOf(u8, bash_only, "Use bash for file operations") != null);

    const bash_grep = try buildSystemPrompt(std.testing.allocator, .{
        .tool_names = &.{ "bash", "grep" },
    });
    defer std.testing.allocator.free(bash_grep);
    try std.testing.expect(std.mem.indexOf(u8, bash_grep, "Prefer grep/find/ls tools over bash") != null);
}

test "default prompt orders zi help append context and read-gated skills" {
    const files = [_]ContextFile{
        .{ .path = "/proj/AGENTS.md", .content = "rule 1" },
        .{ .path = "/proj/docs/STYLE.md", .content = "rule 2" },
    };
    const with_read = try buildSystemPrompt(std.testing.allocator, .{
        .append_system_prompt = &.{"appended guidance"},
        .context_files = &files,
        .skills_section = "\n\n<available_skills>\n  <skill><name>caveman</name></skill>\n</available_skills>",
    });
    defer std.testing.allocator.free(with_read);

    try expectOrderedSubstrings(with_read, &.{
        "Zi documentation (read only when the user asks about zi itself",
        "appended guidance",
        "# Project Context",
        "<available_skills>",
        "Current date:",
    });

    const without_read = try buildSystemPrompt(std.testing.allocator, .{
        .tool_names = &.{"bash"},
        .skills_section = "\n\n<available_skills>\n  <skill><name>caveman</name></skill>\n</available_skills>",
    });
    defer std.testing.allocator.free(without_read);

    try std.testing.expect(std.mem.indexOf(u8, without_read, "<available_skills>") == null);
}
