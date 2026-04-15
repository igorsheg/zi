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
const themes_builtin = @import("../../themes/builtin.zig");
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
const BindingAction = keybindings.Action;

const UndoSnapshot = struct {
    text: []u8,
    cursor_byte: u32,
};

const MarkerRange = struct {
    start: u32,
    end: u32,
};

const LastAction = enum {
    none,
    type_word,
};

pub const Editor = struct {
    allocator: std.mem.Allocator,
    buffer: *PromptBuffer,
    view: PromptView,
    autocomplete: AutocompleteSession,
    history: std.ArrayList([]u8) = .empty,
    undo_stack: std.ArrayList(UndoSnapshot) = .empty,
    pastes: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
    paste_counter: u32 = 0,
    expanded_text_cache: std.ArrayList(u8) = .empty,
    history_index: i32 = -1,
    last_action: LastAction = .none,
    max_visible_lines: u32 = 10,
    last_total_width: u32 = 80,
    last_applied_padding_x: u32 = 0,
    last_content_width: u32 = 80,
    last_viewport_rows: u32 = 10,
    prompt: []const u8 = "",
    on_submit: ?EditorInterface.SubmitCallback = null,
    on_submit_ctx: ?*anyopaque = null,
    on_change: ?EditorInterface.ChangeCallback = null,
    on_change_ctx: ?*anyopaque = null,
    disable_submit: bool = false,
    padding_x: u32 = 0,
    prompt_fg: Color = Color.default,
    text_fg: Color = Color.default,
    border_color: Color = Color.default,
    status_data: ?*const StatusData = null,
    /// Working directory displayed in top border (borrowed, set by Interactive).
    cwd: []const u8 = "",
    /// Git branch displayed in top border (fixed buffer, set by Interactive).
    git_branch_buf: [128]u8 = undefined,
    git_branch_len: u8 = 0,
    focused: bool = true,
    theme: ?*const Theme = null,

    pub fn init(allocator: std.mem.Allocator) Editor {
        const default_theme = themes_builtin.dark();
        const buffer = allocator.create(PromptBuffer) catch @panic("OOM");
        buffer.* = PromptBuffer.init(allocator);
        var view = PromptView.init(allocator, buffer);
        view.setViewportHeight(10);
        return .{
            .allocator = allocator,
            .buffer = buffer,
            .view = view,
            .autocomplete = AutocompleteSession.init(default_theme),
            .theme = default_theme,
            .prompt_fg = default_theme.fg(.muted),
            .border_color = default_theme.fg(.border_muted),
        };
    }

    pub fn deinit(self: *Editor) void {
        for (self.history.items) |entry| self.allocator.free(entry);
        self.history.deinit(self.allocator);
        self.clearUndoStack();
        self.undo_stack.deinit(self.allocator);
        self.clearStoredPastes();
        self.pastes.deinit(self.allocator);
        self.expanded_text_cache.deinit(self.allocator);
        self.view.deinit();
        self.buffer.deinit();
        self.allocator.destroy(self.buffer);
    }

    pub fn getText(self: *const Editor) []const u8 {
        return self.buffer.text();
    }

    pub fn getExpandedText(self: *Editor) []const u8 {
        return self.expandPasteMarkers();
    }

    pub fn clear(self: *Editor) void {
        self.cancelAutocomplete();
        self.history_index = -1;
        self.last_action = .none;
        self.clearUndoStack();
        self.clearStoredPastes();
        self.paste_counter = 0;
        self.setTextInternal("", false);
    }

    pub fn setText(self: *Editor, text: []const u8) void {
        self.cancelAutocomplete();
        self.last_action = .none;
        self.history_index = -1;
        if (!std.mem.eql(u8, self.buffer.text(), text)) {
            self.pushUndoSnapshot();
        }
        self.setTextInternal(text, false);
    }

    pub fn insertText(self: *Editor, text: []const u8) void {
        self.insertTextAtCursor(text);
    }

    pub fn insertTextAtCursor(self: *Editor, text: []const u8) void {
        if (text.len == 0) return;
        self.cancelAutocomplete();
        self.pushUndoSnapshot();
        self.last_action = .none;
        self.history_index = -1;
        self.insertTextAtCursorInternal(text);
    }

    pub fn handlePaste(self: *Editor, pasted_text: []const u8) void {
        self.cancelAutocomplete();
        self.history_index = -1;
        self.last_action = .none;
        self.pushUndoSnapshot();

        var filtered: std.ArrayList(u8) = .empty;
        defer filtered.deinit(self.allocator);
        appendNormalizedPaste(&filtered, self.allocator, pasted_text) catch return;

        if (filtered.items.len > 0 and isPastePathLike(filtered.items) and self.cursorPrecededByWordByte()) {
            filtered.insert(self.allocator, 0, ' ') catch return;
        }

        if (filtered.items.len == 0) return;

        const line_count = countPasteLines(filtered.items);
        const total_chars = filtered.items.len;
        if (line_count > 10 or total_chars > 1000) {
            self.paste_counter += 1;
            const paste_id = self.paste_counter;
            const stored = self.allocator.dupe(u8, filtered.items) catch return;
            self.pastes.put(self.allocator, paste_id, stored) catch {
                self.allocator.free(stored);
                return;
            };

            var marker_buf: [64]u8 = undefined;
            const marker = if (line_count > 10)
                std.fmt.bufPrint(&marker_buf, "[paste #{d} +{d} lines]", .{ paste_id, line_count }) catch return
            else
                std.fmt.bufPrint(&marker_buf, "[paste #{d} {d} chars]", .{ paste_id, total_chars }) catch return;
            self.insertTextAtCursorInternal(marker);
            return;
        }

        self.insertTextAtCursorInternal(filtered.items);
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
        self.autocomplete.setTheme(self.theme orelse themes_builtin.dark());
        self.autocomplete.setProvider(provider);
    }

    pub fn cancelAutocomplete(self: *Editor) void {
        self.autocomplete.cancel();
    }

    pub fn handleInput(self: *Editor, key: Key) bool {
        if (!self.focused) return false;

        const may_accept_autocomplete = self.autocomplete.isActive() and keybindings.isEditorAutocompleteAccept(key);
        var autocomplete_snapshot: ?UndoSnapshot = null;
        if (may_accept_autocomplete) {
            autocomplete_snapshot = self.captureUndoSnapshot() catch null;
        }
        switch (self.autocomplete.processInput(key, self.buffer)) {
            .accepted => |accepted| {
                if (autocomplete_snapshot) |snapshot| {
                    self.appendUndoSnapshot(snapshot);
                }
                self.last_action = .none;
                self.afterAutocompleteAcceptance();
                if (accepted.submit) {
                    if (self.disable_submit) return true;
                    self.submitValue();
                }
                return true;
            },
            .cancelled, .consumed => {
                if (autocomplete_snapshot) |snapshot| self.freeUndoSnapshot(snapshot);
                return true;
            },
            .unhandled => {
                if (autocomplete_snapshot) |snapshot| self.freeUndoSnapshot(snapshot);
            },
        }

        switch (keybindings.resolveEditorCommand(key)) {
            .action => |action| return self.handleEditorAction(action),
            .insert_codepoint => |cp| {
                self.insertCharacter(cp);
                return true;
            },
            .unhandled => return false,
        }
    }

    pub fn render(self: *Editor, region: Region) void {
        const w = region.width;
        const h = region.height;
        if (w == 0 or h < 3) return;

        self.autocomplete.setTheme(self.theme orelse themes_builtin.dark());

        const text_row_cap = @min(self.max_visible_lines, h - 2);
        self.syncViewGeometry(w, text_row_cap);
        const total_lines = self.view.totalVisualLineCount();
        const visible_rows = @min(total_lines, text_row_cap);
        self.syncViewGeometry(w, visible_rows);
        self.view.ensureCursorVisible();

        const editor_h = visible_rows + 2;
        const frame = box_chrome.closedFrame(region.sub(0, 0, w, editor_h));

        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var left_buf: [256]u8 = undefined;
            var right_buf: [256]u8 = undefined;
            const left_text = self.formatStatusLeft(&left_buf);
            const right_text = self.formatStatusRight(&right_buf);
            _ = frame.drawTop(left_text, right_text, style);
        }
        {
            const style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            _ = frame.drawBottom(style);
        }

        const inner = frame.inner.sub(0, 0, frame.inner.width, visible_rows);
        {
            const chrome_style = box_chrome.Style{ .chrome = self.border_color, .fg = self.border_color, .dim = self.border_color };
            var row: u32 = 0;
            while (row < inner.height) : (row += 1) {
                frame.innerRow(row).fill(0, 0, inner.width, 1, .{
                    .grapheme = .{ .codepoint = ' ' },
                    .fg = Color.default,
                    .bg = Color.default,
                });
                _ = frame.drawBodyRow(row, chrome_style);
            }
        }

        editor_core.renderVisibleLines(inner, self.buffer, self.view.visibleLines(), RenderConfig{
            .prompt = self.prompt,
            .continuation_prompt = self.continuationPrompt(),
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
        self.autocomplete.setTheme(self.theme orelse themes_builtin.dark());
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
            .x = 1 + cursor.visual_col + self.last_applied_padding_x,
            .y = cursor.visual_row + 1,
            .style = .bar,
        };
    }

    pub fn nextAnimationDeadline(self: *Editor, now_ns: i128) ?i128 {
        return self.autocomplete.nextAnimationDeadline(now_ns);
    }

    pub fn tickAnimation(self: *Editor, now_ns: i128) bool {
        const needs_snapshot = self.autocomplete.nextAnimationDeadline(now_ns) != null;
        const snapshot = if (needs_snapshot) self.captureUndoSnapshot() catch null else null;
        const outcome = self.autocomplete.tickAnimation(self.buffer, now_ns);
        if (outcome.accepted) {
            if (snapshot) |value| self.appendUndoSnapshot(value);
            self.afterAutocompleteAcceptance();
        } else if (snapshot) |value| {
            self.freeUndoSnapshot(value);
        }
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

    fn handleEditorAction(self: *Editor, action: BindingAction) bool {
        switch (action) {
            .editor_undo => {
                self.undo();
                return true;
            },
            .input_new_line => {
                self.history_index = -1;
                self.last_action = .none;
                self.pushUndoSnapshot();
                self.buffer.insertNewline();
                self.afterTextMutation();
                return true;
            },
            .input_submit => {
                const cursor_byte = self.buffer.cursorByte();
                if (cursor_byte > 0 and self.buffer.text()[cursor_byte - 1] == '\\') {
                    self.history_index = -1;
                    self.last_action = .none;
                    self.pushUndoSnapshot();
                    self.buffer.backspace();
                    self.buffer.insertNewline();
                    self.afterTextMutation();
                    return true;
                }

                if (self.disable_submit) return true;
                self.submitValue();
                return true;
            },
            .editor_backspace => {
                self.history_index = -1;
                self.last_action = .none;
                if (self.buffer.cursorByte() > 0) {
                    self.pushUndoSnapshot();
                    if (self.findMarkerRangeTouchingCursor(.left)) |range| {
                        self.buffer.replaceRange(range.start, range.end, "", 0);
                    } else {
                        self.buffer.backspace();
                    }
                    self.afterTextMutation();
                }
                return true;
            },
            .editor_delete => {
                self.history_index = -1;
                self.last_action = .none;
                if (self.buffer.cursorByte() < self.buffer.text().len) {
                    self.pushUndoSnapshot();
                    if (self.findMarkerRangeTouchingCursor(.right)) |range| {
                        self.buffer.replaceRange(range.start, range.end, "", 0);
                    } else {
                        self.buffer.deleteForward();
                    }
                    self.afterTextMutation();
                }
                return true;
            },
            .editor_move_left => {
                if (self.findMarkerRangeTouchingCursor(.left)) |range| {
                    self.buffer.setCursorByte(range.start);
                } else {
                    self.buffer.moveLeft();
                }
                self.afterCursorMotion();
                return true;
            },
            .editor_move_right => {
                if (self.findMarkerRangeTouchingCursor(.right)) |range| {
                    self.buffer.setCursorByte(range.end);
                } else {
                    self.buffer.moveRight();
                }
                self.afterCursorMotion();
                return true;
            },
            .editor_move_up => {
                if (self.buffer.text().len == 0) {
                    self.navigateHistory(-1);
                } else if (self.history_index > -1 and self.view.isCursorOnFirstVisualLine()) {
                    self.navigateHistory(-1);
                } else if (self.view.isCursorOnFirstVisualLine()) {
                    self.buffer.moveLogicalLineStart();
                    self.afterCursorMotion();
                } else {
                    self.last_action = .none;
                    self.view.moveUpVisual();
                }
                return true;
            },
            .editor_move_down => {
                if (self.history_index > -1 and self.view.isCursorOnLastVisualLine()) {
                    self.navigateHistory(1);
                } else if (self.view.isCursorOnLastVisualLine()) {
                    self.buffer.moveLogicalLineEnd();
                    self.afterCursorMotion();
                } else {
                    self.last_action = .none;
                    self.view.moveDownVisual();
                }
                return true;
            },
            .editor_move_home => {
                self.buffer.moveLogicalLineStart();
                self.afterCursorMotion();
                return true;
            },
            .editor_move_end => {
                self.buffer.moveLogicalLineEnd();
                self.afterCursorMotion();
                return true;
            },
            else => return false,
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

    fn insertTextAtCursorInternal(self: *Editor, text: []const u8) void {
        if (text.len == 0) return;
        self.buffer.insertAtCursor(text);
        self.afterTextMutation();
    }

    fn expandPasteMarkers(self: *Editor) []const u8 {
        if (self.pastes.count() == 0) return self.buffer.text();

        self.expanded_text_cache.clearRetainingCapacity();
        const text = self.buffer.text();
        var last: usize = 0;
        var index: usize = 0;
        var expanded_any = false;
        while (index < text.len) {
            if (text[index] == '[') {
                if (parsePasteMarker(text, index)) |marker| {
                    if (self.pastes.get(marker.id)) |paste| {
                        self.expanded_text_cache.appendSlice(self.allocator, text[last..index]) catch return self.buffer.text();
                        self.expanded_text_cache.appendSlice(self.allocator, paste) catch return self.buffer.text();
                        last = marker.end;
                        index = marker.end;
                        expanded_any = true;
                        continue;
                    }
                }
            }
            index += 1;
        }

        if (!expanded_any) return self.buffer.text();
        self.expanded_text_cache.appendSlice(self.allocator, text[last..]) catch return self.buffer.text();
        return self.expanded_text_cache.items;
    }

    fn navigateHistory(self: *Editor, direction: i32) void {
        self.last_action = .none;
        if (self.history.items.len == 0) return;

        const max_index: i32 = @intCast(self.history.items.len);
        const new_index = self.history_index - direction;
        if (new_index < -1 or new_index >= max_index) return;

        if (self.history_index == -1 and new_index >= 0) {
            self.pushUndoSnapshot();
        }

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
        self.last_action = .none;
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
    }

    fn afterAutocompleteAcceptance(self: *Editor) void {
        self.last_action = .none;
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        self.notifyChange();
    }

    fn insertCharacter(self: *Editor, cp: u21) void {
        self.history_index = -1;
        if (isWhitespaceCodepoint(cp) or self.last_action != .type_word) {
            self.pushUndoSnapshot();
        }
        self.last_action = .type_word;

        var utf8_buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &utf8_buf) catch return;
        self.buffer.insertAtCursor(utf8_buf[0..len]);
        self.afterTextMutation();
    }

    fn submitValue(self: *Editor) void {
        const submitted_text = self.expandPasteMarkers();
        const trimmed = std.mem.trim(u8, submitted_text, " \t\r\n");
        const result = self.allocator.dupe(u8, trimmed) catch return;
        defer self.allocator.free(result);

        self.cancelAutocomplete();
        self.buffer.clear();
        self.view.resetViewport();
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        self.history_index = -1;
        self.last_action = .none;
        self.clearUndoStack();
        self.clearStoredPastes();
        self.paste_counter = 0;

        self.notifyChange();
        if (self.on_submit) |cb| cb(result, self.on_submit_ctx);
    }

    fn undo(self: *Editor) void {
        self.history_index = -1;
        const snapshot = self.popUndoSnapshot() orelse return;
        defer self.freeUndoSnapshot(snapshot);

        self.buffer.setTextAndCursor(snapshot.text, snapshot.cursor_byte);
        self.last_action = .none;
        self.view.resetViewport();
        self.view.clearDesiredVisualColumn();
        self.syncStoredViewGeometry();
        self.view.ensureCursorVisible();
        self.notifyChange();
    }

    fn captureUndoSnapshot(self: *Editor) !UndoSnapshot {
        return .{
            .text = try self.allocator.dupe(u8, self.buffer.text()),
            .cursor_byte = self.buffer.cursorByte(),
        };
    }

    fn pushUndoSnapshot(self: *Editor) void {
        const snapshot = self.captureUndoSnapshot() catch return;
        self.appendUndoSnapshot(snapshot);
    }

    fn appendUndoSnapshot(self: *Editor, snapshot: UndoSnapshot) void {
        self.undo_stack.append(self.allocator, snapshot) catch {
            self.freeUndoSnapshot(snapshot);
        };
    }

    fn popUndoSnapshot(self: *Editor) ?UndoSnapshot {
        return self.undo_stack.pop();
    }

    fn freeUndoSnapshot(self: *Editor, snapshot: UndoSnapshot) void {
        self.allocator.free(snapshot.text);
    }

    fn clearUndoStack(self: *Editor) void {
        for (self.undo_stack.items) |snapshot| self.freeUndoSnapshot(snapshot);
        self.undo_stack.clearRetainingCapacity();
    }

    fn clearStoredPastes(self: *Editor) void {
        var it = self.pastes.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.value_ptr.*);
        }
        self.pastes.clearRetainingCapacity();
        self.expanded_text_cache.clearRetainingCapacity();
    }

    fn findMarkerRangeTouchingCursor(self: *const Editor, side: enum { left, right }) ?MarkerRange {
        const text = self.buffer.text();
        const cursor = self.buffer.cursorByte();
        const line_start: usize = self.buffer.currentLineStart();
        const line_end: usize = self.buffer.currentLineEnd();
        var index = line_start;
        while (index < line_end) {
            if (text[index] == '[') {
                if (self.validMarkerRangeAt(@intCast(index))) |range| {
                    const matches = switch (side) {
                        .left => cursor > range.start and cursor <= range.end,
                        .right => cursor >= range.start and cursor < range.end,
                    };
                    if (matches) return range;
                    index = range.end;
                    continue;
                }
            }
            index += 1;
        }
        return null;
    }

    fn validMarkerRangeAt(self: *const Editor, start: u32) ?MarkerRange {
        const marker = parsePasteMarker(self.buffer.text(), start) orelse return null;
        if (!self.pastes.contains(marker.id)) return null;
        return .{ .start = start, .end = @intCast(marker.end) };
    }

    fn cursorPrecededByWordByte(self: *const Editor) bool {
        const cursor = self.buffer.cursorByte();
        if (cursor == 0) return false;
        const byte = self.buffer.text()[cursor - 1];
        return std.ascii.isAlphanumeric(byte) or byte == '_';
    }

    fn syncStoredViewGeometry(self: *Editor) void {
        self.syncViewGeometry(self.last_total_width, self.last_viewport_rows);
    }

    fn syncViewGeometry(self: *Editor, total_width: u32, viewport_rows: u32) void {
        const applied_padding = self.appliedPaddingX(total_width);
        const content_width = self.effectiveContentWidth(total_width);
        const prompt_width: u32 = @intCast(grapheme_mod.strWidth(self.prompt));
        const continuation_width: u32 = @intCast(grapheme_mod.strWidth(self.continuationPrompt()));

        self.last_total_width = total_width;
        self.last_applied_padding_x = applied_padding;
        self.last_content_width = content_width;
        self.last_viewport_rows = @max(@as(u32, 1), viewport_rows);

        self.view.setLayoutConfig(.{
            .width_cols = content_width,
            .first_line_text_col = prompt_width,
            .continuation_text_col = continuation_width,
        });
        self.view.setViewportHeight(self.last_viewport_rows);
    }

    fn appliedPaddingX(self: *const Editor, total_width: u32) u32 {
        const drawable_width = self.drawableContentRegionWidth(total_width);
        if (drawable_width <= 1) return 0;
        return @min(self.padding_x, @divFloor(drawable_width - 1, @as(u32, 2)));
    }

    fn effectiveContentWidth(self: *const Editor, total_width: u32) u32 {
        const drawable_width = self.drawableContentRegionWidth(total_width);
        const applied = self.appliedPaddingX(total_width);
        return if (drawable_width > applied * 2) drawable_width - applied * 2 else 1;
    }

    fn drawableContentRegionWidth(self: *const Editor, total_width: u32) u32 {
        _ = self;
        return box_chrome.closedInnerWidth(total_width);
    }

    fn getGitBranch(self: *const Editor) ?[]const u8 {
        if (self.git_branch_len == 0) return null;
        return self.git_branch_buf[0..self.git_branch_len];
    }

    fn continuationPrompt(self: *const Editor) []const u8 {
        return if (self.prompt.len == 0) "" else "  ";
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

        if (status.thinking_level.len > 0) {
            const written = std.fmt.bufPrint(buf[pos..], " ({s})", .{status.thinking_level}) catch "";
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
const Buffer = buffer_mod.Buffer;

const PasteMarker = struct {
    id: u32,
    end: usize,
};

fn parsePasteMarker(text: []const u8, start: usize) ?PasteMarker {
    const prefix = "[paste #";
    if (start + prefix.len >= text.len) return null;
    if (!std.mem.startsWith(u8, text[start..], prefix)) return null;

    var index = start + prefix.len;
    const id_start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    if (index == id_start) return null;
    const id = std.fmt.parseInt(u32, text[id_start..index], 10) catch return null;

    if (index >= text.len) return null;
    if (text[index] == ']') {
        return .{ .id = id, .end = index + 1 };
    }
    if (text[index] != ' ') return null;
    index += 1;
    if (index >= text.len) return null;

    if (text[index] == '+') {
        index += 1;
        const count_start = index;
        while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
        if (index == count_start) return null;
        if (!std.mem.startsWith(u8, text[index..], " lines]")) return null;
        return .{ .id = id, .end = index + " lines]".len };
    }

    const count_start = index;
    while (index < text.len and std.ascii.isDigit(text[index])) : (index += 1) {}
    if (index == count_start) return null;
    if (!std.mem.startsWith(u8, text[index..], " chars]")) return null;
    return .{ .id = id, .end = index + " chars]".len };
}

fn appendNormalizedPaste(out: *std.ArrayList(u8), allocator: std.mem.Allocator, pasted_text: []const u8) !void {
    var index: usize = 0;
    while (index < pasted_text.len) : (index += 1) {
        const byte = pasted_text[index];
        switch (byte) {
            '\r' => {
                if (index + 1 < pasted_text.len and pasted_text[index + 1] == '\n') {
                    index += 1;
                }
                try out.append(allocator, '\n');
            },
            '\t' => try out.appendSlice(allocator, "    "),
            '\n' => try out.append(allocator, '\n'),
            else => {
                if (byte >= 0x20) {
                    try out.append(allocator, byte);
                }
            },
        }
    }
}

fn isPastePathLike(text: []const u8) bool {
    return text.len > 0 and switch (text[0]) {
        '/', '~', '.' => true,
        else => false,
    };
}

fn countPasteLines(text: []const u8) usize {
    var count: usize = 1;
    for (text) |byte| {
        if (byte == '\n') count += 1;
    }
    return count;
}

fn isWhitespaceCodepoint(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r' => true,
        else => false,
    };
}

const SubmitCapture = struct {
    count: u32 = 0,
    last_text_len: usize = 0,
    last_text_buf: [128]u8 = undefined,
};

fn captureSubmit(text: []const u8, ctx: ?*anyopaque) void {
    const capture: *SubmitCapture = @ptrCast(@alignCast(ctx));
    capture.count += 1;
    capture.last_text_len = @min(text.len, capture.last_text_buf.len);
    @memcpy(capture.last_text_buf[0..capture.last_text_len], text[0..capture.last_text_len]);
}

fn submittedText(capture: *const SubmitCapture) []const u8 {
    return capture.last_text_buf[0..capture.last_text_len];
}

fn bufferRowAscii(buf: *const Buffer, row: u32, out: []u8) []const u8 {
    const width = @min(buf.width, out.len);
    for (0..width) |x| {
        const cell = buf.get(@intCast(x), row);
        const cp = switch (cell.grapheme) {
            .codepoint => |value| value,
            .pooled => ' ',
        };
        out[x] = if (cp < 128) @intCast(cp) else ' ';
    }
    return out[0..width];
}

test "Editor status line renders thinking inline with model" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var status = StatusData.init(testing.allocator);
    defer status.deinit();
    status.setModelId("claude-4-sonnet");
    status.setThinkingLevel("high");
    status.context_tokens = 1_234;
    status.context_window = 200_000;

    editor.setStatusData(&status);

    var buf: [128]u8 = undefined;
    try testing.expectEqualStrings(
        "ctx 1.2k/200k • claude-4-sonnet (high)",
        editor.formatStatusRight(&buf).?,
    );
}

test "Editor renders input without a prompt marker" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();
    editor.insertText("hello world");

    var buf = try Buffer.init(testing.allocator, 24, 4);
    defer buf.deinit();
    editor.render(buf.region());

    var row_buf: [64]u8 = undefined;
    const row = bufferRowAscii(&buf, 1, &row_buf);
    try testing.expect(std.mem.indexOf(u8, row, "hello world") != null);
    try testing.expect(std.mem.indexOfScalar(u8, row, '>') == null);
}

test "Editor renders closed side borders on content rows" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();
    editor.insertText("hello");

    var buf = try Buffer.init(testing.allocator, 12, 4);
    defer buf.deinit();
    editor.render(buf.region());

    try testing.expectEqual(@as(u21, '│'), buf.get(0, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '│'), buf.get(11, 1).grapheme.codepoint);
}

test "Editor keeps the last pre-wrap character visible before the right border" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();
    editor.insertText("abcdef");

    var buf = try Buffer.init(testing.allocator, 8, 4);
    defer buf.deinit();
    editor.render(buf.region());

    try testing.expectEqual(@as(u21, 'f'), buf.get(6, 1).grapheme.codepoint);
    try testing.expectEqual(@as(u21, '│'), buf.get(7, 1).grapheme.codepoint);
}

test "Editor undo coalesces typing by word boundaries" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    for ("hi there") |c| {
        try testing.expect(editor.handleInput(.{ .code = .char, .char = c }));
    }
    try testing.expectEqualStrings("hi there", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("hi", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("", editor.getText());
}

test "Editor undo restores destructive backspace and delete edits" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.setText("abc");
    try testing.expectEqualStrings("abc", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .backspace }));
    try testing.expectEqualStrings("ab", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("abc", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .left }));
    try testing.expect(editor.handleInput(.{ .code = .delete }));
    try testing.expectEqualStrings("ab", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("abc", editor.getText());
}

test "Editor undo restores autocomplete application as one edit" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = autocomplete_mod.SlashCommandProvider.init(&registry);
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();
    editor.setAutocompleteProvider(provider.provider());

    editor.insertText("/mo");
    try testing.expect(editor.autocomplete.isActive());

    try testing.expect(editor.handleInput(.{ .code = .tab }));
    try testing.expectEqualStrings("/model ", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("/mo", editor.getText());
}

test "Editor submit actions preserve disable-submit and escaped newline semantics" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));
    editor.setSubmitDisabled(true);

    editor.insertText("draft");
    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 0), capture.count);
    try testing.expectEqualStrings("draft", editor.getText());

    editor.setText("line\\");
    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 0), capture.count);
    try testing.expectEqualStrings("line\n", editor.getText());

    editor.setSubmitDisabled(false);
    editor.setText("alpha");
    try testing.expect(editor.handleInput(.{ .code = .enter, .shift = true }));
    try testing.expectEqualStrings("alpha\n", editor.getText());
}

test "Editor autocomplete confirm respects disable-submit and stays undoable" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = autocomplete_mod.SlashCommandProvider.init(&registry);
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));
    editor.setAutocompleteProvider(provider.provider());
    editor.setSubmitDisabled(true);

    editor.insertText("/mo");
    try testing.expect(editor.autocomplete.isActive());

    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 0), capture.count);
    try testing.expectEqualStrings("/model ", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("/mo", editor.getText());
}

test "Editor history browsing snapshots the empty draft and submit clears undo state" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));
    editor.addToHistory("old prompt");

    try testing.expect(editor.handleInput(.{ .code = .up }));
    try testing.expectEqualStrings("old prompt", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '!' }));
    try testing.expectEqualStrings("old prompt!", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("old prompt", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("", editor.getText());

    editor.insertText("draft");
    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 1), capture.count);
    try testing.expectEqualStrings("draft", submittedText(&capture));
    try testing.expectEqualStrings("", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("", editor.getText());
}

test "Editor up/down keep wrapped-line movement and history crossover semantics" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.setText("abcd efgh ijkl");
    _ = editor.measure(9);
    editor.buffer.setCursorByte(5);
    editor.view.clearDesiredVisualColumn();

    try testing.expect(editor.handleInput(.{ .code = .down }));
    try testing.expectEqual(@as(u32, 10), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .up }));
    try testing.expectEqual(@as(u32, 5), editor.buffer.cursorByte());

    editor.setText("hello");
    editor.buffer.setCursorByte(3);

    try testing.expect(editor.handleInput(.{ .code = .up }));
    try testing.expectEqual(@as(u32, 0), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .down }));
    try testing.expectEqual(@as(u32, 5), editor.buffer.cursorByte());

    editor.clear();
    editor.addToHistory("older");

    try testing.expect(editor.handleInput(.{ .code = .up }));
    try testing.expectEqualStrings("older", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .down }));
    try testing.expectEqualStrings("", editor.getText());
}

test "Editor handlePaste normalizes content and undoes atomically" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.setText("open");
    editor.handlePaste("/tmp\tfile\r\nnext\x01");
    try testing.expectEqualStrings("open /tmp    file\nnext", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings("open", editor.getText());
}

test "Editor large multiline paste inserts marker and submits expanded content" {
    const pasted =
        "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11";

    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var capture = SubmitCapture{};
    editor.setOnSubmit(&captureSubmit, @ptrCast(&capture));

    editor.handlePaste(pasted);
    try testing.expectEqualStrings("[paste #1 +11 lines]", editor.getText());
    try testing.expectEqualStrings(pasted, editor.getExpandedText());

    try testing.expect(editor.handleInput(.{ .code = .enter }));
    try testing.expectEqual(@as(u32, 1), capture.count);
    try testing.expectEqualStrings(pasted, submittedText(&capture));
    try testing.expectEqualStrings("", editor.getText());
    try testing.expectEqualStrings("", editor.getExpandedText());
}

test "Editor large single-line paste inserts char-count marker" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    var pasted: [1001]u8 = undefined;
    @memset(&pasted, 'a');

    editor.handlePaste(pasted[0..]);
    try testing.expectEqualStrings("[paste #1 1001 chars]", editor.getText());
    try testing.expectEqual(@as(usize, 1001), editor.getExpandedText().len);
    try testing.expectEqualStrings(pasted[0..], editor.getExpandedText());
}

test "Editor cursor arrows skip stored paste markers atomically" {
    const pasted =
        "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11";

    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.insertText("A");
    editor.handlePaste(pasted);
    editor.insertText("B");

    const marker_len = editor.getText().len - 2;

    try testing.expect(editor.handleInput(.{ .code = .home }));
    try testing.expectEqual(@as(u32, 0), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .right }));
    try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .right }));
    try testing.expectEqual(@as(u32, @intCast(1 + marker_len)), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .left }));
    try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());

    try testing.expect(editor.handleInput(.{ .code = .left }));
    try testing.expectEqual(@as(u32, 0), editor.buffer.cursorByte());
}

test "Editor delete keys remove stored paste markers atomically" {
    const pasted =
        "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11";

    {
        var editor = Editor.init(testing.allocator);
        defer editor.deinit();

        editor.insertText("A");
        editor.handlePaste(pasted);
        editor.insertText("B");

        try testing.expect(editor.handleInput(.{ .code = .home }));
        try testing.expect(editor.handleInput(.{ .code = .right }));
        try testing.expect(editor.handleInput(.{ .code = .right }));
        try testing.expect(editor.handleInput(.{ .code = .backspace }));
        try testing.expectEqualStrings("AB", editor.getText());
        try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
    }

    {
        var editor = Editor.init(testing.allocator);
        defer editor.deinit();

        editor.insertText("A");
        editor.handlePaste(pasted);
        editor.insertText("B");

        try testing.expect(editor.handleInput(.{ .code = .home }));
        try testing.expect(editor.handleInput(.{ .code = .right }));
        try testing.expect(editor.handleInput(.{ .code = .delete }));
        try testing.expectEqualStrings("AB", editor.getText());
        try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
    }
}

test "Editor undo restores marker after atomic marker deletion" {
    const pasted =
        "line1\nline2\nline3\nline4\nline5\nline6\nline7\nline8\nline9\nline10\nline11";

    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.insertText("A");
    editor.handlePaste(pasted);
    editor.insertText("B");
    const original = try testing.allocator.dupe(u8, editor.getText());
    defer testing.allocator.free(original);

    try testing.expect(editor.handleInput(.{ .code = .home }));
    try testing.expect(editor.handleInput(.{ .code = .right }));
    try testing.expect(editor.handleInput(.{ .code = .right }));
    try testing.expect(editor.handleInput(.{ .code = .backspace }));
    try testing.expectEqualStrings("AB", editor.getText());

    try testing.expect(editor.handleInput(.{ .code = .char, .char = '-', .ctrl = true }));
    try testing.expectEqualStrings(original, editor.getText());
}

test "Editor ignores manually typed marker-like text for atomic movement" {
    var editor = Editor.init(testing.allocator);
    defer editor.deinit();

    editor.setText("[paste #99 +5 lines]");
    try testing.expect(editor.handleInput(.{ .code = .home }));
    try testing.expect(editor.handleInput(.{ .code = .right }));
    try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
}

test "Editor arrow keys move by grapheme cluster for combining marks and emoji" {
    const Case = struct {
        text: []const u8,
        atomic_len: u32,
    };

    const cases = [_]Case{
        .{ .text = "Ae\u{0301}B", .atomic_len = @intCast("e\u{0301}".len) },
        .{ .text = "A👋🏿B", .atomic_len = @intCast("👋🏿".len) },
        .{ .text = "A👩‍🚀B", .atomic_len = @intCast("👩‍🚀".len) },
        .{ .text = "A🇨🇦B", .atomic_len = @intCast("🇨🇦".len) },
    };

    for (cases) |case| {
        var editor = Editor.init(testing.allocator);
        defer editor.deinit();

        editor.setText(case.text);
        try testing.expect(editor.handleInput(.{ .code = .home }));
        try testing.expect(editor.handleInput(.{ .code = .right }));
        try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());

        try testing.expect(editor.handleInput(.{ .code = .right }));
        try testing.expectEqual(@as(u32, 1) + case.atomic_len, editor.buffer.cursorByte());

        try testing.expect(editor.handleInput(.{ .code = .left }));
        try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
    }
}

test "Editor backspace and delete remove whole grapheme clusters" {
    const Case = struct {
        atomic: []const u8,
    };

    const cases = [_]Case{
        .{ .atomic = "e\u{0301}" },
        .{ .atomic = "👋🏿" },
        .{ .atomic = "👩‍🚀" },
        .{ .atomic = "🇨🇦" },
    };

    for (cases) |case| {
        {
            var editor = Editor.init(testing.allocator);
            defer editor.deinit();

            const text = try std.fmt.allocPrint(testing.allocator, "A{s}B", .{case.atomic});
            defer testing.allocator.free(text);
            editor.setText(text);

            try testing.expect(editor.handleInput(.{ .code = .home }));
            try testing.expect(editor.handleInput(.{ .code = .right }));
            try testing.expect(editor.handleInput(.{ .code = .right }));
            try testing.expect(editor.handleInput(.{ .code = .backspace }));
            try testing.expectEqualStrings("AB", editor.getText());
            try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
        }

        {
            var editor = Editor.init(testing.allocator);
            defer editor.deinit();

            const text = try std.fmt.allocPrint(testing.allocator, "A{s}B", .{case.atomic});
            defer testing.allocator.free(text);
            editor.setText(text);

            try testing.expect(editor.handleInput(.{ .code = .home }));
            try testing.expect(editor.handleInput(.{ .code = .right }));
            try testing.expect(editor.handleInput(.{ .code = .delete }));
            try testing.expectEqualStrings("AB", editor.getText());
            try testing.expectEqual(@as(u32, 1), editor.buffer.cursorByte());
        }
    }
}
