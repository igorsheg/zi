const std = @import("std");
const text = @import("../text/root.zig");

/// Writes untrusted text without allowing terminal control characters or invalid UTF-8.
pub fn write(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    _ = try writeBounded(writer, bytes, std.math.maxInt(usize));
}

/// Writes at most `maximum` escaped bytes and appends dots without splitting a spelling.
pub fn writeBounded(
    writer: *std.Io.Writer,
    bytes: []const u8,
    maximum: usize,
) std.Io.Writer.Error!bool {
    var total: usize = 0;
    var scan: usize = 0;
    while (scan < bytes.len) {
        var storage: [16]u8 = undefined;
        const unit = escapedAt(bytes, scan, &storage);
        total +|= unit.bytes.len;
        scan += unit.consumed;
    }
    const clipped = total > maximum;
    if (clipped and maximum <= 3) {
        try writer.splatByteAll('.', maximum);
        return true;
    }

    const budget = if (clipped) maximum - 3 else maximum;
    var offset: usize = 0;
    var written: usize = 0;
    while (offset < bytes.len) {
        var storage: [16]u8 = undefined;
        const unit = escapedAt(bytes, offset, &storage);
        if (unit.bytes.len > budget -| written) break;
        try writer.writeAll(unit.bytes);
        written += unit.bytes.len;
        offset += unit.consumed;
    }
    if (clipped) try writer.writeAll("...");
    return clipped;
}

const EscapedUnit = struct {
    bytes: []const u8,
    consumed: usize,
};

fn escapedAt(bytes: []const u8, offset: usize, storage: *[16]u8) EscapedUnit {
    const first = bytes[offset];
    if (first < 0x80) {
        if (first >= 0x20 and first != 0x7f)
            return .{ .bytes = bytes[offset .. offset + 1], .consumed = 1 };
        return .{ .bytes = switch (first) {
            '\n' => "\\n",
            '\r' => "\\r",
            '\t' => "\\t",
            else => std.fmt.bufPrint(storage, "\\x{x:0>2}", .{first}) catch unreachable,
        }, .consumed = 1 };
    }

    const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch
        return .{
            .bytes = std.fmt.bufPrint(storage, "\\x{x:0>2}", .{first}) catch unreachable,
            .consumed = 1,
        };
    if (sequence_len > bytes.len - offset) return .{
        .bytes = std.fmt.bufPrint(storage, "\\x{x:0>2}", .{first}) catch unreachable,
        .consumed = 1,
    };
    const scalar = decode(bytes[offset..], sequence_len) catch return .{
        .bytes = std.fmt.bufPrint(storage, "\\x{x:0>2}", .{first}) catch unreachable,
        .consumed = 1,
    };
    if (text.Utf8.isTerminalUnsafeScalar(scalar)) return .{
        .bytes = std.fmt.bufPrint(storage, "\\u{{{x}}}", .{scalar}) catch unreachable,
        .consumed = sequence_len,
    };
    return .{
        .bytes = bytes[offset .. offset + sequence_len],
        .consumed = sequence_len,
    };
}

fn decode(bytes: []const u8, sequence_len: u3) !u21 {
    return switch (sequence_len) {
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}

test "preserves ordinary UTF-8 and escapes terminal controls and invalid bytes" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(
        &output.writer,
        "Привет 😀 \u{9b}\u{061c}\u{200b}\u{2028}\u{202e}" ++
            "\u{2060}\u{2067}\u{feff}\x9b\x1b\n",
    );
    try std.testing.expectEqualStrings(
        "Привет 😀 \\u{9b}\\u{61c}\\u{200b}\\u{2028}\\u{202e}\\u{2060}\\u{2067}\\u{feff}\\x9b\\x1b\\n",
        output.written(),
    );
}

test "exact escaped fit is not clipped" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(!try writeBounded(&output.writer, "a\nx", 4));
    try std.testing.expectEqualStrings("a\\nx", output.written());
}

test "bounded output reserves a visible clipping marker" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try std.testing.expect(try writeBounded(&output.writer, "abcde", 4));
    try std.testing.expectEqualStrings("a...", output.written());
}

test "escapes every byte of an invalid UTF-8 sequence" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(&output.writer, "x\xf0\x80y");
    try std.testing.expectEqualStrings("x\\xf0\\x80y", output.written());
}
