const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const keys_mod = @import("../keys.zig");
const select_list_mod = @import("select_list.zig");
const theme_mod = @import("../theme.zig");
const box_chrome = @import("../box_chrome.zig");
const grapheme_mod = @import("../grapheme.zig");
const cell_mod = @import("../cell.zig");
const search = @import("../../search/root.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Region = buffer_mod.Region;
const Key = keys_mod.Key;
const SelectList = select_list_mod.SelectList;
const SelectItem = select_list_mod.SelectItem;
const InputResult = select_list_mod.InputResult;
const Theme = theme_mod.Theme;
const Color = cell_mod.Color;

const MAX_ITEMS = 512;
const MAX_QUERY = 128;

/// Modal list picker — wraps SelectList as a Component for use in the overlay stack.
/// Renders a bordered box with optional title, optional search input, and the select list.
/// Reports selection/cancellation via callbacks.
///
/// When `searchable` is true, printable characters and backspace filter the list
/// using fuzzy matching. The original (unfiltered) items are borrowed from the caller;
/// the filtered view is managed internally.
pub const Selection = struct {
    item: *const SelectItem,
    source_index: usize,
};

pub const StatusKind = enum {
    info,
    loading,
    @"error",
};

pub const Status = struct {
    text: []const u8,
    kind: StatusKind = .info,
};

pub const ListPicker = struct {
    list: SelectList,
    title: []const u8 = "",
    theme: *const Theme,
    on_select: ?*const fn (selection: Selection, ctx: ?*anyopaque) void = null,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    focused: bool = false,
    search_placeholder: ?[]const u8 = null,
    empty_text: []const u8 = "No matching commands",
    status: ?Status = null,
    preferred_selection_value: ?[]const u8 = null,
    pending_selection_index: ?usize = null,

    // ── Search state ────────────────────────────────────────────
    searchable: bool = false,
    /// Borrowed: all items from caller (unfiltered).
    all_items: []const SelectItem = &.{},
    /// Optional caller-provided search texts (parallel to all_items).
    /// If null, search uses item.label.
    search_texts: ?[]const []const u8 = null,
    /// Query buffer (owned by ListPicker).
    query_buf: [MAX_QUERY]u8 = undefined,
    query_len: usize = 0,
    /// Scratch: indices from fuzzyFilter.
    match_indices: [MAX_ITEMS]usize = undefined,
    /// Source-row index for each filtered row.
    filtered_source_indices: [MAX_ITEMS]usize = undefined,
    /// Scratch: filtered items slice for SelectList.
    filtered_buf: [MAX_ITEMS]SelectItem = undefined,
    filtered_count: usize = 0,

    pub fn init(theme: *const Theme) ListPicker {
        return .{
            .list = .{ .theme = theme },
            .theme = theme,
        };
    }

    /// Set items and enable search. Caller owns `items` memory.
    /// `search_texts` is optional — if null, search matches on item.label.
    pub fn setItems(self: *ListPicker, items: []const SelectItem) void {
        self.searchable = false;
        self.all_items = items;
        self.search_texts = null;
        self.query_len = 0;
        self.filtered_count = 0;
        self.list.empty_text = self.empty_text;
        self.list.setItems(items);
        self.applyPreferredSelection();
    }

    pub fn setSearchableItems(
        self: *ListPicker,
        items: []const SelectItem,
        search_texts: ?[]const []const u8,
    ) void {
        self.searchable = true;
        self.all_items = items;
        self.search_texts = search_texts;
        self.query_len = 0;
        self.list.empty_text = self.empty_text;
        self.applyFilter();
    }

    pub fn setSearchPlaceholder(self: *ListPicker, text: ?[]const u8) void {
        self.search_placeholder = text;
    }

    pub fn setEmptyText(self: *ListPicker, text: []const u8) void {
        self.empty_text = text;
        self.list.empty_text = text;
    }

    pub fn setStatus(self: *ListPicker, status: ?Status) void {
        self.status = status;
    }

    pub fn setInitialSelectionByValue(self: *ListPicker, value: []const u8) void {
        self.preferred_selection_value = value;
        self.pending_selection_index = null;
        self.applyPreferredSelection();
    }

    pub fn setInitialSelectionIndex(self: *ListPicker, index: usize) void {
        self.pending_selection_index = index;
        self.applyPreferredSelection();
    }

    // ── Component interface ──────────────────────────────────────

    pub fn render(self: *ListPicker, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 4 or h < 3) return;

        const border_color = self.theme.fg(.border);
        const style = box_chrome.Style{ .chrome = border_color, .fg = border_color, .dim = border_color };
        const frame = box_chrome.closedFrame(region);

        // Top border with title
        _ = frame.drawTop(if (self.title.len > 0) self.title else null, null, style);
        // Bottom border
        _ = frame.drawBottom(style);

        const inner = frame.inner;
        const content_h = inner.height;
        if (content_h > 0) {
            var row: u32 = 0;
            while (row < content_h) : (row += 1) {
                _ = frame.drawBodyRow(row, style);
            }
        }

        if (content_h == 0 or inner.width == 0) return;

        var body_row: u32 = 0;
        var body_height = content_h;

        if (self.searchable) {
            // Row 0: search input "/ query_text"
            const prompt = "/ ";
            const prompt_w: u32 = @intCast(grapheme_mod.strWidth(prompt));
            _ = inner.writeStr(0, 0, prompt, self.theme.fg(.accent), Color.default, .{});
            if (self.query_len > 0) {
                _ = inner.writeStr(prompt_w, 0, self.query_buf[0..self.query_len], self.theme.fg(.text), Color.default, .{});
            } else if (self.search_placeholder) |placeholder| {
                _ = inner.writeStr(prompt_w, 0, placeholder, self.theme.fg(.muted), Color.default, .{ .dim = true });
            }
            if (content_h > 1) {
                var col: u32 = 0;
                while (col < inner.width) : (col += 1) {
                    inner.set(col, 1, .{ .grapheme = .{ .codepoint = 0x2500 }, .fg = self.theme.fg(.border_muted) }); // ─
                }
            }
            body_row = 2;
            body_height = content_h -| 2;
        }

        if (self.status) |status| {
            if (body_height > 0) {
                const color = switch (status.kind) {
                    .info => self.theme.fg(.muted),
                    .loading => self.theme.fg(.accent),
                    .@"error" => self.theme.fg(.@"error"),
                };
                _ = inner.writeStr(0, body_row, status.text, color, Color.default, .{ .dim = status.kind == .info });
                body_row += 1;
                body_height -|= 1;
            }
        }

        if (body_height > 0) {
            const list_region = inner.sub(0, body_row, inner.width, body_height);
            self.list.render(list_region);
        }
    }

    pub fn handleInput(self: *ListPicker, key: Key) bool {
        // Text editing → filter (search mode only)
        if (self.searchable) {
            if (key.code == .char and !key.ctrl and !key.alt) {
                if (key.char) |cp| {
                    if (self.query_len < MAX_QUERY) {
                        var utf8_buf: [4]u8 = undefined;
                        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return true;
                        if (self.query_len + len <= MAX_QUERY) {
                            @memcpy(self.query_buf[self.query_len..][0..len], utf8_buf[0..len]);
                            self.query_len += len;
                            self.applyFilter();
                        }
                    }
                }
                return true;
            }
            if (key.code == .backspace and !key.ctrl and !key.alt) {
                if (self.query_len > 0) {
                    // Remove last UTF-8 char
                    var i = self.query_len - 1;
                    while (i > 0 and (self.query_buf[i] & 0xC0) == 0x80) : (i -= 1) {}
                    self.query_len = i;
                    self.applyFilter();
                }
                return true;
            }
        }

        // Navigation/action → SelectList
        const result = self.list.processInput(key);
        switch (result) {
            .selected => {
                if (self.list.getSelectedItem()) |item| {
                    const source_index = self.selectedSourceIndex() orelse unreachable;
                    if (self.on_select) |cb| cb(.{ .item = item, .source_index = source_index }, self.callback_ctx);
                }
                return true;
            },
            .cancelled => {
                if (self.on_cancel) |cb| cb(self.callback_ctx);
                return true;
            },
            .consumed => {
                self.syncPreferredSelection();
                return true;
            },
            .unhandled => return false,
        }
    }

    pub fn measure(self: *ListPicker, width: u32) Measurement {
        const inner_w = if (width > 2) width - 2 else 1;
        const inner_m = self.list.measure(inner_w);
        const search_rows: u32 = if (self.searchable) 2 else 0; // input + separator
        const status_rows: u32 = if (self.status != null) 1 else 0;
        return .{
            .min_height = 3,
            .preferred_height = inner_m.preferred_height + 2 + search_rows + status_rows, // +2 borders
        };
    }

    pub fn cursorState(self: *ListPicker) ?CursorState {
        if (!self.focused or !self.searchable) return null;
        const prompt_w: u32 = @intCast(grapheme_mod.strWidth("/ "));
        const query_w: u32 = @intCast(grapheme_mod.strWidth(self.query_buf[0..self.query_len]));
        return .{
            .x = 1 + prompt_w + query_w, // 1 for left border
            .y = 1, // first content row
            .style = .bar,
        };
    }

    pub fn setFocused(self: *ListPicker, f: bool) void {
        self.focused = f;
    }

    pub fn component(self: *ListPicker) Component {
        return Component.init(ListPicker, self);
    }

    // ── Internal ────────────────────────────────────────────────

    fn applyFilter(self: *ListPicker) void {
        const count = @min(self.all_items.len, MAX_ITEMS);
        if (count == 0) {
            self.filtered_count = 0;
            self.list.setItems(&.{});
            return;
        }

        const query = self.query_buf[0..self.query_len];

        if (query.len == 0) {
            // No filter — preserve caller order. Some pickers pre-sort items
            // intentionally (for example /resume wants most-recent-first), and
            // empty-query fuzzy sorting would scramble that ordering.
            for (0..count) |i| {
                self.filtered_source_indices[i] = i;
                self.filtered_buf[i] = self.all_items[i];
            }
            self.filtered_count = count;
        } else {
            var texts: [MAX_ITEMS][]const u8 = undefined;
            for (0..count) |i| {
                texts[i] = self.getSearchText(i);
            }
            const n = search.plain.filter(query, texts[0..count], &self.match_indices);
            for (0..n) |i| {
                const source_index = self.match_indices[i];
                self.filtered_source_indices[i] = source_index;
                self.filtered_buf[i] = self.all_items[source_index];
            }
            self.filtered_count = n;
        }

        self.list.setItems(self.filtered_buf[0..self.filtered_count]);
        self.applyPreferredSelection();
    }

    fn getSearchText(self: *const ListPicker, idx: usize) []const u8 {
        if (self.search_texts) |texts| {
            if (idx < texts.len) return texts[idx];
        }
        if (idx < self.all_items.len) return self.all_items[idx].label;
        return "";
    }

    fn selectedSourceIndex(self: *const ListPicker) ?usize {
        if (self.list.items.len == 0) return null;
        const selected_index: usize = @intCast(self.list.selected_index);
        if (!self.searchable) return selected_index;
        if (selected_index >= self.filtered_count) return null;
        return self.filtered_source_indices[selected_index];
    }

    fn applyPreferredSelection(self: *ListPicker) void {
        if (self.preferred_selection_value) |value| {
            if (self.list.setSelectedByValue(value)) return;
        }

        if (self.pending_selection_index) |index| {
            if (self.searchable) {
                if (index < self.all_items.len) {
                    self.preferred_selection_value = self.all_items[index].value;
                    if (self.list.setSelectedByValue(self.all_items[index].value)) {
                        self.pending_selection_index = null;
                        return;
                    }
                }
            } else {
                self.list.setSelectedIndexClamped(index);
                self.pending_selection_index = null;
                self.syncPreferredSelection();
            }
        }
    }

    fn syncPreferredSelection(self: *ListPicker) void {
        if (self.list.selectedValue()) |value| {
            self.preferred_selection_value = value;
            self.pending_selection_index = null;
        }
    }
};

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

const SelectionCapture = struct {
    source_index: ?usize = null,
    value: ?[]const u8 = null,
};

fn captureSelection(selection: Selection, ctx: ?*anyopaque) void {
    const capture: *SelectionCapture = @ptrCast(@alignCast(ctx));
    capture.source_index = selection.source_index;
    capture.value = selection.item.value;
}

test "searchable picker selection reports original source index" {
    const theme = Theme.dark;
    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };
    const search_texts = [_][]const u8{ "resume alpha", "resume beta", "resume gamma" };

    var picker = ListPicker.init(&theme);
    var capture = SelectionCapture{};
    picker.setSearchableItems(&items, &search_texts);
    picker.on_select = &captureSelection;
    picker.callback_ctx = @ptrCast(&capture);

    _ = picker.handleInput(.{ .code = .char, .char = 'g' });
    _ = picker.handleInput(.{ .code = .enter });

    try testing.expectEqual(@as(?usize, 2), capture.source_index);
    try testing.expectEqualStrings("gamma", capture.value.?);
}

test "searchable picker preserves selected value across filter changes" {
    const theme = Theme.dark;
    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };
    const search_texts = [_][]const u8{ "resume alpha", "resume beta", "resume gamma" };

    var picker = ListPicker.init(&theme);
    picker.setSearchableItems(&items, &search_texts);
    picker.setInitialSelectionByValue("beta");

    try testing.expectEqualStrings("beta", picker.list.selectedValue().?);

    _ = picker.handleInput(.{ .code = .char, .char = 'g' });
    try testing.expectEqualStrings("gamma", picker.list.selectedValue().?);

    _ = picker.handleInput(.{ .code = .backspace });
    try testing.expectEqualStrings("beta", picker.list.selectedValue().?);
}

test "picker initial selection index and status affect list behavior and measurement" {
    const theme = Theme.dark;
    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };

    var picker = ListPicker.init(&theme);
    picker.setSearchPlaceholder("Search models");
    picker.setEmptyText("No models found");
    picker.setStatus(.{ .text = "Loading models", .kind = .loading });
    picker.setItems(&items);
    picker.setInitialSelectionIndex(2);

    try testing.expectEqualStrings("gamma", picker.list.selectedValue().?);
    try testing.expectEqual(@as(u32, 6), picker.measure(40).preferred_height);
}

test "searchable picker renders placeholder status and custom empty text" {
    const theme = Theme.dark;
    var picker = ListPicker.init(&theme);
    picker.title = "Models";
    picker.setSearchPlaceholder("Search models");
    picker.setEmptyText("No models found");
    picker.setStatus(.{ .text = "Loading models", .kind = .loading });
    picker.setSearchableItems(&.{}, null);

    var buf = try Buffer.init(testing.allocator, 40, 8);
    defer buf.deinit();

    picker.render(buf.region());

    try testing.expectEqual(@as(u21, 'S'), buf.get(3, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'L'), buf.get(1, 3).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'N'), buf.get(3, 4).grapheme.codepoint);
}

test "plain picker selection reports visible source index" {
    const theme = Theme.dark;
    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };

    var picker = ListPicker.init(&theme);
    var capture = SelectionCapture{};
    picker.setItems(&items);
    picker.on_select = &captureSelection;
    picker.callback_ctx = @ptrCast(&capture);

    _ = picker.handleInput(.{ .code = .down });
    _ = picker.handleInput(.{ .code = .enter });

    try testing.expectEqual(@as(?usize, 1), capture.source_index);
    try testing.expectEqualStrings("beta", capture.value.?);
}
