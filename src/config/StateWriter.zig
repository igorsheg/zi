const std = @import("std");
const AtomicReplace = @import("AtomicReplace.zig");
const Document = @import("Document.zig");
const Loader = @import("Loader.zig");
const SecureOpen = @import("SecureOpen.zig");
const Store = @import("Store.zig");

const StateWriter = @This();

pub const maximum_file_bytes: usize = Loader.maximum_file_bytes;
const temp_prefix = ".zi-state.tmp.";

pub const Selection = struct {
    provider: []const u8,
    model: ?[]const u8,
    effort: ?[]const u8,
    /// A name persists only the preset stance, as hax does after applying a
    /// preset. Null persists an explicit selection and removes that stance.
    preset: ?[]const u8 = null,
};

pub const Outcome = enum { unchanged, written, unavailable, failed };

pub const Writer = struct {
    context: *anyopaque,
    write_fn: *const fn (*anyopaque, Selection) error{OutOfMemory}!Outcome,

    pub fn write(self: Writer, selection: Selection) error{OutOfMemory}!Outcome {
        return self.write_fn(self.context, selection);
    }
};

pub const NonceError = AtomicReplace.NonceError;
pub const NonceSource = AtomicReplace.NonceSource;
pub const OpsError = AtomicReplace.OpsError;
pub const CreateTempError = AtomicReplace.CreateTempError;
pub const CommitOps = AtomicReplace.CommitOps;

pub const Options = struct {
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource = null,
    commit_ops: CommitOps = .standard,
};

pub const Init = union(enum) {
    unavailable,
    owner: *Owner,

    pub fn deinit(self: *Init) void {
        switch (self.*) {
            .unavailable => {},
            .owner => |owner| owner.deinit(),
        }
        self.* = undefined;
    }
};

/// Address-stable owner for the state path, expected on-disk fingerprint, and
/// document slot borrowed by config.Store. A successful write replaces the
/// contents of the slot without changing its address.
pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    nonce_source: ?NonceSource,
    commit_ops: CommitOps,
    path: []u8,
    document_value: Document,
    expected: ?Loader.Fingerprint,

    /// Consumes result for every returned Init outcome. Only a coherently
    /// loaded document or a missing file can initialize a writable owner.
    pub fn init(
        allocator: std.mem.Allocator,
        io: std.Io,
        result: *Loader.Result,
        options: Options,
    ) error{OutOfMemory}!Init {
        const source_valid = switch (result.outcome) {
            .loaded => result.document != null and result.fingerprint != null,
            .empty => result.document == null and result.fingerprint != null,
            .missing => result.document == null and result.fingerprint == null,
            else => false,
        };
        const path_valid = result.path.len != 0 and result.path.len <= Loader.maximum_path_bytes and
            result.path.len < std.fs.max_path_bytes and result.path[0] == '/' and
            std.mem.indexOfScalar(u8, result.path, 0) == null and
            std.unicode.utf8ValidateSlice(result.path);
        if (!source_valid or !path_valid) {
            result.deinit(allocator);
            return .unavailable;
        }

        var document_owned = result.document == null;
        var initial_document = if (result.document) |value|
            value
        else
            Document.parse(allocator, "{}", .{}) catch return error.OutOfMemory;
        errdefer if (document_owned) initial_document.deinit();
        const owner = allocator.create(Owner) catch return error.OutOfMemory;
        errdefer allocator.destroy(owner);

        owner.* = .{
            .allocator = allocator,
            .io = io,
            .secure_open = options.secure_open,
            .nonce_source = options.nonce_source,
            .commit_ops = options.commit_ops,
            .path = result.path,
            .document_value = initial_document,
            .expected = result.fingerprint,
        };
        document_owned = false;
        result.* = undefined;
        return .{ .owner = owner };
    }

    pub fn deinit(self: *Owner) void {
        const allocator = self.allocator;
        defer allocator.destroy(self);
        self.document_value.deinit();
        allocator.free(self.path);
        self.* = undefined;
    }

    pub fn writer(self: *Owner) Writer {
        return .{ .context = self, .write_fn = writeErased };
    }

    pub fn document(self: *const Owner) *const Document {
        return &self.document_value;
    }

    pub fn statePath(self: *const Owner) []const u8 {
        return self.path;
    }

    fn writeErased(context: *anyopaque, selection: Selection) error{OutOfMemory}!Outcome {
        const self: *Owner = @ptrCast(@alignCast(context));
        return self.write(selection);
    }

    fn write(self: *Owner, selection: Selection) error{OutOfMemory}!Outcome {
        var candidate = cloneDocument(self.allocator, &self.document_value) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failed,
        };
        errdefer candidate.deinit();
        const changed = applySelection(&candidate, selection) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return .failed,
        };
        if (!changed) {
            candidate.deinit();
            return if (try self.targetUnchanged()) .unchanged else .failed;
        }

        var wiping: Document.WipingAllocator = .{ .backing = self.allocator };
        const scratch = wiping.allocator();
        const storage = scratch.alloc(u8, maximum_file_bytes + 1) catch return error.OutOfMemory;
        defer scratch.free(storage);
        var json_writer = std.Io.Writer.fixed(storage);
        std.json.Stringify.value(candidate.parsed.value, .{
            .whitespace = .indent_2,
        }, &json_writer) catch {
            candidate.deinit();
            return .failed;
        };
        const bytes = json_writer.buffered();
        if (bytes.len > maximum_file_bytes) {
            candidate.deinit();
            return .failed;
        }

        const committed = try self.commit(bytes);
        if (committed != .written) {
            candidate.deinit();
            return committed;
        }
        self.document_value.deinit();
        self.document_value = candidate;
        return .written;
    }

    fn commit(self: *Owner, bytes: []const u8) error{OutOfMemory}!Outcome {
        const result = try AtomicReplace.commit(self.atomicInputs(), bytes);
        return switch (result) {
            .written => |fingerprint_value| outcome: {
                self.expected = fingerprint_value;
                break :outcome .written;
            },
            .unavailable => .unavailable,
            .conflict, .target_unavailable, .failed => .failed,
        };
    }

    fn targetUnchanged(self: *Owner) error{OutOfMemory}!bool {
        return (try AtomicReplace.checkTarget(self.atomicInputs())) == .unchanged;
    }

    fn atomicInputs(self: *Owner) AtomicReplace.Inputs {
        return .{
            .allocator = self.allocator,
            .io = self.io,
            .secure_open = self.secure_open,
            .nonce_source = self.nonce_source,
            .commit_ops = self.commit_ops,
            .path = self.path,
            .expected = self.expected,
            .temp_prefix = temp_prefix,
        };
    }
};

const ApplyError = error{ OutOfMemory, Invalid };

fn cloneDocument(allocator: std.mem.Allocator, source: *const Document) Document.Error!Document {
    var wiping: Document.WipingAllocator = .{ .backing = allocator };
    const scratch = wiping.allocator();
    const bytes = std.json.Stringify.valueAlloc(scratch, source.parsed.value, .{}) catch
        return error.OutOfMemory;
    defer scratch.free(bytes);
    return Document.parse(allocator, bytes, .{});
}

fn applySelection(document: *Document, selection: Selection) ApplyError!bool {
    if (selection.preset) |preset| {
        if (preset.len > Document.maximum_string_bytes) return error.Invalid;
        return setString(document, "preset", preset);
    }
    if (selection.provider.len == 0 or selection.provider.len > Document.maximum_string_bytes) return error.Invalid;
    if (selection.model) |value| if (value.len > Document.maximum_string_bytes) return error.Invalid;
    if (selection.effort) |value| if (value.len > Document.maximum_string_bytes) return error.Invalid;

    var changed = removeMember(document, "preset");
    const previous = document.parsed.value.object.getPtr("provider");
    const provider_changed = previous == null or previous.?.* != .string or
        !providerIdsEqual(previous.?.string, selection.provider);
    changed = (try setString(document, "provider", selection.provider)) or changed;
    if (selection.model) |model| {
        changed = (try setString(document, "model", model)) or changed;
    } else if (provider_changed) {
        changed = (try setString(document, "model", Store.default_sentinel)) or changed;
    }
    if (selection.effort) |effort| {
        changed = (try setString(document, "effort", effort)) or changed;
    } else if (provider_changed) {
        changed = (try setString(document, "effort", Store.default_sentinel)) or changed;
    }
    return changed;
}

fn providerIdsEqual(left: []const u8, right: []const u8) bool {
    const canonical_left = if (std.mem.eql(u8, left, "llama.cpp")) "llamacpp" else left;
    const canonical_right = if (std.mem.eql(u8, right, "llama.cpp")) "llamacpp" else right;
    return std.mem.eql(u8, canonical_left, canonical_right);
}

fn setString(document: *Document, key: []const u8, value: []const u8) error{OutOfMemory}!bool {
    var object = &document.parsed.value.object;
    if (object.getPtr(key)) |existing| {
        if (existing.* == .string and std.mem.eql(u8, existing.string, value)) return false;
    }
    const allocator = document.parsed.arena.allocator();
    const owned = allocator.dupe(u8, value) catch return error.OutOfMemory;
    object.put(allocator, key, .{ .string = owned }) catch return error.OutOfMemory;
    return true;
}

fn removeMember(document: *Document, key: []const u8) bool {
    return document.parsed.value.object.swapRemove(key);
}

const TestSecureOpen = struct {
    directory: std.Io.Dir,
    base: []const u8,

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
        return self.directory.openFile(io, try self.relative(path), .{ .mode = .read_only }) catch |err| switch (err) {
            error.FileNotFound => error.FileNotFound,
            else => error.Failed,
        };
    }
};

const FixedNonce = struct {
    value: u8 = 1,

    pub fn fillBytes(self: *FixedNonce, bytes: []u8) NonceError!void {
        @memset(bytes, self.value);
        self.value +%= 1;
    }
};

const Harness = struct {
    tmp: std.testing.TmpDir,
    base: [:0]u8,
    access: TestSecureOpen,
    nonce: FixedNonce = .{},

    fn init() !Harness {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
        return .{
            .tmp = tmp,
            .base = base,
            .access = .{ .directory = tmp.dir, .base = base },
        };
    }

    fn deinit(self: *Harness) void {
        std.testing.allocator.free(self.base);
        self.tmp.cleanup();
        self.* = undefined;
    }

    fn path(self: *Harness) ![]u8 {
        return std.fs.path.join(std.testing.allocator, &.{ self.base, "state.json" });
    }

    fn load(self: *Harness) !Loader.Result {
        const path_value = try self.path();
        defer std.testing.allocator.free(path_value);
        return Loader.loadTierFile(
            std.testing.allocator,
            std.testing.io,
            SecureOpen.Capability.from(&self.access),
            path_value,
        );
    }

    fn owner(self: *Harness, result: *Loader.Result, ops: CommitOps) !*Owner {
        const initialized = try Owner.init(std.testing.allocator, std.testing.io, result, .{
            .secure_open = SecureOpen.Capability.from(&self.access),
            .nonce_source = NonceSource.from(&self.nonce),
            .commit_ops = ops,
        });
        return switch (initialized) {
            .owner => |value| value,
            .unavailable => error.TestUnexpectedResult,
        };
    }
};

fn readState(harness: *Harness) ![]u8 {
    return harness.tmp.dir.readFileAlloc(
        std.testing.io,
        "state.json",
        std.testing.allocator,
        .limited(maximum_file_bytes),
    );
}

test "missing state initializes a stable document slot and writes private state" {
    var harness = try Harness.init();
    defer harness.deinit();
    var loaded = try harness.load();
    try std.testing.expectEqual(Loader.Outcome.missing, loaded.outcome);
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    const slot = owner.document();
    try std.testing.expectEqual(Outcome.written, try owner.writer().write(.{
        .provider = "openai",
        .model = null,
        .effort = null,
    }));
    try std.testing.expect(slot == owner.document());
    try std.testing.expectEqualStrings("openai", owner.document().lookup("provider").?.string);
    try std.testing.expectEqualStrings(Store.default_sentinel, owner.document().lookup("model").?.string);
    const stat = try harness.tmp.dir.statFile(std.testing.io, "state.json", .{ .follow_symlinks = false });
    try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
}

test "empty state is a writable race-checked baseline" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = " \n\t" });
    var loaded = try harness.load();
    try std.testing.expectEqual(Loader.Outcome.empty, loaded.outcome);
    try std.testing.expect(loaded.fingerprint != null);
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.written, try owner.writer().write(.{
        .provider = "openai",
        .model = null,
        .effort = null,
    }));
    try std.testing.expectEqualStrings("openai", owner.document().lookup("provider").?.string);
}

test "loaded state preserves unknown JSON and hax selection semantics" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "state.json",
        .data = "{\"unknown\":{\"answer\":42},\"preset\":\"work\"," ++
            "\"provider\":\"old\",\"model\":\"m\",\"effort\":\"low\"}",
    });
    var loaded = try harness.load();
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.written, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = "high",
    }));
    try std.testing.expect(owner.document().lookup("preset") == null);
    try std.testing.expectEqualStrings(Store.default_sentinel, owner.document().lookup("model").?.string);
    try std.testing.expectEqualStrings("high", owner.document().lookup("effort").?.string);
    try std.testing.expectEqual(@as(i64, 42), owner.document().lookup("unknown.answer").?.integer);

    try std.testing.expectEqual(Outcome.written, try owner.writer().write(.{
        .provider = "ignored",
        .model = null,
        .effort = null,
        .preset = "review",
    }));
    try std.testing.expectEqualStrings("review", owner.document().lookup("preset").?.string);
    try std.testing.expectEqualStrings("new", owner.document().lookup("provider").?.string);
}

test "an unchanged selection performs no commit" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "state.json",
        .data = "{\"provider\":\"llama.cpp\",\"model\":\"m\",\"effort\":\"e\"}",
    });
    var loaded = try harness.load();
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.unchanged, try owner.writer().write(.{
        .provider = "llama.cpp",
        .model = null,
        .effort = null,
    }));
}

const FailingOps = struct {
    fail: enum { write, sync, rename },
    base: CommitOps = .standard,

    fn ops(self: *FailingOps) CommitOps {
        return .{
            .context = self,
            .write_fn = write,
            .sync_fn = sync,
            .rename_fn = rename,
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
};

const EarlyFailureOps = struct {
    fn makeParent(_: std.Io, _: ?*anyopaque, _: []const u8) OpsError!void {
        return error.Failed;
    }

    fn openParent(_: std.Io, _: ?*anyopaque, _: []const u8) OpsError!std.Io.Dir {
        return error.Failed;
    }

    fn createTemp(_: std.Io, _: ?*anyopaque, _: std.Io.Dir, _: []const u8) CreateTempError!std.Io.File {
        return error.Failed;
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

const ReplacedTempOps = struct {
    directory: std.Io.Dir,
    base: CommitOps = .standard,

    fn ops(self: *ReplacedTempOps) CommitOps {
        return .{ .context = self, .sync_fn = sync };
    }

    fn sync(io: std.Io, context: ?*anyopaque, file: std.Io.File) OpsError!void {
        const self: *ReplacedTempOps = @ptrCast(@alignCast(context.?));
        try self.base.sync_fn(io, self.base.context, file);
        var nonce: [16]u8 = undefined;
        @memset(&nonce, 1);
        var name_buffer: [temp_prefix.len + nonce.len * 2]u8 = undefined;
        const name = std.fmt.bufPrint(&name_buffer, temp_prefix ++ "{x}", .{nonce}) catch unreachable;
        self.directory.deleteFile(io, name) catch return error.Failed;
        const replacement = self.directory.createFile(io, name, .{
            .exclusive = true,
            .permissions = .fromMode(0o600),
        }) catch return error.Failed;
        replacement.close(io);
    }
};

const FailingNonce = struct {
    pub fn fillBytes(_: *FailingNonce, _: []u8) NonceError!void {
        return error.Failed;
    }
};

test "parent temp and nonce failures are typed and retain memory" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = "{\"provider\":\"old\"}" });

    const cases = [_]CommitOps{
        .{ .make_parent_fn = EarlyFailureOps.makeParent },
        .{ .open_parent_fn = EarlyFailureOps.openParent },
        .{ .create_temp_fn = EarlyFailureOps.createTemp },
    };
    for (cases, 0..) |ops, index| {
        var loaded = try harness.load();
        const owner = try harness.owner(&loaded, ops);
        const outcome = try owner.writer().write(.{ .provider = "new", .model = null, .effort = null });
        try std.testing.expectEqual(if (index < 2) Outcome.unavailable else Outcome.failed, outcome);
        try std.testing.expectEqualStrings("old", owner.document().lookup("provider").?.string);
        owner.deinit();
    }

    var loaded = try harness.load();
    var nonce: FailingNonce = .{};
    const initialized = try Owner.init(std.testing.allocator, std.testing.io, &loaded, .{
        .secure_open = SecureOpen.Capability.from(&harness.access),
        .nonce_source = NonceSource.from(&nonce),
    });
    const owner = initialized.owner;
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.unavailable, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
}

test "commit rejects a group-writable opened parent" {
    var harness = try Harness.init();
    defer harness.deinit();
    var loaded = try harness.load();
    try harness.tmp.dir.setPermissions(std.testing.io, .fromMode(0o770));
    defer harness.tmp.dir.setPermissions(std.testing.io, .fromMode(0o700)) catch {};
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.unavailable, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
}

test "commit verifies the named temporary file against its descriptor before rename" {
    var harness = try Harness.init();
    defer harness.deinit();
    var loaded = try harness.load();
    var replacing: ReplacedTempOps = .{ .directory = harness.tmp.dir };
    const owner = try harness.owner(&loaded, replacing.ops());
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
    var after = try harness.load();
    defer after.deinit(std.testing.allocator);
    try std.testing.expectEqual(Loader.Outcome.missing, after.outcome);
}

test "temporary name collisions use all 32 bounded attempts" {
    var harness = try Harness.init();
    defer harness.deinit();
    var loaded = try harness.load();
    var collisions: CollisionOps = .{};
    const owner = try harness.owner(&loaded, collisions.ops());
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
    try std.testing.expectEqual(@as(usize, 32), collisions.attempts);
}

test "content and identity races leave disk and memory unchanged" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = "{\"provider\":\"old\"}" });
    var loaded = try harness.load();
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = "{\"provider\":\"external\"}" });
    try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
    try std.testing.expectEqualStrings("old", owner.document().lookup("provider").?.string);
    const bytes = try readState(&harness);
    defer std.testing.allocator.free(bytes);
    try std.testing.expect(std.mem.indexOf(u8, bytes, "external") != null);
}

test "symlink and nonregular races are rejected" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = "{\"provider\":\"old\"}" });
    var loaded = try harness.load();
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try harness.tmp.dir.rename("state.json", harness.tmp.dir, "real.json", std.testing.io);
    try harness.tmp.dir.symLink(std.testing.io, "real.json", "state.json", .{});
    try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
}

test "write sync and rename failures retain old document and clean temporary files" {
    inline for (.{ .write, .sync, .rename }) |failure| {
        var harness = try Harness.init();
        defer harness.deinit();
        try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = "{\"provider\":\"old\"}" });
        var loaded = try harness.load();
        var failing: FailingOps = .{ .fail = failure };
        const owner = try harness.owner(&loaded, failing.ops());
        defer owner.deinit();
        try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
            .provider = "new",
            .model = null,
            .effort = null,
        }));
        try std.testing.expectEqualStrings("old", owner.document().lookup("provider").?.string);
        var directory = try harness.tmp.dir.openDir(std.testing.io, ".", .{ .iterate = true });
        defer directory.close(std.testing.io);
        var iterator = directory.iterate();
        while (try iterator.next(std.testing.io)) |entry| {
            try std.testing.expect(!std.mem.startsWith(u8, entry.name, temp_prefix));
        }
    }
}

test "serialized state is bounded to one MiB" {
    var harness = try Harness.init();
    defer harness.deinit();
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(std.testing.allocator);
    try source.appendSlice(std.testing.allocator, "{\"provider\":\"old\"");
    for (0..15) |index| {
        var key: [32]u8 = undefined;
        const prefix = try std.fmt.bufPrint(&key, ",\"padding_{d}\":\"", .{index});
        try source.appendSlice(std.testing.allocator, prefix);
        try source.appendNTimes(std.testing.allocator, 'x', Document.maximum_string_bytes);
        try source.append(std.testing.allocator, '"');
    }
    const tail_prefix = ",\"tail\":\"";
    const tail_suffix = "\"}";
    try source.appendSlice(std.testing.allocator, tail_prefix);
    const remaining = maximum_file_bytes - 1 - source.items.len - tail_suffix.len;
    try std.testing.expect(remaining <= Document.maximum_string_bytes);
    try source.appendNTimes(std.testing.allocator, 'y', remaining);
    try source.appendSlice(std.testing.allocator, tail_suffix);
    try harness.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "state.json", .data = source.items });

    var loaded = try harness.load();
    const owner = try harness.owner(&loaded, .standard);
    defer owner.deinit();
    try std.testing.expectEqual(Outcome.failed, try owner.writer().write(.{
        .provider = "new",
        .model = null,
        .effort = null,
    }));
    const stat = try harness.tmp.dir.statFile(std.testing.io, "state.json", .{});
    try std.testing.expectEqual(@as(u64, maximum_file_bytes - 1), stat.size);
}

fn noOpRename(
    _: std.Io,
    _: ?*anyopaque,
    _: std.Io.Dir,
    _: []const u8,
    _: []const u8,
) OpsError!void {}

fn exerciseAllocationFailures(allocator: std.mem.Allocator, path: []const u8, access: SecureOpen.Capability) !void {
    var loaded = try Loader.loadTierFile(allocator, std.testing.io, access, path);
    var loaded_owned = true;
    defer if (loaded_owned) loaded.deinit(allocator);
    var nonce: FixedNonce = .{};
    const initialized = try Owner.init(allocator, std.testing.io, &loaded, .{
        .secure_open = access,
        .nonce_source = NonceSource.from(&nonce),
        .commit_ops = .{ .rename_fn = noOpRename },
    });
    var owner = switch (initialized) {
        .owner => |value| value,
        .unavailable => {
            loaded_owned = false;
            return error.TestUnexpectedResult;
        },
    };
    loaded_owned = false;
    defer owner.deinit();
    _ = try owner.writer().write(.{ .provider = "new", .model = "m", .effort = "high" });
}

test "owner initialization and write release every allocation on OOM" {
    var harness = try Harness.init();
    defer harness.deinit();
    try harness.tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "state.json",
        .data = "{\"provider\":\"old\",\"unknown\":{\"secret\":\"value\"}}",
    });
    const path_value = try harness.path();
    defer std.testing.allocator.free(path_value);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseAllocationFailures,
        .{ path_value, SecureOpen.Capability.from(&harness.access) },
    );
}
