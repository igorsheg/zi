//! Heap-stable advisory transcript owner.

const std = @import("std");
const Renderer = @import("Renderer.zig");
const SecureOpen = @import("SecureOpen.zig");
const ai = @import("../ai/root.zig");
const tool = @import("../tool/root.zig");

pub const default_max_file_bytes: usize = Renderer.default_max_file_bytes;
pub const default_max_segment_bytes: usize = Renderer.default_max_segment_bytes;
pub const default_max_path_bytes: usize = 4096;
pub const default_max_items: usize = Renderer.default_max_items;
pub const default_max_tools: usize = tool.Dispatch.default_maximum_tools;

pub const View = Renderer.View;

pub const Limits = struct {
    max_file_bytes: usize = default_max_file_bytes,
    max_segment_bytes: usize = default_max_segment_bytes,
    max_path_bytes: usize = default_max_path_bytes,
    max_items: usize = default_max_items,
    max_tools: usize = default_max_tools,

    fn renderer(self: Limits) Renderer.Limits {
        return .{
            .max_file_bytes = self.max_file_bytes,
            .max_segment_bytes = self.max_segment_bytes,
            .max_items = self.max_items,
            .max_tools = self.max_tools,
        };
    }

    fn valid(self: Limits) bool {
        return self.max_file_bytes != 0 and self.max_file_bytes <= default_max_file_bytes and
            self.max_segment_bytes != 0 and self.max_segment_bytes <= default_max_segment_bytes and
            self.max_path_bytes != 0 and self.max_path_bytes <= default_max_path_bytes and
            self.max_items != 0 and self.max_items <= default_max_items and
            self.max_tools != 0 and self.max_tools <= default_max_tools;
    }
};

pub const Operation = enum {
    open,
    append,
    selection,
    new,
    resume_conversation,
    undo,
    fork,
};

pub const Failure = enum {
    bounds,
    out_of_memory,
    open_failed,
    lock_contended,
    content_unknown,
    write_failed,
    verification_failed,
    identity_lost,
};

pub const Progress = struct {
    cursor: Renderer.Cursor,
    file_bytes: usize,
};

pub const Status = union(enum) {
    disabled,
    clean: Progress,
    degraded_attached: Failure,
    degraded_detached: Failure,
};

pub const Outcome = union(enum) {
    disabled,
    unchanged,
    appended: Progress,
    rebuilt: Progress,
    degraded: Failure,
};

pub const Warning = struct {
    path: []const u8,
    operation: Operation,
    failure: Failure,
    sequence: u64,
};

pub const Owner = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    secure_open: SecureOpen.Capability,
    limits: Limits,
    path_value: ?[]u8,
    attachment: ?SecureOpen.Opened = null,
    expected: ?SecureOpen.Snapshot = null,
    status_value: Status,
    warning_value: ?Warning = null,
    last_warning_failure: ?Failure = null,
    warning_sequence: u64 = 0,
    active: bool = false,

    pub fn create(
        allocator: std.mem.Allocator,
        io: std.Io,
        secure_open: SecureOpen.Capability,
        path: ?[]const u8,
        limits: Limits,
    ) error{OutOfMemory}!*Owner {
        const configured = path orelse "";
        const path_too_long = configured.len > limits.max_path_bytes or
            configured.len > default_max_path_bytes;
        const retained_path = if (path_too_long)
            "<transcript path exceeds limit>"
        else
            configured;
        const path_copy = if (configured.len == 0)
            null
        else
            allocator.dupe(u8, retained_path) catch return error.OutOfMemory;
        errdefer if (path_copy) |value| allocator.free(value);
        const self = allocator.create(Owner) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .io = io,
            .secure_open = secure_open,
            .limits = limits,
            .path_value = path_copy,
            .status_value = if (path_copy == null) .disabled else .{ .degraded_detached = .open_failed },
        };
        if (path_copy == null) return self;
        if (!limits.valid() or path_too_long) {
            self.degrade(.open, .bounds, false);
            return self;
        }
        try self.attachFresh(.open);
        return self;
    }

    pub fn status(self: *const Owner) Status {
        return self.status_value;
    }

    pub fn activePath(self: *const Owner) ?[]const u8 {
        return self.path_value;
    }

    pub fn append(self: *Owner, view: View) Outcome {
        self.enter();
        defer self.leave();
        return switch (self.status_value) {
            .disabled => .disabled,
            .degraded_attached, .degraded_detached => .unchanged,
            .clean => |progress| self.appendClean(view, progress),
        };
    }

    pub fn rebuild(self: *Owner, operation: Operation, view: View) Outcome {
        self.enter();
        defer self.leave();
        if (self.status_value == .disabled) return .disabled;

        const intended_size = Renderer.preflightAll(self.allocator, view, self.limits.renderer()) catch |err| {
            const failure = rendererFailure(err);
            self.degrade(operation, failure, self.attachment != null);
            return .{ .degraded = failure };
        };
        if (self.attachment == null) {
            self.attachFresh(operation) catch {
                self.degrade(operation, .out_of_memory, false);
            };
            if (self.attachment == null) return .{ .degraded = self.currentFailure() };
        }
        const opened = self.attachment.?;
        self.validateAttached(false) catch {
            self.detach(operation, .identity_lost);
            return .{ .degraded = .identity_lost };
        };
        opened.setLength(self.io, 0) catch {
            return self.failAfterMutation(operation, .write_failed);
        };

        var cursor: Renderer.Cursor = .{};
        var destination: PositionalWriter = .init(self.io, opened, 0);
        Renderer.renderAll(
            self.allocator,
            &destination.writer,
            view,
            &cursor,
            self.limits.renderer(),
        ) catch |err| {
            const failure: Failure = if (err == error.OutOfMemory) .out_of_memory else .write_failed;
            return self.failAfterMutation(operation, failure);
        };
        if (destination.offset != intended_size) {
            return self.failAfterMutation(operation, .verification_failed);
        }
        const final = self.verifyFinal(intended_size) catch {
            return self.failAfterMutation(operation, .verification_failed);
        };
        const progress: Progress = .{ .cursor = cursor, .file_bytes = intended_size };
        self.publishClean(progress, final);
        return .{ .rebuilt = progress };
    }

    /// Borrowed until `ackWarning` or `deinit`; owner mutation does not invalidate it.
    pub fn pendingWarning(self: *const Owner) ?Warning {
        return self.warning_value;
    }

    pub fn ackWarning(self: *Owner) void {
        self.warning_value = null;
    }

    pub fn deinit(self: *Owner) void { // ziglint-ignore: Z030
        std.debug.assert(!self.active);
        if (self.attachment) |opened| opened.close(self.allocator, self.io);
        if (self.path_value) |value| self.allocator.free(value);
        const allocator = self.allocator;
        self.* = undefined;
        allocator.destroy(self);
    }

    fn appendClean(self: *Owner, view: View, progress: Progress) Outcome {
        const first_segment = progress.file_bytes == 0 and progress.cursor.item_high_water == 0 and
            progress.cursor.turn_number == 0;
        const remaining = self.limits.max_file_bytes -| progress.file_bytes;
        const intended = (if (first_segment)
            Renderer.preflightAll(self.allocator, view, self.limits.renderer())
        else
            Renderer.preflightSuffix(
                self.allocator,
                view,
                progress.cursor,
                remaining,
                self.limits.renderer(),
            )) catch |err| {
            const failure = rendererFailure(err);
            self.degrade(.append, failure, true);
            return .{ .degraded = failure };
        };
        if (intended == 0) return .unchanged;
        self.validateAttached(true) catch {
            self.detach(.append, .identity_lost);
            return .{ .degraded = .identity_lost };
        };

        var cursor = progress.cursor;
        var destination: PositionalWriter = .init(self.io, self.attachment.?, progress.file_bytes);
        if (first_segment)
            Renderer.renderAll(
                self.allocator,
                &destination.writer,
                view,
                &cursor,
                self.limits.renderer(),
            ) catch |err| {
                const failure: Failure = if (err == error.OutOfMemory) .out_of_memory else .write_failed;
                return self.failAfterMutation(.append, failure);
            }
        else
            Renderer.renderSuffix(
                self.allocator,
                &destination.writer,
                view,
                &cursor,
                self.limits.renderer(),
            ) catch |err| {
                const failure: Failure = if (err == error.OutOfMemory) .out_of_memory else .write_failed;
                return self.failAfterMutation(.append, failure);
            };
        const final_size = std.math.add(usize, progress.file_bytes, intended) catch {
            return self.failAfterMutation(.append, .verification_failed);
        };
        if (destination.offset != final_size) {
            return self.failAfterMutation(.append, .verification_failed);
        }
        const final = self.verifyFinal(final_size) catch {
            return self.failAfterMutation(.append, .verification_failed);
        };
        const next: Progress = .{ .cursor = cursor, .file_bytes = final_size };
        self.publishClean(next, final);
        return .{ .appended = next };
    }

    fn attachFresh(self: *Owner, operation: Operation) error{OutOfMemory}!void {
        const opened = self.secure_open.open(
            self.allocator,
            self.io,
            self.path_value.?,
        ) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            self.degrade(operation, .open_failed, false);
            return;
        };
        var keep = false;
        defer if (!keep) opened.close(self.allocator, self.io);
        const locked = opened.tryLock(self.io) catch {
            self.degrade(operation, .open_failed, false);
            return;
        };
        if (!locked) {
            self.degrade(operation, .lock_contended, false);
            return;
        }
        opened.setPermissions(self.io) catch {
            self.degrade(operation, .open_failed, false);
            return;
        };
        const opened_stat = opened.statOpened(self.io) catch {
            self.degrade(operation, .open_failed, false);
            return;
        };
        const named = opened.statNamed(self.io) catch {
            self.degrade(operation, .identity_lost, false);
            return;
        };
        if (!usable(opened_stat) or !opened_stat.sameIdentity(named)) {
            self.degrade(operation, .identity_lost, false);
            return;
        }
        keep = true;
        self.attachment = opened;
        self.expected = opened_stat;
        if (opened_stat.token.size == 0) {
            self.publishClean(.{ .cursor = .{}, .file_bytes = 0 }, opened_stat);
        } else {
            self.degrade(operation, .content_unknown, true);
        }
    }

    fn validateAttached(self: *Owner, require_token: bool) SecureOpen.Error!void {
        const opened = self.attachment orelse return error.IdentityChanged;
        const actual = try opened.statOpened(self.io);
        const named = try opened.statNamed(self.io);
        if (!usable(actual) or !actual.sameIdentity(named)) return error.IdentityChanged;
        if (require_token and !actual.sameToken(self.expected.?)) return error.IdentityChanged;
    }

    fn verifyFinal(self: *Owner, expected_size: usize) SecureOpen.Error!SecureOpen.Snapshot {
        const opened = self.attachment orelse return error.IdentityChanged;
        const actual = try opened.statOpened(self.io);
        const named = try opened.statNamed(self.io);
        if (!usable(actual) or !actual.sameIdentity(named) or actual.token.size != expected_size) {
            return error.IdentityChanged;
        }
        return actual;
    }

    fn failAfterMutation(self: *Owner, operation: Operation, failure: Failure) Outcome {
        const opened = self.attachment orelse {
            self.degrade(operation, .identity_lost, false);
            return .{ .degraded = .identity_lost };
        };
        const actual = opened.statOpened(self.io) catch {
            self.detach(operation, .identity_lost);
            return .{ .degraded = .identity_lost };
        };
        const named = opened.statNamed(self.io) catch {
            self.detach(operation, .identity_lost);
            return .{ .degraded = .identity_lost };
        };
        if (!usable(actual) or !actual.sameIdentity(named)) {
            self.detach(operation, .identity_lost);
            return .{ .degraded = .identity_lost };
        }
        self.expected = actual;
        self.degrade(operation, failure, true);
        return .{ .degraded = failure };
    }

    fn detach(self: *Owner, operation: Operation, failure: Failure) void {
        if (self.attachment) |opened| opened.close(self.allocator, self.io);
        self.attachment = null;
        self.expected = null;
        self.degrade(operation, failure, false);
    }

    fn publishClean(self: *Owner, progress: Progress, snapshot: SecureOpen.Snapshot) void {
        self.expected = snapshot;
        self.status_value = .{ .clean = progress };
        self.last_warning_failure = null;
    }

    fn degrade(self: *Owner, operation: Operation, failure: Failure, attached: bool) void {
        self.status_value = if (attached)
            .{ .degraded_attached = failure }
        else
            .{ .degraded_detached = failure };
        self.recordWarning(operation, failure);
    }

    fn recordWarning(self: *Owner, operation: Operation, failure: Failure) void {
        if (self.warning_value) |pending| {
            if (pending.failure == failure or severity(failure) <= severity(pending.failure)) return;
        } else if (self.last_warning_failure == failure) return;
        self.warning_sequence +|= 1;
        const warning: Warning = .{
            .path = self.path_value.?,
            .operation = operation,
            .failure = failure,
            .sequence = self.warning_sequence,
        };
        self.warning_value = warning;
        self.last_warning_failure = failure;
    }

    fn currentFailure(self: *const Owner) Failure {
        return switch (self.status_value) {
            .degraded_attached, .degraded_detached => |value| value,
            else => unreachable,
        };
    }

    fn enter(self: *Owner) void {
        std.debug.assert(!self.active);
        self.active = true;
    }

    fn leave(self: *Owner) void {
        std.debug.assert(self.active);
        self.active = false;
    }
};

fn usable(snapshot: SecureOpen.Snapshot) bool {
    return snapshot.regular and snapshot.nlink == 1 and snapshot.token.mode & 0o777 == 0o600;
}

fn rendererFailure(err: anyerror) Failure {
    return if (err == error.OutOfMemory) .out_of_memory else .bounds;
}

fn severity(failure: Failure) u2 {
    return switch (failure) {
        .bounds => 0,
        .out_of_memory, .content_unknown => 1,
        .write_failed, .verification_failed => 2,
        .open_failed, .lock_contended, .identity_lost => 3,
    };
}

const PositionalWriter = struct {
    io: std.Io,
    opened: SecureOpen.Opened,
    offset: u64,
    writer: std.Io.Writer,

    fn init(io: std.Io, opened: SecureOpen.Opened, offset: u64) PositionalWriter {
        return .{
            .io = io,
            .opened = opened,
            .offset = offset,
            .writer = .{ .vtable = &.{ .drain = drain }, .buffer = &.{} },
        };
    }

    fn drain(writer: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        const self: *PositionalWriter = @alignCast(@fieldParentPtr("writer", writer));
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            self.opened.writeAll(self.io, bytes, self.offset) catch return error.WriteFailed;
            self.offset += bytes.len;
            written += bytes.len;
        }
        const repeated = data[data.len - 1];
        for (0..splat) |_| {
            self.opened.writeAll(self.io, repeated, self.offset) catch return error.WriteFailed;
            self.offset += repeated.len;
            written += repeated.len;
        }
        return written;
    }
};

const FakeFile = struct {
    bytes: std.ArrayList(u8) = .empty,
    inode: std.Io.File.INode = 7,
    mode: std.posix.mode_t = 0o600,
    nlink: std.Io.File.NLink = 1,
    generation: i96 = 1,
    locked: bool = false,
    contend: bool = false,
    fail_write_after: ?usize = null,
    replace_named: bool = false,

    fn snapshot(self: *FakeFile, named: bool) SecureOpen.Snapshot {
        return .{
            .identity = .{ .device = 1, .inode = self.inode + @intFromBool(named and self.replace_named) },
            .token = .{
                .size = self.bytes.items.len,
                .mode = self.mode,
                .mtime_ns = self.generation,
                .ctime_ns = self.generation,
            },
            .nlink = self.nlink,
            .regular = true,
        };
    }
};

const FakeOpen = struct {
    owner: *FakeCapability,

    pub fn close(self: *FakeOpen, allocator: std.mem.Allocator, _: std.Io) void {
        self.owner.file.locked = false;
        allocator.destroy(self);
    }
    pub fn tryLock(self: *FakeOpen, _: std.Io) SecureOpen.Error!bool {
        if (self.owner.file.contend or self.owner.file.locked) return false;
        self.owner.file.locked = true;
        return true;
    }
    pub fn statOpened(self: *FakeOpen, _: std.Io) SecureOpen.Error!SecureOpen.Snapshot {
        return self.owner.file.snapshot(false);
    }
    pub fn statNamed(self: *FakeOpen, _: std.Io) SecureOpen.Error!SecureOpen.Snapshot {
        return self.owner.file.snapshot(true);
    }
    pub fn setPermissions(self: *FakeOpen, _: std.Io) SecureOpen.Error!void {
        self.owner.file.mode = 0o600;
        self.owner.file.generation += 1;
    }
    pub fn setLength(self: *FakeOpen, _: std.Io, length: u64) SecureOpen.Error!void {
        const size: usize = @intCast(length);
        try self.owner.file.bytes.resize(self.owner.allocator, size);
        self.owner.file.generation += 1;
    }
    pub fn writeAll(self: *FakeOpen, _: std.Io, bytes: []const u8, offset: u64) SecureOpen.Error!void {
        const start: usize = @intCast(offset);
        const amount = if (self.owner.file.fail_write_after) |limit| @min(limit, bytes.len) else bytes.len;
        const needed = start + amount;
        self.owner.file.bytes.resize(self.owner.allocator, needed) catch return error.OutOfMemory;
        @memcpy(self.owner.file.bytes.items[start..needed], bytes[0..amount]);
        self.owner.file.generation += 1;
        if (amount != bytes.len) return error.IoFailure;
    }
};

const FakeCapability = struct {
    allocator: std.mem.Allocator,
    file: FakeFile = .{},
    open_error: ?SecureOpen.Error = null,

    fn capability(self: *FakeCapability) SecureOpen.Capability {
        return .from(self);
    }
    pub fn open(
        self: *FakeCapability,
        allocator: std.mem.Allocator,
        _: std.Io,
        _: []const u8,
    ) SecureOpen.Error!SecureOpen.Opened {
        if (self.open_error) |err| return err;
        const opened = allocator.create(FakeOpen) catch return error.OutOfMemory;
        opened.* = .{ .owner = self };
        return .from(opened);
    }
    fn deinit(self: *FakeCapability) void {
        self.file.bytes.deinit(self.allocator);
        self.* = undefined;
    }
};

fn testView(items: []const ai.Item.Item) View {
    return .{ .system_prompt = "system", .tools = &.{}, .items = items };
}

fn mutable(bytes: []const u8) []u8 {
    return @constCast(bytes);
}

test "disabled owner allocates stably and performs no open" {
    var fake: FakeCapability = .{ .allocator = std.testing.allocator, .open_error = error.IoFailure };
    defer fake.deinit();
    const owner = try Owner.create(std.testing.allocator, std.testing.io, fake.capability(), null, .{});
    defer owner.deinit();
    try std.testing.expect(owner.status() == .disabled);
    try std.testing.expect(owner.append(testView(&.{})) == .disabled);
}

test "append, partial write degradation, and rebuild recovery" {
    var fake: FakeCapability = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const owner = try Owner.create(std.testing.allocator, std.testing.io, fake.capability(), "transcript", .{});
    defer owner.deinit();
    const first = [_]ai.Item.Item{.{ .assistant_message = .{ .text = mutable("one") } }};
    try std.testing.expect(owner.append(testView(&first)) == .appended);
    const before = fake.file.bytes.items.len;
    fake.file.fail_write_after = 3;
    const second = [_]ai.Item.Item{
        first[0],
        .{ .assistant_message = .{ .text = mutable("two") } },
    };
    try std.testing.expectEqual(Failure.write_failed, owner.append(testView(&second)).degraded);
    try std.testing.expect(fake.file.bytes.items.len > before);
    try std.testing.expect(owner.status() == .degraded_attached);
    fake.file.fail_write_after = null;
    try std.testing.expect(owner.rebuild(.selection, testView(&second)) == .rebuilt);
    try std.testing.expect(owner.status() == .clean);
}

test "detached rebuild respects lock contention and does not mutate target" {
    var fake: FakeCapability = .{ .allocator = std.testing.allocator, .open_error = error.IoFailure };
    defer fake.deinit();
    const owner = try Owner.create(std.testing.allocator, std.testing.io, fake.capability(), "transcript", .{});
    defer owner.deinit();
    fake.open_error = null;
    fake.file.contend = true;
    try std.testing.expectEqual(Failure.lock_contended, owner.rebuild(.resume_conversation, testView(&.{})).degraded);
    try std.testing.expectEqual(@as(usize, 0), fake.file.bytes.items.len);
}

test "identity loss detaches and closes the lifetime lock" {
    var fake: FakeCapability = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const owner = try Owner.create(std.testing.allocator, std.testing.io, fake.capability(), "transcript", .{});
    defer owner.deinit();
    fake.file.replace_named = true;
    const item = [_]ai.Item.Item{
        .{ .assistant_message = .{ .text = mutable("one") } },
    };
    try std.testing.expectEqual(Failure.identity_lost, owner.append(testView(&item)).degraded);
    try std.testing.expect(owner.status() == .degraded_detached);
    try std.testing.expect(!fake.file.locked);
}

test "bounds refusal is preflight-only and warning severity coalesces" {
    var fake: FakeCapability = .{ .allocator = std.testing.allocator };
    defer fake.deinit();
    const owner = try Owner.create(std.testing.allocator, std.testing.io, fake.capability(), "transcript", .{
        .max_file_bytes = 64,
        .max_segment_bytes = 64,
    });
    defer owner.deinit();
    const item = [_]ai.Item.Item{
        .{ .assistant_message = .{ .text = mutable("body larger than the transcript bound") } },
    };
    try std.testing.expectEqual(Failure.bounds, owner.append(testView(&item)).degraded);
    const first_warning = owner.pendingWarning().?;
    try std.testing.expectEqual(Failure.bounds, first_warning.failure);
    owner.degrade(.append, .write_failed, true);
    const severe = owner.pendingWarning().?;
    try std.testing.expectEqual(Failure.write_failed, severe.failure);
    try std.testing.expect(severe.sequence > first_warning.sequence);
    owner.degrade(.append, .bounds, true);
    try std.testing.expectEqual(severe.sequence, owner.pendingWarning().?.sequence);
}

test "overlong configured path retains only a bounded diagnostic" {
    var configured: [8192]u8 = undefined;
    @memset(&configured, 'x');
    var storage: [1024]u8 = undefined;
    var fixed: std.heap.FixedBufferAllocator = .init(&storage);
    var fake: FakeCapability = .{ .allocator = fixed.allocator() };
    defer fake.deinit();
    const owner = try Owner.create(
        fixed.allocator(),
        std.testing.io,
        fake.capability(),
        &configured,
        .{ .max_path_bytes = 8 },
    );
    defer owner.deinit();
    try std.testing.expectEqualStrings("<transcript path exceeds limit>", owner.activePath().?);
    try std.testing.expectEqual(Failure.bounds, owner.pendingWarning().?.failure);
}

fn exerciseOwnerCreateAllocationFailures(allocator: std.mem.Allocator) !void {
    var fake: FakeCapability = .{ .allocator = allocator };
    defer fake.deinit();
    const owner = try Owner.create(allocator, std.testing.io, fake.capability(), "transcript", .{});
    owner.deinit();
}

test "owner frees create allocations on every failure" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        exerciseOwnerCreateAllocationFailures,
        .{},
    );
}

test "rebuild consumes allocation failure as attached degradation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 3 });
    const allocator = failing.allocator();
    var fake: FakeCapability = .{ .allocator = allocator };
    defer fake.deinit();
    const owner = try Owner.create(allocator, std.testing.io, fake.capability(), "transcript", .{});
    defer owner.deinit();
    const item = [_]ai.Item.Item{
        .{ .assistant_message = .{ .text = mutable("allocation test") } },
    };
    try std.testing.expectEqual(Failure.out_of_memory, owner.rebuild(.selection, testView(&item)).degraded);
    try std.testing.expect(failing.has_induced_failure);
}
