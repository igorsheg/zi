const std = @import("std");
const ProjectTrust = @import("../ProjectTrust.zig");
const ProjectTrustStore = @import("../ProjectTrustStore.zig");
const ZiPaths = @import("../ZiPaths.zig");
const surface = @import("surface.zig");

pub const Context = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    cwd: []const u8,
    home: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
};

pub fn run(request: surface.TrustRequest, context: Context) !u8 {
    const target_path = std.fs.path.resolve(
        context.allocator,
        &.{ context.cwd, request.path orelse context.cwd },
    ) catch {
        try context.stderr.writeAll("Unable to resolve the project path: OutOfMemory.\n");
        return 1;
    };
    defer context.allocator.free(target_path);
    var paths = ZiPaths.init(context.allocator, target_path, context.home) catch |failure| {
        try context.stderr.print("Unable to resolve the project path: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer paths.deinit();
    var identity = ProjectTrustStore.Identity.init(context.allocator, context.io, target_path) catch |failure| {
        try context.stderr.print("Unable to identify the project: {s}.\n", .{@errorName(failure)});
        return 1;
    };
    defer identity.deinit();

    return switch (request.action) {
        .status => status(context, &paths, &identity),
        .allow => update(context, &paths, &identity, .trusted),
        .deny => update(context, &paths, &identity, .untrusted),
        .remove => remove(context, &paths, &identity),
    };
}

fn status(
    context: Context,
    paths: *const ZiPaths,
    identity: *const ProjectTrustStore.Identity,
) !u8 {
    var snapshot = ProjectTrustStore.load(context.allocator, context.io, paths) catch |failure| {
        try writeStoreFailure(context.stderr, "read", failure);
        return 1;
    };
    defer snapshot.deinit();
    if (snapshot.nearest(identity)) |entry| {
        try context.stdout.print(
            "Project trust: {s} (saved at {s}).\n",
            .{ @tagName(entry.decision), entry.path },
        );
    } else {
        try context.stdout.print("Project trust: unset for {s}.\n", .{identity.path()});
    }
    return 0;
}

fn update(
    context: Context,
    paths: *const ZiPaths,
    identity: *const ProjectTrustStore.Identity,
    decision: ProjectTrust.Decision,
) !u8 {
    ProjectTrustStore.put(
        context.allocator,
        context.io,
        paths,
        identity,
        decision,
    ) catch |failure| {
        try writeStoreFailure(context.stderr, "update", failure);
        return 1;
    };
    try context.stdout.print(
        "Saved project trust: {s} for {s}.\n",
        .{ @tagName(decision), identity.path() },
    );
    return 0;
}

fn remove(
    context: Context,
    paths: *const ZiPaths,
    identity: *const ProjectTrustStore.Identity,
) !u8 {
    const removed = ProjectTrustStore.remove(
        context.allocator,
        context.io,
        paths,
        identity,
    ) catch |failure| {
        try writeStoreFailure(context.stderr, "update", failure);
        return 1;
    };
    if (removed) {
        try context.stdout.print("Removed project trust for {s}.\n", .{identity.path()});
    } else {
        try context.stdout.print("No exact project trust decision exists for {s}.\n", .{identity.path()});
    }
    return 0;
}

fn writeStoreFailure(writer: *std.Io.Writer, operation: []const u8, failure: anyerror) !void {
    try writer.print("Unable to {s} project trust: {s}.\n", .{ operation, @errorName(failure) });
}

fn testContext(
    root: []const u8,
    project: []const u8,
    stdout: *std.Io.Writer,
    stderr: *std.Io.Writer,
) Context {
    return .{
        .allocator = std.testing.allocator,
        .io = std.testing.io,
        .cwd = project,
        .home = root,
        .stdout = stdout,
        .stderr = stderr,
    };
}

test "trust command manages exact decisions and reports effective status" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "project", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root_length = try temporary.dir.realPath(std.testing.io, &root_buffer);
    const root = root_buffer[0..root_length];
    const project = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project);
    var stdout: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stdout.deinit();
    var stderr: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer stderr.deinit();

    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .allow }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Saved project trust: trusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: trusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .deny }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: untrusted") != null);
    stdout.clearRetainingCapacity();

    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .remove }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    stdout.clearRetainingCapacity();
    try std.testing.expectEqual(
        @as(u8, 0),
        try run(.{ .action = .status }, testContext(root, project, &stdout.writer, &stderr.writer)),
    );
    try std.testing.expect(std.mem.find(u8, stdout.written(), "Project trust: unset") != null);
    try std.testing.expectEqualStrings("", stderr.written());
}
