const std = @import("std");

pub const max_file_size: usize = 1024 * 1024;
pub const max_name_size: usize = 128;
pub const max_temp_attempts: usize = 32;
const max_derived_name_size: usize = max_name_size * 2;

pub const Error = error{
    Invalid,
    TooLarge,
    Busy,
    NotRegular,
    IoFailure,
    OutOfMemory,
    Canceled,
    Poisoned,
};

/// Publication knowledge for the most recent transaction mutation.
pub const MutationState = enum {
    not_published,
    uncertain,
    published,
};

/// Move-only owned read result. Deinitialize exactly once.
pub const ReadResult = union(enum) {
    missing,
    bytes: []u8,

    pub fn deinit(result: *ReadResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .missing => {},
            .bytes => |bytes| {
                std.crypto.secureZero(u8, bytes);
                allocator.free(bytes);
            },
        }
        result.* = undefined;
    }
};

/// Move-only bounded read paired with metadata from the opened descriptor.
pub const ReadStatResult = union(enum) {
    missing,
    oversize: u64,
    file: struct {
        bytes: []u8,
        stat: std.Io.File.Stat,
    },

    pub fn deinit(result: *ReadStatResult, allocator: std.mem.Allocator) void {
        switch (result.*) {
            .missing, .oversize => {},
            .file => |value| {
                std.crypto.secureZero(u8, value.bytes);
                allocator.free(value.bytes);
            },
        }
        result.* = undefined;
    }
};

/// An erased, caller-owned source of unpredictable bytes. Its context must
/// outlive the call using it. Implementations should map cancellation to
/// `error.Canceled`.
pub const NonceSource = struct {
    context: *anyopaque,
    fill_fn: *const fn (*anyopaque, []u8) Error!void,

    pub fn fill(source: NonceSource, bytes: []u8) Error!void {
        return source.fill_fn(source.context, bytes);
    }
};

/// Injectable seam for fault testing the durability-critical commit steps.
/// Production callers normally use `CommitOps.standard`.
pub const CommitOps = struct {
    context: ?*anyopaque = null,
    write_fn: *const fn (std.Io, ?*anyopaque, std.Io.File, []const u8) Error!void = standardWrite,
    sync_fn: *const fn (std.Io, ?*anyopaque, std.Io.File) Error!void = standardSync,
    rename_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8, []const u8) Error!void = standardRename,
    dir_sync_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir) Error!void = standardDirSync,
    delete_temp_fn: *const fn (
        std.Io,
        ?*anyopaque,
        std.Io.Dir,
        []const u8,
    ) (Error || error{FileNotFound})!void = standardDeleteTemp,

    pub const standard: CommitOps = .{};

    fn standardWrite(io: std.Io, _: ?*anyopaque, file: std.Io.File, bytes: []const u8) Error!void {
        file.writeStreamingAll(io, bytes) catch |err| return mapIo(err);
    }

    fn standardSync(io: std.Io, _: ?*anyopaque, file: std.Io.File) Error!void {
        file.sync(io) catch |err| return mapIo(err);
    }

    fn standardRename(
        io: std.Io,
        _: ?*anyopaque,
        root: std.Io.Dir,
        old_name: []const u8,
        new_name: []const u8,
    ) Error!void {
        root.rename(old_name, root, new_name, io) catch |err| return mapIo(err);
    }

    fn standardDeleteTemp(
        io: std.Io,
        _: ?*anyopaque,
        root: std.Io.Dir,
        name: []const u8,
    ) (Error || error{FileNotFound})!void {
        root.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => return error.FileNotFound,
            else => return mapIo(err),
        };
    }

    fn standardDirSync(io: std.Io, _: ?*anyopaque, root: std.Io.Dir) Error!void {
        // On Zi's Unix targets a directory and file share the same descriptor
        // handle type. This borrowed facade is synced but never closed.
        const file: std.Io.File = .{ .handle = root.handle, .flags = .{ .nonblocking = false } };
        file.sync(io) catch |err| return mapIo(err);
    }
};

/// A borrowed view of a trusted private directory. `root`, `io`, and every
/// injected test context must outlive the store and its transactions. No
/// uncoordinated writer may mutate this namespace. The store never closes it.
pub const Store = struct {
    io: std.Io,
    root: std.Io.Dir,

    pub fn init(io: std.Io, root: std.Io.Dir) Store {
        return .{ .io = io, .root = root };
    }

    pub fn read(store: Store, allocator: std.mem.Allocator, name: []const u8) Error!ReadResult {
        return store.readLimited(allocator, name, max_file_size);
    }

    /// Reads a managed file with a caller-selected bound. The namespace and
    /// regular-file checks are identical to `read`.
    pub fn readLimited(
        store: Store,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_bytes: usize,
    ) Error!ReadResult {
        try validateName(name);
        var result = try readFromDirStat(allocator, store.io, store.root, name, max_bytes);
        return switch (result) {
            .missing => .missing,
            .oversize => return error.TooLarge,
            .file => |value| transfer: {
                result = undefined;
                break :transfer .{ .bytes = value.bytes };
            },
        };
    }

    pub fn readLimitedStat(
        store: Store,
        allocator: std.mem.Allocator,
        name: []const u8,
        max_bytes: usize,
    ) Error!ReadStatResult {
        try validateName(name);
        return readFromDirStat(allocator, store.io, store.root, name, max_bytes);
    }

    /// The returned move-only transaction owns its lock file handle and must
    /// be deinitialized exactly once.
    pub fn begin(store: Store, name: []const u8) Error!Transaction {
        try validateName(name);

        var lock_name_buffer: [max_derived_name_size]u8 = undefined;
        const lock_name = lockName(&lock_name_buffer, name) catch return error.Invalid;

        const permissions = std.Io.File.Permissions.fromMode(0o600);
        _ = try existingRegular(store.io, store.root, lock_name);
        var lock_file = store.root.createFile(store.io, lock_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = permissions,
            .resolve_beneath = true,
        }) catch |create_err| switch (create_err) {
            error.PathAlreadyExists => existing: {
                if (!(try existingRegular(store.io, store.root, lock_name))) return error.IoFailure;
                break :existing store.root.openFile(store.io, lock_name, .{
                    .mode = .read_write,
                    .allow_directory = false,
                    .follow_symlinks = false,
                    .resolve_beneath = true,
                }) catch |open_err| return mapOpen(open_err);
            },
            else => return mapOpen(create_err),
        };
        errdefer lock_file.close(store.io);

        const stat = lock_file.stat(store.io) catch |err| return mapIo(err);
        if (stat.kind != .file or stat.nlink != 1) return error.NotRegular;
        if (!(lock_file.tryLock(store.io, .exclusive) catch |err| return mapIo(err))) return error.Busy;
        lock_file.setPermissions(store.io, permissions) catch |err| return mapIo(err);

        var transaction: Transaction = .{
            .io = store.io,
            .root = store.root,
            .file = lock_file,
            .name_len = name.len,
        };
        @memcpy(transaction.name_buffer[0..name.len], name);
        return transaction;
    }
};

/// Move-only owner. Copying a Transaction and deinitializing both copies is invalid.
pub const Transaction = struct {
    io: std.Io,
    root: std.Io.Dir,
    file: std.Io.File,
    name_buffer: [max_name_size]u8 = undefined,
    name_len: usize,
    poisoned: bool = false,
    mutation_state: MutationState = .not_published,
    orphan_name_buffer: [max_derived_name_size]u8 = undefined,
    orphan_name_len: usize = 0,

    fn name(transaction: *const Transaction) []const u8 {
        return transaction.name_buffer[0..transaction.name_len];
    }

    pub fn deinit(transaction: *Transaction) void {
        transaction.file.unlock(transaction.io);
        transaction.file.close(transaction.io);
        transaction.* = undefined;
    }

    pub fn isPoisoned(transaction: *const Transaction) bool {
        return transaction.poisoned;
    }

    pub fn mutationState(transaction: *const Transaction) MutationState {
        return transaction.mutation_state;
    }

    /// A 0600 temporary leaf that could not be cleaned after a failed commit.
    pub fn orphanName(transaction: *const Transaction) ?[]const u8 {
        if (transaction.orphan_name_len == 0) return null;
        return transaction.orphan_name_buffer[0..transaction.orphan_name_len];
    }

    /// Deletes one exact reported temporary leaf while this target's intrinsic lock is held.
    /// This remains available on a poisoned transaction so callers can remediate an orphan.
    pub fn cleanupOrphan(transaction: *Transaction, orphan_name: []const u8) Error!bool {
        return transaction.cleanupOrphanWithOps(orphan_name, .standard);
    }

    pub fn cleanupOrphanWithOps(
        transaction: *Transaction,
        orphan_name: []const u8,
        commit_ops: CommitOps,
    ) Error!bool {
        var prefix_buffer: [max_derived_name_size]u8 = undefined;
        const prefix = std.fmt.bufPrint(&prefix_buffer, ".zi-tmp-{s}-", .{transaction.name()}) catch
            return error.Invalid;
        if (!std.mem.startsWith(u8, orphan_name, prefix) or orphan_name.len != prefix.len + 32) {
            return error.Invalid;
        }
        for (orphan_name[prefix.len..]) |byte| if (!std.ascii.isHex(byte) or std.ascii.isUpper(byte)) {
            return error.Invalid;
        };
        const is_reported = std.mem.eql(u8, transaction.orphanName() orelse "", orphan_name);
        if (!(try existingRegular(transaction.io, transaction.root, orphan_name))) {
            if (!is_reported) return false;
            transaction.mutation_state = .uncertain;
            try commit_ops.dir_sync_fn(transaction.io, commit_ops.context, transaction.root);
            transaction.mutation_state = .published;
            transaction.orphan_name_len = 0;
            return true;
        }
        transaction.mutation_state = .uncertain;
        transaction.root.deleteFile(transaction.io, orphan_name) catch |err| switch (err) {
            error.FileNotFound => {
                if (!is_reported) {
                    transaction.mutation_state = .not_published;
                    return false;
                }
            },
            error.Canceled => return error.Canceled,
            else => return error.IoFailure,
        };
        try commit_ops.dir_sync_fn(transaction.io, commit_ops.context, transaction.root);
        transaction.mutation_state = .published;
        if (is_reported) transaction.orphan_name_len = 0;
        return true;
    }

    pub fn readCurrent(transaction: *Transaction, allocator: std.mem.Allocator) Error!ReadResult {
        return transaction.readCurrentLimited(allocator, max_file_size);
    }

    pub fn readCurrentLimited(
        transaction: *Transaction,
        allocator: std.mem.Allocator,
        max_bytes: usize,
    ) Error!ReadResult {
        if (transaction.poisoned) return error.Poisoned;
        var result = try readFromDirStat(allocator, transaction.io, transaction.root, transaction.name(), max_bytes);
        return switch (result) {
            .missing => .missing,
            .oversize => return error.TooLarge,
            .file => |value| transfer: {
                result = undefined;
                break :transfer .{ .bytes = value.bytes };
            },
        };
    }

    pub fn replace(transaction: *Transaction, bytes: []const u8, nonce_source: NonceSource) Error!void {
        return transaction.replaceLimitedWithOps(bytes, max_file_size, nonce_source, .standard);
    }

    pub fn replaceWithOps(
        transaction: *Transaction,
        bytes: []const u8,
        nonce_source: NonceSource,
        commit_ops: CommitOps,
    ) Error!void {
        return transaction.replaceLimitedWithOps(bytes, max_file_size, nonce_source, commit_ops);
    }

    pub fn replaceLimited(
        transaction: *Transaction,
        bytes: []const u8,
        max_bytes: usize,
        nonce_source: NonceSource,
    ) Error!void {
        return transaction.replaceLimitedWithOps(bytes, max_bytes, nonce_source, .standard);
    }

    pub fn replaceLimitedWithOps(
        transaction: *Transaction,
        bytes: []const u8,
        max_bytes: usize,
        nonce_source: NonceSource,
        commit_ops: CommitOps,
    ) Error!void {
        if (transaction.poisoned) return error.Poisoned;
        transaction.mutation_state = .not_published;
        transaction.orphan_name_len = 0;
        if (bytes.len > max_bytes) return error.TooLarge;
        _ = try existingRegular(transaction.io, transaction.root, transaction.name());

        var nonce: [16]u8 = undefined;
        defer std.crypto.secureZero(u8, &nonce);
        var temp_name_buffer: [max_derived_name_size]u8 = undefined;
        var attempt: usize = 0;
        while (attempt < max_temp_attempts) : (attempt += 1) {
            try nonce_source.fill(&nonce);
            const temp_name = makeTempName(&temp_name_buffer, transaction.name(), nonce) catch return error.Invalid;
            var temp_file = transaction.root.createFile(transaction.io, temp_name, .{
                .read = true,
                .truncate = false,
                .exclusive = true,
                .permissions = std.Io.File.Permissions.fromMode(0o600),
                .resolve_beneath = true,
            }) catch |err| switch (err) {
                error.PathAlreadyExists => continue,
                else => return mapOpen(err),
            };
            var open = true;
            var renamed = false;
            defer {
                if (open) temp_file.close(transaction.io);
                if (!renamed) commit_ops.delete_temp_fn(
                    transaction.io,
                    commit_ops.context,
                    transaction.root,
                    temp_name,
                ) catch |err| switch (err) {
                    error.FileNotFound => {},
                    else => {
                        transaction.orphan_name_len = temp_name.len;
                        @memcpy(transaction.orphan_name_buffer[0..temp_name.len], temp_name);
                    },
                };
            }
            const temp_stat = temp_file.stat(transaction.io) catch |err| return mapIo(err);
            if (temp_stat.kind != .file or temp_stat.nlink != 1) return error.NotRegular;
            temp_file.setPermissions(
                transaction.io,
                std.Io.File.Permissions.fromMode(0o600),
            ) catch |err| return mapIo(err);

            commit_ops.write_fn(
                transaction.io,
                commit_ops.context,
                temp_file,
                bytes,
            ) catch |err| {
                transaction.poisoned = true;
                return err;
            };
            commit_ops.sync_fn(
                transaction.io,
                commit_ops.context,
                temp_file,
            ) catch |err| {
                transaction.poisoned = true;
                return err;
            };
            temp_file.close(transaction.io);
            open = false;
            transaction.mutation_state = .uncertain;
            commit_ops.rename_fn(
                transaction.io,
                commit_ops.context,
                transaction.root,
                temp_name,
                transaction.name(),
            ) catch |err| {
                transaction.poisoned = true;
                return err;
            };
            renamed = true;
            commit_ops.dir_sync_fn(
                transaction.io,
                commit_ops.context,
                transaction.root,
            ) catch |err| {
                transaction.poisoned = true;
                return err;
            };
            transaction.mutation_state = .published;
            return;
        }
        return error.Busy;
    }

    /// Returns false when the target did not exist.
    pub fn remove(transaction: *Transaction) Error!bool {
        return transaction.removeWithOps(.standard);
    }

    fn removeWithOps(transaction: *Transaction, commit_ops: CommitOps) Error!bool {
        if (transaction.poisoned) return error.Poisoned;
        transaction.mutation_state = .not_published;
        transaction.orphan_name_len = 0;
        if (!(try existingRegular(transaction.io, transaction.root, transaction.name()))) return false;
        const target = transaction.root.openFile(transaction.io, transaction.name(), .{
            .mode = .read_only,
            .allow_directory = false,
            .follow_symlinks = false,
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.FileNotFound => return false,
            else => return mapOpen(err),
        };
        defer target.close(transaction.io);
        const stat = target.stat(transaction.io) catch |err| return mapIo(err);
        if (stat.kind != .file or stat.nlink != 1) return error.NotRegular;
        transaction.mutation_state = .uncertain;
        transaction.root.deleteFile(transaction.io, transaction.name()) catch |err| switch (err) {
            error.FileNotFound => {
                transaction.mutation_state = .not_published;
                return false;
            },
            error.Canceled => {
                transaction.poisoned = true;
                return error.Canceled;
            },
            else => {
                transaction.poisoned = true;
                return error.IoFailure;
            },
        };
        commit_ops.dir_sync_fn(
            transaction.io,
            commit_ops.context,
            transaction.root,
        ) catch |err| {
            transaction.poisoned = true;
            return err;
        };
        transaction.mutation_state = .published;
        return true;
    }
};

fn existingRegular(io: std.Io, root: std.Io.Dir, name: []const u8) Error!bool {
    const stat = root.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return mapOpen(err),
    };
    if (stat.kind != .file or stat.nlink != 1) return error.NotRegular;
    return true;
}

fn readFromDirStat(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: std.Io.Dir,
    name: []const u8,
    max_bytes: usize,
) Error!ReadStatResult {
    const named_stat = root.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return mapOpen(err),
    };
    if (named_stat.kind != .file or named_stat.nlink != 1) return error.NotRegular;
    const file = root.openFile(io, name, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return mapOpen(err),
    };
    defer file.close(io);

    const stat = file.stat(io) catch |err| return mapIo(err);
    if (stat.kind != .file or stat.nlink != 1) return error.NotRegular;
    if (stat.size > max_bytes) return .{ .oversize = stat.size };
    const size: usize = @intCast(stat.size);
    const bytes = allocator.alloc(u8, size) catch return error.OutOfMemory;
    errdefer {
        std.crypto.secureZero(u8, bytes);
        allocator.free(bytes);
    }
    const count = file.readPositionalAll(io, bytes, 0) catch |err| return mapIo(err);
    if (count != size) return error.IoFailure;
    var extra: [1]u8 = undefined;
    defer std.crypto.secureZero(u8, &extra);
    const extra_count = file.readPositionalAll(io, &extra, stat.size) catch |err| return mapIo(err);
    if (extra_count != 0) return error.TooLarge;
    return .{ .file = .{ .bytes = bytes, .stat = stat } };
}

fn validateName(name: []const u8) Error!void {
    if (name.len == 0 or name.len > max_name_size) return error.Invalid;
    if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return error.Invalid;
    if (std.mem.indexOfAny(u8, name, "/\\\x00") != null) return error.Invalid;
    if (std.mem.startsWith(u8, name, ".zi-lock-") or
        std.mem.startsWith(u8, name, ".zi-tmp-")) return error.Invalid;
}

fn lockName(buffer: []u8, name: []const u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, ".zi-lock-{s}", .{name});
}

fn makeTempName(buffer: []u8, name: []const u8, nonce: [16]u8) error{NoSpaceLeft}![]const u8 {
    return std.fmt.bufPrint(buffer, ".zi-tmp-{s}-{x}", .{ name, nonce });
}

fn mapOpen(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.SymLinkLoop, error.IsDir, error.NotDir => error.NotRegular,
        else => error.IoFailure,
    };
}

fn mapIo(err: anyerror) Error {
    return switch (err) {
        error.Canceled => error.Canceled,
        error.IsDir => error.NotRegular,
        else => error.IoFailure,
    };
}

test "replace read remove and boundary" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var source_state: u8 = 0;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const state: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, state.*);
            state.* +%= 1;
        }
    };
    const source: NonceSource = .{ .context = &source_state, .fill_fn = Source.fill };
    const store = Store.init(io, temporary.dir);
    var transaction = try store.begin("secret");
    defer transaction.deinit();
    try transaction.replace("value", source);
    try std.testing.expectEqual(MutationState.published, transaction.mutationState());
    var result = try transaction.readCurrent(std.testing.allocator);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("value", result.bytes);
    try std.testing.expect(try transaction.remove());
    try std.testing.expect(!(try transaction.remove()));
}

test "invalid names" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);
    try std.testing.expectError(error.Invalid, store.read(std.testing.allocator, "../x"));
    try std.testing.expectError(error.Invalid, store.read(std.testing.allocator, "a/b"));
    try std.testing.expectError(error.Invalid, store.read(std.testing.allocator, "a\x00b"));
}

test "rejects non-regular and oversized targets" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);

    try temporary.dir.createDir(io, "directory", .default_dir);
    try std.testing.expectError(error.NotRegular, store.read(std.testing.allocator, "directory"));

    try temporary.dir.symLink(io, "missing-target", "link", .{});
    try std.testing.expectError(error.NotRegular, store.read(std.testing.allocator, "link"));

    const large = try temporary.dir.createFile(io, "large", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try large.setLength(io, max_file_size + 1);
    large.close(io);
    try std.testing.expectError(error.TooLarge, store.read(std.testing.allocator, "large"));
}

test "replacement is private and accepts exact size boundary" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var source_state: u8 = 9;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const state: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, state.*);
            state.* +%= 1;
        }
    };
    const source: NonceSource = .{ .context = &source_state, .fill_fn = Source.fill };
    const bytes = try std.testing.allocator.alloc(u8, max_file_size);
    defer std.testing.allocator.free(bytes);
    @memset(bytes, 0xa5);

    const store = Store.init(io, temporary.dir);
    var transaction = try store.begin("boundary");
    defer transaction.deinit();
    try transaction.replace(bytes, source);
    const target = try temporary.dir.openFile(io, "boundary", .{ .follow_symlinks = false });
    defer target.close(io);
    const stat = try target.stat(io);
    try std.testing.expectEqual(max_file_size, stat.size);
    if (std.Io.File.Permissions.has_executable_bit) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), stat.permissions.toMode() & 0o777);
    }
}

test "commit failure poisons transaction and removes temporary file" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var source_state: u8 = 3;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const state: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, state.*);
        }
    };
    const Failing = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) Error!void {
            return error.IoFailure;
        }
    };
    const store = Store.init(io, temporary.dir);
    var transaction = try store.begin("poison");
    defer transaction.deinit();
    const source: NonceSource = .{ .context = &source_state, .fill_fn = Source.fill };
    try std.testing.expectError(
        error.IoFailure,
        transaction.replaceWithOps("data", source, .{ .write_fn = Failing.write }),
    );
    try std.testing.expect(transaction.isPoisoned());
    try std.testing.expectEqual(MutationState.not_published, transaction.mutationState());
    try std.testing.expectError(error.Poisoned, transaction.readCurrent(std.testing.allocator));

    var directory = try temporary.dir.openDir(io, ".", .{ .iterate = true });
    defer directory.close(io);
    var iterator = directory.iterate();
    while (try iterator.next(io)) |entry| {
        try std.testing.expect(std.mem.indexOf(u8, entry.name, ".zi-tmp-") == null);
    }
}

test "intrinsic lock namespace prevents split coordination" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);
    var first = try store.begin("secret");
    defer first.deinit();
    try std.testing.expectError(error.Busy, store.begin("secret"));
    try std.testing.expectError(error.Invalid, store.begin(".zi-lock-secret"));
    try std.testing.expectError(
        error.Invalid,
        store.read(std.testing.allocator, ".zi-tmp-secret-deadbeef"),
    );
}

test "missing target and nonce exhaustion are explicit" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);
    var missing = try store.read(std.testing.allocator, "missing");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing == .missing);

    const nonce: [16]u8 = @splat(7);
    var name_buffer: [max_derived_name_size]u8 = undefined;
    const temp_name = try makeTempName(&name_buffer, "target", nonce);
    const collision = try temporary.dir.createFile(io, temp_name, .{
        .permissions = .fromMode(0o600),
    });
    collision.close(io);
    const Source = struct {
        fn fill(_: *anyopaque, bytes: []u8) Error!void {
            @memset(bytes, 7);
        }
    };
    var ignored: u8 = 0;
    const source: NonceSource = .{ .context = &ignored, .fill_fn = Source.fill };
    var transaction = try store.begin("target");
    defer transaction.deinit();
    try std.testing.expectError(error.Busy, transaction.replace("data", source));
}

test "directory sync and rename failures poison with defined publication state" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var state: u8 = 1;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const value: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, value.*);
            value.* +%= 1;
        }
    };
    const source: NonceSource = .{ .context = &state, .fill_fn = Source.fill };
    const FailRename = struct {
        fn rename(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
            _: []const u8,
        ) Error!void {
            return error.IoFailure;
        }
    };
    const store = Store.init(io, temporary.dir);
    var transaction = try store.begin("rename-fail");
    try std.testing.expectError(
        error.IoFailure,
        transaction.replaceWithOps("secret", source, .{ .rename_fn = FailRename.rename }),
    );
    try std.testing.expect(transaction.isPoisoned());
    try std.testing.expectEqual(MutationState.uncertain, transaction.mutationState());
    transaction.deinit();
    var missing = try Store.init(io, temporary.dir).read(std.testing.allocator, "rename-fail");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing == .missing);

    const FailSync = struct {
        fn sync(_: std.Io, _: ?*anyopaque, _: std.Io.Dir) Error!void {
            return error.IoFailure;
        }
    };
    transaction = try store.begin("sync-fail");
    try std.testing.expectError(
        error.IoFailure,
        transaction.replaceWithOps("published", source, .{ .dir_sync_fn = FailSync.sync }),
    );
    try std.testing.expect(transaction.isPoisoned());
    try std.testing.expectEqual(MutationState.uncertain, transaction.mutationState());
    transaction.deinit();
    var published = try Store.init(io, temporary.dir).read(std.testing.allocator, "sync-fail");
    defer published.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("published", published.bytes);
}

test "transactions reject preexisting special lock and target leaves before open or rename" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);

    try temporary.dir.createDir(io, ".zi-lock-special", .default_dir);
    try std.testing.expectError(error.NotRegular, store.begin("special"));

    try temporary.dir.createDir(io, "directory-target", .default_dir);
    var transaction = try store.begin("directory-target");
    defer transaction.deinit();
    var state: u8 = 0;
    const Source = struct {
        fn fill(_: *anyopaque, bytes: []u8) Error!void {
            @memset(bytes, 0);
        }
    };
    const source: NonceSource = .{ .context = &state, .fill_fn = Source.fill };
    try std.testing.expectError(error.NotRegular, transaction.replace("x", source));
    try std.testing.expectError(error.NotRegular, transaction.remove());

    try temporary.dir.symLink(io, "missing", "symlink-target", .{});
    var symlink_transaction = try store.begin("symlink-target");
    defer symlink_transaction.deinit();
    try std.testing.expectError(error.NotRegular, symlink_transaction.replace("x", source));
    try std.testing.expectError(error.NotRegular, symlink_transaction.remove());
}

test "temporary cleanup reports only a leaf that may remain" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);
    var state: u8 = 4;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const value: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, value.*);
        }
    };
    const source: NonceSource = .{ .context = &state, .fill_fn = Source.fill };
    const FailWrite = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, _: []const u8) Error!void {
            return error.IoFailure;
        }
        fn cleanup(
            _: std.Io,
            _: ?*anyopaque,
            _: std.Io.Dir,
            _: []const u8,
        ) (Error || error{FileNotFound})!void {
            return error.IoFailure;
        }
    };
    var transaction = try store.begin("orphan");
    try std.testing.expectError(
        error.IoFailure,
        transaction.replaceWithOps("x", source, .{
            .write_fn = FailWrite.write,
            .delete_temp_fn = FailWrite.cleanup,
        }),
    );
    const orphan = transaction.orphanName().?;
    const orphan_file = try temporary.dir.openFile(io, orphan, .{ .follow_symlinks = false });
    orphan_file.close(io);
    try std.testing.expectError(error.Invalid, transaction.cleanupOrphan(".zi-tmp-other-00"));
    const FailSync = struct {
        fn sync(_: std.Io, _: ?*anyopaque, _: std.Io.Dir) Error!void {
            return error.IoFailure;
        }
    };
    try std.testing.expectError(
        error.IoFailure,
        transaction.cleanupOrphanWithOps(orphan, .{ .dir_sync_fn = FailSync.sync }),
    );
    try std.testing.expect(transaction.orphanName() != null);
    try std.testing.expectError(
        error.IoFailure,
        transaction.cleanupOrphanWithOps(orphan, .{ .dir_sync_fn = FailSync.sync }),
    );
    try std.testing.expect(transaction.orphanName() != null);
    try std.testing.expect(try transaction.cleanupOrphan(orphan));
    try std.testing.expect(transaction.orphanName() == null);
    try std.testing.expect(!(try transaction.cleanupOrphan(orphan)));
    transaction.deinit();

    const PublishThenFail = struct {
        fn rename(
            operation_io: std.Io,
            _: ?*anyopaque,
            root: std.Io.Dir,
            old_name: []const u8,
            new_name: []const u8,
        ) Error!void {
            try CommitOps.standardRename(operation_io, null, root, old_name, new_name);
            return error.IoFailure;
        }
    };
    transaction = try store.begin("indeterminate");
    try std.testing.expectError(
        error.IoFailure,
        transaction.replaceWithOps("published", source, .{ .rename_fn = PublishThenFail.rename }),
    );
    try std.testing.expect(transaction.orphanName() == null);
    transaction.deinit();
    var published = try store.read(std.testing.allocator, "indeterminate");
    defer published.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("published", published.bytes);
}

test "remove directory sync failure poisons after removal" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const store = Store.init(io, temporary.dir);
    var state: u8 = 1;
    const Source = struct {
        fn fill(context: *anyopaque, bytes: []u8) Error!void {
            const value: *u8 = @ptrCast(@alignCast(context));
            @memset(bytes, value.*);
        }
    };
    const source: NonceSource = .{ .context = &state, .fill_fn = Source.fill };
    var transaction = try store.begin("removed");
    try transaction.replace("x", source);
    const FailSync = struct {
        fn sync(_: std.Io, _: ?*anyopaque, _: std.Io.Dir) Error!void {
            return error.IoFailure;
        }
    };
    try std.testing.expectError(
        error.IoFailure,
        transaction.removeWithOps(.{ .dir_sync_fn = FailSync.sync }),
    );
    try std.testing.expect(transaction.isPoisoned());
    try std.testing.expectEqual(MutationState.uncertain, transaction.mutationState());
    transaction.deinit();
    var missing = try store.read(std.testing.allocator, "removed");
    defer missing.deinit(std.testing.allocator);
    try std.testing.expect(missing == .missing);
}

fn readAllocationExercise(allocator: std.mem.Allocator, store: *const Store) !void {
    var result = try store.readLimited(allocator, "fixture", 4096);
    defer result.deinit(allocator);
}

test "bounded read reports allocation failures without leaks" {
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, "fixture", .{
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    });
    try file.writeStreamingAll(io, "moderate-size-fixture");
    file.close(io);
    const store = Store.init(io, temporary.dir);
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        readAllocationExercise,
        .{&store},
    );
}
