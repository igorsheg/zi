const std = @import("std");
const agent = @import("agent/root.zig");

pub const Context = agent.Context;
pub const EnvironmentDiscovery = agent.EnvironmentDiscovery;
pub const GuidanceDiscovery = agent.GuidanceDiscovery;
pub const SkillDiscovery = agent.SkillDiscovery;
pub const SystemPrompt = agent.SystemPrompt;

pub const Error = error{
    OutOfMemory,
    InvalidCwd,
    InvalidHome,
    InvalidPath,
    FactsTooLarge,
    TooManyEntries,
    PromptTooLarge,
    TooManyGuidanceFiles,
    TooManySkills,
    TooManyPresets,
};

/// All strings and preset facts are borrowed for the duration of `build`.
/// Discovery receives only these explicit paths and process facts; this type
/// performs no cwd, HOME, environment, or PATH lookup.
pub const Inputs = struct {
    raw: bool = false,
    base: SystemPrompt.Base = .default,
    append: ?[]const u8 = null,
    features: Context.Features = .{},
    tool_facts: Context.ToolFacts = .{},
    environment: EnvironmentDiscovery.Inputs,
    guidance: GuidanceDiscovery.Inputs,
    skills: SkillDiscovery.Inputs,
    presets: []const Context.Preset = &.{},
};

/// Allocator-owned, move-only final prompt. Call `deinit` exactly once.
pub const OwnedPrompt = SystemPrompt.OwnedPrompt;

const FactsProbe = struct {
    facts: Context.ToolFacts,

    pub fn available(self: *FactsProbe, name: []const u8) bool {
        if (std.mem.eql(u8, name, "rg")) return self.facts.rg;
        if (std.mem.eql(u8, name, "fd")) return self.facts.fd;
        if (std.mem.eql(u8, name, "jq")) return self.facts.jq;
        if (std.mem.eql(u8, name, "gh")) return self.facts.gh;
        if (std.mem.eql(u8, name, "python3")) return self.facts.python3;
        if (std.mem.eql(u8, name, "node")) return self.facts.node;
        if (std.mem.eql(u8, name, "magick")) return self.facts.magick;
        return false;
    }
};

/// Discovers context and builds the provider-facing system prompt.
///
/// `raw` and `Base.none` are exact short-circuits: no discovery, filesystem
/// access, tool probe, context rendering, or allocation is performed. Discovery
/// results are destroyed as soon as their rendered context has been copied.
/// A non-null result owns the only storage that survives this call.
pub fn build(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
) Error!?OwnedPrompt {
    if (inputs.raw or inputs.base == .none) return null;

    var project_root: ?[]u8 = null;
    defer if (project_root) |root_path| allocator.free(root_path);
    if (inputs.features.environment or inputs.features.project) {
        if (inputs.environment.cwd.len == 0 or inputs.environment.cwd[0] != '/' or
            std.mem.indexOfScalar(u8, inputs.environment.cwd, 0) != null)
        {
            return error.InvalidCwd;
        }
        project_root = try GuidanceDiscovery.findProjectRoot(allocator, io, inputs.environment.cwd);
    }
    const root_snapshot: Context.ProjectRoot = if (project_root) |root_path|
        .{ .found = root_path }
    else
        .missing;
    var environment_inputs = inputs.environment;
    environment_inputs.project_root = root_snapshot;
    var guidance_inputs = inputs.guidance;
    guidance_inputs.project_root = root_snapshot;

    var environment: ?EnvironmentDiscovery.OwnedFacts = null;
    defer if (environment) |*owned| owned.deinit(allocator);
    var guidance: ?GuidanceDiscovery.OwnedFacts = null;
    defer if (guidance) |*owned| owned.deinit(allocator);
    var skills: ?SkillDiscovery.OwnedFacts = null;
    defer if (skills) |*owned| owned.deinit(allocator);

    var probe: FactsProbe = .{ .facts = inputs.tool_facts };
    if (inputs.features.environment) {
        environment = try EnvironmentDiscovery.discover(
            allocator,
            io,
            environment_inputs,
            EnvironmentDiscovery.ToolProbe.from(&probe),
        );
    }
    if (inputs.features.project) {
        guidance = try GuidanceDiscovery.discover(allocator, io, guidance_inputs);
    }
    if (inputs.features.skills) {
        skills = try SkillDiscovery.discover(allocator, io, inputs.skills);
    }

    var suffix = try Context.build(allocator, .{
        .features = inputs.features,
        .environment = if (environment) |*owned| owned.environmentFacts() else null,
        .guidance_files = if (guidance) |*owned| owned.guidanceFiles() else &.{},
        .skills = if (skills) |*owned| owned.skillFacts() else &.{},
        .presets = inputs.presets,
    });
    defer if (suffix) |*owned| owned.deinit(allocator);

    // SystemPrompt.build copies the suffix. The discovery owners and suffix are
    // all torn down by this function's defers before the final prompt escapes.
    return SystemPrompt.build(allocator, .{
        .base = inputs.base,
        .append = inputs.append,
        .suffix = if (suffix) |owned| owned.bytes else null,
    });
}

fn testingSecureOpen() agent.SecureOpen.Capability {
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

fn noContextInputs() Inputs {
    return .{
        .features = .{
            .tasks = false,
            .subagents = false,
            .environment = false,
            .project = false,
            .skills = false,
        },
        .environment = .{
            .cwd = "invalid",
            .os_description = "OS",
            .command_shell = "sh",
        },
        .guidance = .{ .secure_open = testingSecureOpen(), .cwd = "invalid" },
        .skills = .{ .secure_open = testingSecureOpen(), .cwd = "invalid", .home = "invalid" },
    };
}

fn temporaryRoot(tmp: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try tmp.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

fn writeRelative(dir: std.Io.Dir, path: []const u8, data: []const u8) !void {
    try dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

test "full assembly preserves base append and context section order" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    try tmp.dir.createDir(io, ".git", .default_dir);
    try tmp.dir.createDir(io, "config", .default_dir);
    try tmp.dir.createDir(io, ".agents", .default_dir);
    try tmp.dir.createDir(io, ".agents/skills", .default_dir);
    try tmp.dir.createDir(io, ".agents/skills/demo", .default_dir);
    try writeRelative(tmp.dir, "config/AGENTS.md", "global");
    try writeRelative(tmp.dir, "AGENTS.md", "project");
    try writeRelative(tmp.dir, ".agents/skills/demo/SKILL.md", "---\ndescription: demo skill\n---\n");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    const config_root = try std.fmt.allocPrint(std.testing.allocator, "{s}/config", .{root});
    defer std.testing.allocator.free(config_root);
    const presets = [_]Context.Preset{.{ .name = "review", .description = "review code" }};

    var result = (try build(std.testing.allocator, io, .{
        .base = .{ .custom = "base" },
        .append = "append",
        .tool_facts = .{ .rg = true },
        .environment = .{
            .cwd = root,
            .home = root,
            .os_description = "Test OS",
            .command_shell = "/bin/sh",
            .model = "test-model",
        },
        .guidance = .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root, .config_root = config_root },
        .skills = .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root, .config_root = config_root },
        .presets = &presets,
    })).?;
    defer result.deinit(std.testing.allocator);

    const expected = [_][]const u8{
        "base",
        "append",
        "# Background tasks",
        "# Subagents",
        "Presets (select with `--preset <name>`)",
        "# Environment",
        "# Project Context",
        "## ~/config/AGENTS.md",
        "## ~/AGENTS.md",
        "# Skills",
        "- demo: demo skill (~/.agents/skills/demo/SKILL.md)",
    };
    var previous: usize = 0;
    for (expected, 0..) |needle, index| {
        const position = std.mem.indexOfPos(u8, result.bytes, previous, needle) orelse
            return error.TestExpectedEqual;
        if (index != 0) try std.testing.expect(position > previous);
        previous = position + needle.len;
    }
}

test "raw and none short-circuit invalid discovery inputs and allocation" {
    var inputs = noContextInputs();
    inputs.raw = true;
    try std.testing.expect((try build(std.testing.failing_allocator, std.testing.io, inputs)) == null);
    inputs.raw = false;
    inputs.base = .none;
    try std.testing.expect((try build(std.testing.failing_allocator, std.testing.io, inputs)) == null);
}

test "empty base still emits append and discovered context" {
    var inputs = noContextInputs();
    inputs.base = .empty;
    inputs.append = "append";
    inputs.features.tasks = true;
    var result = (try build(std.testing.allocator, std.testing.io, inputs)).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.startsWith(u8, result.bytes, "append\n\n# Background tasks"));
}

test "missing optional roots are accepted" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    var result = (try build(std.testing.allocator, std.testing.io, .{
        .base = .empty,
        .features = .{ .tasks = false, .subagents = false },
        .environment = .{ .cwd = root, .os_description = "OS", .command_shell = "sh" },
        .guidance = .{ .secure_open = testingSecureOpen(), .cwd = root },
        .skills = .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root },
    })).?;
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "# Environment") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "# Project Context") == null);
    try std.testing.expect(std.mem.indexOf(u8, result.bytes, "# Skills") == null);
}

fn exerciseAllocationFailures(allocator: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);
    try writeRelative(tmp.dir, "AGENTS.md", "rules");
    var path_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const root = try temporaryRoot(&tmp, &path_buffer);
    var result = try build(allocator, std.testing.io, .{
        .base = .{ .custom = "base" },
        .append = "append",
        .environment = .{
            .cwd = root,
            .home = root,
            .os_description = "OS",
            .command_shell = "sh",
        },
        .guidance = .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root },
        .skills = .{ .secure_open = testingSecureOpen(), .cwd = root, .home = root },
    });
    defer if (result) |*owned| owned.deinit(allocator);
}

test "allocation failures clean discovery suffix and final prompt" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{},
    );
}

test "preset bounds are typed and final result owns borrowed prompt facts" {
    const presets = [_]Context.Preset{.{ .name = "p", .description = "d" }} **
        (Context.max_presets + 1);
    var bounded = noContextInputs();
    bounded.presets = &presets;
    try std.testing.expectError(
        error.TooManyPresets,
        build(std.testing.allocator, std.testing.io, bounded),
    );

    var base = [_]u8{ 'b', 'a', 's', 'e' };
    var append = [_]u8{ 'a', 'p', 'p' };
    var owned_inputs = noContextInputs();
    owned_inputs.base = .{ .custom = &base };
    owned_inputs.append = &append;
    var result = (try build(std.testing.allocator, std.testing.io, owned_inputs)).?;
    defer result.deinit(std.testing.allocator);
    @memset(&base, 'x');
    @memset(&append, 'x');
    try std.testing.expectEqualStrings("base\n\napp", result.bytes);
}
