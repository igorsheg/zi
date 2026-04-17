const std = @import("std");
const mime_mod = @import("mime.zig");

pub const Dimensions = struct {
    width: u32,
    height: u32,
};

pub fn sniff(bytes: []const u8, mime: mime_mod.Mime) ?Dimensions {
    return switch (mime) {
        .png => sniffPng(bytes),
        .jpeg => sniffJpeg(bytes),
        .gif => sniffGif(bytes),
        .webp => sniffWebp(bytes),
    };
}

fn sniffPng(bytes: []const u8) ?Dimensions {
    if (bytes.len < 24) return null;
    if (!std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return null;
    if (!std.mem.eql(u8, bytes[12..16], "IHDR")) return null;
    return .{
        .width = readU32Be(bytes[16..20]),
        .height = readU32Be(bytes[20..24]),
    };
}

fn sniffGif(bytes: []const u8) ?Dimensions {
    if (bytes.len < 10) return null;
    if (!(std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return null;
    return .{
        .width = readU16Le(bytes[6..8]),
        .height = readU16Le(bytes[8..10]),
    };
}

fn sniffJpeg(bytes: []const u8) ?Dimensions {
    if (bytes.len < 4 or bytes[0] != 0xFF or bytes[1] != 0xD8) return null;

    var i: usize = 2;
    while (i + 3 < bytes.len) {
        while (i < bytes.len and bytes[i] != 0xFF) : (i += 1) {}
        if (i + 1 >= bytes.len) return null;

        var marker_index = i + 1;
        while (marker_index < bytes.len and bytes[marker_index] == 0xFF) : (marker_index += 1) {}
        if (marker_index >= bytes.len) return null;

        const marker = bytes[marker_index];
        i = marker_index + 1;

        if (marker == 0xD9 or marker == 0xDA) return null;
        if (marker == 0x01 or (marker >= 0xD0 and marker <= 0xD7)) continue;
        if (i + 2 > bytes.len) return null;

        const segment_len = readU16Be(bytes[i .. i + 2]);
        if (segment_len < 2 or i + segment_len > bytes.len) return null;

        if (isStartOfFrame(marker)) {
            if (segment_len < 7) return null;
            return .{
                .width = readU16Be(bytes[i + 5 .. i + 7]),
                .height = readU16Be(bytes[i + 3 .. i + 5]),
            };
        }

        i += segment_len;
    }

    return null;
}

fn sniffWebp(bytes: []const u8) ?Dimensions {
    if (bytes.len < 20) return null;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP")) return null;

    var offset: usize = 12;
    while (offset + 8 <= bytes.len) {
        const chunk_id = bytes[offset .. offset + 4];
        const chunk_size = readU32Le(bytes[offset + 4 .. offset + 8]);
        const payload = offset + 8;
        if (payload + chunk_size > bytes.len) return null;

        if (std.mem.eql(u8, chunk_id, "VP8X")) {
            if (chunk_size < 10) return null;
            return .{
                .width = 1 + readU24Le(bytes[payload + 4 .. payload + 7]),
                .height = 1 + readU24Le(bytes[payload + 7 .. payload + 10]),
            };
        }
        if (std.mem.eql(u8, chunk_id, "VP8L")) {
            if (chunk_size < 5 or bytes[payload] != 0x2F) return null;
            const bits = readU32Le(bytes[payload + 1 .. payload + 5]);
            return .{
                .width = 1 + (bits & 0x3FFF),
                .height = 1 + ((bits >> 14) & 0x3FFF),
            };
        }
        if (std.mem.eql(u8, chunk_id, "VP8 ")) {
            if (chunk_size < 10) return null;
            if (!(bytes[payload + 3] == 0x9D and bytes[payload + 4] == 0x01 and bytes[payload + 5] == 0x2A)) return null;
            return .{
                .width = readU16Le(bytes[payload + 6 .. payload + 8]) & 0x3FFF,
                .height = readU16Le(bytes[payload + 8 .. payload + 10]) & 0x3FFF,
            };
        }

        offset = payload + chunk_size + (chunk_size & 1);
    }

    return null;
}

fn isStartOfFrame(marker: u8) bool {
    return switch (marker) {
        0xC0, 0xC1, 0xC2, 0xC3, 0xC5, 0xC6, 0xC7, 0xC9, 0xCA, 0xCB, 0xCD, 0xCE, 0xCF => true,
        else => false,
    };
}

fn readU16Le(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8);
}

fn readU16Be(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 8) | @as(u32, bytes[1]);
}

fn readU24Le(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}

fn readU32Le(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

fn readU32Be(bytes: []const u8) u32 {
    return (@as(u32, bytes[0]) << 24) |
        (@as(u32, bytes[1]) << 16) |
        (@as(u32, bytes[2]) << 8) |
        @as(u32, bytes[3]);
}

test "sniff extracts dimensions from supported image headers" {
    const png = &.{
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
        0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52,
        0x00, 0x00, 0x01, 0x2C,
        0x00, 0x00, 0x00, 0x96,
    };
    try std.testing.expectEqual(Dimensions{ .width = 300, .height = 150 }, sniff(png, .png).?);

    const gif = "GIF89a\x10\x00\x20\x00";
    try std.testing.expectEqual(Dimensions{ .width = 16, .height = 32 }, sniff(gif, .gif).?);

    const jpeg = &.{
        0xFF, 0xD8,
        0xFF, 0xE0, 0x00, 0x10,
        0x4A, 0x46, 0x49, 0x46, 0x00, 0x01, 0x01, 0x01,
        0x00, 0x48, 0x00, 0x48, 0x00, 0x00,
        0xFF, 0xC0, 0x00, 0x11,
        0x08,
        0x00, 0xF0,
        0x01, 0x40,
        0x03, 0x01, 0x11, 0x00, 0x02, 0x11, 0x00, 0x03, 0x11, 0x00,
    };
    try std.testing.expectEqual(Dimensions{ .width = 320, .height = 240 }, sniff(jpeg, .jpeg).?);

    const webp = &.{
        'R', 'I', 'F', 'F', 0x16, 0x00, 0x00, 0x00,
        'W', 'E', 'B', 'P',
        'V', 'P', '8', 'X', 0x0A, 0x00, 0x00, 0x00,
        0x00, 0x00, 0x00, 0x00,
        0x7F, 0x02, 0x00,
        0xDF, 0x01, 0x00,
    };
    try std.testing.expectEqual(Dimensions{ .width = 640, .height = 480 }, sniff(webp, .webp).?);
}
