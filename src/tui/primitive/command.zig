const buffer = @import("buffer.zig");
const slot = @import("slot.zig");
const surface = @import("surface.zig");
const transcript = @import("transcript.zig");
const view = @import("view.zig");

pub const TuiCommand = union(enum) {
    append_transcript_text: AppendTranscriptText,
    append_custom_transcript_item: AppendCustomTranscriptItem,
    buffer_append: BufferAppend,
    buffer_replace: BufferReplace,
    slot_set_text: SlotSetText,
    slot_clear: SlotClear,
    composer_insert: []const u8,
    composer_backspace,
    composer_clear,
    open_text_surface: OpenTextSurface,
    open_surface: OpenSurface,
    close_surface: surface.SurfaceId,

    pub const AppendTranscriptText = struct {
        kind: transcript.Kind,
        durability: transcript.Durability,
        text: []const u8,
    };

    pub const AppendCustomTranscriptItem = struct {
        durability: transcript.Durability,
        custom_type: []const u8,
        data_json: []const u8,
    };

    pub const BufferAppend = struct {
        id: buffer.BufferId,
        bytes: []const u8,
    };

    pub const BufferReplace = struct {
        id: buffer.BufferId,
        bytes: []const u8,
    };

    pub const SlotSetText = struct {
        slot_id: slot.SlotId,
        contribution_id: slot.ContributionId,
        owner: slot.Owner,
        priority: i16 = 0,
        lifetime: slot.Lifetime = .session,
        text: []const u8,
    };

    pub const SlotClear = struct {
        slot_id: slot.SlotId,
        contribution_id: slot.ContributionId,
    };

    pub const OpenSurface = struct {
        id: surface.SurfaceId,
        view_id: view.ViewId,
        rect: view.Rect,
        layer: surface.Layer,
        modality: surface.Modality = .modeless,
        dismiss_policy: surface.DismissPolicy = .none,
    };

    pub const OpenTextSurface = struct {
        surface_id: surface.SurfaceId,
        view_id: view.ViewId,
        buffer_id: buffer.BufferId,
        buffer_kind: buffer.Kind,
        buffer_name: []const u8,
        rect: view.Rect,
        layer: surface.Layer,
        modality: surface.Modality = .modeless,
        dismiss_policy: surface.DismissPolicy = .none,
        text: []const u8,
    };
};
