const std = @import("std");
const Document = @import("Document.zig");
const Loader = @import("Loader.zig");
const SecureOpen = @import("SecureOpen.zig");

const maximum_temp_attempts: usize = 32;
const maximum_prefix_bytes: usize = 32;

pub const NonceError = error{ OutOfMemory, Failed };

pub const NonceSource = struct {
    context: *anyopaque,
    fill_fn: *const fn (*anyopaque, []u8) NonceError!void,

    pub fn fill(self: NonceSource, bytes: []u8) NonceError!void {
        return self.fill_fn(self.context, bytes);
    }

    pub fn from(implementation: anytype) NonceSource {
        const Pointer = @TypeOf(implementation);
        const pointer = @typeInfo(Pointer);
        if (pointer != .pointer or pointer.pointer.size != .one or pointer.pointer.is_const) {
            @compileError("AtomicReplace.NonceSource.from expects a mutable single-item pointer");
        }
        const Implementation = pointer.pointer.child;
        const Adapter = struct {
            fn fill(context: *anyopaque, bytes: []u8) NonceError!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.fillBytes(bytes);
            }
        };
        return .{ .context = implementation, .fill_fn = Adapter.fill };
    }
};

pub const OpsError = error{Failed};
pub const CreateTempError = error{ Collision, Failed };

/// Injectable operations at points where a completed candidate can still fail.
/// Implementations must not retain borrowed paths or bytes.
pub const CommitOps = struct {
    context: ?*anyopaque = null,
    make_parent_fn: *const fn (std.Io, ?*anyopaque, []const u8) OpsError!void = standardMakeParent,
    open_parent_fn: *const fn (std.Io, ?*anyopaque, []const u8) OpsError!std.Io.Dir = standardOpenParent,
    create_temp_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8) CreateTempError!std.Io.File =
        standardCreateTemp,
    write_fn: *const fn (std.Io, ?*anyopaque, std.Io.File, []const u8) OpsError!void = standardWrite,
    sync_fn: *const fn (std.Io, ?*anyopaque, std.Io.File) OpsError!void = standardSync,
    rename_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8, []const u8) OpsError!void =
        standardRename,
    cleanup_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8) void = standardCleanup,

    pub const standard: CommitOps = .{};
};

pub const Inputs = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource = null,
    commit_ops: CommitOps = .standard,
    path: []const u8,
    expected: ?Loader.Fingerprint,
    temp_prefix: []const u8,
};

pub const TargetStatus = enum { unchanged, conflict, unavailable };

pub const Outcome = union(enum) {
    written: Loader.Fingerprint,
    conflict,
    target_unavailable,
    unavailable,
    failed,
};

pub fn checkTarget(inputs: Inputs) error{OutOfMemory}!TargetStatus {
    const observed = try inspectTarget(inputs.allocator, inputs.io, inputs.secure_open, inputs.path);
    return compareInspection(inputs.expected, observed);
}

pub fn commit(inputs: Inputs, bytes: []const u8) error{OutOfMemory}!Outcome {
    if (bytes.len > Loader.maximum_file_bytes or inputs.temp_prefix.len == 0 or
        inputs.temp_prefix.len > maximum_prefix_bytes)
    {
        return .unavailable;
    }
    const parent = std.fs.path.dirname(inputs.path) orelse return .unavailable;
    const target_name = std.fs.path.basename(inputs.path);
    if (target_name.len == 0 or std.mem.indexOfScalar(u8, target_name, 0) != null) return .unavailable;
    const ops = inputs.commit_ops;
    ops.make_parent_fn(inputs.io, ops.context, parent) catch return .unavailable;
    const directory = ops.open_parent_fn(inputs.io, ops.context, parent) catch return .unavailable;
    defer directory.close(inputs.io);
    const parent_stat = directory.stat(inputs.io) catch return .unavailable;
    if (parent_stat.kind != .directory or parent_stat.permissions.toMode() & 0o022 != 0) return .unavailable;

    var nonce: [16]u8 = undefined;
    var name_buffer: [maximum_prefix_bytes + nonce.len * 2]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < maximum_temp_attempts) : (attempt += 1) {
        if (inputs.nonce_source) |source| {
            source.fill(&nonce) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Failed => return .unavailable,
            };
        } else std.Io.random(inputs.io, &nonce);
        const temp_name = std.fmt.bufPrint(&name_buffer, "{s}{x}", .{ inputs.temp_prefix, nonce }) catch
            return .unavailable;
        const temp = ops.create_temp_fn(inputs.io, ops.context, directory, temp_name) catch |err| switch (err) {
            error.Collision => continue,
            error.Failed => return .failed,
        };
        var renamed = false;
        defer {
            temp.close(inputs.io);
            if (!renamed) ops.cleanup_fn(inputs.io, ops.context, directory, temp_name);
        }

        ops.write_fn(inputs.io, ops.context, temp, bytes) catch return .failed;
        ops.sync_fn(inputs.io, ops.context, temp) catch return .failed;
        const temp_stat = temp.stat(inputs.io) catch return .failed;
        if (temp_stat.kind != .file or temp_stat.nlink != 1 or temp_stat.size != bytes.len) return .failed;
        const target_status = try checkTargetAt(inputs, directory, target_name);
        switch (target_status) {
            .unchanged => {},
            .conflict => return .conflict,
            .unavailable => return .target_unavailable,
        }
        const named_temp = directory.statFile(
            inputs.io,
            temp_name,
            .{ .follow_symlinks = false },
        ) catch return .failed;
        if (!sameDescriptorState(temp_stat, named_temp)) return .failed;
        ops.rename_fn(inputs.io, ops.context, directory, temp_name, target_name) catch return .failed;
        renamed = true;
        return .{ .written = fingerprint(temp_stat, bytes) };
    }
    return .failed;
}

fn checkTargetAt(inputs: Inputs, directory: std.Io.Dir, target_name: []const u8) error{OutOfMemory}!TargetStatus {
    const observed = try inspectTargetAt(inputs.allocator, inputs.io, directory, target_name);
    return compareInspection(inputs.expected, observed);
}

const Inspection = union(enum) {
    missing,
    unsafe,
    unreadable,
    fingerprint: Loader.Fingerprint,
};

fn compareInspection(expected: ?Loader.Fingerprint, observed: Inspection) TargetStatus {
    if (expected) |value| return switch (observed) {
        .fingerprint => |actual| if (value.eql(actual)) .unchanged else .conflict,
        .missing => .conflict,
        .unsafe, .unreadable => .unavailable,
    };
    return switch (observed) {
        .missing => .unchanged,
        .fingerprint => .conflict,
        .unsafe, .unreadable => .unavailable,
    };
}

fn inspectTarget(
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    path: []const u8,
) error{OutOfMemory}!Inspection {
    const named = secure_open.statFile(io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .missing,
        else => return .unreadable,
    };
    if (named.kind != .file or named.nlink == 0 or named.size > Loader.maximum_file_bytes) return .unsafe;
    const file = secure_open.openFile(io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.FileNotFound => return .missing,
        else => return .unreadable,
    };
    defer file.close(io);
    const before = file.stat(io) catch return .unreadable;
    if (before.kind != .file or before.nlink == 0 or before.inode != named.inode or
        before.size > Loader.maximum_file_bytes) return .unsafe;
    var wiping_allocator: Document.WipingAllocator = .{ .backing = allocator };
    const read_allocator = wiping_allocator.allocator();
    const buffer = read_allocator.alloc(u8, Loader.maximum_file_bytes + 1) catch return error.OutOfMemory;
    defer read_allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch return .unreadable;
    if (count > Loader.maximum_file_bytes or count != before.size) return .unsafe;
    const after = file.stat(io) catch return .unreadable;
    if (!sameDescriptorState(before, after)) return .unreadable;
    const final_named = secure_open.statFile(io, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unreadable,
    };
    if (!sameDescriptorState(after, final_named)) return .unreadable;
    return .{ .fingerprint = fingerprint(before, buffer[0..count]) };
}

fn inspectTargetAt(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    target_name: []const u8,
) error{OutOfMemory}!Inspection {
    const named = directory.statFile(io, target_name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return .unreadable,
    };
    if (named.kind != .file or named.nlink == 0 or named.size > Loader.maximum_file_bytes) return .unsafe;
    const file = directory.openFile(io, target_name, .{
        .mode = .read_only,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return .unreadable,
    };
    defer file.close(io);
    const before = file.stat(io) catch return .unreadable;
    if (before.kind != .file or before.nlink == 0 or before.inode != named.inode or
        before.size > Loader.maximum_file_bytes) return .unsafe;
    var wiping_allocator: Document.WipingAllocator = .{ .backing = allocator };
    const read_allocator = wiping_allocator.allocator();
    const buffer = read_allocator.alloc(u8, Loader.maximum_file_bytes + 1) catch return error.OutOfMemory;
    defer read_allocator.free(buffer);
    const count = file.readPositionalAll(io, buffer, 0) catch return .unreadable;
    if (count > Loader.maximum_file_bytes or count != before.size) return .unsafe;
    const after = file.stat(io) catch return .unreadable;
    if (!sameDescriptorState(before, after)) return .unreadable;
    const final_named = directory.statFile(io, target_name, .{ .follow_symlinks = false }) catch
        return .unreadable;
    if (!sameDescriptorState(after, final_named)) return .unreadable;
    return .{ .fingerprint = fingerprint(before, buffer[0..count]) };
}

fn fingerprint(stat: std.Io.File.Stat, bytes: []const u8) Loader.Fingerprint {
    var digest: [std.crypto.hash.Blake3.digest_length]u8 = undefined;
    std.crypto.hash.Blake3.hash(bytes, &digest, .{});
    return .{
        .inode = stat.inode,
        .nlink = stat.nlink,
        .size = stat.size,
        .mtime_ns = stat.mtime.nanoseconds,
        .ctime_ns = stat.ctime.nanoseconds,
        .digest = digest,
    };
}

fn sameDescriptorState(left: std.Io.File.Stat, right: std.Io.File.Stat) bool {
    return left.kind == .file and right.kind == .file and left.inode == right.inode and
        left.nlink == right.nlink and left.size == right.size and
        left.mtime.nanoseconds == right.mtime.nanoseconds and
        left.ctime.nanoseconds == right.ctime.nanoseconds;
}

fn standardMakeParent(io: std.Io, _: ?*anyopaque, parent: []const u8) OpsError!void {
    _ = std.Io.Dir.createDirPathStatus(.cwd(), io, parent, .fromMode(0o700)) catch return error.Failed;
}

fn standardOpenParent(io: std.Io, _: ?*anyopaque, parent: []const u8) OpsError!std.Io.Dir {
    return std.Io.Dir.openDir(.cwd(), io, parent, .{ .follow_symlinks = false }) catch return error.Failed;
}

fn standardCreateTemp(
    io: std.Io,
    _: ?*anyopaque,
    directory: std.Io.Dir,
    name: []const u8,
) CreateTempError!std.Io.File {
    const file = directory.createFile(io, name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = .fromMode(0o600),
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => return error.Collision,
        else => return error.Failed,
    };
    var transferred = false;
    defer if (!transferred) {
        file.close(io);
        standardCleanup(io, null, directory, name);
    };
    const stat = file.stat(io) catch return error.Failed;
    if (stat.kind != .file or stat.nlink != 1) return error.Failed;
    file.setPermissions(io, .fromMode(0o600)) catch return error.Failed;
    transferred = true;
    return file;
}

fn standardWrite(io: std.Io, _: ?*anyopaque, file: std.Io.File, bytes: []const u8) OpsError!void {
    file.writeStreamingAll(io, bytes) catch return error.Failed;
}

fn standardSync(io: std.Io, _: ?*anyopaque, file: std.Io.File) OpsError!void {
    file.sync(io) catch return error.Failed;
}

fn standardRename(
    io: std.Io,
    _: ?*anyopaque,
    directory: std.Io.Dir,
    old_name: []const u8,
    new_name: []const u8,
) OpsError!void {
    directory.rename(old_name, directory, new_name, io) catch return error.Failed;
}

fn standardCleanup(io: std.Io, _: ?*anyopaque, directory: std.Io.Dir, name: []const u8) void {
    directory.deleteFile(io, name) catch return;
}

const TestSecureOpen = struct {
    directory: std.Io.Dir,
    base: []const u8,
    replace_on_open: bool = false,

    fn relative(self: *TestSecureOpen, path: []const u8) SecureOpen.Error![]const u8 {
        if (!std.mem.startsWith(u8, path, self.base) or path.len <= self.base.len or
            path[self.base.len] != '/') return error.InvalidPath;
        return path[self.base.len + 1 ..];
    }

    pub fn statAbsolute(
        self: *TestSecureOpen,
        io: std.Io,
        path: []const u8,
    ) SecureOpen.Error!std.Io.File.Stat {
        return self.directory.statFile(
            io,
            try self.relative(path),
            .{ .follow_symlinks = false },
        ) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }

    pub fn openAbsolute(self: *TestSecureOpen, io: std.Io, path: []const u8) SecureOpen.Error!std.Io.File {
        const sub_path = try self.relative(path);
        const file = self.directory.openFile(io, sub_path, .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return error.Failed,
        };
        errdefer file.close(io);
        if (self.replace_on_open) {
            self.replace_on_open = false;
            self.directory.writeFile(io, .{ .sub_path = "replacement.tmp", .data = "external" }) catch
                return error.Failed;
            self.directory.rename("replacement.tmp", self.directory, sub_path, io) catch
                return error.Failed;
        }
        return file;
    }
};

const FixedNonce = struct {
    value: u8 = 1,

    pub fn fillBytes(self: *FixedNonce, bytes: []u8) NonceError!void {
        @memset(bytes, self.value);
        self.value +%= 1;
    }
};

const TestHarness = struct {
    tmp: std.testing.TmpDir,
    directory: std.Io.Dir,
    base: [:0]u8,
    access: TestSecureOpen,
    nonce: FixedNonce = .{},

    fn init() !TestHarness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "private", .fromMode(0o700));
        const directory = try tmp.dir.openDir(std.testing.io, "private", .{});
        errdefer directory.close(std.testing.io);
        const base = try directory.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{
            .tmp = tmp,
            .directory = directory,
            .base = base,
            .access = .{ .directory = directory, .base = base },
        };
    }

    fn deinit(self: *TestHarness) void {
        std.testing.allocator.free(self.base);
        self.directory.close(std.testing.io);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn path(self: *TestHarness) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.base, "target.json" });
    }

    fn inputs(
        self: *TestHarness,
        path_value: []const u8,
        expected: ?Loader.Fingerprint,
        ops: CommitOps,
    ) Inputs {
        return .{
            .allocator = std.testing.allocator,
            .io = std.testing.io,
            .secure_open = SecureOpen.Capability.from(&self.access),
            .nonce_source = NonceSource.from(&self.nonce),
            .commit_ops = ops,
            .path = path_value,
            .expected = expected,
            .temp_prefix = ".zi-atomic-test.",
        };
    }
};

const CollisionOps = struct {
    attempts: usize = 0,

    fn create(
        _: std.Io,
        context: ?*anyopaque,
        _: std.Io.Dir,
        _: []const u8,
    ) CreateTempError!std.Io.File {
        const self: *CollisionOps = @ptrCast(@alignCast(context.?));
        self.attempts += 1;
        return error.Collision;
    }

    fn ops(self: *CollisionOps) CommitOps {
        return .{ .context = self, .create_temp_fn = create };
    }
};

const FailingOps = struct {
    fail: enum { write, sync, rename },
    cleanup_calls: usize = 0,
    base: CommitOps = .standard,

    fn ops(self: *FailingOps) CommitOps {
        return .{
            .context = self,
            .write_fn = write,
            .sync_fn = sync,
            .rename_fn = rename,
            .cleanup_fn = cleanup,
        };
    }

    fn write(io: std.Io, context: ?*anyopaque, file: std.Io.File, bytes: []const u8) OpsError!void {
        const self: *FailingOps = @ptrCast(@alignCast(context.?));
        if (self.fail == .write) return error.Failed;
        return self.base.write_fn(io, self.base.context, file, bytes);
    }

    fn sync(io: std.Io, context: ?*anyopaque, file: std.Io.File) OpsError!void {
        const self: *FailingOps = @ptrCast(@alignCast(context.?));
        if (self.fail == .sync) return error.Failed;
        return self.base.sync_fn(io, self.base.context, file);
    }

    fn rename(
        io: std.Io,
        context: ?*anyopaque,
        directory: std.Io.Dir,
        old_name: []const u8,
        new_name: []const u8,
    ) OpsError!void {
        const self: *FailingOps = @ptrCast(@alignCast(context.?));
        if (self.fail == .rename) return error.Failed;
        return self.base.rename_fn(io, self.base.context, directory, old_name, new_name);
    }

    fn cleanup(io: std.Io, context: ?*anyopaque, directory: std.Io.Dir, name: []const u8) void {
        const self: *FailingOps = @ptrCast(@alignCast(context.?));
        self.cleanup_calls += 1;
        self.base.cleanup_fn(io, self.base.context, directory, name);
    }
};

test "atomic replace writes private bytes and reports installed fingerprint" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const path = try harness.path();
    defer std.testing.allocator.free(path);
    const outcome = try commit(harness.inputs(path, null, .standard), "candidate");
    const installed = outcome.written;
    try std.testing.expectEqual(TargetStatus.unchanged, try checkTarget(harness.inputs(path, installed, .standard)));
    const bytes = try harness.directory.readFileAlloc(
        std.testing.io,
        "target.json",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("candidate", bytes);
    const stat = try harness.directory.statFile(std.testing.io, "target.json", .{});
    try std.testing.expectEqual(@as(u32, 0), stat.permissions.toMode() & 0o077);
}

test "atomic replace detects a renamed destination during descriptor inspection" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const path = try harness.path();
    defer std.testing.allocator.free(path);
    const installed = (try commit(harness.inputs(path, null, .standard), "candidate")).written;
    harness.access.replace_on_open = true;
    try std.testing.expectEqual(TargetStatus.unavailable, try checkTarget(harness.inputs(path, installed, .standard)));
    const bytes = try harness.directory.readFileAlloc(
        std.testing.io,
        "target.json",
        std.testing.allocator,
        .limited(64),
    );
    defer std.testing.allocator.free(bytes);
    try std.testing.expectEqualStrings("external", bytes);
}

test "atomic replace classifies conflicts and unsafe targets and cleans temporary files" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const path = try harness.path();
    defer std.testing.allocator.free(path);
    const first = try commit(harness.inputs(path, null, .standard), "old");
    const expected = first.written;
    try harness.directory.writeFile(std.testing.io, .{ .sub_path = "target.json", .data = "new" });
    try std.testing.expect((try commit(harness.inputs(path, expected, .standard), "candidate")) == .conflict);
    try harness.directory.deleteFile(std.testing.io, "target.json");
    try harness.directory.createDir(std.testing.io, "target.json", .fromMode(0o700));
    try std.testing.expect((try commit(harness.inputs(path, expected, .standard), "candidate")) == .target_unavailable);
    try harness.directory.deleteDir(std.testing.io, "target.json");

    inline for (.{ .write, .sync, .rename }) |failure| {
        var failing: FailingOps = .{ .fail = failure };
        try std.testing.expect((try commit(harness.inputs(path, null, failing.ops()), "candidate")) == .failed);
        try std.testing.expectEqual(@as(usize, 1), failing.cleanup_calls);
    }
}

test "atomic replace exhausts 32 collisions" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const path = try harness.path();
    defer std.testing.allocator.free(path);
    var collisions: CollisionOps = .{};
    try std.testing.expect((try commit(harness.inputs(path, null, collisions.ops()), "candidate")) == .failed);
    try std.testing.expectEqual(@as(usize, 32), collisions.attempts);
}

fn exerciseTargetCheckAllocations(
    allocator: std.mem.Allocator,
    harness: *TestHarness,
    path: []const u8,
    expected: Loader.Fingerprint,
) !void {
    var inputs = harness.inputs(path, expected, .standard);
    inputs.allocator = allocator;
    try std.testing.expectEqual(TargetStatus.unchanged, try checkTarget(inputs));
}

test "atomic replace target checks release every allocation on OOM" {
    var harness = try TestHarness.init();
    defer harness.deinit();
    const path = try harness.path();
    defer std.testing.allocator.free(path);
    const installed = (try commit(harness.inputs(path, null, .standard), "candidate")).written;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseTargetCheckAllocations,
        .{ &harness, path, installed },
    );
}

test "atomic replace comparison distinguishes conflicts and unsafe targets" {
    const digest_a: [std.crypto.hash.Blake3.digest_length]u8 = @splat(1);
    var digest_b = digest_a;
    digest_b[0] = 2;
    const expected: Loader.Fingerprint = .{
        .inode = 1,
        .nlink = 1,
        .size = 2,
        .mtime_ns = 3,
        .ctime_ns = 4,
        .digest = digest_a,
    };
    var same = expected;
    same.mtime_ns = 99;
    try std.testing.expectEqual(TargetStatus.unchanged, compareInspection(expected, .{ .fingerprint = same }));
    var changed = expected;
    changed.digest = digest_b;
    try std.testing.expectEqual(TargetStatus.conflict, compareInspection(expected, .{ .fingerprint = changed }));
    try std.testing.expectEqual(TargetStatus.conflict, compareInspection(expected, .missing));
    try std.testing.expectEqual(TargetStatus.unavailable, compareInspection(expected, .unsafe));
    try std.testing.expectEqual(TargetStatus.unchanged, compareInspection(null, .missing));
    try std.testing.expectEqual(TargetStatus.conflict, compareInspection(null, .{ .fingerprint = changed }));
}
