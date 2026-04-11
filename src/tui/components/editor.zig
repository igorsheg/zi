const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const keys_mod = @import("../keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const word_wrap_mod = @import("../word_wrap.zig");
const box_chrome = @import("../box_chrome.zig");
const status_data_mod = @import("../status_data.zig");
const autocomplete_mod = @import("../autocomplete.zig");
const select_list_mod = @import("select_list.zig");
const theme_mod = @import("../theme.zig");

const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Key = keys_mod.Key;
const StatusData = status_data_mod.StatusData;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const Suggestions = autocomplete_mod.Suggestions;
const SuggestionSink = autocomplete_mod.SuggestionSink;
const RequestSnapshot = autocomplete_mod.RequestSnapshot;
const SelectItem = select_list_mod.SelectItem;
const SelectList = select_list_mod.SelectList;
const InputResult = select_list_mod.InputResult;
const Theme = theme_mod.Theme;

pub const Editor = struct {
    buf: std.ArrayList(u8),
    cursor_byte: u32 = 0,
    cursor_col: u32 = 0,
    scroll_x: u32 = 0,
    scroll_y: u32 = 0,
    max_visible_lines: u32 = 10,
    last_content_width: u32 = 80,
    prompt: []const u8 = "> ",
    on_submit: ?*const fn (text: []const u8, ctx: ?*anyopaque) void = null,
    on_submit_ctx: ?*anyopaque = null,
    prompt_fg: Color = Color.rgb(100, 100, 100),
    text_fg: Color = Color.default,
    border_color: Color = Color.rgb(0x50, 0x50, 0x50),
    status_data: ?*const StatusData = null,
    /// Working directory displayed in top border (borrowed, set by Interactive).
    cwd: []const u8 = "",
    /// Git branch displayed in top border (fixed buffer, set by Interactive).
    git_branch_buf: [128]u8 = undefined,
    git_branch_len: u8 = 0,
    allocator: std.mem.Allocator,
    focused: bool = true,

    // ── Autocomplete ──────────────────────────────────────────────
    autocomplete_provider: ?AutocompleteProvider = null,
    autocomplete_list: SelectList = undefined,
    autocomplete_active: bool = false,
    autocomplete_prefix_len: u32 = 0,
    sink_ctx: AutocompleteSinkCtx = .{},
    theme: ?*const Theme = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        return .{
            .buf = .empty,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *Editor) void {
        self.buf.deinit(self.allocator);
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buf.items;
    }

    pub fn clear(self: *Editor) void {
        self.buf.items.len = 0;
        self.cursor_byte = 0;
        self.cursor_col = 0;
        self.scroll_x = 0;
        self.scroll_y = 0;
    }

    pub fn setText(self: *Editor, text: []const u8) void {
        self.buf.items.len = 0;
        self.buf.appendSlice(self.allocator, text) catch return;
        self.cursor_byte = @intCast(text.len);
        const last_line_start = if (std.mem.lastIndexOfScalar(u8, text, '\n')) |pos| pos + 1 else 0;
        self.cursor_col = @intCast(grapheme_mod.strWidth(text[last_line_start..]));
        self.scroll_x = 0;
        self.ensureCursorVisible();
    }

    pub fn insertText(self: *Editor, text: []const u8) void {
        self.buf.insertSlice(self.allocator, self.cursor_byte, text) catch return;
        var i: usize = 0;
        while (i < text.len) {
            if (text[i] == '\n') {
                self.cursor_col = 0;
                i += 1;
            } else {
                const cp_len = std.unicode.utf8ByteSequenceLength(text[i]) catch 1;
                const end = @min(i + cp_len, text.len);
                const cp = std.unicode.utf8Decode(text[i..end]) catch '_';
                self.cursor_col += @as(u32, grapheme_mod.charWidth(cp));
                i = end;
            }
        }
        self.cursor_byte += @intCast(text.len);
        self.ensureCursorVisible();
    }

    // --- Autocomplete ---

    pub fn setAutocompleteProvider(self: *Editor, prov: AutocompleteProvider) void {
        self.cancelAutocomplete();
        self.autocomplete_provider = prov;
    }

    fn tryAutocomplete(self: *Editor) void {
        const prov = self.autocomplete_provider orelse return;

        if (self.buf.items.len > 0 and self.buf.items[0] == '/') {
            // Sink context lives on Editor (not stack) so async providers
            // can publish results after request() returns.
            self.sink_ctx = .{ .editor = self };
            prov.request(
                .{ .text = self.buf.items, .cursor_byte = self.cursor_byte },
                .{ .ptr = @ptrCast(&self.sink_ctx), .publish_fn = &autocompleteSinkCallback },
            );
        } else if (self.autocomplete_active) {
            self.cancelAutocomplete();
        }
    }

    const AutocompleteSinkCtx = struct {
        editor: *Editor = undefined,
    };

    fn autocompleteSinkCallback(ptr: *anyopaque, suggestions: ?Suggestions) void {
        const ctx: *AutocompleteSinkCtx = @ptrCast(@alignCast(ptr));
        const self = ctx.editor;

        if (suggestions) |s| {
            if (s.items.len > 0) {
                self.autocomplete_list = .{
                    .theme = self.theme orelse &Theme.dark,
                };
                self.autocomplete_list.setItems(s.items);
                self.autocomplete_prefix_len = @intCast(s.prefix.len);
                self.autocomplete_active = true;
                return;
            }
        }
        self.cancelAutocomplete();
    }

    fn acceptAutocomplete(self: *Editor) bool {
        const prov = self.autocomplete_provider orelse return false;
        const item = self.autocomplete_list.getSelectedItem() orelse return false;

        const prefix_len = self.autocomplete_prefix_len;
        const prefix = if (prefix_len <= self.buf.items.len) self.buf.items[0..prefix_len] else self.buf.items;
        const result = prov.apply(
            self.buf.items,
            self.cursor_byte,
            item,
            prefix,
        ) orelse return false;

        self.buf.items.len = 0;
        self.buf.appendSlice(self.allocator, result.new_text) catch return false;
        self.cursor_byte = result.new_cursor;

        const line_start = if (std.mem.lastIndexOfScalar(u8, self.buf.items[0..self.cursor_byte], '\n')) |pos| pos + 1 else 0;
        self.cursor_col = @intCast(grapheme_mod.strWidth(self.buf.items[line_start..self.cursor_byte]));

        self.cancelAutocomplete();
        return true;
    }

    pub fn cancelAutocomplete(self: *Editor) void {
        if (self.autocomplete_active) {
            if (self.autocomplete_provider) |prov| prov.cancel();
        }
        self.autocomplete_active = false;
        self.autocomplete_prefix_len = 0;
    }

    // --- Input handling ---

    pub fn handleInput(self: *Editor, key: Key) bool {
        if (!self.focused) return false;

        // Autocomplete interception — when picker is active, handle its keys first
        if (self.autocomplete_active) {
            const result = self.autocomplete_list.processInput(key);
            switch (result) {
                .selected => {
                    if (self.acceptAutocomplete()) {
                        // Apply succeeded — submit the completed command
                        if (key.code == .enter) {
                            if (self.on_submit) |cb| {
                                cb(self.buf.items, self.on_submit_ctx);
                            }
                        }
                    } else {
                        self.cancelAutocomplete();
                    }
                    return true;
                },
                .cancelled => {
                    self.cancelAutocomplete();
                    return true;
                },
                .consumed => return true,
                .unhandled => {
                    if (key.code == .tab and !key.ctrl and !key.alt) {
                        // Tab accepts the top pick without submitting
                        if (self.acceptAutocomplete()) return true;
                        self.cancelAutocomplete();
                        return true;
                    } else if (key.code == .char and !key.ctrl and !key.alt) {
                        // let char fall through to normal handling, then tryAutocomplete
                    } else if (key.code == .backspace) {
                        // let backspace fall through, then tryAutocomplete
                    } else {
                        self.cancelAutocomplete();
                    }
                },
            }
        }

        switch (key.code) {
            .enter => {
                if (key.shift) {
                    self.insertNewline();
                    return true;
                }
                if (self.cursor_byte > 0 and self.buf.items[self.cursor_byte - 1] == '\\') {
                    const prev = self.cursor_byte - 1;
                    const items = self.buf.items;
                    std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                    self.buf.items.len -= 1;
                    self.cursor_byte = prev;
                    self.cursor_col -= 1;
                    self.insertNewline();
                    return true;
                }
                if (self.on_submit) |cb| {
                    cb(self.buf.items, self.on_submit_ctx);
                }
                return true;
            },
            .char => {
                if (key.ctrl) return false;
                if (key.char) |cp| {
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return false;
                    self.buf.insertSlice(self.allocator, self.cursor_byte, utf8_buf[0..len]) catch return false;
                    self.cursor_byte += @intCast(len);
                    self.cursor_col += @as(u32, grapheme_mod.charWidth(cp));
                    self.ensureCursorVisible();
                    self.tryAutocomplete();
                    return true;
                }
                return false;
            },
            .backspace => {
                if (self.cursor_byte == 0) return true;
                if (self.buf.items[self.cursor_byte - 1] == '\n') {
                    const prev = self.cursor_byte - 1;
                    const prev_line_start = self.lineStartByIndex(self.cursorLine() -| 1);
                    self.cursor_col = self.displayColAtByte(prev);
                    _ = prev_line_start;
                    const items = self.buf.items;
                    std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                    self.buf.items.len -= 1;
                    self.cursor_byte = prev;
                    self.ensureCursorVisible();
                    self.tryAutocomplete();
                    return true;
                }
                const prev = self.prevCodepointBoundary();
                const removed_bytes = self.cursor_byte - prev;
                const removed_text = self.buf.items[prev..self.cursor_byte];
                const removed_width: u32 = @intCast(grapheme_mod.strWidth(removed_text));
                const items = self.buf.items;
                std.mem.copyForwards(u8, items[prev..], items[self.cursor_byte..]);
                self.buf.items.len -= removed_bytes;
                self.cursor_byte = prev;
                self.cursor_col -= removed_width;
                self.tryAutocomplete();
                return true;
            },
            .delete => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                if (self.buf.items[self.cursor_byte] == '\n') {
                    const items = self.buf.items;
                    const next = self.cursor_byte + 1;
                    std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
                    self.buf.items.len -= 1;
                    return true;
                }
                const next = self.nextCodepointBoundary();
                const remove_count = next - self.cursor_byte;
                const items = self.buf.items;
                std.mem.copyForwards(u8, items[self.cursor_byte..], items[next..]);
                self.buf.items.len -= remove_count;
                return true;
            },
            .left => {
                if (self.cursor_byte == 0) return true;
                if (self.buf.items[self.cursor_byte - 1] == '\n') {
                    self.cursor_byte -= 1;
                    self.cursor_col = self.displayColAtByte(self.cursor_byte);
                    self.ensureCursorVisible();
                    return true;
                }
                const prev = self.prevCodepointBoundary();
                const moved_text = self.buf.items[prev..self.cursor_byte];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = prev;
                self.cursor_col -= moved_width;
                return true;
            },
            .right => {
                if (self.cursor_byte >= self.buf.items.len) return true;
                if (self.buf.items[self.cursor_byte] == '\n') {
                    self.cursor_byte += 1;
                    self.cursor_col = 0;
                    self.ensureCursorVisible();
                    return true;
                }
                const next = self.nextCodepointBoundary();
                const moved_text = self.buf.items[self.cursor_byte..next];
                const moved_width: u32 = @intCast(grapheme_mod.strWidth(moved_text));
                self.cursor_byte = next;
                self.cursor_col += moved_width;
                return true;
            },
            .up => {
                const cur_line = self.cursorLine();
                if (cur_line == 0) return true;
                const target_col = self.cursor_col;
                const prev_line_start = self.lineStartByIndex(cur_line - 1);
                const prev_line_end = self.currentLineStart() - 1;
                self.cursor_byte = self.byteAtDisplayCol(prev_line_start, prev_line_end, target_col);
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                self.ensureCursorVisible();
                return true;
            },
            .down => {
                const cur_line = self.cursorLine();
                if (cur_line + 1 >= self.lineCount()) return true;
                const target_col = self.cursor_col;
                const next_line_start = self.lineStartByIndex(cur_line + 1);
                const next_line_end = self.lineEndByStart(next_line_start);
                self.cursor_byte = self.byteAtDisplayCol(next_line_start, next_line_end, target_col);
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                self.ensureCursorVisible();
                return true;
            },
            .home => {
                self.cursor_byte = self.currentLineStart();
                self.cursor_col = 0;
                return true;
            },
            .end => {
                self.cursor_byte = self.currentLineEnd();
                self.cursor_col = self.displayColAtByte(self.cursor_byte);
                return true;
            },
            else => return false,
        }
    }

    // --- Rendering ---

    pub fn render(self: *Editor, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h < 3) return;

        self.last_content_width = w;
        self.ensureCursorVisible();

        const wrapped_line_count = self.wrappedLineCountForWidth(w);
        const editor_h: u32 = @min(@min(wrapped_line_count, self.max_visible_lines) + 2, h);

        // Top border with rounded corners and inline status
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var left_buf: [256]u8 = undefined;
            var right_buf: [128]u8 = undefined;
            const left_text = self.formatStatusLeft(&left_buf);
            const right_text = self.formatStatusRight(&right_buf);
            _ = box_chrome.drawClosedTop(region, 0, left_text, right_text, style);
        }
        // Bottom border with rounded corners
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            _ = box_chrome.drawClosedBottom(region, editor_h - 1, style);
        }

        // Content between borders
        const content = region.sub(0, 1, w, editor_h - 2);
        const wrapped_lines = self.buildWrappedLines(w, self.allocator) catch return;
        defer self.allocator.free(wrapped_lines);

        // Draw content rows
        {
            const chrome_style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var row: u32 = 0;
            while (row < content.height) : (row += 1) {
                content.fill(0, row, content.width, 1, .{
                    .grapheme = .{ .codepoint = ' ' },
                    .fg = Color.default,
                    .bg = Color.default,
                });
                _ = box_chrome.drawClosedContentPrefix(content, row, chrome_style);
            }
        }

        var visible_row: u32 = 0;
        var wrapped_idx: usize = self.scroll_y;
        while (visible_row < content.height and wrapped_idx < wrapped_lines.len) : ({
            visible_row += 1;
            wrapped_idx += 1;
        }) {
            const line = wrapped_lines[wrapped_idx];
            const prefix = if (line.kind == .prompt) self.prompt else "  ";
            _ = content.writeStr(1, visible_row, prefix, self.prompt_fg, Color.default, .{});
            const line_text = self.buf.items[line.start..line.end];
            if (line_text.len > 0) {
                _ = content.writeStr(line.text_x, visible_row, line_text, self.text_fg, Color.default, .{});
            }
        }

        // Autocomplete picker below bottom border
        if (self.autocomplete_active and self.autocomplete_list.items.len > 0) {
            if (h > editor_h) {
                const picker_region = region.sub(0, editor_h, w, h - editor_h);
                self.autocomplete_list.render(picker_region);
            }
        }
    }

    pub fn measure(self: *Editor, width: u32) Measurement {
        self.last_content_width = if (width == 0) 1 else width;
        const wrapped_line_count = self.wrappedLineCountForWidth(self.last_content_width);
        const box_height = @min(wrapped_line_count, self.max_visible_lines) + 2;

        var picker_height: u32 = 0;
        if (self.autocomplete_active and self.autocomplete_list.items.len > 0) {
            picker_height = self.autocomplete_list.measure(width).preferred_height;
        }

        return .{
            .min_height = 3,
            .preferred_height = box_height + picker_height,
        };
    }

    pub fn cursorState(self: *Editor) ?CursorState {
        if (!self.focused) return null;

        const wrapped_lines = self.buildWrappedLines(self.last_content_width, self.allocator) catch return null;
        defer self.allocator.free(wrapped_lines);

        const cursor = self.findCursorVisualPosition(wrapped_lines) orelse return null;
        if (cursor.visual_row < self.scroll_y) return null;

        return .{
            .x = cursor.x,
            .y = (cursor.visual_row - self.scroll_y) + 1,
            .style = .bar,
        };
    }

    pub fn setFocused(self: *Editor, focused: bool) void {
        self.focused = focused;
    }

    pub fn component(self: *Editor) Component {
        return Component.init(Editor, self);
    }

    // --- Git branch (owned fixed buffer) ---

    pub fn setGitBranch(self: *Editor, branch: ?[]const u8) void {
        if (branch) |b| {
            const len: u8 = @intCast(@min(b.len, self.git_branch_buf.len));
            @memcpy(self.git_branch_buf[0..len], b[0..len]);
            self.git_branch_len = len;
        } else {
            self.git_branch_len = 0;
        }
    }

    fn getGitBranch(self: *const Editor) ?[]const u8 {
        if (self.git_branch_len == 0) return null;
        return self.git_branch_buf[0..self.git_branch_len];
    }

    // --- Status formatting (no allocations) ---

    fn formatStatusLeft(self: *const Editor, buf: []u8) ?[]const u8 {
        var pos: usize = 0;

        if (self.cwd.len > 0) {
            const home = std.posix.getenv("HOME") orelse "";
            if (home.len > 0 and std.mem.startsWith(u8, self.cwd, home)) {
                if (pos + 1 < buf.len) {
                    buf[pos] = '~';
                    pos += 1;
                }
                const rest = self.cwd[home.len..];
                const copy_len = @min(rest.len, buf.len - pos);
                @memcpy(buf[pos..][0..copy_len], rest[0..copy_len]);
                pos += copy_len;
            } else {
                const copy_len = @min(self.cwd.len, buf.len - pos);
                @memcpy(buf[pos..][0..copy_len], self.cwd[0..copy_len]);
                pos += copy_len;
            }
        }

        if (self.getGitBranch()) |branch| {
            const sep = " \xC2\xB7 ";
            if (branch.len > 0 and pos + sep.len + branch.len < buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
                const copy_len = @min(branch.len, buf.len - pos);
                @memcpy(buf[pos..][0..copy_len], branch[0..copy_len]);
                pos += copy_len;
            }
        }

        if (pos == 0) return null;
        return buf[0..pos];
    }

    fn formatStatusRight(self: *const Editor, buf: []u8) ?[]const u8 {
        const sd = self.status_data orelse return null;
        if (sd.model_id.len == 0) return null;

        var pos: usize = 0;
        const id_len = @min(sd.model_id.len, buf.len);
        @memcpy(buf[0..id_len], sd.model_id[0..id_len]);
        pos = id_len;

        if (sd.thinking_level.len > 0 and pos + 3 + sd.thinking_level.len < buf.len) {
            buf[pos] = ' ';
            buf[pos + 1] = '(';
            pos += 2;
            @memcpy(buf[pos..][0..sd.thinking_level.len], sd.thinking_level);
            pos += sd.thinking_level.len;
            buf[pos] = ')';
            pos += 1;
        }

        return buf[0..pos];
    }

    // --- Internal helpers ---

    const WrappedLineKind = enum {
        prompt,
        continuation,
    };

    const WrappedLine = struct {
        start: u32,
        end: u32,
        kind: WrappedLineKind,
        text_x: u32,
    };

    const CursorVisualPosition = struct {
        visual_row: u32,
        x: u32,
    };

    fn buildWrappedLines(self: *const Editor, total_width: u32, allocator: std.mem.Allocator) ![]WrappedLine {
        var lines: std.ArrayListUnmanaged(WrappedLine) = .{};
        errdefer lines.deinit(allocator);

        const items = self.buf.items;
        const continuation = "  ";
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        const continuation_width: u32 = @intCast(grapheme_mod.strWidth(continuation));
        const first_text_width = if (total_width > prompt_width + 1) total_width - prompt_width - 1 else 1;
        const continuation_text_width = if (total_width > continuation_width + 1) total_width - continuation_width - 1 else 1;

        var logical_line_idx: u32 = 0;
        var line_start: usize = 0;
        while (true) {
            const line_end = std.mem.indexOfScalarPos(u8, items, line_start, '\n') orelse items.len;
            const line_text = items[line_start..line_end];

            if (logical_line_idx == 0) {
                try self.appendWrappedSlices(&lines, line_text, @intCast(line_start), .prompt, 1 + prompt_width, first_text_width, continuation_text_width, allocator);
            } else {
                try self.appendWrappedSlices(&lines, line_text, @intCast(line_start), .continuation, 1 + continuation_width, continuation_text_width, continuation_text_width, allocator);
            }

            logical_line_idx += 1;
            if (line_end >= items.len) break;
            line_start = line_end + 1;
        }

        if (lines.items.len == 0) {
            try lines.append(allocator, .{ .start = 0, .end = 0, .kind = .prompt, .text_x = 1 + prompt_width });
        }

        return try lines.toOwnedSlice(allocator);
    }

    fn appendWrappedSlices(
        self: *const Editor,
        out: *std.ArrayListUnmanaged(WrappedLine),
        line_text: []const u8,
        base_start: u32,
        first_kind: WrappedLineKind,
        first_text_x: u32,
        first_width: u32,
        continuation_width: u32,
        allocator: std.mem.Allocator,
    ) !void {
        _ = self;
        const continuation = "  ";
        const continuation_prefix_width: u32 = @intCast(grapheme_mod.strWidth(continuation));
        const continuation_text_x = 1 + continuation_prefix_width;
        const continuation_max_width = if (continuation_width == 0) @as(u32, 1) else continuation_width;

        var remaining = line_text;
        var remaining_base = base_start;
        var current_kind = first_kind;
        var current_text_x = first_text_x;
        var current_width = if (first_width == 0) @as(u32, 1) else first_width;

        while (true) {
            const wrapped = try word_wrap_mod.wordWrap(remaining, @intCast(current_width), allocator);
            defer allocator.free(wrapped);

            if (wrapped.len == 0) break;
            const first = wrapped[0];
            const raw_end: usize = if (wrapped.len > 1) wrapped[1].start else remaining.len;
            try out.append(allocator, .{
                .start = remaining_base + @as(u32, @intCast(first.start)),
                // Preserve editor whitespace exactly. wordWrap trims trailing
                // whitespace and strips leading whitespace on continuation
                // lines for display components; editor must keep those bytes
                // visible and cursor-addressable.
                .end = remaining_base + @as(u32, @intCast(raw_end)),
                .kind = current_kind,
                .text_x = current_text_x,
            });

            if (wrapped.len == 1) break;

            remaining_base += @as(u32, @intCast(wrapped[1].start));
            remaining = remaining[wrapped[1].start..];
            current_kind = .continuation;
            current_text_x = continuation_text_x;
            current_width = continuation_max_width;
        }
    }

    fn wrappedLineCountForWidth(self: *const Editor, total_width: u32) u32 {
        const wrapped_lines = self.buildWrappedLines(total_width, self.allocator) catch return self.lineCount();
        defer self.allocator.free(wrapped_lines);
        return @intCast(wrapped_lines.len);
    }

    fn findCursorVisualPosition(self: *const Editor, wrapped_lines: []const WrappedLine) ?CursorVisualPosition {
        if (wrapped_lines.len == 0) return .{ .visual_row = 0, .x = 1 };

        var idx: usize = 0;
        while (idx < wrapped_lines.len) : (idx += 1) {
            const line = wrapped_lines[idx];
            const next_start = if (idx + 1 < wrapped_lines.len) wrapped_lines[idx + 1].start else line.end;
            if (self.cursor_byte >= line.start and self.cursor_byte <= line.end) {
                const col: u32 = @intCast(grapheme_mod.strWidth(self.buf.items[line.start..self.cursor_byte]));
                return .{ .visual_row = @intCast(idx), .x = line.text_x + col };
            }
            if (self.cursor_byte > line.end and self.cursor_byte < next_start) {
                const col: u32 = @intCast(grapheme_mod.strWidth(self.buf.items[line.start..line.end]));
                return .{ .visual_row = @intCast(idx), .x = line.text_x + col };
            }
        }

        const last = wrapped_lines[wrapped_lines.len - 1];
        const col: u32 = @intCast(grapheme_mod.strWidth(self.buf.items[last.start..last.end]));
        return .{ .visual_row = @intCast(wrapped_lines.len - 1), .x = last.text_x + col };
    }

    fn insertNewline(self: *Editor) void {
        self.buf.insertSlice(self.allocator, self.cursor_byte, "\n") catch return;
        self.cursor_byte += 1;
        self.cursor_col = 0;
        self.ensureCursorVisible();
    }

    fn currentLineStart(self: *const Editor) u32 {
        if (self.cursor_byte == 0) return 0;
        var i = self.cursor_byte - 1;
        while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
        if (self.buf.items[i] == '\n') return i + 1;
        return 0;
    }

    fn currentLineEnd(self: *const Editor) u32 {
        var i = self.cursor_byte;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return @intCast(i);
    }

    fn cursorLine(self: *const Editor) u32 {
        var count: u32 = 0;
        for (self.buf.items[0..self.cursor_byte]) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    fn lineCount(self: *const Editor) u32 {
        if (self.buf.items.len == 0) return 1;
        var count: u32 = 1;
        for (self.buf.items) |b| {
            if (b == '\n') count += 1;
        }
        return count;
    }

    fn lineStartByIndex(self: *const Editor, n: u32) u32 {
        if (n == 0) return 0;
        var count: u32 = 0;
        for (self.buf.items, 0..) |b, i| {
            if (b == '\n') {
                count += 1;
                if (count == n) return @intCast(i + 1);
            }
        }
        return @intCast(self.buf.items.len);
    }

    fn lineEndByStart(self: *const Editor, start: u32) u32 {
        var i = start;
        while (i < self.buf.items.len and self.buf.items[i] != '\n') : (i += 1) {}
        return i;
    }

    fn displayColAtByte(self: *const Editor, byte: u32) u32 {
        var line_start: u32 = 0;
        if (byte > 0) {
            var i: u32 = byte - 1;
            while (i > 0 and self.buf.items[i] != '\n') : (i -= 1) {}
            if (i < byte and self.buf.items[i] == '\n') {
                line_start = i + 1;
            }
        }
        return @intCast(grapheme_mod.strWidth(self.buf.items[line_start..byte]));
    }

    fn byteAtDisplayCol(self: *const Editor, line_start: u32, line_end: u32, target_col: u32) u32 {
        var col: u32 = 0;
        var i: u32 = line_start;
        while (i < line_end) {
            const cp_len: u32 = @intCast(std.unicode.utf8ByteSequenceLength(self.buf.items[i]) catch 1);
            const end = @min(i + cp_len, line_end);
            const cp = std.unicode.utf8Decode(self.buf.items[i..end]) catch '_';
            const w_val: u32 = @as(u32, grapheme_mod.charWidth(cp));
            if (col + w_val > target_col) break;
            col += w_val;
            i = end;
        }
        return i;
    }

    fn ensureCursorVisible(self: *Editor) void {
        const wrapped_lines = self.buildWrappedLines(self.last_content_width, self.allocator) catch return;
        defer self.allocator.free(wrapped_lines);

        const cursor = self.findCursorVisualPosition(wrapped_lines) orelse return;
        if (cursor.visual_row < self.scroll_y) {
            self.scroll_y = cursor.visual_row;
        } else if (cursor.visual_row >= self.scroll_y + self.max_visible_lines) {
            self.scroll_y = cursor.visual_row - self.max_visible_lines + 1;
        }
    }

    fn prevCodepointBoundary(self: *const Editor) u32 {
        if (self.cursor_byte == 0) return 0;
        var i = self.cursor_byte - 1;
        while (i > 0 and (self.buf.items[i] & 0xC0) == 0x80) : (i -= 1) {}
        return i;
    }

    fn nextCodepointBoundary(self: *const Editor) u32 {
        if (self.cursor_byte >= self.buf.items.len) return @intCast(self.buf.items.len);
        var i = self.cursor_byte + 1;
        while (i < self.buf.items.len and (self.buf.items[i] & 0xC0) == 0x80) : (i += 1) {}
        return @intCast(i);
    }
};

// --- Tests ---

test "Editor insert, cursor tracking, and submit" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'h' });
    _ = editor.handleInput(.{ .code = .char, .char = 'i' });
    try std.testing.expectEqualStrings("hi", editor.getText());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 5), cs.x);
}

test "Editor backspace, delete, and navigation" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });
    _ = editor.handleInput(.{ .code = .backspace });
    try std.testing.expectEqualStrings("ab", editor.getText());
    _ = editor.handleInput(.{ .code = .home });
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);
    _ = editor.handleInput(.{ .code = .end });
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);
    editor.clear();
    try std.testing.expectEqualStrings("", editor.getText());
}

test "Editor renders prompt and text to buffer" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'x' });
    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 3);
    defer buf.deinit();
    editor.render(buf.region());
    try std.testing.expectEqual(@as(u21, 0x256D), buf.get(0, 0).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, '>'), buf.get(1, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'x'), buf.get(3, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 0x2570), buf.get(0, 2).grapheme.codepoint);
}

test "editor render after backspace clears deleted char from buffer" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 3);
    defer buf.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });

    editor.render(buf.region());
    try std.testing.expectEqual(@as(u21, 'c'), buf.get(5, 1).grapheme.codepoint);

    _ = editor.handleInput(.{ .code = .backspace });

    buf.clear();
    editor.render(buf.region());

    try std.testing.expectEqual(@as(u21, 'b'), buf.get(4, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(5, 1).grapheme.codepoint);

    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 5), cs.x);
    try std.testing.expectEqual(@as(u32, 1), cs.y);
}

test "Editor handles newline insertion and cross-line backspace" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = 'b' });
    _ = editor.handleInput(.{ .code = .enter, .shift = true });
    _ = editor.handleInput(.{ .code = .char, .char = 'c' });
    _ = editor.handleInput(.{ .code = .char, .char = 'd' });

    try std.testing.expectEqualStrings("ab\ncd", editor.getText());
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    editor.clear();
    _ = editor.handleInput(.{ .code = .char, .char = 'x' });
    _ = editor.handleInput(.{ .code = .char, .char = '\\' });
    _ = editor.handleInput(.{ .code = .enter });
    _ = editor.handleInput(.{ .code = .char, .char = 'y' });
    try std.testing.expectEqualStrings("x\ny", editor.getText());

    _ = editor.handleInput(.{ .code = .home });
    try std.testing.expectEqual(@as(u32, 0), editor.cursor_col);
    _ = editor.handleInput(.{ .code = .backspace });
    try std.testing.expectEqualStrings("xy", editor.getText());
    try std.testing.expectEqual(@as(u32, 1), editor.cursor_col);
}

test "Editor up/down navigation moves between lines" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    editor.insertText("abc\nde\nfghij");
    try std.testing.expectEqualStrings("abc\nde\nfghij", editor.getText());
    try std.testing.expectEqual(@as(u32, 2), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 5), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .up });
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .up });
    try std.testing.expectEqual(@as(u32, 0), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .down });
    try std.testing.expectEqual(@as(u32, 1), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);

    _ = editor.handleInput(.{ .code = .down });
    try std.testing.expectEqual(@as(u32, 2), editor.cursorLine());
    try std.testing.expectEqual(@as(u32, 2), editor.cursor_col);
}

test "Editor wraps long content when rendering" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    editor.setText("hello world");

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 10, 4);
    defer buf.deinit();
    editor.render(buf.region());

    try std.testing.expectEqual(@as(u21, '>'), buf.get(1, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'h'), buf.get(3, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, 'w'), buf.get(3, 2).grapheme.codepoint);
    try std.testing.expectEqual(@as(u32, 4), editor.measure(10).preferred_height);

    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 8), cs.x);
    try std.testing.expectEqual(@as(u32, 2), cs.y);
}

test "Editor preserves trailing spaces in render and cursor position" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();

    _ = editor.handleInput(.{ .code = .char, .char = 'a' });
    _ = editor.handleInput(.{ .code = .char, .char = ' ' });
    try std.testing.expectEqualStrings("a ", editor.getText());

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 20, 3);
    defer buf.deinit();
    editor.render(buf.region());

    try std.testing.expectEqual(@as(u21, 'a'), buf.get(3, 1).grapheme.codepoint);
    try std.testing.expectEqual(@as(u21, ' '), buf.get(4, 1).grapheme.codepoint);

    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 5), cs.x);
    try std.testing.expectEqual(@as(u32, 1), cs.y);
}

test "Editor scrolls wrapped cursor into view" {
    var editor = Editor.init(std.testing.allocator);
    defer editor.deinit();
    editor.max_visible_lines = 2;
    editor.setText("one two three four");

    var buf = try buffer_mod.Buffer.init(std.testing.allocator, 9, 4);
    defer buf.deinit();
    editor.render(buf.region());

    try std.testing.expectEqual(@as(u32, 2), editor.scroll_y);
    const cs = editor.cursorState().?;
    try std.testing.expectEqual(@as(u32, 7), cs.x);
    try std.testing.expectEqual(@as(u32, 2), cs.y);
}

test "slash command autocomplete end-to-end" {
    const allocator = std.testing.allocator;

    const slash_commands_mod = @import("../../slash_commands.zig");
    var registry = slash_commands_mod.CommandRegistry.init(allocator);
    defer registry.deinit();

    var slash_provider = autocomplete_mod.SlashCommandProvider.init(&registry);

    var editor = Editor.init(allocator);
    defer editor.deinit();
    editor.setAutocompleteProvider(slash_provider.provider());
    editor.theme = &theme_mod.Theme.dark;

    var submitted: ?[]const u8 = null;
    const SubmitCtx = struct { submitted: *?[]const u8 };
    var submit_ctx = SubmitCtx{ .submitted = &submitted };
    editor.on_submit = struct {
        fn cb(text: []const u8, ctx: ?*anyopaque) void {
            const sc: *SubmitCtx = @ptrCast(@alignCast(ctx));
            sc.submitted.* = text;
        }
    }.cb;
    editor.on_submit_ctx = @ptrCast(&submit_ctx);

    // Type "/" → autocomplete activates with all commands
    _ = editor.handleInput(.{ .code = .char, .char = '/' });
    try std.testing.expect(editor.autocomplete_active);

    // Type "m" → narrows to commands starting with "m" (model)
    _ = editor.handleInput(.{ .code = .char, .char = 'm' });
    try std.testing.expect(editor.autocomplete_active);
    const item = editor.autocomplete_list.getSelectedItem();
    try std.testing.expect(item != null);
    try std.testing.expectEqualStrings("model", item.?.value);

    // Press Enter → accept autocomplete + submit
    _ = editor.handleInput(.{ .code = .enter });

    // Autocomplete dismissed
    try std.testing.expect(!editor.autocomplete_active);

    // Editor text is "/model "
    try std.testing.expectEqualStrings("/model ", editor.getText());

    // Submit fired with "/model "
    try std.testing.expect(submitted != null);
    try std.testing.expectEqualStrings("/model ", submitted.?);
}

test "slash command Tab accepts top pick without submitting" {
    const allocator = std.testing.allocator;

    const slash_commands_mod = @import("../../slash_commands.zig");
    var registry = slash_commands_mod.CommandRegistry.init(allocator);
    defer registry.deinit();

    var slash_provider = autocomplete_mod.SlashCommandProvider.init(&registry);

    var editor = Editor.init(allocator);
    defer editor.deinit();
    editor.setAutocompleteProvider(slash_provider.provider());
    editor.theme = &theme_mod.Theme.dark;

    var submitted: ?[]const u8 = null;
    const SubmitCtx = struct { submitted: *?[]const u8 };
    var submit_ctx = SubmitCtx{ .submitted = &submitted };
    editor.on_submit = struct {
        fn cb(text: []const u8, ctx: ?*anyopaque) void {
            const sc: *SubmitCtx = @ptrCast(@alignCast(ctx));
            sc.submitted.* = text;
        }
    }.cb;
    editor.on_submit_ctx = @ptrCast(&submit_ctx);

    // Type "/re" → autocomplete shows "resume" as top pick
    _ = editor.handleInput(.{ .code = .char, .char = '/' });
    _ = editor.handleInput(.{ .code = .char, .char = 'r' });
    _ = editor.handleInput(.{ .code = .char, .char = 'e' });
    try std.testing.expect(editor.autocomplete_active);

    // Tab → accept top pick, but do NOT submit
    _ = editor.handleInput(.{ .code = .tab });
    try std.testing.expect(!editor.autocomplete_active);
    try std.testing.expectEqualStrings("/resume ", editor.getText());
    try std.testing.expect(submitted == null); // no submit on Tab

    // Now Enter submits the completed text
    _ = editor.handleInput(.{ .code = .enter });
    try std.testing.expect(submitted != null);
    try std.testing.expectEqualStrings("/resume ", submitted.?);
}

test "slash command Enter on partial text accepts top pick and submits" {
    const allocator = std.testing.allocator;

    const slash_commands_mod = @import("../../slash_commands.zig");
    var registry = slash_commands_mod.CommandRegistry.init(allocator);
    defer registry.deinit();

    var slash_provider = autocomplete_mod.SlashCommandProvider.init(&registry);

    var editor = Editor.init(allocator);
    defer editor.deinit();
    editor.setAutocompleteProvider(slash_provider.provider());
    editor.theme = &theme_mod.Theme.dark;

    var submitted: ?[]const u8 = null;
    const SubmitCtx = struct { submitted: *?[]const u8 };
    var submit_ctx = SubmitCtx{ .submitted = &submitted };
    editor.on_submit = struct {
        fn cb(text: []const u8, ctx: ?*anyopaque) void {
            const sc: *SubmitCtx = @ptrCast(@alignCast(ctx));
            sc.submitted.* = text;
        }
    }.cb;
    editor.on_submit_ctx = @ptrCast(&submit_ctx);

    // Type "/re" → autocomplete active, top pick is "resume"
    _ = editor.handleInput(.{ .code = .char, .char = '/' });
    _ = editor.handleInput(.{ .code = .char, .char = 'r' });
    _ = editor.handleInput(.{ .code = .char, .char = 'e' });
    try std.testing.expect(editor.autocomplete_active);

    // Enter → accept top pick + submit in one action
    _ = editor.handleInput(.{ .code = .enter });
    try std.testing.expect(!editor.autocomplete_active);
    try std.testing.expectEqualStrings("/resume ", editor.getText());
    try std.testing.expect(submitted != null);
    try std.testing.expectEqualStrings("/resume ", submitted.?);
}
