const action = @import("action.zig");
const buffer = @import("buffer.zig");
const slot = @import("slot.zig");
const surface = @import("surface.zig");
const transcript = @import("transcript.zig");
const view = @import("view.zig");

pub const TuiEvent = union(enum) {
    buffer_changed: BufferChanged,
    view_focused: ViewFocused,
    surface_opened: SurfaceChanged,
    surface_closed: SurfaceChanged,
    transcript_item_appended: TranscriptItemAppended,
    composer_changed,
    completion_opened,
    completion_closed,
    action_invoked: action.ActionId,
    slot_changed: SlotChanged,

    pub const BufferChanged = struct {
        id: buffer.BufferId,
        revision: u64,
    };

    pub const ViewFocused = struct {
        id: view.ViewId,
    };

    pub const SurfaceChanged = struct {
        id: surface.SurfaceId,
    };

    pub const TranscriptItemAppended = struct {
        id: transcript.TranscriptItemId,
        durability: transcript.Durability,
    };

    pub const SlotChanged = struct {
        id: slot.SlotId,
        revision: u64,
    };
};
