const std = @import("std");

pub const Mime = enum {
    jpeg,
    png,
    gif,
    webp,
};

pub fn sniff(bytes: []const u8) ?Mime {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], "\x89PNG\r\n\x1a\n")) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xFF and bytes[1] == 0xD8 and bytes[2] == 0xFF) return .jpeg;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    if (bytes.len >= 12 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) return .webp;
    return null;
}

pub fn toString(mime: Mime) []const u8 {
    return switch (mime) {
        .jpeg => "image/jpeg",
        .png => "image/png",
        .gif => "image/gif",
        .webp => "image/webp",
    };
}

pub fn extension(mime: Mime) []const u8 {
    return switch (mime) {
        .jpeg => ".jpg",
        .png => ".png",
        .gif => ".gif",
        .webp => ".webp",
    };
}

test "sniff detects supported image formats by magic bytes" {
    try std.testing.expectEqual(Mime.png, sniff("\x89PNG\r\n\x1a\nrest").?);
    try std.testing.expectEqual(Mime.jpeg, sniff(&.{ 0xFF, 0xD8, 0xFF, 0xE0 }).?);
    try std.testing.expectEqual(Mime.gif, sniff("GIF89arest").?);
    try std.testing.expectEqual(Mime.webp, sniff("RIFFxxxxWEBPVP8 ").?);
    try std.testing.expect(sniff("not an image") == null);
}
