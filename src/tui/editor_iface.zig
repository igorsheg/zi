const std = @import("std");
const component_mod = @import("component.zig");

const Component = component_mod.Component;

/// Type-erased editor interface for runtime editor swapping.
///
/// Matches pi-mono's EditorComponent interface (packages/tui/src/editor-component.ts).
/// Interactive mode routes paste, bare newline, ctrl+d, and submit-clear through
/// this interface instead of referencing a concrete Editor directly.
///
/// The concrete Editor (components/editor.zig) implements all required methods.
/// Extensions can provide alternative editors (vim mode, emacs mode, etc.)
/// by implementing the same method set on their own struct.
pub const EditorInterface = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get_text: *const fn (ptr: *anyopaque) []const u8,
        insert_text: *const fn (ptr: *anyopaque, text: []const u8) void,
        clear: *const fn (ptr: *anyopaque) void,
        component: *const fn (ptr: *anyopaque) Component,
    };

    pub fn init(comptime T: type, ptr: *T) EditorInterface {
        const gen = struct {
            fn getText(erased: *anyopaque) []const u8 {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.getText();
            }
            fn insertText(erased: *anyopaque, text: []const u8) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.insertText(text);
            }
            fn clear(erased: *anyopaque) void {
                const self: *T = @ptrCast(@alignCast(erased));
                self.clear();
            }
            fn component(erased: *anyopaque) Component {
                const self: *T = @ptrCast(@alignCast(erased));
                return self.component();
            }
        };
        return .{
            .ptr = @ptrCast(ptr),
            .vtable = &.{
                .get_text = gen.getText,
                .insert_text = gen.insertText,
                .clear = gen.clear,
                .component = gen.component,
            },
        };
    }

    pub fn getText(self: EditorInterface) []const u8 {
        return self.vtable.get_text(self.ptr);
    }

    pub fn insertText(self: EditorInterface, text: []const u8) void {
        self.vtable.insert_text(self.ptr, text);
    }

    pub fn clear(self: EditorInterface) void {
        self.vtable.clear(self.ptr);
    }

    pub fn component(self: EditorInterface) Component {
        return self.vtable.component(self.ptr);
    }
};

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;
const buffer_mod = @import("buffer.zig");
const Region = buffer_mod.Region;

const MockEditor = struct {
    text: []const u8 = "",
    insert_count: u32 = 0,
    clear_count: u32 = 0,

    pub fn getText(self: *const MockEditor) []const u8 {
        return self.text;
    }

    pub fn insertText(self: *MockEditor, _: []const u8) void {
        self.insert_count += 1;
    }

    pub fn clear(self: *MockEditor) void {
        self.clear_count += 1;
    }

    pub fn render(_: *MockEditor, _: Region) void {}
    pub fn measure(_: *MockEditor, _: u32) component_mod.Measurement {
        return .{ .min_height = 1, .preferred_height = 3 };
    }

    pub fn component(self: *MockEditor) Component {
        return Component.init(MockEditor, self);
    }

    pub fn editorInterface(self: *MockEditor) EditorInterface {
        return EditorInterface.init(MockEditor, self);
    }
};

test "EditorInterface routes through vtable" {
    var mock = MockEditor{ .text = "hello" };
    const iface = mock.editorInterface();

    try testing.expectEqualStrings("hello", iface.getText());

    iface.insertText("world");
    try testing.expectEqual(@as(u32, 1), mock.insert_count);

    iface.clear();
    try testing.expectEqual(@as(u32, 1), mock.clear_count);

    // component() returns valid Component
    const comp = iface.component();
    const m = comp.measure(80);
    try testing.expectEqual(@as(u32, 3), m.preferred_height);
}
