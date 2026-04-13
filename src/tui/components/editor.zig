const std = @import("std");
const cell_mod = @import("../cell.zig");
const buffer_mod = @import("../buffer.zig");
const component_mod = @import("../component.zig");
const keys_mod = @import("../keys.zig");
const grapheme_mod = @import("../grapheme.zig");
const box_chrome = @import("../box_chrome.zig");
const status_data_mod = @import("../status_data.zig");
const autocomplete_mod = @import("../autocomplete.zig");
const editor_iface_mod = @import("../editor_iface.zig");
const theme_mod = @import("../theme.zig");
const editor_core = @import("../editor/root.zig");
const keybindings = @import("../keybindings.zig");

const Color = cell_mod.Color;
const Region = buffer_mod.Region;
const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const CursorState = component_mod.CursorState;
const Key = keys_mod.Key;
const StatusData = status_data_mod.StatusData;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const EditorInterface = editor_iface_mod.EditorInterface;
const Theme = theme_mod.Theme;
const PromptBuffer = editor_core.PromptBuffer;
const PromptView = editor_core.PromptView;
const AutocompleteSession = editor_core.AutocompleteSession;
const RenderConfig = editor_core.RenderConfig;

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: *PromptBuffer,
    view: PromptView,
    autocomplete: AutocompleteSession,
    history: std.ArrayList([]u8) = .empty,
    history_index: i32 = -1,
    max_visible_lines: u32 = 10,
    last_total_width: u32 = 80,
    last_applied_padding_x: u32 = 0,
    last_content_width: u32 = 80,
    last_viewport_rows: u32 = 10,
    prompt: []const u8 = "> ",
    on_submit: ?EditorInterface.SubmitCallback = null,
    on_submit_ctx: ?*anyopaque = null,
    on_change: ?EditorInterface.ChangeCallback = null,
    on_change_ctx: ?*anyopaque = null,
    disable_submit: bool = false,
    padding_x: u32 = 0,
    prompt_fg: Color = Color.rgb(100, 100, 100),
    text_fg: Color = Color.default,
    border_color: Color = Color.rgb(0x50, 0x50, 0x50),
    status_data: ?*const StatusData = null,
    /// Working directory displayed in top border (borrowed, set by Interactive).
    cwd: []const u8 = "",
    /// Git branch displayed in top border (fixed buffer, set by Interactive).
    git_branch_buf: [128]u8 = undefined,
    git_branch_len: u8 = 0,
    focused: bool = true,
    theme: ?*const Theme = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        const buffer = allocator.create(PromptBuffer) catch @panic("OOM");
        buffer.* = PromptBuffer.init(allocator);
        var view = PromptView.init(allocator, buffer);
        view.setViewportHeight(10);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .view = view,
            .autocomplete = AutocompleteSession.init(&Theme.dark),
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.view.deinit();
        self.buffer.deinit();
        self.allocator.destroy(self.buffer);
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buffer.text();
    }

    pub fn getExpandedText(self: *const Editor) []const u8 {
        return self.getText();
    }

    pub fn clear(self: *Editor) void {
        self.cancelAutocomplete();
        self.history_index = -1;
        self.setTextInternal("", false);
    }

    pub fn setText(self: *Editor, text: []const u8) void {
        self.cancelAutocomplete();
        self.history_index = -1;
        self.setTextInternal(text, false);
    }

    pub fn insertText(self: *Editor, text: []const u8) void {
        self.insertTextAtCursor(text);
    }

    pub fn insertTextAtCursor(self: *Editor, text: []const u8) void {
        self.history_index = -1;
        self.buffer.insertAtCursor(text);
        self.afterTextMutation();
    }

    pub fn clearHistory(self: *Editor) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.items.len = 0;
        self.history_index = -1;
    }

    pub fn addToHistory(self: *Editor, text: []const u8) void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0) return;
        if (self.history.items.len > 0 and std.mem.eql(u8, self.history.items[0], trimmed)) return;

        const copy = self.allocator.dupe(u8, trimmed) catch return;
        self.history.insert(self.allocator, 0, copy) catch {
            self.allocator.free(copy);
            return;
        };

        if (self.history.items.len > 100) {
            const evicted = self.history.items[self.history.items.len - 1];
            _ = self.history.pop();
            self.allocator.free(evicted);
        }
    }

    pub fn setOnSubmit(self: *Editor, cb: ?EditorInterface.SubmitCallback, ctx: ?*anyopaque) void {
        self.on_submit = cb;
        self.on_submit_ctx = ctx;
    }

    pub fn setOnChange(self: *Editor, cb: ?EditorInterface.ChangeCallback, ctx: ?*anyopaque) void {
        self.on_change = cb;
        self.on_change_ctx = ctx;
    }

    pub fn setTheme(self: *Editor, theme: *const Theme) void {
        self.theme = theme;
        self.prompt_fg = theme.fg(.muted);
        self.border_color = theme.fg(.border_muted);
        self.autocomplete.setTheme(theme);
    }

    pub fn setStatusData(self: *Editor, status_data: *const StatusData) void {
        self.status_data = status_data;
    }

    pub fn setCwd(self: *Editor, cwd: []const u8) void {
        self.cwd = cwd;
    }

    pub fn setBorderColor(self: *Editor, color: Color) void {
        self.border_color = color;
    }

    pub fn setPaddingX(self: *Editor, padding: u32) void {
        self.padding_x = padding;
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
    }

    pub fn setAutocompleteMaxVisible(self: *Editor, max_visible: u32) void {
        self.autocomplete.setMaxVisible(max_visible);
    }

    pub fn setMaxVisibleLines(self: *Editor, max_visible_lines: u32) void {
        self.max_visible_lines = @max(@as(u32, 1), max_visible_lines);
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
    }

    pub fn setSubmitDisabled(self: *Editor, disabled: bool) void {
        self.disable_submit = disabled;
    }

    pub fn setAutocompleteProvider(self: *Editor, provider: AutocompleteProvider) void {
        self.autocomplete.setTheme(self.theme orelse &Theme.dark);
        self.autocomplete.setProvider(provider);
    }

    pub fn cancelAutocomplete(self: *Editor) void {
        self.autocomplete.cancel();
    }

    pub fn handleInput(self: *Editor, key: Key) bool {
        if (!self.focused) return false;

        switch (self.autocomplete.processInput(key, self.buffer)) {
            .accepted => |accepted| {
                self.afterAutocompleteAcceptance();
                if (accepted.submit) {
                    if (self.disable_submit) return true;
                    if (self.on_submit) |cb| cb(self.buffer.text(), self.on_submit_ctx);
                }
                return true;
            },
            .cancelled, .consumed => return true,
            .unhandled => {},
        }

        if (keybindings.matches(.input_new_line, key)) {
            self.history_index = -1;
            self.buffer.insertNewline();
            self.afterTextMutation();
            return true;
        }

        if (keybindings.matches(.input_submit, key)) {
            const cursor_byte = self.buffer.cursorByte();
            if (cursor_byte > 0 and self.buffer.text()[cursor_byte - 1] == '\\') {
                self.history_index = -1;
                self.buffer.backspace();
                self.buffer.insertNewline();
                self.afterTextMutation();
                return true;
            }

            if (self.disable_submit) return true;
            if (self.on_submit) |cb| cb(self.buffer.text(), self.on_submit_ctx);
            return true;
        }

        switch (key.code) {
            .char => {
                if (key.ctrl) return false;
                if (key.char) |cp| {
                    self.history_index = -1;
                    var utf8_buf: [4]u8 = undefined;
                    const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return false;
                    self.buffer.insertAtCursor(utf8_buf[0..len]);
                    self.afterTextMutation();
                    return true;
                }
                return false;
            },
            .backspace => {
                self.history_index = -1;
                self.buffer.backspace();
                self.afterTextMutation();
                return true;
            },
            .delete => {
                self.history_index = -1;
                self.buffer.deleteForward();
                self.afterTextMutation();
                return true;
            },
            .left => {
                self.buffer.moveLeft();
                self.afterCursorMotion();
                return true;
            },
            .right => {
                self.buffer.moveRight();
                self.afterCursorMotion();
                return true;
            },
            .up => {
                if (self.buffer.text().len == 0) {
                    self.navigateHistory(-1);
                } else if (self.history_index > -1 and self.view.isCursorOnFirstVisualLine()) {
                    self.navigateHistory(-1);
                } else if (self.view.isCursorOnFirstVisualLine()) {
                    self.buffer.moveLogicalLineStart();
                    self.afterCursorMotion();
                } else {
                    self.view.moveUpVisual();
                }
                return true;
            },
            .down => {
                if (self.history_index > -1 and self.view.isCursorOnLastVisualLine()) {
                    self.navigateHistory(1);
                } else if (self.view.isCursorOnLastVisualLine()) {
                    self.buffer.moveLogicalLineEnd();
                    self.afterCursorMotion();
                } else {
                    self.view.moveDownVisual();
                }
                return true;
            },
            .home => {
                self.buffer.moveLogicalLineStart();
                self.afterCursorMotion();
                return true;
            },
            .end => {
                self.buffer.moveLogicalLineEnd();
                self.afterCursorMotion();
                return true;
            },
            else => return false,
        }
    }

    pub fn render(self: *Editor, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h < 3) return;

        self.autocomplete.setTheme(self.theme orelse &Theme.dark);

        const text_row_cap = @min(self.max_visible_lines, h - 2);
        self.syncViewGeometry(w, text_row_cap);
        const total_lines = self.view.totalVisualLineCount();
        const visible_rows = @min(total_lines, text_row_cap);
        self.syncViewGeometry(w, visible_rows);
        self.view.ensureCursorVisible();

        const editor_h = visible_rows + 2;

        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var left_buf: [256]u8 = undefined;
            var right_buf: [256]u8 = undefined;
            const left_text = self.formatStatusLeft(&left_buf);
            const right_text = self.formatStatusRight(&right_buf);
            _ = box_chrome.drawClosedTop(region, 0, left_text, right_text, style);
        }
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            _ = box_chrome.drawClosedBottom(region, editor_h - 1, style);
        }

        const content = region.sub(0, 1, w, visible_rows);
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

        editor_core.renderVisibleLines(content, self.buffer, self.view.visibleLines(), RenderConfig{
            .prompt = self.prompt,
            .applied_padding_x = self.last_applied_padding_x,
            .prompt_fg = self.prompt_fg,
            .text_fg = self.text_fg,
        });

        if (self.autocomplete.isActive() and h > editor_h) {
            const picker_region = region.sub(0, editor_h, w, h - editor_h);
            self.autocomplete.render(picker_region);
        }
    }

    pub fn measure(self: *Editor, width: u32) Measurement {
        self.autocomplete.setTheme(self.theme orelse &Theme.dark);
        self.syncViewGeometry(width, self.max_visible_lines);
        const wrapped_line_count = self.view.totalVisualLineCount();
        const box_height = @min(wrapped_line_count, self.max_visible_lines) + 2;
        const picker_height = self.autocomplete.measure(width).preferred_height;
        return .{
            .min_height = 3,
            .preferred_height = box_height + picker_height,
        };
    }

    pub fn cursorState(self: *Editor) ?CursorState {
        if (!self.focused) return null;
        self.syncStoredViewGeometry();
        const cursor = self.view.visualCursor() orelse return null;
        if (cursor.visual_row >= self.last_viewport_rows) return null;
        return .{
            .x = cursor.visual_col + self.last_applied_padding_x,
            .y = cursor.visual_row + 1,
            .style = .bar,
        };
    }

    pub fn nextAnimationDeadline(self: *Editor, now_ns: i128) ?i128 {
        return self.autocomplete.nextAnimationDeadline(now_ns);
    }

    pub fn tickAnimation(self: *Editor, now_ns: i128) bool {
        const outcome = self.autocomplete.tickAnimation(self.buffer, now_ns);
        if (outcome.accepted) self.afterAutocompleteAcceptance();
        return outcome.changed;
    }

    pub fn setFocused(self: *Editor, focused: bool) void {
        self.focused = focused;
    }

    pub fn component(self: *Editor) Component {
        return Component.init(Editor, self);
    }

    pub fn setGitBranch(self: *Editor, branch: ?[]const u8) void {
        if (branch) |value| {
            const len: u8 = @intCast(@min(value.len, self.git_branch_buf.len));
            @memcpy(self.git_branch_buf[0..len], value[0..len]);
            self.git_branch_len = len;
        } else {
            self.git_branch_len = 0;
        }
    }

    fn setTextInternal(self: *Editor, text: []const u8, preserve_history_index: bool) void {
        self.buffer.setText(text);
        self.view.resetViewport();
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        if (!preserve_history_index) self.history_index = -1;
        self.autocomplete.refresh(self.buffer);
        self.notifyChange();
    }

    fn navigateHistory(self: *Editor, direction: i32) void {
        if (self.history.items.len == 0) return;

        const max_index: i32 = @intCast(self.history.items.len);
        const new_index = self.history_index - direction;
        if (new_index < -1 or new_index >= max_index) return;

        self.history_index = new_index;
        self.cancelAutocomplete();

        if (self.history_index == -1) {
            self.setTextInternal("", true);
        } else {
            const idx: usize = @intCast(self.history_index);
            self.setTextInternal(self.history.items[idx], true);
        }
    }

    fn notifyChange(self: *Editor) void {
        if (self.on_change) |cb| cb(self.buffer.text(), self.on_change_ctx);
    }

    fn afterTextMutation(self: *Editor) void {
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        self.autocomplete.refresh(self.buffer);
        self.notifyChange();
    }

    fn afterCursorMotion(self: *Editor) void {
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
    }

    fn afterAutocompleteAcceptance(self: *Editor) void {
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        self.notifyChange();
    }

    fn syncStoredViewGeometry(self: *Editor) void {
        self.syncViewGeometry(self.last_total_width, self.last_viewport_rows);
    }

    fn syncViewGeometry(self: *Editor, total_width: u32, viewport_rows: u32) void {
        const applied_padding = self.appliedPaddingX(total_width);
        const content_width = self.effectiveContentWidth(total_width);
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        const continuation_prompt = "  ";
        const continuation_width: u32 = @intCast(grapheme_mod.strWidth(continuation_prompt));

        self.last_total_width = total_width;
        self.last_applied_padding_x = applied_padding;
        self.last_content_width = content_width;
        self.last_viewport_rows = @max(@as(u32, 1), viewport_rows);

        self.view.setLayoutConfig(.{
            .width_cols = content_width,
            .first_line_text_col = 1 + prompt_width,
            .continuation_text_col = 1 + continuation_width,
        });
        self.view.setViewportHeight(self.last_viewport_rows);
    }

    fn appliedPaddingX(self: *const Editor, total_width: u32) u32 {
        if (total_width <= 1) return 0;
        return @min(self.padding_x, @divFloor(total_width - 1, @as(u32, 2)));
    }

    fn effectiveContentWidth(self: *const Editor, total_width: u32) u32 {
        const applied = self.appliedPaddingX(total_width);
        return if (total_width > applied * 2) total_width - applied * 2 else 1;
    }

    fn getGitBranch(self: *const Editor) ?[]const u8 {
        if (self.git_branch_len == 0) return null;
        return self.git_branch_buf[0..self.git_branch_len];
    }

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
        const status = self.status_data orelse return null;
        if (status.model_id.len == 0) return null;

        var pos: usize = 0;
        var first = true;

        if (status.context_window > 0) {
            var tokens_buf: [24]u8 = undefined;
            var window_buf: [24]u8 = undefined;
            const window_text = formatTokenCount(&window_buf, status.context_window);
            const label = if (status.context_tokens) |tokens|
                std.fmt.bufPrint(buf[pos..], "ctx {s}/{s}", .{ formatTokenCount(&tokens_buf, tokens), window_text }) catch ""
            else
                std.fmt.bufPrint(buf[pos..], "ctx ?/{s}", .{window_text}) catch "";
            if (label.len > 0) {
                pos += label.len;
                first = false;
            }
        }

        if (status.model_id.len > 0) {
            const sep = " • ";
            if (!first and pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
            const copy_len = @min(status.model_id.len, buf.len - pos);
            @memcpy(buf[pos..][0..copy_len], status.model_id[0..copy_len]);
            pos += copy_len;
            first = false;
        }

        if (status.thinking_level.len > 0 and pos + 3 + status.thinking_level.len < buf.len) {
            const sep = " • ";
            if (!first and pos + sep.len <= buf.len) {
                @memcpy(buf[pos..][0..sep.len], sep);
                pos += sep.len;
            }
            const written = std.fmt.bufPrint(buf[pos..], "thinking {s}", .{status.thinking_level}) catch "";
            pos += written.len;
        }

        return if (pos == 0) null else buf[0..pos];
    }

    fn formatTokenCount(buf: []u8, value: u64) []const u8 {
        if (value < 1_000) return std.fmt.bufPrint(buf, "{d}", .{value}) catch "";
        if (value < 10_000) {
            const whole = @divTrunc(value, 1_000);
            const tenth = @divTrunc(value % 1_000, 100);
            return std.fmt.bufPrint(buf, "{d}.{d}k", .{ whole, tenth }) catch "";
        }
        if (value < 1_000_000) return std.fmt.bufPrint(buf, "{d}k", .{@divTrunc(value, 1_000)}) catch "";
        if (value < 10_000_000) {
            const whole = @divTrunc(value, 1_000_000);
            const tenth = @divTrunc(value % 1_000_000, 100_000);
            return std.fmt.bufPrint(buf, "{d}.{d}M", .{ whole, tenth }) catch "";
        }
        return std.fmt.bufPrint(buf, "{d}M", .{@divTrunc(value, 1_000_000)}) catch "";
    }
};

const testing = std.testing;

const SubmitCapture = struct {
    count: u32 = 0,
};

fn captureSubmit(_: []const u8, ctx: ?*anyopaque) void {
    const capture: *SubmitCapture = @ptrCast(@alignCast(ctx));
    capture.count += 1;
}

test "Editor shared bindings keep shift enter as newline and enter as submit" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));
    editor.insertText("hello");

    try testing.expect(editor.handleInput(.{ .code = .enter, .shift = true }));
    try testing.expectEqualStrings("hello\n", editor.getText());
    try testing.expectEqual(@as(u32, 0), capture.count);

    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 1), capture.count);
}

test "Editor submit binding preserves backslash newline fallback" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));
    editor.insertText("hello\\");

    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqualStrings("hello\n", editor.getText());
    try testing.expectEqual(@as(u32, 0), capture.count);
}
