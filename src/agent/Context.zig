const std = @import("std");

pub const max_prompt_bytes: usize = 8 * 1024 * 1024;
pub const max_guidance_files: usize = 65;
pub const max_skills: usize = 4096;
pub const max_presets: usize = 1024;

pub const BuildError = error{
    OutOfMemory,
    PromptTooLarge,
    TooManyGuidanceFiles,
    TooManySkills,
    TooManyPresets,
};

pub const Features = struct {
    tasks: bool = true,
    subagents: bool = true,
    environment: bool = true,
    project: bool = true,
    skills: bool = true,
};

pub const ToolFacts = struct {
    rg: bool = false,
    fd: bool = false,
    jq: bool = false,
    gh: bool = false,
    python3: bool = false,
    node: bool = false,
    magick: bool = false,
};

pub const ProjectRoot = union(enum) {
    discover,
    missing,
    found: []const u8,
};

pub const EnvironmentFacts = struct {
    working_directory: []const u8,
    home_directory: ?[]const u8 = null,
    operating_system: []const u8,
    command_shell: []const u8,
    model: ?[]const u8 = null,
    git_repository_root: ?[]const u8 = null,
    tools: ToolFacts = .{},
};

pub const GuidanceKind = enum { global, project };

/// Content and display_path are already collected and sanitized facts.
/// `content` is the retained (possibly capped) file content.
pub const GuidanceFile = struct {
    kind: GuidanceKind,
    display_path: []const u8,
    content: []const u8,
    truncated: bool = false,
};

/// The first occurrence of a name wins before the result is sorted by name.
/// Pass project skills before global skills to preserve hax shadowing.
pub const Skill = struct {
    name: []const u8,
    display_path: []const u8,
    description: ?[]const u8 = null,
};

/// Presets reaching this renderer have already passed provider validation.
pub const Preset = struct {
    name: []const u8,
    description: []const u8,
};

pub const Facts = struct {
    features: Features = .{},
    environment: ?EnvironmentFacts = null,
    guidance_files: []const GuidanceFile = &.{},
    skills: []const Skill = &.{},
    presets: []const Preset = &.{},
};

/// Allocator-owned, move-only context prompt. Call `deinit` exactly once.
pub const OwnedPrompt = struct {
    bytes: []u8,

    pub fn deinit(self: *OwnedPrompt, allocator: std.mem.Allocator) void {
        allocator.free(self.bytes);
        self.* = undefined;
    }
};

const tasks_prompt =
    "# Background tasks\n" ++
    "\n" ++
    "A bash command that outlives its timeout, or is launched with `background: true`, " ++
    "continues as a background task. Wait on the task whose result you need next with " ++
    "task_wait — it returns that task's output and status. Completions of other tasks are " ++
    "announced automatically as one-line notes (with the pending output size); collect an " ++
    "announced task with task_wait when you want its output. Stop a task with task_wait's " ++
    "`kill` flag, which also returns its final output. Never pass time with sleep or a " ++
    "polling loop; give task_wait a timeout instead. " ++
    "Tasks do not survive the Zi process: in a one-shot (-p) run, tasks nobody waited on are " ++
    "killed once the final answer is produced. The user manages tasks with /tasks.\n";

const subagents_prompt =
    "# Subagents\n" ++
    "\n" ++
    "`zi -p \"<task>\"` (via the bash tool) runs a fresh Zi instance with clean context in " ++
    "this directory and prints its final answer to stdout. Delegate to subagents only when " ++
    "the user asks for it. The child inherits this session's provider, model, and effort. " ++
    "Launch each subagent with `background: true` and collect answers with task_wait — that " ++
    "is also how several run in parallel. The child prints its session id to stderr at " ++
    "startup (captured in the task log); follow up on a finished (or killed) run with " ++
    "`zi --resume=<id> -p \"<follow-up>\"`.\n";

const subagents_prompt_no_tasks =
    "# Subagents\n" ++
    "\n" ++
    "`zi -p \"<task>\"` (via the bash tool) runs a fresh Zi instance with clean context in " ++
    "this directory and prints its final answer to stdout. Delegate to subagents only when " ++
    "the user asks for it. The child inherits this session's provider, model, and effort. " ++
    "Subagents are slow: pass a generous timeout_seconds (e.g. 1800). The child prints its " ++
    "session id to stderr at startup; follow up on a finished (or timed-out) run with " ++
    "`zi --resume=<id> -p \"<follow-up>\"`.\n";

const Builder = struct {
    allocator: std.mem.Allocator,
    output: std.ArrayList(u8) = .empty,

    fn deinit(self: *Builder) void {
        self.output.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(self: *Builder, bytes: []const u8) BuildError!void {
        const remaining = max_prompt_bytes - self.output.items.len;
        if (bytes.len > remaining) return error.PromptTooLarge;
        try self.output.appendSlice(self.allocator, bytes);
    }

    fn section(self: *Builder) BuildError!void {
        if (self.output.items.len != 0) try self.append("\n");
    }
    /// Appends one model-facing scalar without allowing it to create prompt
    /// structure or carry ASCII control sequences.
    fn inlineValue(self: *Builder, bytes: []const u8) BuildError!void {
        const hex = "0123456789abcdef";
        for (bytes) |byte| switch (byte) {
            '\n' => try self.append("\\n"),
            '\r' => try self.append("\\r"),
            '\t' => try self.append("\\t"),
            0...8, 11, 12, 14...31, 127 => {
                const escaped = [_]u8{ '\\', 'x', hex[byte >> 4], hex[byte & 0x0f] };
                try self.append(&escaped);
            },
            else => try self.append(&.{byte}),
        };
    }

    fn finish(self: *Builder) BuildError!?OwnedPrompt {
        if (self.output.items.len == 0) return null;
        return .{ .bytes = try self.output.toOwnedSlice(self.allocator) };
    }
};

const NamedTool = struct {
    name: []const u8,
    replacement: ?[]const u8,
    available: bool,
};

fn appendEnvironment(builder: *Builder, facts: EnvironmentFacts) BuildError!void {
    try builder.section();
    try builder.append("# Environment\n\n- Working directory: ");
    try builder.inlineValue(facts.working_directory);
    try builder.append("\n");
    if (facts.home_directory) |home| {
        if (home.len != 0) {
            try builder.append("- Home directory: ");
            try builder.inlineValue(home);
            try builder.append("\n");
        }
    }
    try builder.append("- Operating system: ");
    try builder.inlineValue(facts.operating_system);
    try builder.append("\n- Command shell: ");
    try builder.inlineValue(facts.command_shell);
    try builder.append("\n");
    if (facts.model) |model| {
        if (model.len != 0) {
            try builder.append("- Model: ");
            try builder.inlineValue(model);
            try builder.append("\n");
        }
    }
    if (facts.git_repository_root) |root| {
        try builder.append("- Git repository root: ");
        try builder.inlineValue(root);
        try builder.append("\n");
    } else {
        try builder.append("- Git repository: no\n");
    }

    const tools = [_]NamedTool{
        .{ .name = "rg", .replacement = "grep -r", .available = facts.tools.rg },
        .{ .name = "fd", .replacement = "find", .available = facts.tools.fd },
        .{ .name = "jq", .replacement = null, .available = facts.tools.jq },
        .{ .name = "gh", .replacement = null, .available = facts.tools.gh },
        .{ .name = "python3", .replacement = "python", .available = facts.tools.python3 },
        .{ .name = "node", .replacement = null, .available = facts.tools.node },
        .{ .name = "magick", .replacement = null, .available = facts.tools.magick },
    };
    var any = false;
    for (tools) |tool| {
        if (!tool.available) continue;
        try builder.append(if (any) ", `" else "\nAvailable command-line tools: `");
        try builder.append(tool.name);
        try builder.append("`");
        any = true;
    }
    if (any) try builder.append(".\n");

    any = false;
    for (tools) |tool| {
        const replacement = tool.replacement orelse continue;
        if (!tool.available) continue;
        try builder.append(if (any) ", `" else "Prefer `");
        try builder.append(tool.name);
        try builder.append("` to `");
        try builder.append(replacement);
        try builder.append("`");
        any = true;
    }
    if (any) try builder.append(".\n");
}

fn appendGuidanceFile(builder: *Builder, file: GuidanceFile) BuildError!void {
    try builder.append("\n## ");
    try builder.inlineValue(file.display_path);
    try builder.append("\n\n");
    try builder.append(file.content);
    if (file.content.len == 0 or file.content[file.content.len - 1] != '\n') {
        try builder.append("\n");
    }
    if (file.truncated) try builder.append("[truncated]\n");
}

fn appendGuidance(builder: *Builder, files: []const GuidanceFile) BuildError!void {
    if (files.len == 0) return;
    try builder.section();
    try builder.append(
        "# Project Context\n\n" ++
            "Project guidance below overrides the assistant defaults above.\n",
    );
    inline for ([_]GuidanceKind{ .global, .project }) |kind| {
        for (files) |file| {
            if (file.kind == kind) try appendGuidanceFile(builder, file);
        }
    }
}

const IndexedSkill = struct { value: Skill, index: usize };
const IndexedPreset = struct { value: Preset, index: usize };

fn lessSkill(_: void, a: IndexedSkill, b: IndexedSkill) bool {
    const order = std.mem.order(u8, a.value.name, b.value.name);
    return if (order == .eq) a.index < b.index else order == .lt;
}

fn lessPreset(_: void, a: IndexedPreset, b: IndexedPreset) bool {
    const order = std.mem.order(u8, a.value.name, b.value.name);
    return if (order == .eq) a.index < b.index else order == .lt;
}

fn appendSkills(builder: *Builder, allocator: std.mem.Allocator, skills: []const Skill) BuildError!void {
    if (skills.len == 0) return;
    var sorted = try std.ArrayList(IndexedSkill).initCapacity(allocator, skills.len);
    defer sorted.deinit(allocator);
    for (skills, 0..) |skill, index| sorted.appendAssumeCapacity(.{ .value = skill, .index = index });
    std.mem.sort(IndexedSkill, sorted.items, {}, lessSkill);

    var emitted = false;
    var previous_name: ?[]const u8 = null;
    for (sorted.items) |entry| {
        if (previous_name) |name| {
            if (std.mem.eql(u8, name, entry.value.name)) continue;
        }
        previous_name = entry.value.name;
        if (!emitted) {
            try builder.section();
            try builder.append(
                "# Skills\n\n" ++
                    "Read the corresponding SKILL.md when a task matches the description:\n\n",
            );
            emitted = true;
        }
        try builder.append("- ");
        try builder.inlineValue(entry.value.name);
        if (entry.value.description) |description| {
            try builder.append(": ");
            try builder.inlineValue(description);
        }
        try builder.append(" (");
        try builder.inlineValue(entry.value.display_path);
        try builder.append(")\n");
    }
}

fn appendPresets(builder: *Builder, allocator: std.mem.Allocator, presets: []const Preset) BuildError!void {
    var usable: usize = 0;
    for (presets) |preset| {
        if (preset.description.len != 0) usable += 1;
    }
    if (usable == 0) return;
    var sorted = try std.ArrayList(IndexedPreset).initCapacity(allocator, presets.len);
    defer sorted.deinit(allocator);
    for (presets, 0..) |preset, index| {
        if (preset.description.len != 0) sorted.appendAssumeCapacity(.{ .value = preset, .index = index });
    }
    std.mem.sort(IndexedPreset, sorted.items, {}, lessPreset);
    try builder.append("\nPresets (select with `--preset <name>`):\n");
    var previous_name: ?[]const u8 = null;
    for (sorted.items) |entry| {
        if (previous_name) |name| {
            if (std.mem.eql(u8, name, entry.value.name)) continue;
        }
        previous_name = entry.value.name;
        try builder.append("- ");
        try builder.inlineValue(entry.value.name);
        try builder.append(": ");
        try builder.inlineValue(entry.value.description);
        try builder.append("\n");
    }
}

/// Renders only the supplied facts. It performs no discovery, configuration access, or I/O.
/// Every byte in a non-null result is independently owned by the caller.
pub fn build(allocator: std.mem.Allocator, facts: Facts) BuildError!?OwnedPrompt {
    if (facts.guidance_files.len > max_guidance_files) return error.TooManyGuidanceFiles;
    if (facts.skills.len > max_skills) return error.TooManySkills;
    if (facts.presets.len > max_presets) return error.TooManyPresets;

    var builder: Builder = .{ .allocator = allocator };
    defer builder.deinit();

    if (facts.features.tasks) try builder.append(tasks_prompt);
    if (facts.features.subagents) {
        try builder.section();
        try builder.append(if (facts.features.tasks) subagents_prompt else subagents_prompt_no_tasks);
        try appendPresets(&builder, allocator, facts.presets);
    }
    if (facts.features.environment) {
        if (facts.environment) |environment| try appendEnvironment(&builder, environment);
    }
    if (facts.features.project) try appendGuidance(&builder, facts.guidance_files);
    if (facts.features.skills) try appendSkills(&builder, allocator, facts.skills);

    return builder.finish();
}

fn expectPrompt(facts: Facts, expected: ?[]const u8) !void {
    var prompt = try build(std.testing.allocator, facts);
    defer if (prompt) |*owned| owned.deinit(std.testing.allocator);
    if (expected) |text| {
        try std.testing.expectEqualStrings(text, prompt.?.bytes);
    } else {
        try std.testing.expect(prompt == null);
    }
}

test "all disabled or absent facts returns null" {
    try expectPrompt(.{ .features = .{
        .tasks = false,
        .subagents = false,
        .environment = false,
        .project = false,
        .skills = false,
    } }, null);
}

test "environment golden preserves fact and command preference order" {
    try expectPrompt(.{
        .features = .{ .tasks = false, .subagents = false, .project = false, .skills = false },
        .environment = .{
            .working_directory = "~/src",
            .home_directory = "/home/me",
            .operating_system = "Linux",
            .command_shell = "/bin/sh",
            .model = "m",
            .git_repository_root = "~",
            .tools = .{ .rg = true, .fd = true, .jq = true, .python3 = true, .node = true },
        },
    }, "# Environment\n\n" ++
        "- Working directory: ~/src\n" ++
        "- Home directory: /home/me\n" ++
        "- Operating system: Linux\n" ++
        "- Command shell: /bin/sh\n" ++
        "- Model: m\n" ++
        "- Git repository root: ~\n" ++
        "\nAvailable command-line tools: `rg`, `fd`, `jq`, `python3`, `node`.\n" ++
        "Prefer `rg` to `grep -r`, `fd` to `find`, `python3` to `python`.\n");
}

test "environment omits optional empty facts and reports no repository" {
    try expectPrompt(.{
        .features = .{ .tasks = false, .subagents = false, .project = false, .skills = false },
        .environment = .{
            .working_directory = "/tmp",
            .home_directory = "",
            .operating_system = "Test OS",
            .command_shell = "sh",
            .model = "",
        },
    }, "# Environment\n\n- Working directory: /tmp\n" ++
        "- Operating system: Test OS\n- Command shell: sh\n- Git repository: no\n");
}

test "guidance golden is global then project with exact newlines and marker" {
    const files = [_]GuidanceFile{
        .{ .kind = .project, .display_path = "~/p/a/AGENTS.md", .content = "inner" },
        .{ .kind = .global, .display_path = "~/.config/zi/AGENTS.md", .content = "global\n" },
        .{ .kind = .project, .display_path = "~/p/AGENTS.md", .content = "", .truncated = true },
    };
    try expectPrompt(.{
        .features = .{ .tasks = false, .subagents = false, .environment = false, .skills = false },
        .guidance_files = &files,
    }, "# Project Context\n\nProject guidance below overrides the assistant defaults above.\n" ++
        "\n## ~/.config/zi/AGENTS.md\n\nglobal\n" ++
        "\n## ~/p/a/AGENTS.md\n\ninner\n" ++
        "\n## ~/p/AGENTS.md\n\n\n[truncated]\n");
}

test "skills sort and first duplicate shadows later metadata" {
    const skills = [_]Skill{
        .{ .name = "zeta", .display_path = "/p/z/SKILL.md" },
        .{ .name = "alpha", .display_path = "/project/a/SKILL.md", .description = "project" },
        .{ .name = "alpha", .display_path = "/global/a/SKILL.md", .description = "global" },
    };
    try expectPrompt(.{
        .features = .{ .tasks = false, .subagents = false, .environment = false, .project = false },
        .skills = &skills,
    }, "# Skills\n\nRead the corresponding SKILL.md when a task matches the description:\n\n" ++
        "- alpha: project (/project/a/SKILL.md)\n- zeta (/p/z/SKILL.md)\n");
}

test "tasks subagents no-tasks variant presets and section order" {
    const presets = [_]Preset{
        .{ .name = "review", .description = "code review stance" },
        .{ .name = "alpha", .description = "quick answers" },
        .{ .name = "favorite", .description = "" },
    };
    var prompt = (try build(std.testing.allocator, .{
        .features = .{ .environment = false, .project = false, .skills = false },
        .presets = &presets,
    })).?;
    defer prompt.deinit(std.testing.allocator);
    const tasks = std.mem.indexOf(u8, prompt.bytes, "# Background tasks").?;
    const subagents = std.mem.indexOf(u8, prompt.bytes, "# Subagents").?;
    try std.testing.expect(tasks < subagents);
    try std.testing.expect(std.mem.indexOf(
        u8,
        prompt.bytes,
        "Presets (select with `--preset <name>`):\n" ++
            "- alpha: quick answers\n- review: code review stance\n",
    ) != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "timeout_seconds") == null);

    var no_tasks = (try build(std.testing.allocator, .{
        .features = .{ .tasks = false, .environment = false, .project = false, .skills = false },
    })).?;
    defer no_tasks.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, no_tasks.bytes, "# Background tasks") == null);
    try std.testing.expect(std.mem.indexOf(u8, no_tasks.bytes, "timeout_seconds (e.g. 1800)") != null);
    try std.testing.expect(std.mem.indexOf(u8, no_tasks.bytes, "task_wait") == null);
}

test "full golden section separators are exactly one blank line" {
    const guidance = [_]GuidanceFile{.{
        .kind = .project,
        .display_path = "/p/AGENTS.md",
        .content = "rules\n",
    }};
    const skills = [_]Skill{.{ .name = "one", .display_path = "/s/SKILL.md" }};
    var prompt = (try build(std.testing.allocator, .{
        .environment = .{
            .working_directory = "/p",
            .operating_system = "OS",
            .command_shell = "sh",
        },
        .guidance_files = &guidance,
        .skills = &skills,
    })).?;
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "\n\n# Subagents\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "\n\n# Environment\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "\n\n# Project Context\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "\n\n# Skills\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "\n\n\n#") == null);
}

test "result owns copies of every mutable input" {
    var cwd = [_]u8{ '/', 'c' };
    var path = [_]u8{ '/', 'g' };
    var content = [_]u8{ 'r', 'u', 'l', 'e' };
    var name = [_]u8{'s'};
    var skill_path = [_]u8{ '/', 's' };
    var description = [_]u8{'d'};
    const guidance = [_]GuidanceFile{.{
        .kind = .project,
        .display_path = &path,
        .content = &content,
    }};
    const skills = [_]Skill{.{
        .name = &name,
        .display_path = &skill_path,
        .description = &description,
    }};
    var prompt = (try build(std.testing.allocator, .{
        .features = .{ .tasks = false, .subagents = false },
        .environment = .{ .working_directory = &cwd, .operating_system = "o", .command_shell = "s" },
        .guidance_files = &guidance,
        .skills = &skills,
    })).?;
    defer prompt.deinit(std.testing.allocator);
    @memset(&cwd, 'x');
    @memset(&path, 'x');
    @memset(&content, 'x');
    @memset(&name, 'x');
    @memset(&skill_path, 'x');
    @memset(&description, 'x');
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "- Working directory: /c\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "## /g\n\nrule\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "- s: d (/s)\n") != null);
}

test "aggregate and metadata bounds fail without allocation" {
    const too_large = [_]u8{'x'} ** (max_prompt_bytes + 1);
    try std.testing.expectError(error.PromptTooLarge, build(std.testing.allocator, .{
        .features = .{ .tasks = false, .subagents = false, .project = false, .skills = false },
        .environment = .{
            .working_directory = &too_large,
            .operating_system = "o",
            .command_shell = "s",
        },
    }));

    const files = [_]GuidanceFile{.{
        .kind = .project,
        .display_path = "p",
        .content = "c",
    }} ** (max_guidance_files + 1);
    try std.testing.expectError(error.TooManyGuidanceFiles, build(std.testing.allocator, .{
        .guidance_files = &files,
    }));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    const guidance = [_]GuidanceFile{.{
        .kind = .project,
        .display_path = "/p/AGENTS.md",
        .content = "rules",
        .truncated = true,
    }};
    const skills = [_]Skill{
        .{ .name = "b", .display_path = "/b", .description = "B" },
        .{ .name = "a", .display_path = "/a", .description = "A" },
    };
    const presets = [_]Preset{.{ .name = "review", .description = "review" }};
    var prompt = try build(allocator, .{
        .environment = .{
            .working_directory = "/p",
            .home_directory = "/home/me",
            .operating_system = "OS",
            .command_shell = "sh",
            .model = "model",
            .tools = .{ .rg = true },
        },
        .guidance_files = &guidance,
        .skills = &skills,
        .presets = &presets,
    });
    defer if (prompt) |*owned| owned.deinit(allocator);
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "inline facts cannot forge prompt structure with ASCII controls" {
    const skills = [_]Skill{.{
        .name = "bad\n# Forged",
        .description = "desc\r\t\x1b",
        .display_path = "/tmp/x\nSKILL.md",
    }};
    var prompt = (try build(std.testing.allocator, .{
        .features = .{ .tasks = false, .subagents = false, .project = false },
        .environment = .{
            .working_directory = "/tmp/x\n# Instructions",
            .operating_system = "os\rname",
            .command_shell = "sh\x1b",
        },
        .skills = &skills,
    })).?;
    defer prompt.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "x\\n# Instructions") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt.bytes, "bad\\n# Forged") != null);
    try std.testing.expect(std.mem.indexOfScalar(u8, prompt.bytes, 0x1b) == null);
}
