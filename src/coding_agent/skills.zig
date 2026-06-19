const std = @import("std");
const paths_mod = @import("paths.zig");

pub const max_skills = 128;
pub const max_skill_bytes = 256 * 1024;
pub const max_skill_depth = 32;
pub const max_skill_name_bytes = 128;
pub const max_skill_description_bytes = 1024;

pub const Skill = struct {
    path: []const u8,
    name: []const u8,
    description: []const u8,
};

pub const SkillSet = struct {
    allocator: std.mem.Allocator,
    skills: []Skill,

    pub fn deinit(self: *SkillSet) void {
        for (self.skills) |skill| deinitSkill(self.allocator, skill);
        self.allocator.free(self.skills);
        self.* = undefined;
    }
};

pub const LoadSkillsOptions = struct {
    dir: std.Io.Dir = .cwd(),
    agent_dir: []const u8,
    cwd: []const u8,
};

pub fn loadSkills(allocator: std.mem.Allocator, io: std.Io, options: LoadSkillsOptions) !SkillSet {
    var skills = std.ArrayList(Skill).empty;
    errdefer {
        for (skills.items) |skill| deinitSkill(allocator, skill);
        skills.deinit(allocator);
    }

    const resource_paths: paths_mod.PersistencePaths = .{ .global_dir = options.agent_dir, .cwd = options.cwd };
    const global_dir = try resource_paths.globalSkillsDir(allocator);
    defer allocator.free(global_dir);
    try loadSkillsFromDir(allocator, io, options.dir, global_dir, 0, &skills);

    const project_dir = try resource_paths.projectSkillsDir(allocator);
    defer allocator.free(project_dir);
    try loadSkillsFromDir(allocator, io, options.dir, project_dir, 0, &skills);

    return .{ .allocator = allocator, .skills = try skills.toOwnedSlice(allocator) };
}

fn loadSkillsFromDir(
    allocator: std.mem.Allocator,
    io: std.Io,
    root_dir: std.Io.Dir,
    path: []const u8,
    depth: usize,
    skills: *std.ArrayList(Skill),
) !void {
    if (depth == max_skill_depth) return;

    const skill_path = try std.fs.path.join(allocator, &.{ path, paths_mod.skill_file_name });
    defer allocator.free(skill_path);
    if (try loadSkillFile(allocator, io, root_dir, skill_path, std.fs.path.basename(path))) |skill| {
        try insertSkill(allocator, skills, skill);
        return;
    }

    var dir = root_dir.openDir(io, path, .{ .iterate = true, .access_sub_paths = true }) catch |err| switch (err) {
        error.FileNotFound => return,
        else => return err,
    };
    defer dir.close(io);

    var root_files = std.ArrayList([]const u8).empty;
    defer {
        for (root_files.items) |file| allocator.free(file);
        root_files.deinit(allocator);
    }

    var child_dirs = std.ArrayList([]const u8).empty;
    defer {
        for (child_dirs.items) |child| allocator.free(child);
        child_dirs.deinit(allocator);
    }

    var iterator = dir.iterate();
    while (try iterator.next(io)) |entry| {
        if (entry.name.len == 0 or entry.name[0] == '.') continue;
        switch (entry.kind) {
            .file => if (depth == 0 and std.mem.endsWith(u8, entry.name, ".md")) {
                const name_copy = try allocator.dupe(u8, entry.name);
                root_files.append(allocator, name_copy) catch |err| {
                    allocator.free(name_copy);
                    return err;
                };
            },
            .directory => {
                if (std.mem.eql(u8, entry.name, "node_modules")) continue;
                const name_copy = try allocator.dupe(u8, entry.name);
                child_dirs.append(allocator, name_copy) catch |err| {
                    allocator.free(name_copy);
                    return err;
                };
            },
            else => {},
        }
    }

    std.mem.sort([]const u8, root_files.items, {}, stringLessThan);
    for (root_files.items) |file| {
        {
            const file_path = try std.fs.path.join(allocator, &.{ path, file });
            defer allocator.free(file_path);
            const fallback_name = fallbackNameFromMarkdownFile(file);
            if (try loadSkillFile(allocator, io, root_dir, file_path, fallback_name)) |skill| {
                try insertSkill(allocator, skills, skill);
            }
        }
    }

    std.mem.sort([]const u8, child_dirs.items, {}, stringLessThan);
    for (child_dirs.items) |child| {
        {
            const child_path = try std.fs.path.join(allocator, &.{ path, child });
            defer allocator.free(child_path);
            try loadSkillsFromDir(allocator, io, root_dir, child_path, depth + 1, skills);
        }
    }
}

fn loadSkillFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    path: []const u8,
    fallback_name: []const u8,
) !?Skill {
    const content = dir.readFileAlloc(io, path, allocator, .limited(max_skill_bytes)) catch |err| switch (err) {
        error.FileNotFound, error.FileTooBig, error.StreamTooLong => return null,
        else => return err,
    };
    defer allocator.free(content);

    const parsed = parseFrontmatter(content) catch |err| switch (err) {
        error.InvalidSkillFrontmatter => return null,
    };
    if (parsed.description.len == 0) return null;
    const skill_name = if (parsed.name.len > 0) parsed.name else fallback_name;
    if (skill_name.len == 0) return null;
    if (skill_name.len > max_skill_name_bytes) return null;
    if (parsed.description.len > max_skill_description_bytes) return null;

    const path_copy = try canonicalSkillPath(allocator, io, dir, path);
    errdefer allocator.free(path_copy);
    const name = try allocator.dupe(u8, skill_name);
    errdefer allocator.free(name);
    const description = try allocator.dupe(u8, parsed.description);

    return .{
        .path = path_copy,
        .name = name,
        .description = description,
    };
}

const ParsedFrontmatter = struct {
    name: []const u8,
    description: []const u8,
};

fn parseFrontmatter(content: []const u8) !ParsedFrontmatter {
    const start: usize = if (std.mem.startsWith(u8, content, "---\n"))
        4
    else if (std.mem.startsWith(u8, content, "---\r\n"))
        5
    else
        return error.InvalidSkillFrontmatter;
    const end = findFrontmatterEnd(content, start) orelse return error.InvalidSkillFrontmatter;
    const frontmatter = content[start..end];
    var name: ?[]const u8 = null;
    var description: ?[]const u8 = null;
    var description_start: ?usize = null;
    var description_end: ?usize = null;

    var line_start: usize = 0;
    while (line_start <= frontmatter.len) {
        const line_end = std.mem.indexOfScalarPos(u8, frontmatter, line_start, '\n') orelse frontmatter.len;
        const raw_line = frontmatter[line_start..line_end];
        const trimmed = std.mem.trim(u8, raw_line, " \t\r");
        if (trimmed.len != 0) {
            if (description_start) |start_index| {
                if (raw_line.len != trimmed.len) {
                    description_end = line_end;
                    if (line_end == frontmatter.len) break;
                    line_start = line_end + 1;
                    continue;
                }
                const end_index = description_end orelse line_start;
                description = std.mem.trim(u8, frontmatter[start_index..end_index], " \t\r\n");
                description_start = null;
            }

            const colon = std.mem.findScalar(u8, trimmed, ':') orelse return error.InvalidSkillFrontmatter;
            const key = std.mem.trim(u8, trimmed[0..colon], " \t\r");
            const value = std.mem.trim(u8, trimmed[colon + 1 ..], " \t\r");
            if (std.mem.eql(u8, key, "name")) {
                if (name != null) return error.InvalidSkillFrontmatter;
                name = value;
            } else if (std.mem.eql(u8, key, "description")) {
                if (description != null or description_start != null) return error.InvalidSkillFrontmatter;
                if (value.len == 0 or std.mem.eql(u8, value, ">")) {
                    description_start = line_end + 1;
                    description_end = null;
                } else {
                    description = value;
                }
            }
        }
        if (line_end == frontmatter.len) break;
        line_start = line_end + 1;
    }

    if (description_start) |start_index| {
        const end_index = description_end orelse frontmatter.len;
        description = std.mem.trim(u8, frontmatter[start_index..end_index], " \t\r\n");
    }

    return .{
        .name = name orelse "",
        .description = description orelse "",
    };
}

fn findFrontmatterEnd(content: []const u8, start: usize) ?usize {
    var line_start = start;
    while (line_start <= content.len) {
        const line_end = std.mem.indexOfScalarPos(u8, content, line_start, '\n') orelse content.len;
        const raw_line = content[line_start..line_end];
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.eql(u8, line, "---")) return line_start;
        if (line_end == content.len) return null;
        line_start = line_end + 1;
    }
    return null;
}

fn canonicalSkillPath(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, path: []const u8) ![]const u8 {
    const real_path = dir.realPathFileAlloc(io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, path),
        error.NameTooLong => return allocator.dupe(u8, path),
        error.AccessDenied => return allocator.dupe(u8, path),
        error.PermissionDenied => return allocator.dupe(u8, path),
        else => return err,
    };
    defer allocator.free(real_path);
    return allocator.dupe(u8, real_path);
}

fn fallbackNameFromMarkdownFile(file_name: []const u8) []const u8 {
    if (std.mem.endsWith(u8, file_name, ".md")) return file_name[0 .. file_name.len - 3];
    return file_name;
}

fn insertSkill(allocator: std.mem.Allocator, skills: *std.ArrayList(Skill), skill: Skill) !void {
    for (skills.items, 0..) |existing, index| {
        if (std.mem.eql(u8, existing.name, skill.name)) {
            deinitSkill(allocator, existing);
            skills.items[index] = skill;
            return;
        }
    }
    if (skills.items.len == max_skills) {
        deinitSkill(allocator, skill);
        return;
    }
    skills.append(allocator, skill) catch |err| {
        deinitSkill(allocator, skill);
        return err;
    };
}

fn stringLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return std.mem.lessThan(u8, lhs, rhs);
}

fn deinitSkill(allocator: std.mem.Allocator, skill: Skill) void {
    allocator.free(skill.path);
    allocator.free(skill.name);
    allocator.free(skill.description);
}

test "loads global and project skills with project override" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/test-skill");
    try tmp.dir.createDirPath(std.testing.io, "repo/.zi/skills/test-skill");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/test-skill/SKILL.md",
        .data = "---\nname: test-skill\ndescription: global skill\n---\nbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "repo/.zi/skills/test-skill/SKILL.md",
        .data = "---\nname: test-skill\ndescription: project skill\n---\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("test-skill", skills.skills[0].name);
    try std.testing.expectEqualStrings("project skill", skills.skills[0].description);
}

test "skill root stops recursion" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/root/child");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/root/SKILL.md",
        .data = "---\nname: root\ndescription: root skill\n---\nbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/root/child/SKILL.md",
        .data = "---\nname: child\ndescription: child skill\n---\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("root", skills.skills[0].name);
}

test "loads root markdown skills and falls back to file name" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/root-tool.md",
        .data = "---\ndescription: root markdown skill\n---\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("root-tool", skills.skills[0].name);
    try std.testing.expectEqualStrings("root markdown skill", skills.skills[0].description);
    try std.testing.expect(std.fs.path.isAbsolute(skills.skills[0].path));
}

test "falls back to parent directory name for SKILL files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/parent-name");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/parent-name/SKILL.md",
        .data = "---\ndescription: directory skill\n---\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("parent-name", skills.skills[0].name);
    try std.testing.expectEqualStrings("directory skill", skills.skills[0].description);
}

test "accepts folded description frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/folded");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/folded/SKILL.md",
        .data =
        \\---
        \\name: folded
        \\description: >
        \\  first line
        \\  second line
        \\---
        \\body
        ,
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("folded", skills.skills[0].name);
    try std.testing.expectEqualStrings("first line\n  second line", skills.skills[0].description);
}

test "accepts crlf frontmatter delimiters" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/crlf");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/crlf/SKILL.md",
        .data = "---\r\nname: crlf\r\ndescription: crlf skill\r\n---\r\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("crlf", skills.skills[0].name);
    try std.testing.expectEqualStrings("crlf skill", skills.skills[0].description);
}

test "skips invalid skill frontmatter" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "agent/skills/bad-close");
    try tmp.dir.createDirPath(std.testing.io, "agent/skills/bad");
    try tmp.dir.createDirPath(std.testing.io, "agent/skills/good");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/bad-close/SKILL.md",
        .data = "---\nname: bad-close\n---oops\ndescription: invalid\n---\nbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/bad/SKILL.md",
        .data = "---\nname: bad\n---\nbody",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "agent/skills/good/SKILL.md",
        .data = "---\nname: good\ndescription: good skill\n---\nbody",
    });

    var skills = try loadSkills(std.testing.allocator, std.testing.io, .{
        .dir = tmp.dir,
        .agent_dir = "agent",
        .cwd = "repo",
    });
    defer skills.deinit();

    try std.testing.expectEqual(@as(usize, 1), skills.skills.len);
    try std.testing.expectEqualStrings("good", skills.skills[0].name);
}
