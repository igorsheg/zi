const std = @import("std");
const tokens = @import("../themes/tokens.zig");

/// A single styled text run inside a retained extension-rendered line.
/// Pure data: no Lua state, callbacks, or extension runner pointers.
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

/// Arena-owned retained render document produced by an extension render hook on
/// the Lua-owner thread. Consumers may measure/paint this immutable document
/// without crossing into Lua.
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
