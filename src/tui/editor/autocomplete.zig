const std = @import("std");
const autocomplete_mod = @import("../autocomplete.zig");
const keys_mod = @import("../terminal/keys.zig");
const theme_mod = @import("../theme.zig");
const select_list_mod = @import("../components/select_list.zig");
const component_mod = @import("../component.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const buffer_mod = @import("buffer.zig");
const keybindings = @import("../keybindings.zig");

const Key = keys_mod.Key;
const Theme = theme_mod.Theme;
const SelectItem = select_list_mod.SelectItem;
const SelectList = select_list_mod.SelectList;
const Suggestions = autocomplete_mod.Suggestions;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const RequestMode = autocomplete_mod.RequestMode;
const PromptBuffer = buffer_mod.PromptBuffer;
const Measurement = component_mod.Measurement;

pub const InputOutcome = union(enum) {
    unhandled,
    consumed,
    accepted: struct {
        submit: bool,
    },
    cancelled,
};

pub const TickOutcome = struct {
    changed: bool,
    accepted: bool,
};

pub const AutocompleteSession = struct {
    provider: ?AutocompleteProvider = null,
    list: SelectList = undefined,
    active: bool = false,
    request_mode: RequestMode = .regular,
    replace_start_byte: u32 = 0,
    replace_end_byte: u32 = 0,
    submit_on_confirm: bool = false,
    auto_accept_single_on_tab: bool = false,
    max_visible: u32 = 5,
    theme: *const Theme = undefined,
    sink_ctx: SinkCtx = .{},

    const SinkCtx = struct {
        session: *AutocompleteSession = undefined,
    };

    pub fn init(theme: *const Theme) AutocompleteSession {
        return .{
            .theme = theme,
            .list = .{
                .theme = theme,
            },
        };
    }

    pub fn setTheme(self: *AutocompleteSession, theme: *const Theme) void {
        self.theme = theme;
        self.list.theme = theme;
    }

    pub fn setProvider(self: *AutocompleteSession, provider: AutocompleteProvider) void {
        self.cancel();
        self.provider = provider;
    }

    pub fn setMaxVisible(self: *AutocompleteSession, max_visible: u32) void {
        self.max_visible = @max(@as(u32, 3), @min(@as(u32, 20), max_visible));
        self.list.max_visible = self.max_visible;
    }

    pub fn refresh(self: *AutocompleteSession, buffer: *const PromptBuffer) void {
        self.request(buffer, self.request_mode);
    }

    pub fn cancel(self: *AutocompleteSession) void {
        if (self.provider) |provider| provider.cancel();
        self.active = false;
        self.request_mode = .regular;
        self.replace_start_byte = 0;
        self.replace_end_byte = 0;
        self.submit_on_confirm = false;
        self.auto_accept_single_on_tab = false;
        self.list.items = &.{};
        self.list.selected_index = 0;
    }

    pub fn nextAnimationDeadline(self: *const AutocompleteSession, now_ns: i128) ?i128 {
        const provider = self.provider orelse return null;
        return provider.nextDeadline(now_ns);
    }

    pub fn tickAnimation(self: *AutocompleteSession, buffer: *PromptBuffer, now_ns: i128) TickOutcome {
        const provider = self.provider orelse return .{ .changed = false, .accepted = false };
        self.sink_ctx = .{ .session = self };
        const changed = provider.tick(now_ns, .{ .ptr = @ptrCast(&self.sink_ctx), .publish_fn = &sinkCallback });
        if (!changed) return .{ .changed = false, .accepted = false };
        if (self.isActive() and self.auto_accept_single_on_tab and self.list.items.len == 1) {
            if (self.accept(buffer)) {
                return .{ .changed = true, .accepted = true };
            }
            self.cancel();
        }
        return .{ .changed = true, .accepted = false };
    }

    pub fn measure(self: *const AutocompleteSession, width: u32) Measurement {
        if (!self.active or self.list.items.len == 0) {
            return .{ .min_height = 0, .preferred_height = 0 };
        }
        return self.list.measure(width);
    }

    pub fn render(self: *const AutocompleteSession, region: anytype) void {
        if (!self.active or self.list.items.len == 0) return;
        self.list.render(region);
    }

    pub fn isActive(self: *const AutocompleteSession) bool {
        return self.active and self.list.items.len > 0;
    }

    pub fn processInput(self: *AutocompleteSession, key: Key, buffer: *PromptBuffer) InputOutcome {
        if (!self.isActive()) {
            if (keybindings.matches(.input_tab, key)) {
                return self.trigger(buffer);
            }
            return .unhandled;
        }

        const result = self.list.processInput(key);
        switch (result) {
            .selected => {
                const should_submit = self.submit_on_confirm;
                if (self.accept(buffer)) {
                    return .{ .accepted = .{ .submit = should_submit } };
                }
                self.cancel();
                return .cancelled;
            },
            .cancelled => {
                self.cancel();
                return .cancelled;
            },
            .consumed => return .consumed,
            .unhandled => {
                if (keybindings.matches(.input_tab, key)) {
                    if (self.accept(buffer)) {
                        return .{ .accepted = .{ .submit = false } };
                    }
                    self.cancel();
                    return .cancelled;
                }
                if ((key.code == .char and !key.ctrl and !key.alt) or key.code == .backspace) {
                    return .unhandled;
                }
                self.cancel();
                return .unhandled;
            },
        }
    }

    fn trigger(self: *AutocompleteSession, buffer: *PromptBuffer) InputOutcome {
        if (self.provider == null) return .unhandled;
        self.request(buffer, .force);
        if (self.isActive() and self.auto_accept_single_on_tab and self.list.items.len == 1) {
            if (self.accept(buffer)) {
                return .{ .accepted = .{ .submit = false } };
            }
            self.cancel();
            return .cancelled;
        }
        return .consumed;
    }

    fn request(self: *AutocompleteSession, buffer: *const PromptBuffer, mode: RequestMode) void {
        const provider = self.provider orelse {
            self.cancel();
            return;
        };
        self.request_mode = mode;
        self.sink_ctx = .{ .session = self };
        provider.request(
            .{ .text = buffer.text(), .cursor_byte = buffer.cursorByte(), .mode = mode },
            .{ .ptr = @ptrCast(&self.sink_ctx), .publish_fn = &sinkCallback },
        );
    }

    fn accept(self: *AutocompleteSession, buffer: *PromptBuffer) bool {
        const provider = self.provider orelse return false;
        const item = self.list.getSelectedItem() orelse return false;
        const should_continue = shouldContinueAfterAccept(item);
        const result = provider.apply(
            buffer.text(),
            buffer.cursorByte(),
            item,
            .{ .start_byte = self.replace_start_byte, .end_byte = self.replace_end_byte },
        ) orelse return false;
        const applied_range: autocomplete_mod.ReplaceRange = result.replace_range orelse .{
            .start_byte = self.replace_start_byte,
            .end_byte = self.replace_end_byte,
        };
        buffer.replaceRange(
            applied_range.start_byte,
            applied_range.end_byte,
            result.replacement_text,
            result.cursor_in_replacement,
        );
        if (should_continue) {
            self.request(buffer, self.request_mode);
        } else {
            self.cancel();
        }
        return true;
    }

    fn shouldContinueAfterAccept(item: *const SelectItem) bool {
        return std.mem.endsWith(u8, item.label, "/");
    }

    fn sinkCallback(ptr: *anyopaque, suggestions: ?Suggestions) void {
        const ctx: *SinkCtx = @ptrCast(@alignCast(ptr));
        ctx.session.publishSuggestions(suggestions);
    }

    fn publishSuggestions(self: *AutocompleteSession, suggestions: ?Suggestions) void {
        if (suggestions) |value| {
            if (value.items.len > 0) {
                self.list.theme = self.theme;
                self.list.max_visible = self.max_visible;
                self.list.setItems(value.items);
                self.request_mode = value.refresh_mode;
                self.replace_start_byte = value.replace_range.start_byte;
                self.replace_end_byte = value.replace_range.end_byte;
                self.submit_on_confirm = value.submit_on_confirm;
                self.auto_accept_single_on_tab = value.auto_accept_single_on_tab;
                self.active = true;
                return;
            }
        }
        self.cancel();
    }
};

const testing = std.testing;

const TestProvider = struct {
    items: []const SelectItem = &.{},
    replacement_text: ?[]const u8 = null,
    replace_range: autocomplete_mod.ReplaceRange = .{ .start_byte = 0, .end_byte = 0 },
    result_replace_range: ?autocomplete_mod.ReplaceRange = null,
    submit_on_confirm: bool = false,
    refresh_mode: RequestMode = .regular,
    auto_accept_single_on_tab: bool = false,
    tick_items: []const SelectItem = &.{},
    tick_changed: bool = false,
    tick_auto_accept_single_on_tab: bool = false,
    request_count: u32 = 0,
    cancel_count: u32 = 0,
    apply_count: u32 = 0,
    last_mode: RequestMode = .regular,
    last_text: []const u8 = "",
    last_cursor: u32 = 0,
    last_applied_value: []const u8 = "",

    const vtable = AutocompleteProvider.VTable{
        .request = @ptrCast(&requestImpl),
        .cancel = @ptrCast(&cancelImpl),
        .apply = @ptrCast(&applyImpl),
        .tick = @ptrCast(&tickImpl),
    };

    fn provider(self: *TestProvider) AutocompleteProvider {
        return .{ .ptr = @ptrCast(self), .vtable = &vtable };
    }

    fn requestImpl(self: *TestProvider, snapshot: autocomplete_mod.RequestSnapshot, sink: autocomplete_mod.SuggestionSink) void {
        self.request_count += 1;
        self.last_mode = snapshot.mode;
        self.last_text = snapshot.text;
        self.last_cursor = snapshot.cursor_byte;
        if (self.items.len == 0) {
            sink.publish(null);
            return;
        }
        sink.publish(.{
            .items = self.items,
            .replace_range = self.replace_range,
            .submit_on_confirm = self.submit_on_confirm,
            .refresh_mode = self.refresh_mode,
            .auto_accept_single_on_tab = self.auto_accept_single_on_tab,
        });
    }

    fn cancelImpl(self: *TestProvider) void {
        self.cancel_count += 1;
    }

    fn applyImpl(self: *TestProvider, _: []const u8, _: u32, item: *const SelectItem, _: autocomplete_mod.ReplaceRange) ?autocomplete_mod.ApplyResult {
        self.apply_count += 1;
        self.last_applied_value = item.value;
        return .{
            .replacement_text = self.replacement_text orelse item.value,
            .cursor_in_replacement = @intCast((self.replacement_text orelse item.value).len),
            .replace_range = self.result_replace_range,
        };
    }

    fn tickImpl(self: *TestProvider, _: i128, sink: autocomplete_mod.SuggestionSink) bool {
        if (!self.tick_changed) return false;
        self.tick_changed = false;
        if (self.tick_items.len == 0) {
            sink.publish(null);
            return true;
        }
        sink.publish(.{
            .items = self.tick_items,
            .replace_range = self.replace_range,
            .auto_accept_single_on_tab = self.tick_auto_accept_single_on_tab,
        });
        return true;
    }
};

fn testSession(provider: *TestProvider) AutocompleteSession {
    var session = AutocompleteSession.init(themes_builtin.dark());
    session.setProvider(provider.provider());
    return session;
}

fn testPrompt(text: []const u8) PromptBuffer {
    var buffer = PromptBuffer.init(testing.allocator);
    buffer.setText(text);
    return buffer;
}

fn expectSessionActive(session: *const AutocompleteSession, expected: bool) !void {
    try testing.expectEqual(expected, session.isActive());
}

test "AutocompleteSession activates, preserves selection, and applies provider result" {
    const items = [_]SelectItem{
        .{ .value = "alpha", .label = "alpha" },
        .{ .value = "beta", .label = "beta" },
    };
    var provider = TestProvider{
        .items = &items,
        .replace_range = .{ .start_byte = 4, .end_byte = 6 },
        .submit_on_confirm = true,
    };
    var session = testSession(&provider);

    var buffer = testPrompt("say al tail");
    defer buffer.deinit();
    buffer.setCursorByte(6);

    try testing.expectEqual(InputOutcome.consumed, session.processInput(.{ .code = .tab }, &buffer));
    try expectSessionActive(&session, true);
    try testing.expectEqual(@as(u32, 1), provider.request_count);
    try testing.expectEqual(RequestMode.force, provider.last_mode);

    try testing.expectEqual(InputOutcome.consumed, session.processInput(.{ .code = .down }, &buffer));
    const outcome = session.processInput(.{ .code = .enter }, &buffer);

    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = true } }, outcome);
    try testing.expectEqualStrings("say beta tail", buffer.text());
    try testing.expectEqualStrings("beta", provider.last_applied_value);
    try testing.expectEqual(@as(u32, 1), provider.apply_count);
    try expectSessionActive(&session, false);
}

test "AutocompleteSession honors provider replacement range over stale editor text" {
    const items = [_]SelectItem{.{ .value = "model", .label = "model" }};
    var provider = TestProvider{
        .items = &items,
        .replace_range = .{ .start_byte = 0, .end_byte = 3 },
        .replacement_text = "/model ",
    };
    var session = testSession(&provider);

    var buffer = testPrompt("/mo");
    defer buffer.deinit();
    session.refresh(&buffer);
    try expectSessionActive(&session, true);

    buffer.insertAtCursor(" extra");
    const outcome = session.processInput(.{ .code = .tab }, &buffer);

    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = false } }, outcome);
    try testing.expectEqualStrings("/model  extra", buffer.text());
    try expectSessionActive(&session, false);
}

test "AutocompleteSession cancels on provider boundaries and keeps text edits unhandled" {
    var provider = TestProvider{};
    var session = AutocompleteSession.init(themes_builtin.dark());

    var buffer = testPrompt("hello");
    defer buffer.deinit();

    try testing.expectEqual(InputOutcome.unhandled, session.processInput(.{ .code = .tab }, &buffer));

    const items = [_]SelectItem{.{ .value = "hello", .label = "hello" }};
    provider.items = &items;
    provider.replace_range = .{ .start_byte = 0, .end_byte = 5 };
    session.setProvider(provider.provider());
    session.refresh(&buffer);
    try expectSessionActive(&session, true);

    try testing.expectEqual(InputOutcome.unhandled, session.processInput(.{ .code = .char, .char = 'x' }, &buffer));
    try expectSessionActive(&session, true);

    try testing.expectEqual(InputOutcome.cancelled, session.processInput(.{ .code = .escape }, &buffer));
    try expectSessionActive(&session, false);
    try testing.expectEqual(@as(u32, 1), provider.cancel_count);

    provider.items = &.{};
    session.refresh(&buffer);
    try expectSessionActive(&session, false);
    try testing.expectEqual(@as(u32, 2), provider.cancel_count);
}

test "AutocompleteSession refreshes after directory-like accept and auto-accepts tick result" {
    const dir_items = [_]SelectItem{.{ .value = "./src/", .label = "src/" }};
    const file_items = [_]SelectItem{.{ .value = "./src/main.zig", .label = "main.zig" }};
    var provider = TestProvider{
        .items = &dir_items,
        .tick_items = &file_items,
        .replace_range = .{ .start_byte = 0, .end_byte = 4 },
        .tick_changed = true,
        .tick_auto_accept_single_on_tab = true,
    };
    var session = testSession(&provider);

    var buffer = testPrompt("./sr");
    defer buffer.deinit();
    session.refresh(&buffer);

    provider.items = &file_items;
    provider.replace_range = .{ .start_byte = 0, .end_byte = 6 };
    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = false } }, session.processInput(.{ .code = .tab }, &buffer));
    try testing.expectEqualStrings("./src/", buffer.text());
    try expectSessionActive(&session, true);
    try testing.expectEqualStrings("main.zig", session.list.getSelectedItem().?.label);

    provider.replace_range = .{ .start_byte = 0, .end_byte = 6 };
    const tick = session.tickAnimation(&buffer, 0);
    try testing.expect(tick.changed);
    try testing.expect(tick.accepted);
    try testing.expectEqualStrings("./src/main.zig", buffer.text());
    try expectSessionActive(&session, false);
}
