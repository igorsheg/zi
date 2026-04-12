const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const word_wrap_mod = @import("../word_wrap.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const grapheme = @import("../grapheme.zig");
const Line = word_wrap_mod.Line;

/// Styled text with word wrapping, padding, and scroll support.
///
/// Wraps content at word boundaries when rendering into a Region.
/// Supports horizontal/vertical padding (matching pi-mono's Text component).
/// When content exceeds the visible area, `scroll_offset` controls which
/// wrapped lines are visible. Call `scrollToBottom` after updating content
/// to auto-follow streaming output.
pub const Text = struct {
    content: []const u8 = "",
    fg: Color = Color.default,
    bg: Color = Color.default,
    attrs: Attributes = .{},
    padding_x: u32 = 0,
    padding_y: u32 = 0,
    scroll_offset: u32 = 0,
    allocator: std.mem.Allocator,

    /// Owned content buffer — setContent copies into this so callers
    /// don't need to keep the source alive.
    content_buf: std.ArrayListUnmanaged(u8) = .empty,

    // wrap cache — invalidated on content or width change
    cached_lines: ?[]Line = null,
    cached_width: u32 = 0,
    cached_content_ptr: ?[*]const u8 = null,
    cached_content_len: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Text {
        return .{ .allocator = allocator };
    }

    pub fn setContent(self: *Text, text: []const u8) void {
        self.content_buf.clearRetainingCapacity();
        self.content_buf.appendSlice(self.allocator, text) catch return;
        self.content = self.content_buf.items;
        self.invalidateCache();
    }

    pub fn setPadding(self: *Text, x: u32, y: u32) void {
        self.padding_x = x;
        self.padding_y = y;
        self.invalidateCache();
    }

    /// Scroll so the last wrapped line is visible at the bottom of the region.
    /// Call after setContent during streaming to auto-follow.
    pub fn scrollToBottom(self: *Text, visible_height: u32) void {
        const total = self.totalLines(visible_height);
        if (total > visible_height) {
            self.scroll_offset = @intCast(total - visible_height);
        } else {
            self.scroll_offset = 0;
        }
    }

    /// Total lines this text would occupy (wrapped lines + padding).
    pub fn totalLines(self: *Text, visible_width: u32) u32 {
        const m = self.measure(visible_width);
        return m.preferred_height;
    }

    pub fn render(self: *Text, region: Region) void {
        self.renderSlice(region, 0);
    }

    pub fn renderSlice(self: *Text, region: Region, first_row: u32) void {
        if (self.content.len == 0) return;

        const w = region.width;
        const h = region.height;
        if (w == 0 or h == 0) return;

        const content_width = if (w > self.padding_x * 2) w - self.padding_x * 2 else 1;
        const lines = self.getWrappedLines(content_width) orelse return;

        if (!self.bg.eql(Color.default)) {
            region.fill(0, 0, w, h, .{
                .grapheme = .{ .codepoint = ' ' },
                .fg = self.fg,
                .bg = self.bg,
            });
        }

        const pad_y = self.padding_y;
        var row: u32 = 0;
        var virtual_row: u32 = self.scroll_offset + first_row;

        while (row < h) {
            if (virtual_row < pad_y) {
                virtual_row += 1;
                row += 1;
                continue;
            }

            const line_idx = virtual_row - pad_y;
            if (line_idx >= lines.len) break;

            const line = lines[line_idx];
            const line_text = line.text(self.content);
            if (line_text.len > 0) {
                _ = region.writeStr(self.padding_x, row, line_text, self.fg, self.bg, self.attrs);
            }

            row += 1;
            virtual_row += 1;
        }
    }

    pub fn measure(self: *Text, width: u32) Measurement {
        if (self.content.len == 0) return .{ .min_height = 0, .preferred_height = 0 };
        if (width == 0) return .{ .min_height = 1, .preferred_height = 1 };

        const content_width = if (width > self.padding_x * 2) width - self.padding_x * 2 else 1;
        const lines = self.getWrappedLines(content_width) orelse
            return .{ .min_height = 1, .preferred_height = 1 };

        const line_count: u32 = @intCast(lines.len);
        const total = line_count + self.padding_y * 2;
        return .{ .min_height = 1, .preferred_height = total };
    }

    pub fn component(self: *Text) Component {
        return Component.init(Text, self);
    }

    // --- cache management ---

    fn getWrappedLines(self: *Text, content_width: u32) ?[]Line {
        // check cache
        if (self.cached_lines) |cached| {
            if (self.cached_width == content_width and
                self.cached_content_ptr == self.content.ptr and
                self.cached_content_len == self.content.len)
            {
                return cached;
            }
            // cache miss — free old
            self.allocator.free(cached);
            self.cached_lines = null;
        }

        const lines = word_wrap_mod.wordWrap(self.content, content_width, self.allocator) catch return null;
        self.cached_lines = lines;
        self.cached_width = content_width;
        self.cached_content_ptr = self.content.ptr;
        self.cached_content_len = self.content.len;
        return lines;
    }

    fn invalidateCache(self: *Text) void {
        if (self.cached_lines) |cached| {
            self.allocator.free(cached);
            self.cached_lines = null;
        }
    }

    pub fn deinit(self: *Text) void {
        self.content_buf.deinit(self.allocator);
        self.invalidateCache();
    }
};

// --- tests ---

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "Text wraps content across multiple rows" {
    var buf = try Buffer.init(testing.allocator, 10, 5);
    defer buf.deinit();

    var text = Text.init(testing.allocator);
    defer text.deinit();
    text.content = "hello world how are you";
    text.fg = Color.rgb(255, 255, 255);
    text.render(buf.region());

    // "hello" on row 0, "world how" on row 1, "are you" on row 2
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'w'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'a'), buf.get(0, 2).grapheme.codepoint);
}

test "Text measure returns accurate wrapped line count" {
    var text = Text.init(testing.allocator);
    defer text.deinit();
    text.content = "hello world";

    // at width 5: "hello" + "world" = 2 lines
    try testing.expectEqual(@as(u32, 2), text.measure(5).preferred_height);

    // at width 20: fits on one line
    try testing.expectEqual(@as(u32, 1), text.measure(20).preferred_height);

    // with padding
    text.padding_y = 1;
    try testing.expectEqual(@as(u32, 4), text.measure(5).preferred_height); // 1+2+1

    // empty
    var empty = Text.init(testing.allocator);
    defer empty.deinit();
    try testing.expectEqual(@as(u32, 0), empty.measure(10).preferred_height);
}

test "Text scroll_offset skips top lines" {
    var buf = try Buffer.init(testing.allocator, 10, 2);
    defer buf.deinit();

    var text = Text.init(testing.allocator);
    defer text.deinit();
    text.content = "aaa bbb ccc ddd";
    // at width 10: "aaa bbb" + "ccc ddd" = 2 lines, but let's force narrower
    // at width 4: "aaa" / "bbb" / "ccc" / "ddd" = 4 lines
    // Actually let's be more explicit
    text.content = "aa bb cc dd";

    // width=3 → "aa" / "bb" / "cc" / "dd" (4 wrapped lines)
    // buffer is 3×2, scroll_offset=2 → shows "cc" and "dd"
    var small_buf = try Buffer.init(testing.allocator, 3, 2);
    defer small_buf.deinit();

    text.scroll_offset = 2;
    text.render(small_buf.region());

    try testing.expectEqual(@as(u21, 'c'), small_buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'd'), small_buf.get(0, 1).grapheme.codepoint);
}
