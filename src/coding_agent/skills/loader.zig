const std = @import("std");
const storage = @import("../../storage.zig");
const discovery = @import("discovery.zig");
const parse = @import("parse.zig");
const types = @import("types.zig");
const resource_types = @import("../resources/types.zig");

pub const LoadOptions = struct {
    cwd: ?[]const u8 = null,
    agent_dir: ?[]const u8 = null,
    skill_paths: []const []const u8 = &.{},
    include_defaults: bool = true,
};

pub fn loadSkills(allocator: std.mem.Allocator, options: LoadOptions) !types.LoadResult {
    const cwd = if (options.cwd) |cwd| try allocator.dupe(u8, cwd) else try std.fs.cwd().realpathAlloc(allocator, ".");
    defer allocator.free(cwd);

    const agent_dir = if (options.agent_dir) |agent_dir| try allocator.dupe(u8, agent_dir) else try storage.getAgentDir(allocator, null);
    defer allocator.free(agent_dir);

    var collector = Collector{};
    defer collector.deinit(allocator);

    if (options.include_defaults) {
        const user_skills_dir = try std.fs.path.join(allocator, &.{ agent_dir, "skills" });
        defer allocator.free(user_skills_dir);
        try loadSkillDirectory(allocator, user_skills_dir, .user, &collector);

        const project_dir = try storage.getProjectDir(allocator, cwd);
        defer allocator.free(project_dir);
        const project_skills_dir = try std.fs.path.join(allocator, &.{ project_dir, "skills" });
        defer allocator.free(project_skills_dir);
        try loadSkillDirectory(allocator, project_skills_dir, .project, &collector);
    }

    for (options.skill_paths) |raw_path| {
        const resolved = try resolveSkillPath(allocator, cwd, raw_path);
        defer allocator.free(resolved);

        if (std.fs.openDirAbsolute(resolved, .{})) |opened_dir| {
            var dir = opened_dir;
            dir.close();
            try loadSkillDirectory(allocator, resolved, .path, &collector);
        } else |dir_err| switch (dir_err) {
            error.NotDir => {
                const file = std.fs.openFileAbsolute(resolved, .{}) catch |file_err| switch (file_err) {
                    error.FileNotFound => {
                        try collector.appendWarning(allocator, resolved, "skill path does not exist");
                        continue;
                    },
                    else => return file_err,
                };
                file.close();

                if (std.mem.endsWith(u8, resolved, ".md")) {
                    try loadSkillFile(allocator, resolved, .path, &collector);
                } else {
                    try collector.appendWarning(allocator, resolved, "skill path is not a markdown file");
                }
            },
            error.FileNotFound => {
                try collector.appendWarning(allocator, resolved, "skill path does not exist");
                continue;
            },
            else => return dir_err,
        }
    }

    return try collector.toOwnedResult(allocator);
}

fn loadSkillDirectory(
    allocator: std.mem.Allocator,
    dir_path: []const u8,
    source_kind: types.SourceKind,
    collector: *Collector,
) !void {
    const files = discovery.discoverSkillFiles(allocator, dir_path) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer {
        for (files) |path| allocator.free(path);
        allocator.free(files);
    }

    for (files) |file_path| {
        try loadSkillFile(allocator, file_path, source_kind, collector);
    }
}

fn loadSkillFile(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source_kind: types.SourceKind,
    collector: *Collector,
) !void {
    const file = try std.fs.openFileAbsolute(file_path, .{});
    defer file.close();
    const raw = try file.readToEndAlloc(allocator, 1024 * 1024);
    defer allocator.free(raw);

    const parsed = try parse.parseFrontmatter(allocator, raw);
    defer parse.deinitParsedSkillDocument(allocator, parsed);

    const base_dir = std.fs.path.dirname(file_path) orelse ".";
    const parent_dir = std.fs.path.basename(base_dir);
    const diagnostics = try parse.validateSkillFrontmatter(allocator, parsed.frontmatter, parent_dir, file_path);
    defer types.deinitDiagnostics(allocator, diagnostics);
    for (diagnostics) |diagnostic| try collector.diagnostics.append(allocator, try dupDiagnostic(allocator, diagnostic));

    const description = parsed.frontmatter.description orelse return;
    if (std.mem.trim(u8, description, " \t\r\n").len == 0) return;

    const name = parsed.frontmatter.name orelse parent_dir;
    const skill = types.Skill{
        .name = try allocator.dupe(u8, name),
        .description = try allocator.dupe(u8, description),
        .file_path = try allocator.dupe(u8, file_path),
        .base_dir = try allocator.dupe(u8, base_dir),
        .source_info = try types.createSkillSourceInfo(allocator, file_path, base_dir, source_kind),
        .disable_model_invocation = parsed.frontmatter.disable_model_invocation,
    };
    errdefer types.deinitSkill(allocator, skill);
    try collector.addSkill(allocator, skill);
}

const Collector = struct {
    skills: std.ArrayListUnmanaged(types.Skill) = .empty,
    diagnostics: std.ArrayListUnmanaged(resource_types.ResourceDiagnostic) = .empty,
    loaded_realpaths: std.StringHashMapUnmanaged(void) = .empty,
    loaded_names: std.StringHashMapUnmanaged(usize) = .empty,

    fn deinit(self: *Collector, allocator: std.mem.Allocator) void {
        for (self.skills.items) |skill| types.deinitSkill(allocator, skill);
        self.skills.deinit(allocator);
        for (self.diagnostics.items) |diagnostic| {
            allocator.free(diagnostic.message);
            if (diagnostic.path) |path| allocator.free(path);
            if (diagnostic.collision) |collision| {
                allocator.free(collision.name);
                allocator.free(collision.winner_path);
                allocator.free(collision.loser_path);
                if (collision.winner_source) |winner_source| allocator.free(winner_source);
                if (collision.loser_source) |loser_source| allocator.free(loser_source);
            }
        }
        self.diagnostics.deinit(allocator);
        var realpath_it = self.loaded_realpaths.keyIterator();
        while (realpath_it.next()) |key| allocator.free(key.*);
        self.loaded_realpaths.deinit(allocator);
        self.loaded_names.deinit(allocator);
    }

    fn toOwnedResult(self: *Collector, allocator: std.mem.Allocator) !types.LoadResult {
        const skills = try self.skills.toOwnedSlice(allocator);
        const diagnostics = try self.diagnostics.toOwnedSlice(allocator);

        var realpath_it = self.loaded_realpaths.keyIterator();
        while (realpath_it.next()) |key| allocator.free(key.*);
        self.loaded_realpaths.deinit(allocator);
        self.loaded_names.deinit(allocator);

        self.* = .{};
        return .{ .skills = skills, .diagnostics = diagnostics };
    }

    fn addSkill(self: *Collector, allocator: std.mem.Allocator, skill: types.Skill) !void {
        const realpath = std.fs.realpathAlloc(allocator, skill.file_path) catch try allocator.dupe(u8, skill.file_path);
        errdefer allocator.free(realpath);
        if (self.loaded_realpaths.contains(realpath)) {
            allocator.free(realpath);
            types.deinitSkill(allocator, skill);
            return;
        }

        if (self.loaded_names.get(skill.name)) |winner_index| {
            const winner = self.skills.items[winner_index];
            try self.diagnostics.append(allocator, .{
                .kind = .collision,
                .message = try allocator.dupe(u8, "skill name collision"),
                .path = try allocator.dupe(u8, skill.file_path),
                .collision = .{
                    .resource_type = .skill,
                    .name = try allocator.dupe(u8, skill.name),
                    .winner_path = try allocator.dupe(u8, winner.file_path),
                    .loser_path = try allocator.dupe(u8, skill.file_path),
                },
            });
            types.deinitSkill(allocator, skill);
            return;
        }

        try self.loaded_realpaths.put(allocator, realpath, {});
        try self.loaded_names.put(allocator, skill.name, self.skills.items.len);
        try self.skills.append(allocator, skill);
    }

    fn appendWarning(self: *Collector, allocator: std.mem.Allocator, path: []const u8, message: []const u8) !void {
        try self.diagnostics.append(allocator, .{
            .kind = .warning,
            .message = try allocator.dupe(u8, message),
            .path = try allocator.dupe(u8, path),
        });
    }
};

fn resolveSkillPath(allocator: std.mem.Allocator, cwd: []const u8, raw_path: []const u8) ![]const u8 {
    const normalized = if (std.mem.eql(u8, raw_path, "~"))
        try allocator.dupe(u8, std.posix.getenv("HOME") orelse raw_path)
    else if (std.mem.startsWith(u8, raw_path, "~/")) blk: {
        const home = std.posix.getenv("HOME") orelse break :blk try allocator.dupe(u8, raw_path);
        break :blk try std.fs.path.join(allocator, &.{ home, raw_path[2..] });
    } else try allocator.dupe(u8, raw_path);
    defer allocator.free(normalized);

    if (std.fs.path.isAbsolute(normalized)) return allocator.dupe(u8, normalized);
    return try std.fs.path.join(allocator, &.{ cwd, normalized });
}

fn dupDiagnostic(allocator: std.mem.Allocator, diagnostic: resource_types.ResourceDiagnostic) !resource_types.ResourceDiagnostic {
    return .{
        .kind = diagnostic.kind,
        .message = try allocator.dupe(u8, diagnostic.message),
        .path = if (diagnostic.path) |path| try allocator.dupe(u8, path) else null,
        .collision = if (diagnostic.collision) |collision| .{
            .resource_type = collision.resource_type,
            .name = try allocator.dupe(u8, collision.name),
            .winner_path = try allocator.dupe(u8, collision.winner_path),
            .loser_path = try allocator.dupe(u8, collision.loser_path),
            .winner_source = if (collision.winner_source) |value| try allocator.dupe(u8, value) else null,
            .loser_source = if (collision.loser_source) |value| try allocator.dupe(u8, value) else null,
        } else null,
    };
}

test "load skills from defaults and explicit paths" {
    const allocator = std.testing.allocator;

    var agent_tmp = std.testing.tmpDir(.{});
    defer agent_tmp.cleanup();
    try agent_tmp.dir.makePath("skills/git");
    try agent_tmp.dir.writeFile(.{ .sub_path = "skills/git/SKILL.md", .data = "---\ndescription: git help\n---\nbody\n" });
    const agent_root = try agent_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(agent_root);

    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();
    try project_tmp.dir.makePath("repo/.zi/skills/project-skill");
    try project_tmp.dir.writeFile(.{ .sub_path = "repo/.zi/skills/project-skill/SKILL.md", .data = "---\ndescription: project help\n---\nbody\n" });
    try project_tmp.dir.writeFile(.{ .sub_path = "extra.md", .data = "---\nname: extra\ndescription: extra help\n---\nbody\n" });
    const cwd = try project_tmp.dir.realpathAlloc(allocator, "repo");
    defer allocator.free(cwd);
    const extra_path = try project_tmp.dir.realpathAlloc(allocator, "extra.md");
    defer allocator.free(extra_path);

    const result = try loadSkills(allocator, .{
        .cwd = cwd,
        .agent_dir = agent_root,
        .skill_paths = &.{extra_path},
    });
    defer types.deinitLoadResult(allocator, result);

    try std.testing.expectEqual(@as(usize, 3), result.skills.len);
}
