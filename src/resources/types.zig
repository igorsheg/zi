const std = @import("std");
const tui_theme = @import("../tui/theme.zig");

pub const ResourceType = enum {
    extension,
    skill,
    prompt,
    theme,
};

pub const ResourceCollision = struct {
    resource_type: ResourceType,
    name: []const u8,
    winner_path: []const u8,
    loser_path: []const u8,
    winner_source: ?[]const u8 = null,
    loser_source: ?[]const u8 = null,
};

pub const ResourceDiagnosticKind = enum {
    warning,
    err,
    collision,
};

pub const ResourceDiagnostic = struct {
    kind: ResourceDiagnosticKind,
    message: []const u8,
    path: ?[]const u8 = null,
    collision: ?ResourceCollision = null,
};

pub const SourceScope = enum {
    user,
    project,
    temporary,
};

pub const SourceOrigin = enum {
    package,
    top_level,
};

pub const SourceInfo = struct {
    path: []const u8,
    source: []const u8,
    scope: SourceScope = .temporary,
    origin: SourceOrigin = .top_level,
    base_dir: ?[]const u8 = null,
};

pub const PathMetadata = struct {
    source: []const u8,
    scope: SourceScope = .temporary,
    origin: SourceOrigin = .top_level,
    base_dir: ?[]const u8 = null,
};

pub fn createSourceInfo(path: []const u8, metadata: PathMetadata) SourceInfo {
    return .{
        .path = path,
        .source = metadata.source,
        .scope = metadata.scope,
        .origin = metadata.origin,
        .base_dir = metadata.base_dir,
    };
}

pub const ResourcePath = struct {
    path: []const u8,
    metadata: PathMetadata,
};

pub const ResourceExtensionPaths = struct {
    skill_paths: []const ResourcePath = &.{},
    prompt_paths: []const ResourcePath = &.{},
    theme_paths: []const ResourcePath = &.{},
};

pub const ExtensionSource = enum {
    explicit,
    user,
    project,
    builtin,
};

pub const LoadedExtension = struct {
    id: []const u8,
    path: []const u8,
    source: ExtensionSource,
    source_info: ?SourceInfo = null,
};

pub const LoadedExtensions = struct {
    extensions: []const LoadedExtension = &.{},
    diagnostics: []const ResourceDiagnostic = &.{},
};

pub const Skill = struct {
    name: []const u8,
    description: []const u8,
    file_path: []const u8,
    base_dir: []const u8,
    source_info: SourceInfo,
    disable_model_invocation: bool = false,
};

pub const LoadedSkills = struct {
    skills: []Skill = &.{},
    diagnostics: []const ResourceDiagnostic = &.{},
};

pub const PromptTemplate = struct {
    name: []const u8,
    path: []const u8,
    content: []const u8,
    source_info: ?SourceInfo = null,
};

pub const LoadedPrompts = struct {
    prompts: []const PromptTemplate = &.{},
    diagnostics: []const ResourceDiagnostic = &.{},
};

pub const Theme = struct {
    name: []const u8,
    path: []const u8,
    theme: tui_theme.Theme,
    source_info: ?SourceInfo = null,
};

pub const LoadedThemes = struct {
    themes: []const Theme = &.{},
    diagnostics: []const ResourceDiagnostic = &.{},
};

pub const AgentsFile = struct {
    path: []const u8,
    content: []const u8,
};

pub const LoadedAgentsFiles = struct {
    agents_files: []const AgentsFile = &.{},
};

pub const LoadedPromptInputs = struct {
    system_prompt: ?[]const u8 = null,
    append_system_prompt: []const []const u8 = &.{},
    agents_files: []const AgentsFile = &.{},
};

test {
    std.testing.refAllDecls(@This());
}
