const std = @import("std");
const mem = @import("../runtime/root.zig");

pub const global_config_dir_name = ".zi";
pub const agent_dir_name = "agent";
pub const env_agent_dir_name = "ZI_CODING_AGENT_DIR";
pub const project_config_dir_name = ".zi";
pub const settings_file_name = "settings.json";
pub const auth_file_name = "auth.json";
pub const skills_dir_name = "skills";
pub const system_prompt_file_name = "SYSTEM.md";
pub const append_system_prompt_file_name = "APPEND_SYSTEM.md";

pub const GlobalAgentDirOptions = struct {
    home_dir: []const u8,
    override: ?[]const u8 = null,
};

pub fn resolveGlobalAgentDirFromEnv(
    allocator: std.mem.Allocator,
    environ: ?*const std.process.Environ.Map,
) ![]u8 {
    const env = environ orelse return error.HomeNotSet;
    const home_dir = env.get("HOME") orelse return error.HomeNotSet;
    return resolveGlobalAgentDir(allocator, .{
        .home_dir = home_dir,
        .override = env.get(env_agent_dir_name),
    });
}

pub fn resolveGlobalAgentDir(
    allocator: std.mem.Allocator,
    options: GlobalAgentDirOptions,
) ![]u8 {
    if (options.override) |value| {
        if (std.mem.eql(u8, value, "~")) return allocator.dupe(u8, options.home_dir);
        if (std.mem.startsWith(u8, value, "~/")) {
            return std.fs.path.join(allocator, &.{ options.home_dir, value[2..] });
        }
        return allocator.dupe(u8, value);
    }

    return std.fs.path.join(allocator, &.{ options.home_dir, global_config_dir_name, agent_dir_name });
}

pub const PersistencePaths = struct {
    global_dir: []const u8,
    cwd: []const u8,

    pub fn sessionsDirForCwd(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        const encoded = try encodeCwd(allocator, self.cwd);
        defer allocator.free(encoded);
        return std.fs.path.join(allocator, &.{ self.global_dir, "sessions", encoded });
    }

    pub fn globalSettingsPath(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.global_dir, settings_file_name });
    }

    pub fn authPath(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.global_dir, auth_file_name });
    }

    pub fn projectConfigDir(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.cwd, project_config_dir_name });
    }

    pub fn projectSettingsPath(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.cwd, project_config_dir_name, settings_file_name });
    }

    pub fn globalSkillsDir(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.global_dir, skills_dir_name });
    }

    pub fn projectSkillsDir(self: PersistencePaths, allocator: std.mem.Allocator) ![]const u8 {
        return std.fs.path.join(allocator, &.{ self.cwd, project_config_dir_name, skills_dir_name });
    }
};

/// One source of truth for the session file naming scheme:
/// `<timestamp>_<session-id>.jsonl`. The store formats it; listing and
/// resume validate it.
pub fn sessionFileLeafName(
    allocator: std.mem.Allocator,
    timestamp: []const u8,
    session_id: []const u8,
) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}_{s}.jsonl", .{ timestamp, session_id });
}

pub fn isSessionFileLeafName(file_name: []const u8) bool {
    if (!std.mem.eql(u8, std.fs.path.basename(file_name), file_name)) return false;
    if (!std.mem.endsWith(u8, file_name, ".jsonl")) return false;
    return std.mem.indexOfScalar(u8, file_name, '_') != null;
}

pub fn encodeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    const capacity_max = std.math.add(usize, cwd.len, 4) catch return error.OutOfMemory;
    var out = mem.ByteBuilder.initBounded(allocator, capacity_max);
    errdefer out.deinit();
    try out.append("--");
    const start: usize = if (cwd.len > 0 and (cwd[0] == '/' or cwd[0] == '\\')) 1 else 0;
    for (cwd[start..]) |char| {
        switch (char) {
            '/', '\\', ':' => try out.appendByte('-'),
            else => try out.appendByte(char),
        }
    }
    try out.append("--");
    return out.toOwnedSlice();
}

test "global agent dir defaults under home zi agent" {
    const dir = try resolveGlobalAgentDir(std.testing.allocator, .{ .home_dir = "/home/me" });
    defer std.testing.allocator.free(dir);

    try std.testing.expectEqualStrings("/home/me/.zi/agent", dir);
}

test "global agent dir expands tilde override" {
    const dir = try resolveGlobalAgentDir(std.testing.allocator, .{
        .home_dir = "/home/me",
        .override = "~/custom-agent",
    });
    defer std.testing.allocator.free(dir);

    try std.testing.expectEqualStrings("/home/me/custom-agent", dir);
}

test "global agent dir accepts absolute override" {
    const dir = try resolveGlobalAgentDir(std.testing.allocator, .{
        .home_dir = "/home/me",
        .override = "/tmp/zi-agent",
    });
    defer std.testing.allocator.free(dir);

    try std.testing.expectEqualStrings("/tmp/zi-agent", dir);
}

test "cwd encoding matches pi session directory shape" {
    const encoded = try encodeCwd(std.testing.allocator, "/Users/me/project:one");
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqualStrings("--Users-me-project-one--", encoded);
}

test "persistence paths computes cwd session directory" {
    const paths: PersistencePaths = .{ .global_dir = "/home/me/.zi", .cwd = "/repo/app" };
    const session_dir = try paths.sessionsDirForCwd(std.testing.allocator);
    defer std.testing.allocator.free(session_dir);

    try std.testing.expect(std.mem.endsWith(u8, session_dir, "sessions/--repo-app--"));
}

test "persistence paths owns user and project zi resource paths" {
    const paths: PersistencePaths = .{ .global_dir = "agent", .cwd = "repo" };

    const global_settings = try paths.globalSettingsPath(std.testing.allocator);
    defer std.testing.allocator.free(global_settings);
    const auth_path = try paths.authPath(std.testing.allocator);
    defer std.testing.allocator.free(auth_path);
    const project_config = try paths.projectConfigDir(std.testing.allocator);
    defer std.testing.allocator.free(project_config);
    const project_settings = try paths.projectSettingsPath(std.testing.allocator);
    defer std.testing.allocator.free(project_settings);
    const global_skills = try paths.globalSkillsDir(std.testing.allocator);
    defer std.testing.allocator.free(global_skills);
    const project_skills = try paths.projectSkillsDir(std.testing.allocator);
    defer std.testing.allocator.free(project_skills);

    try std.testing.expectEqualStrings(".zi", global_config_dir_name);
    try std.testing.expectEqualStrings("agent/settings.json", global_settings);
    try std.testing.expectEqualStrings("agent/auth.json", auth_path);
    try std.testing.expectEqualStrings("repo/.zi", project_config);
    try std.testing.expectEqualStrings("repo/.zi/settings.json", project_settings);
    try std.testing.expectEqualStrings("agent/skills", global_skills);
    try std.testing.expectEqualStrings("repo/.zi/skills", project_skills);
}
