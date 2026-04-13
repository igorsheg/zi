const std = @import("std");
const autocomplete_mod = @import("../autocomplete.zig");
const keys_mod = @import("../keys.zig");
const theme_mod = @import("../theme.zig");
const select_list_mod = @import("../components/select_list.zig");
const component_mod = @import("../component.zig");
const buffer_mod = @import("buffer.zig");
const keybindings = @import("../keybindings.zig");

const Key = keys_mod.Key;
const Theme = theme_mod.Theme;
const SelectList = select_list_mod.SelectList;
const Suggestions = autocomplete_mod.Suggestions;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const RequestMode = autocomplete_mod.RequestMode;
const SlashCommandProvider = autocomplete_mod.SlashCommandProvider;
const CombinedAutocompleteProvider = autocomplete_mod.CombinedAutocompleteProvider;
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
    theme: *const Theme = &Theme.dark,
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
        if (self.active) {
            if (self.provider) |provider| provider.cancel();
        }
        self.active = false;
        self.request_mode = .regular;
        self.replace_start_byte = 0;
        self.replace_end_byte = 0;
        self.submit_on_confirm = false;
        self.auto_accept_single_on_tab = false;
        self.list.items = &.{};
        self.list.selected_index = 0;
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
        self.sink_ctx = .{ .session = self };
        provider.request(
            .{ .text = buffer.text(), .cursor_byte = buffer.cursorByte(), .mode = mode },
            .{ .ptr = @ptrCast(&self.sink_ctx), .publish_fn = &sinkCallback },
        );
    }

    fn accept(self: *AutocompleteSession, buffer: *PromptBuffer) bool {
        const provider = self.provider orelse return false;
        const item = self.list.getSelectedItem() orelse return false;
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
        self.cancel();
        return true;
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

test "AutocompleteSession applies replacement range without borrowing mutable buffer slices" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = SlashCommandProvider.init(&registry);
    var session = AutocompleteSession.init(&Theme.dark);
    session.setProvider(provider.provider());

    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("/mo");

    session.refresh(&buffer);
    try testing.expect(session.isActive());

    const filler = "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx";
    buffer.insertAtCursor(filler);

    const outcome = session.processInput(.{ .code = .tab }, &buffer);
    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = false } }, outcome);
    try testing.expectEqualStrings("/model " ++ filler, buffer.text());
    try testing.expect(!session.isActive());
}

test "AutocompleteSession enter accepts slash command selection and requests submit" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = SlashCommandProvider.init(&registry);
    var session = AutocompleteSession.init(&Theme.dark);
    session.setProvider(provider.provider());

    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("/mo");

    session.refresh(&buffer);
    try testing.expect(session.isActive());

    const outcome = session.processInput(.{ .code = .enter }, &buffer);
    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = true } }, outcome);
    try testing.expectEqualStrings("/model ", buffer.text());
    try testing.expect(!session.isActive());
}

fn makeCombinedProvider(registry: *const @import("../../slash_commands.zig").CommandRegistry, cwd: []const u8) CombinedAutocompleteProvider {
    return CombinedAutocompleteProvider.init(registry, cwd);
}

test "AutocompleteSession enter accepts file completion without submit" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("src");
    try tmp.dir.writeFile(.{ .sub_path = "src/main.zig", .data = "const x = 1;" });

    const cwd = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(cwd);

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = makeCombinedProvider(&registry, cwd);
    var session = AutocompleteSession.init(&Theme.dark);
    session.setProvider(provider.provider());

    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("./src/ma");

    session.refresh(&buffer);
    try testing.expect(session.isActive());

    const outcome = session.processInput(.{ .code = .enter }, &buffer);
    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = false } }, outcome);
    try testing.expectEqualStrings("./src/main.zig", buffer.text());
    try testing.expect(!session.isActive());
}

test "AutocompleteSession tab force-completes a single file suggestion immediately" {
    const slash_commands_mod = @import("../../slash_commands.zig");

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "notes.md", .data = "hello" });

    const cwd = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(cwd);

    var registry = slash_commands_mod.CommandRegistry.init(testing.allocator);
    defer registry.deinit();

    var provider = makeCombinedProvider(&registry, cwd);
    var session = AutocompleteSession.init(&Theme.dark);
    session.setProvider(provider.provider());

    var buffer = PromptBuffer.init(testing.allocator);
    defer buffer.deinit();
    buffer.setText("/open no");

    const outcome = session.processInput(.{ .code = .tab }, &buffer);
    try testing.expectEqual(InputOutcome{ .accepted = .{ .submit = false } }, outcome);
    try testing.expectEqualStrings("/open notes.md", buffer.text());
    try testing.expect(!session.isActive());
}
