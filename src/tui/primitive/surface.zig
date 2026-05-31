const action = @import("action.zig");
const view = @import("view.zig");

pub const SurfaceId = enum(u32) {
    root = 1,
    chat = 2,
    input = 3,
    diagnostics = 4,
    header = 5,
    status = 6,
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
};
