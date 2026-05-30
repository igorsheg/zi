const std = @import("std");

const buffer_mod = @import("buffer.zig");
const transcript_mod = @import("transcript.zig");

pub const Renderer = struct {
    pub fn appendItemToChatBuffer(
        allocator: std.mem.Allocator,
        item: *const transcript_mod.TranscriptItem,
        chat: *buffer_mod.Buffer,
    ) !void {
        assertChatBuffer(chat);
        try appendItem(allocator, chat, item);
    }

    pub fn appendAssistantDeltaToChatBuffer(
        allocator: std.mem.Allocator,
        delta: []const u8,
        chat: *buffer_mod.Buffer,
    ) !void {
        assertChatBuffer(chat);
        try appendChunked(allocator, chat, delta);
    }

    pub fn rebuildChatBuffer(
        allocator: std.mem.Allocator,
        store: *const transcript_mod.Store,
        chat: *buffer_mod.Buffer,
    ) !void {
        assertChatBuffer(chat);

        chat.clear(allocator);
        var index: usize = 0;
        while (index < store.item_count) : (index += 1) {
            try appendItem(allocator, chat, &store.items[index]);
        }
    }

    fn assertChatBuffer(chat: *const buffer_mod.Buffer) void {
        std.debug.assert(chat.id == .chat);
        std.debug.assert(chat.kind == .chat);
    }

    fn appendItem(
        allocator: std.mem.Allocator,
        chat: *buffer_mod.Buffer,
        item: *const transcript_mod.TranscriptItem,
    ) !void {
        switch (item.kind) {
            .system => {
                try appendChunked(allocator, chat, "\n[system] ");
                try appendPayloadText(allocator, chat, item);
                try appendChunked(allocator, chat, "\n");
            },
            .user_message => {
                try appendChunked(allocator, chat, "\n> ");
                try appendPayloadText(allocator, chat, item);
                try appendChunked(allocator, chat, "\n");
            },
            .assistant_message => try appendPayloadText(allocator, chat, item),
            .tool_call => {
                try appendChunked(allocator, chat, "\n[tool] ");
                try appendPayloadText(allocator, chat, item);
                try appendChunked(allocator, chat, "\n");
            },
            .custom => {
                try appendChunked(allocator, chat, "\n[custom:");
                try appendChunked(allocator, chat, item.payload.custom.custom_type);
                try appendChunked(allocator, chat, "]\n");
            },
        }
    }

    fn appendPayloadText(
        allocator: std.mem.Allocator,
        chat: *buffer_mod.Buffer,
        item: *const transcript_mod.TranscriptItem,
    ) !void {
        switch (item.payload) {
            .text => |text| try appendChunked(allocator, chat, text),
            .custom => std.debug.panic("custom transcript item has non-text payload", .{}),
        }
    }

    fn appendChunked(
        allocator: std.mem.Allocator,
        chat: *buffer_mod.Buffer,
        bytes: []const u8,
    ) !void {
        var index: usize = 0;
        while (index < bytes.len) {
            const remaining = bytes.len - index;
            const chunk_len = @min(remaining, buffer_mod.Buffer.append_bytes_max);
            try chat.append(allocator, bytes[index .. index + chunk_len]);
            index += chunk_len;
        }
    }
};

test "transcript renderer projects built-in items into chat buffer" {
    var store = transcript_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var chat = buffer_mod.Buffer.init(.chat, .chat, "chat");
    defer chat.deinit(std.testing.allocator);

    _ = try store.appendText(.user_message, .persistent, "hello", 0);
    _ = try store.appendText(.assistant_message, .ephemeral, "hi", 0);
    _ = try store.appendText(.tool_call, .ephemeral, "build", 0);

    try Renderer.rebuildChatBuffer(std.testing.allocator, &store, &chat);

    try std.testing.expectEqualStrings("\n> hello\nhi\n[tool] build\n", chat.text());
}

test "custom transcript item has bounded fallback projection" {
    var store = transcript_mod.Store.init(std.testing.allocator);
    defer store.deinit();
    var chat = buffer_mod.Buffer.init(.chat, .chat, "chat");
    defer chat.deinit(std.testing.allocator);

    _ = try store.appendCustom(.persistent, "todo", "{\"items\":[]}", 0);

    try Renderer.rebuildChatBuffer(std.testing.allocator, &store, &chat);

    try std.testing.expectEqualStrings("\n[custom:todo]\n", chat.text());
}
