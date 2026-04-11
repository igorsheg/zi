const std = @import("std");
const resource_types = @import("../resources/types.zig");

pub const MAX_NAME_LENGTH: usize = 64;
pub const MAX_DESCRIPTION_LENGTH: usize = 1024;

pub const SkillFrontmatter = struct {
    name: ?[]const u8 = null,
    description: ?[]const u8 = null,
    disable_model_invocation: bool = false,
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    file_path: []const u8,
    base_dir: []const u8,
    source_info: resource_types.SourceInfo,
    disable_model_invocation: bool = false,
};

pub const LoadResult = struct {
    skills: []const Skill = &.{},
    diagnostics: []const resource_types.ResourceDiagnostic = &.{},
};

pub const SourceKind = enum {
    user,
    project,
    path,
};

pub fn createSkillSourceInfo(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    base_dir: []const u8,
    source_kind: SourceKind,
) !resource_types.SourceInfo {
    return .{
        .path = try allocator.dupe(u8, file_path),
        .source = try allocator.dupe(u8, switch (source_kind) {
            .user, .project, .path => "local",
        }),
        .scope = switch (source_kind) {
            .user => .user,
            .project => .project,
            .path => .temporary,
        },
        .origin = .top_level,
        .base_dir = try allocator.dupe(u8, base_dir),
    };
}

pub fn deinitSkill(allocator: std.mem.Allocator, skill: Skill) void {
    allocator.free(skill.name);
    allocator.free(skill.description);
    allocator.free(skill.file_path);
    allocator.free(skill.base_dir);
    allocator.free(skill.source_info.path);
    allocator.free(skill.source_info.source);
    if (skill.source_info.base_dir) |base_dir| allocator.free(base_dir);
}

pub fn deinitDiagnostics(allocator: std.mem.Allocator, diagnostics: []const resource_types.ResourceDiagnostic) void {
    for (diagnostics) |diagnostic| {
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
    if (diagnostics.len > 0) allocator.free(diagnostics);
}

pub fn deinitLoadResult(allocator: std.mem.Allocator, result: LoadResult) void {
    for (result.skills) |skill| deinitSkill(allocator, skill);
    if (result.skills.len > 0) allocator.free(result.skills);
    deinitDiagnostics(allocator, result.diagnostics);
}

test {
    std.testing.refAllDecls(@This());
}
