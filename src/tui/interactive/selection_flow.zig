const std = @import("std");
const clipboard_mod = @import("../terminal/clipboard.zig");
const layout_mod = @import("../primitives/layout.zig");
const keys_mod = @import("../terminal/keys.zig");
const selection_mod = @import("../selection/mod.zig");
const transcript_mod = @import("../conversation/transcript.zig");

const ChildRect = layout_mod.ChildRect;
const Point = selection_mod.Point;
const Rect = selection_mod.Rect;
const Selectable = selection_mod.Selectable;
const SelectableId = selection_mod.SelectableId;
const GlobalSelection = selection_mod.GlobalSelection;

pub const MouseCapture = union(enum) {
    none,
    selection: void,
};

const transcript_id: SelectableId = @enumFromInt(1);

const TranscriptSelectable = struct {
    transcript: *transcript_mod.Transcript,
    rect: Rect,

    pub fn selectionBounds(self: *@This()) Rect {
        return self.rect;
    }

    pub fn shouldStartSelection(self: *@This(), point: Point) bool {
        return self.transcript.shouldStartSelection(self.rect, point);
    }

    pub fn onSelectionChanged(self: *@This(), selection: ?GlobalSelection) bool {
        return self.transcript.onSelectionChanged(self.rect, selection);
    }

    pub fn hasSelection(self: *@This()) bool {
        return self.transcript.hasSelection(self.rect.width);
    }

    pub fn selectedText(self: *@This(), allocator: std.mem.Allocator) !?[]u8 {
        return self.transcript.selectedText(allocator, self.rect.width);
    }

    pub fn clearSelection(self: *@This()) void {
        self.transcript.cancelSelection();
    }
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

    var registry = selection_mod.SelectionRegistry{};
    defer registry.deinit(self.allocator);
    var transcript_selectable = transcriptSelectable(self) orelse return;
    registry.register(self.allocator, Selectable.init(TranscriptSelectable, transcript_id, &transcript_selectable)) catch return;

    const point = Point{ .x = event.x, .y = event.y };
    switch (self.mouse_capture) {
        .none => {
            if (event.kind != .down or event.button != .left) return;
            if (self.selection.begin(self.allocator, &registry, point) catch false) {
                self.mouse_capture = .{ .selection = {} };
                self.tui.dirty = true;
            }
        },
        .selection => {
            switch (event.kind) {
                .drag, .move => {
                    if (self.selection.update(self.allocator, &registry, point) catch false) {
                        maybeAutoScrollTranscript(self, transcript_selectable.rect, point);
                        self.tui.dirty = true;
                    }
                },
                .up => {
                    const text = self.selection.finish(self.allocator, &registry, point) catch null;
                    self.mouse_capture = .none;
                    if (text) |selected| {
                        defer self.allocator.free(selected);
                        copySelection(self, selected);
                    }
                    self.tui.dirty = true;
                },
                else => {},
            }
        },
    }
}

pub fn cancelSelection(self: anytype) void {
    var registry = selection_mod.SelectionRegistry{};
    defer registry.deinit(self.allocator);
    var transcript_selectable = transcriptSelectable(self) orelse {
        self.selection.clear(&registry);
        self.mouse_capture = .none;
        return;
    };
    registry.register(self.allocator, Selectable.init(TranscriptSelectable, transcript_id, &transcript_selectable)) catch {};
    self.selection.clear(&registry);
    self.mouse_capture = .none;
}

fn transcriptSelectable(self: anytype) ?TranscriptSelectable {
    const child = transcriptRect(self) orelse return null;
    if (child.width == 0 or child.height == 0) return null;
    return .{
        .transcript = &self.transcript,
        .rect = .{ .x = @intCast(child.x), .y = @intCast(child.y), .width = child.width, .height = child.height },
    };
}

fn transcriptRect(self: anytype) ?ChildRect {
    return self.tui.root.childRect(0);
}

fn maybeAutoScrollTranscript(self: anytype, rect: Rect, point: Point) void {
    const width = rect.width;
    const height = rect.height;
    if (width == 0 or height == 0) return;
    if (point.y < rect.y) {
        self.transcript.scrollBy(width, height, -1);
    } else if (point.y >= rect.y + @as(i32, @intCast(height))) {
        self.transcript.scrollBy(width, height, 1);
    }
}

fn copySelection(self: anytype, text: []const u8) void {
    if (text.len == 0) return;
    if (clipboard_mod.copyText(text)) {
        self.status_line.setPrimary("copied selection", self.theme.fg(.success));
    } else {
        self.status_line.setPrimary("failed to copy selection", self.theme.fg(.@"error"));
    }
}
