const std = @import("std");
const component_mod = @import("../component.zig");
const buffer_mod = @import("../buffer.zig");
const keys_mod = @import("../keys.zig");
const select_list_mod = @import("select_list.zig");
const theme_mod = @import("../theme.zig");
const box_chrome = @import("../box_chrome.zig");
const grapheme_mod = @import("../grapheme.zig");
const cell_mod = @import("../cell.zig");
const fuzzy_mod = @import("../fuzzy.zig");

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

const MAX_ITEMS = 256;
const MAX_QUERY = 128;

/// Modal list picker — wraps SelectList as a Component for use in the overlay stack.
/// Renders a bordered box with optional title, optional search input, and the select list.
/// Reports selection/cancellation via callbacks.
///
/// When `searchable` is true, printable characters and backspace filter the list
/// using fuzzy matching. The original (unfiltered) items are borrowed from the caller;
/// the filtered view is managed internally.
pub const ListPicker = struct {
    list: SelectList,
    title: []const u8 = "",
    theme: *const Theme,
    on_select: ?*const fn (item: *const SelectItem, ctx: ?*anyopaque) void = null,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void = null,
    callback_ctx: ?*anyopaque = null,
    focused: bool = false,

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
    pub fn setSearchableItems(
        self: *ListPicker,
        items: []const SelectItem,
        search_texts: ?[]const []const u8,
    ) void {
        self.searchable = true;
        self.all_items = items;
        self.search_texts = search_texts;
        self.query_len = 0;
        self.applyFilter();
    }

    // ── Component interface ──────────────────────────────────────

    pub fn render(self: *ListPicker, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w < 4 or h < 3) return;

        const border_color = self.theme.fg(.border);
        const style = box_chrome.Style{ .chrome = border_color, .fg = border_color, .dim = border_color };

        // Top border with title
        _ = box_chrome.drawClosedTop(region, 0, if (self.title.len > 0) self.title else null, null, style);
        // Bottom border
        _ = box_chrome.drawClosedBottom(region, h - 1, style);

        // Side borders on all content rows
        const content_h = h -| 2;
        if (content_h > 0) {
            var row: u32 = 0;
            while (row < content_h) : (row += 1) {
                _ = box_chrome.drawClosedContentPrefix(region, row + 1, style);
                if (w > 1) {
                    region.set(w - 1, row + 1, .{ .grapheme = .{ .codepoint = 0x2502 }, .fg = border_color });
                }
            }
        }

        if (content_h == 0 or w <= 3) return;
        const inner_w = w - 2;

        if (self.searchable) {
            // Row 1: search input "/ query_text"
            const prompt = "/ ";
            const prompt_w: u32 = @intCast(grapheme_mod.strWidth(prompt));
            _ = region.writeStr(1, 1, prompt, self.theme.fg(.accent), Color.default, .{});
            if (self.query_len > 0) {
                _ = region.writeStr(1 + prompt_w, 1, self.query_buf[0..self.query_len], self.theme.fg(.text), Color.default, .{});
            }
            // Separator line
            if (content_h > 1) {
                var col: u32 = 1;
                while (col < w - 1) : (col += 1) {
                    region.set(col, 2, .{ .grapheme = .{ .codepoint = 0x2500 }, .fg = self.theme.fg(.border_muted) }); // ─
                }
            }
            // List below separator
            if (content_h > 2) {
                const list_region = region.sub(1, 3, inner_w, content_h - 2);
                self.list.render(list_region);
            }
        } else {
            // No search — list fills entire content area
            const inner = region.sub(1, 1, inner_w, content_h);
            self.list.render(inner);
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
                    if (self.on_select) |cb| cb(item, self.callback_ctx);
                }
                return true;
            },
            .cancelled => {
                if (self.on_cancel) |cb| cb(self.callback_ctx);
                return true;
            },
            .consumed => return true,
            .unhandled => return false,
        }
    }

    pub fn measure(self: *ListPicker, width: u32) Measurement {
        const inner_w = if (width > 2) width - 2 else 1;
        const inner_m = self.list.measure(inner_w);
        const search_rows: u32 = if (self.searchable) 2 else 0; // input + separator
        return .{
            .min_height = 3,
            .preferred_height = inner_m.preferred_height + 2 + search_rows, // +2 borders
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
            // No filter — show all items (fuzzyFilter handles alphabetical sort)
            var texts: [MAX_ITEMS][]const u8 = undefined;
            for (0..count) |i| {
                texts[i] = self.getSearchText(i);
            }
            const n = fuzzy_mod.fuzzyFilter("", texts[0..count], &self.match_indices);
            for (0..n) |i| {
                self.filtered_buf[i] = self.all_items[self.match_indices[i]];
            }
            self.filtered_count = n;
        } else {
            var texts: [MAX_ITEMS][]const u8 = undefined;
            for (0..count) |i| {
                texts[i] = self.getSearchText(i);
            }
            const n = fuzzy_mod.fuzzyFilter(query, texts[0..count], &self.match_indices);
            for (0..n) |i| {
                self.filtered_buf[i] = self.all_items[self.match_indices[i]];
            }
            self.filtered_count = n;
        }

        self.list.setItems(self.filtered_buf[0..self.filtered_count]);
    }

    fn getSearchText(self: *const ListPicker, idx: usize) []const u8 {
        if (self.search_texts) |texts| {
            if (idx < texts.len) return texts[idx];
        }
        if (idx < self.all_items.len) return self.all_items[idx].label;
        return "";
    }
};
