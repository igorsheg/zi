const std = @import("std");

const buffer = @import("../primitive/buffer.zig");
const composer = @import("../product/composer.zig");
const surface = @import("../primitive/surface.zig");
const transcript = @import("../product/transcript.zig");
const view = @import("../primitive/view.zig");

pub const ReadModel = struct {
    buffers: StoreSummary,
    views: StoreSummary,
    surfaces: StoreSummary,
    events: StoreSummary,
    focus: Focus,
    transcript: Transcript,
    composer: Composer,
    transcript_projection: TranscriptProjection,

    pub const StoreSummary = struct {
        count: usize,
        capacity: usize,
    };

    pub const Focus = struct {
        surface_id: surface.SurfaceId,
        view_id: view.ViewId,
        input_target: InputTarget,
    };

    pub const InputTarget = enum {
        composer,
        surface,
    };

    pub const Transcript = struct {
        item_count: usize,
        item_count_max: usize,
        revision: u64,
        active_assistant_item_id: ?transcript.TranscriptItemId,
    };

    pub const Composer = struct {
        text_byte_count: usize,
        input_bytes_max: usize,
        cursor_byte_index: usize,
        revision: u64,
        completion: Completion,
    };

    pub const Completion = union(enum) {
        closed,
        open: OpenCompletion,

        pub const OpenCompletion = struct {
            trigger: u8,
            query_start_byte_index: usize,
            selected_index: usize,
            candidate_count: usize,
        };
    };

    pub const TranscriptProjection = struct {
        buffer_id: buffer.BufferId,
        revision: u64,
        byte_count: usize,
        dropped_prefix_byte_count: usize,
    };
};

pub fn completionFromComposer(state: composer.CompletionState) ReadModel.Completion {
    return switch (state) {
        .closed => .closed,
        .open => |open| .{ .open = .{
            .trigger = open.trigger,
            .query_start_byte_index = open.query_start,
            .selected_index = open.selected_index,
            .candidate_count = open.candidate_count,
        } },
    };
}

test "read model completion snapshot is non-owning data" {
    const snapshot = completionFromComposer(.{ .open = .{
        .trigger = '@',
        .query_start = 1,
        .selected_index = 2,
    } });

    try std.testing.expect(snapshot == .open);
    try std.testing.expectEqual(@as(u8, '@'), snapshot.open.trigger);
    try std.testing.expectEqual(@as(usize, 1), snapshot.open.query_start_byte_index);
    try std.testing.expectEqual(@as(usize, 2), snapshot.open.selected_index);
    try std.testing.expectEqual(@as(usize, 0), snapshot.open.candidate_count);
}
