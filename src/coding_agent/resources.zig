const std = @import("std");
const paths_mod = @import("paths.zig");
const skills_mod = @import("skills.zig");

pub const max_context_files = 64;
pub const max_context_file_bytes = 256 * 1024;
pub const max_system_prompt_file_bytes = 256 * 1024;
pub const max_ancestor_depth = 128;

pub const ContextFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const PromptFile = struct {
    path: []const u8,
    content: []const u8,
};

const LoadedPromptFile = struct {
    allocator: std.mem.Allocator,
    file: ?PromptFile,

    pub fn deinit(self: *LoadedPromptFile) void {
        if (self.file) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.content);
        }
        self.* = undefined;
    }
};

pub const LoadedContextFiles = struct {
    allocator: std.mem.Allocator,
    files: []const ContextFile,

    pub fn deinit(self: *LoadedContextFiles) void {
        for (self.files) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.content);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

const LoadProjectContextOptions = struct {
    dir: std.Io.Dir = .cwd(),
    agent_dir: []const u8,
    cwd: []const u8,
};

const DiscoverPromptFileOptions = struct {
    dir: std.Io.Dir = .cwd(),
    agent_dir: []const u8,
    cwd: []const u8,
};

pub const PromptResources = struct {
    context_files: LoadedContextFiles,
    system_prompt: LoadedPromptFile,
    append_system_prompt: LoadedPromptFile,
    skills: skills_mod.SkillSet,

    pub const LoadOptions = struct {
        dir: std.Io.Dir = .cwd(),
        agent_dir: []const u8,
        cwd: []const u8,
    };

    pub fn load(allocator: std.mem.Allocator, io: std.Io, options: LoadOptions) !PromptResources {
        var context_files = try loadProjectContextFiles(allocator, io, .{
            .dir = options.dir,
            .agent_dir = options.agent_dir,
            .cwd = options.cwd,
        });
        errdefer context_files.deinit();

        var system_prompt = try discoverSystemPromptFile(allocator, io, .{
            .dir = options.dir,
            .agent_dir = options.agent_dir,
            .cwd = options.cwd,
        });
        errdefer system_prompt.deinit();

        var append_system_prompt = try discoverAppendSystemPromptFile(allocator, io, .{
            .dir = options.dir,
            .agent_dir = options.agent_dir,
            .cwd = options.cwd,
        });
        errdefer append_system_prompt.deinit();

        var loaded_skills = try skills_mod.loadSkills(allocator, io, .{
            .dir = options.dir,
            .agent_dir = options.agent_dir,
            .cwd = options.cwd,
        });
        errdefer loaded_skills.deinit();

        return .{
            .context_files = context_files,
            .system_prompt = system_prompt,
            .append_system_prompt = append_system_prompt,
            .skills = loaded_skills,
        };
    }

    pub fn deinit(self: *PromptResources) void {
        self.context_files.deinit();
        self.system_prompt.deinit();
        self.append_system_prompt.deinit();
        self.skills.deinit();
        self.* = undefined;
    }
};

fn discoverSystemPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
) !LoadedPromptFile {
    return discoverPromptFile(allocator, io, options, paths_mod.system_prompt_file_name);
}

fn discoverAppendSystemPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
) !LoadedPromptFile {
    return discoverPromptFile(allocator, io, options, paths_mod.append_system_prompt_file_name);
}

fn discoverPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
    file_name: []const u8,
) !LoadedPromptFile {
    const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = options.agent_dir, .cwd = options.cwd };
    const project_dir = try resource_paths.projectConfigDir(allocator);
    defer allocator.free(project_dir);
    if (try loadPromptFileFromDir(allocator, io, options.dir, project_dir, file_name)) |file| {
        return .{ .allocator = allocator, .file = file };
    }
    if (try loadPromptFileFromDir(allocator, io, options.dir, options.agent_dir, file_name)) |file| {
        return .{ .allocator = allocator, .file = file };
    }
    return .{ .allocator = allocator, .file = null };
}

fn loadProjectContextFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadProjectContextOptions,
) !LoadedContextFiles {
    var files = std.ArrayList(ContextFile).empty;
    errdefer {
        deinitContextFileItems(allocator, files.items);
        files.deinit(allocator);
    }

    if (try loadContextFileFromDir(allocator, io, options.dir, options.agent_dir)) |global| {
        try appendContextFile(allocator, &files, global);
    }

    // Collect ancestor dirs cwd -> root (bounded slices of cwd, no copies),
    // then load root -> cwd so context closer to the cwd appears later.
    var ancestors: [max_ancestor_depth][]const u8 = undefined;
    var depth: usize = 0;
    var current_dir = options.cwd;
    while (true) {
        if (depth == max_ancestor_depth) return error.AncestorLimitExceeded;
        ancestors[depth] = current_dir;
        depth += 1;
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;
        current_dir = parent;
    }
    while (depth > 0) {
        depth -= 1;
        const context_file = (try loadContextFileFromDir(allocator, io, options.dir, ancestors[depth])) orelse
            continue;
        if (containsPath(files.items, context_file.path)) {
            deinitContextFile(allocator, context_file);
            continue;
        }
        try appendContextFile(allocator, &files, context_file);
    }

    return .{ .allocator = allocator, .files = try files.toOwnedSlice(allocator) };
}

fn appendContextFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayList(ContextFile),
    context_file: ContextFile,
) !void {
    if (files.items.len == max_context_files) return error.ContextFileLimitExceeded;
    try files.append(allocator, context_file);
}

fn loadPromptFileFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    search_dir: []const u8,
    file_name: []const u8,
) !?PromptFile {
    const path = try std.fs.path.join(allocator, &.{ search_dir, file_name });
    errdefer allocator.free(path);
    const content = dir.readFileAlloc(
        io,
        path,
        allocator,
        .limited(max_system_prompt_file_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => {
            allocator.free(path);
            return null;
        },
        else => return err,
    };
    return .{ .path = path, .content = content };
}

fn loadContextFileFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    search_dir: []const u8,
) !?ContextFile {
    const candidates = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
    for (candidates) |candidate| {
        const path = try std.fs.path.join(allocator, &.{ search_dir, candidate });
        errdefer allocator.free(path);
        const content = dir.readFileAlloc(
            io,
            path,
            allocator,
            .limited(max_context_file_bytes),
        ) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            error.AccessDenied, error.PermissionDenied, error.IsDir => {
                allocator.free(path);
                continue;
            },
            else => return err,
        };
        return .{ .path = path, .content = content };
    }
    return null;
}

fn containsPath(files: []const ContextFile, path: []const u8) bool {
    for (files) |file| {
        if (std.mem.eql(u8, file.path, path)) return true;
    }
    return false;
}

fn deinitContextFileItems(allocator: std.mem.Allocator, files: []const ContextFile) void {
    for (files) |file| deinitContextFile(allocator, file);
}

fn deinitContextFile(allocator: std.mem.Allocator, file: ContextFile) void {
    allocator.free(file.path);
    allocator.free(file.content);
}

test "prompt resources load context and prompt overrides" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/AGENTS.md", .data = "repo" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/SYSTEM.md", .data = "system" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/APPEND_SYSTEM.md", .data = "append" });

    var prompt_resources = try PromptResources.load(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer prompt_resources.deinit();

    try std.testing.expectEqual(@as(usize, 2), prompt_resources.context_files.files.len);
    try std.testing.expectEqual(@as(usize, 0), prompt_resources.skills.skills.len);
    try std.testing.expectEqualStrings("system", prompt_resources.system_prompt.file.?.content);
    try std.testing.expectEqualStrings("append", prompt_resources.append_system_prompt.file.?.content);
}

test "prompt resources returns null prompts when files are missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var prompt_resources = try PromptResources.load(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer prompt_resources.deinit();

    try std.testing.expectEqual(@as(usize, 0), prompt_resources.context_files.files.len);
    try std.testing.expect(prompt_resources.system_prompt.file == null);
    try std.testing.expect(prompt_resources.append_system_prompt.file == null);
}

test "system prompt discovery rejects directory at prompt path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/.zi/SYSTEM.md");

    try std.testing.expectError(error.IsDir, discoverSystemPromptFile(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "missing",
        .cwd = "repo",
    }));
}

test "discovers project system prompt before global" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/SYSTEM.md", .data = "global" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/.zi/SYSTEM.md", .data = "project" });

    var file = try discoverSystemPromptFile(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer file.deinit();

    try std.testing.expect(file.file != null);
    try std.testing.expectEqualStrings("repo/.zi/SYSTEM.md", file.file.?.path);
    try std.testing.expectEqualStrings("project", file.file.?.content);
}

test "discovers global append system prompt when project prompt is missing" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/APPEND_SYSTEM.md", .data = "append" });

    var file = try discoverAppendSystemPromptFile(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer file.deinit();

    try std.testing.expect(file.file != null);
    try std.testing.expectEqualStrings("agent/APPEND_SYSTEM.md", file.file.?.path);
    try std.testing.expectEqualStrings("append", file.file.?.content);
}

test "loads global then ancestor context files root to cwd" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent");
    try tmp.dir.createDirPath(std.testing.io, "repo/app");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "agent/AGENTS.md", .data = "global" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/AGENTS.md", .data = "repo" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/app/CLAUDE.md", .data = "app" });

    var files = try loadProjectContextFiles(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo/app",
    });
    defer files.deinit();

    try std.testing.expectEqual(@as(usize, 3), files.files.len);
    try std.testing.expectEqualStrings("agent/AGENTS.md", files.files[0].path);
    try std.testing.expectEqualStrings("repo/AGENTS.md", files.files[1].path);
    try std.testing.expectEqualStrings("repo/app/CLAUDE.md", files.files[2].path);
}

test "prefers agents over claude in same directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/AGENTS.md", .data = "agents" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/CLAUDE.md", .data = "claude" });

    var files = try loadProjectContextFiles(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "missing",
        .cwd = "repo",
    });
    defer files.deinit();

    try std.testing.expectEqual(@as(usize, 1), files.files.len);
    try std.testing.expectEqualStrings("repo/AGENTS.md", files.files[0].path);
    try std.testing.expectEqualStrings("agents", files.files[0].content);
}
