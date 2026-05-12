const component_mod = @import("../primitives/view.zig");
const cell_mod = @import("../cell.zig");
const autocomplete_mod = @import("../autocomplete/provider.zig");
const status_data_mod = @import("../status_data.zig");
const theme_mod = @import("../theme.zig");

const Component = component_mod.Component;
const Color = cell_mod.Color;
const AutocompleteProvider = autocomplete_mod.AutocompleteProvider;
const StatusData = status_data_mod.StatusData;
const Theme = theme_mod.Theme;

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
        handle_paste: *const fn (ptr: *anyopaque, text: []const u8) void,
        clear: *const fn (ptr: *anyopaque) void,
        clear_history: *const fn (ptr: *anyopaque) void,
        add_to_history: *const fn (ptr: *anyopaque, text: []const u8) void,
        set_on_submit: *const fn (ptr: *anyopaque, cb: ?SubmitCallback, ctx: ?*anyopaque) void,
        set_on_change: *const fn (ptr: *anyopaque, cb: ?ChangeCallback, ctx: ?*anyopaque) void,
        set_autocomplete_provider: *const fn (ptr: *anyopaque, provider: AutocompleteProvider) void,
        set_theme: *const fn (ptr: *anyopaque, theme: *const Theme) void,
        set_status_data: *const fn (ptr: *anyopaque, status_data: *const StatusData) void,
        set_cwd: *const fn (ptr: *anyopaque, cwd: []const u8) void,
        set_git_branch: *const fn (ptr: *anyopaque, branch: ?[]const u8) void,
        set_border_color: *const fn (ptr: *anyopaque, color: Color) void,
        set_padding_x: *const fn (ptr: *anyopaque, padding: u32) void,
        set_autocomplete_max_visible: *const fn (ptr: *anyopaque, max_visible: u32) void,
        set_max_visible_lines: *const fn (ptr: *anyopaque, max_visible: u32) void,
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
            fn handlePaste(erased: *anyopaque, text: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.handlePaste(text);
            }
            fn clear(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.clear();
            }
            fn clearHistory(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.clearHistory();
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
            fn setTheme(erased: *anyopaque, theme: *const Theme) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setTheme(theme);
            }
            fn setStatusData(erased: *anyopaque, status_data: *const StatusData) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setStatusData(status_data);
            }
            fn setCwd(erased: *anyopaque, cwd: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setCwd(cwd);
            }
            fn setGitBranch(erased: *anyopaque, branch: ?[]const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setGitBranch(branch);
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
            fn setMaxVisibleLines(erased: *anyopaque, max_visible: u32) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.setMaxVisibleLines(max_visible);
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
                .handle_paste = gen.handlePaste,
                .clear = gen.clear,
                .clear_history = gen.clearHistory,
                .add_to_history = gen.addToHistory,
                .set_on_submit = gen.setOnSubmit,
                .set_on_change = gen.setOnChange,
                .set_autocomplete_provider = gen.setAutocompleteProvider,
                .set_theme = gen.setTheme,
                .set_status_data = gen.setStatusData,
                .set_cwd = gen.setCwd,
                .set_git_branch = gen.setGitBranch,
                .set_border_color = gen.setBorderColor,
                .set_padding_x = gen.setPaddingX,
                .set_autocomplete_max_visible = gen.setAutocompleteMaxVisible,
                .set_max_visible_lines = gen.setMaxVisibleLines,
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

    pub fn handlePaste(self: EditorInterface, text: []const u8) void {
        self.vtable.handle_paste(self.ptr, text);
    }

    pub fn clear(self: EditorInterface) void {
        self.vtable.clear(self.ptr);
    }

    pub fn clearHistory(self: EditorInterface) void {
        self.vtable.clear_history(self.ptr);
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

    pub fn setTheme(self: EditorInterface, theme: *const Theme) void {
        self.vtable.set_theme(self.ptr, theme);
    }

    pub fn setStatusData(self: EditorInterface, status_data: *const StatusData) void {
        self.vtable.set_status_data(self.ptr, status_data);
    }

    pub fn setCwd(self: EditorInterface, cwd: []const u8) void {
        self.vtable.set_cwd(self.ptr, cwd);
    }

    pub fn setGitBranch(self: EditorInterface, branch: ?[]const u8) void {
        self.vtable.set_git_branch(self.ptr, branch);
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

    pub fn setMaxVisibleLines(self: EditorInterface, max_visible: u32) void {
        self.vtable.set_max_visible_lines(self.ptr, max_visible);
    }

    pub fn setSubmitDisabled(self: EditorInterface, disabled: bool) void {
        self.vtable.set_submit_disabled(self.ptr, disabled);
    }

    pub fn component(self: EditorInterface) Component {
        return self.vtable.component(self.ptr);
    }
};

const buffer_mod = @import("../primitives/surface.zig");
const Region = buffer_mod.Region;

pub const MockEditor = struct {
    text: []const u8 = "",
    expanded_text: []const u8 = "",
    insert_count: u32 = 0,
    paste_count: u32 = 0,
    clear_count: u32 = 0,
    clear_history_count: u32 = 0,
    history_count: u32 = 0,
    theme: ?*const Theme = null,
    status_data: ?*const StatusData = null,
    cwd: []const u8 = "",
    git_branch: ?[]const u8 = null,
    border_color: Color = Color.default,
    padding_x: u32 = 0,
    autocomplete_max_visible: u32 = 0,
    max_visible_lines: u32 = 0,
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

    pub fn handlePaste(self: *MockEditor, _: []const u8) void {
        self.paste_count += 1;
    }

    pub fn clear(self: *MockEditor) void {
        self.clear_count += 1;
    }

    pub fn clearHistory(self: *MockEditor) void {
        self.clear_history_count += 1;
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

    pub fn setTheme(self: *MockEditor, theme: *const Theme) void {
        self.theme = theme;
    }

    pub fn setStatusData(self: *MockEditor, status_data: *const StatusData) void {
        self.status_data = status_data;
    }

    pub fn setCwd(self: *MockEditor, cwd: []const u8) void {
        self.cwd = cwd;
    }

    pub fn setGitBranch(self: *MockEditor, branch: ?[]const u8) void {
        self.git_branch = branch;
    }

    pub fn setBorderColor(self: *MockEditor, color: Color) void {
        self.border_color = color;
    }

    pub fn setPaddingX(self: *MockEditor, padding: u32) void {
        self.padding_x = padding;
    }

    pub fn setAutocompleteMaxVisible(self: *MockEditor, max_visible: u32) void {
        self.autocomplete_max_visible = max_visible;
    }

    pub fn setMaxVisibleLines(self: *MockEditor, max_visible: u32) void {
        self.max_visible_lines = max_visible;
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
