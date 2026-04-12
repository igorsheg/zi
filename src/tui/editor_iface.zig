const std = @import("std");
const component_mod = @import("component.zig");
const cell_mod = @import("cell.zig");
const autocomplete_mod = @import("autocomplete.zig");

const Component = component_mod.Component;
const Color = cell_mod.Color;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;

/// Type-erased editor interface for runtime editor swapping.
///
/// Matches pi-mono's EditorComponent surface where zi needs parity:
/// text access/manipulation, history seeding, autocomplete wiring,
/// appearance knobs, and submit/change callback seams. Interactive mode
/// should use this interface instead of reaching around to a concrete
/// editor for those capabilities.
pub const EditorInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const SubmitCallback = *const fn (text: []const u8, ctx: ?*anyopaque) void;
    pub const ChangeCallback = *const fn (text: []const u8, ctx: ?*anyopaque) void;

    pub const VTable = struct {
        get_text: *const fn (ptr: *anyopaque) []const u8,
        get_expanded_text: *const fn (ptr: *anyopaque) []const u8,
        set_text: *const fn (ptr: *anyopaque, text: []const u8) void,
        insert_text_at_cursor: *const fn (ptr: *anyopaque, text: []const u8) void,
        clear: *const fn (ptr: *anyopaque) void,
        add_to_history: *const fn (ptr: *anyopaque, text: []const u8) void,
        set_on_submit: *const fn (ptr: *anyopaque, cb: ?SubmitCallback, ctx: ?*anyopaque) void,
        set_on_change: *const fn (ptr: *anyopaque, cb: ?ChangeCallback, ctx: ?*anyopaque) void,
        set_autocomplete_provider: *const fn (ptr: *anyopaque, provider: AutocompleteProvider) void,
        set_border_color: *const fn (ptr: *anyopaque, color: Color) void,
        set_padding_x: *const fn (ptr: *anyopaque, padding: u32) void,
        set_autocomplete_max_visible: *const fn (ptr: *anyopaque, max_visible: u32) void,
        set_submit_disabled: *const fn (ptr: *anyopaque, disabled: bool) void,
        component: *const fn (ptr: *anyopaque) Component,
    };

    pub fn init(comptime T: type, ptr: *T) EditorInterface {
        const gen = struct {
            fn getText(erased: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.getText();
            }
            fn getExpandedText(erased: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.getExpandedText();
            }
            fn setText(erased: *anyopaque, text: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setText(text);
            }
            fn insertTextAtCursor(erased: *anyopaque, text: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.insertTextAtCursor(text);
            }
            fn clear(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.clear();
            }
            fn addToHistory(erased: *anyopaque, text: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.addToHistory(text);
            }
            fn setOnSubmit(erased: *anyopaque, cb: ?SubmitCallback, ctx: ?*anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setOnSubmit(cb, ctx);
            }
            fn setOnChange(erased: *anyopaque, cb: ?ChangeCallback, ctx: ?*anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setOnChange(cb, ctx);
            }
            fn setAutocompleteProvider(erased: *anyopaque, provider: AutocompleteProvider) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setAutocompleteProvider(provider);
            }
            fn setBorderColor(erased: *anyopaque, color: Color) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setBorderColor(color);
            }
            fn setPaddingX(erased: *anyopaque, padding: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setPaddingX(padding);
            }
            fn setAutocompleteMaxVisible(erased: *anyopaque, max_visible: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setAutocompleteMaxVisible(max_visible);
            }
            fn setSubmitDisabled(erased: *anyopaque, disabled: bool) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setSubmitDisabled(disabled);
            }
            fn component(erased: *anyopaque) Component {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.component();
            }
        };
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .get_text = gen.getText,
                .get_expanded_text = gen.getExpandedText,
                .set_text = gen.setText,
                .insert_text_at_cursor = gen.insertTextAtCursor,
                .clear = gen.clear,
                .add_to_history = gen.addToHistory,
                .set_on_submit = gen.setOnSubmit,
                .set_on_change = gen.setOnChange,
                .set_autocomplete_provider = gen.setAutocompleteProvider,
                .set_border_color = gen.setBorderColor,
                .set_padding_x = gen.setPaddingX,
                .set_autocomplete_max_visible = gen.setAutocompleteMaxVisible,
                .set_submit_disabled = gen.setSubmitDisabled,
                .component = gen.component,
            },
        };
    }

    pub fn getText(self: EditorInterface) []const u8 {
        return self.vtable.get_text(self.ptr);
    }

    pub fn getExpandedText(self: EditorInterface) []const u8 {
        return self.vtable.get_expanded_text(self.ptr);
    }

    pub fn setText(self: EditorInterface, text: []const u8) void {
        self.vtable.set_text(self.ptr, text);
    }

    pub fn insertTextAtCursor(self: EditorInterface, text: []const u8) void {
        self.vtable.insert_text_at_cursor(self.ptr, text);
    }

    pub fn insertText(self: EditorInterface, text: []const u8) void {
        self.insertTextAtCursor(text);
    }

    pub fn clear(self: EditorInterface) void {
        self.vtable.clear(self.ptr);
    }

    pub fn addToHistory(self: EditorInterface, text: []const u8) void {
        self.vtable.add_to_history(self.ptr, text);
    }

    pub fn setOnSubmit(self: EditorInterface, cb: ?SubmitCallback, ctx: ?*anyopaque) void {
        self.vtable.set_on_submit(self.ptr, cb, ctx);
    }

    pub fn setOnChange(self: EditorInterface, cb: ?ChangeCallback, ctx: ?*anyopaque) void {
        self.vtable.set_on_change(self.ptr, cb, ctx);
    }

    pub fn setAutocompleteProvider(self: EditorInterface, provider: AutocompleteProvider) void {
        self.vtable.set_autocomplete_provider(self.ptr, provider);
    }

    pub fn setBorderColor(self: EditorInterface, color: Color) void {
        self.vtable.set_border_color(self.ptr, color);
    }

    pub fn setPaddingX(self: EditorInterface, padding: u32) void {
        self.vtable.set_padding_x(self.ptr, padding);
    }

    pub fn setAutocompleteMaxVisible(self: EditorInterface, max_visible: u32) void {
        self.vtable.set_autocomplete_max_visible(self.ptr, max_visible);
    }

    pub fn setSubmitDisabled(self: EditorInterface, disabled: bool) void {
        self.vtable.set_submit_disabled(self.ptr, disabled);
    }

    pub fn component(self: EditorInterface) Component {
        return self.vtable.component(self.ptr);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const buffer_mod = @import("buffer.zig");
const Region = buffer_mod.Region;

const MockEditor = struct {
    text: []const u8 = "",
    expanded_text: []const u8 = "",
    insert_count: u32 = 0,
    clear_count: u32 = 0,
    history_count: u32 = 0,
    border_color: Color = Color.default,
    padding_x: u32 = 0,
    autocomplete_max_visible: u32 = 0,
    submit_disabled: bool = false,
    submit_cb: ?EditorInterface.SubmitCallback = null,
    submit_ctx: ?*anyopaque = null,
    change_cb: ?EditorInterface.ChangeCallback = null,
    change_ctx: ?*anyopaque = null,

    pub fn getText(self: *const MockEditor) []const u8 {
        return self.text;
    }

    pub fn getExpandedText(self: *const MockEditor) []const u8 {
        return self.expanded_text;
    }

    pub fn setText(self: *MockEditor, text: []const u8) void {
        self.text = text;
        self.expanded_text = text;
    }

    pub fn insertTextAtCursor(self: *MockEditor, _: []const u8) void {
        self.insert_count += 1;
    }

    pub fn clear(self: *MockEditor) void {
        self.clear_count += 1;
    }

    pub fn addToHistory(self: *MockEditor, _: []const u8) void {
        self.history_count += 1;
    }

    pub fn setOnSubmit(self: *MockEditor, cb: ?EditorInterface.SubmitCallback, ctx: ?*anyopaque) void {
        self.submit_cb = cb;
        self.submit_ctx = ctx;
    }

    pub fn setOnChange(self: *MockEditor, cb: ?EditorInterface.ChangeCallback, ctx: ?*anyopaque) void {
        self.change_cb = cb;
        self.change_ctx = ctx;
    }

    pub fn setAutocompleteProvider(_: *MockEditor, _: AutocompleteProvider) void {}

    pub fn setBorderColor(self: *MockEditor, color: Color) void {
        self.border_color = color;
    }

    pub fn setPaddingX(self: *MockEditor, padding: u32) void {
        self.padding_x = padding;
    }

    pub fn setAutocompleteMaxVisible(self: *MockEditor, max_visible: u32) void {
        self.autocomplete_max_visible = max_visible;
    }

    pub fn setSubmitDisabled(self: *MockEditor, disabled: bool) void {
        self.submit_disabled = disabled;
    }

    pub fn render(_: *MockEditor, _: Region) void {}
    pub fn measure(_: *MockEditor, _: u32) component_mod.Measurement {
        return .{ .min_height = 1, .preferred_height = 3 };
    }

    pub fn component(self: *MockEditor) Component {
        return Component.init(MockEditor, self);
    }

    pub fn editorInterface(self: *MockEditor) EditorInterface {
        return EditorInterface.init(MockEditor, self);
    }
};

test "EditorInterface routes parity surface through vtable" {
    var mock = MockEditor{ .text = "hello", .expanded_text = "expanded" };
    const iface = mock.editorInterface();

    try testing.expectEqualStrings("hello", iface.getText());
    try testing.expectEqualStrings("expanded", iface.getExpandedText());

    iface.setText("world");
    try testing.expectEqualStrings("world", mock.text);

    iface.insertTextAtCursor("!");
    try testing.expectEqual(@as(u32, 1), mock.insert_count);

    iface.addToHistory("prompt");
    try testing.expectEqual(@as(u32, 1), mock.history_count);

    iface.setBorderColor(Color.rgb(1, 2, 3));
    try testing.expectEqual(Color.rgb(1, 2, 3), mock.border_color);

    iface.setPaddingX(2);
    try testing.expectEqual(@as(u32, 2), mock.padding_x);

    iface.setAutocompleteMaxVisible(9);
    try testing.expectEqual(@as(u32, 9), mock.autocomplete_max_visible);

    iface.setSubmitDisabled(true);
    try testing.expect(mock.submit_disabled);

    var submit_called = false;
    var change_called = false;
    const submit_ctx = &submit_called;
    const change_ctx = &change_called;
    const callbacks = struct {
        fn submit(_: []const u8, ctx: ?*anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
        fn change(_: []const u8, ctx: ?*anyopaque) void {
            const flag: *bool = @ptrCast(@alignCast(ctx));
            flag.* = true;
        }
    };

    iface.setOnSubmit(&callbacks.submit, @ptrCast(submit_ctx));
    iface.setOnChange(&callbacks.change, @ptrCast(change_ctx));
    mock.submit_cb.?("ok", mock.submit_ctx);
    mock.change_cb.?("ok", mock.change_ctx);
    try testing.expect(submit_called);
    try testing.expect(change_called);

    iface.clear();
    try testing.expectEqual(@as(u32, 1), mock.clear_count);

    const comp = iface.component();
    const m = comp.measure(80);
    try testing.expectEqual(@as(u32, 3), m.preferred_height);
}
