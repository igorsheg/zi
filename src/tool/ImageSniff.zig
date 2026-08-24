const std = @import("std");

pub const Format = enum {
    png,
    gif,
    jpeg,
    webp,

    pub fn mime(self: Format) []const u8 {
        return switch (self) {
            .png => "image/png",
            .gif => "image/gif",
            .jpeg => "image/jpeg",
            .webp => "image/webp",
        };
    }
};

pub const Info = struct {
    format: Format,
    width: u32 = 0,
    height: u32 = 0,
    complete: bool = false,

    pub fn mime(self: Info) []const u8 {
        return self.format.mime();
    }
};

/// Inspects borrowed bytes without allocating. Dimensions are best effort.
/// `complete` reproduces hax's container-sentinel checks, not full decoding. In
/// particular, PNG/WebP trailing bytes and minimal JPEG segment declarations
/// accepted by hax remain accepted here; compressed pixels and CRCs are ignored.
pub fn sniff(data: []const u8) ?Info {
    if (data.len >= 8 and std.mem.eql(u8, data[0..8], "\x89PNG\r\n\x1a\n"))
        return inspectPng(data);
    if (data.len >= 6 and
        (std.mem.eql(u8, data[0..6], "GIF87a") or std.mem.eql(u8, data[0..6], "GIF89a")))
        return inspectGif(data);
    if (data.len >= 3 and data[0] == 0xff and data[1] == 0xd8 and data[2] == 0xff)
        return inspectJpeg(data);
    if (data.len >= 12 and std.mem.eql(u8, data[0..4], "RIFF") and
        std.mem.eql(u8, data[8..12], "WEBP"))
        return inspectWebp(data);
    return null;
}

fn readBe16(data: []const u8) u16 {
    return (@as(u16, data[0]) << 8) | data[1];
}

fn readBe32(data: []const u8) u32 {
    return (@as(u32, data[0]) << 24) | (@as(u32, data[1]) << 16) |
        (@as(u32, data[2]) << 8) | data[3];
}

fn readLe16(data: []const u8) u16 {
    return (@as(u16, data[1]) << 8) | data[0];
}

fn readLe24(data: []const u8) u32 {
    return (@as(u32, data[2]) << 16) | (@as(u32, data[1]) << 8) | data[0];
}

fn readLe32(data: []const u8) u32 {
    return (@as(u32, data[3]) << 24) | (@as(u32, data[2]) << 16) |
        (@as(u32, data[1]) << 8) | data[0];
}

fn inspectPng(data: []const u8) Info {
    var info: Info = .{ .format = .png, .complete = pngIsComplete(data) };
    if (data.len >= 24 and readBe32(data[8..12]) == 13 and std.mem.eql(u8, data[12..16], "IHDR")) {
        info.width = readBe32(data[16..20]);
        info.height = readBe32(data[20..24]);
    }
    return info;
}

fn pngIsComplete(data: []const u8) bool {
    var offset: usize = 8;
    var saw_ihdr = false;
    var saw_image_data = false;
    while (offset <= data.len) {
        const remaining = data.len - offset;
        if (remaining < 12) return false;
        const chunk_data_len: usize = readBe32(data[offset..][0..4]);
        if (chunk_data_len > remaining - 12) return false;
        const chunk_type = data[offset + 4 .. offset + 8];
        if (!saw_ihdr) {
            if (!std.mem.eql(u8, chunk_type, "IHDR") or chunk_data_len != 13) return false;
            saw_ihdr = true;
        } else if (std.mem.eql(u8, chunk_type, "IDAT")) {
            saw_image_data = true;
        } else if (std.mem.eql(u8, chunk_type, "IEND")) {
            return chunk_data_len == 0 and saw_image_data;
        }
        offset += 12 + chunk_data_len;
    }
    return false;
}

fn inspectGif(data: []const u8) Info {
    var info: Info = .{ .format = .gif, .complete = gifIsComplete(data) };
    if (data.len >= 10) {
        info.width = readLe16(data[6..8]);
        info.height = readLe16(data[8..10]);
    }
    return info;
}

fn skipGifSubBlocks(data: []const u8, offset_ptr: *usize, saw_data: ?*bool) bool {
    while (offset_ptr.* < data.len) {
        const block_len: usize = data[offset_ptr.*];
        offset_ptr.* += 1;
        if (block_len == 0) return true;
        if (block_len > data.len - offset_ptr.*) return false;
        if (saw_data) |value| value.* = true;
        offset_ptr.* += block_len;
    }
    return false;
}

fn gifIsComplete(data: []const u8) bool {
    if (data.len < 13) return false;
    var offset: usize = 13;
    if (data[10] & 0x80 != 0) {
        const shift: u4 = @intCast((data[10] & 0x07) + 1);
        const color_table_len: usize = @as(usize, 3) << shift;
        if (color_table_len > data.len - offset) return false;
        offset += color_table_len;
    }
    var saw_image = false;
    while (offset < data.len) {
        const block_type = data[offset];
        if (block_type == 0x3b) return saw_image and offset + 1 == data.len;
        if (block_type == 0x21) {
            if (data.len - offset < 2) return false;
            offset += 2;
            if (!skipGifSubBlocks(data, &offset, null)) return false;
            continue;
        }
        if (block_type != 0x2c or data.len - offset < 10) return false;
        const flags = data[offset + 9];
        offset += 10;
        if (flags & 0x80 != 0) {
            const shift: u4 = @intCast((flags & 0x07) + 1);
            const color_table_len: usize = @as(usize, 3) << shift;
            if (color_table_len > data.len - offset) return false;
            offset += color_table_len;
        }
        if (offset >= data.len) return false;
        offset += 1;
        var saw_compressed_data = false;
        if (!skipGifSubBlocks(data, &offset, &saw_compressed_data) or !saw_compressed_data)
            return false;
        saw_image = true;
    }
    return false;
}

fn jpegMarkerIsStandalone(marker: u8) bool {
    return marker == 0x01 or (marker >= 0xd0 and marker <= 0xd7);
}

fn jpegMarkerIsSof(marker: u8) bool {
    return marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
}

fn inspectJpeg(data: []const u8) Info {
    var info: Info = .{ .format = .jpeg, .complete = jpegIsComplete(data) };
    readJpegDimensions(data, &info);
    return info;
}

fn readJpegDimensions(data: []const u8, info: *Info) void {
    var offset: usize = 2;
    while (offset < data.len) {
        if (data[offset] != 0xff) return;
        offset += 1;
        while (offset < data.len and data[offset] == 0xff) offset += 1;
        if (offset >= data.len) return;
        const marker = data[offset];
        offset += 1;
        if (marker == 0x00 or marker == 0xd9 or marker == 0xda) return;
        if (jpegMarkerIsStandalone(marker)) continue;
        if (data.len - offset < 2) return;
        const segment_len: usize = readBe16(data[offset..][0..2]);
        if (segment_len < 2 or segment_len > data.len - offset) return;
        if (jpegMarkerIsSof(marker)) {
            if (segment_len >= 7) {
                info.height = readBe16(data[offset + 3 .. offset + 5]);
                info.width = readBe16(data[offset + 5 .. offset + 7]);
            }
            return;
        }
        offset += segment_len;
    }
}

fn jpegIsComplete(data: []const u8) bool {
    var offset: usize = 2;
    var saw_scan = false;
    while (offset < data.len) {
        if (data[offset] != 0xff) return false;
        offset += 1;
        while (offset < data.len and data[offset] == 0xff) offset += 1;
        if (offset >= data.len) return false;
        const marker = data[offset];
        offset += 1;
        if (marker == 0x00) return false;
        if (marker == 0xd9) return saw_scan;
        if (jpegMarkerIsStandalone(marker)) continue;
        if (data.len - offset < 2) return false;
        const segment_len: usize = readBe16(data[offset..][0..2]);
        if (segment_len < 2 or segment_len > data.len - offset) return false;
        offset += segment_len;
        if (marker != 0xda) continue;
        saw_scan = true;
        while (data.len - offset >= 2) {
            if (data[offset] != 0xff) {
                offset += 1;
                continue;
            }
            const escaped = data[offset + 1];
            if (escaped == 0x00 or (escaped >= 0xd0 and escaped <= 0xd7)) {
                offset += 2;
                continue;
            }
            if (escaped == 0xff) {
                offset += 1;
                continue;
            }
            break;
        }
    }
    return false;
}

const WebpChunk = struct {
    kind: []const u8,
    data: []const u8,
};

fn nextWebpChunk(data: []const u8, offset_ptr: *usize) ?WebpChunk {
    const offset = offset_ptr.*;
    if (offset > data.len or data.len - offset < 8) return null;
    const payload_len: usize = readLe32(data[offset + 4 .. offset + 8]);
    if (payload_len > data.len - offset - 8) return null;
    var next_offset = offset + 8 + payload_len;
    if (payload_len & 1 != 0) {
        if (next_offset >= data.len) return null;
        next_offset += 1;
    }
    offset_ptr.* = next_offset;
    return .{ .kind = data[offset .. offset + 4], .data = data[offset + 8 .. offset + 8 + payload_len] };
}

fn webpLossyPayloadIsValid(data: []const u8) bool {
    return data.len >= 10 and data[3] == 0x9d and data[4] == 0x01 and data[5] == 0x2a;
}

fn webpLosslessPayloadIsValid(data: []const u8) bool {
    return data.len >= 5 and data[0] == 0x2f;
}

fn webpAnimationFrameIsComplete(data: []const u8) bool {
    if (data.len < 16) return false;
    var offset: usize = 16;
    var saw_image_data = false;
    while (offset < data.len) {
        const chunk = nextWebpChunk(data, &offset) orelse return false;
        if (std.mem.eql(u8, chunk.kind, "VP8 ")) {
            if (!webpLossyPayloadIsValid(chunk.data)) return false;
            saw_image_data = true;
        } else if (std.mem.eql(u8, chunk.kind, "VP8L")) {
            if (!webpLosslessPayloadIsValid(chunk.data)) return false;
            saw_image_data = true;
        }
    }
    return saw_image_data;
}

fn webpIsComplete(data: []const u8) bool {
    const riff_data_len: usize = readLe32(data[4..8]);
    if (riff_data_len < 4 or riff_data_len > data.len - 8) return false;
    const chunks_len = riff_data_len - 4;
    const chunks = data[12 .. 12 + chunks_len];
    var offset: usize = 0;
    var saw_image_data = false;
    while (offset < chunks.len) {
        const chunk = nextWebpChunk(chunks, &offset) orelse return false;
        if (std.mem.eql(u8, chunk.kind, "VP8 ")) {
            if (!webpLossyPayloadIsValid(chunk.data)) return false;
            saw_image_data = true;
        } else if (std.mem.eql(u8, chunk.kind, "VP8L")) {
            if (!webpLosslessPayloadIsValid(chunk.data)) return false;
            saw_image_data = true;
        } else if (std.mem.eql(u8, chunk.kind, "ANMF")) {
            if (!webpAnimationFrameIsComplete(chunk.data)) return false;
            saw_image_data = true;
        }
    }
    return saw_image_data;
}

fn inspectWebp(data: []const u8) Info {
    var info: Info = .{ .format = .webp, .complete = webpIsComplete(data) };
    if (data.len < 20) return info;
    const chunk_type = data[12..16];
    const chunk_data_len: usize = readLe32(data[16..20]);
    const available = data.len - 20;
    if (std.mem.eql(u8, chunk_type, "VP8 ") and chunk_data_len <= available and
        webpLossyPayloadIsValid(data[20 .. 20 + chunk_data_len]))
    {
        const chunk_data = data[20 .. 20 + chunk_data_len];
        info.width = readLe16(chunk_data[6..8]) & 0x3fff;
        info.height = readLe16(chunk_data[8..10]) & 0x3fff;
    } else if (std.mem.eql(u8, chunk_type, "VP8L") and chunk_data_len <= available and
        webpLosslessPayloadIsValid(data[20 .. 20 + chunk_data_len]))
    {
        const dimensions = readLe32(data[21..25]);
        info.width = (dimensions & 0x3fff) + 1;
        info.height = ((dimensions >> 14) & 0x3fff) + 1;
    } else if (std.mem.eql(u8, chunk_type, "VP8X") and chunk_data_len >= 10 and available >= 10) {
        info.width = readLe24(data[24..27]) + 1;
        info.height = readLe24(data[27..30]) + 1;
    }
    return info;
}

fn expectInfo(data: []const u8, format: Format, width: u32, height: u32) !void {
    const info = sniff(data) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(format, info.format);
    try std.testing.expectEqualStrings(format.mime(), info.mime());
    try std.testing.expectEqual(width, info.width);
    try std.testing.expectEqual(height, info.height);
}

fn expectComplete(data: []const u8, expected: bool) !void {
    const info = sniff(data) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(expected, info.complete);
}

test "dimensions and truncated recognized headers" {
    const png = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR\x00\x00\x03\x20\x00\x00\x02\x58\x08\x06\x00\x00\x00";
    try expectInfo(png, .png, 800, 600);
    try expectInfo(png[0..8], .png, 0, 0);
    try expectInfo("GIF89a\x40\x01\xc8\x00", .gif, 320, 200);

    const jpeg = "\xff\xd8\xff\xe0\x00\x10JFIF\x00\x01\x01\x00\x00\x01\x00\x01\x00\x00" ++
        "\xff\xc0\x00\x11\x08\x01\x00\x02\x00\x03\x01\x22\x00\x02\x11\x01\x03\x11\x01\xff\xd9";
    try expectInfo(jpeg, .jpeg, 512, 256);

    const lossy = "RIFF\x16\x00\x00\x00WEBPVP8 \x0a\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\x80\x02\xe0\x01";
    try expectInfo(lossy, .webp, 640, 480);
    const bits: u32 = 99 | (49 << 14);
    const lossless = [_]u8{
        'R',                   'I',             'F',                  'F',
        0x12,                  0,               0,                    0,
        'W',                   'E',             'B',                  'P',
        'V',                   'P',             '8',                  'L',
        5,                     0,               0,                    0,
        0x2f,                  @truncate(bits), @truncate(bits >> 8), @truncate(bits >> 16),
        @truncate(bits >> 24), 0,
    };
    try expectInfo(&lossless, .webp, 100, 50);
    const extended = "RIFF\x16\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x00\x00\x00\x00\x7f\x07\x00\x37\x04\x00";
    try expectInfo(extended, .webp, 1920, 1080);
}

test "PNG completeness" {
    const ihdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x08\x00\x00\x00\x08\x08\x02\x00\x00\x00\x00\x00\x00\x00";
    const idat = "\x00\x00\x00\x02IDAT\x78\x9c\x00\x00\x00\x00";
    const iend = "\x00\x00\x00\x00IEND\xae\x42\x60\x82";
    const png = ihdr ++ idat ++ iend;
    try expectComplete(png, true);
    try expectComplete(png[0 .. png.len - 4], false);
    try expectComplete(ihdr, false);
    try expectComplete(ihdr ++ iend, false);
    try expectComplete(ihdr[0..8] ++ idat ++ iend, false);
}

test "GIF completeness" {
    const gif = "GIF89a\x01\x00\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x02\x02\x44\x01\x00\x3b";
    try expectComplete(gif, true);
    try expectComplete(gif[0 .. gif.len - 1], false);
    try expectComplete("GIF89a\x01\x00\x01\x00\x00\x00\x00\x3b", false);
    try expectComplete("GIF89a\x01\x00\x01\x00\x00\x00\x00\x2c\x00\x00\x00\x00\x01\x00\x01\x00\x00\x3b", false);
}

test "JPEG completeness" {
    const jpeg = "\xff\xd8\xff\xc0\x00\x11\x08\x00\x08\x00\x08\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01" ++
        "\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00\x12\x34\xff\x00\xff\xd0\x56\xff\xff\xd9";
    try expectComplete(jpeg, true);
    try expectComplete(jpeg[0 .. jpeg.len - 2], false);
    try expectComplete("\xff\xd8\xff\xd9", false);
    try expectComplete(jpeg[0..2] ++ "\xff\xd8" ++ jpeg[2..], false);
    const embedded = "\xff\xd8\xff\xe1\x00\x08\xff\xd8\xff\xd9\x00\x00" ++
        "\xff\xc0\x00\x11\x08\x00\x08\x00\x08\x03\x01\x11\x00\x02\x11\x01\x03\x11\x01" ++
        "\xff\xda\x00\x0c\x03\x01\x00\x02\x11\x03\x11\x00\x3f\x00\x12\x34";
    try expectComplete(embedded, false);
}

test "WebP completeness including animation" {
    const webp = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00";
    try expectComplete(webp, true);
    try expectComplete(webp[0 .. webp.len - 1], false);
    var invalid = webp.*;
    invalid[16] = 7;
    try expectComplete(&invalid, false);
    try expectComplete("RIFF\x0c\x00\x00\x00WEBPVP8 \x00\x00\x00\x00", false);
    try expectComplete("RIFF\x0c\x00\x00\x00WEBPVP8L\x00\x00\x00\x00", false);
    const empty_frame = "RIFF\x1e\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00" ++
        "\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00ANMF\x00\x00\x00\x00";
    const empty_info = sniff(empty_frame).?;
    try std.testing.expectEqual(@as(u32, 1), empty_info.width);
    try std.testing.expect(!empty_info.complete);
    const animation = "RIFF\x3c\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "ANMF\x1e\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" ++
        "VP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00";
    try expectComplete(animation, true);
}

test "non-images do not match" {
    try std.testing.expect(sniff("#!/bin/sh\necho hello\n") == null);
    try std.testing.expect(sniff("\x7fELF\x02\x01\x01\x00") == null);
    try std.testing.expect(sniff("") == null);
    try std.testing.expect(sniff("RIFF\x00\x00\x00\x00WAVE") == null);
}

test "hax-compatible completeness intentionally accepts lenient framing" {
    const ihdr = "\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR" ++
        "\x00\x00\x00\x01\x00\x00\x00\x01\x08\x02\x00\x00\x00\x00\x00\x00\x00";
    const idat = "\x00\x00\x00\x00IDAT\x00\x00\x00\x00";
    const iend = "\x00\x00\x00\x00IEND\x00\x00\x00\x00";
    try std.testing.expect(sniff(ihdr ++ idat ++ iend ++ "trailer").?.complete);

    const webp = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00";
    try std.testing.expect(sniff(webp ++ "trailer").?.complete);

    const minimal_jpeg = "\xff\xd8\xff\xc0\x00\x07\x08\x00\x01\x00\x01" ++
        "\xff\xda\x00\x02\xff\xd9";
    const jpeg_info = sniff(minimal_jpeg).?;
    try std.testing.expect(jpeg_info.complete);
    try std.testing.expectEqual(@as(u32, 1), jpeg_info.width);
    try std.testing.expectEqual(@as(u32, 1), jpeg_info.height);
}
