const std = @import("std");

const buffer_mod = @import("../primitive/buffer.zig");
const transcript_mod = @import("transcript.zig");

pub const Renderer = struct {
    pub fn rebuildProjectionBuffer(
        allocator: std.mem.Allocator,
        store: *const transcript_mod.Store,
        projection: *buffer_mod.Buffer,
    ) !void {
        assertProjectionBuffer(projection);

        projection.clear(allocator);
        var index: usize = 0;
        while (index < store.item_count) : (index += 1) {
            try appendItem(allocator, projection, &store.items[index]);
        }
    }

    fn assertProjectionBuffer(projection: *const buffer_mod.Buffer) void {
        std.debug.assert(projection.kind == .scrollback);
    }

    fn appendItem(
        allocator: std.mem.Allocator,
        projection: *buffer_mod.Buffer,
        item: *const transcript_mod.TranscriptItem,
    ) !void {
        switch (item.kind) {
            .system => {
                try appendChunked(allocator, projection, "\n[system] ");
                try appendPayloadText(allocator, projection, item);
                try appendChunked(allocator, projection, "\n");
            },
            .user_message => {
                try appendChunked(allocator, projection, "\n> ");
                try appendPayloadText(allocator, projection, item);
                try appendChunked(allocator, projection, "\n");
            },
            .assistant_message => try appendPayloadText(allocator, projection, item),
            .tool_call => {
                try appendChunked(allocator, projection, "\n[tool] ");
                try appendPayloadText(allocator, projection, item);
                try appendChunked(allocator, projection, "\n");
            },
            .custom => {
                try appendChunked(allocator, projection, "\n[custom:");
                try appendChunked(allocator, projection, item.payload.custom.custom_type);
                try appendChunked(allocator, projection, "]\n");
            },
        }
    }

    fn appendPayloadText(
        allocator: std.mem.Allocator,
        projection: *buffer_mod.Buffer,
        item: *const transcript_mod.TranscriptItem,
    ) !void {
        switch (item.payload) {
            .text => |text| try appendChunked(allocator, projection, text),
            .custom => std.debug.panic("custom transcript item has non-text payload", .{}),
        }
    }

    fn appendChunked(
        allocator: std.mem.Allocator,
        projection: *buffer_mod.Buffer,
        bytes: []const u8,
    ) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const remaining = bytes.len - index;
            const chunk_len = @min(remaining, buffer_mod.Buffer.append_bytes_max);
            try projection.append(allocator, bytes[index .. index + chunk_len]);
            index += chunk_len;
        }
    }
};

test "transcript renderer projects built-in items into transcript projection buffer" {
    var store = transcript_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var projection = buffer_mod.Buffer.init(@enumFromInt(1), .scrollback, "transcript");
    defer projection.deinit(std.testing.allocator);

    _ = try store.appendText(.user_message, .persistent, "hello", 0);
    _ = try store.appendText(.assistant_message, .ephemeral, "hi", 0);
    _ = try store.appendText(.tool_call, .ephemeral, "build", 0);

    try Renderer.rebuildProjectionBuffer(std.testing.allocator, &store, &projection);

    try std.testing.expectEqualStrings("\n> hello\nhi\n[tool] build\n", projection.text());
}

test "custom transcript item has bounded fallback projection" {
    var store = transcript_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var projection = buffer_mod.Buffer.init(@enumFromInt(1), .scrollback, "transcript");
    defer projection.deinit(std.testing.allocator);

    _ = try store.appendCustom(.persistent, "todo", "{\"items\":[]}", 0);

    try Renderer.rebuildProjectionBuffer(std.testing.allocator, &store, &projection);

    try std.testing.expectEqualStrings("\n[custom:todo]\n", projection.text());
}
