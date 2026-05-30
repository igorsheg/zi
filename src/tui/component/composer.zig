const std = @import("std");

pub const CompletionState = union(enum) {
    closed,
    open: Open,

    pub const Open = struct {
        trigger: u8,
        query_start: usize,
        selected_index: usize = 0,
    };
};

pub const Composer = struct {
    pub const input_bytes_max = 64 * 1024;
    pub const insert_bytes_max = 4096;

    input: std.ArrayList(u8) = .empty,
    cursor_byte_index: usize = 0,
    revision: u64 = 0,
    completion: CompletionState = .closed,

    pub fn deinit(self: *Composer, allocator: std.mem.Allocator) void {
        self.input.deinit(allocator);
        self.* = undefined;
    }

    pub fn insert(self: *Composer, allocator: std.mem.Allocator, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        if (bytes.len > insert_bytes_max) return error.ComposerInsertTooLarge;
        if (self.input.items.len + bytes.len > input_bytes_max) return error.ComposerFull;
        std.debug.assert(self.cursor_byte_index <= self.input.items.len);

        try self.input.insertSlice(allocator, self.cursor_byte_index, bytes);
        self.cursor_byte_index += bytes.len;
        self.revision += 1;
        self.updateCompletion();
    }

    pub fn clear(self: *Composer, allocator: std.mem.Allocator) void {
        _ = allocator;
        self.input.clearRetainingCapacity();
        self.cursor_byte_index = 0;
        self.completion = .closed;
        self.revision += 1;
    }

    pub fn text(self: *const Composer) []const u8 {
        return self.input.items;
    }

    fn updateCompletion(self: *Composer) void {
        self.completion = .closed;
        if (self.cursor_byte_index == 0) return;

        var index = self.cursor_byte_index;
        while (index > 0) {
            index -= 1;
            const byte = self.input.items[index];
            if (byte == ' ' or byte == '\n' or byte == '\t') return;
            if (byte == '@' or byte == '/') {
                self.completion = .{ .open = .{
                    .trigger = byte,
                    .query_start = index + 1,
                } };
                return;
            }
        }
    }
};

test "composer opens completion on file and command triggers" {
    var composer: Composer = .{};
    defer composer.deinit(std.testing.allocator);

    try composer.insert(std.testing.allocator, "@src");
    try std.testing.expectEqualStrings("@src", composer.text());
    try std.testing.expectEqual(@as(u8, '@'), composer.completion.open.trigger);

    composer.clear(std.testing.allocator);
    try composer.insert(std.testing.allocator, "/model");
    try std.testing.expectEqual(@as(u8, '/'), composer.completion.open.trigger);
}
