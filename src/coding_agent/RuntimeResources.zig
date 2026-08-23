const std = @import("std");
const ContextFiles = @import("ContextFiles.zig");
const ProjectTrust = @import("ProjectTrust.zig");
const ProjectTrustStore = @import("ProjectTrustStore.zig");
const PromptFiles = @import("PromptFiles.zig");
const SystemPrompt = @import("SystemPrompt.zig");
const SettingsStore = @import("SettingsStore.zig");
const ZiPaths = @import("ZiPaths.zig");

const RuntimeResources = @This();

pub const Error = error{
    OutOfMemory,
    InvalidProjectIdentity,
    ProjectIdentityUnavailable,
    InvalidProjectTrustFile,
    UnsupportedVersion,
    UnsafeProjectTrustStorage,
    ProjectTrustReadFailed,
    ProjectTrustLockFailed,
    ProjectTrustWriteFailed,
    ProjectTrustCommitIndeterminate,
    Cancelled,
    PromptFileTooLarge,
    InvalidPromptFile,
    UnsafePromptFile,
    PromptFileReadFailed,
    ContextFileTooLarge,
    ContextFilesTooLarge,
    TooManyContextFiles,
    ContextTraversalTooDeep,
    InvalidContextFile,
    UnsafeContextFile,
    ContextFileReadFailed,
};

arena: std.heap.ArenaAllocator,
prompt_files: ?PromptFiles = null,
context_files: ?ContextFiles = null,
project_trust: ProjectTrust.Decision,
effective_policy: SystemPrompt.Policy,

pub fn resolve(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    intent: ProjectTrust.Intent,
    requested_policy: SystemPrompt.Policy,
) Error!RuntimeResources {
    const requested_prompt_files = requestedPromptFiles(requested_policy);
    const project_trust = try resolveProjectTrust(
        allocator,
        io,
        paths,
        requested_prompt_files,
        intent,
    );
    var resources: RuntimeResources = .{
        .arena = .init(allocator),
        .project_trust = project_trust,
        .effective_policy = requested_policy,
    };
    errdefer resources.deinit();

    if (requested_prompt_files.system or requested_prompt_files.append) {
        resources.prompt_files = try PromptFiles.load(
            allocator,
            io,
            paths,
            requested_prompt_files,
            project_trust,
        );
    }
    resources.effective_policy = try resolvePromptPolicy(
        resources.arena.allocator(),
        requested_policy,
        if (resources.prompt_files) |*files| files else null,
    );

    if (requestsContextFiles(resources.effective_policy)) {
        resources.context_files = try ContextFiles.load(allocator, io, paths);
    }
    resources.effective_policy = try resolveContextPolicy(
        resources.arena.allocator(),
        resources.effective_policy,
        if (resources.context_files) |*files| files else null,
    );
    return resources;
}

pub fn policy(self: *const RuntimeResources) SystemPrompt.Policy {
    return self.effective_policy;
}

pub fn projectTrust(self: *const RuntimeResources) ProjectTrust.Decision {
    return self.project_trust;
}

pub fn deinit(self: *RuntimeResources) void {
    if (self.context_files) |*files| files.deinit();
    if (self.prompt_files) |*files| files.deinit();
    self.arena.deinit();
    self.* = undefined;
}

fn resolveProjectTrust(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    requested: PromptFiles.Requested,
    intent: ProjectTrust.Intent,
) Error!ProjectTrust.Decision {
    if (intent != .automatic) return ProjectTrust.resolve(intent, null);
    const has_prompt_source = try PromptFiles.hasProjectSources(io, paths, requested);
    const has_settings_source = try SettingsStore.hasProjectSource(io, paths);
    if (!has_prompt_source and !has_settings_source) {
        return ProjectTrust.resolve(.automatic, null);
    }
    var identity = try ProjectTrustStore.Identity.init(allocator, io, paths.cwd);
    defer identity.deinit();
    var snapshot = try ProjectTrustStore.load(allocator, io, paths);
    defer snapshot.deinit();
    const saved = if (snapshot.nearest(&identity)) |entry| entry.decision else null;
    return ProjectTrust.resolve(.automatic, saved);
}

fn requestedPromptFiles(policy_value: SystemPrompt.Policy) PromptFiles.Requested {
    return switch (policy_value) {
        .verbatim => .{},
        .composed => |composition| .{
            .system = switch (composition.base) {
                .builtin => true,
                .custom => false,
            },
            .append = composition.rules.len == 0,
        },
    };
}

fn resolvePromptPolicy(
    allocator: std.mem.Allocator,
    policy_value: SystemPrompt.Policy,
    files: ?*const PromptFiles,
) Error!SystemPrompt.Policy {
    return switch (policy_value) {
        .verbatim => policy_value,
        .composed => |composition| .{ .composed = .{
            .base = switch (composition.base) {
                .builtin => if (files) |loaded|
                    if (loaded.system()) |text| .{ .custom = text } else .builtin
                else
                    .builtin,
                .custom => composition.base,
            },
            .context_sections = composition.context_sections,
            .rules = if (composition.rules.len > 0)
                composition.rules
            else if (files) |loaded|
                if (loaded.append()) |text| rules: {
                    const discovered = try allocator.alloc([]const u8, 1);
                    discovered[0] = text;
                    break :rules discovered;
                } else &.{}
            else
                &.{},
        } },
    };
}

fn requestsContextFiles(policy_value: SystemPrompt.Policy) bool {
    return switch (policy_value) {
        .verbatim => false,
        .composed => |composition| composition.context_sections.len == 0,
    };
}

fn resolveContextPolicy(
    allocator: std.mem.Allocator,
    policy_value: SystemPrompt.Policy,
    files: ?*const ContextFiles,
) Error!SystemPrompt.Policy {
    return switch (policy_value) {
        .verbatim => policy_value,
        .composed => |composition| .{ .composed = .{
            .base = composition.base,
            .context_sections = if (composition.context_sections.len > 0)
                composition.context_sections
            else if (files) |loaded| discovered: {
                const sources = loaded.sections();
                const sections = try allocator.alloc(SystemPrompt.ContextSection, sources.len);
                for (sources, sections) |source, *section| {
                    section.* = .{ .path = source.path, .text = source.text };
                }
                break :discovered sections;
            } else &.{},
            .rules = composition.rules,
        } },
    };
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

const AllocationContext = struct {
    paths: *const ZiPaths,
};

fn resolveAndDeinit(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    var resources = try resolve(
        allocator,
        std.testing.io,
        context.paths,
        .approve,
        .{ .composed = .{} },
    );
    resources.deinit();
}

test "runtime resources own discovered prompt and context policy" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "Project context.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();

    var resources = try resolve(
        std.testing.allocator,
        std.testing.io,
        &paths,
        .approve,
        .{ .composed = .{} },
    );
    defer resources.deinit();
    const composition = resources.policy().composed;
    try std.testing.expectEqualStrings("Project base.", composition.base.custom);
    try std.testing.expect(composition.context_sections.len >= 1);
    try std.testing.expectEqualStrings(
        "Project context.",
        composition.context_sections[composition.context_sections.len - 1].text,
    );
}

test "runtime resources settle every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, ".zi", .default_dir);
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = ".zi/SYSTEM.md",
        .data = "Project base.",
    });
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "AGENTS.md",
        .data = "Project context.",
    });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    var context: AllocationContext = .{ .paths = &paths };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, resolveAndDeinit, .{&context});
}
