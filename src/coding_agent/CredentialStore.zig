const std = @import("std");
const builtin = @import("builtin");
const BoundedJson = @import("../BoundedJson.zig");
const credential = @import("../ai/credential.zig");
const ZiPaths = @import("ZiPaths.zig");

const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);
const auth_file_name = "auth.json";
const lock_file_name = ".auth.lock";
const max_document_bytes = 2 * 1024 * 1024;
const max_provider_id_bytes = 256;
const lock_timeout_ms = 2000;
const lock_poll_ms = 10;

pub const Boundary = enum {
    after_write,
    after_file_sync,
    after_replace,
};

pub const Faults = struct {
    context: ?*anyopaque = null,
    boundary_fn: ?*const fn (*anyopaque, Boundary) anyerror!void = null,

    pub fn none() Faults {
        return .{};
    }

    fn boundary(self: Faults, point: Boundary) !void {
        const function = self.boundary_fn orelse return;
        return function(self.context.?, point);
    }
};

pub const Error = error{
    OutOfMemory,
    InvalidCredentialFile,
    UnsupportedVersion,
    UnsafePath,
    ReadFailed,
    LockFailed,
    WriteFailed,
    CommitIndeterminate,
};

const Source = struct {
    version: u32,
    credentials: []const SourceEntry,
};

const SourceEntry = struct {
    provider_id: []const u8,
    type: enum { api_key, oauth },
    key: ?[]const u8 = null,
    access: ?[]const u8 = null,
    refresh: ?[]const u8 = null,
    expires_at_ms: ?u64 = null,
    account_id: ?[]const u8 = null,
};

pub const Snapshot = struct {
    arena: std.heap.ArenaAllocator,
    entries: []const credential.Entry,

    pub fn deinit(self: *Snapshot) void {
        wipeCredentials(self.entries);
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Mutation = struct {
    io: std.Io,
    directory: std.Io.Dir,
    lock: std.Io.File,
    faults: Faults,

    pub fn deinit(self: *Mutation) void {
        self.lock.close(self.io);
        self.directory.close(self.io);
        self.* = undefined;
    }

    pub fn load(self: *Mutation, allocator: std.mem.Allocator) Error!Snapshot {
        return loadFile(allocator, self.io, self.directory, auth_file_name);
    }

    pub fn put(
        self: *Mutation,
        allocator: std.mem.Allocator,
        entry: credential.Entry,
    ) Error!void {
        try validateEntry(entry);
        var current = try self.load(allocator);
        defer current.deinit();
        const replacing = find(current.entries, entry.provider_id);
        const count = current.entries.len + @intFromBool(replacing == null);
        if (count > credential.max_credentials) return error.InvalidCredentialFile;
        const updated = try allocator.alloc(credential.Entry, count);
        defer allocator.free(updated);
        var cursor: usize = 0;
        for (current.entries, 0..) |stored, index| {
            updated[cursor] = if (replacing == index) entry else stored;
            cursor += 1;
        }
        if (replacing == null) updated[cursor] = entry;

        try self.writeEntries(allocator, updated);
    }

    pub fn remove(
        self: *Mutation,
        allocator: std.mem.Allocator,
        provider_id: []const u8,
    ) Error!bool {
        var current = try self.load(allocator);
        defer current.deinit();
        const removing = find(current.entries, provider_id) orelse return false;
        const updated = try allocator.alloc(credential.Entry, current.entries.len - 1);
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

    fn writeEntries(self: *Mutation, allocator: std.mem.Allocator, entries: []const credential.Entry) Error!void {
        const encoded = try encode(allocator, entries);
        defer {
            std.crypto.secureZero(u8, encoded);
            allocator.free(encoded);
        }
        var atomic = self.directory.createFileAtomic(self.io, auth_file_name, .{
            .permissions = private_file_permissions,
            .replace = true,
        }) catch return error.WriteFailed;
        defer atomic.deinit(self.io);
        atomic.file.writePositionalAll(self.io, encoded, 0) catch return error.WriteFailed;
        self.faults.boundary(.after_write) catch return error.WriteFailed;
        atomic.file.sync(self.io) catch return error.WriteFailed;
        self.faults.boundary(.after_file_sync) catch return error.WriteFailed;
        atomic.replace(self.io) catch return error.WriteFailed;
        self.faults.boundary(.after_replace) catch return error.CommitIndeterminate;
        syncDirectory(self.directory) catch return error.CommitIndeterminate;
    }
};

pub fn load(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
) Error!Snapshot {
    const directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{}) catch |failure| {
        return switch (failure) {
            error.FileNotFound => empty(allocator),
            else => error.ReadFailed,
        };
    };
    defer directory.close(io);
    return loadFile(allocator, io, directory, auth_file_name);
}

pub fn beginMutation(io: std.Io, paths: *const ZiPaths) Error!Mutation {
    return beginMutationWithFaults(io, paths, .none());
}

fn beginMutationWithFaults(io: std.Io, paths: *const ZiPaths, faults: Faults) Error!Mutation {
    var directory = try openPrivateAgentDirectory(io, paths);
    errdefer directory.close(io);
    const lock = directory.createFile(io, lock_file_name, .{
        .read = true,
        .truncate = false,
        .permissions = private_file_permissions,
    }) catch return error.LockFailed;
    errdefer lock.close(io);
    try validatePrivateFile(lock.stat(io) catch return error.LockFailed);
    const deadline = std.Io.Clock.Timestamp.fromNow(io, .{
        .raw = .fromMilliseconds(lock_timeout_ms),
        .clock = .awake,
    });
    while (!(lock.tryLock(io, .exclusive) catch return error.LockFailed)) {
        if (std.Io.Clock.Timestamp.now(io, .awake).compare(.gte, deadline)) return error.LockFailed;
        const poll: std.Io.Timeout = .{ .duration = .{
            .raw = .fromMilliseconds(lock_poll_ms),
            .clock = .awake,
        } };
        poll.sleep(io) catch return error.LockFailed;
    }
    return .{ .io = io, .directory = directory, .lock = lock, .faults = faults };
}

pub fn put(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    entry: credential.Entry,
) Error!void {
    var mutation = try beginMutation(io, paths);
    defer mutation.deinit();
    return mutation.put(allocator, entry);
}

pub fn remove(
    allocator: std.mem.Allocator,
    io: std.Io,
    paths: *const ZiPaths,
    provider_id: []const u8,
) Error!bool {
    var mutation = try beginMutation(io, paths);
    defer mutation.deinit();
    return mutation.remove(allocator, provider_id);
}

fn loadFile(
    allocator: std.mem.Allocator,
    io: std.Io,
    directory: std.Io.Dir,
    path: []const u8,
) Error!Snapshot {
    const file = directory.openFile(io, path, .{
        .mode = .read_only,
        .allow_directory = false,
        .follow_symlinks = false,
    }) catch |failure| return switch (failure) {
        error.FileNotFound => empty(allocator),
        else => error.ReadFailed,
    };
    defer file.close(io);
    const stat = file.stat(io) catch return error.ReadFailed;
    try validatePrivateFile(stat);
    if (stat.size > max_document_bytes) return error.InvalidCredentialFile;
    var read_buffer: [8192]u8 = undefined;
    var file_reader = file.reader(io, &read_buffer);
    const source_text = file_reader.interface.allocRemaining(
        allocator,
        .limited(max_document_bytes + 1),
    ) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ReadFailed,
    };
    defer {
        std.crypto.secureZero(u8, source_text);
        allocator.free(source_text);
    }
    if (source_text.len > max_document_bytes) return error.InvalidCredentialFile;
    return decode(allocator, source_text);
}

pub fn empty(allocator: std.mem.Allocator) Error!Snapshot {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    return .{ .arena = arena, .entries = try arena.allocator().alloc(credential.Entry, 0) };
}

fn decode(allocator: std.mem.Allocator, source_text: []const u8) Error!Snapshot {
    BoundedJson.validate(allocator, source_text, .{
        .document_bytes = max_document_bytes,
        .value_bytes = credential.max_secret_bytes,
        .depth = 4,
        .collection_items = credential.max_credentials * 8,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCredentialFile,
    };
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const source = std.json.parseFromSliceLeaky(Source, arena.allocator(), source_text, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .max_value_len = credential.max_secret_bytes,
    }) catch |failure| return switch (failure) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidCredentialFile,
    };
    if (source.version != 1) return error.UnsupportedVersion;
    if (source.credentials.len > credential.max_credentials) return error.InvalidCredentialFile;
    const entries = try arena.allocator().alloc(credential.Entry, source.credentials.len);
    for (source.credentials, entries, 0..) |item, *entry, index| {
        entry.* = .{
            .provider_id = item.provider_id,
            .credential = switch (item.type) {
                .api_key => .{ .api_key = .{ .key = item.key orelse return error.InvalidCredentialFile } },
                .oauth => .{ .oauth = .{
                    .access = item.access orelse return error.InvalidCredentialFile,
                    .refresh = item.refresh orelse return error.InvalidCredentialFile,
                    .expires_at_ms = item.expires_at_ms orelse return error.InvalidCredentialFile,
                    .account_id = item.account_id,
                } },
            },
        };
        if (item.type == .api_key and
            (item.access != null or item.refresh != null or item.expires_at_ms != null or item.account_id != null))
        {
            return error.InvalidCredentialFile;
        }
        if (item.type == .oauth and item.key != null) return error.InvalidCredentialFile;
        try validateEntry(entry.*);
        for (entries[0..index]) |previous| {
            if (std.mem.eql(u8, previous.provider_id, entry.provider_id)) return error.InvalidCredentialFile;
        }
    }
    return .{ .arena = arena, .entries = entries };
}

fn encode(allocator: std.mem.Allocator, entries: []const credential.Entry) Error![]u8 {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer };
    json.beginObject() catch return error.OutOfMemory;
    try writeField(&json, "version", @as(u32, 1));
    json.objectField("credentials") catch return error.OutOfMemory;
    json.beginArray() catch return error.OutOfMemory;
    for (entries) |entry| {
        try validateEntry(entry);
        json.beginObject() catch return error.OutOfMemory;
        try writeField(&json, "provider_id", entry.provider_id);
        switch (entry.credential) {
            .api_key => |api_key| {
                try writeField(&json, "type", "api_key");
                try writeField(&json, "key", api_key.key);
            },
            .oauth => |oauth| {
                try writeField(&json, "type", "oauth");
                try writeField(&json, "access", oauth.access);
                try writeField(&json, "refresh", oauth.refresh);
                try writeField(&json, "expires_at_ms", oauth.expires_at_ms);
                if (oauth.account_id) |account_id| try writeField(&json, "account_id", account_id);
            },
        }
        json.endObject() catch return error.OutOfMemory;
    }
    json.endArray() catch return error.OutOfMemory;
    json.endObject() catch return error.OutOfMemory;
    const encoded = output.toOwnedSlice() catch return error.OutOfMemory;
    if (encoded.len > max_document_bytes) {
        std.crypto.secureZero(u8, encoded);
        allocator.free(encoded);
        return error.InvalidCredentialFile;
    }
    return encoded;
}

fn writeField(json: *std.json.Stringify, name: []const u8, value: anytype) Error!void {
    json.objectField(name) catch return error.OutOfMemory;
    json.write(value) catch return error.OutOfMemory;
}

fn validateEntry(entry: credential.Entry) Error!void {
    if (entry.provider_id.len == 0 or entry.provider_id.len > max_provider_id_bytes or
        !std.unicode.utf8ValidateSlice(entry.provider_id) or
        std.mem.indexOfScalar(u8, entry.provider_id, 0) != null)
    {
        return error.InvalidCredentialFile;
    }
    switch (entry.credential) {
        .api_key => |api_key| try validateSecret(api_key.key),
        .oauth => |oauth| {
            try validateSecret(oauth.access);
            try validateSecret(oauth.refresh);
            if (oauth.account_id) |account_id| try validateSecret(account_id);
        },
    }
}

fn validateSecret(value: []const u8) Error!void {
    if (value.len == 0 or value.len > credential.max_secret_bytes or
        !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null)
    {
        return error.InvalidCredentialFile;
    }
}

fn find(entries: []const credential.Entry, provider_id: []const u8) ?usize {
    for (entries, 0..) |entry, index| {
        if (std.mem.eql(u8, entry.provider_id, provider_id)) return index;
    }
    return null;
}

fn wipeCredentials(entries: []const credential.Entry) void {
    for (entries) |entry| switch (entry.credential) {
        .api_key => |api_key| std.crypto.secureZero(u8, @constCast(api_key.key)),
        .oauth => |oauth| {
            std.crypto.secureZero(u8, @constCast(oauth.access));
            std.crypto.secureZero(u8, @constCast(oauth.refresh));
            if (oauth.account_id) |account_id| std.crypto.secureZero(u8, @constCast(account_id));
        },
    };
}

fn openPrivateAgentDirectory(io: std.Io, paths: *const ZiPaths) Error!std.Io.Dir {
    _ = std.Io.Dir.createDirPathStatus(.cwd(), io, paths.global_agent, private_dir_permissions) catch
        return error.UnsafePath;
    const directory = std.Io.Dir.openDirAbsolute(io, paths.global_agent, .{}) catch return error.UnsafePath;
    errdefer directory.close(io);
    const stat = directory.stat(io) catch return error.UnsafePath;
    if (stat.kind != .directory) return error.UnsafePath;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) return error.UnsafePath;
    }
    return directory;
}

fn validatePrivateFile(stat: std.Io.File.Stat) Error!void {
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafePath;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) return error.UnsafePath;
    }
}

fn syncDirectory(directory: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return error.OperationUnsupported;
    while (true) {
        const result = std.c.fsync(directory.handle);
        if (result == 0) return;
        if (std.c.errno(result) == .INTR) continue;
        return error.DirectorySyncFailed;
    }
}

fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
    const length = try temporary.dir.realPath(std.testing.io, buffer);
    return buffer[0..length];
}

test "credential store atomically inserts and replaces provider credentials" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();

    var empty_snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer empty_snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty_snapshot.entries.len);

    try put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "provider-a",
        .credential = .{ .api_key = .{ .key = "first-secret" } },
    });
    try put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "provider-b",
        .credential = .{ .oauth = .{
            .access = "access-token",
            .refresh = "refresh-token",
            .expires_at_ms = 42,
            .account_id = "account-id",
        } },
    });
    try put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "provider-a",
        .credential = .{ .api_key = .{ .key = "replacement-secret" } },
    });

    var snapshot = try load(std.testing.allocator, std.testing.io, &paths);
    defer snapshot.deinit();
    try std.testing.expectEqual(@as(usize, 2), snapshot.entries.len);
    try std.testing.expectEqualStrings("replacement-secret", snapshot.entries[0].credential.api_key.key);
    try std.testing.expectEqualStrings("access-token", snapshot.entries[1].credential.oauth.access);
    try std.testing.expectEqualStrings("refresh-token", snapshot.entries[1].credential.oauth.refresh);

    var agent_directory = try std.Io.Dir.openDirAbsolute(std.testing.io, paths.global_agent, .{});
    defer agent_directory.close(std.testing.io);
    const file = try agent_directory.openFile(std.testing.io, auth_file_name, .{
        .mode = .read_only,
        .allow_directory = false,
    });
    defer file.close(std.testing.io);
    const stat = try file.stat(std.testing.io);
    if (comptime builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(u16, 0), stat.permissions.toMode() & 0o077);
    }
    const encoded = try agent_directory.readFileAlloc(
        std.testing.io,
        auth_file_name,
        std.testing.allocator,
        .limited(max_document_bytes),
    );
    defer std.testing.allocator.free(encoded);
    try std.testing.expect(std.mem.indexOf(u8, encoded, "first-secret") == null);

    try std.testing.expect(try remove(
        std.testing.allocator,
        std.testing.io,
        &paths,
        "provider-a",
    ));
    try std.testing.expect(!try remove(
        std.testing.allocator,
        std.testing.io,
        &paths,
        "provider-a",
    ));
    var after_remove = try load(std.testing.allocator, std.testing.io, &paths);
    defer after_remove.deinit();
    try std.testing.expectEqual(@as(usize, 1), after_remove.entries.len);
    try std.testing.expectEqualStrings("provider-b", after_remove.entries[0].provider_id);
}

test "credential store distinguishes failed and indeterminate replacement boundaries" {
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
    var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const root = try temporaryPath(&temporary, &root_buffer);
    var paths = try ZiPaths.init(std.testing.allocator, root, root);
    defer paths.deinit();
    try put(std.testing.allocator, std.testing.io, &paths, .{
        .provider_id = "provider",
        .credential = .{ .api_key = .{ .key = "original" } },
    });

    var before_replace: Fault = .{ .fail_at = .after_write };
    var failed = try beginMutationWithFaults(std.testing.io, &paths, before_replace.faults());
    try std.testing.expectError(error.WriteFailed, failed.put(std.testing.allocator, .{
        .provider_id = "provider",
        .credential = .{ .api_key = .{ .key = "not-committed" } },
    }));
    failed.deinit();
    var original = try load(std.testing.allocator, std.testing.io, &paths);
    try std.testing.expectEqualStrings("original", original.entries[0].credential.api_key.key);
    original.deinit();

    var after_replace: Fault = .{ .fail_at = .after_replace };
    var indeterminate = try beginMutationWithFaults(std.testing.io, &paths, after_replace.faults());
    try std.testing.expectError(error.CommitIndeterminate, indeterminate.put(std.testing.allocator, .{
        .provider_id = "provider",
        .credential = .{ .api_key = .{ .key = "published" } },
    }));
    indeterminate.deinit();
    var published = try load(std.testing.allocator, std.testing.io, &paths);
    defer published.deinit();
    try std.testing.expectEqualStrings("published", published.entries[0].credential.api_key.key);
}

test "credential store rejects unknown fields and unsupported versions" {
    try std.testing.expectError(error.InvalidCredentialFile, decode(
        std.testing.allocator,
        "{\"version\":1,\"credentials\":[],\"unknown\":true}",
    ));
    try std.testing.expectError(error.UnsupportedVersion, decode(
        std.testing.allocator,
        "{\"version\":2,\"credentials\":[]}",
    ));
    const mixed_fields =
        \\{"version":1,"credentials":[
        \\  {"provider_id":"p","type":"api_key","key":"k","access":"mixed"}
        \\]}
    ;
    try std.testing.expectError(
        error.InvalidCredentialFile,
        decode(std.testing.allocator, mixed_fields),
    );
}

test "credential snapshot wipes parsed secrets" {
    const backing = try std.testing.allocator.alloc(u8, 4096);
    defer std.testing.allocator.free(backing);
    @memset(backing, 0xa5);
    var fixed = std.heap.FixedBufferAllocator.init(backing);
    const encoded =
        \\{"version":1,"credentials":[
        \\  {"provider_id":"p","type":"oauth","access":"wipe-access",
        \\   "refresh":"wipe-refresh","expires_at_ms":1,"account_id":"wipe-account"}
        \\]}
    ;
    var snapshot = try decode(fixed.allocator(), encoded);
    const oauth = snapshot.entries[0].credential.oauth;
    const secrets = [_][]const u8{ oauth.access, oauth.refresh, oauth.account_id.? };
    var offsets: [secrets.len]usize = undefined;
    var lengths: [secrets.len]usize = undefined;
    for (secrets, 0..) |secret, index| {
        offsets[index] = @intFromPtr(secret.ptr) - @intFromPtr(backing.ptr);
        lengths[index] = secret.len;
    }
    snapshot.deinit();
    for (offsets, lengths) |offset, length| {
        for (backing[offset..][0..length]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    }
}
