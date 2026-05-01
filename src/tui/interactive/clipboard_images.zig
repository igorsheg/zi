const std = @import("std");

const keybindings = @import("../keybindings.zig");
const ai_protocol = @import("../../ai/protocol.zig");
const image_mod = @import("../../image/root.zig");

pub const PendingImageAttachment = struct {
    image: ai_protocol.ImageContent,
    dimensions: ?image_mod.Dimensions = null,

    pub fn deinit(self: *PendingImageAttachment, allocator: std.mem.Allocator) void {
        allocator.free(self.image.data);
        allocator.free(self.image.mime_type);
        self.* = undefined;
    }
};

pub const PreparedClipboardImageResult = union(enum) {
    attach: PendingImageAttachment,
    rejected: []u8,

    pub fn deinit(self: *PreparedClipboardImageResult, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .attach => |*attachment| attachment.deinit(allocator),
            .rejected => |message| allocator.free(message),
        }
    }
};

pub const BuiltSubmitContent = struct {
    content: ai_protocol.UserMessage.UserMessageContent,

    pub fn deinit(self: *BuiltSubmitContent, allocator: std.mem.Allocator) void {
        switch (self.content) {
            .text => {},
            .blocks => |blocks| allocator.free(blocks),
        }
    }
};

pub fn buildSubmittedUserContent(
    allocator: std.mem.Allocator,
    text: []const u8,
    pending_images: []const PendingImageAttachment,
) !BuiltSubmitContent {
    if (pending_images.len == 0) return .{ .content = .{ .text = text } };

    var blocks: std.ArrayList(ai_protocol.UserMessage.UserMessageContent.Block) = .empty;
    errdefer blocks.deinit(allocator);

    var attached: std.DynamicBitSetUnmanaged = try .initEmpty(allocator, pending_images.len);
    defer attached.deinit(allocator);

    var segment_start: usize = 0;
    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            if (parseImageMarkerWithId(text, index, pending_images.len)) |marker| {
                const segment = std.mem.trim(u8, text[segment_start..index], " \t\r\n");
                if (segment.len > 0) try blocks.append(allocator, .{ .text = .{ .text = segment } });

                const attachment_index = marker.id - 1;
                try blocks.append(allocator, .{ .image = pending_images[attachment_index].image });
                attached.set(attachment_index);

                index = marker.end;
                segment_start = index;
                continue;
            }
        }
        index += 1;
    }

    const tail = std.mem.trim(u8, text[segment_start..], " \t\r\n");
    if (tail.len > 0) try blocks.append(allocator, .{ .text = .{ .text = tail } });

    for (pending_images, 0..) |attachment, attachment_index| {
        if (!attached.isSet(attachment_index)) try blocks.append(allocator, .{ .image = attachment.image });
    }

    return .{ .content = .{ .blocks = try blocks.toOwnedSlice(allocator) } };
}

pub fn prepareClipboardImageAttachment(
    allocator: std.mem.Allocator,
    raw: []const u8,
    policy: image_mod.InlinePolicy,
) !PreparedClipboardImageResult {
    const mime = image_mod.sniffMime(raw) orelse {
        return .{ .rejected = try allocator.dupe(u8, "clipboard image format unsupported") };
    };
    const dimensions = image_mod.sniffDimensions(raw, mime);
    switch (image_mod.evaluateInlineImage(raw.len, dimensions, policy)) {
        .needs_resize => return .{ .rejected = try std.fmt.allocPrint(
            allocator,
            "clipboard image not attached: {s}",
            .{image_mod.omittedInlineNote()},
        ) },
        .attach_original => {
            const encoded = try encodeBase64Owned(allocator, raw);
            errdefer allocator.free(encoded);
            const mime_owned = try allocator.dupe(u8, image_mod.mimeString(mime));
            return .{ .attach = .{
                .image = .{
                    .data = encoded,
                    .mime_type = mime_owned,
                },
                .dimensions = dimensions,
            } };
        },
    }
}

pub fn stripPendingImageMarkers(allocator: std.mem.Allocator, text: []const u8, pending_image_count: usize) ![]u8 {
    if (pending_image_count == 0 or text.len == 0) return allocator.dupe(u8, text);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var index: usize = 0;
    while (index < text.len) {
        if (text[index] == '[') {
            if (parseImageMarker(text, index, pending_image_count)) |end| {
                index = end;
                while (index < text.len and out.items.len > 0 and isAsciiWhitespace(out.items[out.items.len - 1]) and isAsciiWhitespace(text[index])) {
                    index += 1;
                }
                continue;
            }
        }
        try out.append(allocator, text[index]);
        index += 1;
    }

    const stripped = std.mem.trim(u8, out.items, " \t\r\n");
    if (stripped.len == out.items.len) return out.toOwnedSlice(allocator);
    const result = try allocator.dupe(u8, stripped);
    out.deinit(allocator);
    return result;
}

fn isAsciiWhitespace(byte: u8) bool {
    return byte == ' ' or byte == '\t' or byte == '\r' or byte == '\n';
}

const ImageMarker = struct {
    id: usize,
    end: usize,
};

fn parseImageMarker(text: []const u8, start: usize, pending_image_count: usize) ?usize {
    return if (parseImageMarkerWithId(text, start, pending_image_count)) |marker| marker.end else null;
}

fn parseImageMarkerWithId(text: []const u8, start: usize, pending_image_count: usize) ?ImageMarker {
    if (start >= text.len or text[start] != '[') return null;
    const prefix = "[image";
    if (!std.mem.startsWith(u8, text[start..], prefix)) return null;

    var index = start + prefix.len;
    if (index >= text.len or text[index] < '1' or text[index] > '9') return null;

    var id: usize = 0;
    while (index < text.len and text[index] >= '0' and text[index] <= '9') : (index += 1) {
        id = id * 10 + (text[index] - '0');
    }
    if (index >= text.len or text[index] != ']') return null;
    if (id == 0 or id > pending_image_count) return null;
    return .{ .id = id, .end = index + 1 };
}

pub fn pendingImageBannerText(
    allocator: std.mem.Allocator,
    pending_images: []const PendingImageAttachment,
) ![]u8 {
    var clear_binding_buf: [32]u8 = undefined;
    const clear_binding = keybindings.formatBindings(.app_clear, " / ", &clear_binding_buf);
    const last = pending_images[pending_images.len - 1];

    if (pending_images.len == 1) {
        if (last.dimensions) |dimensions| {
            return std.fmt.allocPrint(
                allocator,
                "1 clipboard image pending ({s}, {d}x{d}) · {s} to clear",
                .{ last.image.mime_type, dimensions.width, dimensions.height, clear_binding },
            );
        }
        return std.fmt.allocPrint(
            allocator,
            "1 clipboard image pending ({s}) · {s} to clear",
            .{ last.image.mime_type, clear_binding },
        );
    }

    if (last.dimensions) |dimensions| {
        return std.fmt.allocPrint(
            allocator,
            "{d} clipboard images pending (latest {s}, {d}x{d}) · {s} to clear",
            .{ pending_images.len, last.image.mime_type, dimensions.width, dimensions.height, clear_binding },
        );
    }
    return std.fmt.allocPrint(
        allocator,
        "{d} clipboard images pending (latest {s}) · {s} to clear",
        .{ pending_images.len, last.image.mime_type, clear_binding },
    );
}

fn encodeBase64Owned(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const encoded = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(raw.len));
    _ = std.base64.standard.Encoder.encode(encoded, raw);
    return encoded;
}

const testing = std.testing;

fn pngHeader(width: u32, height: u32) [24]u8 {
    return .{
        0x89,                                    0x50,                                    0x4E,                                   0x47,                            0x0D,                                     0x0A,                                     0x1A,                                    0x0A,
        0x00,                                    0x00,                                    0x00,                                   0x0D,                            0x49,                                     0x48,                                     0x44,                                    0x52,
        @as(u8, @intCast((width >> 24) & 0xFF)), @as(u8, @intCast((width >> 16) & 0xFF)), @as(u8, @intCast((width >> 8) & 0xFF)), @as(u8, @intCast(width & 0xFF)), @as(u8, @intCast((height >> 24) & 0xFF)), @as(u8, @intCast((height >> 16) & 0xFF)), @as(u8, @intCast((height >> 8) & 0xFF)), @as(u8, @intCast(height & 0xFF)),
    };
}

test "prepareClipboardImageAttachment accepts clipboard png within inline policy" {
    const png = pngHeader(64, 32);
    var prepared = try prepareClipboardImageAttachment(testing.allocator, &png, .{});
    defer prepared.deinit(testing.allocator);

    switch (prepared) {
        .attach => |attachment| {
            try testing.expectEqualStrings("image/png", attachment.image.mime_type);
            try testing.expectEqual(image_mod.Dimensions{ .width = 64, .height = 32 }, attachment.dimensions.?);
        },
        .rejected => return error.ExpectedClipboardAttachment,
    }
}

test "prepareClipboardImageAttachment rejects oversized clipboard image when auto resize is enabled" {
    const png = pngHeader(640, 480);
    var prepared = try prepareClipboardImageAttachment(testing.allocator, &png, .{
        .auto_resize = true,
        .max_width = 100,
        .max_height = 100,
        .max_base64_bytes = 1024,
    });
    defer prepared.deinit(testing.allocator);

    switch (prepared) {
        .rejected => |message| try testing.expect(std.mem.indexOf(u8, message, image_mod.omittedInlineNote()) != null),
        .attach => return error.ExpectedClipboardRejection,
    }
}

test "buildSubmittedUserContent preserves inline image marker placement" {
    const data1 = try testing.allocator.dupe(u8, "one");
    defer testing.allocator.free(data1);
    const mime1 = try testing.allocator.dupe(u8, "image/png");
    defer testing.allocator.free(mime1);
    const data2 = try testing.allocator.dupe(u8, "two");
    defer testing.allocator.free(data2);
    const mime2 = try testing.allocator.dupe(u8, "image/jpeg");
    defer testing.allocator.free(mime2);

    const pending = [_]PendingImageAttachment{
        .{ .image = .{ .data = data1, .mime_type = mime1 } },
        .{ .image = .{ .data = data2, .mime_type = mime2 } },
    };

    var built = try buildSubmittedUserContent(testing.allocator, "before [image2] middle [image1] after", &pending);
    defer built.deinit(testing.allocator);

    switch (built.content) {
        .blocks => |blocks| {
            try testing.expectEqual(@as(usize, 5), blocks.len);
            try testing.expectEqualStrings("before", blocks[0].text.text);
            try testing.expectEqualStrings("image/jpeg", blocks[1].image.mime_type);
            try testing.expectEqualStrings("middle", blocks[2].text.text);
            try testing.expectEqualStrings("image/png", blocks[3].image.mime_type);
            try testing.expectEqualStrings("after", blocks[4].text.text);
        },
        .text => return error.ExpectedBlockContent,
    }
}

test "buildSubmittedUserContent appends images whose markers were deleted" {
    const data = try testing.allocator.dupe(u8, "ZGF0YQ==");
    defer testing.allocator.free(data);
    const mime_type = try testing.allocator.dupe(u8, "image/png");
    defer testing.allocator.free(mime_type);

    const pending = [_]PendingImageAttachment{.{
        .image = .{ .data = data, .mime_type = mime_type },
        .dimensions = .{ .width = 10, .height = 20 },
    }};

    var built = try buildSubmittedUserContent(testing.allocator, "describe this", &pending);
    defer built.deinit(testing.allocator);

    switch (built.content) {
        .blocks => |blocks| {
            try testing.expectEqual(@as(usize, 2), blocks.len);
            try testing.expectEqualStrings("describe this", blocks[0].text.text);
            try testing.expectEqualStrings("image/png", blocks[1].image.mime_type);
        },
        .text => return error.ExpectedBlockContent,
    }
}

test "stripPendingImageMarkers removes inline image placeholders" {
    const stripped = try stripPendingImageMarkers(testing.allocator, "look [image1] and [image2]", 2);
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings("look and", stripped);
}

test "stripPendingImageMarkers preserves unrelated bracketed text" {
    const stripped = try stripPendingImageMarkers(testing.allocator, "[image1] [image3] [paste #1]", 2);
    defer testing.allocator.free(stripped);
    try testing.expectEqualStrings("[image3] [paste #1]", stripped);
}

test "pendingImageBannerText includes latest image details and clear shortcut" {
    const data1 = try testing.allocator.dupe(u8, "aaa");
    defer testing.allocator.free(data1);
    const mime1 = try testing.allocator.dupe(u8, "image/png");
    defer testing.allocator.free(mime1);
    const data2 = try testing.allocator.dupe(u8, "bbb");
    defer testing.allocator.free(data2);
    const mime2 = try testing.allocator.dupe(u8, "image/jpeg");
    defer testing.allocator.free(mime2);

    const pending = [_]PendingImageAttachment{
        .{ .image = .{ .data = data1, .mime_type = mime1 }, .dimensions = .{ .width = 10, .height = 20 } },
        .{ .image = .{ .data = data2, .mime_type = mime2 }, .dimensions = .{ .width = 30, .height = 40 } },
    };

    const banner = try pendingImageBannerText(testing.allocator, &pending);
    defer testing.allocator.free(banner);

    try testing.expect(std.mem.indexOf(u8, banner, "2 clipboard images pending") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "image/jpeg") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "30x40") != null);
    try testing.expect(std.mem.indexOf(u8, banner, "ctrl+c") != null);
}
