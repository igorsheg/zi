const std = @import("std");
const vaxis = @import("vaxis");
const action = @import("action.zig");
const tui_testing = @import("testing.zig");
const view = @import("view.zig");

pub const SurfaceId = enum(u32) {
    root = 1,
    chat = 2,
    input = 3,
    diagnostics = 4,
    _,
};

pub const Layer = enum(u8) {
    base = 0,
    panel = 10,
    popover = 20,
    modal = 30,
    tooltip = 40,
    notification = 50,
};

pub const Modality = enum {
    modeless,
    focus_trap,
    blocks_below,
};

pub const DismissPolicy = union(enum) {
    none,
    escape,
    outside_click,
    escape_or_outside_click,
    action: action.ActionId,
};

pub const Surface = struct {
    id: SurfaceId,
    view_id: view.ViewId,
    rect: view.Rect,
    layer: Layer,
    modality: Modality = .modeless,
    dismiss_policy: DismissPolicy = .none,
    insertion_index: u64 = 0,
    dirty: bool = true,
    focused: bool = false,
    cursor_visible: bool = false,

    pub fn init(id: SurfaceId, view_id: view.ViewId, rect: view.Rect, layer: Layer) Surface {
        return .{
            .id = id,
            .view_id = view_id,
            .rect = rect,
            .layer = layer,
        };
    }

    pub fn markDirty(self: *Surface) void {
        self.dirty = true;
    }

    pub fn markClean(self: *Surface) void {
        self.dirty = false;
    }

    pub fn renderText(self: *Surface, win: vaxis.Window, text: []const u8) void {
        const child = win.child(.{
            .x_off = @intCast(self.rect.x),
            .y_off = @intCast(self.rect.y),
            .width = self.rect.width,
            .height = self.rect.height,
        });
        child.clear();
        _ = child.print(&.{.{ .text = text }}, .{ .wrap = .word });
        self.markClean();
    }
};

test "surface renders buffer text into a bounded rect" {
    var screen = try vaxis.Screen.init(std.testing.allocator, .{
        .rows = 3,
        .cols = 12,
        .x_pixel = 0,
        .y_pixel = 0,
    });
    defer screen.deinit(std.testing.allocator);

    var surf = Surface.init(.chat, .chat, .init(0, 0, 12, 3), .base);
    const root: vaxis.Window = .{
        .x_off = 0,
        .y_off = 0,
        .parent_x_off = 0,
        .parent_y_off = 0,
        .width = screen.width,
        .height = screen.height,
        .screen = &screen,
    };
    surf.renderText(root, "hello");

    try std.testing.expect(!surf.dirty);
    try tui_testing.expectScreenAscii(
        \\hello       
        \\            
        \\            
    , &screen, 12, 3);
}
