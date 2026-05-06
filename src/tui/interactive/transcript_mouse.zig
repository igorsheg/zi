const std = @import("std");
const clipboard_mod = @import("../terminal/clipboard.zig");
const layout_mod = @import("../primitives/layout.zig");
const keys_mod = @import("../terminal/keys.zig");
const transcript_mod = @import("../transcript.zig");

const ChildRect = layout_mod.ChildRect;

pub const MouseCapture = union(enum) {
    none,
    transcript_selection: void,
};

const Zone = struct {
    zone: transcript_mod.DragZone,
    local_x: u32,
    local_y: u32,
    width: u32,
    height: u32,
};

pub fn handle(self: anytype, event: keys_mod.MouseEvent) void {
    if (self.tui.hasCapturingOverlay()) {
        cancelSelection(self);
        return;
    }

    if (event.kind == .scroll) {
        switch (event.button) {
            .scroll_up => {
                const w = self.tui.width();
                const output_h = self.outputHeight();
                self.transcript.scrollBy(w, output_h, -3);
                self.tui.dirty = true;
            },
            .scroll_down => {
                const w = self.tui.width();
                const output_h = self.outputHeight();
                self.transcript.scrollBy(w, output_h, 3);
                self.tui.dirty = true;
            },
            else => {},
        }
        return;
    }

    switch (self.mouse_capture) {
        .none => {
            if (event.kind != .down or event.button != .left) return;
            const zone = mouseZone(self, event, false) orelse return;
            if (zone.zone != .inside) return;
            if (self.transcript.beginSelection(zone.width, zone.height, zone.local_x, zone.local_y)) {
                self.mouse_capture = .{ .transcript_selection = {} };
                self.tui.dirty = true;
            }
        },
        .transcript_selection => {
            const zone = mouseZone(self, event, true) orelse return;
            const now_ns = @as(i128, @intCast(std.Io.Timestamp.now(std.Options.debug_io, .awake).toNanoseconds()));
            switch (event.kind) {
                .drag, .move => {
                    if (self.transcript.updateSelection(zone.width, zone.height, zone.local_x, zone.local_y, zone.zone, now_ns)) {
                        self.tui.dirty = true;
                    }
                },
                .up => {
                    _ = self.transcript.endSelection(zone.width, zone.height, zone.local_x, zone.local_y, zone.zone, now_ns);
                    self.mouse_capture = .none;
                    copySelection(self, zone.width);
                    cancelSelection(self);
                    self.tui.dirty = true;
                },
                else => {},
            }
        },
    }
}

pub fn cancelSelection(self: anytype) void {
    self.transcript.cancelSelection();
    self.mouse_capture = .none;
}

fn rect(self: anytype) ?ChildRect {
    return self.tui.root.childRect(0);
}

fn mouseZone(self: anytype, event: keys_mod.MouseEvent, allow_outside: bool) ?Zone {
    const transcript_rect = rect(self) orelse return null;
    if (transcript_rect.width == 0 or transcript_rect.height == 0) return null;

    const ex: i32 = event.x;
    const ey: i32 = event.y;
    const left: i32 = @intCast(transcript_rect.x);
    const top: i32 = @intCast(transcript_rect.y);
    const right: i32 = left + @as(i32, @intCast(transcript_rect.width));
    const bottom: i32 = top + @as(i32, @intCast(transcript_rect.height));

    if (!allow_outside and (ex < left or ex >= right or ey < top or ey >= bottom)) return null;

    const clamped_x: u32 = if (ex < left)
        0
    else if (ex >= right)
        transcript_rect.width - 1
    else
        @intCast(ex - left);

    const zone: transcript_mod.DragZone = if (ey < top)
        .above
    else if (ey >= bottom)
        .below
    else
        .inside;
    if (!allow_outside and zone != .inside) return null;

    const local_y: u32 = switch (zone) {
        .inside => @intCast(ey - top),
        .above => 0,
        .below => transcript_rect.height - 1,
    };

    return .{
        .zone = zone,
        .local_x = clamped_x,
        .local_y = local_y,
        .width = transcript_rect.width,
        .height = transcript_rect.height,
    };
}

fn copySelection(self: anytype, width: u32) void {
    const selected = self.transcript.selectedText(self.allocator, width) catch return;
    const text = selected orelse return;
    defer self.allocator.free(text);

    if (clipboard_mod.copyText(text)) {
        self.status_line.setPrimary("copied selection", self.theme.fg(.success));
    } else {
        self.status_line.setPrimary("failed to copy selection", self.theme.fg(.@"error"));
    }
}
