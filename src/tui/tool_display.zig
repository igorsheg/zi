const std = @import("std");
const component_mod = @import("component.zig");
const buffer_mod = @import("buffer.zig");
const cell_mod = @import("cell.zig");
const grapheme = @import("grapheme.zig");
const word_wrap_mod = @import("word_wrap.zig");

const Component = component_mod.Component;
const Measurement = component_mod.Measurement;
const Region = buffer_mod.Region;
const Color = cell_mod.Color;
const Attributes = cell_mod.Attributes;
const Key = @import("keys.zig").Key;
const CursorState = component_mod.CursorState;
const UiEvent = @import("ui_event.zig").UiEvent;

/// Tool display interface — type-erased component + event reducer.
///
/// A ToolDisplay is created per tool execution and handles its own lifecycle:
/// - Receives events (start/update/end) via `apply`
/// - Renders its content (the tool-specific part, not the container chrome)
/// - The owning ToolExecutionComponent wraps this in background/padding
///
/// Tools register ToolDisplayFactory functions. The composition root builds
/// a ToolDisplayRegistry that maps tool names to factories.
pub const ToolDisplay = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const Event = union(enum) {
        start: struct {
            tool_name: []const u8,
            args_json: []const u8,
        },
        update: struct {
            result_text: ?[]const u8,
            is_error: bool,
        },
        end: struct {
            result_text: ?[]const u8,
            is_error: bool,
        },
    };

    pub const VTable = struct {
        apply: *const fn (ptr: *anyopaque, event: Event) void,
        render: *const fn (ptr: *anyopaque, region: Region) void,
        measure: *const fn (ptr: *anyopaque, width: u32) Measurement,
        handle_input: *const fn (ptr: *anyopaque, key: Key) bool,
        cursor_state: *const fn (ptr: *anyopaque) ?CursorState,
        deinit: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(comptime T: type, ptr: *T) ToolDisplay {
        const gen = struct {
            fn apply(erased: *anyopaque, event: Event) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.apply(event);
            }
            fn render(erased: *anyopaque, region: Region) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.render(region);
            }
            fn measure(erased: *anyopaque, width: u32) Measurement {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.measure(width);
            }
            fn handleInput(erased: *anyopaque, key: Key) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.handleInput(key);
            }
            fn cursorState(erased: *anyopaque) ?CursorState {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.cursorState();
            }
            fn deinit(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.deinit();
            }
        };
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .apply = gen.apply,
                .render = gen.render,
                .measure = gen.measure,
                .handle_input = gen.handleInput,
                .cursor_state = gen.cursorState,
                .deinit = gen.deinit,
            },
        };
    }

    pub fn apply(self: ToolDisplay, event: Event) void {
        self.vtable.apply(self.ptr, event);
    }

    pub fn render(self: ToolDisplay, region: Region) void {
        self.vtable.render(self.ptr, region);
    }

    pub fn measure(self: ToolDisplay, width: u32) Measurement {
        return self.vtable.measure(self.ptr, width);
    }

    pub fn handleInput(self: ToolDisplay, key: Key) bool {
        return self.vtable.handle_input(self.ptr, key);
    }

    pub fn cursorState(self: ToolDisplay) ?CursorState {
        return self.vtable.cursor_state(self.ptr);
    }

    pub fn deinitDisplay(self: ToolDisplay) void {
        self.vtable.deinit(self.ptr);
    }
};

/// Factory function that creates a ToolDisplay for a given tool.
pub const ToolDisplayFactory = *const fn (allocator: std.mem.Allocator, tool_name: []const u8) ?ToolDisplay;

/// Registry mapping tool names to display factories.
/// Composition root builds this and passes to Interactive.
pub const ToolDisplayRegistry = struct {
    entries: []const Registration,
    fallback: ToolDisplayFactory,

    pub const Registration = struct {
        tool_name: []const u8,
        factory: ToolDisplayFactory,
    };

    pub fn create(self: *const ToolDisplayRegistry, allocator: std.mem.Allocator, tool_name: []const u8) ToolDisplay {
        for (self.entries) |entry| {
            if (std.mem.eql(u8, entry.tool_name, tool_name)) {
                if (entry.factory(allocator, tool_name)) |display| {
                    return display;
                }
            }
        }
        return self.fallback(allocator, tool_name).?;
    }
};

// ============================================================================
// GenericDisplay — fallback for tools without a custom renderer
// ============================================================================

/// Displays: bold(tool_name) on the call line, plain text output for results.
pub const GenericDisplay = struct {
    allocator: std.mem.Allocator,
    tool_name: []u8 = &.{},
    args_json: []u8 = &.{},
    result_text: []u8 = &.{},
    is_error: bool = false,

    pub fn create(allocator: std.mem.Allocator, _: []const u8) ?ToolDisplay {
        const self = allocator.create(GenericDisplay) catch return null;
        self.* = .{ .allocator = allocator };
        return ToolDisplay.init(GenericDisplay, self);
    }

    pub fn apply(self: *GenericDisplay, event: ToolDisplay.Event) void {
        switch (event) {
            .start => |s| {
                self.freeField(&self.tool_name);
                self.tool_name = self.allocator.dupe(u8, s.tool_name) catch &.{};
                self.freeField(&self.args_json);
                self.args_json = self.allocator.dupe(u8, s.args_json) catch &.{};
            },
            .update => |u| {
                if (u.result_text) |txt| {
                    self.freeField(&self.result_text);
                    self.result_text = self.allocator.dupe(u8, txt) catch &.{};
                }
                self.is_error = u.is_error;
            },
            .end => |e| {
                if (e.result_text) |txt| {
                    self.freeField(&self.result_text);
                    self.result_text = self.allocator.dupe(u8, txt) catch &.{};
                }
                self.is_error = e.is_error;
            },
        }
    }

    pub fn render(self: *GenericDisplay, region: Region) void {
        const w = region.width;
        if (w == 0 or region.height == 0) return;

        var row: u32 = 0;

        // tool name (bold)
        if (self.tool_name.len > 0 and row < region.height) {
            _ = region.writeStr(0, row, self.tool_name, Color.default, Color.default, .{ .bold = true });
            row += 1;
        }

        // result text
        if (self.result_text.len > 0 and row < region.height) {
            const fg = if (self.is_error) Color.rgb(255, 80, 80) else Color.rgb(150, 150, 150);
            const lines = word_wrap_mod.wordWrap(self.result_text, w, self.allocator) catch return;
            defer self.allocator.free(lines);

            const max_preview: u32 = 5;
            var line_idx: u32 = 0;
            while (line_idx < @min(@as(u32, @intCast(lines.len)), max_preview) and row < region.height) {
                const line = lines[line_idx];
                _ = region.writeStr(0, row, line.text(self.result_text), fg, Color.default, .{});
                row += 1;
                line_idx += 1;
            }

            if (lines.len > max_preview and row < region.height) {
                const remaining = lines.len - max_preview;
                var hint_buf: [64]u8 = undefined;
                const hint = std.fmt.bufPrint(&hint_buf, "... ({d} more lines)", .{remaining}) catch "...";
                _ = region.writeStr(0, row, hint, Color.rgb(120, 120, 120), Color.default, .{});
            }
        }
    }

    pub fn measure(self: *GenericDisplay, width: u32) Measurement {
        if (width == 0) return .{ .min_height = 0, .preferred_height = 0 };
        var h: u32 = 0;

        if (self.tool_name.len > 0) h += 1;

        if (self.result_text.len > 0) {
            const lines = word_wrap_mod.wordWrap(self.result_text, width, self.allocator) catch
                return .{ .min_height = 1, .preferred_height = h + 1 };
            defer self.allocator.free(lines);
            h += @min(@as(u32, @intCast(lines.len)), 6); // 5 + hint line
        }

        return .{ .min_height = 1, .preferred_height = @max(1, h) };
    }

    pub fn handleInput(_: *GenericDisplay, _: Key) bool {
        return false;
    }

    pub fn cursorState(_: *GenericDisplay) ?CursorState {
        return null;
    }

    pub fn deinit(self: *GenericDisplay) void {
        self.freeField(&self.tool_name);
        self.freeField(&self.args_json);
        self.freeField(&self.result_text);
        self.allocator.destroy(self);
    }

    fn freeField(self: *GenericDisplay, field: *[]u8) void {
        if (field.len > 0) {
            self.allocator.free(field.*);
            field.* = &.{};
        }
    }
};

/// Default registry with only the generic fallback.
pub const default_registry = ToolDisplayRegistry{
    .entries = &.{},
    .fallback = &GenericDisplay.create,
};

// --- tests ---

const testing = std.testing;
const Buffer = buffer_mod.Buffer;

test "GenericDisplay renders tool name and result text" {
    var display = GenericDisplay.create(testing.allocator, "test_tool").?;
    defer display.deinitDisplay();

    display.apply(.{ .start = .{ .tool_name = "bash", .args_json = "{}" } });
    display.apply(.{ .end = .{ .result_text = "hello output", .is_error = false } });

    var buf = try Buffer.init(testing.allocator, 20, 5);
    defer buf.deinit();

    display.render(buf.region());

    // first row: tool name
    try testing.expectEqual(@as(u21, 'b'), buf.get(0, 0).grapheme.codepoint);
    try testing.expectEqual(@as(u21, 'a'), buf.get(1, 0).grapheme.codepoint);
    // second row: result text
    try testing.expectEqual(@as(u21, 'h'), buf.get(0, 1).grapheme.codepoint);
}

test "ToolDisplayRegistry falls back to generic" {
    const registry = default_registry;
    var display = registry.create(testing.allocator, "unknown_tool");
    defer display.deinitDisplay();

    display.apply(.{ .start = .{ .tool_name = "unknown_tool", .args_json = "{}" } });

    const m = display.measure(40);
    try testing.expect(m.preferred_height >= 1);
}
