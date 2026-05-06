const std = @import("std");

const component_mod = @import("../component.zig");
const text_mod = @import("../components/text.zig");
const framebuffer_surface_mod = @import("../components/framebuffer_surface.zig");
const extension_ui = @import("../../coding_agent/extensions/ui.zig");

const Component = component_mod.Component;

pub const ExtensionUiState = struct {
    allocator: std.mem.Allocator,
    message_text: text_mod.Text,
    frame_surface: framebuffer_surface_mod.FramebufferSurface,

    pub fn init(allocator: std.mem.Allocator) ExtensionUiState {
        return .{
            .allocator = allocator,
            .message_text = text_mod.Text.init(allocator),
            .frame_surface = framebuffer_surface_mod.FramebufferSurface.init(allocator),
        };
    }

    pub fn deinit(self: *ExtensionUiState) void {
        self.frame_surface.deinit();
        self.message_text.deinit();
    }

    pub fn messageComponent(self: *ExtensionUiState) Component {
        return self.message_text.component();
    }

    pub fn frameComponent(self: *ExtensionUiState) Component {
        return self.frame_surface.component();
    }

    pub fn applyRender(self: *ExtensionUiState, render: extension_ui.RenderSpec) void {
        if (render.title) |title| self.message_text.setContent(title);
    }

    pub fn applyFrame(self: *ExtensionUiState, frame: extension_ui.UiFrame) void {
        self.frame_surface.applyFrame(frame);
    }
};
