//! Bounded, domain-neutral single-select picker. The TUI core owns only
//! modal product state: filter query, rows, and highlighted index.
//! Item ids are opaque bytes that the concrete frontend interprets.
const std = @import("std");

const input_mod = @import("input.zig");
const match_mod = @import("match.zig");
const text_mod = @import("text.zig");

const Picker = @This();

pub const Id = u32;
pub const item_count_max: usize = 384;
pub const visible_rows_max: usize = 8;
pub const id_bytes_max: usize = 128;
pub const label_bytes_max: usize = 160;
pub const detail_bytes_max: usize = 160;
pub const query_bytes_max: usize = 128;

pub const Item = struct {
    id: []const u8,
    label: []const u8,
    detail: []const u8 = "",
};

pub const Open = struct {
    id: Id,
    query: []const u8 = "",
    items: []const Item,
    search_detail: bool = false,
};

pub const Selection = struct {
    picker_id: Id,
    item_id: []u8,
};

pub const InputResult = union(enum) {
    none,
    closed,
    selected: Selection,
};

pub const OwnedItem = struct {
    id: [id_bytes_max]u8 = undefined,
    id_len: u16 = 0,
    label: [label_bytes_max]u8 = undefined,
    label_len: u16 = 0,
    detail: [detail_bytes_max]u8 = undefined,
    detail_len: u16 = 0,

    fn init(item: Item) OwnedItem {
        var self: OwnedItem = .{};
        self.id_len = copyBounded(id_bytes_max, &self.id, item.id);
        self.label_len = copyBounded(label_bytes_max, &self.label, item.label);
        self.detail_len = copyBounded(detail_bytes_max, &self.detail, item.detail);
        return self;
    }

    pub fn idSlice(self: *const OwnedItem) []const u8 {
        return self.id[0..self.id_len];
    }

    pub fn labelSlice(self: *const OwnedItem) []const u8 {
        return self.label[0..self.label_len];
    }

    pub fn detailSlice(self: *const OwnedItem) []const u8 {
        return self.detail[0..self.detail_len];
    }
};

id: Id,
query: [query_bytes_max]u8 = undefined,
query_len: u16 = 0,
items: std.ArrayList(OwnedItem) = .empty,
matches: [item_count_max]u16 = undefined,
match_len: u16 = 0,
selected_index: usize = 0,
dropped_items: usize = 0,
search_detail: bool = false,

pub fn init(gpa: std.mem.Allocator, open: Open) error{OutOfMemory}!Picker {
    var self: Picker = .{ .id = open.id, .search_detail = open.search_detail };
    errdefer self.deinit(gpa);

    self.query_len = copyBounded(query_bytes_max, &self.query, open.query);

    const keep = @min(open.items.len, item_count_max);
    try self.items.ensureTotalCapacity(gpa, keep);
    for (open.items[0..keep]) |item| self.items.appendAssumeCapacity(OwnedItem.init(item));
    self.dropped_items = open.items.len - keep;
    self.refreshMatches();
    return self;
}

pub fn deinit(self: *Picker, gpa: std.mem.Allocator) void {
    self.items.deinit(gpa);
    self.* = undefined;
}

pub fn querySlice(self: *const Picker) []const u8 {
    return self.query[0..self.query_len];
}

pub fn replaceQuery(self: *Picker, bytes: []const u8) void {
    self.query_len = 0;
    self.insertQuery(bytes);
    if (self.query_len == 0) self.refreshMatches();
}

pub fn itemCount(self: *const Picker) usize {
    return self.items.items.len;
}

pub fn itemAt(self: *const Picker, index: usize) *const OwnedItem {
    return &self.items.items[index];
}

pub fn matchCount(self: *const Picker) usize {
    return self.match_len;
}

pub fn selectedIndex(self: *const Picker) ?usize {
    if (self.match_len == 0) return null;
    if (self.selected_index >= self.items.items.len) return null;
    if (!self.matchesIndex(self.selected_index)) return null;
    return self.selected_index;
}

pub fn selectedOrdinal(self: *const Picker) ?usize {
    const selected = self.selectedIndex() orelse return null;
    for (self.matches[0..self.match_len], 0..) |index, ordinal| {
        if (index == selected) return ordinal;
    }
    return null;
}

pub fn nthMatchIndex(self: *const Picker, wanted: usize) ?usize {
    if (wanted >= self.match_len) return null;
    return self.matches[wanted];
}

pub fn matchesIndex(self: *const Picker, index: usize) bool {
    return self.itemScore(index) != null;
}

pub fn applyInput(
    self: *Picker,
    gpa: std.mem.Allocator,
    event: input_mod.Input,
) error{OutOfMemory}!InputResult {
    switch (event) {
        .text => |bytes| {
            self.insertQuery(bytes.slice());
            return .none;
        },
        .key => |key| switch (key) {
            .enter => return self.select(gpa),
            .escape, .ctrl_c => return .closed,
            .backspace => {
                self.backspaceQuery();
                return .none;
            },
            .delete => {
                self.clearQuery();
                return .none;
            },
            .arrow_up => {
                self.moveSelection(.up);
                return .none;
            },
            .arrow_down, .tab => {
                self.moveSelection(.down);
                return .none;
            },
            else => return .none,
        },
        .wheel_up => {
            self.moveSelection(.up);
            return .none;
        },
        .wheel_down => {
            self.moveSelection(.down);
            return .none;
        },
        else => return .none,
    }
}

fn select(self: *const Picker, gpa: std.mem.Allocator) error{OutOfMemory}!InputResult {
    const index = self.selectedIndex() orelse return .none;
    const item = &self.items.items[index];
    return .{ .selected = .{
        .picker_id = self.id,
        .item_id = try gpa.dupe(u8, item.idSlice()),
    } };
}

fn insertQuery(self: *Picker, bytes: []const u8) void {
    var clean_buffer: [input_mod.inline_text_bytes_max * 3]u8 = undefined;
    const clean = if (std.unicode.utf8ValidateSlice(bytes))
        bytes
    else
        text_mod.sanitizeInto(&clean_buffer, bytes);
    const available = query_bytes_max - self.query_len;
    if (available == 0) return;
    const piece = text_mod.utf8Prefix(clean, available);
    if (piece.len == 0) return;
    @memcpy(self.query[self.query_len..][0..piece.len], piece);
    self.query_len += @intCast(piece.len);
    self.refreshMatches();
}

fn backspaceQuery(self: *Picker) void {
    if (self.query_len == 0) return;
    self.query_len = @intCast(text_mod.previousGraphemeStart(self.querySlice(), self.query_len));
    self.refreshMatches();
}

fn clearQuery(self: *Picker) void {
    if (self.query_len == 0) return;
    self.query_len = 0;
    self.refreshMatches();
}

const Direction = enum { up, down };

fn moveSelection(self: *Picker, direction: Direction) void {
    if (self.match_len == 0) return;
    const current = self.selectedOrdinal() orelse 0;
    const next = switch (direction) {
        .up => if (current == 0) self.match_len - 1 else current - 1,
        .down => if (current + 1 >= self.match_len) 0 else current + 1,
    };
    self.selected_index = self.matches[next];
}

fn refreshMatches(self: *Picker) void {
    self.match_len = 0;
    if (self.items.items.len == 0) {
        self.selected_index = 0;
        return;
    }

    const query_text = self.querySlice();
    if (query_text.len == 0) {
        for (self.items.items, 0..) |_, index| self.appendMatch(index);
        self.selected_index = self.matches[0];
        return;
    }

    var scores: [item_count_max]match_mod.Score = undefined;
    for (self.items.items, 0..) |_, index| {
        const score = self.itemScore(index) orelse continue;
        self.insertScoredMatch(index, score, &scores);
    }
    self.selected_index = if (self.match_len > 0) self.matches[0] else 0;
}

fn appendMatch(self: *Picker, index: usize) void {
    std.debug.assert(self.match_len < self.matches.len);
    self.matches[self.match_len] = @intCast(index);
    self.match_len += 1;
}

fn insertScoredMatch(
    self: *Picker,
    index: usize,
    score: match_mod.Score,
    scores: *[item_count_max]match_mod.Score,
) void {
    std.debug.assert(self.match_len < self.matches.len);
    var out: usize = self.match_len;
    self.match_len += 1;
    while (out > 0 and match_mod.lessThan(score, scores[out - 1])) : (out -= 1) {
        scores[out] = scores[out - 1];
        self.matches[out] = self.matches[out - 1];
    }
    scores[out] = score;
    self.matches[out] = @intCast(index);
}

fn itemScore(self: *const Picker, index: usize) ?match_mod.Score {
    const query_text = self.querySlice();
    const item = &self.items.items[index];
    var best: ?match_mod.Score = null;
    best = bestScore(best, fieldScore(item.idSlice(), query_text, 0));
    best = bestScore(best, fieldScore(item.labelSlice(), query_text, 4));
    if (self.search_detail) best = bestScore(best, fieldScore(item.detailSlice(), query_text, 8));
    return best;
}

fn fieldScore(field: []const u8, query: []const u8, bias: u32) ?match_mod.Score {
    var value = match_mod.score(field, query) orelse return null;
    value.value +|= bias;
    return value;
}

fn bestScore(current: ?match_mod.Score, candidate: ?match_mod.Score) ?match_mod.Score {
    const next = candidate orelse return current;
    const old = current orelse return next;
    return if (match_mod.lessThan(next, old)) next else old;
}

fn copyBounded(comptime max: usize, dest: *[max]u8, bytes: []const u8) u16 {
    var clean_buffer: [max]u8 = undefined;
    const clean = if (std.unicode.utf8ValidateSlice(bytes))
        bytes
    else
        text_mod.sanitizeInto(&clean_buffer, bytes);
    const prefix = text_mod.utf8Prefix(clean, max);
    @memcpy(dest[0..prefix.len], prefix);
    return @intCast(prefix.len);
}

test "picker filters, moves, and returns an opaque selected id" {
    const gpa = std.testing.allocator;
    const source = [_]Item{
        .{ .id = "openai/gpt", .label = "openai/gpt", .detail = "OpenAI" },
        .{ .id = "anthropic/claude", .label = "anthropic/claude", .detail = "Anthropic" },
    };
    var picker = try Picker.init(gpa, .{ .id = 7, .query = "", .items = &source });
    defer picker.deinit(gpa);

    _ = try picker.applyInput(gpa, .{ .text = input_mod.InlineBytes.from("cla") });
    try std.testing.expectEqual(@as(usize, 1), picker.matchCount());
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex().?);

    const result = try picker.applyInput(gpa, .{ .key = .enter });
    defer switch (result) {
        .selected => |selection| gpa.free(selection.item_id),
        else => {},
    };
    try std.testing.expect(result == .selected);
    try std.testing.expectEqual(@as(Id, 7), result.selected.picker_id);
    try std.testing.expectEqualStrings("anthropic/claude", result.selected.item_id);
}

test "picker optionally searches detail text" {
    const gpa = std.testing.allocator;
    const source = [_]Item{
        .{ .id = "one", .label = "first", .detail = "repo alpha" },
        .{ .id = "two", .label = "second", .detail = "repo beta" },
    };
    var picker = try Picker.init(gpa, .{ .id = 7, .items = &source, .search_detail = true });
    defer picker.deinit(gpa);

    _ = try picker.applyInput(gpa, .{ .text = input_mod.InlineBytes.from("beta") });
    try std.testing.expectEqual(@as(usize, 1), picker.matchCount());
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex().?);
}

test "picker falls back to fuzzy search and wraps navigation" {
    const gpa = std.testing.allocator;
    const source = [_]Item{
        .{ .id = "openai/gpt-4.1", .label = "openai/gpt-4.1" },
        .{ .id = "openai/gpt-5.1", .label = "openai/gpt-5.1" },
    };
    var picker = try Picker.init(gpa, .{ .id = 7, .items = &source });
    defer picker.deinit(gpa);

    _ = try picker.applyInput(gpa, .{ .text = input_mod.InlineBytes.from("g51") });
    try std.testing.expectEqual(@as(usize, 1), picker.matchCount());
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex().?);

    _ = try picker.applyInput(gpa, .{ .key = .arrow_down });
    try std.testing.expectEqual(@as(usize, 1), picker.selectedIndex().?);
}
