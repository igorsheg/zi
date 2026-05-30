const std = @import("std");

const buffer = @import("../primitive/buffer.zig");
const surface = @import("../primitive/surface.zig");
const view = @import("../primitive/view.zig");

pub const height_min = 4;

pub const Part = enum {
    header,
    transcript,
    status,
    composer,
};

pub const Placement = struct {
    surface_id: surface.SurfaceId,
    view_id: view.ViewId,
    buffer_id: buffer.BufferId,
    rect: view.Rect,
};

pub const Layout = struct {
    header: Placement,
    transcript: Placement,
    status: Placement,
    composer: Placement,

    pub fn placement(self: Layout, part: Part) Placement {
        return switch (part) {
            .header => self.header,
            .transcript => self.transcript,
            .status => self.status,
            .composer => self.composer,
        };
    }
};

pub fn layout(width: u16, height: u16) Layout {
    std.debug.assert(width > 0);
    std.debug.assert(height >= height_min);

    return .{
        .header = .{
            .surface_id = .header,
            .view_id = .header,
            .buffer_id = .header,
            .rect = .init(0, 0, width, 1),
        },
        .transcript = .{
            .surface_id = .chat,
            .view_id = .chat,
            .buffer_id = .chat,
            .rect = .init(0, 1, width, height - 3),
        },
        .status = .{
            .surface_id = .status,
            .view_id = .status,
            .buffer_id = .status,
            .rect = .init(0, height - 2, width, 1),
        },
        .composer = .{
            .surface_id = .input,
            .view_id = .input,
            .buffer_id = .input,
            .rect = .init(0, height - 1, width, 1),
        },
    };
}

test "shell layout divides the viewport into stable regions" {
    const out = layout(80, 24);

    try std.testing.expectEqual(@as(u16, 0), out.header.rect.y);
    try std.testing.expectEqual(@as(u16, 1), out.transcript.rect.y);
    try std.testing.expectEqual(@as(u16, 21), out.transcript.rect.height);
    try std.testing.expectEqual(@as(u16, 22), out.status.rect.y);
    try std.testing.expectEqual(@as(u16, 23), out.composer.rect.y);
}
