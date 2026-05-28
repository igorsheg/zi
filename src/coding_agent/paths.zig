const std = @import("std");
const mem = @import("../zistd/root.zig");

pub const global_config_dir_name = ".zi";
pub const project_config_dir_name = ".zi";
pub const settings_file_name = "settings.json";
pub const auth_file_name = "auth.json";
pub const skills_dir_name = "skills";
pub const system_prompt_file_name = "SYSTEM.md";
pub const append_system_prompt_file_name = "APPEND_SYSTEM.md";

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

pub fn encodeCwd(allocator: std.mem.Allocator, cwd: []const u8) ![]const u8 {
    var out = mem.ByteBuilder.init(allocator);
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
