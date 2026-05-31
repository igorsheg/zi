const std = @import("std");
const surface = @import("surface.zig");

pub const Stack = struct {
    pub const entry_count_max = 16;

    entries: [entry_count_max]surface.SurfaceId = undefined,
    entry_count: usize = 0,

    pub fn init(base: surface.SurfaceId) Stack {
        var stack: Stack = .{};
        stack.entries[0] = base;
        stack.entry_count = 1;
        return stack;
    }

    pub fn active(self: *const Stack) surface.SurfaceId {
        std.debug.assert(self.entry_count > 0);
        return self.entries[self.entry_count - 1];
    }

    pub fn contains(self: *const Stack, id: surface.SurfaceId) bool {
        var index: usize = 0;
        while (index < self.entry_count) : (index += 1) {
            if (self.entries[index] == id) return true;
        }
        return false;
    }

    pub fn push(self: *Stack, id: surface.SurfaceId) !void {
        std.debug.assert(self.entry_count > 0);
        self.remove(id);
        if (self.entry_count == self.entries.len) return error.FocusStackFull;
        self.entries[self.entry_count] = id;
        self.entry_count += 1;
    }

    pub fn remove(self: *Stack, id: surface.SurfaceId) void {
        var write_index: usize = 0;
        var read_index: usize = 0;
        while (read_index < self.entry_count) : (read_index += 1) {
            if (self.entries[read_index] == id) continue;
            self.entries[write_index] = self.entries[read_index];
            write_index += 1;
        }
        self.entry_count = write_index;
        std.debug.assert(self.entry_count > 0);
    }
};

test "focus stack has one active owner and removes closed surfaces" {
    var stack = Stack.init(.input);

    try std.testing.expectEqual(surface.SurfaceId.input, stack.active());
    try stack.push(.diagnostics);
    try std.testing.expectEqual(surface.SurfaceId.diagnostics, stack.active());
    try stack.push(.chat);
    try std.testing.expectEqual(surface.SurfaceId.chat, stack.active());

    stack.remove(.chat);
    try std.testing.expectEqual(surface.SurfaceId.diagnostics, stack.active());
    stack.remove(.diagnostics);
    try std.testing.expectEqual(surface.SurfaceId.input, stack.active());
}

test "focus stack moves duplicate focus to the top" {
    var stack = Stack.init(.input);

    try stack.push(.diagnostics);
    try stack.push(.chat);
    try stack.push(.diagnostics);

    try std.testing.expectEqual(@as(usize, 3), stack.entry_count);
    try std.testing.expectEqual(surface.SurfaceId.diagnostics, stack.active());
}
