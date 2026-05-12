const std = @import("std");
const tokens = @import("../themes/tokens.zig");

pub const Span = struct {
    text: []const u8,
    fg: ?tokens.FgColor = null,
    bg: ?tokens.BgColor = null,
    bold: bool = false,
    dim: bool = false,
    italic: bool = false,
    underline: bool = false,
};

pub const Line = []const Span;

pub const RenderedToolResult = struct {
    arena: std.heap.ArenaAllocator,
    collapsed: []const Line,
    expanded: []const Line,

    pub fn deinit(self: *RenderedToolResult, parent_allocator: std.mem.Allocator) void {
        self.arena.deinit();
        parent_allocator.destroy(self);
    }

    pub fn deinitOpaque(state: *anyopaque, allocator: std.mem.Allocator) void {
        const self: *RenderedToolResult = @ptrCast(@alignCast(state));
        self.deinit(allocator);
    }
};
