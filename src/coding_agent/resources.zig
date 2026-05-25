const std = @import("std");

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

pub const OwnedPromptFile = struct {
    allocator: std.mem.Allocator,
    file: ?PromptFile,

    pub fn deinit(self: *OwnedPromptFile) void {
        if (self.file) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.content);
        }
        self.* = undefined;
    }
};

pub const OwnedContextFiles = struct {
    allocator: std.mem.Allocator,
    files: []const ContextFile,

    pub fn deinit(self: *OwnedContextFiles) void {
        for (self.files) |file| {
            self.allocator.free(file.path);
            self.allocator.free(file.content);
        }
        self.allocator.free(self.files);
        self.* = undefined;
    }
};

pub const LoadProjectContextOptions = struct {
    dir: std.Io.Dir = .cwd(),
    agent_dir: []const u8,
    cwd: []const u8,
};

pub const DiscoverPromptFileOptions = struct {
    dir: std.Io.Dir = .cwd(),
    agent_dir: []const u8,
    cwd: []const u8,
};

pub const PromptResources = struct {
    context_files: OwnedContextFiles,
    system_prompt: OwnedPromptFile,
    append_system_prompt: OwnedPromptFile,

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

        return .{
            .context_files = context_files,
            .system_prompt = system_prompt,
            .append_system_prompt = append_system_prompt,
        };
    }

    pub fn deinit(self: *PromptResources) void {
        self.context_files.deinit();
        self.system_prompt.deinit();
        self.append_system_prompt.deinit();
        self.* = undefined;
    }

    pub fn customPrompt(self: *const PromptResources) ?[]const u8 {
        return if (self.system_prompt.file) |file| file.content else null;
    }

    pub fn appendSystemPrompt(self: *const PromptResources) ?[]const u8 {
        return if (self.append_system_prompt.file) |file| file.content else null;
    }
};

pub fn discoverSystemPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
) !OwnedPromptFile {
    return discoverPromptFile(allocator, io, options, "SYSTEM.md");
}

pub fn discoverAppendSystemPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
) !OwnedPromptFile {
    return discoverPromptFile(allocator, io, options, "APPEND_SYSTEM.md");
}

fn discoverPromptFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: DiscoverPromptFileOptions,
    file_name: []const u8,
) !OwnedPromptFile {
    const project_dir = try std.fs.path.join(allocator, &.{ options.cwd, ".zi" });
    defer allocator.free(project_dir);
    if (try loadPromptFileFromDir(allocator, io, options.dir, project_dir, file_name)) |file| {
        return .{ .allocator = allocator, .file = file };
    }
    if (try loadPromptFileFromDir(allocator, io, options.dir, options.agent_dir, file_name)) |file| {
        return .{ .allocator = allocator, .file = file };
    }
    return .{ .allocator = allocator, .file = null };
}

pub fn loadProjectContextFiles(
    allocator: std.mem.Allocator,
    io: std.Io,
    options: LoadProjectContextOptions,
) !OwnedContextFiles {
    var files = std.ArrayList(ContextFile).empty;
    errdefer freeContextFileItems(allocator, files.items);
    errdefer files.deinit(allocator);

    if (try loadContextFileFromDir(allocator, io, options.dir, options.agent_dir)) |global| {
        try appendContextFile(allocator, &files, global);
    }

    var ancestor_files = std.ArrayList(ContextFile).empty;
    errdefer freeContextFileItems(allocator, ancestor_files.items);
    errdefer ancestor_files.deinit(allocator);

    var current_dir = options.cwd;
    var depth: usize = 0;
    while (true) {
        if (depth == max_ancestor_depth) return error.AncestorLimitExceeded;
        if (try loadContextFileFromDir(allocator, io, options.dir, current_dir)) |context_file| {
            const already_loaded = containsPath(files.items, context_file.path) or
                containsPath(ancestor_files.items, context_file.path);
            if (!already_loaded) {
                try appendContextFile(allocator, &ancestor_files, context_file);
            } else {
                freeContextFile(allocator, context_file);
            }
        }
        const parent = std.fs.path.dirname(current_dir) orelse break;
        if (std.mem.eql(u8, parent, current_dir)) break;
        current_dir = parent;
        depth += 1;
    }

    std.mem.reverse(ContextFile, ancestor_files.items);
    for (ancestor_files.items) |file| try appendContextFile(allocator, &files, file);
    ancestor_files.clearRetainingCapacity();
    ancestor_files.deinit(allocator);

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

fn freeContextFileItems(allocator: std.mem.Allocator, files: []const ContextFile) void {
    for (files) |file| freeContextFile(allocator, file);
}

fn freeContextFile(allocator: std.mem.Allocator, file: ContextFile) void {
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
    try std.testing.expectEqualStrings("system", prompt_resources.customPrompt().?);
    try std.testing.expectEqualStrings("append", prompt_resources.appendSystemPrompt().?);
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
    try std.testing.expect(prompt_resources.customPrompt() == null);
    try std.testing.expect(prompt_resources.appendSystemPrompt() == null);
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
