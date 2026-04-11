const std = @import("std");
const resource_types = @import("resources/types.zig");

pub const ContextFile = resource_types.AgentsFile;

pub const ToolSnippet = struct {
    name: []const u8,
    snippet: []const u8,
};

pub const Options = struct {
    /// Loader-resolved custom system prompt, if present.
    custom_prompt: ?[]const u8 = null,
    tool_names: []const []const u8 = &.{},
    tool_snippets: []const ToolSnippet = &.{},
    guidelines: []const []const u8 = &.{},
    /// Pre-formatted skills section, built from loader-owned skills.
    skills_section: ?[]const u8 = null,
    /// Loader-resolved append-system-prompt content.
    append_system_prompt: []const []const u8 = &.{},
    cwd: []const u8 = ".",
    /// Loader-resolved AGENTS/CLAUDE-style project context files.
    context_files: []const ContextFile = &.{},
};

fn containsStr(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| {
        if (std.mem.eql(u8, item, needle)) return true;
    }
    return false;
}

/// Normalize cwd: backslash → forward slash (pi-mono system-prompt.ts:40)
fn normalizeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, cwd);
    for (result) |*c| {
        if (c.* == '\\') c.* = '/';
    }
    return result;
}

/// Build the system prompt matching pi-mono's system-prompt.ts:28-168.
///
/// This is a pure builder over already-resolved inputs. Discovery/loading of
/// custom prompts, append prompts, and AGENTS/CLAUDE context files belongs to
/// `src/resources/loader.zig`, not to prompt-building callsites.
///
/// If `custom_prompt` is set, it replaces the default identity/tools/guidelines
/// section but still appends context files, date, and cwd.
/// Otherwise builds the full default prompt with identity, tools, guidelines,
/// context, date, and cwd.
pub fn buildSystemPrompt(allocator: std.mem.Allocator, options: Options) ![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    const w = &aw.writer;

    const date = try isoDate(allocator);
    defer allocator.free(date);

    const cwd = try normalizeCwd(allocator, options.cwd);
    defer allocator.free(cwd);

    if (options.custom_prompt) |custom| {
        try w.writeAll(custom);
        try writeSkillsSection(w, options.skills_section);
        try writeAppendSystemPrompt(w, options.append_system_prompt);
        try writeContextFiles(w, options.context_files);
        try w.print("\nCurrent date: {s}", .{date});
        try w.print("\nCurrent working directory: {s}", .{cwd});
        return try aw.toOwnedSlice();
    }

    // Default prompt: identity
    try w.writeAll(
        "You are an expert coding assistant operating inside zi, a coding agent." ++
            " You help users by reading files, executing commands, editing code, and writing new files.",
    );

    // Available tools section — only show tools that have snippets
    try w.writeAll("\n\nAvailable tools:\n");
    var visible_count: usize = 0;
    for (options.tool_names) |name| {
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

    // Guidelines — deduplicated
    try w.writeAll("\nGuidelines:\n");

    var guideline_list: std.ArrayList([]const u8) = .empty;
    defer guideline_list.deinit(allocator);

    const has_bash = containsStr(options.tool_names, "bash");
    const has_grep = containsStr(options.tool_names, "grep");
    const has_find = containsStr(options.tool_names, "find");
    const has_ls = containsStr(options.tool_names, "ls");

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

    try writeSkillsSection(w, options.skills_section);
    try writeAppendSystemPrompt(w, options.append_system_prompt);

    try writeContextFiles(w, options.context_files);

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

/// YYYY-MM-DD from wall-clock time.
fn isoDate(allocator: std.mem.Allocator) ![]const u8 {
    const ts = std.time.timestamp();
    const epoch_secs: std.time.epoch.EpochSeconds = .{ .secs = @intCast(ts) };
    const year_day = epoch_secs.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{
        year_day.year,
        @intFromEnum(month_day.month),
        month_day.day_index + 1,
    });
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "default prompt includes identity and cwd" {
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .cwd = "/home/user/project",
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "expert coding assistant") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Current working directory: /home/user/project") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Be concise") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Available tools:") != null);
}

test "custom prompt replaces default but keeps context" {
    const files = [_]ContextFile{.{ .path = "AGENTS.md", .content = "be nice" }};
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .custom_prompt = "You are a pirate.",
        .context_files = &files,
        .cwd = "/tmp",
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "You are a pirate.") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "expert coding assistant") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "be nice") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Current working directory: /tmp") != null);
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

test "skills section is appended when provided" {
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .skills_section = "\n\n<available_skills>\n  <skill><name>caveman</name></skill>\n</available_skills>",
    });
    defer std.testing.allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "<available_skills>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "caveman") != null);
}

test "context files appended in default prompt" {
    const files = [_]ContextFile{
        .{ .path = "/proj/AGENTS.md", .content = "rule 1" },
        .{ .path = "/proj/docs/STYLE.md", .content = "rule 2" },
    };
    const result = try buildSystemPrompt(std.testing.allocator, .{
        .context_files = &files,
    });
    defer std.testing.allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "# Project Context") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "## /proj/AGENTS.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rule 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "## /proj/docs/STYLE.md") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "rule 2") != null);
}
