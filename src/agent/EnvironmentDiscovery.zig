const std = @import("std");
const Context = @import("Context.zig");
const GuidanceDiscovery = @import("GuidanceDiscovery.zig");
const text = @import("../text/root.zig");

pub const Inputs = struct {
    /// Absolute process working directory. No process state is read.
    cwd: []const u8,
    /// Absolute HOME used for display collapsing and retained in absolute form.
    home: ?[]const u8 = null,
    /// Already collected provider-neutral operating system description.
    os_description: []const u8,
    /// Already resolved command shell. This module performs no shell lookup.
    command_shell: []const u8,
    model: ?[]const u8 = null,
    /// Optional caller snapshot. `.discover` performs the bounded filesystem search.
    project_root: Context.ProjectRoot = .discover,
};

pub const Error = error{
    OutOfMemory,
    InvalidCwd,
    InvalidHome,
    FactsTooLarge,
};

/// Injected command availability lookup. The implementation must outlive `discover`.
/// Calls are synchronous and names are borrowed only for the duration of each call.
/// Availability is advisory: lookup and permission failures are reported as `false`.
pub const ToolProbe = struct {
    context: *anyopaque,
    probe_fn: *const fn (*anyopaque, []const u8) bool,

    pub fn available(self: ToolProbe, name: []const u8) bool {
        return self.probe_fn(self.context, name);
    }

    pub fn from(implementation: anytype) ToolProbe {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("ToolProbe.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn available(context: *anyopaque, name: []const u8) bool {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.available(name);
            }
        };
        return .{ .context = implementation, .probe_fn = Adapter.available };
    }
};

/// Allocator-owned, move-only environment result. Every fact slice borrows
/// storage owned by this value and remains stable until `deinit`.
pub const OwnedFacts = struct {
    facts: Context.EnvironmentFacts,

    pub fn environmentFacts(self: *const OwnedFacts) Context.EnvironmentFacts {
        return self.facts;
    }

    pub fn deinit(self: *OwnedFacts, allocator: std.mem.Allocator) void {
        allocator.free(self.facts.working_directory);
        if (self.facts.home_directory) |value| allocator.free(value);
        allocator.free(self.facts.operating_system);
        allocator.free(self.facts.command_shell);
        if (self.facts.model) |value| allocator.free(value);
        if (self.facts.git_repository_root) |value| allocator.free(value);
        self.* = undefined;
    }
};

const Collector = struct {
    allocator: std.mem.Allocator,
    retained_bytes: usize = 0,

    fn sanitize(self: *Collector, input: []const u8) Error![]u8 {
        const output = text.Utf8.sanitize(
            self.allocator,
            input,
            Context.max_prompt_bytes -| self.retained_bytes,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResultTooLarge => return error.FactsTooLarge,
        };
        self.retained_bytes += output.len;
        return output;
    }

    fn sanitizeDisplayPath(self: *Collector, path: []const u8, home: ?[]const u8) Error![]u8 {
        const display = try GuidanceDiscovery.collapseHome(self.allocator, path, home);
        defer self.allocator.free(display);
        return self.sanitize(display);
    }
};

/// Collects only supplied facts, `.git` stat markers, and injected tool results.
/// It does not read process environment, PATH, shell state, or OS metadata.
pub fn discover(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    tool_probe: ToolProbe,
) Error!OwnedFacts {
    const cwd = try normalizedAbsolute(inputs.cwd, error.InvalidCwd);
    const home = if (inputs.home) |value|
        if (value.len == 0) null else try normalizedHome(value)
    else
        null;

    var collector: Collector = .{ .allocator = allocator };
    const working_directory = try collector.sanitizeDisplayPath(cwd, home);
    errdefer allocator.free(working_directory);

    const home_directory = if (home) |value| try collector.sanitize(value) else null;
    errdefer if (home_directory) |value| allocator.free(value);

    const operating_system = try collector.sanitize(inputs.os_description);
    errdefer allocator.free(operating_system);
    const command_shell = try collector.sanitize(inputs.command_shell);
    errdefer allocator.free(command_shell);

    const model = if (inputs.model) |value|
        if (value.len == 0) null else try collector.sanitize(value)
    else
        null;
    errdefer if (model) |value| allocator.free(value);

    const discovered_root = switch (inputs.project_root) {
        .discover => try GuidanceDiscovery.findProjectRoot(allocator, io, cwd),
        .missing, .found => null,
    };
    defer if (discovered_root) |value| allocator.free(value);
    const raw_root: ?[]const u8 = switch (inputs.project_root) {
        .discover => discovered_root,
        .missing => null,
        .found => |value| value,
    };
    const git_repository_root = if (raw_root) |value|
        try collector.sanitizeDisplayPath(value, home)
    else
        null;
    errdefer if (git_repository_root) |value| allocator.free(value);

    var tools: Context.ToolFacts = .{};
    tools.rg = tool_probe.available("rg");
    tools.fd = tool_probe.available("fd");
    tools.jq = tool_probe.available("jq");
    tools.gh = tool_probe.available("gh");
    tools.python3 = tool_probe.available("python3");
    tools.node = tool_probe.available("node");
    tools.magick = tool_probe.available("magick");

    return .{ .facts = .{
        .working_directory = working_directory,
        .home_directory = home_directory,
        .operating_system = operating_system,
        .command_shell = command_shell,
        .model = model,
        .git_repository_root = git_repository_root,
        .tools = tools,
    } };
}

fn normalizedAbsolute(path: []const u8, invalid: Error) Error![]const u8 {
    if (path.len == 0 or path[0] != '/' or std.mem.indexOfScalar(u8, path, 0) != null) return invalid;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

fn normalizedHome(path: []const u8) Error![]const u8 {
    if (path.len == 0 or path[0] != '/') return error.InvalidHome;
    var end = path.len;
    while (end > 1 and path[end - 1] == '/') end -= 1;
    return path[0..end];
}

const SpyProbe = struct {
    seen: [7][]const u8 = undefined,
    count: usize = 0,

    fn available(self: *SpyProbe, name: []const u8) bool {
        self.seen[self.count] = name;
        self.count += 1;
        return std.mem.eql(u8, name, "rg") or std.mem.eql(u8, name, "python3");
    }
};

fn temporaryRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

test "home collapse repository root model omission and canonical tool order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.createDir(io, "a", .default_dir);
    try tmp.dir.createDir(io, "a/b", .default_dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const home = try temporaryRoot(&tmp, &path_buffer);
    const cwd = try std.fmt.allocPrint(std.testing.allocator, "{s}/a/b", .{home});
    defer std.testing.allocator.free(cwd);
    var spy: SpyProbe = .{};

    var result = try discover(std.testing.allocator, io, .{
        .cwd = cwd,
        .home = home,
        .os_description = "Test OS",
        .command_shell = "/bin/sh",
    }, ToolProbe.from(&spy));
    defer result.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("~/a/b", result.facts.working_directory);
    try std.testing.expectEqualStrings(home, result.facts.home_directory.?);
    try std.testing.expectEqualStrings("~", result.facts.git_repository_root.?);
    try std.testing.expect(result.facts.model == null);
    try std.testing.expect(result.facts.tools.rg);
    try std.testing.expect(result.facts.tools.python3);
    try std.testing.expect(!result.facts.tools.fd);
    const expected = [_][]const u8{ "rg", "fd", "jq", "gh", "python3", "node", "magick" };
    try std.testing.expectEqual(@as(usize, expected.len), spy.count);
    for (expected, spy.seen) |name, seen| try std.testing.expectEqualStrings(name, seen);
}

test "home collapse requires a component boundary and no repository is null" {
    const io = std.testing.io;
    var root_buffer: [128]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, "/tmp/zi-environment-{x}", .{@intFromPtr(&root_buffer)});
    try std.Io.Dir.createDirAbsolute(io, root, .default_dir);
    defer std.Io.Dir.deleteTree(.cwd(), io, root) catch @panic("test cleanup failed");
    const home = try std.fmt.allocPrint(std.testing.allocator, "{s}/home", .{root});
    defer std.testing.allocator.free(home);
    const cwd = try std.fmt.allocPrint(std.testing.allocator, "{s}/home-other", .{root});
    defer std.testing.allocator.free(cwd);
    try std.Io.Dir.createDirAbsolute(io, cwd, .default_dir);
    var spy: SpyProbe = .{};
    var result = try discover(std.testing.allocator, io, .{
        .cwd = cwd,
        .home = home,
        .os_description = "OS",
        .command_shell = "sh",
    }, ToolProbe.from(&spy));
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(cwd, result.facts.working_directory);
    try std.testing.expect(result.facts.git_repository_root == null);
}

test "all retained strings are sanitized and copied" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try temporaryRoot(&tmp, &path_buffer);
    var home = [_]u8{ '/', 'h', 0, 0xff };
    var os = [_]u8{ 'O', 0, 0xff };
    var shell = [_]u8{ 's', 0xff };
    var model = [_]u8{ 'm', 0 };
    var spy: SpyProbe = .{};
    var result = try discover(std.testing.allocator, std.testing.io, .{
        .cwd = cwd,
        .home = &home,
        .os_description = &os,
        .command_shell = &shell,
        .model = &model,
    }, ToolProbe.from(&spy));
    defer result.deinit(std.testing.allocator);
    @memset(&home, 'x');
    @memset(&os, 'x');
    @memset(&shell, 'x');
    @memset(&model, 'x');
    try std.testing.expectEqualStrings("/h\xef\xbf\xbd\xef\xbf\xbd", result.facts.home_directory.?);
    try std.testing.expectEqualStrings("O\xef\xbf\xbd\xef\xbf\xbd", result.facts.operating_system);
    try std.testing.expectEqualStrings("s\xef\xbf\xbd", result.facts.command_shell);
    try std.testing.expectEqualStrings("m\xef\xbf\xbd", result.facts.model.?);
}

test "git root search is limited to 64 candidates" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    var relative: std.ArrayList(u8) = .empty;
    defer relative.deinit(std.testing.allocator);
    for (0..63) |index| {
        if (index != 0) try relative.append(std.testing.allocator, '/');
        try relative.append(std.testing.allocator, 'd');
    }
    try tmp.dir.createDirPath(io, relative.items);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const within = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, relative.items });
    defer std.testing.allocator.free(within);
    var spy: SpyProbe = .{};
    var found = try discover(std.testing.allocator, io, .{
        .cwd = within,
        .os_description = "OS",
        .command_shell = "sh",
    }, ToolProbe.from(&spy));
    defer found.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(root, found.facts.git_repository_root.?);

    try relative.appendSlice(std.testing.allocator, "/d");
    try tmp.dir.createDirPath(io, relative.items);
    const beyond = try std.fmt.allocPrint(std.testing.allocator, "{s}/{s}", .{ root, relative.items });
    defer std.testing.allocator.free(beyond);
    spy = .{};
    var missing = try discover(std.testing.allocator, io, .{
        .cwd = beyond,
        .os_description = "OS",
        .command_shell = "sh",
    }, ToolProbe.from(&spy));
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing.facts.git_repository_root == null);
}

test "invalid explicit paths and aggregate bound are reported" {
    var spy: SpyProbe = .{};
    try std.testing.expectError(error.InvalidCwd, discover(std.testing.allocator, std.testing.io, .{
        .cwd = "relative",
        .os_description = "OS",
        .command_shell = "sh",
    }, ToolProbe.from(&spy)));
    const too_large = [_]u8{'x'} ** (Context.max_prompt_bytes + 1);
    try std.testing.expectError(error.FactsTooLarge, discover(std.testing.allocator, std.testing.io, .{
        .cwd = "/",
        .os_description = &too_large,
        .command_shell = "sh",
    }, ToolProbe.from(&spy)));
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = try temporaryRoot(&tmp, &path_buffer);
    var spy: SpyProbe = .{};
    var result = try discover(allocator, std.testing.io, .{
        .cwd = cwd,
        .home = cwd,
        .os_description = "Test OS",
        .command_shell = "/bin/sh",
        .model = "model",
    }, ToolProbe.from(&spy));
    result.deinit(allocator);
}

test "allocation failures do not leak" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}
