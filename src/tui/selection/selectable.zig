const std = @import("std");
const types = @import("types.zig");

pub const SelectableId = types.SelectableId;
pub const Point = types.Point;
pub const Rect = types.Rect;
pub const GlobalSelection = types.GlobalSelection;

pub const Selectable = struct {
    id: SelectableId,
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        bounds: *const fn (ptr: *anyopaque) Rect,
        should_start_selection: *const fn (ptr: *anyopaque, point: Point) bool,
        on_selection_changed: *const fn (ptr: *anyopaque, selection: ?GlobalSelection) bool,
        has_selection: *const fn (ptr: *anyopaque) bool,
        selected_text: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8,
        clear_selection: *const fn (ptr: *anyopaque) void,
    };

    pub fn init(comptime T: type, id: SelectableId, ptr: *T) Selectable {
        comptime {
            if (!@hasDecl(T, "selectionBounds")) @compileError(@typeName(T) ++ " must implement selectionBounds()");
            if (!@hasDecl(T, "shouldStartSelection")) @compileError(@typeName(T) ++ " must implement shouldStartSelection(point)");
            if (!@hasDecl(T, "onSelectionChanged")) @compileError(@typeName(T) ++ " must implement onSelectionChanged(selection)");
            if (!@hasDecl(T, "hasSelection")) @compileError(@typeName(T) ++ " must implement hasSelection()");
            if (!@hasDecl(T, "selectedText")) @compileError(@typeName(T) ++ " must implement selectedText(allocator)");
            if (!@hasDecl(T, "clearSelection")) @compileError(@typeName(T) ++ " must implement clearSelection()");
        }

        const gen = struct {
            fn bounds(erased: *anyopaque) Rect {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.selectionBounds();
            }
            fn shouldStartSelection(erased: *anyopaque, point: Point) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.shouldStartSelection(point);
            }
            fn onSelectionChanged(erased: *anyopaque, selection: ?GlobalSelection) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.onSelectionChanged(selection);
            }
            fn hasSelection(erased: *anyopaque) bool {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.hasSelection();
            }
            fn selectedText(erased: *anyopaque, allocator: std.mem.Allocator) anyerror!?[]u8 {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.selectedText(allocator);
            }
            fn clearSelection(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.clearSelection();
            }
        };

        return .{
            .id = id,
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .bounds = gen.bounds,
                .should_start_selection = gen.shouldStartSelection,
                .on_selection_changed = gen.onSelectionChanged,
                .has_selection = gen.hasSelection,
                .selected_text = gen.selectedText,
                .clear_selection = gen.clearSelection,
            },
        };
    }

    pub fn bounds(self: Selectable) Rect {
        return self.vtable.bounds(self.ptr);
    }

    pub fn shouldStartSelection(self: Selectable, point: Point) bool {
        return self.vtable.should_start_selection(self.ptr, point);
    }

    pub fn onSelectionChanged(self: Selectable, selection: ?GlobalSelection) bool {
        return self.vtable.on_selection_changed(self.ptr, selection);
    }

    pub fn hasSelection(self: Selectable) bool {
        return self.vtable.has_selection(self.ptr);
    }

    pub fn selectedText(self: Selectable, allocator: std.mem.Allocator) !?[]u8 {
        return self.vtable.selected_text(self.ptr, allocator);
    }

    pub fn clearSelection(self: Selectable) void {
        self.vtable.clear_selection(self.ptr);
    }
};
