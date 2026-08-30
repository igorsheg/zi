const std = @import("std");
const LineEditor = @import("LineEditor.zig");
const PromptHistory = @import("PromptHistory.zig");
const PromptSearch = @This();

pub const Direction = enum { older, newer };
pub const Intent = enum { accept, submit, cancel };
pub const Finish = enum { editing, submit };
pub const Error = LineEditor.Error;

pub const View = struct {
    buffer: []const u8,
    cursor: usize,
};

allocator: std.mem.Allocator,
original: ?[]u8,
original_cursor: usize,
original_position: usize,
query: std.ArrayList(u8) = .empty,
direction: Direction = .older,
match_index: ?usize = null,
no_match: bool = false,

/// Snapshots the editor and history position. The editor and history are otherwise
/// borrowed only by individual operations.
pub fn init(
    allocator: std.mem.Allocator,
    editor: *const LineEditor,
    history: *const PromptHistory,
) error{OutOfMemory}!PromptSearch {
    return .{
        .allocator = allocator,
        .original = try allocator.dupe(u8, editor.bytes()),
        .original_cursor = editor.cursorOffset(),
        .original_position = history.currentPosition(),
    };
}

pub fn deinit(self: *PromptSearch) void {
    if (self.original) |storage| self.allocator.free(storage);
    self.query.deinit(self.allocator);
    self.* = undefined;
}

/// Appends bytes to the bounded query, then recomputes from the current match.
/// Allocation and size failures leave all search state unchanged.
pub fn append(
    self: *PromptSearch,
    history: *const PromptHistory,
    bytes: []const u8,
) Error!void {
    if (bytes.len > LineEditor.max_prompt_bytes - self.query.items.len) {
        return error.PromptTooLong;
    }
    try self.query.ensureUnusedCapacity(self.allocator, bytes.len);
    self.query.appendSliceAssumeCapacity(bytes);
    self.recompute(history);
}

/// Removes one valid UTF-8 codepoint, or one byte when the query tail is malformed.
pub fn backspace(self: *PromptSearch, history: *const PromptHistory) void {
    self.query.items.len = LineEditor.previousCodepoint(self.query.items, self.query.items.len);
    self.recompute(history);
}

/// Repeats from one entry beyond the current match. Like hax, an exhausted repeat
/// keeps the displayed match and does not enter the no-match state.
pub fn repeat(
    self: *PromptSearch,
    history: *const PromptHistory,
    direction: Direction,
) void {
    self.direction = direction;
    if (self.query.items.len == 0 or self.no_match) return;

    const current = self.match_index orelse return;
    const start = switch (direction) {
        .older => if (current == 0) return else current - 1,
        .newer => if (current + 1 >= history.count()) return else current + 1,
    };
    if (history.search(self.query.items, start, historyDirection(direction))) |found| {
        self.match_index = found;
    }
}

/// Returns a view borrowed from this search or history until either is mutated.
pub fn view(self: *const PromptSearch, history: *const PromptHistory) View {
    if (self.no_match) return .{ .buffer = "", .cursor = 0 };
    if (self.match_index) |index| {
        if (history.entry(index)) |entry| {
            return .{
                .buffer = entry,
                .cursor = std.mem.indexOf(u8, entry, self.query.items) orelse entry.len,
            };
        }
        return .{ .buffer = "", .cursor = 0 };
    }
    const original = self.original orelse "";
    return .{ .buffer = original, .cursor = @min(self.original_cursor, original.len) };
}

/// Installs the final editor state before publishing a history position. A valid
/// accepted live search transfers the saved draft to history.
pub fn finish(
    self: *PromptSearch,
    history: *PromptHistory,
    editor: *LineEditor,
    intent: Intent,
) Error!Finish {
    const accepted_index = if (intent != .cancel and !self.no_match and self.query.items.len != 0)
        self.match_index
    else
        null;

    if (accepted_index) |index| {
        const entry = history.entry(index) orelse return self.restore(editor);
        const cursor = std.mem.indexOf(u8, entry, self.query.items) orelse entry.len;
        try editor.setBufferAtCursor(entry, cursor);
        history.acceptSearch(index, self.original_position, &self.original);
        return if (intent == .submit) .submit else .editing;
    }
    return self.restore(editor);
}

fn restore(self: *PromptSearch, editor: *LineEditor) Error!Finish {
    const original = self.original orelse "";
    try editor.setBufferAtCursor(original, self.original_cursor);
    return .editing;
}

fn recompute(self: *PromptSearch, history: *const PromptHistory) void {
    if (self.query.items.len == 0) {
        self.match_index = null;
        self.no_match = false;
        return;
    }

    const start = self.match_index orelse switch (self.direction) {
        .older => if (history.count() == 0) {
            self.no_match = true;
            return;
        } else history.count() - 1,
        .newer => if (history.count() == 0) {
            self.no_match = true;
            return;
        } else 0,
    };
    if (history.search(self.query.items, start, historyDirection(self.direction))) |found| {
        self.match_index = found;
        self.no_match = false;
    } else {
        self.no_match = true;
    }
}

fn historyDirection(direction: Direction) PromptHistory.SearchDirection {
    return switch (direction) {
        .older => .older,
        .newer => .newer,
    };
}

fn makeHistory(allocator: std.mem.Allocator) !PromptHistory {
    var history = PromptHistory.init(allocator);
    errdefer history.deinit();
    try history.seed("old alpha");
    try history.seed("middle beta alpha");
    try history.seed("new alpha beta");
    history.beginRead();
    return history;
}

fn expectView(search: *const PromptSearch, history: *const PromptHistory, text: []const u8, cursor: usize) !void {
    const current = search.view(history);
    try std.testing.expectEqualStrings(text, current.buffer);
    try std.testing.expectEqual(cursor, current.cursor);
}

test "initial search is case-sensitive in both directions" {
    var history = try makeHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");

    var reverse = try init(std.testing.allocator, &editor, &history);
    defer reverse.deinit();
    try reverse.append(&history, "alpha");
    try std.testing.expectEqual(@as(?usize, 2), reverse.match_index);
    try expectView(&reverse, &history, "new alpha beta", 4);

    var forward = try init(std.testing.allocator, &editor, &history);
    defer forward.deinit();
    forward.repeat(&history, .newer);
    try forward.append(&history, "alpha");
    try std.testing.expectEqual(@as(?usize, 0), forward.match_index);

    var exact_case = try init(std.testing.allocator, &editor, &history);
    defer exact_case.deinit();
    try exact_case.append(&history, "Alpha");
    try std.testing.expect(exact_case.match_index == null);
    try std.testing.expect(exact_case.no_match);
    try expectView(&exact_case, &history, "", 0);
}

test "repeat traverses and exhausted repeat preserves the last match" {
    var history = try makeHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();

    try search.append(&history, "alpha");
    search.repeat(&history, .older);
    try std.testing.expectEqual(@as(?usize, 1), search.match_index);
    search.repeat(&history, .older);
    try std.testing.expectEqual(@as(?usize, 0), search.match_index);
    search.repeat(&history, .older);
    try std.testing.expectEqual(@as(?usize, 0), search.match_index);
    try std.testing.expect(!search.no_match);

    search.repeat(&history, .newer);
    try std.testing.expectEqual(@as(?usize, 1), search.match_index);
    search.repeat(&history, .newer);
    try std.testing.expectEqual(@as(?usize, 2), search.match_index);
    search.repeat(&history, .newer);
    try std.testing.expectEqual(@as(?usize, 2), search.match_index);
}

test "editing recomputes from the retained match and can recover from no match" {
    var history = try makeHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();

    try search.append(&history, "alpha");
    search.repeat(&history, .older);
    try std.testing.expectEqual(@as(?usize, 1), search.match_index);
    try search.append(&history, " z");
    try std.testing.expectEqual(@as(?usize, 1), search.match_index);
    try std.testing.expect(search.no_match);

    search.repeat(&history, .newer);
    try std.testing.expectEqual(Direction.newer, search.direction);
    try std.testing.expect(search.no_match);
    search.backspace(&history);
    try std.testing.expect(!search.no_match);
    try std.testing.expectEqual(@as(?usize, 2), search.match_index);
    search.backspace(&history);
    try std.testing.expect(!search.no_match);
    try std.testing.expectEqual(@as(?usize, 2), search.match_index);

    while (search.query.items.len != 0) search.backspace(&history);
    try std.testing.expect(search.match_index == null);
    try std.testing.expect(!search.no_match);
    try expectView(&search, &history, "", 0);
}

test "backspace removes UTF-8 codepoints and malformed tail bytes" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("prefix é");
    history.beginRead();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();

    try search.append(&history, "é\xff");
    try std.testing.expect(search.no_match);
    search.backspace(&history);
    try std.testing.expectEqualStrings("é", search.query.items);
    try std.testing.expect(!search.no_match);
    search.backspace(&history);
    try std.testing.expectEqualStrings("", search.query.items);
}

test "view restores the original cursor and uses the first substring cursor" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    try history.seed("xx needle needle");
    history.beginRead();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("original");
    editor.cursor = 3;
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();

    try expectView(&search, &history, "original", 3);
    try search.append(&history, "needle");
    try expectView(&search, &history, "xx needle needle", 3);
}

test "cancel and invalid acceptance restore atomically without changing history" {
    for ([_]Intent{ .cancel, .accept, .submit }) |intent| {
        var history = try makeHistory(std.testing.allocator);
        defer history.deinit();
        var editor = LineEditor.init(std.testing.allocator, false);
        defer editor.deinit();
        try editor.setBuffer("original");
        editor.cursor = 2;
        const position = history.currentPosition();
        var search = try init(std.testing.allocator, &editor, &history);
        defer search.deinit();
        if (intent == .cancel) {
            try search.append(&history, "alpha");
        } else {
            try search.append(&history, "missing");
        }
        try editor.setBuffer("temporary");

        try std.testing.expectEqual(Finish.editing, try search.finish(&history, &editor, intent));
        try std.testing.expectEqualStrings("original", editor.bytes());
        try std.testing.expectEqual(@as(usize, 2), editor.cursor);
        try std.testing.expectEqual(position, history.currentPosition());
    }
}

test "accept installs a match and only valid submit requests submission" {
    for ([_]Intent{ .accept, .submit }) |intent| {
        var history = try makeHistory(std.testing.allocator);
        defer history.deinit();
        var editor = LineEditor.init(std.testing.allocator, false);
        defer editor.deinit();
        try editor.setBuffer("draft");
        var search = try init(std.testing.allocator, &editor, &history);
        defer search.deinit();
        try search.append(&history, "beta");

        const result = try search.finish(&history, &editor, intent);
        try std.testing.expectEqual(if (intent == .submit) Finish.submit else Finish.editing, result);
        try std.testing.expectEqualStrings("new alpha beta", editor.bytes());
        try std.testing.expectEqual(@as(usize, 10), editor.cursor);
        try std.testing.expectEqual(@as(usize, 2), history.currentPosition());
    }
}

test "accepting from live transfers the original draft for newer navigation" {
    var history = try makeHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    try editor.setBuffer("live draft");
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();
    try search.append(&history, "middle");

    try std.testing.expectEqual(Finish.editing, try search.finish(&history, &editor, .accept));
    try std.testing.expect(search.original == null);
    try std.testing.expectEqual(@as(usize, 1), history.currentPosition());
    var newer = (try history.prepareNavigation(editor.bytes(), .newer)).?;
    history.commitNavigation(&newer);
    var live = (try history.prepareNavigation("ignored", .newer)).?;
    try std.testing.expectEqualStrings("live draft", live.target);
    history.commitNavigation(&live);
}

test "accepting from a recalled position leaves original ownership with search" {
    var history = try makeHistory(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var navigation = (try history.prepareNavigation("live", .older)).?;
    try editor.setBuffer(navigation.target);
    history.commitNavigation(&navigation);
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();
    try search.append(&history, "old");

    _ = try search.finish(&history, &editor, .accept);
    try std.testing.expect(search.original != null);
    try std.testing.expectEqual(@as(usize, 0), history.currentPosition());
}

fn initAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = PromptHistory.init(allocator);
    defer history.deinit();
    var editor = LineEditor.init(allocator, false);
    defer editor.deinit();
    try editor.setBuffer("original allocation");
    var search = try init(allocator, &editor, &history);
    defer search.deinit();
}

fn appendAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = try makeHistory(allocator);
    defer history.deinit();
    var editor = LineEditor.init(allocator, false);
    defer editor.deinit();
    var search = try init(allocator, &editor, &history);
    defer search.deinit();
    try search.append(&history, "a");
    const old_match = search.match_index;
    const old_no_match = search.no_match;
    var bytes: [256]u8 = undefined;
    @memset(&bytes, 'x');
    search.append(&history, &bytes) catch |err| {
        try std.testing.expectEqualStrings("a", search.query.items);
        try std.testing.expectEqual(old_match, search.match_index);
        try std.testing.expectEqual(old_no_match, search.no_match);
        return err;
    };
}

fn finishAllocationFailureCase(allocator: std.mem.Allocator) !void {
    var history = PromptHistory.init(allocator);
    defer history.deinit();
    var entry: [512]u8 = undefined;
    @memset(&entry, 'm');
    try history.seed(&entry);
    history.beginRead();
    var editor = LineEditor.init(allocator, false);
    defer editor.deinit();
    try editor.setBuffer("draft");
    var search = try init(allocator, &editor, &history);
    defer search.deinit();
    try search.append(&history, "mmm");
    const old_position = history.currentPosition();
    _ = search.finish(&history, &editor, .accept) catch |err| {
        try std.testing.expectEqualStrings("draft", editor.bytes());
        try std.testing.expectEqual(old_position, history.currentPosition());
        try std.testing.expect(search.original != null);
        return err;
    };
}

test "all initialization, query, and finish allocation failures are leak-free and atomic" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, initAllocationFailureCase, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, appendAllocationFailureCase, .{});
    try std.testing.checkAllAllocationFailures(std.testing.allocator, finishAllocationFailureCase, .{});
}

test "query bound rejects growth without mutation" {
    var history = PromptHistory.init(std.testing.allocator);
    defer history.deinit();
    var editor = LineEditor.init(std.testing.allocator, false);
    defer editor.deinit();
    var search = try init(std.testing.allocator, &editor, &history);
    defer search.deinit();
    try search.query.ensureTotalCapacityPrecise(std.testing.allocator, LineEditor.max_prompt_bytes);
    search.query.items.len = LineEditor.max_prompt_bytes;
    @memset(search.query.items, 'q');
    try std.testing.expectError(error.PromptTooLong, search.append(&history, "x"));
    try std.testing.expectEqual(LineEditor.max_prompt_bytes, search.query.items.len);
}
