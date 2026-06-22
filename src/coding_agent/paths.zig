const std = @import("std");
const builtin = @import("builtin");
const mem = @import("../runtime/root.zig");

pub const global_config_dir_name = ".zi";
pub const agent_dir_name = "agent";
pub const env_agent_dir_name = "ZI_CODING_AGENT_DIR";
pub const project_config_dir_name = ".zi";
pub const settings_file_name = "settings.json";
pub const auth_file_name = "auth.json";
pub const sessions_dir_name = "sessions";
pub const skills_dir_name = "skills";
pub const skill_file_name = "SKILL.md";
pub const system_prompt_file_name = "SYSTEM.md";
pub const append_system_prompt_file_name = "APPEND_SYSTEM.md";

/// Tool operand path policy owner. Tools pass user-supplied operands here and
/// receive an owned absolute path after normalization, optional home expansion,
/// platform filename repair, and cwd containment checks.
pub const ToolPaths = struct {
    pub const Config = ToolPathConfig;

    pub fn resolveExisting(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        path: []const u8,
    ) ![]const u8 {
        return resolvePath(allocator, io, config, path, .existing);
    }

    pub fn resolveCreatable(
        allocator: std.mem.Allocator,
        io: std.Io,
        config: Config,
        path: []const u8,
    ) ![]const u8 {
        return resolvePath(allocator, io, config, path, .creatable);
    }
};

const max_path_bytes: usize = 16 * 1024;

pub const ToolPathConfig = struct {
    cwd: []const u8,
    allow_paths_outside_cwd: bool = false,
    home_dir: ?[]const u8 = null,
};

const PathKind = enum { existing, creatable };

fn pathExists(allocator: std.mem.Allocator, io: std.Io, path: []const u8) !bool {
    const real_path = std.Io.Dir.realPathFileAlloc(.cwd(), io, path, allocator) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    allocator.free(real_path);
    return true;
}

fn resolveExistingVariant(
    allocator: std.mem.Allocator,
    io: std.Io,
    owned_path: []u8,
) ![]u8 {
    if (try pathExists(allocator, io, owned_path)) return owned_path;
    if (try macOsScreenshotPathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        allocator.free(variant);
    }
    if (try nfdLatin1PathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        if (try curlyQuotePathVariant(allocator, variant)) |combined| {
            errdefer allocator.free(combined);
            if (try pathExists(allocator, io, combined)) {
                allocator.free(owned_path);
                allocator.free(variant);
                return combined;
            }
            allocator.free(combined);
        }
        allocator.free(variant);
    }
    if (try curlyQuotePathVariant(allocator, owned_path)) |variant| {
        errdefer allocator.free(variant);
        if (try pathExists(allocator, io, variant)) {
            allocator.free(owned_path);
            return variant;
        }
        allocator.free(variant);
    }
    return owned_path;
}

fn resolvePath(
    allocator: std.mem.Allocator,
    io: std.Io,
    config: ToolPathConfig,
    path: []const u8,
    kind: PathKind,
) ![]const u8 {
    const normalized = try normalizeInputPath(allocator, path);
    defer allocator.free(normalized);
    const expanded_home = try expandHomePath(allocator, normalized, config.home_dir);
    defer if (expanded_home) |expanded| allocator.free(expanded);
    const input_path = expanded_home orelse normalized;

    var resolved = if (std.fs.path.isAbsolute(input_path))
        try std.fs.path.resolve(allocator, &.{input_path})
    else
        try std.fs.path.resolve(allocator, &.{ config.cwd, input_path });
    if (kind == .existing) {
        resolved = resolveExistingVariant(allocator, io, resolved) catch |err| {
            allocator.free(resolved);
            return err;
        };
    }
    errdefer allocator.free(resolved);

    if (!config.allow_paths_outside_cwd) {
        const canonical_cwd = try std.Io.Dir.realPathFileAlloc(.cwd(), io, config.cwd, allocator);
        defer allocator.free(canonical_cwd);
        const canonical_path = switch (kind) {
            .existing => try std.Io.Dir.realPathFileAlloc(.cwd(), io, resolved, allocator),
            .creatable => try canonicalExistingParent(allocator, io, resolved),
        };
        defer allocator.free(canonical_path);
        if (!isPathInside(canonical_cwd, canonical_path)) return error.PathOutsideCwd;
    }
    return resolved;
}

fn expandHomePath(allocator: std.mem.Allocator, path: []const u8, home_dir_raw: ?[]const u8) !?[]u8 {
    if (path.len == 0 or path[0] != '~') return null;
    if (path.len > 1 and !std.fs.path.isSep(path[1])) return null;
    const home_dir = trimTrailingPathSeparators(home_dir_raw orelse return null);
    if (home_dir.len == 0) return null;
    const suffix = if (path.len == 1) "" else path[1..];
    const expanded = try std.fmt.allocPrint(allocator, "{s}{s}", .{ home_dir, suffix });
    errdefer allocator.free(expanded);
    if (expanded.len == 0 or expanded.len > max_path_bytes) return error.InvalidToolArguments;
    return expanded;
}

fn trimTrailingPathSeparators(path: []const u8) []const u8 {
    var end = path.len;
    while (end > 1 and std.fs.path.isSep(path[end - 1])) : (end -= 1) {}
    return path[0..end];
}

fn normalizeInputPath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    if (path.len == 0 or path.len > max_path_bytes) return error.InvalidToolArguments;
    const stripped = if (path[0] == '@') path[1..] else path;
    if (stripped.len == 0) return error.InvalidToolArguments;

    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var index: usize = 0;
    while (index < stripped.len) {
        if (unicodeSpaceLen(stripped[index..])) |len| {
            try out.writer.writeByte(' ');
            index += len;
        } else {
            try out.writer.writeByte(stripped[index]);
            index += 1;
        }
    }
    const normalized = try out.toOwnedSlice();
    if (normalized.len == 0 or normalized.len > max_path_bytes) {
        allocator.free(normalized);
        return error.InvalidToolArguments;
    }
    return normalized;
}

fn macOsScreenshotPathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    var index: usize = 0;
    while (index < path.len) {
        if (index + 4 <= path.len and
            path[index] == ' ' and
            path[index + 3] == '.' and
            (std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "AM") or
                std.ascii.eqlIgnoreCase(path[index + 1 .. index + 3], "PM")))
        {
            try out.writer.writeAll("\xe2\x80\xaf");
            try out.writer.writeAll(path[index + 1 .. index + 4]);
            index += 4;
            changed = true;
        } else {
            try out.writer.writeByte(path[index]);
            index += 1;
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

const NfdMapping = struct {
    composed: []const u8,
    decomposed: []const u8,
};

const latin1_nfd_mappings = [_]NfdMapping{
    .{ .composed = "À", .decomposed = "A\u{300}" },
    .{ .composed = "Á", .decomposed = "A\u{301}" },
    .{ .composed = "Â", .decomposed = "A\u{302}" },
    .{ .composed = "Ã", .decomposed = "A\u{303}" },
    .{ .composed = "Ä", .decomposed = "A\u{308}" },
    .{ .composed = "Å", .decomposed = "A\u{30a}" },
    .{ .composed = "Ç", .decomposed = "C\u{327}" },
    .{ .composed = "È", .decomposed = "E\u{300}" },
    .{ .composed = "É", .decomposed = "E\u{301}" },
    .{ .composed = "Ê", .decomposed = "E\u{302}" },
    .{ .composed = "Ë", .decomposed = "E\u{308}" },
    .{ .composed = "Ì", .decomposed = "I\u{300}" },
    .{ .composed = "Í", .decomposed = "I\u{301}" },
    .{ .composed = "Î", .decomposed = "I\u{302}" },
    .{ .composed = "Ï", .decomposed = "I\u{308}" },
    .{ .composed = "Ñ", .decomposed = "N\u{303}" },
    .{ .composed = "Ò", .decomposed = "O\u{300}" },
    .{ .composed = "Ó", .decomposed = "O\u{301}" },
    .{ .composed = "Ô", .decomposed = "O\u{302}" },
    .{ .composed = "Õ", .decomposed = "O\u{303}" },
    .{ .composed = "Ö", .decomposed = "O\u{308}" },
    .{ .composed = "Ù", .decomposed = "U\u{300}" },
    .{ .composed = "Ú", .decomposed = "U\u{301}" },
    .{ .composed = "Û", .decomposed = "U\u{302}" },
    .{ .composed = "Ü", .decomposed = "U\u{308}" },
    .{ .composed = "Ý", .decomposed = "Y\u{301}" },
    .{ .composed = "à", .decomposed = "a\u{300}" },
    .{ .composed = "á", .decomposed = "a\u{301}" },
    .{ .composed = "â", .decomposed = "a\u{302}" },
    .{ .composed = "ã", .decomposed = "a\u{303}" },
    .{ .composed = "ä", .decomposed = "a\u{308}" },
    .{ .composed = "å", .decomposed = "a\u{30a}" },
    .{ .composed = "ç", .decomposed = "c\u{327}" },
    .{ .composed = "è", .decomposed = "e\u{300}" },
    .{ .composed = "é", .decomposed = "e\u{301}" },
    .{ .composed = "ê", .decomposed = "e\u{302}" },
    .{ .composed = "ë", .decomposed = "e\u{308}" },
    .{ .composed = "ì", .decomposed = "i\u{300}" },
    .{ .composed = "í", .decomposed = "i\u{301}" },
    .{ .composed = "î", .decomposed = "i\u{302}" },
    .{ .composed = "ï", .decomposed = "i\u{308}" },
    .{ .composed = "ñ", .decomposed = "n\u{303}" },
    .{ .composed = "ò", .decomposed = "o\u{300}" },
    .{ .composed = "ó", .decomposed = "o\u{301}" },
    .{ .composed = "ô", .decomposed = "o\u{302}" },
    .{ .composed = "õ", .decomposed = "o\u{303}" },
    .{ .composed = "ö", .decomposed = "o\u{308}" },
    .{ .composed = "ù", .decomposed = "u\u{300}" },
    .{ .composed = "ú", .decomposed = "u\u{301}" },
    .{ .composed = "û", .decomposed = "u\u{302}" },
    .{ .composed = "ü", .decomposed = "u\u{308}" },
    .{ .composed = "ý", .decomposed = "y\u{301}" },
    .{ .composed = "ÿ", .decomposed = "y\u{308}" },
};

fn nfdLatin1PathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    var index: usize = 0;
    while (index < path.len) {
        for (latin1_nfd_mappings) |mapping| {
            if (std.mem.startsWith(u8, path[index..], mapping.composed)) {
                try out.writer.writeAll(mapping.decomposed);
                index += mapping.composed.len;
                changed = true;
                break;
            }
        } else {
            try out.writer.writeByte(path[index]);
            index += 1;
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

fn curlyQuotePathVariant(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    errdefer out.deinit();
    var changed = false;
    for (path) |byte| {
        if (byte == '\'') {
            try out.writer.writeAll("\xe2\x80\x99");
            changed = true;
        } else {
            try out.writer.writeByte(byte);
        }
    }
    if (!changed) {
        out.deinit();
        return null;
    }
    const variant = try out.toOwnedSlice();
    return variant;
}

fn unicodeSpaceLen(bytes: []const u8) ?usize {
    const spaces = [_][]const u8{
        "\xc2\xa0", // no-break space
        "\xe1\x9a\x80", // ogham space mark
        "\xe2\x80\x80", // en quad
        "\xe2\x80\x81", // em quad
        "\xe2\x80\x82", // en space
        "\xe2\x80\x83", // em space
        "\xe2\x80\x84", // three-per-em space
        "\xe2\x80\x85", // four-per-em space
        "\xe2\x80\x86", // six-per-em space
        "\xe2\x80\x87", // figure space
        "\xe2\x80\x88", // punctuation space
        "\xe2\x80\x89", // thin space
        "\xe2\x80\x8a", // hair space
        "\xe2\x80\xaf", // narrow no-break space
        "\xe2\x81\x9f", // medium mathematical space
        "\xe3\x80\x80", // ideographic space
    };
    for (spaces) |space| {
        if (std.mem.startsWith(u8, bytes, space)) return space.len;
    }
    return null;
}

fn canonicalExistingParent(allocator: std.mem.Allocator, io: std.Io, path: []const u8) ![:0]u8 {
    var candidate = path;
    while (true) {
        return std.Io.Dir.realPathFileAlloc(.cwd(), io, candidate, allocator) catch |err| switch (err) {
            error.FileNotFound => {
                candidate = std.fs.path.dirname(candidate) orelse return err;
                continue;
            },
            else => return err,
        };
    }
}

fn isPathInside(raw_cwd: []const u8, path: []const u8) bool {
    var cwd = raw_cwd;
    while (cwd.len > 1 and std.fs.path.isSep(cwd[cwd.len - 1])) cwd = cwd[0 .. cwd.len - 1];
    if (!std.mem.startsWith(u8, path, cwd)) return false;
    if (cwd.len == 1 and std.fs.path.isSep(cwd[0])) return true;
    if (path.len == cwd.len) return true;
    return std.fs.path.isSep(path[cwd.len]);
}

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
        return std.fs.path.join(allocator, &.{ self.global_dir, sessions_dir_name, encoded });
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

test "existing path resolution tries common macOS filename variants" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "repo");
    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/shot\xe2\x80\xafAM.png", .data = "x" });
    const screenshot = try ToolPaths.resolveExisting(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "shot AM.png");
    defer std.testing.allocator.free(screenshot);
    try std.testing.expect(std.mem.endsWith(u8, screenshot, "shot\xe2\x80\xafAM.png"));

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/it\xe2\x80\x99s.txt", .data = "x" });
    const curly = try ToolPaths.resolveExisting(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "it's.txt");
    defer std.testing.allocator.free(curly);
    try std.testing.expect(std.mem.endsWith(u8, curly, "it\xe2\x80\x99s.txt"));

    const nfd = (try nfdLatin1PathVariant(std.testing.allocator, "Café.txt")).?;
    defer std.testing.allocator.free(nfd);
    try std.testing.expectEqualStrings("Cafe\u{301}.txt", nfd);
    try std.testing.expect((try nfdLatin1PathVariant(std.testing.allocator, "Cafe.txt")) == null);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/Cafe\u{301}.txt", .data = "x" });
    const decomposed = try ToolPaths.resolveExisting(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "Café.txt");
    defer std.testing.allocator.free(decomposed);
    try std.testing.expect(std.mem.endsWith(u8, decomposed, "Café.txt") or
        std.mem.endsWith(u8, decomposed, "Cafe\u{301}.txt"));

    const nfd_curly = (try curlyQuotePathVariant(std.testing.allocator, "Cafe\u{301}'s.txt")).?;
    defer std.testing.allocator.free(nfd_curly);
    try std.testing.expectEqualStrings("Cafe\u{301}\xe2\x80\x99s.txt", nfd_curly);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "repo/Cafe\u{301}\xe2\x80\x99s.txt", .data = "x" });
    const combined = try ToolPaths.resolveExisting(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
    }, "Café's.txt");
    defer std.testing.allocator.free(combined);
    try std.testing.expect(std.mem.endsWith(u8, combined, "Café's.txt") or
        std.mem.endsWith(u8, combined, "Cafe\u{301}\xe2\x80\x99s.txt"));
}

test "path containment requires separator boundary" {
    try std.testing.expect(isPathInside("/repo", "/repo"));
    try std.testing.expect(isPathInside("/repo", "/repo/file"));
    try std.testing.expect(!isPathInside("/repo", "/repo2/file"));
}

test "home expansion is explicit and bounded" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "home/project");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "home/project/file.txt", .data = "x" });
    try tmp.dir.createDirPath(std.testing.io, "repo");

    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPathFile(std.testing.io, ".", &root_buffer);
    const root = root_buffer[0..root_len];
    var repo_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const repo_len = try tmp.dir.realPathFile(std.testing.io, "repo", &repo_buffer);
    const repo = repo_buffer[0..repo_len];

    var home_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const home = try std.fmt.bufPrint(&home_buffer, "{s}/home/", .{root});
    const resolved = try ToolPaths.resolveExisting(std.testing.allocator, std.testing.io, .{
        .cwd = repo,
        .allow_paths_outside_cwd = true,
        .home_dir = home,
    }, "~/project/file.txt");
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "home/project/file.txt"));

    const literal = try normalizeInputPath(std.testing.allocator, "~other/file.txt");
    defer std.testing.allocator.free(literal);
    try std.testing.expectEqualStrings("~other/file.txt", literal);
}

test "path normalization strips one at sign and maps unicode spaces" {
    const normalized = try normalizeInputPath(std.testing.allocator, "@@dir\xc2\xa0name/\xe2\x80\x89file");
    defer std.testing.allocator.free(normalized);
    try std.testing.expectEqualStrings("@dir name/ file", normalized);
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, ""));
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, "@"));

    const oversized = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try std.testing.expectError(error.InvalidToolArguments, normalizeInputPath(std.testing.allocator, oversized));
}

test "path containment rejects symlink escapes" {
    if (builtin.os.tag == .windows) return error.SkipZigTest;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo");
    try tmp.dir.createDirPath(std.testing.io, "other");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "other/file.txt", .data = "outside" });
    try tmp.dir.symLink(std.testing.io, "../other", "repo/link", .{});

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    try std.testing.expectError(error.PathOutsideCwd, ToolPaths.resolveExisting(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "link/file.txt",
    ));
    try std.testing.expectError(error.PathOutsideCwd, ToolPaths.resolveCreatable(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "link/new.txt",
    ));
}

test "creatable path containment uses nearest existing parent" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.createDirPath(std.testing.io, "repo/dir");
    try tmp.dir.createDirPath(std.testing.io, "other");

    var cwd_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const cwd_len = try tmp.dir.realPathFile(std.testing.io, "repo", &cwd_buffer);
    const cwd = cwd_buffer[0..cwd_len];

    const resolved = try ToolPaths.resolveCreatable(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "dir/new/file.txt",
    );
    defer std.testing.allocator.free(resolved);
    try std.testing.expect(std.mem.endsWith(u8, resolved, "dir/new/file.txt"));

    try std.testing.expectError(error.PathOutsideCwd, ToolPaths.resolveCreatable(
        std.testing.allocator,
        std.testing.io,
        .{ .cwd = cwd },
        "../other/new.txt",
    ));
}
