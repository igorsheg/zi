const buffer = @import("../primitive/buffer.zig");
const slot = @import("../primitive/slot.zig");
const surface = @import("../primitive/surface.zig");
const view = @import("../primitive/view.zig");

pub const buffers = struct {
    pub const header: buffer.BufferId = @enumFromInt(1);
    pub const transcript: buffer.BufferId = @enumFromInt(2);
    pub const status: buffer.BufferId = @enumFromInt(3);
    pub const composer: buffer.BufferId = @enumFromInt(4);
    pub const diagnostics: buffer.BufferId = @enumFromInt(5);
};

pub const views = struct {
    pub const header: view.ViewId = @enumFromInt(1);
    pub const transcript: view.ViewId = @enumFromInt(2);
    pub const status: view.ViewId = @enumFromInt(3);
    pub const composer: view.ViewId = @enumFromInt(4);
    pub const diagnostics: view.ViewId = @enumFromInt(5);
};

pub const surfaces = struct {
    pub const header: surface.SurfaceId = @enumFromInt(1);
    pub const transcript: surface.SurfaceId = @enumFromInt(2);
    pub const status: surface.SurfaceId = @enumFromInt(3);
    pub const composer: surface.SurfaceId = @enumFromInt(4);
    pub const diagnostics: surface.SurfaceId = @enumFromInt(5);
    pub const root: surface.SurfaceId = @enumFromInt(6);
};

pub const slots = struct {
    pub const shell_header: slot.SlotId = @enumFromInt(1);
    pub const transcript_status: slot.SlotId = @enumFromInt(2);
    pub const composer_header: slot.SlotId = @enumFromInt(3);
    pub const composer_footer: slot.SlotId = @enumFromInt(4);
};

pub const slot_ids = [_]slot.SlotId{
    slots.shell_header,
    slots.transcript_status,
    slots.composer_header,
    slots.composer_footer,
};

pub const composer_prompt = "> ";

pub const BufferSpec = struct {
    id: buffer.BufferId,
    kind: buffer.Kind,
    name: []const u8,
    initial_text: []const u8 = "",
};

pub const shell_buffers = [_]BufferSpec{
    .{
        .id = buffers.header,
        .kind = .text,
        .name = "header",
        .initial_text = "zi",
    },
    .{
        .id = buffers.transcript,
        .kind = .scrollback,
        .name = "transcript",
    },
    .{
        .id = buffers.status,
        .kind = .text,
        .name = "status",
        .initial_text = "idle",
    },
    .{
        .id = buffers.composer,
        .kind = .editable,
        .name = "composer",
        .initial_text = composer_prompt,
    },
};
