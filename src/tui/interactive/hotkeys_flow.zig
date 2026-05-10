const std = @import("std");

const keybindings = @import("../keybindings.zig");
const list_picker_mod = @import("../components/list_picker.zig");
const select_list_mod = @import("../components/select_list.zig");
const theme_mod = @import("../theme.zig");
const tui_mod = @import("../tui.zig");
const overlay_mod = @import("../primitives/overlay.zig");

const Interactive = @import("../interactive.zig").Interactive;
const ListPicker = list_picker_mod.ListPicker;
const Selection = list_picker_mod.Selection;
const SelectItem = select_list_mod.SelectItem;

/// Owns one `/hotkeys` help picker.
///
/// Hotkey help is intentionally modeled as picker data: keybinding definitions
/// become rows, search text, and callbacks. Rendering stays in ListPicker,
/// SelectList, TextInput, Panel, and overlay primitives.
pub const HotkeysFlow = struct {
    arena: std.heap.ArenaAllocator,
    items: []SelectItem = &.{},
    search_texts: []const []const u8 = &.{},
    picker: ListPicker,
    handle: ?tui_mod.OverlayHandle = null,

    pub fn init(gpa: std.mem.Allocator, theme: *const theme_mod.Theme) !HotkeysFlow {
        var arena = std.heap.ArenaAllocator.init(gpa);
        errdefer arena.deinit();
        const a = arena.allocator();

        var count: usize = 0;
        for (keybindings.all()) |def| {
            if (def.show_in_help) count += 1;
        }

        const items = try a.alloc(SelectItem, count);
        const search_texts = try a.alloc([]const u8, count);

        var i: usize = 0;
        for (keybindings.all()) |def| {
            if (!def.show_in_help) continue;

            var binding_buf: [64]u8 = undefined;
            const binding_text = keybindings.formatBindings(def.action, " / ", &binding_buf);
            const section = keybindings.sectionTitle(def.section);

            const label = try a.dupe(u8, binding_text);
            const description = try std.fmt.allocPrint(a, "{s} · {s}", .{ section, def.description });
            const search_text = try std.fmt.allocPrint(a, "{s} {s} {s} {s}", .{
                section,
                binding_text,
                def.description,
                @tagName(def.action),
            });
            const value = try a.dupe(u8, @tagName(def.action));

            items[i] = .{ .value = value, .label = label, .description = description };
            search_texts[i] = search_text;
            i += 1;
        }

        var picker = ListPicker.init(gpa, theme);
        picker.title = "Hotkeys";
        picker.list.max_visible = 14;
        picker.setSearchPlaceholder("Search hotkeys");
        picker.setEmptyText("No matching hotkeys");
        picker.setSearchableItems(items, search_texts);

        return .{
            .arena = arena,
            .items = items,
            .search_texts = search_texts,
            .picker = picker,
        };
    }

    pub fn deinit(self: *HotkeysFlow) void {
        self.picker.deinit();
        self.arena.deinit();
    }
};

pub fn close(self: *Interactive) void {
    if (self.hotkeys_flow) |*flow| {
        if (flow.handle) |h| {
            flow.handle = null;
            h.hide();
        }
        flow.deinit();
    }
    self.hotkeys_flow = null;
}

pub fn show(self: *Interactive) void {
    close(self);
    var flow = HotkeysFlow.init(self.allocator, self.theme) catch {
        self.status_line.setPrimary("failed to build hotkeys picker", self.theme.fg(.@"error"));
        self.tui.dirty = true;
        return;
    };
    errdefer flow.deinit();

    flow.picker.on_select = &onSelected;
    flow.picker.on_cancel = &onCancel;
    flow.picker.callback_ctx = @ptrCast(self);

    self.cancelTranscriptSelection();
    self.hotkeys_flow = flow;
    self.hotkeys_flow.?.handle = self.tui.showOverlay(
        self.hotkeys_flow.?.picker.component(),
        overlay_mod.OverlayPreset.ivy.options(.{
            .top_margin = self.overlayTopMargin(),
        }),
    );
}

fn onSelected(_: Selection, ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    close(self);
}

fn onCancel(ctx: ?*anyopaque) void {
    const self: *Interactive = @ptrCast(@alignCast(ctx.?));
    close(self);
}
