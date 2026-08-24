const std = @import("std");
const Context = @import("Context.zig");
const SecureOpen = @import("SecureOpen.zig");
const text = @import("../text/root.zig");

pub const frontmatter_head_bytes: usize = 8192;
pub const description_input_bytes: usize = 1024;
pub const maximum_examined_entries: usize = 16 * 1024;

pub const Inputs = struct {
    secure_open: SecureOpen.Capability,
    /// Absolute, normalized process working directory. No process state is read.
    cwd: []const u8,
    /// Absolute home directory, used only to collapse model-facing paths to `~`.
    home: ?[]const u8 = null,
    /// Already-resolved absolute Zi configuration directory.
    config_root: ?[]const u8 = null,
};

pub const Error = error{
    OutOfMemory,
    InvalidCwd,
    InvalidHome,
    InvalidPath,
    FactsTooLarge,
    TooManyEntries,
};

/// Allocator-owned, move-only discovery result. Every skill slice borrows only
/// storage owned by this value. Call `deinit` exactly once.
pub const OwnedFacts = struct {
    skills: []Context.Skill,

    pub fn skillFacts(self: *const OwnedFacts) []const Context.Skill {
        return self.skills;
    }

    pub fn deinit(self: *OwnedFacts, allocator: std.mem.Allocator) void {
        for (self.skills) |skill| freeSkill(allocator, skill);
        allocator.free(self.skills);
        self.* = undefined;
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    home: ?[]const u8,
    secure_open: SecureOpen.Capability,
    skills: std.ArrayList(Context.Skill) = .empty,
    seen: std.StringHashMapUnmanaged(void) = .empty,
    retained_bytes: usize = 0,
    examined_entries: usize = 0,

    fn deinit(self: *Collector) void {
        self.seen.deinit(self.allocator);
        for (self.skills.items) |skill| freeSkill(self.allocator, skill);
        self.skills.deinit(self.allocator);
        self.* = undefined;
    }

    fn noteExamined(self: *Collector) Error!void {
        if (self.examined_entries == maximum_examined_entries) return error.TooManyEntries;
        self.examined_entries += 1;
    }

    fn scan(self: *Collector, root: []const u8) Error!void {
        var directory = std.Io.Dir.openDirAbsolute(self.io, root, .{ .iterate = true }) catch return;
        defer directory.close(self.io);

        var candidates: std.ArrayList([]u8) = .empty;
        defer {
            for (candidates.items) |name| self.allocator.free(name);
            candidates.deinit(self.allocator);
        }
        var candidate_bytes: usize = 0;
        var iterator = directory.iterate();
        while (iterator.next(self.io) catch return) |entry| {
            try self.noteExamined();
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (entry.name.len > Context.max_prompt_bytes -| candidate_bytes) {
                return error.FactsTooLarge;
            }
            const raw_name = try self.allocator.dupe(u8, entry.name);
            errdefer self.allocator.free(raw_name);
            try candidates.append(self.allocator, raw_name);
            candidate_bytes += raw_name.len;
        }
        std.mem.sort([]u8, candidates.items, {}, lessRawName);

        for (candidates.items) |raw_name| {
            const name = sanitizeBounded(self.allocator, raw_name, Context.max_prompt_bytes) catch |err| {
                return mapSanitizeError(err);
            };
            if (self.seen.contains(name)) {
                self.allocator.free(name);
                continue;
            }
            errdefer self.allocator.free(name);

            var skill_directory = directory.openDir(self.io, raw_name, .{
                .follow_symlinks = false,
            }) catch {
                self.allocator.free(name);
                continue;
            };
            defer skill_directory.close(self.io);
            const candidate = try readCandidate(
                self.allocator,
                self.io,
                self.secure_open,
                skill_directory,
            );
            if (candidate == null) {
                self.allocator.free(name);
                continue;
            }
            const description = candidate.?.description;
            errdefer if (description) |value| self.allocator.free(value);

            const skill_path = try skillPath(self.allocator, root, raw_name);
            defer self.allocator.free(skill_path);

            const collapsed = try collapseHome(self.allocator, skill_path, self.home);
            defer self.allocator.free(collapsed);
            const display_path = sanitizeBounded(
                self.allocator,
                collapsed,
                Context.max_prompt_bytes -| name.len,
            ) catch |err| return mapSanitizeError(err);
            errdefer self.allocator.free(display_path);

            const description_len = if (description) |value| value.len else 0;
            const added = name.len + display_path.len + description_len;
            try checkBounds(self.skills.items.len, self.retained_bytes, added);
            try self.seen.put(self.allocator, name, {});
            errdefer _ = self.seen.remove(name);
            try self.skills.append(self.allocator, .{
                .name = name,
                .display_path = display_path,
                .description = description,
            });
            self.retained_bytes += added;
        }
    }
};

/// Discovers `<cwd>/.agents/skills` before `<config_root>/skills`. Missing,
/// unreadable, non-regular, and symlinked directory or file candidates are
/// ignored. At most `maximum_examined_entries` directory entries are inspected
/// across both roots. No environment, rendering, or process lookup occurs.
pub fn discover(allocator: std.mem.Allocator, io: std.Io, inputs: Inputs) Error!OwnedFacts {
    const cwd = try normalizedAbsolute(inputs.cwd, error.InvalidCwd);
    const home = if (inputs.home) |value|
        try normalizedAbsolute(value, error.InvalidHome)
    else
        null;
    const config_root = if (inputs.config_root) |value|
        try normalizedAbsolute(value, error.InvalidPath)
    else
        null;

    var collector: Collector = .{
        .allocator = allocator,
        .io = io,
        .home = home,
        .secure_open = inputs.secure_open,
    };
    defer collector.deinit();

    const project_root = try joinTwo(allocator, cwd, ".agents/skills");
    defer allocator.free(project_root);
    try collector.scan(project_root);
    if (config_root) |root| {
        const global_root = try joinTwo(allocator, root, "skills");
        defer allocator.free(global_root);
        try collector.scan(global_root);
    }
    std.mem.sort(Context.Skill, collector.skills.items, {}, lessSkill);
    const skills = try collector.skills.toOwnedSlice(allocator);
    collector.skills = .empty;
    return .{ .skills = skills };
}

fn checkBounds(count: usize, retained_bytes: usize, added_bytes: usize) Error!void {
    if (count >= Context.max_skills) return error.FactsTooLarge;
    if (added_bytes > Context.max_prompt_bytes -| retained_bytes) return error.FactsTooLarge;
}

fn lessRawName(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessSkill(_: void, a: Context.Skill, b: Context.Skill) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

fn freeSkill(allocator: std.mem.Allocator, skill: Context.Skill) void {
    allocator.free(skill.name);
    allocator.free(skill.display_path);
    if (skill.description) |description| allocator.free(description);
}

fn mapSanitizeError(err: text.Utf8.Error) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResultTooLarge => error.FactsTooLarge,
    };
}

fn sanitizeBounded(
    allocator: std.mem.Allocator,
    input: []const u8,
    maximum: usize,
) text.Utf8.Error![]u8 {
    return text.Utf8.sanitize(allocator, input, maximum);
}

const Candidate = struct { description: ?[]u8 };

fn readCandidate(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    directory: std.Io.Dir,
) Error!?Candidate {
    // The no-follow stat avoids opening stable FIFOs and rejects a final
    // symlink. O_NONBLOCK and O_NOFOLLOW close replacement races.
    const named_stat = directory.statFile(io, "SKILL.md", .{ .follow_symlinks = false }) catch return null;
    if (named_stat.kind != .file) return null;
    var file = secure_open.openFile(io, directory, "SKILL.md") catch return null;
    defer file.close(io);
    const opened_stat = file.stat(io) catch return null;
    if (opened_stat.kind != .file) return null;
    var head: [frontmatter_head_bytes]u8 = undefined;
    const count = file.readPositionalAll(io, &head, 0) catch return null;
    const description = parseDescription(allocator, head[0..count]) catch |err| return mapSanitizeError(err);
    return .{ .description = description };
}

fn parseDescription(allocator: std.mem.Allocator, content: []const u8) text.Utf8.Error!?[]u8 {
    var position: usize = undefined;
    if (std.mem.startsWith(u8, content, "---\n")) {
        position = 4;
    } else if (std.mem.startsWith(u8, content, "---\r\n")) {
        position = 5;
    } else return null;

    while (position < content.len) {
        const newline = std.mem.indexOfScalarPos(u8, content, position, '\n') orelse content.len;
        const line = content[position..newline];
        if (std.mem.eql(u8, line, "---") or std.mem.eql(u8, line, "---\r")) return null;
        if (line.len > "description:".len and std.mem.startsWith(u8, line, "description:")) {
            var value = line["description:".len..];
            value = std.mem.trimStart(u8, value, " \t");
            value = std.mem.trimEnd(u8, value, " \t\r");
            if (value.len >= 2 and
                ((value[0] == '"' and value[value.len - 1] == '"') or
                    (value[0] == '\'' and value[value.len - 1] == '\'')))
            {
                value = value[1 .. value.len - 1];
            }
            if (value.len == 0) return null;
            const sanitized = try text.Utf8.sanitize(
                allocator,
                value[0..@min(value.len, description_input_bytes)],
                std.math.maxInt(usize),
            );
            return sanitized;
        }
        if (newline == content.len) break;
        position = newline + 1;
    }
    return null;
}

fn normalizedAbsolute(path: []const u8, invalid: Error) Error![]const u8 {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return invalid;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn joinTwo(allocator: std.mem.Allocator, root: []const u8, suffix: []const u8) error{OutOfMemory}![]u8 {
    return if (std.mem.eql(u8, root, "/"))
        std.fmt.allocPrint(allocator, "/{s}", .{suffix})
    else
        std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, suffix });
}

fn skillPath(allocator: std.mem.Allocator, root: []const u8, name: []const u8) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/SKILL.md", .{ root, name });
}

fn collapseHome(
    allocator: std.mem.Allocator,
    path: []const u8,
    optional_home: ?[]const u8,
) error{OutOfMemory}![]u8 {
    const home = optional_home orelse return allocator.dupe(u8, path);
    if (!std.mem.startsWith(u8, path, home) or
        (path.len != home.len and home.len != 1 and path[home.len] != '/'))
    {
        return allocator.dupe(u8, path);
    }
    if (path.len == home.len) return allocator.dupe(u8, "~");
    const suffix = if (home.len == 1) path else path[home.len..];
    return std.fmt.allocPrint(allocator, "~{s}", .{suffix});
}

fn testingSecureOpen() SecureOpen.Capability {
    const Adapter = struct {
        fn openFile(
            _: *anyopaque,
            _: std.Io,
            directory: std.Io.Dir,
            name: []const u8,
        ) anyerror!std.Io.File {
            const handle = try std.posix.openat(directory.handle, name, .{
                .ACCMODE = .RDONLY,
                .NONBLOCK = true,
                .CLOEXEC = true,
                .NOFOLLOW = true,
            }, 0);
            return .{ .handle = handle, .flags = .{ .nonblocking = true } };
        }
    };
    return .{ .context = undefined, .open_fn = Adapter.openFile };
}

fn temporaryRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeSkill(dir: std.Io.Dir, root: []const u8, name: []const u8, content: []const u8) !void {
    const folder = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, name });
    defer std.testing.allocator.free(folder);
    try dir.createDirPath(std.testing.io, folder);
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/SKILL.md", .{folder});
    defer std.testing.allocator.free(path);
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = content });
}

test "description parser accepts exact LF and CRLF frontmatter" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { input: []const u8, expected: ?[]const u8 }{
        .{ .input = "---\ndescription: hello  \n---\nbody", .expected = "hello" },
        .{ .input = "---\r\ndescription:\t'hello crlf'\r\n---\r\n", .expected = "hello crlf" },
        .{ .input = "---\ndescription: \"quoted\"\n---", .expected = "quoted" },
        .{ .input = "x---\ndescription: no\n---\n", .expected = null },
        .{ .input = "--- \ndescription: no\n---\n", .expected = null },
        .{ .input = "---\n description: no\n---\n", .expected = null },
        .{ .input = "---\nDescription: no\n---\n", .expected = null },
        .{ .input = "---\ndescription:\n---\n", .expected = null },
        .{ .input = "---\n--- \ndescription: still frontmatter\n---\n", .expected = "still frontmatter" },
        .{ .input = "---\n---\ndescription: after\n", .expected = null },
    };
    for (cases) |case| {
        const actual = try parseDescription(allocator, case.input);
        defer if (actual) |value| allocator.free(value);
        if (case.expected) |expected| {
            try std.testing.expectEqualStrings(expected, actual.?);
        } else try std.testing.expect(actual == null);
    }
}

test "description is byte capped before UTF-8 and NUL sanitation" {
    var input: [description_input_bytes + 64]u8 = undefined;
    @memset(&input, 'x');
    input[0] = 0;
    input[1] = 0xff;
    const prefix = "---\ndescription: ";
    var document: [prefix.len + input.len]u8 = undefined;
    @memcpy(document[0..prefix.len], prefix);
    @memcpy(document[prefix.len..], &input);
    const description = (try parseDescription(std.testing.allocator, &document)).?;
    defer std.testing.allocator.free(description);
    try std.testing.expectEqual(description_input_bytes + 4, description.len);
    try std.testing.expectEqualStrings("\xef\xbf\xbd\xef\xbf\xbd", description[0..6]);
}

test "project shadows global and result sorts while candidates are filtered" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try writeSkill(tmp.dir, ".agents/skills", "zeta", "plain body");
    try writeSkill(tmp.dir, ".agents/skills", "dup", "---\ndescription: project\n---\n");
    try writeSkill(tmp.dir, "config/skills", "dup", "---\ndescription: global\n---\n");
    try writeSkill(tmp.dir, "config/skills", "alpha", "---\ndescription: alpha\n---\n");
    try writeSkill(tmp.dir, ".agents/skills", ".hidden", "---\ndescription: hidden\n---\n");
    try tmp.dir.writeFile(io, .{ .sub_path = ".agents/skills/not-dir", .data = "x" });
    try tmp.dir.createDirPath(io, ".agents/skills/missing");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const config = try joinTwo(std.testing.allocator, root, "config");
    defer std.testing.allocator.free(config);

    var result = try discover(std.testing.allocator, io, .{
        .secure_open = testingSecureOpen(),
        .cwd = root,
        .home = root,
        .config_root = config,
    });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 3), result.skills.len);
    try std.testing.expectEqualStrings("alpha", result.skills[0].name);
    try std.testing.expectEqualStrings("dup", result.skills[1].name);
    try std.testing.expectEqualStrings("project", result.skills[1].description.?);
    try std.testing.expectEqualStrings("zeta", result.skills[2].name);
    try std.testing.expectEqualStrings("~/.agents/skills/dup/SKILL.md", result.skills[1].display_path);
    try std.testing.expect(result.skills[2].description == null);
}

test "skill count and aggregate retained bytes are bounded" {
    try checkBounds(Context.max_skills - 1, Context.max_prompt_bytes - 1, 1);
    try std.testing.expectError(
        error.FactsTooLarge,
        checkBounds(Context.max_skills, 0, 0),
    );
    try std.testing.expectError(
        error.FactsTooLarge,
        checkBounds(0, Context.max_prompt_bytes, 1),
    );
}

fn exerciseDiscoveryAllocations(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeSkill(tmp.dir, ".agents/skills", "one", "---\ndescription: one\n---\n");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    var result = try discover(allocator, std.testing.io, .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root });
    result.deinit(allocator);
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseDiscoveryAllocations, .{});
}

test "symlinked candidate directory and SKILL file are rejected" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDirPath(io, ".agents/skills");
    try tmp.dir.createDirPath(io, "actual-dir");
    try tmp.dir.writeFile(io, .{
        .sub_path = "actual-dir/SKILL.md",
        .data = "---\ndescription: linked directory\n---\n",
    });
    try tmp.dir.symLink(io, "../../actual-dir", ".agents/skills/dir-link", .{});
    try tmp.dir.createDirPath(io, ".agents/skills/file-link");
    try tmp.dir.writeFile(io, .{
        .sub_path = "actual-file",
        .data = "---\ndescription: linked file\n---\n",
    });
    try tmp.dir.symLink(io, "../../../actual-file", ".agents/skills/file-link/SKILL.md", .{});
    try tmp.dir.createDirPath(io, ".agents/skills/nonregular/SKILL.md");
    try writeSkill(tmp.dir, ".agents/skills", "regular", "---\ndescription: regular\n---\n");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);

    var result = try discover(std.testing.allocator, io, .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.skills.len);
    try std.testing.expectEqualStrings("regular", result.skills[0].name);
    try std.testing.expectEqualStrings("regular", result.skills[0].description.?);
}

test "only the first frontmatter head bytes are read" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const prefix = "---\n";
    const late = "description: too late\n---\n";
    var document: [frontmatter_head_bytes + late.len]u8 = undefined;
    @memcpy(document[0..prefix.len], prefix);
    @memset(document[prefix.len..frontmatter_head_bytes], 'x');
    @memcpy(document[frontmatter_head_bytes..], late);
    try writeSkill(tmp.dir, ".agents/skills", "head", &document);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);

    var result = try discover(std.testing.allocator, std.testing.io, .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root });
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), result.skills.len);
    try std.testing.expect(result.skills[0].description == null);
}

test "sanitized directory names define dedup identity and sanitized home path" {
    const allocator = std.testing.allocator;
    const first = try sanitizeBounded(allocator, "\xff", Context.max_prompt_bytes);
    defer allocator.free(first);
    const second = try sanitizeBounded(allocator, "\xfe", Context.max_prompt_bytes);
    defer allocator.free(second);
    try std.testing.expectEqualStrings("\xef\xbf\xbd", first);
    try std.testing.expectEqualStrings(first, second);

    var collector: Collector = .{
        .allocator = allocator,
        .io = std.testing.io,
        .home = "/home/me",
        .secure_open = testingSecureOpen(),
    };
    defer collector.skills.deinit(allocator);
    defer collector.seen.deinit(allocator);
    try collector.skills.append(allocator, .{
        .name = first,
        .display_path = "unused",
    });
    try collector.seen.put(allocator, first, {});
    try std.testing.expect(collector.seen.contains(second));

    const collapsed = try collapseHome(allocator, "/home/me/.agents/skills/\xff/SKILL.md", "/home/me");
    defer allocator.free(collapsed);
    const display = try sanitizeBounded(allocator, collapsed, Context.max_prompt_bytes);
    defer allocator.free(display);
    try std.testing.expectEqualStrings("~/.agents/skills/\xef\xbf\xbd/SKILL.md", display);
}

test "explicit paths must be absolute and normalized trailing slashes are accepted" {
    try std.testing.expectError(error.InvalidCwd, discover(
        std.testing.allocator,
        std.testing.io,
        .{ .secure_open = testingSecureOpen(), .cwd = "relative", .home = "/home" },
    ));
    try std.testing.expectError(error.InvalidHome, discover(
        std.testing.allocator,
        std.testing.io,
        .{ .secure_open = testingSecureOpen(), .cwd = "/tmp", .home = "" },
    ));
    try std.testing.expectError(error.InvalidPath, discover(
        std.testing.allocator,
        std.testing.io,
        .{ .secure_open = testingSecureOpen(), .cwd = "/tmp", .home = "/home", .config_root = "relative" },
    ));
}

test "examined entry work cap is exact" {
    var collector: Collector = .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .home = "/home",
        .secure_open = testingSecureOpen(),
        .examined_entries = maximum_examined_entries - 1,
    };
    defer collector.deinit();
    try collector.noteExamined();
    try std.testing.expectEqual(maximum_examined_entries, collector.examined_entries);
    try std.testing.expectError(error.TooManyEntries, collector.noteExamined());
}
