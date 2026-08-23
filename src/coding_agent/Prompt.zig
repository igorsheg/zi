const std = @import("std");
const ProjectTrust = @import("ProjectTrust.zig");
const ZiPaths = @import("ZiPaths.zig");

pub const BoundedTextFile = struct {
    const read_buffer_bytes = 8192;

    pub const Outcome = union(enum) {
        missing,
        loaded: []const u8,
        too_large,
        invalid,
        unsafe,
        unreadable,
    };

    pub const Error = error{
        OutOfMemory,
        Cancelled,
    };

    /// Loaded bytes belong to `allocator`.
    pub fn loadOptional(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        file_name: []const u8,
        max_bytes: usize,
    ) Error!Outcome {
        const path_stat = directory.statFile(io, file_name, .{ .follow_symlinks = false }) catch |failure| {
            return switch (failure) {
                error.FileNotFound, error.NotDir => .missing,
                error.Canceled => error.Cancelled,
                else => .unreadable,
            };
        };
        if (path_stat.kind != .file) return .unsafe;
        if (path_stat.size > max_bytes) return .too_large;

        const file = directory.openFile(io, file_name, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |failure| return switch (failure) {
            error.FileNotFound, error.NotDir => .missing,
            error.Canceled => error.Cancelled,
            error.SymLinkLoop, error.IsDir => .unsafe,
            else => .unreadable,
        };
        defer file.close(io);
        const opened_stat = file.stat(io) catch return .unreadable;
        if (opened_stat.kind != .file) return .unsafe;
        if (opened_stat.size > max_bytes) return .too_large;

        const read_limit = std.math.add(usize, max_bytes, 1) catch return .too_large;
        var read_buffer: [read_buffer_bytes]u8 = undefined;
        var reader = file.reader(io, &read_buffer);
        const text = reader.interface.allocRemaining(
            allocator,
            .limited(read_limit),
        ) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.StreamTooLong => .too_large,
            else => .unreadable,
        };
        if (text.len > max_bytes) {
            allocator.free(text);
            return .too_large;
        }
        if (!std.unicode.utf8ValidateSlice(text) or std.mem.findScalar(u8, text, 0) != null) {
            allocator.free(text);
            return .invalid;
        }
        return .{ .loaded = text };
    }

    test "bounded text files classify optional external text" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();

        try std.testing.expect(try loadOptional(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "missing.md",
            16,
        ) == .missing);

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "context.md",
            .data = "context",
        });
        const loaded = try loadOptional(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "context.md",
            16,
        );
        defer std.testing.allocator.free(loaded.loaded);
        try std.testing.expectEqualStrings("context", loaded.loaded);

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "context.md",
            .data = "invalid\xff",
        });
        try std.testing.expect(try loadOptional(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "context.md",
            16,
        ) == .invalid);

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "context.md",
            .data = "seventeen bytes!!",
        });
        try std.testing.expect(try loadOptional(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "context.md",
            16,
        ) == .too_large);

        try temporary.dir.deleteFile(std.testing.io, "context.md");
        try temporary.dir.createDir(std.testing.io, "context.md", .default_dir);
        try std.testing.expect(try loadOptional(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "context.md",
            16,
        ) == .unsafe);
    }

    fn loadAndFree(allocator: std.mem.Allocator, directory: std.Io.Dir) !void {
        const outcome = try loadOptional(allocator, std.testing.io, directory, "context.md", 16);
        switch (outcome) {
            .loaded => |text| allocator.free(text),
            else => return error.UnexpectedOutcome,
        }
    }

    test "bounded text files settle every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "context.md",
            .data = "context",
        });

        try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndFree, .{temporary.dir});
    }
};

pub const ContextFiles = struct {
    // Candidate precedence and broad-to-narrow inheritance follow pi's context-file contract.
    const candidate_names = [_][]const u8{
        "AGENTS.md",
        "AGENTS.MD",
        "CLAUDE.md",
        "CLAUDE.MD",
    };
    // These match fx's bounded defaults for project instruction files and their aggregate.
    const max_file_bytes = 64 * 1024;
    const max_total_bytes = 128 * 1024;
    const max_context_files = 128;
    const max_ancestor_directories = 1024;

    pub const Section = struct {
        path: []const u8,
        text: []const u8,
    };

    pub const Error = error{
        OutOfMemory,
        Cancelled,
        ContextFileTooLarge,
        ContextFilesTooLarge,
        TooManyContextFiles,
        ContextTraversalTooDeep,
        InvalidContextFile,
        UnsafeContextFile,
        ContextFileReadFailed,
    };

    arena: std.heap.ArenaAllocator,
    section_values: []const Section,

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
    ) Error!ContextFiles {
        return loadWithin(allocator, io, paths, null);
    }

    fn loadWithin(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        ancestor_root: ?[]const u8,
    ) Error!ContextFiles {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        var collected_sections: std.ArrayList(Section) = .empty;
        var total_bytes: usize = 0;

        if (try loadFromDirectory(owned, io, paths.global_agent)) |section| {
            try appendUnique(owned, &collected_sections, &total_bytes, section);
        }

        var ancestors: std.ArrayList([]const u8) = .empty;
        var current = paths.cwd;
        while (true) {
            if (ancestors.items.len >= max_ancestor_directories) return error.ContextTraversalTooDeep;
            try ancestors.append(owned, current);
            if (ancestor_root) |root| {
                if (std.mem.eql(u8, current, root)) break;
            }
            const parent = std.fs.path.dirname(current) orelse break;
            if (std.mem.eql(u8, parent, current)) break;
            current = parent;
        }
        var index = ancestors.items.len;
        while (index > 0) {
            index -= 1;
            if (try loadFromDirectory(owned, io, ancestors.items[index])) |section| {
                try appendUnique(owned, &collected_sections, &total_bytes, section);
            }
        }

        const section_values = try collected_sections.toOwnedSlice(owned);
        return .{
            .arena = arena,
            .section_values = section_values,
        };
    }

    pub fn deinit(self: *ContextFiles) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn sections(self: *const ContextFiles) []const Section {
        return self.section_values;
    }

    fn loadFromDirectory(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory_path: []const u8,
    ) Error!?Section {
        const directory = std.Io.Dir.openDirAbsolute(io, directory_path, .{}) catch |failure| {
            return switch (failure) {
                error.FileNotFound => null,
                error.Canceled => error.Cancelled,
                else => error.ContextFileReadFailed,
            };
        };
        defer directory.close(io);
        for (candidate_names) |file_name| {
            const outcome = try BoundedTextFile.loadOptional(
                allocator,
                io,
                directory,
                file_name,
                max_file_bytes,
            );
            switch (outcome) {
                .missing => continue,
                .loaded => |text| {
                    const path = try std.fs.path.resolve(allocator, &.{ directory_path, file_name });
                    if (path.len > ZiPaths.max_path_bytes) return error.ContextFileReadFailed;
                    return .{ .path = path, .text = text };
                },
                .too_large => return error.ContextFileTooLarge,
                .invalid => return error.InvalidContextFile,
                .unsafe => return error.UnsafeContextFile,
                .unreadable => return error.ContextFileReadFailed,
            }
        }
        return null;
    }

    fn appendUnique(
        allocator: std.mem.Allocator,
        collected_sections: *std.ArrayList(Section),
        total_bytes: *usize,
        section: Section,
    ) Error!void {
        for (collected_sections.items) |existing| {
            if (std.mem.eql(u8, existing.path, section.path)) return;
        }
        if (collected_sections.items.len >= max_context_files) return error.TooManyContextFiles;
        if (section.text.len > max_total_bytes - total_bytes.*) return error.ContextFilesTooLarge;
        total_bytes.* += section.text.len;
        try collected_sections.append(allocator, section);
    }

    fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
        const length = try temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..length];
    }

    fn pathInRoot(root: []const u8, parts: []const []const u8) ![]u8 {
        var all_parts: std.ArrayList([]const u8) = .empty;
        defer all_parts.deinit(std.testing.allocator);
        try all_parts.append(std.testing.allocator, root);
        try all_parts.appendSlice(std.testing.allocator, parts);
        return std.fs.path.resolve(std.testing.allocator, all_parts.items);
    }

    test "context files own global and broad-to-narrow ancestor instructions" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.createDirPath(std.testing.io, "workspace/project/sub");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/AGENTS.md",
            .data = "Global instructions.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "workspace/CLAUDE.md",
            .data = "Workspace instructions.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "workspace/project/AGENTS.md",
            .data = "Project instructions.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "workspace/project/CLAUDE.md",
            .data = "Shadowed Claude instructions.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "workspace/project/sub/AGENTS.MD",
            .data = "Subdirectory instructions.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const cwd = try pathInRoot(root, &.{ "workspace", "project", "sub" });
        defer std.testing.allocator.free(cwd);
        var paths = try ZiPaths.init(std.testing.allocator, cwd, root);
        defer paths.deinit();

        var context = try loadWithin(std.testing.allocator, std.testing.io, &paths, root);
        defer context.deinit();
        const loaded = context.sections();
        try std.testing.expectEqual(@as(usize, 4), loaded.len);
        try std.testing.expectEqualStrings("Global instructions.", loaded[0].text);
        try std.testing.expect(std.mem.endsWith(u8, loaded[0].path, "/.zi/agent/AGENTS.md"));
        try std.testing.expectEqualStrings("Workspace instructions.", loaded[1].text);
        try std.testing.expectEqualStrings("Project instructions.", loaded[2].text);
        try std.testing.expectEqualStrings("Subdirectory instructions.", loaded[3].text);
    }

    test "context files distinguish missing sources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();

        var context = try loadWithin(std.testing.allocator, std.testing.io, &paths, root);
        defer context.deinit();
        try std.testing.expectEqual(@as(usize, 0), context.sections().len);
    }

    test "context files reject invalid excessive and unsafe sources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "AGENTS.md",
            .data = "invalid\x00context",
        });
        try std.testing.expectError(
            error.InvalidContextFile,
            loadWithin(std.testing.allocator, std.testing.io, &paths, root),
        );

        const oversized = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
        defer std.testing.allocator.free(oversized);
        @memset(oversized, 'x');
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "AGENTS.md",
            .data = oversized,
        });
        try std.testing.expectError(
            error.ContextFileTooLarge,
            loadWithin(std.testing.allocator, std.testing.io, &paths, root),
        );

        try temporary.dir.deleteFile(std.testing.io, "AGENTS.md");
        try temporary.dir.createDir(std.testing.io, "AGENTS.md", .default_dir);
        try std.testing.expectError(
            error.UnsafeContextFile,
            loadWithin(std.testing.allocator, std.testing.io, &paths, root),
        );
    }

    test "context files bound aggregate ancestor instructions" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, "one/two");
        const content = try std.testing.allocator.alloc(u8, 48 * 1024);
        defer std.testing.allocator.free(content);
        @memset(content, 'x');
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "AGENTS.md", .data = content });
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one/AGENTS.md", .data = content });
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = "one/two/AGENTS.md", .data = content });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const cwd = try pathInRoot(root, &.{ "one", "two" });
        defer std.testing.allocator.free(cwd);
        var paths = try ZiPaths.init(std.testing.allocator, cwd, root);
        defer paths.deinit();

        try std.testing.expectError(
            error.ContextFilesTooLarge,
            loadWithin(std.testing.allocator, std.testing.io, &paths, root),
        );
    }

    const AllocationContext = struct {
        paths: *const ZiPaths,
        ancestor_root: []const u8,
    };

    fn loadAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
        var files = try loadWithin(allocator, std.testing.io, context.paths, context.ancestor_root);
        files.deinit();
    }

    test "context files settle every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/AGENTS.md",
            .data = "Global instructions.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "AGENTS.md",
            .data = "Project instructions.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        var context: AllocationContext = .{ .paths = &paths, .ancestor_root = root };

        try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndDeinit, .{&context});
    }
};

pub const PromptFiles = struct {
    const system_file_name = "SYSTEM.md";
    const append_file_name = "APPEND_SYSTEM.md";
    const max_file_bytes = 1024 * 1024;

    pub const Requested = struct {
        system: bool = false,
        append: bool = false,
    };

    pub const Error = error{
        OutOfMemory,
        Cancelled,
        PromptFileTooLarge,
        InvalidPromptFile,
        UnsafePromptFile,
        PromptFileReadFailed,
    };

    arena: std.heap.ArenaAllocator,
    system_text: ?[]const u8,
    append_text: ?[]const u8,

    pub fn hasProjectSources(
        io: std.Io,
        paths: *const ZiPaths,
        requested: Requested,
    ) Error!bool {
        const directory = std.Io.Dir.openDirAbsolute(io, paths.project, .{
            .follow_symlinks = false,
        }) catch |failure| return switch (failure) {
            error.FileNotFound => false,
            error.Canceled => error.Cancelled,
            error.NotDir, error.SymLinkLoop => true,
            else => true,
        };
        defer directory.close(io);
        if (requested.system and try sourceExists(io, directory, system_file_name)) return true;
        if (requested.append and try sourceExists(io, directory, append_file_name)) return true;
        return false;
    }

    pub fn load(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
        requested: Requested,
        project_trust: ProjectTrust.Decision,
    ) Error!PromptFiles {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();

        const project_directory: ?std.Io.Dir = if (project_trust == .trusted)
            try openOptionalDirectory(io, paths.project, false)
        else
            null;
        defer if (project_directory) |directory| directory.close(io);
        var system_text: ?[]const u8 = if (requested.system and project_directory != null)
            try loadOptionalText(owned, io, project_directory.?, system_file_name)
        else
            null;
        var append_text: ?[]const u8 = if (requested.append and project_directory != null)
            try loadOptionalText(owned, io, project_directory.?, append_file_name)
        else
            null;

        const needs_global_system = requested.system and system_text == null;
        const needs_global_append = requested.append and append_text == null;
        if (needs_global_system or needs_global_append) {
            const global_directory = try openOptionalDirectory(io, paths.global_agent, true);
            if (global_directory) |directory| {
                defer directory.close(io);
                if (needs_global_system) {
                    system_text = try loadOptionalText(owned, io, directory, system_file_name);
                }
                if (needs_global_append) {
                    append_text = try loadOptionalText(owned, io, directory, append_file_name);
                }
            }
        }
        return .{
            .arena = arena,
            .system_text = system_text,
            .append_text = append_text,
        };
    }

    pub fn deinit(self: *PromptFiles) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn system(self: *const PromptFiles) ?[]const u8 {
        return self.system_text;
    }

    pub fn append(self: *const PromptFiles) ?[]const u8 {
        return self.append_text;
    }

    fn openOptionalDirectory(
        io: std.Io,
        path: []const u8,
        follow_symlinks: bool,
    ) Error!?std.Io.Dir {
        return std.Io.Dir.openDirAbsolute(io, path, .{ .follow_symlinks = follow_symlinks }) catch |failure| {
            return switch (failure) {
                error.FileNotFound => null,
                error.Canceled => error.Cancelled,
                error.NotDir, error.SymLinkLoop => error.UnsafePromptFile,
                else => error.PromptFileReadFailed,
            };
        };
    }

    fn sourceExists(io: std.Io, directory: std.Io.Dir, path: []const u8) Error!bool {
        const file = directory.openFile(io, path, .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
        }) catch |failure| return switch (failure) {
            error.FileNotFound => false,
            error.Canceled => error.Cancelled,
            else => true,
        };
        file.close(io);
        return true;
    }

    fn loadOptionalText(
        allocator: std.mem.Allocator,
        io: std.Io,
        directory: std.Io.Dir,
        file_name: []const u8,
    ) Error!?[]const u8 {
        const outcome = try BoundedTextFile.loadOptional(
            allocator,
            io,
            directory,
            file_name,
            max_file_bytes,
        );
        return switch (outcome) {
            .missing => null,
            .loaded => |text| text,
            .too_large => error.PromptFileTooLarge,
            .invalid => error.InvalidPromptFile,
            .unsafe => error.UnsafePromptFile,
            .unreadable => error.PromptFileReadFailed,
        };
    }

    fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
        const length = try temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..length];
    }

    fn testPaths(temporary: *std.testing.TmpDir, buffer: []u8) !ZiPaths {
        const root = try temporaryPath(temporary, buffer);
        return ZiPaths.init(std.testing.allocator, root, root);
    }

    test "prompt files load requested global text and own its bytes" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Global base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/APPEND_SYSTEM.md",
            .data = "Global rules.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();

        var files = try load(std.testing.allocator, std.testing.io, &paths, .{
            .system = true,
            .append = true,
        }, .untrusted);
        defer files.deinit();
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Changed.",
        });

        try std.testing.expectEqualStrings("Global base.", files.system().?);
        try std.testing.expectEqualStrings("Global rules.", files.append().?);
    }

    test "prompt files distinguish absent and unrequested sources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Ignored base.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();

        var files = try load(std.testing.allocator, std.testing.io, &paths, .{ .append = true }, .untrusted);
        defer files.deinit();
        try std.testing.expect(files.system() == null);
        try std.testing.expect(files.append() == null);
    }

    test "project prompt source detection is role-aware and treats unsafe roots as present" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();
        try std.testing.expect(try hasProjectSources(std.testing.io, &paths, .{ .system = true }));
        try std.testing.expect(!try hasProjectSources(std.testing.io, &paths, .{ .append = true }));

        try temporary.dir.deleteTree(std.testing.io, ".zi");
        try temporary.dir.writeFile(std.testing.io, .{ .sub_path = ".zi", .data = "unsafe" });
        try std.testing.expect(try hasProjectSources(std.testing.io, &paths, .{ .system = true }));
    }

    test "trusted project prompt files shadow global sources independently" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Global base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/APPEND_SYSTEM.md",
            .data = "Global rules.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/APPEND_SYSTEM.md",
            .data = "Project rules.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();

        var project = try load(std.testing.allocator, std.testing.io, &paths, .{
            .system = true,
            .append = true,
        }, .trusted);
        try std.testing.expectEqualStrings("Project base.", project.system().?);
        try std.testing.expectEqualStrings("Project rules.", project.append().?);
        project.deinit();

        try temporary.dir.deleteFile(std.testing.io, ".zi/APPEND_SYSTEM.md");
        var partial = try load(std.testing.allocator, std.testing.io, &paths, .{
            .system = true,
            .append = true,
        }, .trusted);
        try std.testing.expectEqualStrings("Project base.", partial.system().?);
        try std.testing.expectEqualStrings("Global rules.", partial.append().?);
        partial.deinit();

        try temporary.dir.deleteFile(std.testing.io, ".zi/SYSTEM.md");
        try temporary.dir.createDir(std.testing.io, ".zi/SYSTEM.md", .default_dir);
        var untrusted = try load(std.testing.allocator, std.testing.io, &paths, .{
            .system = true,
            .append = true,
        }, .untrusted);
        defer untrusted.deinit();
        try std.testing.expectEqualStrings("Global base.", untrusted.system().?);
        try std.testing.expectEqualStrings("Global rules.", untrusted.append().?);
    }

    test "trusted project prompt files prevent reads from shadowed global sources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent/SYSTEM.md");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();

        var files = try load(
            std.testing.allocator,
            std.testing.io,
            &paths,
            .{ .system = true },
            .trusted,
        );
        defer files.deinit();
        try std.testing.expectEqualStrings("Project base.", files.system().?);
    }

    test "trusted project prompt files reject a linked project configuration root" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, "home/.zi/agent");
        try temporary.dir.createDir(std.testing.io, "workspace", .default_dir);
        try temporary.dir.createDir(std.testing.io, "outside", .default_dir);
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "home/.zi/agent/SYSTEM.md",
            .data = "Global base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = "outside/SYSTEM.md",
            .data = "Linked project base.",
        });
        try temporary.dir.symLink(
            std.testing.io,
            "../outside",
            "workspace/.zi",
            .{ .is_directory = true },
        );
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const cwd = try std.fs.path.resolve(std.testing.allocator, &.{ root, "workspace" });
        defer std.testing.allocator.free(cwd);
        const home = try std.fs.path.resolve(std.testing.allocator, &.{ root, "home" });
        defer std.testing.allocator.free(home);
        var paths = try ZiPaths.init(std.testing.allocator, cwd, home);
        defer paths.deinit();

        try std.testing.expectError(
            error.UnsafePromptFile,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .trusted),
        );
        var untrusted = try load(
            std.testing.allocator,
            std.testing.io,
            &paths,
            .{ .system = true },
            .untrusted,
        );
        defer untrusted.deinit();
        try std.testing.expectEqualStrings("Global base.", untrusted.system().?);
    }

    test "prompt files reject invalid excessive and non-regular sources" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();

        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "invalid\xff",
        });
        try std.testing.expectError(
            error.InvalidPromptFile,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
        );
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "invalid\x00text",
        });
        try std.testing.expectError(
            error.InvalidPromptFile,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
        );

        const oversized = try std.testing.allocator.alloc(u8, max_file_bytes + 1);
        defer std.testing.allocator.free(oversized);
        @memset(oversized, 'x');
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = oversized,
        });
        try std.testing.expectError(
            error.PromptFileTooLarge,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
        );

        try temporary.dir.deleteFile(std.testing.io, ".zi/agent/SYSTEM.md");
        try temporary.dir.createDir(std.testing.io, ".zi/agent/SYSTEM.md", .default_dir);
        try std.testing.expectError(
            error.UnsafePromptFile,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
        );

        try temporary.dir.deleteTree(std.testing.io, ".zi/agent/SYSTEM.md");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/target.md",
            .data = "Linked base.",
        });
        try temporary.dir.symLink(
            std.testing.io,
            "target.md",
            ".zi/agent/SYSTEM.md",
            .{},
        );
        try std.testing.expectError(
            error.UnsafePromptFile,
            load(std.testing.allocator, std.testing.io, &paths, .{ .system = true }, .untrusted),
        );
    }

    const AllocationContext = struct {
        paths: *const ZiPaths,
    };

    fn loadAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
        var files = try load(allocator, std.testing.io, context.paths, .{
            .system = true,
            .append = true,
        }, .trusted);
        files.deinit();
    }

    test "prompt files settle every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/SYSTEM.md",
            .data = "Global base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/agent/APPEND_SYSTEM.md",
            .data = "Global rules.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/SYSTEM.md",
            .data = "Project base.",
        });
        try temporary.dir.writeFile(std.testing.io, .{
            .sub_path = ".zi/APPEND_SYSTEM.md",
            .data = "Project rules.",
        });
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        var paths = try testPaths(&temporary, &root_buffer);
        defer paths.deinit();
        var context: AllocationContext = .{ .paths = &paths };

        try std.testing.checkAllAllocationFailures(std.testing.allocator, loadAndDeinit, .{&context});
    }
};

pub const SystemPrompt = struct {
    const max_prompt_bytes = 1024 * 1024;

    const builtin_base =
        \\You are Zi, an autonomous coding agent that completes software engineering tasks.
        \\Your goal is to complete the user's request using the tools available in this session.
        \\
        \\<work_policy>
        \\- Keep every explicit requirement in view until it is completed, superseded by the user,
        \\  or blocked. State blockers plainly.
        \\- Match the user's intent. Implement clear action requests, and answer questions or reviews
        \\  without making unsolicited changes.
        \\- Inspect relevant files before drawing conclusions or editing code.
        \\- Keep changes scoped to the request and follow the repository's existing conventions.
        \\- Claim work is complete, fixed, or tested only when tool output supports the claim.
        \\  Otherwise state what remains unverified.
        \\</work_policy>
        \\
        \\<tool_calling>
        \\- Use `read` instead of cat, sed, or guessing file contents. Continue truncated reads with offset.
        \\- Read an existing file before editing it. Use `edit` for precise changes, combine disjoint
        \\  changes to one file in one call, keep each old text small but unique and exact, and never
        \\  overlap replacements.
        \\- Use `write` only for new files or complete rewrites.
        \\- Use `bash` for builds, tests, repository inspection, and commands. Bash calls are
        \\  non-interactive and cannot create managed background jobs.
        \\</tool_calling>
        \\
        \\<communication>
        \\Communicate directly and concisely in complete sentences. Lead with the answer.
        \\The final response must stand alone for a reader who has not seen tool calls. State what changed,
        \\what was verified, and any remaining blocker.
        \\Use GitHub-flavored Markdown when it improves readability. Show file paths and commands clearly.
        \\</communication>
    ;

    const environment_before = "\n\n<environment>\n<working_directory>";
    const environment_after = "</working_directory>\n</environment>";
    const context_before =
        "\n\n<project_context>\n" ++
        "Project-specific instructions and guidelines, ordered from broadest to narrowest scope:\n";
    const context_section_before = "\n<project_instructions path=\"";
    const context_path_after = "\">\n";
    const context_section_after = "\n</project_instructions>\n";
    const context_after = "</project_context>";
    const rules_before = "\n\n<human_rules>\n";
    const rules_between = "\n\n";
    const rules_after = "\n</human_rules>";

    pub const Base = union(enum) {
        builtin,
        custom: []const u8,
    };

    pub const ContextSection = struct {
        path: []const u8,
        text: []const u8,
    };

    pub const Composition = struct {
        base: Base = .builtin,
        context_sections: []const ContextSection = &.{},
        rules: []const []const u8 = &.{},
    };

    pub const Policy = union(enum) {
        verbatim: []const u8,
        composed: Composition,
    };

    pub const Config = struct {
        working_directory: []const u8 = ".",
        policy: Policy = .{ .composed = .{} },
    };

    pub const Error = error{
        OutOfMemory,
        InvalidSystemPrompt,
        SystemPromptTooLarge,
    };

    arena: std.heap.ArenaAllocator,
    text_value: []const u8,
    instruction_values: []const []const u8,

    pub fn init(allocator: std.mem.Allocator, config: Config) Error!SystemPrompt {
        try validateText(config.working_directory);

        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const text_value = switch (config.policy) {
            .composed => |composition| try render(owned, config.working_directory, composition),
            .verbatim => |replacement| block: {
                try validateText(replacement);
                if (replacement.len > max_prompt_bytes) return error.SystemPromptTooLarge;
                break :block try owned.dupe(u8, replacement);
            },
        };
        const instruction_values = try owned.alloc([]const u8, 1);
        instruction_values[0] = text_value;
        return .{
            .arena = arena,
            .text_value = text_value,
            .instruction_values = instruction_values,
        };
    }

    pub fn deinit(self: *SystemPrompt) void {
        self.arena.deinit();
        self.* = undefined;
    }

    pub fn text(self: *const SystemPrompt) []const u8 {
        return self.text_value;
    }

    /// The model receives one canonical prompt so provider encoders cannot assign
    /// different roles or separators to individual policy fragments.
    pub fn instructions(self: *const SystemPrompt) []const []const u8 {
        return self.instruction_values;
    }

    fn render(
        allocator: std.mem.Allocator,
        working_directory: []const u8,
        composition: Composition,
    ) Error![]const u8 {
        const base = switch (composition.base) {
            .builtin => builtin_base,
            .custom => |value| block: {
                try validateText(value);
                break :block value;
            },
        };
        for (composition.context_sections) |section| {
            try validateText(section.path);
            try validateText(section.text);
        }
        for (composition.rules) |value| try validateText(value);

        var length: usize = 0;
        try addLength(&length, base.len);
        try addLength(&length, environment_before.len);
        try addLength(&length, try escapedTextLength(working_directory));
        try addLength(&length, environment_after.len);
        if (composition.context_sections.len > 0) {
            try addLength(&length, context_before.len);
            for (composition.context_sections) |section| {
                try addLength(&length, context_section_before.len);
                try addLength(&length, try escapedAttributeLength(section.path));
                try addLength(&length, context_path_after.len);
                try addLength(&length, try escapedTextLength(section.text));
                try addLength(&length, context_section_after.len);
            }
            try addLength(&length, context_after.len);
        }
        if (composition.rules.len > 0) {
            try addLength(&length, rules_before.len);
            for (composition.rules, 0..) |value, index| {
                if (index > 0) try addLength(&length, rules_between.len);
                try addLength(&length, value.len);
            }
            try addLength(&length, rules_after.len);
        }

        var output = std.Io.Writer.Allocating.initCapacity(allocator, length) catch
            return error.OutOfMemory;
        defer output.deinit();
        output.writer.writeAll(base) catch return error.OutOfMemory;
        output.writer.writeAll(environment_before) catch return error.OutOfMemory;
        try writeEscapedText(&output.writer, working_directory);
        output.writer.writeAll(environment_after) catch return error.OutOfMemory;
        if (composition.context_sections.len > 0) {
            output.writer.writeAll(context_before) catch return error.OutOfMemory;
            for (composition.context_sections) |section| {
                output.writer.writeAll(context_section_before) catch return error.OutOfMemory;
                try writeEscapedAttribute(&output.writer, section.path);
                output.writer.writeAll(context_path_after) catch return error.OutOfMemory;
                try writeEscapedText(&output.writer, section.text);
                output.writer.writeAll(context_section_after) catch return error.OutOfMemory;
            }
            output.writer.writeAll(context_after) catch return error.OutOfMemory;
        }
        if (composition.rules.len > 0) {
            output.writer.writeAll(rules_before) catch return error.OutOfMemory;
            for (composition.rules, 0..) |value, index| {
                if (index > 0) output.writer.writeAll(rules_between) catch return error.OutOfMemory;
                output.writer.writeAll(value) catch return error.OutOfMemory;
            }
            output.writer.writeAll(rules_after) catch return error.OutOfMemory;
        }
        std.debug.assert(output.written().len == length);
        return output.toOwnedSlice() catch return error.OutOfMemory;
    }

    fn validateText(value: []const u8) error{InvalidSystemPrompt}!void {
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidSystemPrompt;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidSystemPrompt;
    }

    fn addLength(total: *usize, amount: usize) error{SystemPromptTooLarge}!void {
        if (amount > max_prompt_bytes - total.*) return error.SystemPromptTooLarge;
        total.* += amount;
    }

    fn escapedTextLength(value: []const u8) error{SystemPromptTooLarge}!usize {
        var length: usize = 0;
        for (value) |byte| try addLength(&length, switch (byte) {
            '&' => "&amp;".len,
            '<' => "&lt;".len,
            '>' => "&gt;".len,
            else => 1,
        });
        return length;
    }

    fn escapedAttributeLength(value: []const u8) error{SystemPromptTooLarge}!usize {
        var length: usize = 0;
        for (value) |byte| try addLength(&length, switch (byte) {
            '&' => "&amp;".len,
            '<' => "&lt;".len,
            '>' => "&gt;".len,
            '"' => "&quot;".len,
            '\'' => "&apos;".len,
            else => 1,
        });
        return length;
    }

    fn writeEscapedText(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
        for (value) |byte| switch (byte) {
            '&' => writer.writeAll("&amp;") catch return error.OutOfMemory,
            '<' => writer.writeAll("&lt;") catch return error.OutOfMemory,
            '>' => writer.writeAll("&gt;") catch return error.OutOfMemory,
            else => writer.writeByte(byte) catch return error.OutOfMemory,
        };
    }

    fn writeEscapedAttribute(writer: *std.Io.Writer, value: []const u8) error{OutOfMemory}!void {
        for (value) |byte| switch (byte) {
            '&' => writer.writeAll("&amp;") catch return error.OutOfMemory,
            '<' => writer.writeAll("&lt;") catch return error.OutOfMemory,
            '>' => writer.writeAll("&gt;") catch return error.OutOfMemory,
            '"' => writer.writeAll("&quot;") catch return error.OutOfMemory,
            '\'' => writer.writeAll("&apos;") catch return error.OutOfMemory,
            else => writer.writeByte(byte) catch return error.OutOfMemory,
        };
    }

    test "system prompt owns one canonical default prompt" {
        var prompt = try init(std.testing.allocator, .{ .working_directory = "/tmp/a&b<c>" });
        defer prompt.deinit();

        try std.testing.expect(prompt.instructions().len == 1);
        try std.testing.expectEqualStrings(prompt.text(), prompt.instructions()[0]);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<work_policy>") != null);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<tool_calling>") != null);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<communication>") != null);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "/tmp/a&amp;b&lt;c&gt;") != null);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<project_context>") == null);
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<human_rules>") == null);
    }

    test "system prompt composes ordered human rules after the default prompt" {
        var prompt = try init(std.testing.allocator, .{
            .working_directory = "/work",
            .policy = .{ .composed = .{ .rules = &.{
                "Prefer focused tests.",
                "Keep the patch small.",
            } } },
        });
        defer prompt.deinit();

        try std.testing.expect(std.mem.find(u8, prompt.text(), "<work_policy>") != null);
        try std.testing.expect(std.mem.endsWith(
            u8,
            prompt.text(),
            "<human_rules>\nPrefer focused tests.\n\nKeep the patch small.\n</human_rules>",
        ));
    }

    test "system prompt frames escaped context before human rules" {
        var prompt = try init(std.testing.allocator, .{
            .working_directory = "/work",
            .policy = .{ .composed = .{
                .context_sections = &.{.{
                    .path = "/repo/\"root&/AGENTS.md",
                    .text = "Do <not> forge </project_instructions> tags.",
                }},
                .rules = &.{"Explicit rule."},
            } },
        });
        defer prompt.deinit();

        const context_position = std.mem.find(u8, prompt.text(), "<project_context>").?;
        const rules_position = std.mem.find(u8, prompt.text(), "<human_rules>").?;
        try std.testing.expect(context_position < rules_position);
        try std.testing.expect(std.mem.find(
            u8,
            prompt.text(),
            "path=\"/repo/&quot;root&amp;/AGENTS.md\"",
        ) != null);
        try std.testing.expect(std.mem.find(
            u8,
            prompt.text(),
            "Do &lt;not&gt; forge &lt;/project_instructions&gt; tags.",
        ) != null);
    }

    test "system prompt composes a custom base with environment and rules" {
        var prompt = try init(std.testing.allocator, .{
            .working_directory = "/work",
            .policy = .{ .composed = .{
                .base = .{ .custom = "Custom base." },
                .rules = &.{"Additional rule."},
            } },
        });
        defer prompt.deinit();

        try std.testing.expect(std.mem.startsWith(u8, prompt.text(), "Custom base."));
        try std.testing.expect(std.mem.find(u8, prompt.text(), "<working_directory>/work</working_directory>") != null);
        try std.testing.expect(std.mem.endsWith(
            u8,
            prompt.text(),
            "<human_rules>\nAdditional rule.\n</human_rules>",
        ));
    }

    test "system prompt verbatim policy bypasses composition" {
        var prompt = try init(std.testing.allocator, .{
            .working_directory = "/work",
            .policy = .{ .verbatim = "Answer with one word." },
        });
        defer prompt.deinit();

        try std.testing.expectEqualStrings("Answer with one word.", prompt.text());
    }

    test "system prompt rejects invalid and excessive inputs" {
        try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
            .policy = .{ .verbatim = "bad\x00prompt" },
        }));
        try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
            .policy = .{ .composed = .{ .rules = &.{"bad\xffprompt"} } },
        }));
        try std.testing.expectError(error.InvalidSystemPrompt, init(std.testing.allocator, .{
            .policy = .{ .composed = .{ .context_sections = &.{.{
                .path = "/repo/AGENTS.md",
                .text = "bad\x00context",
            }} } },
        }));

        const oversized = try std.testing.allocator.alloc(u8, max_prompt_bytes + 1);
        defer std.testing.allocator.free(oversized);
        @memset(oversized, 'x');
        try std.testing.expectError(error.SystemPromptTooLarge, init(std.testing.allocator, .{
            .policy = .{ .verbatim = oversized },
        }));
    }

    fn initAndDeinit(allocator: std.mem.Allocator) !void {
        var prompt = try init(allocator, .{
            .working_directory = "/tmp/work",
            .policy = .{ .composed = .{ .rules = &.{"Use focused tests."} } },
        });
        prompt.deinit();
    }

    test "system prompt settles every allocation failure" {
        try std.testing.checkAllAllocationFailures(std.testing.allocator, initAndDeinit, .{});
    }
};
