const std = @import("std");
const builtin = @import("builtin");
const ai = @import("../ai/root.zig");
const agent_root = @import("../agent/root.zig");
const SessionFormat = @import("SessionFormat.zig");
const ZiPaths = @import("ZiPaths.zig");

pub const Journal = struct {
    const format = SessionFormat;
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

        // ziglint-ignore: Z012
        pub fn none() Faults {
            return .{};
        }

        fn boundary(self: Faults, point: Boundary) !void {
            const function = self.boundaryFn orelse return;
            try function(self.context.?, point);
        }
    };

    pub const Opened = struct {
        journal: Journal,
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

    pub fn deinit(self: *Journal) void {
        var iterator = self.entry_ids.keyIterator();
        while (iterator.next()) |key| self.allocator.free(key.*);
        self.entry_ids.deinit(self.allocator);
        self.file.close(self.io);
        self.* = undefined;
    }

    pub fn recovery(self: *const Journal) Recovery {
        return switch (self.state) {
            .read_only_torn_tail => |offset| .{ .torn_tail = .{ .truncate_offset = offset } },
            .writable_repair_pending => |offset| .{ .torn_tail = .{ .truncate_offset = offset } },
            else => .clean,
        };
    }

    pub fn activeLeafId(self: *const Journal) ?[]const u8 {
        return self.active_leaf_id;
    }

    pub fn append(self: *Journal, entry: format.Entry, faults: Faults) Error!void {
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

        var journal: Journal = .{
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

    fn indexEntries(self: *Journal, entries: []const format.Entry) Error!void {
        self.entry_ids.ensureTotalCapacity(self.allocator, @intCast(entries.len)) catch
            return error.OutOfMemory;
        for (entries) |entry| {
            const owned = self.allocator.dupe(u8, entry.base().id) catch return error.OutOfMemory;
            errdefer self.allocator.free(owned);
            self.entry_ids.putAssumeCapacity(owned, {});
            self.active_leaf_id = owned;
        }
    }

    fn repairTail(self: *Journal, offset: u64, faults: Faults) Error!void {
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
        self: *Journal,
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
        self: *Journal,
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

    fn markExternalChange(self: *Journal) void {
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
};

pub const Selection = struct {
    const format = SessionFormat;
    const journal_api = Journal;
    const sessions_directory_name = "sessions";
    const max_directory_entries = 4096;
    const private_dir_permissions = std.Io.File.Permissions.fromMode(0o700);

    pub const Error = error{
        OutOfMemory,
        InvalidPath,
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
        InvalidSessionPath,
        MissingCwd,
        CwdUnavailable,
        SessionChanged,
        SessionStorageUnavailable,
        TooManySessions,
    };

    pub const Intent = union(enum) {
        new,
        open: []const u8,
        continue_recent,
    };

    const Origin = enum {
        new,
        opened,
        continued,
    };

    allocator: std.mem.Allocator,
    io: std.Io,
    paths: ZiPaths,
    journal_path: []const u8,
    journal: JournalOwnership,
    origin: Origin,
    discard_new: bool = false,

    const JournalOwnership = union(enum) {
        admitted: journal_api.Opened,
        transferred,
    };

    pub fn select(
        allocator: std.mem.Allocator,
        io: std.Io,
        startup_cwd: []const u8,
        home: []const u8,
        sources: format.Sources,
        intent: Intent,
    ) Error!Selection {
        return switch (intent) {
            .new => createNew(allocator, io, startup_cwd, home, sources),
            .open => |path| openExact(allocator, io, startup_cwd, home, path, .opened),
            .continue_recent => continueRecent(allocator, io, startup_cwd, home, sources),
        };
    }

    pub fn deinit(self: *Selection) void {
        const owns_journal = switch (self.journal) {
            .admitted => true,
            .transferred => false,
        };
        const remove_new = self.origin == .new and self.discard_new and owns_journal;
        switch (self.journal) {
            .admitted => |*opened| opened.deinit(),
            .transferred => {},
        }
        if (remove_new) {
            std.Io.Dir.deleteFile(.cwd(), self.io, self.journal_path) catch |failure|
                ignoreDeleteError(failure);
        }
        self.allocator.free(self.journal_path);
        self.paths.deinit();
        self.* = undefined;
    }

    pub fn pathsView(self: *const Selection) *const ZiPaths {
        return &self.paths;
    }

    pub fn journalPath(self: *const Selection) []const u8 {
        return self.journal_path;
    }

    pub fn restoredModel(self: *const Selection) ?ai.ModelIdentity {
        return self.restoredView().active_model;
    }

    pub fn discardNew(self: *Selection) void {
        self.discard_new = true;
    }

    pub fn isFresh(self: *const Selection) bool {
        return self.origin == .new;
    }

    pub fn takeJournal(self: *Selection) journal_api.Opened {
        return switch (self.journal) {
            .admitted => |opened| result: {
                self.journal = .transferred;
                break :result opened;
            },
            .transferred => unreachable,
        };
    }

    /// Borrows the admitted restoration until `takeJournal` transfers it.
    pub fn restoredView(self: *const Selection) *const format.Restored {
        return switch (self.journal) {
            .admitted => |*opened| &opened.restore_candidate,
            .transferred => unreachable,
        };
    }

    fn ignoreDeleteError(failure: anyerror) void {
        std.debug.assert(@errorName(failure).len != 0);
    }

    /// Journal filenames bind a fixed-width stamp id to a constant extension.
    /// The typed id buffer makes any stamp-width change a compile error here
    /// instead of a runtime formatting failure.
    const journal_filename_width = format.stamp_id_width + ".jsonl".len;

    fn writeJournalFilename(buffer: *[journal_filename_width]u8, stamp: *const format.Stamp) []const u8 {
        const id_text = &stamp.id_buffer;
        @memcpy(buffer[0..id_text.len], id_text);
        @memcpy(buffer[id_text.len..], ".jsonl");
        return buffer;
    }

    fn createNew(
        allocator: std.mem.Allocator,
        io: std.Io,
        cwd: []const u8,
        home: []const u8,
        sources: format.Sources,
    ) Error!Selection {
        var paths = try ZiPaths.init(allocator, cwd, home);
        errdefer paths.deinit();
        try admitCwd(io, paths.cwd);
        const sessions_path = try resolveSessionsPath(allocator, &paths);
        defer allocator.free(sessions_path);
        try ensureSessionStorage(io, sessions_path);

        const stamp = try sources.next();
        var filename_buffer: [journal_filename_width]u8 = undefined;
        const filename = writeJournalFilename(&filename_buffer, &stamp);
        const journal_path = std.fs.path.resolve(allocator, &.{ sessions_path, filename }) catch
            return error.OutOfMemory;
        errdefer allocator.free(journal_path);
        if (journal_path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
        var directory = std.Io.Dir.openDir(.cwd(), io, sessions_path, .{}) catch
            return error.SessionStorageUnavailable;
        defer directory.close(io);

        var opened = try journal_api.create(
            allocator,
            io,
            directory,
            filename,
            .{
                .id = stamp.id(),
                .timestamp = stamp.timestamp(),
                .cwd = paths.cwd,
            },
            .none(),
        );
        errdefer opened.deinit();
        return .{
            .allocator = allocator,
            .io = io,
            .paths = paths,
            .journal_path = journal_path,
            .journal = .{ .admitted = opened },
            .origin = .new,
        };
    }

    fn openExact(
        allocator: std.mem.Allocator,
        io: std.Io,
        startup_cwd: []const u8,
        home: []const u8,
        input_path: []const u8,
        origin: Origin,
    ) Error!Selection {
        var startup_paths = try ZiPaths.init(allocator, startup_cwd, home);
        defer startup_paths.deinit();
        try validateInputPath(input_path);
        const journal_path = std.fs.path.resolve(allocator, &.{ startup_paths.cwd, input_path }) catch
            return error.OutOfMemory;
        errdefer allocator.free(journal_path);
        if (journal_path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
        const parent_path = std.fs.path.dirname(journal_path) orelse return error.InvalidSessionPath;
        const filename = std.fs.path.basename(journal_path);
        if (filename.len == 0) return error.InvalidSessionPath;
        var directory = std.Io.Dir.openDir(.cwd(), io, parent_path, .{}) catch |failure| {
            return switch (failure) {
                error.FileNotFound => error.NotFound,
                else => error.OpenFailed,
            };
        };
        defer directory.close(io);

        var probe = try journal_api.probeHeader(allocator, io, directory, filename);
        defer probe.deinit();
        const probed = probe.header();
        var paths = try ZiPaths.init(allocator, probed.cwd, home);
        errdefer paths.deinit();
        try admitCwd(io, paths.cwd);

        var opened = try journal_api.openWritable(allocator, io, directory, filename);
        errdefer opened.deinit();
        if (!sameHeader(probed, opened.restore_candidate.header)) return error.SessionChanged;
        return .{
            .allocator = allocator,
            .io = io,
            .paths = paths,
            .journal_path = journal_path,
            .journal = .{ .admitted = opened },
            .origin = origin,
        };
    }

    fn continueRecent(
        allocator: std.mem.Allocator,
        io: std.Io,
        startup_cwd: []const u8,
        home: []const u8,
        sources: format.Sources,
    ) Error!Selection {
        var paths = try ZiPaths.init(allocator, startup_cwd, home);
        defer paths.deinit();
        try admitCwd(io, paths.cwd);
        const recent_path = try findRecent(allocator, io, &paths);
        if (recent_path) |path| {
            defer allocator.free(path);
            return openExact(allocator, io, paths.cwd, home, path, .continued);
        }
        return createNew(allocator, io, paths.cwd, home, sources);
    }

    fn findRecent(
        allocator: std.mem.Allocator,
        io: std.Io,
        paths: *const ZiPaths,
    ) Error!?[]u8 {
        const sessions_path = try resolveSessionsPath(allocator, paths);
        defer allocator.free(sessions_path);
        var directory = std.Io.Dir.openDir(.cwd(), io, sessions_path, .{ .iterate = true }) catch |failure| {
            return switch (failure) {
                error.FileNotFound => null,
                else => error.SessionStorageUnavailable,
            };
        };
        defer directory.close(io);
        var iterator = directory.iterateAssumeFirstIteration();
        var inspected: usize = 0;
        var best_name: ?[]u8 = null;
        defer if (best_name) |name| allocator.free(name);
        var best_mtime: i96 = 0;

        while (iterator.next(io) catch return error.SessionStorageUnavailable) |entry| {
            inspected += 1;
            if (inspected > max_directory_entries) return error.TooManySessions;
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
            const stat = directory.statFile(io, entry.name, .{}) catch |failure| switch (failure) {
                error.FileNotFound => continue,
                else => return error.SessionStorageUnavailable,
            };
            if (stat.kind != .file) continue;
            var probe = journal_api.probeHeader(allocator, io, directory, entry.name) catch |failure| switch (failure) {
                error.OutOfMemory => return error.OutOfMemory,
                else => continue,
            };
            defer probe.deinit();
            if (!std.mem.eql(u8, probe.header().cwd, paths.cwd)) continue;
            const newer = best_name == null or stat.mtime.nanoseconds > best_mtime or
                (stat.mtime.nanoseconds == best_mtime and
                    std.mem.order(u8, entry.name, best_name.?) == .gt);
            if (!newer) continue;
            const owned_name = allocator.dupe(u8, entry.name) catch return error.OutOfMemory;
            if (best_name) |name| allocator.free(name);
            best_name = owned_name;
            best_mtime = stat.mtime.nanoseconds;
        }

        const name = best_name orelse return null;
        const result = std.fs.path.resolve(allocator, &.{ sessions_path, name }) catch
            return error.OutOfMemory;
        if (result.len > ZiPaths.max_path_bytes) {
            allocator.free(result);
            return error.InvalidSessionPath;
        }
        return result;
    }

    fn admitCwd(io: std.Io, cwd: []const u8) Error!void {
        const stat = std.Io.Dir.statFile(.cwd(), io, cwd, .{}) catch |failure| {
            return switch (failure) {
                error.FileNotFound => error.MissingCwd,
                else => error.CwdUnavailable,
            };
        };
        if (stat.kind != .directory) return error.MissingCwd;
    }

    fn resolveSessionsPath(allocator: std.mem.Allocator, paths: *const ZiPaths) Error![]u8 {
        const result = std.fs.path.resolve(allocator, &.{ paths.global_agent, sessions_directory_name }) catch
            return error.OutOfMemory;
        if (result.len > ZiPaths.max_path_bytes) {
            allocator.free(result);
            return error.InvalidSessionPath;
        }
        return result;
    }

    fn ensureSessionStorage(io: std.Io, path: []const u8) Error!void {
        _ = std.Io.Dir.createDirPathStatus(.cwd(), io, path, private_dir_permissions) catch
            return error.SessionStorageUnavailable;
        const agent_path = std.fs.path.dirname(path) orelse return error.SessionStorageUnavailable;
        const zi_path = std.fs.path.dirname(agent_path) orelse return error.SessionStorageUnavailable;
        const home_path = std.fs.path.dirname(zi_path) orelse return error.SessionStorageUnavailable;
        const sync_paths = [_][]const u8{ path, agent_path, zi_path, home_path };
        for (sync_paths) |sync_path| {
            var directory = std.Io.Dir.openDir(.cwd(), io, sync_path, .{}) catch
                return error.SessionStorageUnavailable;
            defer directory.close(io);
            journal_api.syncDirectory(directory) catch return error.SessionStorageUnavailable;
        }
    }

    fn validateInputPath(path: []const u8) error{InvalidSessionPath}!void {
        if (path.len == 0 or path.len > ZiPaths.max_path_bytes) return error.InvalidSessionPath;
        if (!std.unicode.utf8ValidateSlice(path)) return error.InvalidSessionPath;
        if (std.mem.findScalar(u8, path, 0) != null) return error.InvalidSessionPath;
    }

    fn sameHeader(left: format.Header, right: format.Header) bool {
        return std.mem.eql(u8, left.id, right.id) and
            std.mem.eql(u8, left.timestamp, right.timestamp) and
            std.mem.eql(u8, left.cwd, right.cwd);
    }

    const TestSources = struct {
        next_id: u64 = 0,
        next_ms: u64 = 1_777_800_000_000,

        fn nextId(context: *anyopaque) [16]u8 {
            const self: *TestSources = @ptrCast(@alignCast(context));
            self.next_id += 1;
            var bytes: [16]u8 = @splat(0);
            std.mem.writeInt(u64, bytes[8..16], self.next_id, .big);
            return bytes;
        }

        fn nowMs(context: *anyopaque) u64 {
            const self: *TestSources = @ptrCast(@alignCast(context));
            defer self.next_ms += 1;
            return self.next_ms;
        }

        fn view(self: *TestSources) format.Sources {
            return .{
                .id_context = self,
                .nextIdFn = nextId,
                .clock_context = self,
                .nowMsFn = nowMs,
            };
        }
    };

    fn temporaryPath(temporary: *std.testing.TmpDir, buffer: []u8) ![]const u8 {
        const length = try temporary.dir.realPath(std.testing.io, buffer);
        return buffer[0..length];
    }

    test "session selection creates a private journal from admitted paths" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var sources: TestSources = .{};

        var selected = try select(
            std.testing.allocator,
            std.testing.io,
            root,
            root,
            sources.view(),
            .new,
        );
        defer selected.deinit();

        try std.testing.expect(selected.origin == .new);
        try std.testing.expectEqualStrings(root, selected.paths.cwd);
        try std.testing.expectEqualStrings(root, selected.restoredView().header.cwd);
        const sessions_path = try resolveSessionsPath(std.testing.allocator, &selected.paths);
        defer std.testing.allocator.free(sessions_path);
        try std.testing.expect(std.mem.startsWith(u8, selected.journal_path, sessions_path));
        const stat = try std.Io.Dir.statFile(.cwd(), std.testing.io, selected.journal_path, .{});
        try std.testing.expectEqual(@as(u16, 0), stat.permissions.toMode() & 0o077);
    }

    test "session selection opens an exact relative path with the stored cwd" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, "launch", .default_dir);
        try temporary.dir.createDir(std.testing.io, "stored", .default_dir);
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const launch = try std.fs.path.resolve(std.testing.allocator, &.{ root, "launch" });
        defer std.testing.allocator.free(launch);
        const stored = try std.fs.path.resolve(std.testing.allocator, &.{ root, "stored" });
        defer std.testing.allocator.free(stored);
        var sources: TestSources = .{};
        var created = try select(
            std.testing.allocator,
            std.testing.io,
            stored,
            root,
            sources.view(),
            .new,
        );
        const relative = try std.fs.path.relative(
            std.testing.allocator,
            launch,
            null,
            launch,
            created.journal_path,
        );
        defer std.testing.allocator.free(relative);
        created.deinit();

        var opened = try select(
            std.testing.allocator,
            std.testing.io,
            launch,
            root,
            sources.view(),
            .{ .open = relative },
        );
        defer opened.deinit();
        try std.testing.expect(opened.origin == .opened);
        try std.testing.expectEqualStrings(stored, opened.paths.cwd);
    }

    test "session continuation chooses the newest valid journal for the admitted cwd" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        try temporary.dir.createDir(std.testing.io, "project-a", .default_dir);
        try temporary.dir.createDir(std.testing.io, "project-b", .default_dir);
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const project_a = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project-a" });
        defer std.testing.allocator.free(project_a);
        const project_b = try std.fs.path.resolve(std.testing.allocator, &.{ root, "project-b" });
        defer std.testing.allocator.free(project_b);
        var sources: TestSources = .{};
        var older = try select(
            std.testing.allocator,
            std.testing.io,
            project_a,
            root,
            sources.view(),
            .new,
        );
        const older_id = try std.testing.allocator.dupe(u8, older.restoredView().header.id);
        defer std.testing.allocator.free(older_id);
        var older_file = try std.Io.Dir.openFile(.cwd(), std.testing.io, older.journal_path, .{ .mode = .read_write });
        defer older_file.close(std.testing.io);
        try older_file.setTimestamps(std.testing.io, .{
            .modify_timestamp = .{ .new = .fromNanoseconds(1_000_000) },
        });
        older.deinit();

        var other = try select(
            std.testing.allocator,
            std.testing.io,
            project_b,
            root,
            sources.view(),
            .new,
        );
        other.deinit();
        var newer = try select(
            std.testing.allocator,
            std.testing.io,
            project_a,
            root,
            sources.view(),
            .new,
        );
        const newer_id = try std.testing.allocator.dupe(u8, newer.restoredView().header.id);
        defer std.testing.allocator.free(newer_id);
        newer.deinit();

        var continued = try select(
            std.testing.allocator,
            std.testing.io,
            project_a,
            root,
            sources.view(),
            .continue_recent,
        );
        defer continued.deinit();
        try std.testing.expect(continued.origin == .continued);
        try std.testing.expect(!std.mem.eql(u8, older_id, newer_id));
        try std.testing.expectEqualStrings(newer_id, continued.restoredView().header.id);
    }

    test "session continuation ignores corrupt candidates and creates a new journal" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        const sessions_path = try resolveSessionsPath(std.testing.allocator, &paths);
        defer std.testing.allocator.free(sessions_path);
        try ensureSessionStorage(std.testing.io, sessions_path);
        var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, sessions_path, .{});
        defer directory.close(std.testing.io);
        try directory.writeFile(std.testing.io, .{
            .sub_path = "corrupt.jsonl",
            .data = "not a session\n",
        });
        var sources: TestSources = .{};

        var continued = try select(
            std.testing.allocator,
            std.testing.io,
            root,
            root,
            sources.view(),
            .continue_recent,
        );
        defer continued.deinit();
        try std.testing.expect(continued.origin == .new);
        try std.testing.expect(!std.mem.endsWith(u8, continued.journal_path, "corrupt.jsonl"));
    }

    test "session continuation bounds directory inspection" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        var paths = try ZiPaths.init(std.testing.allocator, root, root);
        defer paths.deinit();
        const sessions_path = try resolveSessionsPath(std.testing.allocator, &paths);
        defer std.testing.allocator.free(sessions_path);
        try ensureSessionStorage(std.testing.io, sessions_path);
        var directory = try std.Io.Dir.openDir(.cwd(), std.testing.io, sessions_path, .{});
        defer directory.close(std.testing.io);
        var name_buffer: [32]u8 = undefined;
        for (0..max_directory_entries + 1) |index| {
            const name = try std.fmt.bufPrint(&name_buffer, "ignored-{d}", .{index});
            const file = try directory.createFile(std.testing.io, name, .{});
            file.close(std.testing.io);
        }
        var sources: TestSources = .{};

        try std.testing.expectError(error.TooManySessions, select(
            std.testing.allocator,
            std.testing.io,
            root,
            root,
            sources.view(),
            .continue_recent,
        ));
    }

    test "session selection rejects a missing stored cwd before full restoration" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        const missing = try std.fs.path.resolve(std.testing.allocator, &.{ root, "missing" });
        defer std.testing.allocator.free(missing);
        var sources: TestSources = .{};
        const stamp = try sources.view().next();
        var opened = try journal_api.create(
            std.testing.allocator,
            std.testing.io,
            temporary.dir,
            "missing-cwd.jsonl",
            .{ .id = stamp.id(), .timestamp = stamp.timestamp(), .cwd = missing },
            .none(),
        );
        opened.deinit();

        try std.testing.expectError(error.MissingCwd, select(
            std.testing.allocator,
            std.testing.io,
            root,
            root,
            sources.view(),
            .{ .open = "missing-cwd.jsonl" },
        ));
    }

    fn createAndDispose(allocator: std.mem.Allocator, root: []const u8) !void {
        var path_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const path = try std.fmt.bufPrint(
            &path_buffer,
            "{s}/.zi/agent/sessions/00000000-0000-0000-0000-000000000001.jsonl",
            .{root},
        );
        std.Io.Dir.deleteFile(.cwd(), std.testing.io, path) catch |failure| switch (failure) {
            error.FileNotFound => {},
            else => return failure,
        };
        var sources: TestSources = .{};
        var selected = try select(allocator, std.testing.io, root, root, sources.view(), .new);
        selected.deinit();
    }

    test "session selection settles every allocation failure" {
        var temporary = std.testing.tmpDir(.{});
        defer temporary.cleanup();
        var root_buffer: [std.Io.Dir.max_path_bytes]u8 = undefined;
        const root = try temporaryPath(&temporary, &root_buffer);
        try std.testing.checkAllAllocationFailures(std.testing.allocator, createAndDispose, .{root});
    }
};

pub const Commit = struct {
    const format = SessionFormat;
    const journal_api = Journal;
    const agent_api = agent_root;
    const ai_message = ai.message;
    const Agent = agent_api.Agent;
    const commit_api = agent_api.commit;
    pub const Error = error{
        OutOfMemory,
        SessionTooLarge,
        PersistenceFailed,
        CommitIndeterminate,
    };

    const EntryId = struct {
        bytes: [128]u8 = undefined,
        len: u8,

        fn init(value: []const u8) EntryId {
            var id: EntryId = .{ .len = @intCast(value.len) };
            @memcpy(id.bytes[0..value.len], value);
            return id;
        }

        fn slice(self: *const EntryId) []const u8 {
            return self.bytes[0..self.len];
        }
    };

    const TurnState = union(enum) {
        idle,
        active: EntryId,
    };

    const BindingState = union(enum) {
        restore_candidate: format.Restored,
        active,
    };

    allocator: std.mem.Allocator,
    journal: journal_api,
    sources: format.Sources,
    faults: journal_api.Faults,
    binding: BindingState,
    turn: TurnState = .idle,

    pub fn create(
        allocator: std.mem.Allocator,
        opened: *journal_api.Opened,
        sources: format.Sources,
        selection: ai_message.ModelIdentity,
        thinking_level: ai.ThinkingLevel,
        faults: journal_api.Faults,
    ) Error!*Commit {
        var owned = opened.*;
        opened.* = undefined;
        var owned_live = true;
        errdefer if (owned_live) owned.deinit();
        const self = allocator.create(Commit) catch return error.OutOfMemory;
        self.* = .{
            .allocator = allocator,
            .journal = owned.journal,
            .sources = sources,
            .faults = faults,
            .binding = .{ .restore_candidate = owned.restore_candidate },
        };
        owned_live = false;
        errdefer self.deinit();

        const restored = &self.binding.restore_candidate;
        switch (restored.recovery) {
            .clean => {},
            .interrupted => |interrupted| try self.appendTerminal(interrupted.turn_id, .interrupted),
        }
        const model_changed = restored.active_model == null or !sameModel(restored.active_model.?, selection);
        if (model_changed) try self.appendModelChange(selection);
        if (model_changed or restored.active_thinking_level == null or
            restored.active_thinking_level.? != thinking_level)
        {
            try self.appendThinkingLevelChange(thinking_level);
        }
        return self;
    }

    pub fn bindAgent(self: *Commit, agent: *Agent) Error!void {
        const restored = &self.binding.restore_candidate;
        agent.bindCommits(restored.context_messages, self.sink()) catch |failure| switch (failure) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SessionTooLarge => return error.SessionTooLarge,
        };
        restored.deinit();
        self.binding = .active;
    }

    // Heap destruction follows explicit field invalidation.
    // ziglint-ignore: Z030
    pub fn deinit(self: *Commit) void {
        const allocator = self.allocator;
        switch (self.binding) {
            .restore_candidate => |*restored| restored.deinit(),
            .active => {},
        }
        self.journal.deinit();
        self.* = undefined;
        allocator.destroy(self);
    }

    fn sink(self: *Commit) commit_api.Sink {
        return .{
            .context = self,
            .messageFn = commitMessage,
            .settleFn = settleRun,
        };
    }

    fn commitMessage(
        context: *anyopaque,
        kind: commit_api.MessageKind,
        message: ai_message.Message,
    ) commit_api.Error!void {
        const self: *Commit = @ptrCast(@alignCast(context));
        const stamp = self.sources.next() catch return error.PersistenceFailed;
        const entry: format.Entry = .{ .message = .{
            .base = stamp.base(self.journal.activeLeafId()),
            .message = message,
        } };
        self.journal.append(entry, self.faults) catch |failure| return mapJournalError(failure);
        if (kind == .user) self.turn = .{ .active = EntryId.init(stamp.id()) };
    }

    fn settleRun(context: *anyopaque, outcome: commit_api.RunOutcome) commit_api.Error!void {
        const self: *Commit = @ptrCast(@alignCast(context));
        const turn_id = switch (self.turn) {
            .active => |*id| id.slice(),
            .idle => unreachable,
        };
        try self.appendTerminal(turn_id, mapOutcome(outcome));
        self.turn = .idle;
    }

    pub fn appendThinkingLevelChange(self: *Commit, level: ai.ThinkingLevel) Error!void {
        if (self.turn != .idle) unreachable;
        const stamp = self.sources.next() catch return error.PersistenceFailed;
        self.journal.append(.{ .thinking_level_change = .{
            .base = stamp.base(self.journal.activeLeafId()),
            .level = level,
        } }, self.faults) catch |failure| return mapJournalError(failure);
    }

    fn appendModelChange(self: *Commit, selection: ai_message.ModelIdentity) Error!void {
        const stamp = self.sources.next() catch return error.PersistenceFailed;
        self.journal.append(.{ .model_change = .{
            .base = stamp.base(self.journal.activeLeafId()),
            .selection = selection,
        } }, self.faults) catch |failure| return mapJournalError(failure);
    }

    fn appendTerminal(self: *Commit, turn_id: []const u8, outcome: format.TurnOutcome) Error!void {
        const stamp = self.sources.next() catch return error.PersistenceFailed;
        self.journal.append(.{ .turn_end = .{
            .base = stamp.base(self.journal.activeLeafId()),
            .turn_id = turn_id,
            .outcome = outcome,
        } }, self.faults) catch |failure| return mapJournalError(failure);
    }

    fn mapJournalError(failure: journal_api.Error) commit_api.Error {
        return switch (failure) {
            error.OutOfMemory => error.OutOfMemory,
            error.SessionTooLarge, error.TooManyEntries => error.SessionTooLarge,
            error.CommitIndeterminate => error.CommitIndeterminate,
            else => error.PersistenceFailed,
        };
    }

    fn mapOutcome(outcome: commit_api.RunOutcome) format.TurnOutcome {
        return switch (outcome) {
            .completed => .completed,
            .cancelled => .cancelled,
            .interrupted => .interrupted,
            .failed => |failure| .{ .failed = switch (failure) {
                .resource_exhausted => .resource_exhausted,
                .timed_out => .timed_out,
                .unsupported_capability => .unsupported_capability,
                .unsupported_setting => .unsupported_setting,
                .invalid_request => .invalid_request,
                .connection_failed => .connection_failed,
                .rate_limited => .rate_limited,
                .provider_rejected_request => .provider_rejected_request,
                .provider_unavailable => .provider_unavailable,
                .invalid_provider_response => .invalid_provider_response,
                .event_consumer_stopped => .stream_consumer_stopped,
                .handoff_rejected => .handoff_rejected,
                .max_model_requests_exceeded => .max_model_requests_exceeded,
                .max_tool_calls_exceeded => .max_tool_calls_exceeded,
                .tool_result_too_large => .tool_result_too_large,
                .tool_control_unavailable => .tool_control_unavailable,
                .persistence_failed => .persistence_failed,
            } },
        };
    }

    fn sameModel(left: ai_message.ModelIdentity, right: ai_message.ModelIdentity) bool {
        return std.mem.eql(u8, left.provider, right.provider) and
            std.mem.eql(u8, left.model, right.model);
    }
};

pub const Transcript = struct {
    const session_format = SessionFormat;
    pub const Error = error{
        OutOfMemory,
        InvalidTranscript,
    };

    pub const DurableMetadata = struct {
        entry_id: []const u8,
        timestamp: []const u8,
    };

    pub const Metadata = union(enum) {
        durable: DurableMetadata,
        recovered_open_turn,
    };

    pub const Interrupted = struct {
        turn_id: []const u8,
    };

    pub const UserTurn = struct {
        parts: []const ai.message.UserContent,
    };

    pub const ToolResults = struct {
        results: []const ai.message.ToolResult,
    };

    pub const Content = union(enum) {
        model_change: ai.message.ModelIdentity,
        thinking_level_change: ai.ThinkingLevel,
        user: UserTurn,
        assistant: ai.message.ResponseMessage,
        tool_results: ToolResults,
        failure: struct {
            turn_id: []const u8,
            category: session_format.FailureCategory,
        },
        cancelled: struct { turn_id: []const u8 },
        interrupted: Interrupted,
    };

    pub const Item = struct {
        metadata: Metadata,
        content: Content,
    };

    arena: std.heap.ArenaAllocator,
    items: []const Item,

    /// Builds an owned presentation-neutral projection of the restored active
    /// branch. The result remains valid after the journal restoration is released.
    pub fn init(
        allocator: std.mem.Allocator,
        restored: *const session_format.Restored,
    ) Error!Transcript {
        var arena = std.heap.ArenaAllocator.init(allocator);
        errdefer arena.deinit();
        const memory = arena.allocator();

        // SessionFormat.Restored projects the active branch once; Transcript
        // consumes that projection instead of re-walking the journal topology.
        if ((restored.active_leaf_id != null) != (restored.active_entries.len != 0)) {
            return error.InvalidTranscript;
        }

        var projected: std.ArrayList(Item) = .empty;
        for (restored.active_entries) |entry| {
            const content: ?Content = switch (entry) {
                .model_change => |change| .{ .model_change = try ai.message.copyIdentityLeaky(
                    memory,
                    change.selection,
                ) },
                .thinking_level_change => |change| .{ .thinking_level_change = change.level },
                .message => |message_entry| switch (message_entry.message) {
                    .response => |response| .{
                        .assistant = try ai.message.copyResponseLeaky(memory, response),
                    },
                    .request => |request| switch (try classifyRequest(request)) {
                        .user => .{ .user = try copyUserTurnLeaky(memory, request) },
                        .tool_results => .{
                            .tool_results = try copyToolResultsLeaky(memory, request),
                        },
                    },
                },
                .turn_end => |terminal| switch (terminal.outcome) {
                    .completed => null,
                    .failed => |category| .{ .failure = .{
                        .turn_id = try memory.dupe(u8, terminal.turn_id),
                        .category = category,
                    } },
                    .cancelled => .{ .cancelled = .{
                        .turn_id = try memory.dupe(u8, terminal.turn_id),
                    } },
                    .interrupted => .{ .interrupted = .{
                        .turn_id = try memory.dupe(u8, terminal.turn_id),
                    } },
                },
            };
            if (content) |value| try projected.append(memory, .{
                .metadata = try copyMetadataLeaky(memory, entry.base()),
                .content = value,
            });
        }

        switch (restored.recovery) {
            .clean => {},
            .interrupted => |interrupted| try projected.append(memory, .{
                .metadata = .recovered_open_turn,
                .content = .{ .interrupted = .{
                    .turn_id = try memory.dupe(u8, interrupted.turn_id),
                } },
            }),
        }

        return .{
            .arena = arena,
            .items = projected.items,
        };
    }

    pub fn deinit(self: *Transcript) void {
        self.arena.deinit();
        self.* = undefined;
    }

    const RequestKind = enum {
        user,
        tool_results,
    };

    fn classifyRequest(request: ai.message.RequestMessage) Error!RequestKind {
        if (request.parts.len == 0) return error.InvalidTranscript;
        var kind: ?RequestKind = null;
        for (request.parts) |part| {
            const current: RequestKind = switch (part) {
                .user => .user,
                .tool_result => .tool_results,
                .retry_prompt => return error.InvalidTranscript,
            };
            if (kind) |existing| {
                if (existing != current) return error.InvalidTranscript;
            } else {
                kind = current;
            }
        }
        return kind.?;
    }

    fn copyUserTurnLeaky(
        allocator: std.mem.Allocator,
        request: ai.message.RequestMessage,
    ) error{OutOfMemory}!UserTurn {
        const parts = try allocator.alloc(ai.message.UserContent, request.parts.len);
        for (request.parts, parts) |part, *copy| {
            copy.* = try ai.message.copyUserContentLeaky(allocator, part.user);
        }
        return .{ .parts = parts };
    }

    fn copyToolResultsLeaky(
        allocator: std.mem.Allocator,
        request: ai.message.RequestMessage,
    ) error{OutOfMemory}!ToolResults {
        const results = try allocator.alloc(ai.message.ToolResult, request.parts.len);
        for (request.parts, results) |part, *copy| {
            copy.* = try ai.message.copyToolResultLeaky(allocator, part.tool_result);
        }
        return .{ .results = results };
    }

    fn copyMetadataLeaky(
        allocator: std.mem.Allocator,
        base: session_format.EntryBase,
    ) error{OutOfMemory}!Metadata {
        return .{ .durable = .{
            .entry_id = try allocator.dupe(u8, base.id),
            .timestamp = try allocator.dupe(u8, base.timestamp),
        } };
    }

    fn restoredView(
        entries: []const session_format.Entry,
        active_leaf_id: ?[]const u8,
        recovery: session_format.Recovery,
    ) session_format.Restored {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        const memory = arena.allocator();
        const active_entries = activeBranchOf(memory, entries, active_leaf_id);
        return .{
            .arena = arena,
            .header = .{ .id = "session", .timestamp = "time", .cwd = "/tmp" },
            .entries = entries,
            .active_leaf_id = active_leaf_id,
            .active_entries = active_entries,
            .active_model = null,
            .active_thinking_level = null,
            .context_messages = &.{},
            .recovery = recovery,
        };
    }

    /// Test-only mirror of SessionFormat's active-branch projection: walks the
    /// leaf chain so restored fixtures carry the production `active_entries`.
    fn activeBranchOf(
        allocator: std.mem.Allocator,
        entries: []const session_format.Entry,
        active_leaf_id: ?[]const u8,
    ) []const session_format.Entry {
        if (active_leaf_id == null) return &.{};
        var chain: std.ArrayList(session_format.Entry) = .empty;
        defer chain.deinit(allocator);
        var current = active_leaf_id;
        while (current) |id| {
            var found: ?session_format.Entry = null;
            for (entries) |entry| {
                if (std.mem.eql(u8, entry.base().id, id)) {
                    found = entry;
                    break;
                }
            }
            const entry = found orelse break;
            chain.append(allocator, entry) catch return &.{};
            current = entry.base().parent_id;
        }
        const result = allocator.alloc(session_format.Entry, chain.items.len) catch return &.{};
        for (chain.items, 0..) |entry, index| result[chain.items.len - 1 - index] = entry;
        return result;
    }

    test "transcript projects only the restored active branch" {
        const entries = [_]session_format.Entry{
            .{ .model_change = .{
                .base = .{ .id = "model", .parent_id = null, .timestamp = "t0" },
                .selection = .{ .provider = "script", .model = "model-a" },
            } },
            .{ .message = .{
                .base = .{ .id = "main-user", .parent_id = "model", .timestamp = "t1" },
                .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "main" } }} } },
            } },
            .{ .turn_end = .{
                .base = .{ .id = "main-end", .parent_id = "main-user", .timestamp = "t2" },
                .turn_id = "main-user",
                .outcome = .cancelled,
            } },
            .{ .message = .{
                .base = .{ .id = "branch-user", .parent_id = "model", .timestamp = "t3" },
                .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "branch" } }} } },
            } },
            .{ .turn_end = .{
                .base = .{ .id = "branch-end", .parent_id = "branch-user", .timestamp = "t4" },
                .turn_id = "branch-user",
                .outcome = .{ .failed = .connection_failed },
            } },
        };
        var restored = restoredView(&entries, "branch-end", .clean);
        defer restored.deinit();
        var transcript = try Transcript.init(std.testing.allocator, &restored);
        defer transcript.deinit();

        try std.testing.expectEqual(@as(usize, 3), transcript.items.len);
        try std.testing.expect(transcript.items[0].content == .model_change);
        try std.testing.expectEqualStrings(
            "branch",
            transcript.items[1].content.user.parts[0].text,
        );
        try std.testing.expect(transcript.items[2].content == .failure);
        try std.testing.expectEqual(
            session_format.FailureCategory.connection_failed,
            transcript.items[2].content.failure.category,
        );
    }

    test "transcript retains assistant and tool facts after source mutation" {
        var user_text = [_]u8{ 'f', 'i', 'x' };
        var assistant_text = [_]u8{ 'd', 'o', 'n', 'e' };
        var tool_text = [_]u8{ 'o', 'k' };
        const entries = [_]session_format.Entry{
            .{ .message = .{
                .base = .{ .id = "user", .parent_id = null, .timestamp = "t0" },
                .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = &user_text } }} } },
            } },
            .{ .message = .{
                .base = .{ .id = "tool-call", .parent_id = "user", .timestamp = "t1" },
                .message = .{ .response = .{
                    .parts = &.{.{ .tool_call = .{
                        .id = "call",
                        .name = "read",
                        .arguments_json = "{}",
                    } }},
                    .identity = .{ .provider = "script", .model = "model" },
                } },
            } },
            .{ .message = .{
                .base = .{ .id = "tool-result", .parent_id = "tool-call", .timestamp = "t2" },
                .message = .{ .request = .{ .parts = &.{.{ .tool_result = .{
                    .call_id = "call",
                    .name = "read",
                    .content = &.{.{ .text = &tool_text }},
                    .outcome = .success,
                } }} } },
            } },
            .{ .message = .{
                .base = .{ .id = "assistant", .parent_id = "tool-result", .timestamp = "t3" },
                .message = .{ .response = .{
                    .parts = &.{.{ .text = .{ .text = &assistant_text } }},
                    .identity = .{ .provider = "script", .model = "model" },
                } },
            } },
            .{ .turn_end = .{
                .base = .{ .id = "end", .parent_id = "assistant", .timestamp = "t4" },
                .turn_id = "user",
                .outcome = .completed,
            } },
        };
        var restored = restoredView(&entries, "end", .clean);
        defer restored.deinit();
        var transcript = try Transcript.init(std.testing.allocator, &restored);
        defer transcript.deinit();
        @memset(&user_text, 'x');
        @memset(&assistant_text, 'x');
        @memset(&tool_text, 'x');

        try std.testing.expectEqual(@as(usize, 4), transcript.items.len);
        try std.testing.expectEqualStrings("fix", transcript.items[0].content.user.parts[0].text);
        try std.testing.expect(transcript.items[1].content == .assistant);
        try std.testing.expectEqualStrings(
            "ok",
            transcript.items[2].content.tool_results.results[0].content[0].text,
        );
        try std.testing.expectEqualStrings(
            "done",
            transcript.items[3].content.assistant.parts[0].text.text,
        );
    }

    test "transcript preserves durable cancellation and interruption terminals" {
        const cases = [_]struct {
            outcome: session_format.TurnOutcome,
            expected: std.meta.Tag(Content),
        }{
            .{ .outcome = .cancelled, .expected = .cancelled },
            .{ .outcome = .interrupted, .expected = .interrupted },
        };
        for (cases) |case| {
            const entries = [_]session_format.Entry{
                .{ .message = .{
                    .base = .{ .id = "turn", .parent_id = null, .timestamp = "t0" },
                    .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "prompt" } }} } },
                } },
                .{ .turn_end = .{
                    .base = .{ .id = "end", .parent_id = "turn", .timestamp = "t1" },
                    .turn_id = "turn",
                    .outcome = case.outcome,
                } },
            };
            var restored = restoredView(&entries, "end", .clean);
            defer restored.deinit();
            var transcript = try Transcript.init(std.testing.allocator, &restored);
            defer transcript.deinit();

            try std.testing.expectEqual(@as(usize, 2), transcript.items.len);
            try std.testing.expectEqual(case.expected, std.meta.activeTag(transcript.items[1].content));
            try std.testing.expect(transcript.items[1].metadata == .durable);
        }
    }

    test "transcript marks a recovered open turn as synthetic interruption" {
        const entries = [_]session_format.Entry{.{ .message = .{
            .base = .{ .id = "open-turn", .parent_id = null, .timestamp = "t0" },
            .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "unfinished" } }} } },
        } }};
        var restored = restoredView(
            &entries,
            "open-turn",
            .{ .interrupted = .{ .turn_id = "open-turn" } },
        );
        defer restored.deinit();
        var transcript = try Transcript.init(std.testing.allocator, &restored);
        defer transcript.deinit();

        try std.testing.expectEqual(@as(usize, 2), transcript.items.len);
        const interruption = transcript.items[1];
        try std.testing.expect(interruption.content == .interrupted);
        try std.testing.expect(interruption.metadata == .recovered_open_turn);
        try std.testing.expectEqualStrings("open-turn", interruption.content.interrupted.turn_id);
    }

    fn projectForAllocationFailure(allocator: std.mem.Allocator) !void {
        const entries = [_]session_format.Entry{
            .{ .model_change = .{
                .base = .{ .id = "model", .parent_id = null, .timestamp = "t0" },
                .selection = .{ .provider = "script", .model = "allocation" },
            } },
            .{ .message = .{
                .base = .{ .id = "user", .parent_id = "model", .timestamp = "t1" },
                .message = .{ .request = .{ .parts = &.{.{ .user = .{ .text = "prompt" } }} } },
            } },
            .{ .message = .{
                .base = .{ .id = "assistant", .parent_id = "user", .timestamp = "t2" },
                .message = .{ .response = .{
                    .parts = &.{.{ .text = .{
                        .text = "answer",
                        .provider_state = .{
                            .provider = "script",
                            .protocol = "test",
                            .value = .{ .string = "opaque" },
                        },
                    } }},
                    .identity = .{ .provider = "script", .model = "allocation" },
                } },
            } },
        };
        var restored = restoredView(
            &entries,
            "assistant",
            .{ .interrupted = .{ .turn_id = "user" } },
        );
        defer restored.deinit();
        var transcript = try Transcript.init(allocator, &restored);
        transcript.deinit();
    }

    test "transcript settles every allocation failure" {
        try std.testing.checkAllAllocationFailures(
            std.testing.allocator,
            projectForAllocationFailure,
            .{},
        );
    }

    test "transcript rejects missing leaves and mixed request roles" {
        const mixed = [_]session_format.Entry{.{ .message = .{
            .base = .{ .id = "mixed", .parent_id = null, .timestamp = "t0" },
            .message = .{ .request = .{ .parts = &.{
                .{ .user = .{ .text = "question" } },
                .{ .tool_result = .{
                    .call_id = "call",
                    .name = "read",
                    .content = &.{.{ .text = "result" }},
                    .outcome = .success,
                } },
            } } },
        } }};
        var missing = restoredView(&.{}, "missing", .clean);
        defer missing.deinit();
        try std.testing.expectError(
            error.InvalidTranscript,
            Transcript.init(std.testing.allocator, &missing),
        );
        var invalid = restoredView(&mixed, "mixed", .clean);
        defer invalid.deinit();
        try std.testing.expectError(
            error.InvalidTranscript,
            Transcript.init(std.testing.allocator, &invalid),
        );
    }
};
