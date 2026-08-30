const std = @import("std");
const builtin = @import("builtin");
const PrivateFileStore = @import("PrivateFileStore.zig");

comptime {
    switch (builtin.os.tag) {
        .macos, .linux, .freebsd, .openbsd, .netbsd, .dragonfly, .illumos => {},
        else => @compileError("PromptHistoryFile supports only Zi's Unix product targets"),
    }
}

pub const maximum_record_bytes: usize = 65_536;
pub const compact_after_records: usize = 3000;
pub const maximum_lock_attempts: usize = 8;
pub const maximum_lock_wait_ms: usize = 40;

const maximum_state_root_bytes: usize = 4096;
const history_name = "history";
const lock_name = ".zi-lock-history";
const temp_prefix = ".zi-tmp-history-";

pub const Mode = enum { read_only, writable };
pub const AppendOutcome = enum { written, too_large, unavailable };

/// A synchronous borrowed view used while startup loads and possibly compacts.
/// `seed` must copy any bytes it retains.
pub const Entries = struct {
    context: *anyopaque,
    seed_fn: *const fn (*anyopaque, []const u8) error{OutOfMemory}!void,
    count_fn: *const fn (*anyopaque) usize,
    entry_fn: *const fn (*anyopaque, usize) ?[]const u8,

    pub fn seed(self: Entries, value: []const u8) error{OutOfMemory}!void {
        return self.seed_fn(self.context, value);
    }

    pub fn count(self: Entries) usize {
        return self.count_fn(self.context);
    }

    pub fn entry(self: Entries, index: usize) ?[]const u8 {
        return self.entry_fn(self.context, index);
    }

    pub fn from(implementation: anytype) Entries {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one) {
            @compileError("Entries.from expects a single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn seed(context: *anyopaque, value: []const u8) error{OutOfMemory}!void {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.seed(self, value);
            }

            fn count(context: *anyopaque) usize {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.count(self);
            }

            fn entry(context: *anyopaque, index: usize) ?[]const u8 {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return Implementation.entry(self, index);
            }
        };
        return .{
            .context = implementation,
            .seed_fn = Adapter.seed,
            .count_fn = Adapter.count,
            .entry_fn = Adapter.entry,
        };
    }
};

pub const Open = union(enum) {
    unavailable,
    read_only,
    writable: Owner,
};

/// Move-only writable history owner. Deinitialize exactly once.
pub const Owner = struct {
    io: std.Io,
    root: std.Io.Dir,
    lock_file: std.Io.File,
    ops: Ops = .standard,

    pub fn deinit(self: *Owner) void {
        self.lock_file.close(self.io);
        self.root.close(self.io);
        self.* = undefined;
    }

    pub fn append(
        self: *Owner,
        allocator: std.mem.Allocator,
        entry_value: []const u8,
    ) error{OutOfMemory}!AppendOutcome {
        return self.appendWithOps(allocator, entry_value, self.ops);
    }

    fn appendWithOps(
        self: *Owner,
        allocator: std.mem.Allocator,
        entry_value: []const u8,
        ops: Ops,
    ) error{OutOfMemory}!AppendOutcome {
        const record = try encodeRecord(allocator, entry_value);
        switch (record) {
            .too_large => return .too_large,
            .bytes => |bytes| {
                defer allocator.free(bytes);
                if (!acquireLock(self.io, self.lock_file, .shared, ops)) return .unavailable;
                defer self.lock_file.unlock(self.io);

                const file = PosixAppend.open(self.root) catch return .unavailable;
                defer file.close(self.io);
                const stat = file.stat(self.io) catch return .unavailable;
                if (stat.kind != .file or stat.nlink != 1) return .unavailable;
                file.setPermissions(self.io, .fromMode(0o600)) catch return .unavailable;
                const written = ops.append_write_fn(
                    self.io,
                    ops.context,
                    file,
                    bytes,
                ) catch return .unavailable;
                return if (written == bytes.len) .written else .unavailable;
            },
        }
    }
};

pub fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    mode: Mode,
    entries: Entries,
    nonce_source: PrivateFileStore.NonceSource,
) error{OutOfMemory}!Open {
    return openWithOps(allocator, io, state_root, mode, entries, nonce_source, .standard);
}

fn openWithOps(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    mode: Mode,
    entries: Entries,
    nonce_source: PrivateFileStore.NonceSource,
    ops: Ops,
) error{OutOfMemory}!Open {
    if (!validStateRoot(state_root)) return .unavailable;
    return switch (mode) {
        .read_only => openReadOnly(allocator, io, state_root, entries, ops),
        .writable => openWritable(allocator, io, state_root, entries, nonce_source, ops),
    };
}

fn openReadOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    entries: Entries,
    ops: Ops,
) error{OutOfMemory}!Open {
    const root = std.Io.Dir.openDir(.cwd(), io, state_root, .{
        .follow_symlinks = false,
    }) catch return .read_only;
    defer root.close(io);

    const lock_file = openExistingRegular(io, root, lock_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return .unavailable,
    };
    defer if (lock_file) |file| file.close(io);

    if (lock_file) |file| {
        if (!acquireLock(io, file, .shared, ops)) return .unavailable;
        defer file.unlock(io);
    }
    const history = openExistingRegular(io, root, history_name, .read_only) catch |err| switch (err) {
        error.FileNotFound => return .read_only,
        else => return .unavailable,
    };
    defer history.close(io);
    const loaded = try loadOpened(allocator, io, history, entries);
    return if (loaded.ok) .read_only else .unavailable;
}

fn openWritable(
    allocator: std.mem.Allocator,
    io: std.Io,
    state_root: []const u8,
    entries: Entries,
    nonce_source: PrivateFileStore.NonceSource,
    ops: Ops,
) error{OutOfMemory}!Open {
    _ = std.Io.Dir.createDirPathStatus(
        .cwd(),
        io,
        state_root,
        .fromMode(0o700),
    ) catch return .unavailable;
    const root = std.Io.Dir.openDir(.cwd(), io, state_root, .{
        .iterate = true,
        .follow_symlinks = false,
    }) catch return .unavailable;
    errdefer root.close(io);
    root.setPermissions(io, .fromMode(0o700)) catch {
        root.close(io);
        return .unavailable;
    };

    const lock_file = openOrCreateLock(io, root) catch {
        root.close(io);
        return .unavailable;
    };
    errdefer lock_file.close(io);
    var owner: Owner = .{ .io = io, .root = root, .lock_file = lock_file, .ops = ops };

    if (ops.lock_fn(io, ops.context, lock_file, .exclusive) catch false) {
        const history = openExistingRegular(io, root, history_name, .read_only) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                lock_file.unlock(io);
                return .{ .writable = owner };
            },
        };
        var loaded: LoadResult = .{ .ok = true, .physical_records = 0 };
        if (history) |file| {
            loaded = try loadOpened(allocator, io, file, entries);
            file.close(io);
        }
        if (loaded.ok and loaded.physical_records > compact_after_records) {
            _ = try compactLocked(allocator, &owner, entries, nonce_source, ops);
        }
        lock_file.unlock(io);
        return .{ .writable = owner };
    }

    if (acquireLock(io, lock_file, .shared, ops)) {
        const history = openExistingRegular(io, root, history_name, .read_only) catch |err| switch (err) {
            error.FileNotFound => null,
            else => {
                lock_file.unlock(io);
                return .{ .writable = owner };
            },
        };
        if (history) |file| {
            _ = try loadOpened(allocator, io, file, entries);
            file.close(io);
        }
        lock_file.unlock(io);
    }
    return .{ .writable = owner };
}

const LoadResult = struct {
    ok: bool,
    physical_records: usize,
};

fn loadOpened(
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    entries: Entries,
) error{OutOfMemory}!LoadResult {
    var record: std.ArrayList(u8) = .empty;
    defer record.deinit(allocator);
    record.ensureTotalCapacity(allocator, maximum_record_bytes) catch return error.OutOfMemory;

    var input: [4096]u8 = undefined;
    var physical_records: usize = 0;
    var overflow = false;
    var has_physical_bytes = false;
    while (true) {
        const read_count = file.readStreaming(io, &.{&input}) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return .{ .ok = false, .physical_records = physical_records },
        };
        for (input[0..read_count]) |byte| {
            has_physical_bytes = true;
            if (byte == '\n') {
                physical_records +|= 1;
                if (!overflow) try decodeAndSeed(&record, entries);
                record.clearRetainingCapacity();
                overflow = false;
                has_physical_bytes = false;
            } else if (!overflow) {
                if (record.items.len < maximum_record_bytes - 1) {
                    record.appendAssumeCapacity(byte);
                } else {
                    overflow = true;
                    record.clearRetainingCapacity();
                }
            }
        }
    }
    if (has_physical_bytes) {
        physical_records +|= 1;
        if (!overflow) try decodeAndSeed(&record, entries);
    }
    return .{ .ok = true, .physical_records = physical_records };
}

fn decodeAndSeed(record: *std.ArrayList(u8), entries: Entries) error{OutOfMemory}!void {
    while (record.items.len != 0 and record.items[record.items.len - 1] == '\r') {
        _ = record.pop();
    }
    if (record.items.len == 0) return;
    const decoded_length = decodeInPlace(record.items);
    try entries.seed(record.items[0..decoded_length]);
}

fn decodeInPlace(bytes: []u8) usize {
    var read_index: usize = 0;
    var write_index: usize = 0;
    while (read_index < bytes.len) {
        if (bytes[read_index] == '\\' and read_index + 1 < bytes.len) {
            const next = bytes[read_index + 1];
            if (next == '\\' or next == 'n') {
                bytes[write_index] = if (next == 'n') '\n' else '\\';
                write_index += 1;
                read_index += 2;
                continue;
            }
        }
        bytes[write_index] = bytes[read_index];
        write_index += 1;
        read_index += 1;
    }
    return write_index;
}

const EncodedRecord = union(enum) {
    too_large,
    bytes: []u8,
};

fn encodeRecord(allocator: std.mem.Allocator, entry_value: []const u8) error{OutOfMemory}!EncodedRecord {
    var encoded_length: usize = 1;
    for (entry_value) |byte| {
        encoded_length = std.math.add(
            usize,
            encoded_length,
            if (byte == '\\' or byte == '\n') 2 else 1,
        ) catch return .too_large;
        if (encoded_length > maximum_record_bytes) return .too_large;
    }
    const result = allocator.alloc(u8, encoded_length) catch return error.OutOfMemory;
    var cursor: usize = 0;
    for (entry_value) |byte| {
        if (byte == '\\') {
            result[cursor..][0..2].* = "\\\\".*;
            cursor += 2;
        } else if (byte == '\n') {
            result[cursor..][0..2].* = "\\n".*;
            cursor += 2;
        } else {
            result[cursor] = byte;
            cursor += 1;
        }
    }
    result[cursor] = '\n';
    return .{ .bytes = result };
}

fn compactLocked(
    allocator: std.mem.Allocator,
    owner: *Owner,
    entries: Entries,
    nonce_source: PrivateFileStore.NonceSource,
    ops: Ops,
) error{OutOfMemory}!bool {
    var nonce: [16]u8 = undefined;
    var name_buffer: [temp_prefix.len + 32]u8 = undefined;
    var attempt: usize = 0;
    while (attempt < PrivateFileStore.max_temp_attempts) : (attempt += 1) {
        nonce_source.fill(&nonce) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return false,
        };
        const temp_name = std.fmt.bufPrint(&name_buffer, temp_prefix ++ "{x}", .{nonce}) catch unreachable;
        const temp = owner.root.createFile(owner.io, temp_name, .{
            .read = true,
            .truncate = false,
            .exclusive = true,
            .permissions = .fromMode(0o600),
            .resolve_beneath = true,
        }) catch |err| switch (err) {
            error.PathAlreadyExists => continue,
            else => return false,
        };
        var open_temp = true;
        var renamed = false;
        defer {
            if (open_temp) temp.close(owner.io);
            if (!renamed) ops.cleanup_fn(owner.io, ops.context, owner.root, temp_name) catch {};
        }
        const stat = temp.stat(owner.io) catch return false;
        if (stat.kind != .file or stat.nlink != 1) return false;
        temp.setPermissions(owner.io, .fromMode(0o600)) catch return false;

        var index: usize = 0;
        while (index < entries.count()) : (index += 1) {
            const value = entries.entry(index) orelse return false;
            const encoded = try encodeRecord(allocator, value);
            const bytes = switch (encoded) {
                .too_large => return false,
                .bytes => |record| record,
            };
            defer allocator.free(bytes);
            ops.temp_write_fn(owner.io, ops.context, temp, bytes) catch return false;
        }
        ops.sync_fn(owner.io, ops.context, temp) catch return false;
        temp.close(owner.io);
        open_temp = false;
        ops.rename_fn(owner.io, ops.context, owner.root, temp_name, history_name) catch return false;
        renamed = true;
        ops.dir_sync_fn(owner.io, ops.context, owner.root) catch return false;
        return true;
    }
    return false;
}

const OpsError = error{Failure};

const Ops = struct {
    context: ?*anyopaque = null,
    lock_fn: *const fn (std.Io, ?*anyopaque, std.Io.File, std.Io.File.Lock) OpsError!bool = standardLock,
    append_write_fn: *const fn (std.Io, ?*anyopaque, std.Io.File, []const u8) OpsError!usize = standardAppendWrite,
    temp_write_fn: *const fn (std.Io, ?*anyopaque, std.Io.File, []const u8) OpsError!void = standardTempWrite,
    sync_fn: *const fn (std.Io, ?*anyopaque, std.Io.File) OpsError!void = standardSync,
    rename_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8, []const u8) OpsError!void = standardRename,
    dir_sync_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir) OpsError!void = standardDirSync,
    cleanup_fn: *const fn (std.Io, ?*anyopaque, std.Io.Dir, []const u8) OpsError!void = standardCleanup,

    const standard: Ops = .{};

    fn standardLock(io: std.Io, _: ?*anyopaque, file: std.Io.File, kind: std.Io.File.Lock) OpsError!bool {
        return file.tryLock(io, kind) catch return error.Failure;
    }

    fn standardAppendWrite(io: std.Io, _: ?*anyopaque, file: std.Io.File, bytes: []const u8) OpsError!usize {
        return file.writeStreaming(io, &.{}, &.{bytes}, 1) catch return error.Failure;
    }

    fn standardTempWrite(io: std.Io, _: ?*anyopaque, file: std.Io.File, bytes: []const u8) OpsError!void {
        file.writeStreamingAll(io, bytes) catch return error.Failure;
    }

    fn standardSync(io: std.Io, _: ?*anyopaque, file: std.Io.File) OpsError!void {
        file.sync(io) catch return error.Failure;
    }

    fn standardRename(
        io: std.Io,
        _: ?*anyopaque,
        root: std.Io.Dir,
        old_name: []const u8,
        new_name: []const u8,
    ) OpsError!void {
        root.rename(old_name, root, new_name, io) catch return error.Failure;
    }

    fn standardDirSync(io: std.Io, _: ?*anyopaque, root: std.Io.Dir) OpsError!void {
        const file: std.Io.File = .{ .handle = root.handle, .flags = .{ .nonblocking = false } };
        file.sync(io) catch return error.Failure;
    }

    fn standardCleanup(io: std.Io, _: ?*anyopaque, root: std.Io.Dir, name: []const u8) OpsError!void {
        root.deleteFile(io, name) catch |err| switch (err) {
            error.FileNotFound => {},
            else => return error.Failure,
        };
    }
};

fn acquireLock(io: std.Io, file: std.Io.File, kind: std.Io.File.Lock, ops: Ops) bool {
    var attempt: usize = 0;
    while (attempt < maximum_lock_attempts) : (attempt += 1) {
        if (ops.lock_fn(io, ops.context, file, kind) catch return false) return true;
        if (attempt + 1 < maximum_lock_attempts) {
            io.sleep(
                .fromMilliseconds(maximum_lock_wait_ms / maximum_lock_attempts),
                .awake,
            ) catch return false;
        }
    }
    return false;
}

const LeafError = error{ FileNotFound, Failure };

fn openExistingRegular(
    io: std.Io,
    root: std.Io.Dir,
    name: []const u8,
    mode: std.Io.File.OpenMode,
) LeafError!std.Io.File {
    const named = root.statFile(io, name, .{ .follow_symlinks = false }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Failure,
    };
    if (named.kind != .file or named.nlink != 1) return error.Failure;
    const file = root.openFile(io, name, .{
        .mode = mode,
        .allow_directory = false,
        .follow_symlinks = false,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.FileNotFound => return error.FileNotFound,
        else => return error.Failure,
    };
    errdefer file.close(io);
    const opened = file.stat(io) catch return error.Failure;
    if (opened.kind != .file or opened.nlink != 1 or opened.inode != named.inode) {
        return error.Failure;
    }
    return file;
}

fn openOrCreateLock(io: std.Io, root: std.Io.Dir) OpsError!std.Io.File {
    const permissions: std.Io.File.Permissions = .fromMode(0o600);
    const file = root.createFile(io, lock_name, .{
        .read = true,
        .truncate = false,
        .exclusive = true,
        .permissions = permissions,
        .resolve_beneath = true,
    }) catch |err| switch (err) {
        error.PathAlreadyExists => openExistingRegular(io, root, lock_name, .read_write) catch return error.Failure,
        else => return error.Failure,
    };
    errdefer file.close(io);
    const stat = file.stat(io) catch return error.Failure;
    if (stat.kind != .file or stat.nlink != 1) return error.Failure;
    file.setPermissions(io, permissions) catch return error.Failure;
    return file;
}

fn validStateRoot(path: []const u8) bool {
    if (path.len == 0 or path.len > maximum_state_root_bytes or path.len >= std.fs.max_path_bytes or
        path[0] != '/' or std.mem.findScalar(u8, path, 0) != null or
        !std.unicode.utf8ValidateSlice(path)) return false;
    var parts = std.mem.splitScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

const PosixAppend = struct {
    fn open(root: std.Io.Dir) std.posix.OpenError!std.Io.File {
        var flags: std.posix.O = .{};
        flags.ACCMODE = .WRONLY;
        flags.APPEND = true;
        flags.CREAT = true;
        flags.CLOEXEC = true;
        flags.NOFOLLOW = true;
        flags.NONBLOCK = true;
        const descriptor = try std.posix.openat(root.handle, history_name, flags, 0o600);
        return .{ .handle = descriptor, .flags = .{ .nonblocking = true } };
    }
};

const TestEntries = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList([]u8) = .empty,
    maximum: usize = 1000,

    fn deinit(self: *TestEntries) void {
        for (self.values.items) |value| self.allocator.free(value);
        self.values.deinit(self.allocator);
        self.* = undefined;
    }

    fn seed(self: *TestEntries, value: []const u8) error{OutOfMemory}!void {
        var duplicate: ?usize = null;
        for (self.values.items, 0..) |existing, index| {
            if (std.mem.eql(u8, existing, value)) duplicate = index;
        }
        const owned = self.allocator.dupe(u8, value) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        self.values.ensureUnusedCapacity(self.allocator, 1) catch return error.OutOfMemory;
        if (duplicate) |index| self.allocator.free(self.values.orderedRemove(index));
        if (self.values.items.len == self.maximum) self.allocator.free(self.values.orderedRemove(0));
        self.values.appendAssumeCapacity(owned);
    }

    fn count(self: *TestEntries) usize {
        return self.values.items.len;
    }

    fn entry(self: *TestEntries, index: usize) ?[]const u8 {
        if (index >= self.values.items.len) return null;
        return self.values.items[index];
    }
};

const TestNonce = struct {
    value: u8 = 0,

    fn fill(context: *anyopaque, bytes: []u8) PrivateFileStore.Error!void {
        const self: *TestNonce = @ptrCast(@alignCast(context));
        @memset(bytes, self.value);
        self.value +%= 1;
    }

    fn source(self: *TestNonce) PrivateFileStore.NonceSource {
        return .{ .context = self, .fill_fn = fill };
    }
};

fn absoluteTempPath(allocator: std.mem.Allocator, temporary: *const std.testing.TmpDir, leaf: []const u8) ![]u8 {
    var cwd_buffer: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_length = try std.process.currentPath(std.testing.io, &cwd_buffer);
    return std.fs.path.join(allocator, &.{
        cwd_buffer[0..cwd_length],
        ".zig-cache",
        "tmp",
        &temporary.sub_path,
        leaf,
    });
}

test "codec round trips escapes and preserves unknown and trailing escapes" {
    const allocator = std.testing.allocator;
    const encoded = try encodeRecord(allocator, "a\\b\nc");
    const bytes = encoded.bytes;
    defer allocator.free(bytes);
    try std.testing.expectEqualStrings("a\\\\b\\nc\n", bytes);

    var unknown = "a\\qb\\".*;
    const length = decodeInPlace(&unknown);
    try std.testing.expectEqualStrings("a\\qb\\", unknown[0..length]);

    var known = "a\\\\b\\nc".*;
    const known_length = decodeInPlace(&known);
    try std.testing.expectEqualStrings("a\\b\nc", known[0..known_length]);
}

test "read only missing root and history create nothing" {
    const allocator = std.testing.allocator;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try absoluteTempPath(allocator, &temporary, "missing");
    defer allocator.free(root_path);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    var nonce: TestNonce = .{};

    const result = try open(allocator, std.testing.io, root_path, .read_only, Entries.from(&values), nonce.source());
    try std.testing.expect(result == .read_only);
    try std.testing.expectError(error.FileNotFound, temporary.dir.openDir(std.testing.io, "missing", .{}));
}

test "read only history without lock loads without creating lock" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "state", .fromMode(0o700));
    var state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    try state.writeFile(io, .{ .sub_path = history_name, .data = "one\r\ntwo\\nline\n" });
    const root_path = try absoluteTempPath(allocator, &temporary, "state");
    defer allocator.free(root_path);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    var nonce: TestNonce = .{};

    const result = try open(allocator, io, root_path, .read_only, Entries.from(&values), nonce.source());
    try std.testing.expect(result == .read_only);
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectEqualStrings("one", values.entry(0).?);
    try std.testing.expectEqualStrings("two\nline", values.entry(1).?);
    try std.testing.expectError(error.FileNotFound, state.openFile(io, lock_name, .{}));
}

test "streaming load drops oversized records and accepts unterminated tail" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const file = try temporary.dir.createFile(io, history_name, .{});
    const oversized = try allocator.alloc(u8, maximum_record_bytes);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    try file.writeStreamingAll(io, "first\n\n");
    try file.writeStreamingAll(io, oversized);
    try file.writeStreamingAll(io, "\na\\qb\\");
    file.close(io);
    const input = try temporary.dir.openFile(io, history_name, .{});
    defer input.close(io);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    const loaded = try loadOpened(allocator, io, input, Entries.from(&values));

    try std.testing.expect(loaded.ok);
    try std.testing.expectEqual(@as(usize, 4), loaded.physical_records);
    try std.testing.expectEqual(@as(usize, 2), values.count());
    try std.testing.expectEqualStrings("first", values.entry(0).?);
    try std.testing.expectEqualStrings("a\\qb\\", values.entry(1).?);
}

test "writable setup is private and append reopens the named file" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try absoluteTempPath(allocator, &temporary, "state");
    defer allocator.free(root_path);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    var nonce: TestNonce = .{};

    const result = try open(allocator, io, root_path, .writable, Entries.from(&values), nonce.source());
    try std.testing.expect(result == .writable);
    var owner = result.writable;
    defer owner.deinit();
    try std.testing.expectEqual(AppendOutcome.written, try owner.append(allocator, "one\ntwo"));
    try std.testing.expectEqual(AppendOutcome.written, try owner.append(allocator, "three"));

    const root_stat = try std.Io.Dir.statFile(.cwd(), io, root_path, .{ .follow_symlinks = false });
    const lock_stat = try owner.root.statFile(io, lock_name, .{ .follow_symlinks = false });
    const history_stat = try owner.root.statFile(io, history_name, .{ .follow_symlinks = false });
    if (std.Io.File.Permissions.has_executable_bit) {
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o700), root_stat.permissions.toMode() & 0o777);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), lock_stat.permissions.toMode() & 0o777);
        try std.testing.expectEqual(@as(std.posix.mode_t, 0o600), history_stat.permissions.toMode() & 0o777);
    }
    const data = try owner.root.readFileAlloc(io, history_name, allocator, .limited(1024));
    defer allocator.free(data);
    try std.testing.expectEqualStrings("one\\ntwo\nthree\n", data);
}

test "append bounds short writes and unsafe history leaves degrade" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    const root_path = try absoluteTempPath(allocator, &temporary, "state");
    defer allocator.free(root_path);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    var nonce: TestNonce = .{};
    const result = try open(allocator, io, root_path, .writable, Entries.from(&values), nonce.source());
    var owner = result.writable;
    defer owner.deinit();

    const large = try allocator.alloc(u8, maximum_record_bytes);
    defer allocator.free(large);
    @memset(large, 'x');
    try std.testing.expectEqual(AppendOutcome.too_large, try owner.append(allocator, large));

    const Short = struct {
        fn write(_: std.Io, _: ?*anyopaque, _: std.Io.File, bytes: []const u8) OpsError!usize {
            return bytes.len - 1;
        }
    };
    try std.testing.expectEqual(
        AppendOutcome.unavailable,
        try owner.appendWithOps(allocator, "short", .{ .append_write_fn = Short.write }),
    );

    try owner.root.deleteFile(io, history_name);
    try owner.root.symLink(io, "target", history_name, .{});
    try std.testing.expectEqual(AppendOutcome.unavailable, try owner.append(allocator, "blocked"));
}

test "exclusive startup compacts retained entries in oldest first order" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    try temporary.dir.createDir(io, "state", .fromMode(0o700));
    var state = try temporary.dir.openDir(io, "state", .{});
    defer state.close(io);
    const history = try state.createFile(io, history_name, .{ .permissions = .fromMode(0o600) });
    var index: usize = 0;
    while (index <= compact_after_records) : (index += 1) {
        try history.writeStreamingAll(io, if (index % 2 == 0) "old\n" else "new\n");
    }
    history.close(io);
    const root_path = try absoluteTempPath(allocator, &temporary, "state");
    defer allocator.free(root_path);
    var values: TestEntries = .{ .allocator = allocator };
    defer values.deinit();
    var nonce: TestNonce = .{};

    const result = try open(allocator, io, root_path, .writable, Entries.from(&values), nonce.source());
    var owner = result.writable;
    defer owner.deinit();
    try std.testing.expectEqual(@as(usize, 2), values.count());
    const data = try owner.root.readFileAlloc(io, history_name, allocator, .limited(1024));
    defer allocator.free(data);
    try std.testing.expectEqualStrings("new\nold\n", data);
}

test "allocation failure during streaming load escapes without leaks" {
    const Exercise = struct {
        fn run(allocator: std.mem.Allocator) !void {
            const io = std.testing.io;
            var temporary = std.testing.tmpDir(.{});
            defer temporary.cleanup();
            const file = try temporary.dir.createFile(io, history_name, .{});
            try file.writeStreamingAll(io, "one\ntwo\n");
            file.close(io);
            const input = try temporary.dir.openFile(io, history_name, .{});
            defer input.close(io);
            var values: TestEntries = .{ .allocator = allocator };
            defer values.deinit();
            _ = try loadOpened(allocator, io, input, Entries.from(&values));
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{});
}
