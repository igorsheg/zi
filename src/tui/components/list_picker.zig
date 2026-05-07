const std = @import("std");
const component_mod = @import("../primitives/view.zig");
const buffer_mod = @import("../primitives/surface.zig");
const keys_mod = @import("../terminal/keys.zig");
const select_list_mod = @import("select_list.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const panel_mod = @import("panel.zig");
const search_input_mod = @import("search_input.zig");
const status_text_mod = @import("status_text.zig");
const search = @import("../../search/root.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Region = buffer_mod.Region;
const Key = keys_mod.Key;
const SelectList = select_list_mod.SelectList;
const SelectItem = select_list_mod.SelectItem;
const InputResult = select_list_mod.InputResult;
const SearchInput = search_input_mod.SearchInput;
const StatusText = status_text_mod.StatusText;
const Theme = theme_mod.Theme;

const MAX_ITEMS = 512;
const MAX_QUERY = 128;

/// Modal picker surface composed from Panel, SearchInput, StatusText, and SelectList.
///
/// Filtering/selection bookkeeping lives in PickerState; this view wires state to
/// primitives and reports selection/cancellation via callbacks.
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

/// Query/filter/selection bookkeeping for picker-like surfaces.
///
/// It owns no rendering primitives and borrows caller item storage. The view
/// layer decides how to present `visibleItems()`.
pub const PickerState = struct {
    searchable: bool = false,
    all_items: []const SelectItem = &.{},
    search_texts: ?[]const []const u8 = null,
    query_buf: [MAX_QUERY]u8 = undefined,
    query_len: usize = 0,
    match_indices: [MAX_ITEMS]usize = undefined,
    filtered_source_indices: [MAX_ITEMS]usize = undefined,
    filtered_buf: [MAX_ITEMS]SelectItem = undefined,
    filtered_count: usize = 0,
    preferred_selection_value: ?[]const u8 = null,
    pending_selection_index: ?usize = null,

    pub fn setItems(self: *PickerState, items: []const SelectItem) []const SelectItem {
        self.searchable = false;
        self.all_items = items;
        self.search_texts = null;
        self.query_len = 0;
        self.filtered_count = 0;
        return items;
    }

    pub fn setSearchableItems(self: *PickerState, items: []const SelectItem, search_texts: ?[]const []const u8) []const SelectItem {
        self.searchable = true;
        self.all_items = items;
        self.search_texts = search_texts;
        self.query_len = 0;
        self.applyFilter();
        return self.visibleItems();
    }

    pub fn query(self: *const PickerState) []const u8 {
        return self.query_buf[0..self.query_len];
    }

    pub fn visibleItems(self: *const PickerState) []const SelectItem {
        return if (self.searchable) self.filtered_buf[0..self.filtered_count] else self.all_items;
    }

    pub fn appendCodepoint(self: *PickerState, cp: u21) bool {
        if (self.query_len >= MAX_QUERY) return false;
        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return false;
        if (self.query_len + len > MAX_QUERY) return false;
        @memcpy(self.query_buf[self.query_len..][0..len], utf8_buf[0..len]);
        self.query_len += len;
        self.applyFilter();
        return true;
    }

    pub fn backspace(self: *PickerState) bool {
        if (self.query_len == 0) return false;
        var i = self.query_len - 1;
        while (i > 0 and (self.query_buf[i] & 0b1100_0000) == 0b1000_0000) : (i -= 1) {}
        self.query_len = i;
        self.applyFilter();
        return true;
    }

    pub fn setInitialSelectionByValue(self: *PickerState, value: []const u8) void {
        self.preferred_selection_value = value;
        self.pending_selection_index = null;
    }

    pub fn setInitialSelectionIndex(self: *PickerState, index: usize) void {
        self.pending_selection_index = index;
    }

    pub fn selectedSourceIndex(self: *const PickerState, selected_index: usize) ?usize {
        if (!self.searchable) return selected_index;
        if (selected_index >= self.filtered_count) return null;
        return self.filtered_source_indices[selected_index];
    }

    pub fn syncPreferredSelection(self: *PickerState, selected_value: ?[]const u8) void {
        if (selected_value) |value| {
            self.preferred_selection_value = value;
            self.pending_selection_index = null;
        }
    }

    pub fn applyPreferredSelection(self: *PickerState, list: *SelectList) void {
        if (self.preferred_selection_value) |value| {
            if (list.setSelectedByValue(value)) return;
        }

        if (self.pending_selection_index) |index| {
            if (self.searchable) {
                if (index < self.all_items.len) {
                    self.preferred_selection_value = self.all_items[index].value;
                    if (list.setSelectedByValue(self.all_items[index].value)) {
                        self.pending_selection_index = null;
                        return;
                    }
                }
            } else {
                list.setSelectedIndexClamped(index);
                self.pending_selection_index = null;
                self.syncPreferredSelection(list.selectedValue());
            }
        }
    }

    fn applyFilter(self: *PickerState) void {
        const count = @min(self.all_items.len, MAX_ITEMS);
        if (count == 0) {
            self.filtered_count = 0;
            return;
        }

        const q = self.query();
        if (q.len == 0) {
            for (0..count) |i| {
                self.filtered_source_indices[i] = i;
                self.filtered_buf[i] = self.all_items[i];
            }
            self.filtered_count = count;
        } else {
            var field_storage: [MAX_ITEMS][3]search.plain.Field = undefined;
            var rows: [MAX_ITEMS][]const search.plain.Field = undefined;
            for (0..count) |i| rows[i] = self.searchFieldsFor(i, &field_storage[i]);
            const n = search.plain.filterFields(q, rows[0..count], &self.match_indices);
            for (0..n) |i| {
                const source_index = self.match_indices[i];
                self.filtered_source_indices[i] = source_index;
                self.filtered_buf[i] = self.all_items[source_index];
            }
            self.filtered_count = n;
        }
    }

    fn getSearchText(self: *const PickerState, idx: usize) []const u8 {
        if (self.search_texts) |texts| if (idx < texts.len) return texts[idx];
        if (idx < self.all_items.len) return self.all_items[idx].label;
        return "";
    }

    fn searchFieldsFor(self: *const PickerState, idx: usize, storage: *[3]search.plain.Field) []const search.plain.Field {
        if (idx >= self.all_items.len) return &.{};
        const item = self.all_items[idx];
        var n: usize = 0;
        storage[n] = .{ .name = "label", .text = item.label, .weight = 24 };
        n += 1;
        const search_text = self.getSearchText(idx);
        if (!std.mem.eql(u8, search_text, item.label)) {
            storage[n] = .{ .name = "search", .text = search_text, .weight = 12 };
            n += 1;
        }
        if (item.description) |description| {
            storage[n] = .{ .name = "description", .text = description, .weight = -8 };
            n += 1;
        }
        return storage[0..n];
    }
};

pub const ListPicker = struct {
    state: PickerState = .{},
    list: SelectList,
    search_input: SearchInput,
    status_text: StatusText,
    title: []const u8 = "",
    theme: *const Theme,
    on_select: ?*const fn (selection: Selection, ctx: ?*anyopaque) void = null,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    focused: bool = false,
    search_placeholder: ?[]const u8 = null,
    empty_text: []const u8 = "No matching commands",
    status: ?Status = null,
    pub fn init(theme: *const Theme) ListPicker {
        return .{
            .list = .{ .theme = theme },
            .search_input = SearchInput.init(theme),
            .status_text = StatusText.init(theme),
            .theme = theme,
        };
    }

    /// Set items and enable search. Caller owns `items` memory.
    /// `search_texts` is optional — if null, search matches on item.label.
    pub fn setItems(self: *ListPicker, items: []const SelectItem) void {
        self.list.empty_text = self.empty_text;
        self.list.setItems(self.state.setItems(items));
        self.state.applyPreferredSelection(&self.list);
    }

    pub fn setSearchableItems(
        self: *ListPicker,
        items: []const SelectItem,
        search_texts: ?[]const []const u8,
    ) void {
        self.list.empty_text = self.empty_text;
        self.list.setItems(self.state.setSearchableItems(items, search_texts));
        self.state.applyPreferredSelection(&self.list);
    }

    pub fn setSearchPlaceholder(self: *ListPicker, text: ?[]const u8) void {
        self.search_placeholder = text;
        self.search_input.placeholder = text;
    }

    pub fn setEmptyText(self: *ListPicker, text: []const u8) void {
        self.empty_text = text;
        self.list.empty_text = text;
    }

    pub fn setStatus(self: *ListPicker, status: ?Status) void {
        self.status = status;
        self.syncStatusText();
    }

    pub fn setInitialSelectionByValue(self: *ListPicker, value: []const u8) void {
        self.state.setInitialSelectionByValue(value);
        self.state.applyPreferredSelection(&self.list);
    }

    pub fn setInitialSelectionIndex(self: *ListPicker, index: usize) void {
        self.state.setInitialSelectionIndex(index);
        self.state.applyPreferredSelection(&self.list);
    }

    pub fn render(self: *ListPicker, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 4 or h < 3) return;

        const panel = panel_mod.Panel.themed(self.theme, if (self.title.len > 0) self.title else null);
        const panel_layout = panel.render(region) orelse return;
        const inner = panel_layout.body;
        const content_h = inner.height;

        if (content_h == 0 or inner.width == 0) return;

        var body_row: u32 = 0;
        var body_height = content_h;

        if (self.state.searchable) {
            self.syncSearchInput();
            self.search_input.render(inner.sub(0, 0, inner.width, 1));
            if (content_h > 1) {
                var col: u32 = 0;
                while (col < inner.width) : (col += 1) {
                    inner.set(col, 1, .{ .grapheme = .{ .codepoint = 0x2500 }, .fg = self.theme.fg(.border_muted) });
                }
            }
            body_row = 2;
            body_height = content_h -| 2;
        }

        if (self.status != null) {
            if (body_height > 0) {
                self.syncStatusText();
                self.status_text.render(inner.sub(0, body_row, inner.width, 1));
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
        if (self.state.searchable) {
            if (key.code == .char and !key.ctrl and !key.alt) {
                if (key.char) |cp| {
                    _ = self.state.appendCodepoint(cp);
                    self.list.setItems(self.state.visibleItems());
                    self.state.applyPreferredSelection(&self.list);
                }
                return true;
            }
            if (key.code == .backspace and !key.ctrl and !key.alt) {
                _ = self.state.backspace();
                self.list.setItems(self.state.visibleItems());
                self.state.applyPreferredSelection(&self.list);
                return true;
            }
        }

        const result = self.list.processInput(key);
        switch (result) {
            .selected => {
                if (self.list.getSelectedItem()) |item| {
                    const source_index = self.state.selectedSourceIndex(@intCast(self.list.selected_index)) orelse unreachable;
                    if (self.on_select) |cb| cb(.{ .item = item, .source_index = source_index }, self.callback_ctx);
                }
                return true;
            },
            .cancelled => {
                if (self.on_cancel) |cb| cb(self.callback_ctx);
                return true;
            },
            .consumed => {
                self.state.syncPreferredSelection(self.list.selectedValue());
                return true;
            },
            .unhandled => return false,
        }
    }

    pub fn measure(self: *ListPicker, width: u32) Measurement {
        const inner_w = if (width > 2) width - 2 else 1;
        const inner_m = self.list.measure(inner_w);
        const search_rows: u32 = if (self.state.searchable) 2 else 0;
        const status_rows: u32 = if (self.status != null) 1 else 0;
        return .{
            .min_height = 3,
            .preferred_height = inner_m.preferred_height + 2 + search_rows + status_rows,
        };
    }

    pub fn cursorState(self: *ListPicker) ?CursorState {
        if (!self.focused or !self.state.searchable) return null;
        self.syncSearchInput();
        const cs = self.search_input.cursorState() orelse return null;
        return .{ .x = 1 + cs.x, .y = 1 + cs.y, .style = cs.style };
    }

    pub fn setFocused(self: *ListPicker, f: bool) void {
        self.focused = f;
        self.search_input.setFocused(f and self.state.searchable);
    }

    pub fn component(self: *ListPicker) Component {
        return Component.init(ListPicker, self);
    }

    fn syncSearchInput(self: *ListPicker) void {
        self.search_input.placeholder = self.search_placeholder;
        self.search_input.setText(self.state.query());
        self.search_input.setFocused(self.focused and self.state.searchable);
    }

    fn syncStatusText(self: *ListPicker) void {
        if (self.status) |status| {
            self.status_text.set(status.text, switch (status.kind) {
                .info => .info,
                .loading => .loading,
                .@"error" => .@"error",
            });
        } else {
            self.status_text.clear();
        }
    }
};

const testing = std.testing;

const SelectionCapture = struct {
    source_index: ?usize = null,
    value: ?[]const u8 = null,
    cancelled: bool = false,
};

fn captureSelection(selection: Selection, ctx: ?*anyopaque) void {
    const capture: *SelectionCapture = @ptrCast(@alignCast(ctx));
    capture.source_index = selection.source_index;
    capture.value = selection.item.value;
}

fn captureCancel(ctx: ?*anyopaque) void {
    const capture: *SelectionCapture = @ptrCast(@alignCast(ctx));
    capture.cancelled = true;
}

fn testTheme() Theme {
    return themes_builtin.dark().*;
}

fn pickerItems() [3]SelectItem {
    return .{
        .{ .value = "alpha", .label = "Alpha" },
        .{ .value = "beta", .label = "Beta" },
        .{ .value = "gamma", .label = "Gamma" },
    };
}

test "plain picker navigates and reports visible source index" {
    const theme = testTheme();
    var items = pickerItems();

    var picker = ListPicker.init(&theme);
    var capture = SelectionCapture{};
    picker.setItems(&items);
    picker.on_select = &captureSelection;
    picker.callback_ctx = @ptrCast(&capture);

    try testing.expectEqual(@as(u32, 0), picker.list.selected_index);
    try testing.expect(picker.handleInput(.{ .code = .up }));
    try testing.expectEqualStrings("gamma", picker.list.selectedValue().?);
    try testing.expect(picker.handleInput(.{ .code = .home }));
    try testing.expect(picker.handleInput(.{ .code = .down }));
    try testing.expect(picker.handleInput(.{ .code = .enter }));

    try testing.expectEqual(@as(?usize, 1), capture.source_index);
    try testing.expectEqualStrings("beta", capture.value.?);
}

test "searchable picker filters and reports original source index" {
    const theme = testTheme();
    var items = pickerItems();
    const search_texts = [_][]const u8{ "resume alpha", "resume beta", "resume gamma" };

    var picker = ListPicker.init(&theme);
    var capture = SelectionCapture{};
    picker.setSearchableItems(&items, &search_texts);
    picker.on_select = &captureSelection;
    picker.callback_ctx = @ptrCast(&capture);

    try testing.expect(picker.handleInput(.{ .code = .char, .char = 'g' }));
    try testing.expectEqualStrings("gamma", picker.list.selectedValue().?);
    try testing.expect(picker.handleInput(.{ .code = .enter }));

    try testing.expectEqual(@as(?usize, 2), capture.source_index);
    try testing.expectEqualStrings("gamma", capture.value.?);
}

test "searchable picker preserves selected value across filter changes" {
    const theme = testTheme();
    var items = pickerItems();
    const search_texts = [_][]const u8{ "resume alpha", "resume beta", "resume gamma" };

    var picker = ListPicker.init(&theme);
    picker.setSearchableItems(&items, &search_texts);
    picker.setInitialSelectionByValue("beta");

    try testing.expectEqualStrings("beta", picker.list.selectedValue().?);

    try testing.expect(picker.handleInput(.{ .code = .char, .char = 'g' }));
    try testing.expectEqualStrings("gamma", picker.list.selectedValue().?);

    try testing.expect(picker.handleInput(.{ .code = .backspace }));
    try testing.expectEqualStrings("beta", picker.list.selectedValue().?);
}
