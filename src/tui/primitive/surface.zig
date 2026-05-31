const std = @import("std");

const view = @import("view.zig");

pub const SurfaceId = enum(u32) {
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
};

pub fn dismissesOnEscape(policy: DismissPolicy) bool {
    return switch (policy) {
        .escape, .escape_or_outside_click => true,
        .none, .outside_click => false,
    };
}

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
};

test "dismiss policy records escape behavior explicitly" {
    try std.testing.expect(dismissesOnEscape(.escape));
    try std.testing.expect(dismissesOnEscape(.escape_or_outside_click));
    try std.testing.expect(!dismissesOnEscape(.none));
    try std.testing.expect(!dismissesOnEscape(.outside_click));
}
