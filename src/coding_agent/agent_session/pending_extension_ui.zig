const std = @import("std");

const extension_ui = @import("../extensions/ui.zig");

pub const PendingExtensionUi = struct {
    allocator: std.mem.Allocator,
    render_updates: std.ArrayListUnmanaged(extension_ui.RenderSpec) = .empty,
    frame_updates: std.ArrayListUnmanaged(extension_ui.UiFrame) = .empty,
    editor_actions: std.ArrayListUnmanaged(extension_ui.EditorAction) = .empty,

    pub fn init(allocator: std.mem.Allocator) PendingExtensionUi {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *PendingExtensionUi) void {
        self.clearRenderUpdates();
        self.clearFrameUpdates();
        self.clearEditorActions();
    }

    pub fn publishRender(self: *PendingExtensionUi, spec: extension_ui.RenderSpec) !void {
        var cloned = try extension_ui.RenderSpec.clone(self.allocator, spec);
        errdefer cloned.deinit(self.allocator);
        try self.render_updates.append(self.allocator, cloned);
    }

    pub fn takeRenderUpdates(self: *PendingExtensionUi, allocator: std.mem.Allocator) ![]extension_ui.RenderSpec {
        const out = try allocator.alloc(extension_ui.RenderSpec, self.render_updates.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |*update| update.deinit(allocator);
        for (self.render_updates.items, 0..) |update, i| {
            out[i] = try extension_ui.RenderSpec.clone(allocator, update);
            initialized += 1;
        }
        self.clearRenderUpdates();
        return out;
    }

    pub fn clearRenderUpdates(self: *PendingExtensionUi) void {
        for (self.render_updates.items) |*update| update.deinit(self.allocator);
        self.render_updates.deinit(self.allocator);
        self.render_updates = .empty;
    }

    pub fn publishFrame(self: *PendingExtensionUi, frame: extension_ui.UiFrame) !void {
        try frame.validate();
        var cloned = try extension_ui.UiFrame.clone(self.allocator, frame);
        errdefer cloned.deinit(self.allocator);
        try self.frame_updates.append(self.allocator, cloned);
    }

    pub fn takeFrameUpdates(self: *PendingExtensionUi, allocator: std.mem.Allocator) ![]extension_ui.UiFrame {
        const out = try allocator.alloc(extension_ui.UiFrame, self.frame_updates.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |*update| update.deinit(allocator);
        for (self.frame_updates.items, 0..) |update, i| {
            out[i] = try extension_ui.UiFrame.clone(allocator, update);
            initialized += 1;
        }
        self.clearFrameUpdates();
        return out;
    }

    pub fn clearFrameUpdates(self: *PendingExtensionUi) void {
        for (self.frame_updates.items) |*update| update.deinit(self.allocator);
        self.frame_updates.deinit(self.allocator);
        self.frame_updates = .empty;
    }

    pub fn publishEditorAction(self: *PendingExtensionUi, action: extension_ui.EditorAction) !void {
        var cloned = try extension_ui.EditorAction.clone(self.allocator, action);
        errdefer cloned.deinit(self.allocator);
        try self.editor_actions.append(self.allocator, cloned);
    }

    pub fn takeEditorActions(self: *PendingExtensionUi, allocator: std.mem.Allocator) ![]extension_ui.EditorAction {
        const out = try allocator.alloc(extension_ui.EditorAction, self.editor_actions.items.len);
        errdefer allocator.free(out);
        var initialized: usize = 0;
        errdefer for (out[0..initialized]) |*action| action.deinit(allocator);
        for (self.editor_actions.items, 0..) |action, i| {
            out[i] = try extension_ui.EditorAction.clone(allocator, action);
            initialized += 1;
        }
        self.clearEditorActions();
        return out;
    }

    pub fn clearEditorActions(self: *PendingExtensionUi) void {
        for (self.editor_actions.items) |*action| action.deinit(self.allocator);
        self.editor_actions.deinit(self.allocator);
        self.editor_actions = .empty;
    }
};
