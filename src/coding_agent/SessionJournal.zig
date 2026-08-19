const std = @import("std");
const builtin = @import("builtin");
const format = @import("SessionFormat.zig");

const SessionJournal = @This();
const read_buffer_bytes = 8192;
const private_file_permissions = std.Io.File.Permissions.fromMode(0o600);

pub const Error = error{
    OutOfMemory,
    InvalidHeader,
    InvalidRecord,
    UnsupportedVersion,
    SessionTooLarge,
    TooManyEntries,
    AlreadyExists,
    NotFound,
    UnsafeFile,
    OpenFailed,
    CreateFailed,
    CreateIndeterminate,
    ReadFailed,
    AppendFailed,
    RepairFailed,
    CommitIndeterminate,
    ReadOnly,
};

pub const State = union(enum) {
    read_only_clean,
    read_only_torn_tail: u64,
    writable_clean,
    writable_repair_pending: u64,
    write_indeterminate: Indeterminate,
};

pub const Indeterminate = struct {
    operation: enum { repair, append, external_change },
    entry_id: [128]u8 = undefined,
    entry_id_len: u8 = 0,
    start_offset: u64,
    encoded_sha256: [32]u8 = @splat(0),

    pub fn entryId(self: *const Indeterminate) []const u8 {
        return self.entry_id[0..self.entry_id_len];
    }
};

pub const Recovery = union(enum) {
    clean,
    torn_tail: struct { truncate_offset: u64 },
};

pub const Boundary = enum {
    after_create_header_write,
    after_create_write,
    after_create_file_sync,
    after_create_publish,
    after_create_directory_sync,
    before_repair_truncate,
    after_repair_truncate,
    after_repair_sync,
    after_append_record_write,
    after_append_write,
    after_append_sync,
    before_rollback_truncate,
    after_rollback_truncate,
    after_rollback_sync,
};

pub const Faults = struct {
    context: ?*anyopaque = null,
    boundaryFn: ?*const fn (context: *anyopaque, boundary: Boundary) anyerror!void = null,

    pub fn none() Faults {
        return .{};
    }

    fn boundary(self: Faults, point: Boundary) !void {
        const function = self.boundaryFn orelse return;
        try function(self.context.?, point);
    }
};

pub const Opened = struct {
    journal: SessionJournal,
    restore_candidate: format.Restored,

    pub fn deinit(self: *Opened) void {
        self.journal.deinit();
        self.restore_candidate.deinit();
        self.* = undefined;
    }
};

pub const HeaderProbe = struct {
    owned: format.OwnedHeader,

    pub fn header(self: *const HeaderProbe) format.Header {
        return self.owned.value;
    }

    pub fn deinit(self: *HeaderProbe) void {
        self.owned.deinit();
        self.* = undefined;
    }
};

allocator: std.mem.Allocator,
io: std.Io,
file: std.Io.File,
state: State,
committed_offset: u64,
entry_ids: std.StringHashMapUnmanaged(void) = .empty,
active_leaf_id: ?[]const u8 = null,

pub fn create(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    header: format.Header,
    faults: Faults,
) Error!Opened {
    const encoded = try format.encodeHeader(allocator, header);
    defer allocator.free(encoded);

    var atomic = dir.createFileAtomic(io, sub_path, .{
        .permissions = private_file_permissions,
        .replace = false,
    }) catch |failure| return mapCreateError(failure);
    defer atomic.deinit(io);

    atomic.file.writePositionalAll(io, encoded, 0) catch return error.CreateFailed;
    faults.boundary(.after_create_header_write) catch return error.CreateFailed;
    atomic.file.writePositionalAll(io, "\n", encoded.len) catch return error.CreateFailed;
    faults.boundary(.after_create_write) catch return error.CreateFailed;
    atomic.file.sync(io) catch return error.CreateFailed;
    faults.boundary(.after_create_file_sync) catch return error.CreateFailed;
    atomic.link(io) catch |failure| return mapLinkError(failure);
    faults.boundary(.after_create_publish) catch return error.CreateIndeterminate;
    syncDirectory(dir) catch return error.CreateIndeterminate;
    faults.boundary(.after_create_directory_sync) catch return error.CreateIndeterminate;

    return open(allocator, io, dir, sub_path, .writable);
}

pub fn openReadOnly(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) Error!Opened {
    return open(allocator, io, dir, sub_path, .read_only);
}

pub fn openWritable(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) Error!Opened {
    return open(allocator, io, dir, sub_path, .writable);
}

pub fn probeHeader(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
) Error!HeaderProbe {
    const file = dir.openFile(io, sub_path, .{
        .mode = .read_only,
        .allow_directory = false,
    }) catch |failure| return mapOpenError(failure);
    defer file.close(io);
    const stat = file.stat(io) catch return error.OpenFailed;
    try validateFileStat(stat);
    if (stat.size > format.max_journal_bytes) return error.SessionTooLarge;

    var scanner = Scanner.init(allocator, io, file, stat.size);
    defer scanner.deinit();
    const line = (try scanner.next()) orelse return error.InvalidHeader;
    defer allocator.free(line.bytes);
    if (!line.terminated) return error.InvalidHeader;
    return .{ .owned = try format.decodeOwnedHeader(allocator, line.bytes) };
}

pub fn deinit(self: *SessionJournal) void {
    var iterator = self.entry_ids.keyIterator();
    while (iterator.next()) |key| self.allocator.free(key.*);
    self.entry_ids.deinit(self.allocator);
    self.file.close(self.io);
    self.* = undefined;
}

pub fn recovery(self: *const SessionJournal) Recovery {
    return switch (self.state) {
        .read_only_torn_tail => |offset| .{ .torn_tail = .{ .truncate_offset = offset } },
        .writable_repair_pending => |offset| .{ .torn_tail = .{ .truncate_offset = offset } },
        else => .clean,
    };
}

pub fn activeLeafId(self: *const SessionJournal) ?[]const u8 {
    return self.active_leaf_id;
}

pub fn append(self: *SessionJournal, entry: format.Entry, faults: Faults) Error!void {
    switch (self.state) {
        .read_only_clean, .read_only_torn_tail => return error.ReadOnly,
        .write_indeterminate => return error.CommitIndeterminate,
        .writable_repair_pending => |offset| try self.repairTail(offset, faults),
        .writable_clean => {},
    }

    if (self.entry_ids.count() >= format.max_entries) return error.TooManyEntries;
    const file_length = self.file.length(self.io) catch {
        self.markExternalChange();
        return error.CommitIndeterminate;
    };
    if (file_length != self.committed_offset) {
        self.markExternalChange();
        return error.CommitIndeterminate;
    }

    const base = entry.base();
    if (self.entry_ids.contains(base.id)) return error.InvalidRecord;
    if (self.active_leaf_id) |leaf| {
        const parent = base.parent_id orelse return error.InvalidRecord;
        if (!std.mem.eql(u8, parent, leaf)) return error.InvalidRecord;
    } else if (base.parent_id != null) return error.InvalidRecord;

    const encoded = try format.encodeEntry(self.allocator, entry);
    defer self.allocator.free(encoded);
    const record_bytes = std.math.add(usize, encoded.len, 1) catch return error.SessionTooLarge;
    const proposed_offset = std.math.add(u64, self.committed_offset, record_bytes) catch
        return error.SessionTooLarge;
    if (proposed_offset > format.max_journal_bytes) return error.SessionTooLarge;

    const owned_id = self.allocator.dupe(u8, base.id) catch return error.OutOfMemory;
    self.entry_ids.ensureUnusedCapacity(self.allocator, 1) catch {
        self.allocator.free(owned_id);
        return error.OutOfMemory;
    };

    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(encoded);
    hash.update("\n");
    const digest = hash.finalResult();
    const start_offset = self.committed_offset;

    self.file.writePositionalAll(self.io, encoded, start_offset) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };
    faults.boundary(.after_append_record_write) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };
    self.file.writePositionalAll(self.io, "\n", start_offset + encoded.len) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };
    faults.boundary(.after_append_write) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };
    self.file.sync(self.io) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };
    faults.boundary(.after_append_sync) catch {
        return self.rollbackAppend(start_offset, base.id, digest, owned_id, faults);
    };

    self.entry_ids.putAssumeCapacity(owned_id, {});
    self.active_leaf_id = owned_id;
    self.committed_offset = proposed_offset;
    self.state = .writable_clean;
}

fn open(
    allocator: std.mem.Allocator,
    io: std.Io,
    dir: std.Io.Dir,
    sub_path: []const u8,
    mode: enum { read_only, writable },
) Error!Opened {
    const file = dir.openFile(io, sub_path, .{
        .mode = if (mode == .read_only) .read_only else .read_write,
        .allow_directory = false,
    }) catch |failure| return mapOpenError(failure);
    var file_owned = true;
    errdefer if (file_owned) file.close(io);
    const stat = file.stat(io) catch return error.OpenFailed;
    try validateFileStat(stat);
    if (stat.size > format.max_journal_bytes) return error.SessionTooLarge;

    var scanner = Scanner.init(allocator, io, file, stat.size);
    defer scanner.deinit();
    const header_line = (try scanner.next()) orelse return error.InvalidHeader;
    defer allocator.free(header_line.bytes);
    if (!header_line.terminated) return error.InvalidHeader;
    var restorer = try format.Restorer.init(allocator, header_line.bytes);
    var restorer_live = true;
    errdefer if (restorer_live) restorer.deinit();

    var committed_offset = header_line.next_offset;
    var torn_tail = false;
    while (try scanner.next()) |line| {
        defer allocator.free(line.bytes);
        if (!line.terminated) {
            torn_tail = true;
            break;
        }
        try restorer.append(line.bytes);
        committed_offset = line.next_offset;
    }
    var restored = try restorer.finish();
    restorer_live = false;
    errdefer restored.deinit();

    var journal: SessionJournal = .{
        .allocator = allocator,
        .io = io,
        .file = file,
        .state = if (torn_tail)
            if (mode == .read_only)
                .{ .read_only_torn_tail = committed_offset }
            else
                .{ .writable_repair_pending = committed_offset }
        else if (mode == .read_only)
            .read_only_clean
        else
            .writable_clean,
        .committed_offset = committed_offset,
    };
    file_owned = false;
    errdefer journal.deinit();
    try journal.indexEntries(restored.entries);
    return .{ .journal = journal, .restore_candidate = restored };
}

fn indexEntries(self: *SessionJournal, entries: []const format.Entry) Error!void {
    self.entry_ids.ensureTotalCapacity(self.allocator, @intCast(entries.len)) catch
        return error.OutOfMemory;
    for (entries) |entry| {
        const owned = self.allocator.dupe(u8, entry.base().id) catch return error.OutOfMemory;
        errdefer self.allocator.free(owned);
        self.entry_ids.putAssumeCapacity(owned, {});
        self.active_leaf_id = owned;
    }
}

fn repairTail(self: *SessionJournal, offset: u64, faults: Faults) Error!void {
    faults.boundary(.before_repair_truncate) catch return error.RepairFailed;
    self.file.setLength(self.io, offset) catch return error.RepairFailed;
    faults.boundary(.after_repair_truncate) catch {
        self.state = .{ .write_indeterminate = .{
            .operation = .repair,
            .start_offset = offset,
        } };
        return error.CommitIndeterminate;
    };
    self.file.sync(self.io) catch {
        self.state = .{ .write_indeterminate = .{
            .operation = .repair,
            .start_offset = offset,
        } };
        return error.CommitIndeterminate;
    };
    faults.boundary(.after_repair_sync) catch {
        self.state = .{ .write_indeterminate = .{
            .operation = .repair,
            .start_offset = offset,
        } };
        return error.CommitIndeterminate;
    };
    self.committed_offset = offset;
    self.state = .writable_clean;
}

fn rollbackAppend(
    self: *SessionJournal,
    start_offset: u64,
    entry_id: []const u8,
    digest: [32]u8,
    owned_id: []u8,
    faults: Faults,
) Error {
    defer self.allocator.free(owned_id);
    faults.boundary(.before_rollback_truncate) catch {
        self.markAppendIndeterminate(start_offset, entry_id, digest);
        return error.CommitIndeterminate;
    };
    self.file.setLength(self.io, start_offset) catch {
        self.markAppendIndeterminate(start_offset, entry_id, digest);
        return error.CommitIndeterminate;
    };
    faults.boundary(.after_rollback_truncate) catch {
        self.markAppendIndeterminate(start_offset, entry_id, digest);
        return error.CommitIndeterminate;
    };
    self.file.sync(self.io) catch {
        self.markAppendIndeterminate(start_offset, entry_id, digest);
        return error.CommitIndeterminate;
    };
    faults.boundary(.after_rollback_sync) catch {
        self.markAppendIndeterminate(start_offset, entry_id, digest);
        return error.CommitIndeterminate;
    };
    self.state = .writable_clean;
    return error.AppendFailed;
}

fn markAppendIndeterminate(
    self: *SessionJournal,
    start_offset: u64,
    entry_id: []const u8,
    digest: [32]u8,
) void {
    var state: Indeterminate = .{
        .operation = .append,
        .start_offset = start_offset,
        .encoded_sha256 = digest,
    };
    @memcpy(state.entry_id[0..entry_id.len], entry_id);
    state.entry_id_len = @intCast(entry_id.len);
    self.state = .{ .write_indeterminate = state };
}

fn markExternalChange(self: *SessionJournal) void {
    self.state = .{ .write_indeterminate = .{
        .operation = .external_change,
        .start_offset = self.committed_offset,
    } };
}

const Scanner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    file_size: u64,
    offset: u64 = 0,

    const Line = struct {
        bytes: []u8,
        terminated: bool,
        next_offset: u64,
    };

    fn init(allocator: std.mem.Allocator, io: std.Io, file: std.Io.File, file_size: u64) Scanner {
        return .{ .allocator = allocator, .io = io, .file = file, .file_size = file_size };
    }

    fn deinit(self: *Scanner) void {
        self.* = undefined;
    }

    fn next(self: *Scanner) Error!?Line {
        if (self.offset == self.file_size) return null;
        const limit: usize = if (self.offset == 0)
            format.max_header_bytes
        else
            format.max_record_bytes;
        var bytes: std.ArrayList(u8) = .empty;
        errdefer bytes.deinit(self.allocator);
        var cursor = self.offset;
        var buffer: [read_buffer_bytes]u8 = undefined;
        while (cursor < self.file_size) {
            const remaining: usize = @intCast(@min(buffer.len, self.file_size - cursor));
            const count = self.file.readPositionalAll(self.io, buffer[0..remaining], cursor) catch
                return error.ReadFailed;
            if (count == 0) return error.ReadFailed;
            if (std.mem.findScalar(u8, buffer[0..count], '\n')) |newline| {
                if (bytes.items.len + newline > limit) return sizeError(self.offset);
                bytes.appendSlice(self.allocator, buffer[0..newline]) catch return error.OutOfMemory;
                const next_offset = cursor + newline + 1;
                self.offset = next_offset;
                return .{
                    .bytes = bytes.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
                    .terminated = true,
                    .next_offset = next_offset,
                };
            }
            if (bytes.items.len + count > limit) return sizeError(self.offset);
            bytes.appendSlice(self.allocator, buffer[0..count]) catch return error.OutOfMemory;
            cursor += count;
        }
        self.offset = cursor;
        return .{
            .bytes = bytes.toOwnedSlice(self.allocator) catch return error.OutOfMemory,
            .terminated = false,
            .next_offset = cursor,
        };
    }
};

fn sizeError(offset: u64) Error {
    return if (offset == 0) error.InvalidHeader else error.InvalidRecord;
}

pub fn syncDirectory(dir: std.Io.Dir) !void {
    if (comptime builtin.os.tag == .windows) return error.OperationUnsupported;
    while (true) {
        const result = std.c.fsync(dir.handle);
        if (result == 0) return;
        if (std.c.errno(result) == .INTR) continue;
        return error.DirectorySyncFailed;
    }
}

fn validateFileStat(stat: std.Io.File.Stat) Error!void {
    if (stat.kind != .file or stat.nlink != 1) return error.UnsafeFile;
    if (comptime builtin.os.tag != .windows) {
        if (stat.permissions.toMode() & 0o077 != 0) return error.UnsafeFile;
    }
}

fn mapCreateError(failure: anyerror) Error {
    return switch (failure) {
        error.PathAlreadyExists => error.AlreadyExists,
        error.OutOfMemory => error.OutOfMemory,
        else => error.CreateFailed,
    };
}

fn mapLinkError(failure: anyerror) Error {
    return switch (failure) {
        error.PathAlreadyExists => error.AlreadyExists,
        else => error.CreateFailed,
    };
}

fn mapOpenError(failure: anyerror) Error {
    return switch (failure) {
        error.FileNotFound => error.NotFound,
        else => error.OpenFailed,
    };
}

fn testHeader() format.Header {
    return .{
        .id = "session-1",
        .timestamp = "2026-08-19T10:30:00.000Z",
        .cwd = "/tmp/zi-project",
    };
}

fn testEntry(id: []const u8, parent_id: ?[]const u8) format.Entry {
    return .{ .model_change = .{
        .base = .{
            .id = id,
            .parent_id = parent_id,
            .timestamp = "2026-08-19T10:30:01.000Z",
        },
        .selection = .{ .provider = "openai", .model = "gpt-5.2" },
    } };
}

const TestFaults = struct {
    first: Boundary,
    second: ?Boundary = null,

    fn boundary(raw: *anyopaque, point: Boundary) anyerror!void {
        const self: *TestFaults = @ptrCast(@alignCast(raw));
        if (point == self.first or point == self.second) return error.InjectedFault;
    }

    fn faults(self: *const TestFaults) Faults {
        return .{ .context = @constCast(self), .boundaryFn = boundary };
    }
};

test "session journal creates exclusively and restores a synchronized append" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var opened = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    try std.testing.expectEqual(State.writable_clean, opened.journal.state);
    try std.testing.expectEqualStrings("session-1", opened.restore_candidate.header.id);
    try opened.journal.append(testEntry("entry-1", null), .none());
    opened.deinit();

    var probe = try probeHeader(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer probe.deinit();
    try std.testing.expectEqualStrings("/tmp/zi-project", probe.header().cwd);

    var restored = try openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer restored.deinit();
    try std.testing.expectEqual(@as(usize, 1), restored.restore_candidate.entries.len);
    try std.testing.expectEqualStrings("entry-1", restored.restore_candidate.active_leaf_id.?);
    try std.testing.expectEqualStrings("gpt-5.2", restored.restore_candidate.active_model.?.model);
    try std.testing.expectError(
        error.ReadOnly,
        restored.journal.append(testEntry("entry-2", "entry-1"), .none()),
    );
    try std.testing.expectError(
        error.AlreadyExists,
        create(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
            testHeader(),
            .none(),
        ),
    );
}

test "session journal reports and repairs only an unterminated final record" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var created = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    created.deinit();
    var file = try temporary.dir.openFile(std.testing.io, "session.jsonl", .{ .mode = .read_write });
    const clean_length = try file.length(std.testing.io);
    try file.writePositionalAll(std.testing.io, "{\"type\":", clean_length);
    try file.sync(std.testing.io);
    file.close(std.testing.io);

    var read_only = try openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    switch (read_only.journal.recovery()) {
        .torn_tail => |tail| try std.testing.expectEqual(clean_length, tail.truncate_offset),
        .clean => return error.TestUnexpectedResult,
    }
    read_only.deinit();

    var writable = try openWritable(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    try writable.journal.append(testEntry("entry-1", null), .none());
    writable.deinit();

    var reopened = try openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer reopened.deinit();
    try std.testing.expect(reopened.journal.recovery() == .clean);
    try std.testing.expectEqual(@as(usize, 1), reopened.restore_candidate.entries.len);
}

test "session journal rejects newline-terminated corruption" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    var created = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    created.deinit();
    var file = try temporary.dir.openFile(std.testing.io, "session.jsonl", .{ .mode = .read_write });
    const offset = try file.length(std.testing.io);
    try file.writePositionalAll(std.testing.io, "{}\n", offset);
    try file.sync(std.testing.io);
    file.close(std.testing.io);

    try std.testing.expectError(
        error.InvalidRecord,
        openReadOnly(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "session.jsonl",
        ),
    );
}

test "session journal rolls back a failed append before accepting another" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var opened = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    defer opened.deinit();

    const start_offset = opened.journal.committed_offset;
    for ([_]Boundary{
        .after_append_record_write,
        .after_append_write,
        .after_append_sync,
    }) |boundary| {
        const injected: TestFaults = .{ .first = boundary };
        try std.testing.expectError(
            error.AppendFailed,
            opened.journal.append(testEntry("entry-1", null), injected.faults()),
        );
        try std.testing.expectEqual(State.writable_clean, opened.journal.state);
        try std.testing.expectEqual(start_offset, try opened.journal.file.length(std.testing.io));
    }
    try opened.journal.append(testEntry("entry-1", null), .none());
}

test "session journal blocks writes after an indeterminate rollback" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var opened = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    errdefer opened.deinit();

    const injected: TestFaults = .{
        .first = .after_append_write,
        .second = .before_rollback_truncate,
    };
    try std.testing.expectError(
        error.CommitIndeterminate,
        opened.journal.append(testEntry("entry-1", null), injected.faults()),
    );
    const indeterminate = opened.journal.state.write_indeterminate;
    try std.testing.expectEqualStrings("entry-1", indeterminate.entryId());
    try std.testing.expectEqual(.append, indeterminate.operation);
    try std.testing.expectError(
        error.CommitIndeterminate,
        opened.journal.append(testEntry("entry-2", null), .none()),
    );
    opened.deinit();

    var reopened = try openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer reopened.deinit();
    try std.testing.expectEqual(@as(usize, 1), reopened.restore_candidate.entries.len);
    try std.testing.expectEqualStrings("entry-1", reopened.restore_candidate.active_leaf_id.?);
}

test "session journal creation distinguishes cleanup from published uncertainty" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();

    const before_publish: TestFaults = .{ .first = .after_create_header_write };
    try std.testing.expectError(
        error.CreateFailed,
        create(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "not-published.jsonl",
            testHeader(),
            before_publish.faults(),
        ),
    );
    try std.testing.expectError(
        error.FileNotFound,
        temporary.dir.access(std.testing.io, "not-published.jsonl", .{}),
    );

    const after_publish: TestFaults = .{ .first = .after_create_publish };
    try std.testing.expectError(
        error.CreateIndeterminate,
        create(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "published.jsonl",
            testHeader(),
            after_publish.faults(),
        ),
    );
    var reopened = try openReadOnly(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "published.jsonl",
    );
    defer reopened.deinit();
    try std.testing.expectEqualStrings("session-1", reopened.restore_candidate.header.id);
}

test "session journal retains a repair-pending tail after a definite repair failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var created = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    created.deinit();
    var file = try temporary.dir.openFile(std.testing.io, "session.jsonl", .{ .mode = .read_write });
    const offset = try file.length(std.testing.io);
    try file.writePositionalAll(std.testing.io, "{", offset);
    try file.sync(std.testing.io);
    file.close(std.testing.io);

    var opened = try openWritable(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
    );
    defer opened.deinit();
    const injected: TestFaults = .{ .first = .before_repair_truncate };
    try std.testing.expectError(
        error.RepairFailed,
        opened.journal.append(testEntry("entry-1", null), injected.faults()),
    );
    try std.testing.expectEqual(
        offset,
        opened.journal.state.writable_repair_pending,
    );
    try opened.journal.append(testEntry("entry-1", null), .none());
}

fn allocationOpen(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var opened = try openReadOnly(allocator, std.testing.io, dir, "session.jsonl");
    defer opened.deinit();
}

fn allocationProbe(allocator: std.mem.Allocator, dir: std.Io.Dir) !void {
    var probe = try probeHeader(allocator, std.testing.io, dir, "session.jsonl");
    defer probe.deinit();
}

test "session journal open settles every allocation failure" {
    var temporary = std.testing.tmpDir(.{});
    defer temporary.cleanup();
    var created = try create(
        std.testing.allocator,
        std.testing.io,
        temporary.dir,
        "session.jsonl",
        testHeader(),
        .none(),
    );
    try created.journal.append(testEntry("entry-1", null), .none());
    created.deinit();

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationOpen,
        .{temporary.dir},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocationProbe,
        .{temporary.dir},
    );
}
