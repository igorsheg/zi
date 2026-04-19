const std = @import("std");
const storage = @import("../../storage.zig");
const extension_loader = @import("../extensions/loader.zig");
const extension_runner = @import("../extensions/runner.zig");
const lua_runtime = @import("../extensions/lua_runtime.zig");
const skills = @import("../skills/root.zig");
const settings_manager_mod = @import("../settings/manager.zig");
const theme_json = @import("../../themes/json.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const tui_theme = @import("../../tui/theme.zig");
const types = @import("types.zig");

pub const ResourceLoader = struct {
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
    settings_manager: ?*settings_manager_mod.SettingsManager,
    system_prompt_source: ?[]const u8,
    append_system_prompt_source: ?[]const u8,
    injected_agents_files: []types.AgentsFile,

    extensions: types.LoadedExtensions,
    skills: types.LoadedSkills,
    prompts: types.LoadedPrompts,
    themes: types.LoadedThemes,
    agents_files: []types.AgentsFile,
    system_prompt: ?[]const u8,
    append_system_prompt: []const []const u8,

    extended_skill_paths: []types.ResourcePath,
    extended_prompt_paths: []types.ResourcePath,
    extended_theme_paths: []types.ResourcePath,

    pub const Options = struct {
        cwd: []const u8,
        agent_dir_override: ?[]const u8 = null,
        settings_manager: ?*settings_manager_mod.SettingsManager = null,
        system_prompt: ?[]const u8 = null,
        append_system_prompt: ?[]const u8 = null,
        injected_agents_files: []const types.AgentsFile = &.{},
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !ResourceLoader {
        const cwd = try allocator.dupe(u8, options.cwd);
        errdefer allocator.free(cwd);

        const agent_dir = try storage.getAgentDir(allocator, options.agent_dir_override);
        errdefer allocator.free(agent_dir);

        const system_prompt_source = if (options.system_prompt) |value| try allocator.dupe(u8, value) else null;
        errdefer if (system_prompt_source) |value| allocator.free(value);

        const append_system_prompt_source = if (options.append_system_prompt) |value| try allocator.dupe(u8, value) else null;
        errdefer if (append_system_prompt_source) |value| allocator.free(value);

        const injected_agents_files = try dupAgentsFiles(allocator, options.injected_agents_files);
        errdefer freeAgentsFiles(allocator, injected_agents_files);

        var self = ResourceLoader{
            .allocator = allocator,
            .cwd = cwd,
            .agent_dir = agent_dir,
            .settings_manager = options.settings_manager,
            .system_prompt_source = system_prompt_source,
            .append_system_prompt_source = append_system_prompt_source,
            .injected_agents_files = injected_agents_files,
            .extensions = .{},
            .skills = .{},
            .prompts = .{},
            .themes = .{},
            .agents_files = &.{},
            .system_prompt = null,
            .append_system_prompt = &.{},
            .extended_skill_paths = &.{},
            .extended_prompt_paths = &.{},
            .extended_theme_paths = &.{},
        };
        errdefer self.deinit();

        try self.reload();
        return self;
    }

    pub fn deinit(self: *ResourceLoader) void {
        self.allocator.free(self.cwd);
        self.allocator.free(self.agent_dir);
        if (self.system_prompt_source) |value| self.allocator.free(value);
        if (self.append_system_prompt_source) |value| self.allocator.free(value);
        freeAgentsFiles(self.allocator, self.injected_agents_files);
        self.clearLoadedState();
        freeResourcePaths(self.allocator, self.extended_skill_paths);
        freeResourcePaths(self.allocator, self.extended_prompt_paths);
        freeResourcePaths(self.allocator, self.extended_theme_paths);
    }

    pub fn getExtensions(self: *const ResourceLoader) types.LoadedExtensions {
        return self.extensions;
    }

    pub fn loadExtensionsInto(self: *const ResourceLoader, state: *lua_runtime.LuaState, runner: *extension_runner.ExtensionRunner) extension_loader.LoadStats {
        const entries = self.allocExtensionLoaderEntries() catch return .{};
        defer self.allocator.free(entries);
        return extension_loader.loadAll(self.allocator, state, runner, entries);
    }

    pub fn getSkills(self: *const ResourceLoader) types.LoadedSkills {
        return self.skills;
    }

    pub fn getPrompts(self: *const ResourceLoader) types.LoadedPrompts {
        return self.prompts;
    }

    pub fn getThemes(self: *const ResourceLoader) types.LoadedThemes {
        return self.themes;
    }

    pub fn findThemeByName(self: *const ResourceLoader, name: []const u8) ?*const types.Theme {
        for (self.themes.themes) |*theme| {
            if (std.mem.eql(u8, theme.name, name)) return theme;
        }
        return null;
    }

    pub fn getPromptInputs(self: *const ResourceLoader) types.LoadedPromptInputs {
        return .{
            .system_prompt = self.system_prompt,
            .append_system_prompt = self.append_system_prompt,
            .agents_files = self.agents_files,
        };
    }

    pub fn extendResources(self: *ResourceLoader, paths: types.ResourceExtensionPaths) !void {
        self.extended_skill_paths = try mergeResourcePaths(self.allocator, self.extended_skill_paths, paths.skill_paths);
        self.extended_prompt_paths = try mergeResourcePaths(self.allocator, self.extended_prompt_paths, paths.prompt_paths);
        self.extended_theme_paths = try mergeResourcePaths(self.allocator, self.extended_theme_paths, paths.theme_paths);
        try self.reloadSkills();
        try self.reloadThemes();
    }

    pub fn reload(self: *ResourceLoader) !void {
        self.clearLoadedState();

        try self.reloadExtensions();
        try self.reloadSkills();
        try self.reloadThemes();

        self.system_prompt = if (self.system_prompt_source) |source|
            try resolvePromptInput(self.allocator, self.cwd, source)
        else
            null;

        self.append_system_prompt = if (self.append_system_prompt_source) |source|
            try allocSingleStringSlice(self.allocator, try resolvePromptInput(self.allocator, self.cwd, source))
        else
            &.{};

        self.agents_files = try loadAgentsFiles(self.allocator, self.cwd, self.agent_dir, self.injected_agents_files);
    }

    fn reloadExtensions(self: *ResourceLoader) !void {
        const discovered = try extension_loader.discover(.{
            .allocator = self.allocator,
            .cwd = self.cwd,
            .agent_dir_override = self.agent_dir,
        });
        defer extension_loader.freeExtensions(self.allocator, discovered);

        self.extensions = .{
            .extensions = try copyLoadedExtensions(self.allocator, discovered),
            .diagnostics = &.{},
        };
    }

    fn reloadSkills(self: *ResourceLoader) !void {
        freeLoadedSkills(self.allocator, self.skills.skills);
        freeDiagnostics(self.allocator, self.skills.diagnostics);
        self.skills = .{};

        var extended_paths = try self.allocator.alloc([]const u8, self.extended_skill_paths.len);
        defer self.allocator.free(extended_paths);
        for (self.extended_skill_paths, 0..) |entry, i| {
            extended_paths[i] = entry.path;
        }

        const loaded = try skills.loader.loadSkills(self.allocator, .{
            .cwd = self.cwd,
            .agent_dir = self.agent_dir,
            .skill_paths = extended_paths,
            .include_defaults = true,
        });
        defer skills.types.deinitLoadResult(self.allocator, loaded);

        self.skills = .{
            .skills = try copyLoadedSkills(self.allocator, loaded.skills),
            .diagnostics = try copyDiagnostics(self.allocator, loaded.diagnostics),
        };
        try applyExtendedSkillMetadata(self.allocator, self.skills.skills, self.extended_skill_paths);
    }

    fn reloadThemes(self: *ResourceLoader) !void {
        freeLoadedThemes(self.allocator, self.themes.themes);
        freeDiagnostics(self.allocator, self.themes.diagnostics);
        self.themes = .{};

        var themes: std.ArrayListUnmanaged(types.Theme) = .empty;
        errdefer {
            freeLoadedThemes(self.allocator, themes.items);
            themes = .empty;
        }
        var diagnostics: std.ArrayListUnmanaged(types.ResourceDiagnostic) = .empty;
        errdefer freeDiagnostics(self.allocator, diagnostics.items);

        try appendBuiltinTheme(self.allocator, &themes, &diagnostics, "dark", themes_builtin.dark().*);
        try appendBuiltinTheme(self.allocator, &themes, &diagnostics, "light", themes_builtin.light().*);

        const global_dir = try std.fs.path.join(self.allocator, &.{ self.agent_dir, "themes" });
        defer self.allocator.free(global_dir);
        try loadThemesFromPath(self, global_dir, .{
            .source = "local",
            .scope = .user,
            .origin = .top_level,
            .base_dir = global_dir,
        }, &themes, &diagnostics);

        const project_dir_root = try storage.getProjectDir(self.allocator, self.cwd);
        defer self.allocator.free(project_dir_root);
        const project_themes_dir = try std.fs.path.join(self.allocator, &.{ project_dir_root, "themes" });
        defer self.allocator.free(project_themes_dir);
        try loadThemesFromPath(self, project_themes_dir, .{
            .source = "local",
            .scope = .project,
            .origin = .top_level,
            .base_dir = project_themes_dir,
        }, &themes, &diagnostics);

        if (self.settings_manager) |settings| {
            if (settings.getThemePaths()) |paths| {
                for (paths) |path| {
                    const resolved = resolveResourcePath(self.allocator, self.cwd, path) catch continue;
                    defer self.allocator.free(resolved);
                    try loadThemesFromPath(self, resolved, .{
                        .source = "settings",
                        .scope = .temporary,
                        .origin = .top_level,
                        .base_dir = resolved,
                    }, &themes, &diagnostics);
                }
            }
        }

        for (self.extended_theme_paths) |entry| {
            try loadThemesFromPath(self, entry.path, entry.metadata, &themes, &diagnostics);
        }

        self.themes = .{
            .themes = try themes.toOwnedSlice(self.allocator),
            .diagnostics = try diagnostics.toOwnedSlice(self.allocator),
        };
    }

    fn clearLoadedState(self: *ResourceLoader) void {
        freeLoadedExtensions(self.allocator, self.extensions.extensions);
        self.extensions = .{};

        freeLoadedSkills(self.allocator, self.skills.skills);
        freeDiagnostics(self.allocator, self.skills.diagnostics);
        self.skills = .{};

        freeLoadedThemes(self.allocator, self.themes.themes);
        freeDiagnostics(self.allocator, self.themes.diagnostics);
        self.themes = .{};

        freeAgentsFiles(self.allocator, self.agents_files);
        self.agents_files = &.{};

        if (self.system_prompt) |value| self.allocator.free(value);
        self.system_prompt = null;

        freeStringSlice(self.allocator, self.append_system_prompt);
        self.append_system_prompt = &.{};
    }

    fn allocExtensionLoaderEntries(self: *const ResourceLoader) ![]extension_loader.LoadedExtension {
        const entries = try self.allocator.alloc(extension_loader.LoadedExtension, self.extensions.extensions.len);
        for (self.extensions.extensions, 0..) |entry, i| {
            entries[i] = .{
                .id = entry.id,
                .path = entry.path,
                .source = switch (entry.source) {
                    .explicit => .explicit,
                    .user => .user,
                    .project => .project,
                    .builtin => .builtin,
                },
            };
        }
        return entries;
    }
};

fn resolvePromptInput(allocator: std.mem.Allocator, cwd: []const u8, input: []const u8) ![]const u8 {
    const resolved_path = if (std.fs.path.isAbsolute(input))
        try allocator.dupe(u8, input)
    else
        try std.fs.path.join(allocator, &.{ cwd, input });
    defer allocator.free(resolved_path);

    const file = std.fs.openFileAbsolute(resolved_path, .{}) catch |err| switch (err) {
        error.FileNotFound => return allocator.dupe(u8, input),
        else => return allocator.dupe(u8, input),
    };
    defer file.close();
    return file.readToEndAlloc(allocator, 1024 * 1024);
}

fn allocSingleStringSlice(allocator: std.mem.Allocator, value: []const u8) ![]const []const u8 {
    const out = try allocator.alloc([]const u8, 1);
    out[0] = value;
    return out;
}

fn loadAgentsFiles(
    allocator: std.mem.Allocator,
    cwd: []const u8,
    agent_dir: []const u8,
    injected_agents_files: []const types.AgentsFile,
) ![]types.AgentsFile {
    var files: std.ArrayListUnmanaged(types.AgentsFile) = .empty;
    errdefer {
        for (files.items) |file| freeAgentsFile(allocator, file);
        files.deinit(allocator);
    }

    var seen_paths: std.StringHashMapUnmanaged(void) = .empty;
    defer seen_paths.deinit(allocator);

    if (try loadContextFileFromDir(allocator, agent_dir)) |global_file| {
        try appendUniqueAgentsFile(allocator, &files, &seen_paths, global_file);
    }

    var ancestor_files: std.ArrayListUnmanaged(types.AgentsFile) = .empty;
    defer ancestor_files.deinit(allocator);

    var current_dir = try allocator.dupe(u8, cwd);
    defer allocator.free(current_dir);

    while (true) {
        if (try loadContextFileFromDir(allocator, current_dir)) |context_file| {
            if (!seen_paths.contains(context_file.path)) {
                try seen_paths.put(allocator, context_file.path, {});
                try ancestor_files.insert(allocator, 0, context_file);
            } else {
                freeAgentsFile(allocator, context_file);
            }
        }

        const parent_dir = std.fs.path.dirname(current_dir) orelse break;
        if (parent_dir.len == 0 or std.mem.eql(u8, parent_dir, current_dir)) break;
        const next_dir = try allocator.dupe(u8, parent_dir);
        allocator.free(current_dir);
        current_dir = next_dir;
    }

    for (ancestor_files.items) |file| {
        try files.append(allocator, file);
    }

    for (injected_agents_files) |file| {
        const duped: types.AgentsFile = .{
            .path = try allocator.dupe(u8, file.path),
            .content = try allocator.dupe(u8, file.content),
        };
        errdefer freeAgentsFile(allocator, duped);
        try appendUniqueAgentsFile(allocator, &files, &seen_paths, duped);
    }

    return try files.toOwnedSlice(allocator);
}

fn appendUniqueAgentsFile(
    allocator: std.mem.Allocator,
    files: *std.ArrayListUnmanaged(types.AgentsFile),
    seen_paths: *std.StringHashMapUnmanaged(void),
    file: types.AgentsFile,
) !void {
    if (seen_paths.contains(file.path)) {
        freeAgentsFile(allocator, file);
        return;
    }
    try seen_paths.put(allocator, file.path, {});
    try files.append(allocator, file);
}

fn loadContextFileFromDir(allocator: std.mem.Allocator, dir: []const u8) !?types.AgentsFile {
    const candidates = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
    for (candidates) |filename| {
        const path = try std.fs.path.join(allocator, &.{ dir, filename });
        errdefer allocator.free(path);

        const file = std.fs.openFileAbsolute(path, .{}) catch |err| switch (err) {
            error.FileNotFound => {
                allocator.free(path);
                continue;
            },
            else => {
                allocator.free(path);
                continue;
            },
        };
        defer file.close();

        const content = try file.readToEndAlloc(allocator, 1024 * 1024);
        return .{ .path = path, .content = content };
    }
    return null;
}

fn copyLoadedExtensions(
    allocator: std.mem.Allocator,
    discovered: []const extension_loader.LoadedExtension,
) ![]types.LoadedExtension {
    const out = try allocator.alloc(types.LoadedExtension, discovered.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            freeLoadedExtension(allocator, out[j]);
        }
        allocator.free(out);
    }
    while (i < discovered.len) : (i += 1) {
        const source = extensionSourceFromLoader(discovered[i].source);
        out[i] = .{
            .id = try allocator.dupe(u8, discovered[i].id),
            .path = try allocator.dupe(u8, discovered[i].path),
            .source = source,
            .source_info = .{
                .path = try allocator.dupe(u8, discovered[i].path),
                .source = switch (source) {
                    .explicit => try allocator.dupe(u8, "explicit"),
                    .user => try allocator.dupe(u8, "local"),
                    .project => try allocator.dupe(u8, "local"),
                    .builtin => try allocator.dupe(u8, "builtin"),
                },
                .scope = switch (source) {
                    .user => .user,
                    .project => .project,
                    else => .temporary,
                },
                .origin = .top_level,
            },
        };
    }
    return out;
}

fn extensionSourceFromLoader(source: extension_loader.ExtensionSource) types.ExtensionSource {
    return switch (source) {
        .explicit => .explicit,
        .user => .user,
        .project => .project,
        .builtin => .builtin,
    };
}

fn freeLoadedExtensions(allocator: std.mem.Allocator, extensions: []const types.LoadedExtension) void {
    for (extensions) |entry| freeLoadedExtension(allocator, entry);
    if (extensions.len > 0) allocator.free(extensions);
}

fn copyLoadedSkills(allocator: std.mem.Allocator, loaded: []const skills.types.Skill) ![]types.Skill {
    const out = try allocator.alloc(types.Skill, loaded.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            freeLoadedSkill(allocator, out[j]);
        }
        allocator.free(out);
    }
    while (i < loaded.len) : (i += 1) {
        out[i] = .{
            .name = try allocator.dupe(u8, loaded[i].name),
            .description = try allocator.dupe(u8, loaded[i].description),
            .file_path = try allocator.dupe(u8, loaded[i].file_path),
            .base_dir = try allocator.dupe(u8, loaded[i].base_dir),
            .source_info = .{
                .path = try allocator.dupe(u8, loaded[i].source_info.path),
                .source = try allocator.dupe(u8, loaded[i].source_info.source),
                .scope = loaded[i].source_info.scope,
                .origin = loaded[i].source_info.origin,
                .base_dir = if (loaded[i].source_info.base_dir) |base_dir| try allocator.dupe(u8, base_dir) else null,
            },
            .disable_model_invocation = loaded[i].disable_model_invocation,
        };
    }
    return out;
}

fn freeLoadedSkills(allocator: std.mem.Allocator, loaded: []const types.Skill) void {
    for (loaded) |skill| freeLoadedSkill(allocator, skill);
    if (loaded.len > 0) allocator.free(loaded);
}

fn freeLoadedSkill(allocator: std.mem.Allocator, skill: types.Skill) void {
    allocator.free(skill.name);
    allocator.free(skill.description);
    allocator.free(skill.file_path);
    allocator.free(skill.base_dir);
    allocator.free(skill.source_info.path);
    allocator.free(skill.source_info.source);
    if (skill.source_info.base_dir) |base_dir| allocator.free(base_dir);
}

fn freeLoadedThemes(allocator: std.mem.Allocator, loaded: []const types.Theme) void {
    for (loaded) |theme| freeLoadedTheme(allocator, theme);
    if (loaded.len > 0) allocator.free(loaded);
}

fn freeLoadedTheme(allocator: std.mem.Allocator, theme: types.Theme) void {
    allocator.free(theme.name);
    allocator.free(theme.path);
    if (theme.source_info) |source_info| {
        allocator.free(source_info.path);
        allocator.free(source_info.source);
        if (source_info.base_dir) |base_dir| allocator.free(base_dir);
    }
}

fn appendBuiltinTheme(
    allocator: std.mem.Allocator,
    themes: *std.ArrayListUnmanaged(types.Theme),
    diagnostics: *std.ArrayListUnmanaged(types.ResourceDiagnostic),
    label: []const u8,
    theme_value: tui_theme.Theme,
) !void {
    const builtin_path = try std.fmt.allocPrint(allocator, "<builtin:{s}>", .{label});
    errdefer allocator.free(builtin_path);

    try appendThemeUnique(allocator, themes, diagnostics, .{
        .name = try allocator.dupe(u8, label),
        .path = builtin_path,
        .theme = theme_value,
        .source_info = .{
            .path = try allocator.dupe(u8, builtin_path),
            .source = try allocator.dupe(u8, "builtin"),
            .scope = .temporary,
            .origin = .top_level,
        },
    });
}

fn loadThemesFromPath(
    self: *ResourceLoader,
    path: []const u8,
    metadata: types.PathMetadata,
    themes: *std.ArrayListUnmanaged(types.Theme),
    diagnostics: *std.ArrayListUnmanaged(types.ResourceDiagnostic),
) !void {
    var dir = std.fs.openDirAbsolute(path, .{ .iterate = true }) catch |dir_err| switch (dir_err) {
        error.FileNotFound => return,
        error.NotDir => {
            if (!std.mem.endsWith(u8, path, ".json")) {
                try diagnostics.append(self.allocator, try themeDiagnostic(self.allocator, .warning, try std.fmt.allocPrint(self.allocator, "theme path is not a json file", .{}), path));
                return;
            }
            try loadThemeFromFile(self.allocator, path, metadata, themes, diagnostics);
            return;
        },
        else => {
            try diagnostics.append(self.allocator, try themeDiagnostic(self.allocator, .warning, try std.fmt.allocPrint(self.allocator, "failed to open theme path: {s}", .{@errorName(dir_err)}), path));
            return;
        },
    };
    defer dir.close();

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".json")) continue;
        const file_path = try std.fs.path.join(self.allocator, &.{ path, entry.name });
        defer self.allocator.free(file_path);
        try loadThemeFromFile(self.allocator, file_path, metadata, themes, diagnostics);
    }
}

fn loadThemeFromFile(
    allocator: std.mem.Allocator,
    path: []const u8,
    metadata: types.PathMetadata,
    themes: *std.ArrayListUnmanaged(types.Theme),
    diagnostics: *std.ArrayListUnmanaged(types.ResourceDiagnostic),
) !void {
    const file = std.fs.openFileAbsolute(path, .{}) catch |err| {
        try diagnostics.append(allocator, try themeDiagnostic(allocator, .warning, try std.fmt.allocPrint(allocator, "failed to open theme file: {s}", .{@errorName(err)}), path));
        return;
    };
    defer file.close();

    const bytes = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        try diagnostics.append(allocator, try themeDiagnostic(allocator, .warning, try std.fmt.allocPrint(allocator, "failed to read theme file: {s}", .{@errorName(err)}), path));
        return;
    };
    defer allocator.free(bytes);

    const loaded = theme_json.loadFromSlice(allocator, bytes) catch |err| {
        try diagnostics.append(allocator, try themeDiagnostic(allocator, .warning, try std.fmt.allocPrint(allocator, "failed to parse theme file: {s}", .{@errorName(err)}), path));
        return;
    };
    defer loaded.deinit(allocator);

    try appendThemeUnique(allocator, themes, diagnostics, .{
        .name = try allocator.dupe(u8, loaded.name),
        .path = try allocator.dupe(u8, path),
        .theme = loaded.theme,
        .source_info = .{
            .path = try allocator.dupe(u8, path),
            .source = try allocator.dupe(u8, metadata.source),
            .scope = metadata.scope,
            .origin = metadata.origin,
            .base_dir = if (metadata.base_dir) |base_dir| try allocator.dupe(u8, base_dir) else null,
        },
    });
}

fn appendThemeUnique(
    allocator: std.mem.Allocator,
    themes: *std.ArrayListUnmanaged(types.Theme),
    diagnostics: *std.ArrayListUnmanaged(types.ResourceDiagnostic),
    theme: types.Theme,
) !void {
    errdefer freeLoadedTheme(allocator, theme);

    for (themes.items) |existing| {
        if (!std.mem.eql(u8, existing.name, theme.name)) continue;
        try diagnostics.append(allocator, try collisionDiagnostic(allocator, existing, theme));
        return;
    }

    try themes.append(allocator, theme);
}

fn collisionDiagnostic(allocator: std.mem.Allocator, winner: types.Theme, loser: types.Theme) !types.ResourceDiagnostic {
    return .{
        .kind = .collision,
        .message = try std.fmt.allocPrint(allocator, "name \"{s}\" collision", .{loser.name}),
        .path = try allocator.dupe(u8, loser.path),
        .collision = .{
            .resource_type = .theme,
            .name = try allocator.dupe(u8, loser.name),
            .winner_path = try allocator.dupe(u8, winner.path),
            .loser_path = try allocator.dupe(u8, loser.path),
            .winner_source = if (winner.source_info) |info| try allocator.dupe(u8, info.source) else null,
            .loser_source = if (loser.source_info) |info| try allocator.dupe(u8, info.source) else null,
        },
    };
}

fn themeDiagnostic(
    allocator: std.mem.Allocator,
    kind: types.ResourceDiagnosticKind,
    message: []const u8,
    path: ?[]const u8,
) !types.ResourceDiagnostic {
    return .{
        .kind = kind,
        .message = message,
        .path = if (path) |value| try allocator.dupe(u8, value) else null,
    };
}

fn resolveResourcePath(allocator: std.mem.Allocator, cwd: []const u8, path: []const u8) ![]const u8 {
    const trimmed = std.mem.trim(u8, path, " \t\r\n");
    if (std.fs.path.isAbsolute(trimmed)) return allocator.dupe(u8, trimmed);
    if (std.mem.eql(u8, trimmed, "~")) {
        const home = std.posix.getenv("HOME") orelse return allocator.dupe(u8, trimmed);
        return allocator.dupe(u8, home);
    }
    if (std.mem.startsWith(u8, trimmed, "~/")) {
        const home = std.posix.getenv("HOME") orelse return allocator.dupe(u8, trimmed);
        return std.fs.path.join(allocator, &.{ home, trimmed[2..] });
    }
    return std.fs.path.join(allocator, &.{ cwd, trimmed });
}

fn copyDiagnostics(allocator: std.mem.Allocator, diagnostics: []const types.ResourceDiagnostic) ![]types.ResourceDiagnostic {
    const out = try allocator.alloc(types.ResourceDiagnostic, diagnostics.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            freeDiagnostic(allocator, out[j]);
        }
        allocator.free(out);
    }
    while (i < diagnostics.len) : (i += 1) {
        out[i] = try copyDiagnostic(allocator, diagnostics[i]);
    }
    return out;
}

fn copyDiagnostic(allocator: std.mem.Allocator, diagnostic: types.ResourceDiagnostic) !types.ResourceDiagnostic {
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

fn freeDiagnostics(allocator: std.mem.Allocator, diagnostics: []const types.ResourceDiagnostic) void {
    for (diagnostics) |diagnostic| freeDiagnostic(allocator, diagnostic);
    if (diagnostics.len > 0) allocator.free(diagnostics);
}

fn freeDiagnostic(allocator: std.mem.Allocator, diagnostic: types.ResourceDiagnostic) void {
    allocator.free(diagnostic.message);
    if (diagnostic.path) |path| allocator.free(path);
    if (diagnostic.collision) |collision| {
        allocator.free(collision.name);
        allocator.free(collision.winner_path);
        allocator.free(collision.loser_path);
        if (collision.winner_source) |value| allocator.free(value);
        if (collision.loser_source) |value| allocator.free(value);
    }
}

fn applyExtendedSkillMetadata(
    allocator: std.mem.Allocator,
    loaded: []types.Skill,
    extended_paths: []const types.ResourcePath,
) !void {
    for (loaded) |*skill| {
        for (extended_paths) |entry| {
            if (!pathContains(entry.path, skill.file_path)) continue;
            allocator.free(skill.source_info.path);
            allocator.free(skill.source_info.source);
            if (skill.source_info.base_dir) |base_dir| allocator.free(base_dir);
            skill.source_info = .{
                .path = try allocator.dupe(u8, skill.file_path),
                .source = try allocator.dupe(u8, entry.metadata.source),
                .scope = entry.metadata.scope,
                .origin = entry.metadata.origin,
                .base_dir = if (entry.metadata.base_dir) |base_dir| try allocator.dupe(u8, base_dir) else try allocator.dupe(u8, skill.base_dir),
            };
            break;
        }
    }
}

fn pathContains(root: []const u8, candidate: []const u8) bool {
    if (std.mem.eql(u8, root, candidate)) return true;
    if (!std.mem.startsWith(u8, candidate, root)) return false;
    if (candidate.len == root.len) return true;
    const sep = std.fs.path.sep;
    return candidate[root.len] == sep;
}

fn freeLoadedExtension(allocator: std.mem.Allocator, entry: types.LoadedExtension) void {
    allocator.free(entry.id);
    allocator.free(entry.path);
    if (entry.source_info) |source_info| {
        allocator.free(source_info.path);
        allocator.free(source_info.source);
        if (source_info.base_dir) |base_dir| allocator.free(base_dir);
    }
}

fn dupAgentsFiles(allocator: std.mem.Allocator, files: []const types.AgentsFile) ![]types.AgentsFile {
    const out = try allocator.alloc(types.AgentsFile, files.len);
    var i: usize = 0;
    errdefer {
        var j: usize = 0;
        while (j < i) : (j += 1) {
            freeAgentsFile(allocator, out[j]);
        }
        allocator.free(out);
    }
    while (i < files.len) : (i += 1) {
        out[i] = .{
            .path = try allocator.dupe(u8, files[i].path),
            .content = try allocator.dupe(u8, files[i].content),
        };
    }
    return out;
}

fn freeAgentsFiles(allocator: std.mem.Allocator, files: []types.AgentsFile) void {
    for (files) |file| freeAgentsFile(allocator, file);
    if (files.len > 0) allocator.free(files);
}

fn freeAgentsFile(allocator: std.mem.Allocator, file: types.AgentsFile) void {
    allocator.free(file.path);
    allocator.free(file.content);
}

fn freeStringSlice(allocator: std.mem.Allocator, values: []const []const u8) void {
    for (values) |value| allocator.free(value);
    if (values.len > 0) allocator.free(values);
}

fn mergeResourcePaths(
    allocator: std.mem.Allocator,
    existing: []types.ResourcePath,
    incoming: []const types.ResourcePath,
) ![]types.ResourcePath {
    var merged: std.ArrayListUnmanaged(types.ResourcePath) = .empty;
    errdefer freeResourcePaths(allocator, merged.items);

    for (existing) |entry| {
        try merged.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .metadata = .{
                .source = try allocator.dupe(u8, entry.metadata.source),
                .scope = entry.metadata.scope,
                .origin = entry.metadata.origin,
                .base_dir = if (entry.metadata.base_dir) |base_dir| try allocator.dupe(u8, base_dir) else null,
            },
        });
    }
    for (incoming) |entry| {
        try merged.append(allocator, .{
            .path = try allocator.dupe(u8, entry.path),
            .metadata = .{
                .source = try allocator.dupe(u8, entry.metadata.source),
                .scope = entry.metadata.scope,
                .origin = entry.metadata.origin,
                .base_dir = if (entry.metadata.base_dir) |base_dir| try allocator.dupe(u8, base_dir) else null,
            },
        });
    }

    freeResourcePaths(allocator, existing);
    return try merged.toOwnedSlice(allocator);
}

fn freeResourcePaths(allocator: std.mem.Allocator, paths: []types.ResourcePath) void {
    for (paths) |entry| {
        allocator.free(entry.path);
        allocator.free(entry.metadata.source);
        if (entry.metadata.base_dir) |base_dir| allocator.free(base_dir);
    }
    if (paths.len > 0) allocator.free(paths);
}

test "resource loader resolves prompt inputs and discovers agents files" {
    const allocator = std.testing.allocator;

    var agent_tmp = std.testing.tmpDir(.{});
    defer agent_tmp.cleanup();
    try agent_tmp.dir.makePath("skills/git");
    try agent_tmp.dir.writeFile(.{ .sub_path = "AGENTS.md", .data = "global rules" });
    try agent_tmp.dir.writeFile(.{ .sub_path = "skills/git/SKILL.md", .data = "---\ndescription: git help\n---\nbody\n" });
    const agent_root = try agent_tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(agent_root);

    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();
    try project_tmp.dir.makePath("repo/nested");
    try project_tmp.dir.makePath("repo/nested/.zi/skills/project-skill");
    try project_tmp.dir.writeFile(.{ .sub_path = "repo/AGENTS.md", .data = "repo rules" });
    try project_tmp.dir.writeFile(.{ .sub_path = "repo/nested/CLAUDE.md", .data = "nested rules" });
    try project_tmp.dir.writeFile(.{ .sub_path = "repo/nested/.zi/skills/project-skill/SKILL.md", .data = "---\ndescription: project help\n---\nbody\n" });
    try project_tmp.dir.writeFile(.{ .sub_path = "append.txt", .data = "append from file" });
    try project_tmp.dir.writeFile(.{ .sub_path = "extra-skill.md", .data = "---\nname: extra-skill\ndescription: extra help\n---\nbody\n" });
    const cwd = try project_tmp.dir.realpathAlloc(allocator, "repo/nested");
    defer allocator.free(cwd);
    const append_path = try project_tmp.dir.realpathAlloc(allocator, "append.txt");
    defer allocator.free(append_path);
    const extra_skill_path = try project_tmp.dir.realpathAlloc(allocator, "extra-skill.md");
    defer allocator.free(extra_skill_path);

    var loader = try ResourceLoader.init(allocator, .{
        .cwd = cwd,
        .agent_dir_override = agent_root,
        .system_prompt = "literal prompt",
        .append_system_prompt = append_path,
    });
    defer loader.deinit();

    const prompt_inputs = loader.getPromptInputs();
    try std.testing.expectEqualStrings("literal prompt", prompt_inputs.system_prompt.?);
    try std.testing.expectEqual(@as(usize, 1), prompt_inputs.append_system_prompt.len);
    try std.testing.expectEqualStrings("append from file", prompt_inputs.append_system_prompt[0]);
    try std.testing.expectEqual(@as(usize, 2), loader.getSkills().skills.len);

    const agents_files = prompt_inputs.agents_files;
    try std.testing.expect(agents_files.len >= 3);

    var saw_global = false;
    var saw_repo = false;
    var saw_nested = false;
    for (agents_files) |file| {
        if (std.mem.eql(u8, file.content, "global rules")) saw_global = true;
        if (std.mem.eql(u8, file.content, "repo rules")) saw_repo = true;
        if (std.mem.eql(u8, file.content, "nested rules")) saw_nested = true;
    }

    try std.testing.expect(saw_global);
    try std.testing.expect(saw_repo);
    try std.testing.expect(saw_nested);

    try loader.extendResources(.{
        .skill_paths = &.{.{
            .path = extra_skill_path,
            .metadata = .{
                .source = "extension:test",
                .scope = .temporary,
                .origin = .top_level,
            },
        }},
    });

    const loaded_skills = loader.getSkills().skills;
    try std.testing.expectEqual(@as(usize, 3), loaded_skills.len);
    var saw_extension_skill = false;
    for (loaded_skills) |skill| {
        if (std.mem.eql(u8, skill.name, "extra-skill")) {
            saw_extension_skill = true;
            try std.testing.expectEqualStrings("extension:test", skill.source_info.source);
        }
    }
    try std.testing.expect(saw_extension_skill);
}
