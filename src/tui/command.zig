const buffer = @import("buffer.zig");
const slot = @import("slot.zig");
const surface = @import("surface.zig");
const transcript = @import("transcript.zig");

pub const TuiCommand = union(enum) {
    append_transcript_text: AppendTranscriptText,
    append_custom_transcript_item: AppendCustomTranscriptItem,
    buffer_append: BufferAppend,
    slot_set_text: SlotSetText,
    slot_clear: SlotClear,
    composer_insert: []const u8,
    composer_clear,
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
        view_id: @import("view.zig").ViewId,
        rect: @import("view.zig").Rect,
        layer: surface.Layer,
        modality: surface.Modality = .modeless,
        dismiss_policy: surface.DismissPolicy = .none,
    };
};
