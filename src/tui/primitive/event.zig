const action = @import("action.zig");
const buffer = @import("buffer.zig");
const slot = @import("slot.zig");
const surface = @import("surface.zig");
const transcript = @import("transcript.zig");
const view = @import("view.zig");

/// TUI events are bounded, non-owning observation facts.
///
/// They may be drained by tests, future extension hooks, or cleared by a
/// frontend that only needs retained rendering. Variants must not own memory or
/// borrow caller-owned slices. Add typed ids/revisions here, and keep owned
/// payloads in the stores they reference.
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
