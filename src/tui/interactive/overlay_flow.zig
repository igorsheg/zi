const Color = @import("../cell.zig").Color;
const overlay_mod = @import("../overlay.zig");
const tui_mod = @import("../tui.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");

const Interactive = @import("../interactive.zig").Interactive;
const ListPicker = list_picker_mod.ListPicker;
const PickerSelection = list_picker_mod.Selection;
const SelectItem = select_list_mod.SelectItem;

pub fn bottomSheetOptions(self: *Interactive) overlay_mod.OverlayOptions {
    const width = self.tui.width();
    const header_h = self.header_container.measure(width).preferred_height;
    return .{
        .anchor = .bottom_left,
        .width_percent = 100,
        .max_height_percent = 40,
        .margin_bottom = 0,
        .margin_top = header_h,
        .surface = .{ .fill = Color.default },
    };
}

pub fn centerDialogOptions(self: *Interactive) overlay_mod.OverlayOptions {
    var options = overlay_mod.OverlayPresets.centerDialog();
    const width = self.tui.width();
    const header_h = self.header_container.measure(width).preferred_height;
    options.margin_top = header_h;
    options.margin_bottom = 1;
    options.surface = .{ .fill = self.theme.bg(.tool_pending_bg) };
    return options;
}

pub fn showHotkeys(self: *Interactive) void {
    self.cancelTranscriptSelection();
    _ = self.tui.showOverlay(self.hotkeys_overlay.component(), centerDialogOptions(self));
}

pub fn configureSimplePicker(
    self: *Interactive,
    picker: *ListPicker,
    title: []const u8,
    max_visible: u32,
    items: []const SelectItem,
    on_select: ?*const fn (selection: PickerSelection, ctx: ?*anyopaque) void,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void,
) void {
    picker.* = ListPicker.init(self.theme);
    picker.title = title;
    picker.list.max_visible = max_visible;
    picker.setItems(items);
    picker.on_select = on_select;
    picker.on_cancel = on_cancel;
    picker.callback_ctx = @ptrCast(self);
}

pub fn showSimplePickerOverlay(
    self: *Interactive,
    handle: *?tui_mod.OverlayHandle,
    picker: *ListPicker,
) void {
    self.cancelTranscriptSelection();
    hideSimplePickerOverlay(handle);
    handle.* = self.tui.showOverlay(picker.component(), bottomSheetOptions(self));
}

pub fn hideSimplePickerOverlay(handle: *?tui_mod.OverlayHandle) void {
    if (handle.*) |h| {
        handle.* = null;
        h.hide();
    }
}
