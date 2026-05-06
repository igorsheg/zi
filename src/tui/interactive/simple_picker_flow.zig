const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");
const tui_mod = @import("../tui.zig");
const theme_mod = @import("../theme.zig");

pub const ListPicker = list_picker_mod.ListPicker;
pub const Selection = list_picker_mod.Selection;
pub const SelectItem = select_list_mod.SelectItem;
pub const OverlayHandle = tui_mod.OverlayHandle;
pub const Theme = theme_mod.Theme;

/// Reusable overlay lifecycle for static menu-style pickers.
///
/// Payload storage remains with each domain flow. This keeps the helper deep:
/// it owns picker presentation/lifecycle, not domain meaning.
pub const SimplePickerFlow = struct {
    picker: ListPicker = undefined,
    handle: ?OverlayHandle = null,

    pub fn configure(
        self: *SimplePickerFlow,
        theme: *const Theme,
        title: []const u8,
        max_visible: u32,
        items: []const SelectItem,
        callback_ctx: ?*anyopaque,
        on_select: ?*const fn (selection: Selection, ctx: ?*anyopaque) void,
        on_cancel: ?*const fn (ctx: ?*anyopaque) void,
    ) void {
        self.picker = ListPicker.init(theme);
        self.picker.title = title;
        self.picker.list.max_visible = max_visible;
        self.picker.setItems(items);
        self.picker.on_select = on_select;
        self.picker.on_cancel = on_cancel;
        self.picker.callback_ctx = callback_ctx;
    }

    pub fn hide(self: *SimplePickerFlow) void {
        if (self.handle) |h| {
            self.handle = null;
            h.hide();
        }
    }
};
