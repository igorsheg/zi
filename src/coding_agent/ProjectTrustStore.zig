const std = @import("std");
const builtin = @import("builtin");
const BoundedJson = @import("../BoundedJson.zig");
const PrivateFileStore = @import("PrivateFileStore.zig");
const ProjectTrust = @import("ProjectTrust.zig");
const ZiPaths = @import("ZiPaths.zig");

const trust_file_name = "trust.json";
const lock_file_name = ".trust.lock";
const max_document_bytes = 1024 * 1024;
const max_entries = 1024;
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
};

pub const Identity = struct {
    allocator: std.mem.Allocator,
    canonical_path: [:0]u8,

    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        target_path: []const u8,
    ) Error!Identity {
        try validatePath(target_path);
        const resolved = std.fs.path.resolve(allocator, &.{target_path}) catch return error.OutOfMemory;
        defer allocator.free(resolved);
        var directory = std.Io.Dir.openDirAbsolute(io, resolved, .{}) catch
            return error.ProjectIdentityUnavailable;
        defer directory.close(io);
        const canonical_path = directory.realPathFileAlloc(io, ".", allocator) catch |failure| return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.ProjectIdentityUnavailable,
        };
        errdefer allocator.free(canonical_path);
        try validatePath(canonical_path);
        if (canonical_path.len > ZiPaths.max_path_bytes) return error.InvalidProjectIdentity;
        return .{ .allocator = allocator, .canonical_path = canonical_path };
    }

    pub fn path(self: *const Identity) []const u8 {
        return self.canonical_path;
    }

    pub fn deinit(self: *Identity) void {
        self.allocator.free(self.canonical_path);
        self.* = undefined;
    }
};

pub const Entry = struct {
    path: []const u8,
    decision: ProjectTrust.Decision,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const Entry,

    pub fn nearest(self: *const Snapshot, identity: *const Identity) ?Entry {
        var candidate = identity.path();
        while (true) {
            for (self.entries) |entry| {
                if (std.mem.eql(u8, entry.path, candidate)) return entry;
            }
            const parent = std.fs.path.dirname(candidate) orelse return null;
            if (std.mem.eql(u8, parent, candidate)) return null;
            candidate = parent;
        }
    }

    pub fn exact(self: *const Snapshot, identity: *const Identity) ?Entry {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.path, identity.path())) return entry;
        }
        return null;
    }

    pub fn deinit(self: *Snapshot) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

const Boundary = PrivateFileStore.Boundary;
const Faults = PrivateFileStore.Faults;

const Source = struct {
    version: u32,
    projects: []const SourceEntry,
};

const SourceEntry = struct {
    path: []const u8,
    trusted: bool,
};

const Mutation = struct {
    store: PrivateFileStore.Mutation,

    fn deinit(self: *Mutation) void {
        self.store.deinit();
        self.* = undefined;
    }

    fn put(
        self: *Mutation,
        allocator: std.mem.Allocator,
        identity: *const Identity,
        decision: ProjectTrust.Decision,
    ) Error!void {
        var current = try loadMutation(self, allocator);
        defer current.deinit();
        const replacing = findExact(current.entries, identity.path());
        const count = current.entries.len + @intFromBool(replacing == null);
        if (count > max_entries) return error.InvalidProjectTrustFile;
        const updated = try allocator.alloc(Entry, count);
        defer allocator.free(updated);
        var cursor: usize = 0;
        for (current.entries, 0..) |entry, index| {
            updated[cursor] = if (replacing == index)
                .{ .path = identity.path(), .decision = decision }
            else
                entry;
            cursor += 1;
        }
        if (replacing == null) {
            updated[cursor] = .{ .path = identity.path(), .decision = decision };
        }
        try self.writeEntries(allocator, updated);
    }

    fn remove(
        self: *Mutation,
        allocator: std.mem.Allocator,
        identity: *const Identity,
    ) Error!bool {
        var current = try loadMutation(self, allocator);
        defer current.deinit();
        const removing = findExact(current.entries, identity.path()) orelse return false;
        const updated = try allocator.alloc(Entry, current.entries.len - 1);
        defer allocator.free(updated);
        var cursor: usize = 0;
        for (current.entries, 0..) |entry, index| {
            if (index == removing) continue;
            updated[cursor] = entry;
            cursor += 1;
        }
        try self.writeEntries(allocator, updated);
        return true;
    }

    fn writeEntries(self: *Mutation, allocator: std.mem.Allocator, entries: []const Entry) Error!void {
        const encoded = try encode(allocator, entries);
        defer allocator.free(encoded);
        self.store.replace(trust_file_name, encoded) catch |failure| return mapWriteFailure(failure);
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) Error!Snapshot {
    const source_text = PrivateFileStore.readFileAlloc(
        allocator,
        io,
        paths.home,
        paths.global_agent,
        trust_file_name,
        max_document_bytes,
    ) catch |failure| return mapReadFailure(failure);
    return decodeOptional(allocator, source_text);
}

pub fn put(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    identity: *const Identity,
    decision: ProjectTrust.Decision,
) Error!void {
    var mutation = try beginMutation(io, paths, .none());
    defer mutation.deinit();
    return mutation.put(allocator, identity, decision);
}

pub fn remove(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    identity: *const Identity,
) Error!bool {
    var mutation = try beginMutation(io, paths, .none());
    defer mutation.deinit();
    return mutation.remove(allocator, identity);
}

fn beginMutation(io: std.Io, paths: *const ZiPaths, faults: Faults) Error!Mutation {
    const store = PrivateFileStore.beginMutation(
        io,
        paths.home,
        paths.global_agent,
        lock_file_name,
        faults,
    ) catch |failure| return mapMutationFailure(failure);
    return .{ .store = store };
}

fn loadMutation(self: *Mutation, allocator: std.mem.Allocator) Error!Snapshot {
    const source_text = self.store.readFileAlloc(
        allocator,
        trust_file_name,
        max_document_bytes,
    ) catch |failure| return mapReadFailure(failure);
    return decodeOptional(allocator, source_text);
}

fn decodeOptional(allocator: std.mem.Allocator, maybe_source_text: ?[]u8) Error!Snapshot {
    const source_text = maybe_source_text orelse return empty(allocator);
    defer allocator.free(source_text);
    if (source_text.len > max_document_bytes) return error.InvalidProjectTrustFile;
    return decode(allocator, source_text);
}

fn mapReadFailure(failure: PrivateFileStore.Error) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeProjectTrustStorage,
        else => error.ProjectTrustReadFailed,
    };
}

fn mapMutationFailure(failure: PrivateFileStore.Error) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeProjectTrustStorage,
        else => error.ProjectTrustLockFailed,
    };
}

fn mapWriteFailure(failure: PrivateFileStore.Error) Error {
    return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        error.UnsafePath => error.UnsafeProjectTrustStorage,
        error.CommitIndeterminate => error.ProjectTrustCommitIndeterminate,
        else => error.ProjectTrustWriteFailed,
    };
}

fn empty(allocator: std.mem.Allocator) Snapshot {
    return .{ .arena = .init(allocator), .entries = &.{} };
}

fn decode(allocator: std.mem.Allocator, source_text: []const u8) Error!Snapshot {
    BoundedJson.validate(allocator, source_text, .{
        .document_bytes = max_document_bytes,
        .value_bytes = ZiPaths.max_path_bytes,
        .depth = 4,
        .collection_items = max_entries * 4,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidProjectTrustFile,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const source = std.json.parseFromSliceLeaky(Source, arena.allocator(), source_text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = ZiPaths.max_path_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidProjectTrustFile,
    };
    if (source.version != 1) return error.UnsupportedVersion;
    if (source.projects.len > max_entries) return error.InvalidProjectTrustFile;
    const entries = try arena.allocator().alloc(Entry, source.projects.len);
    for (source.projects, entries, 0..) |item, *entry, index| {
        try validateStoredPath(arena.allocator(), item.path);
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.path, item.path)) return error.InvalidProjectTrustFile;
        }
        entry.* = .{
            .path = item.path,
            .decision = if (item.trusted) .trusted else .untrusted,
        };
    }
    return .{ .arena = arena, .entries = entries };
}

fn encode(allocator: std.mem.Allocator, entries: []const Entry) Error![]u8 {
    if (entries.len > max_entries) return error.InvalidProjectTrustFile;
    const sorted = try allocator.dupe(Entry, entries);
    defer allocator.free(sorted);
    std.mem.sort(Entry, sorted, {}, lessThanEntry);
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    try writeField(&json, "version", @as(u32, 1));
    json.objectField("projects") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (sorted) |entry| {
        try validateStoredPath(allocator, entry.path);
        json.beginObject() catch return error.OutOfMemory;
        try writeField(&json, "path", entry.path);
        try writeField(&json, "trusted", entry.decision == .trusted);
        json.endObject() catch return error.OutOfMemory;
    }
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    output.writer.writeByte('\n') catch return error.OutOfMemory;
    const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
    if (encoded.len > max_document_bytes) {
        allocator.free(encoded);
        return error.InvalidProjectTrustFile;
    }
    return encoded;
}

fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) Error!void {
    json.objectField(name) catch return error.OutOfMemory;
    json.write(value) catch return error.OutOfMemory;
}

fn validatePath(path: []const u8) Error!void {
    if (path.len == 0 or path.len > ZiPaths.max_path_bytes or
        !std.unicode.utf8ValidateSlice(path) or
        std.mem.findScalar(u8, path, 0) != null or
        !std.fs.path.isAbsolute(path))
    {
        return error.InvalidProjectIdentity;
    }
}

fn validateStoredPath(allocator: std.mem.Allocator, path: []const u8) Error!void {
    validatePath(path) catch return error.InvalidProjectTrustFile;
    const normalized = std.fs.path.resolve(allocator, &.{path}) catch return error.OutOfMemory;
    defer allocator.free(normalized);
    if (!std.mem.eql(u8, normalized, path)) return error.InvalidProjectTrustFile;
}

fn findExact(entries: []const Entry, path: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.path, path)) return index;
    }
    return null;
}

fn lessThanEntry(_: void, left: Entry, right: Entry) bool {
    return std.mem.order(u8, left.path, right.path) == .lt;
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

test "project identities canonicalize directory aliases" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "project/child");
    try temporary.dir.symLink(std.testing.io, "project", "alias", .{ .is_directory = true });
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const project_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_path);
    const alias_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "alias" });
    defer std.testing.allocator.free(alias_path);

    var project = try Identity.init(std.testing.allocator, std.testing.io, project_path);
    defer project.deinit();
    var alias = try Identity.init(std.testing.allocator, std.testing.io, alias_path);
    defer alias.deinit();
    try std.testing.expectEqualStrings(project.path(), alias.path());
    try std.testing.expectError(
        error.ProjectIdentityUnavailable,
        Identity.init(std.testing.allocator, std.testing.io, "/path/that/does/not/exist"),
    );
}

test "project trust store resolves nearest decisions and supports revocation" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, "workspace/child");
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const workspace_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "workspace" });
    defer std.testing.allocator.free(workspace_path);
    const child_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "workspace", "child" });
    defer std.testing.allocator.free(child_path);
    var paths = try ZiPaths.init(std.testing.allocator, child_path, root);
    defer paths.deinit();
    var workspace = try Identity.init(std.testing.allocator, std.testing.io, workspace_path);
    defer workspace.deinit();
    var child = try Identity.init(std.testing.allocator, std.testing.io, child_path);
    defer child.deinit();

    try put(std.testing.allocator, std.testing.io, &paths, &workspace, .trusted);
    var inherited = try load(std.testing.allocator, std.testing.io, &paths);
    try std.testing.expectEqualStrings(workspace.path(), inherited.nearest(&child).?.path);
    try std.testing.expectEqual(ProjectTrust.Decision.trusted, inherited.nearest(&child).?.decision);
    inherited.deinit();

    try put(std.testing.allocator, std.testing.io, &paths, &child, .untrusted);
    var overridden = try load(std.testing.allocator, std.testing.io, &paths);
    try std.testing.expectEqualStrings(child.path(), overridden.nearest(&child).?.path);
    try std.testing.expectEqual(ProjectTrust.Decision.untrusted, overridden.nearest(&child).?.decision);
    overridden.deinit();

    try std.testing.expect(try remove(std.testing.allocator, std.testing.io, &paths, &child));
    try std.testing.expect(!try remove(std.testing.allocator, std.testing.io, &paths, &child));
    var revealed = try load(std.testing.allocator, std.testing.io, &paths);
    try std.testing.expectEqualStrings(workspace.path(), revealed.nearest(&child).?.path);
    revealed.deinit();

    try std.testing.expect(try remove(std.testing.allocator, std.testing.io, &paths, &workspace));
    var empty_snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer empty_snapshot.deinit();
    try std.testing.expect(empty_snapshot.nearest(&child) == null);
}

test "project trust store validates its bounded versioned format" {
    try std.testing.expectError(
        error.UnsupportedVersion,
        decode(std.testing.allocator, "{\"version\":2,\"projects\":[]}"),
    );
    try std.testing.expectError(
        error.InvalidProjectTrustFile,
        decode(std.testing.allocator, "{\"version\":1,\"projects\":[],\"extra\":true}"),
    );
    try std.testing.expectError(
        error.InvalidProjectTrustFile,
        decode(std.testing.allocator, "{\"version\":1,\"projects\":[{\"path\":\"relative\",\"trusted\":true}]}"),
    );
    try std.testing.expectError(
        error.InvalidProjectTrustFile,
        decode(std.testing.allocator, "{\"version\":1,\"projects\":[{\"path\":\"/tmp/a/../b\",\"trusted\":true}]}"),
    );
    try std.testing.expectError(
        error.InvalidProjectTrustFile,
        decode(std.testing.allocator,
            \\{"version":1,"projects":[
            \\  {"path":"/tmp/a","trusted":true},
            \\  {"path":"/tmp/a","trusted":false}
            \\]}
        ),
    );
}

test "project trust store requires private non-linked storage" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDirPath(std.testing.io, ".zi/agent");
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();

    const insecure = try temporary.dir.createFile(std.testing.io, ".zi/agent/trust.json", .{
        .permissions = std.Io.File.Permissions.fromMode(0o644),
    });
    try insecure.writePositionalAll(std.testing.io, "{\"version\":1,\"projects\":[]}", 0);
    insecure.close(std.testing.io);
    try std.testing.expectError(
        error.UnsafeProjectTrustStorage,
        load(std.testing.allocator, std.testing.io, &paths),
    );

    try temporary.dir.deleteFile(std.testing.io, ".zi/agent/trust.json");
    try temporary.dir.writeFile(std.testing.io, .{
        .sub_path = "outside.json",
        .data = "{\"version\":1,\"projects\":[]}",
    });
    try temporary.dir.symLink(
        std.testing.io,
        "../../outside.json",
        ".zi/agent/trust.json",
        .{ .is_directory = false },
    );
    try std.testing.expectError(
        error.UnsafeProjectTrustStorage,
        load(std.testing.allocator, std.testing.io, &paths),
    );

    try temporary.dir.deleteFile(std.testing.io, ".zi/agent/trust.json");
    const outside_lock = try temporary.dir.createFile(std.testing.io, "outside.lock", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    outside_lock.close(std.testing.io);
    try temporary.dir.symLink(
        std.testing.io,
        "../../outside.lock",
        ".zi/agent/.trust.lock",
        .{ .is_directory = false },
    );
    var identity = try Identity.init(std.testing.allocator, std.testing.io, root);
    defer identity.deinit();
    try std.testing.expectError(
        error.UnsafeProjectTrustStorage,
        put(std.testing.allocator, std.testing.io, &paths, &identity, .trusted),
    );
}

test "project trust store distinguishes failed and indeterminate commits" {
    const Fault = struct {
        const Self = @This();
        fail_at: Boundary,

        fn boundary(context: *anyopaque, point: Boundary) anyerror!void {
            const self: *Self = @ptrCast(@alignCast(context));
            if (point == self.fail_at) return error.Injected;
        }

        fn faults(self: *Self) Faults {
            return .{ .context = self, .boundary_fn = boundary };
        }
    };
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "project", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const project_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_path);
    var paths = try ZiPaths.init(std.testing.allocator, project_path, root);
    defer paths.deinit();
    var identity = try Identity.init(std.testing.allocator, std.testing.io, project_path);
    defer identity.deinit();
    try put(std.testing.allocator, std.testing.io, &paths, &identity, .untrusted);

    var before_replace: Fault = .{ .fail_at = .after_write };
    var failed = try beginMutation(std.testing.io, &paths, before_replace.faults());
    try std.testing.expectError(
        error.ProjectTrustWriteFailed,
        failed.put(std.testing.allocator, &identity, .trusted),
    );
    failed.deinit();
    var original = try load(std.testing.allocator, std.testing.io, &paths);
    try std.testing.expectEqual(ProjectTrust.Decision.untrusted, original.exact(&identity).?.decision);
    original.deinit();

    var after_replace: Fault = .{ .fail_at = .after_replace };
    var indeterminate = try beginMutation(std.testing.io, &paths, after_replace.faults());
    try std.testing.expectError(
        error.ProjectTrustCommitIndeterminate,
        indeterminate.put(std.testing.allocator, &identity, .trusted),
    );
    indeterminate.deinit();
    var published = try load(std.testing.allocator, std.testing.io, &paths);
    defer published.deinit();
    try std.testing.expectEqual(ProjectTrust.Decision.trusted, published.exact(&identity).?.decision);
}

fn decodeAndDeinit(allocator: std.mem.Allocator) !void {
    var snapshot = try decode(
        allocator,
        "{\"version\":1,\"projects\":[{\"path\":\"/tmp/project\",\"trusted\":true}]}",
    );
    snapshot.deinit();
}

test "project trust decoding settles every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, decodeAndDeinit, .{});
}

const AllocationContext = struct {
    paths: *const ZiPaths,
    identity: *const Identity,
};

fn putAndLoad(allocator: std.mem.Allocator, context: *AllocationContext) !void {
    try put(allocator, std.testing.io, context.paths, context.identity, .trusted);
    var snapshot = try load(allocator, std.testing.io, context.paths);
    snapshot.deinit();
}

test "project trust persistence settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(std.testing.io, "project", .default_dir);
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    const project_path = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project" });
    defer std.testing.allocator.free(project_path);
    var paths = try ZiPaths.init(std.testing.allocator, project_path, root);
    defer paths.deinit();
    var identity = try Identity.init(std.testing.allocator, std.testing.io, project_path);
    defer identity.deinit();
    var context: AllocationContext = .{ .paths = &paths, .identity = &identity };

    try std.testing.checkAllAllocationFailures(std.testing.allocator, putAndLoad, .{&context});
}
