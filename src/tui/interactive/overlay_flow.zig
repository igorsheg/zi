const Color = @import("../cell.zig").Color;
const overlay_mod = @import("../primitives/overlay.zig");
const simple_picker_flow_mod = @import("simple_picker_flow.zig");

const Interactive = @import("../interactive.zig").Interactive;
const SimplePickerFlow = simple_picker_flow_mod.SimplePickerFlow;
const PickerSelection = simple_picker_flow_mod.Selection;
const SelectItem = simple_picker_flow_mod.SelectItem;

pub fn bottomSheetOptions(self: *Interactive) overlay_mod.OverlayOptions {
    return .{
        .anchor = .bottom_left,
        .width_percent = 100,
        .max_height_percent = 40,
        .margin_bottom = 0,
        .margin_top = chromeTopMargin(self),
        .surface = .{ .fill = Color.default },
    };
}

pub fn centerDialogOptions(self: *Interactive) overlay_mod.OverlayOptions {
    var options = overlay_mod.OverlayPresets.centerDialog();
    options.margin_top = chromeTopMargin(self);
    options.margin_bottom = 1;
    options.surface = .{ .fill = self.theme.bg(.tool_pending_bg) };
    return options;
}

fn chromeTopMargin(self: *Interactive) u32 {
    return if (self.greeter_dismissed) 0 else self.greeter.measure(self.tui.width()).preferred_height;
}

pub fn showHotkeys(self: *Interactive) void {
    self.cancelTranscriptSelection();
    _ = self.tui.showOverlay(self.hotkeys_overlay.component(), centerDialogOptions(self));
}

pub fn configureSimplePicker(
    self: *Interactive,
    picker: *SimplePickerFlow,
    title: []const u8,
    max_visible: u32,
    items: []const SelectItem,
    on_select: ?*const fn (selection: PickerSelection, ctx: ?*anyopaque) void,
    on_cancel: ?*const fn (ctx: ?*anyopaque) void,
) void {
    picker.configure(self.allocator, self.theme, title, max_visible, items, @ptrCast(self), on_select, on_cancel);
}

pub fn showSimplePickerOverlay(
    self: *Interactive,
    picker: *SimplePickerFlow,
) void {
    self.cancelTranscriptSelection();
    picker.hide();
    picker.handle = self.tui.showOverlay(picker.picker.component(), bottomSheetOptions(self));
}

pub fn hideSimplePickerOverlay(picker: *SimplePickerFlow) void {
    picker.hide();
}
