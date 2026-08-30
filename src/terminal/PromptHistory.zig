const std = @import("std");
const PromptHistory = @This();

pub const maximum_entries: usize = 1000;
pub const maximum_entry_bytes: usize = 1024 * 1024;

pub const Admission = enum { session, persistent };
pub const AppendOutcome = enum { written, too_large, unavailable };

/// Borrowed synchronous persistence seam. The implementation and entry bytes must
/// remain valid only for the duration of `append`.
pub const Appender = struct {
    context: *anyopaque,
    append_fn: *const fn (
        std.mem.Allocator,
        *anyopaque,
        []const u8,
    ) error{OutOfMemory}!AppendOutcome,

    pub fn append(
        self: Appender,
        allocator: std.mem.Allocator,
        entry_bytes: []const u8,
    ) error{OutOfMemory}!AppendOutcome {
        return self.append_fn(allocator, self.context, entry_bytes);
    }

    pub fn from(implementation: anytype) Appender {
        const Pointer = @TypeOf(implementation);
        const pointer_info = @typeInfo(Pointer);
        if (pointer_info != .pointer or pointer_info.pointer.size != .one or
            pointer_info.pointer.is_const)
        {
            @compileError("Appender.from expects a mutable single-item pointer");
        }
        const Implementation = pointer_info.pointer.child;
        const Adapter = struct {
            fn append(
                allocator: std.mem.Allocator,
                context: *anyopaque,
                entry_bytes: []const u8,
            ) error{OutOfMemory}!AppendOutcome {
                const self: *Implementation = @ptrCast(@alignCast(context));
                return self.append(allocator, entry_bytes);
            }
        };
        return .{ .context = implementation, .append_fn = Adapter.append };
    }
};

allocator: std.mem.Allocator,
entries: std.ArrayList([]u8) = .empty,
position: usize = 0,
draft: ?[]u8 = null,
newest_unpersisted: bool = false,
appender: ?Appender = null,

pub fn init(allocator: std.mem.Allocator) PromptHistory {
    return .{ .allocator = allocator };
}

pub fn deinit(self: *PromptHistory) void {
    for (self.entries.items) |owned_entry| self.allocator.free(owned_entry);
    self.entries.deinit(self.allocator);
    if (self.draft) |owned_draft| self.allocator.free(owned_draft);
    self.* = undefined;
}

pub fn setAppender(self: *PromptHistory, appender: ?Appender) void {
    self.appender = appender;
}

pub fn beginRead(self: *PromptHistory) void {
    if (self.draft) |owned_draft| self.allocator.free(owned_draft);
    self.draft = null;
    self.position = self.entries.items.len;
}

/// Copies a decoded persistent entry. This never invokes the appender.
pub fn seed(self: *PromptHistory, entry_bytes: []const u8) error{OutOfMemory}!void {
    var prepared = try self.prepareAdmission(entry_bytes, .persistent);
    defer prepared.deinit(self.allocator);
    self.commitAdmission(&prepared, .persistent);
}

/// Copies and admits an entry. Persistent append failures other than allocation
/// failure are best-effort and do not prevent in-memory admission.
pub fn admit(
    self: *PromptHistory,
    entry_bytes: []const u8,
    admission: Admission,
) error{OutOfMemory}!void {
    var prepared = try self.prepareAdmission(entry_bytes, admission);
    defer prepared.deinit(self.allocator);

    if (admission == .persistent and prepared != .noop) {
        if (self.appender) |appender| {
            _ = try appender.append(self.allocator, prepared.entry(self));
        }
    }
    self.commitAdmission(&prepared, admission);
}

pub fn count(self: *const PromptHistory) usize {
    return self.entries.items.len;
}

/// The returned entry is borrowed until the next history mutation or `deinit`.
pub fn entry(self: *const PromptHistory, index: usize) ?[]const u8 {
    if (index >= self.entries.items.len) return null;
    return self.entries.items[index];
}

pub fn currentPosition(self: *const PromptHistory) usize {
    return self.position;
}

const PreparedAdmission = union(enum) {
    noop,
    promote_newest,
    replace: struct {
        owned_entry: []u8,
        duplicate_index: ?usize,
        evict_oldest: bool,
    },

    fn entry(prepared: *const PreparedAdmission, history: *const PromptHistory) []const u8 {
        return switch (prepared.*) {
            .noop => "",
            .promote_newest => history.entries.items[history.entries.items.len - 1],
            .replace => |replacement| replacement.owned_entry,
        };
    }

    fn deinit(prepared: *PreparedAdmission, allocator: std.mem.Allocator) void {
        switch (prepared.*) {
            .replace => |replacement| allocator.free(replacement.owned_entry),
            else => {},
        }
        prepared.* = undefined;
    }
};

fn prepareAdmission(
    self: *PromptHistory,
    entry_bytes: []const u8,
    admission: Admission,
) error{OutOfMemory}!PreparedAdmission {
    if (entry_bytes.len == 0 or entry_bytes.len > maximum_entry_bytes) return .noop;

    const duplicate_index = self.findExact(entry_bytes);
    if (duplicate_index) |index| {
        if (index + 1 == self.entries.items.len) {
            if (admission == .persistent and self.newest_unpersisted) return .promote_newest;
            return .noop;
        }
    }

    const owned_entry = try self.allocator.dupe(u8, entry_bytes);
    errdefer self.allocator.free(owned_entry);
    const evict_oldest = duplicate_index == null and self.entries.items.len == maximum_entries;
    if (duplicate_index == null and !evict_oldest) {
        try self.entries.ensureUnusedCapacity(self.allocator, 1);
    }
    return .{ .replace = .{
        .owned_entry = owned_entry,
        .duplicate_index = duplicate_index,
        .evict_oldest = evict_oldest,
    } };
}

fn commitAdmission(
    self: *PromptHistory,
    prepared: *PreparedAdmission,
    admission: Admission,
) void {
    switch (prepared.*) {
        .noop => return,
        .promote_newest => self.newest_unpersisted = false,
        .replace => |replacement| {
            if (replacement.duplicate_index) |index| {
                self.allocator.free(self.entries.orderedRemove(index));
            } else if (replacement.evict_oldest) {
                self.allocator.free(self.entries.orderedRemove(0));
            }
            self.entries.appendAssumeCapacity(replacement.owned_entry);
            self.newest_unpersisted = admission == .session;
            prepared.* = .noop;
        },
    }
    if (self.draft) |owned_draft| self.allocator.free(owned_draft);
    self.draft = null;
    self.position = self.entries.items.len;
}

fn findExact(self: *const PromptHistory, entry_bytes: []const u8) ?usize {
    for (self.entries.items, 0..) |existing, index| {
        if (std.mem.eql(u8, existing, entry_bytes)) return index;
    }
    return null;
}

pub const Direction = enum { older, newer };

pub const PreparedNavigation = struct {
    target: []const u8,
    next_position: usize,
    owned_draft: ?[]u8,
    release_draft: bool,

    pub fn deinit(prepared: *PreparedNavigation, allocator: std.mem.Allocator) void {
        if (prepared.owned_draft) |storage| allocator.free(storage);
        prepared.* = undefined;
    }
};

pub fn prepareNavigation(
    self: *PromptHistory,
    current_editor: []const u8,
    direction: Direction,
) error{OutOfMemory}!?PreparedNavigation {
    const len = self.entries.items.len;
    return switch (direction) {
        .older => older: {
            if (self.position == 0 or len == 0) break :older null;
            if (self.position == len) {
                const owned_draft = try self.allocator.dupe(u8, current_editor);
                break :older .{
                    .target = self.entries.items[len - 1],
                    .next_position = len - 1,
                    .owned_draft = owned_draft,
                    .release_draft = false,
                };
            }
            break :older .{
                .target = self.entries.items[self.position - 1],
                .next_position = self.position - 1,
                .owned_draft = null,
                .release_draft = false,
            };
        },
        .newer => newer: {
            if (self.position >= len) break :newer null;
            const next_position = self.position + 1;
            if (next_position < len) {
                break :newer .{
                    .target = self.entries.items[next_position],
                    .next_position = next_position,
                    .owned_draft = null,
                    .release_draft = false,
                };
            }
            break :newer .{
                .target = self.draft orelse "",
                .next_position = len,
                .owned_draft = null,
                .release_draft = true,
            };
        },
    };
}

pub fn commitNavigation(self: *PromptHistory, prepared: *PreparedNavigation) void {
    if (prepared.owned_draft) |owned_draft| {
        if (self.draft) |old_draft| self.allocator.free(old_draft);
        self.draft = owned_draft;
        prepared.owned_draft = null;
    }
    self.position = prepared.next_position;
    if (prepared.release_draft) {
        if (self.draft) |owned_draft| self.allocator.free(owned_draft);
        self.draft = null;
    }
    prepared.* = undefined;
}

pub const SearchDirection = enum(i2) { older = -1, newer = 1 };

pub fn search(
    self: *const PromptHistory,
    query: []const u8,
    start: usize,
    direction: SearchDirection,
) ?usize {
    if (query.len == 0 or start >= self.entries.items.len) return null;
    return switch (direction) {
        .older => older: {
            var index = start;
            while (true) {
                if (std.mem.indexOf(u8, self.entries.items[index], query) != null) {
                    break :older index;
                }
                if (index == 0) break :older null;
                index -= 1;
            }
        },
        .newer => newer: {
            var index = start;
            while (index < self.entries.items.len) : (index += 1) {
                if (std.mem.indexOf(u8, self.entries.items[index], query) != null) {
                    break :newer index;
                }
            }
            break :newer null;
        },
    };
}

/// Retains a search match. When search began at the live position, ownership of
/// `owned_original` transfers to history and the caller's optional is emptied.
pub fn acceptSearch(
    self: *PromptHistory,
    match_index: usize,
    original_position: usize,
    owned_original: *?[]u8,
) void {
    std.debug.assert(match_index < self.entries.items.len);
    self.position = match_index;
    if (original_position == self.entries.items.len) {
        if (self.draft) |owned_draft| self.allocator.free(owned_draft);
        self.draft = owned_original.*;
        owned_original.* = null;
    }
}

const RecordingAppender = struct {
    allocator: std.mem.Allocator,
    entries: std.ArrayList([]u8) = .empty,
    outcome: AppendOutcome = .written,
    fail: bool = false,

    fn deinit(self: *RecordingAppender) void {
        for (self.entries.items) |owned_entry| self.allocator.free(owned_entry);
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn append(
        self: *RecordingAppender,
        allocator: std.mem.Allocator,
        entry_bytes: []const u8,
    ) error{OutOfMemory}!AppendOutcome {
        if (self.fail) return error.OutOfMemory;
        const copy = try allocator.dupe(u8, entry_bytes);
        errdefer allocator.free(copy);
        try self.entries.append(self.allocator, copy);
        return self.outcome;
    }
};

fn expectEntries(history: *const PromptHistory, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, history.count());
    for (expected, 0..) |value, index| {
        try std.testing.expectEqualStrings(value, history.entry(index).?);
    }
}

fn navigate(
    history: *PromptHistory,
    current_editor: []const u8,
    direction: Direction,
) !?[]const u8 {
    var prepared = (try history.prepareNavigation(current_editor, direction)) orelse return null;
    const target = prepared.target;
    history.commitNavigation(&prepared);
    return target;
}

test "erasedups are exact and newest repeats preserve persistence state" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    var recorder: RecordingAppender = .{ .allocator = std.testing.allocator };
    defer recorder.deinit();
    history.setAppender(Appender.from(&recorder));

    try history.admit("One", .persistent);
    try history.admit("Two", .persistent);
    try history.admit("one", .persistent);
    try history.admit("One", .persistent);
    try expectEntries(&history, &.{ "Two", "one", "One" });
    try std.testing.expectEqual(@as(usize, 4), recorder.entries.items.len);

    try history.admit("One", .persistent);
    try history.admit("One", .session);
    try expectEntries(&history, &.{ "Two", "one", "One" });
    try std.testing.expectEqual(@as(usize, 4), recorder.entries.items.len);
    try std.testing.expect(!history.newest_unpersisted);
    try history.admit("", .persistent);
    try std.testing.expectEqual(@as(usize, 4), recorder.entries.items.len);
}

test "history retains exactly the newest 1000 entries" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    var buffer: [32]u8 = undefined;
    for (0..maximum_entries + 2) |index| {
        const value = try std.fmt.bufPrint(&buffer, "entry-{d}", .{index});
        try history.seed(value);
    }
    try std.testing.expectEqual(maximum_entries, history.count());
    try std.testing.expectEqualStrings("entry-2", history.entry(0).?);
    try std.testing.expectEqualStrings("entry-1001", history.entry(maximum_entries - 1).?);

    try history.seed("entry-2");
    try std.testing.expectEqual(maximum_entries, history.count());
    try std.testing.expectEqualStrings("entry-3", history.entry(0).?);
    try std.testing.expectEqualStrings("entry-2", history.entry(maximum_entries - 1).?);
}

test "session newest promotes once and persistent repeats do not append" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    var recorder: RecordingAppender = .{ .allocator = std.testing.allocator };
    defer recorder.deinit();
    history.setAppender(Appender.from(&recorder));

    try history.admit("draft", .session);
    try std.testing.expect(history.newest_unpersisted);
    try history.admit("draft", .session);
    try std.testing.expectEqual(@as(usize, 0), recorder.entries.items.len);
    try history.admit("draft", .persistent);
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
    try std.testing.expectEqualStrings("draft", recorder.entries.items[0]);
    try std.testing.expect(!history.newest_unpersisted);
    try history.admit("draft", .persistent);
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
}

test "every appender outcome commits and OOM preserves pending state" {
    for ([_]AppendOutcome{ .written, .too_large, .unavailable }) |outcome| {
        var history = init(std.testing.allocator);
        defer history.deinit();
        var recorder: RecordingAppender = .{ .allocator = std.testing.allocator, .outcome = outcome };
        defer recorder.deinit();
        history.setAppender(Appender.from(&recorder));
        try history.admit("session", .session);
        try history.admit("session", .persistent);
        try std.testing.expect(!history.newest_unpersisted);
        try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
    }

    var history = init(std.testing.allocator);
    defer history.deinit();
    var recorder: RecordingAppender = .{ .allocator = std.testing.allocator, .fail = true };
    defer recorder.deinit();
    history.setAppender(Appender.from(&recorder));
    try history.admit("before", .session);
    try std.testing.expectError(error.OutOfMemory, history.admit("before", .persistent));
    try expectEntries(&history, &.{"before"});
    try std.testing.expect(history.newest_unpersisted);

    try std.testing.expectError(error.OutOfMemory, history.admit("after", .persistent));
    try expectEntries(&history, &.{"before"});
}

test "seed never appends and marks a promoted newest persistent" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    var recorder: RecordingAppender = .{ .allocator = std.testing.allocator };
    defer recorder.deinit();
    history.setAppender(Appender.from(&recorder));

    try history.admit("same", .session);
    try history.seed("same");
    try std.testing.expect(!history.newest_unpersisted);
    try std.testing.expectEqual(@as(usize, 0), recorder.entries.items.len);
    try history.seed("other");
    try std.testing.expectEqual(@as(usize, 0), recorder.entries.items.len);
}

test "navigation snapshots and restores the live draft without mutating entries" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    try history.seed("oldest");
    try history.seed("newest");
    history.beginRead();

    try std.testing.expectEqualStrings("newest", (try navigate(&history, "live draft", .older)).?);
    try std.testing.expectEqual(@as(usize, 1), history.currentPosition());
    try std.testing.expectEqualStrings("oldest", (try navigate(&history, "edited recall", .older)).?);
    try std.testing.expect((try navigate(&history, "ignored", .older)) == null);
    try std.testing.expectEqualStrings("newest", (try navigate(&history, "changed oldest", .newer)).?);
    var restore = (try history.prepareNavigation("changed newest", .newer)).?;
    try std.testing.expectEqualStrings("live draft", restore.target);
    history.commitNavigation(&restore);
    try std.testing.expect((try navigate(&history, "live draft", .newer)) == null);
    try expectEntries(&history, &.{ "oldest", "newest" });
    try std.testing.expect(history.draft == null);
}

test "failed or abandoned navigation leaves position and draft unchanged" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    try history.seed("entry");
    history.beginRead();

    var prepared = (try history.prepareNavigation("draft", .older)).?;
    try std.testing.expectEqual(@as(usize, 1), history.currentPosition());
    try std.testing.expect(history.draft == null);
    prepared.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), history.currentPosition());
    try std.testing.expect(history.draft == null);
}

test "empty navigation and beginRead reset position and release stale draft" {
    var empty = init(std.testing.allocator);
    defer empty.deinit();
    try std.testing.expect((try empty.prepareNavigation("draft", .older)) == null);
    try std.testing.expect((try empty.prepareNavigation("draft", .newer)) == null);

    var history = init(std.testing.allocator);
    defer history.deinit();
    try history.seed("entry");
    history.beginRead();
    _ = try navigate(&history, "draft", .older);
    try std.testing.expect(history.draft != null);
    history.beginRead();
    try std.testing.expect(history.draft == null);
    try std.testing.expectEqual(history.count(), history.currentPosition());
}

test "search is case-sensitive byte-substring traversal" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    try history.seed("alpha needle");
    try history.seed("Needle middle");
    try history.seed("last needle value");

    try std.testing.expectEqual(@as(?usize, 2), history.search("needle", 2, .older));
    try std.testing.expectEqual(@as(?usize, 0), history.search("needle", 1, .older));
    try std.testing.expectEqual(@as(?usize, 2), history.search("needle", 1, .newer));
    try std.testing.expectEqual(@as(?usize, 1), history.search("Needle", 0, .newer));
    try std.testing.expectEqual(@as(?usize, null), history.search("missing", 2, .older));
    try std.testing.expectEqual(@as(?usize, null), history.search("", 0, .newer));
    try std.testing.expectEqual(@as(?usize, null), history.search("needle", 3, .older));
}

test "acceptSearch transfers a live original draft only when search began live" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    try history.seed("zero");
    try history.seed("one");
    history.beginRead();

    var original: ?[]u8 = try std.testing.allocator.dupe(u8, "live");
    history.acceptSearch(0, history.count(), &original);
    try std.testing.expect(original == null);
    try std.testing.expectEqual(@as(usize, 0), history.currentPosition());
    try std.testing.expectEqualStrings("one", (try navigate(&history, "zero edited", .newer)).?);
    var restore = (try history.prepareNavigation("one edited", .newer)).?;
    try std.testing.expectEqualStrings("live", restore.target);
    history.commitNavigation(&restore);

    var recalled_original: ?[]u8 = try std.testing.allocator.dupe(u8, "caller-owned");
    defer if (recalled_original) |storage| std.testing.allocator.free(storage);
    history.acceptSearch(1, 0, &recalled_original);
    try std.testing.expect(recalled_original != null);
}

test "admitted and seeded storage survives caller mutation" {
    var history = init(std.testing.allocator);
    defer history.deinit();
    var admitted = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    try history.admit(&admitted, .session);
    @memset(&admitted, 'x');
    try std.testing.expectEqualStrings("value", history.entry(0).?);

    var seeded = [_]u8{ 's', 'e', 'e', 'd' };
    try history.seed(&seeded);
    @memset(&seeded, 'y');
    try std.testing.expectEqualStrings("seed", history.entry(1).?);
}

fn admissionAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = init(allocator);
    defer history.deinit();
    try history.seed("before");
    history.admit("after", .session) catch |err| {
        try expectEntries(&history, &.{"before"});
        try std.testing.expect(!history.newest_unpersisted);
        return err;
    };
    try expectEntries(&history, &.{ "before", "after" });
}

fn erasedupAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = init(allocator);
    defer history.deinit();
    try history.seed("one");
    try history.seed("two");
    try history.seed("three");
    history.admit("one", .session) catch |err| {
        try expectEntries(&history, &.{ "one", "two", "three" });
        return err;
    };
    try expectEntries(&history, &.{ "two", "three", "one" });
}

fn navigationAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = init(allocator);
    defer history.deinit();
    try history.seed("entry");
    history.beginRead();
    var prepared = (history.prepareNavigation("draft", .older) catch |err| {
        try std.testing.expectEqual(history.count(), history.currentPosition());
        try std.testing.expect(history.draft == null);
        return err;
    }).?;
    defer prepared.deinit(allocator);
}

fn appenderAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = init(allocator);
    defer history.deinit();
    var recorder: RecordingAppender = .{ .allocator = allocator };
    defer recorder.deinit();
    history.setAppender(Appender.from(&recorder));
    try history.seed("before");
    history.admit("after", .persistent) catch |err| {
        try expectEntries(&history, &.{"before"});
        return err;
    };
    try expectEntries(&history, &.{ "before", "after" });
    try std.testing.expectEqual(@as(usize, 1), recorder.entries.items.len);
}

test "all owner, erasedup, navigation, and appender allocation failures are atomic" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        admissionAllocationFailureCase,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        erasedupAllocationFailureCase,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        navigationAllocationFailureCase,
        .{},
    );
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        appenderAllocationFailureCase,
        .{},
    );
}
