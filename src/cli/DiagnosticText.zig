const std = @import("std");
const text = @import("../text/root.zig");

/// Writes untrusted text without allowing terminal control characters or invalid UTF-8.
pub fn write(writer: *std.Io.Writer, bytes: []const u8) std.Io.Writer.Error!void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const first = bytes[offset];
        if (first < 0x80) {
            if (first >= 0x20 and first != 0x7f) {
                try writer.writeByte(first);
            } else switch (first) {
                '\n' => try writer.writeAll("\\n"),
                '\r' => try writer.writeAll("\\r"),
                '\t' => try writer.writeAll("\\t"),
                else => try writer.print("\\x{x:0>2}", .{first}),
            }
            offset += 1;
            continue;
        }

        const sequence_len = std.unicode.utf8ByteSequenceLength(first) catch {
            try writeInvalidByte(writer, first);
            offset += 1;
            continue;
        };
        if (sequence_len > bytes.len - offset) {
            try writeInvalidByte(writer, first);
            offset += 1;
            continue;
        }
        const scalar = decode(bytes[offset..], sequence_len) catch {
            try writeInvalidByte(writer, first);
            offset += 1;
            continue;
        };
        if (text.Utf8.isTerminalUnsafeScalar(scalar)) {
            try writer.print("\\u{{{x}}}", .{scalar});
        } else {
            try writer.writeAll(bytes[offset .. offset + sequence_len]);
        }
        offset += sequence_len;
    }
}

fn decode(bytes: []const u8, sequence_len: u3) !u21 {
    return switch (sequence_len) {
        2 => std.unicode.utf8Decode2(bytes[0..2].*),
        3 => std.unicode.utf8Decode3(bytes[0..3].*),
        4 => std.unicode.utf8Decode4(bytes[0..4].*),
        else => unreachable,
    };
}

fn writeInvalidByte(writer: *std.Io.Writer, byte: u8) std.Io.Writer.Error!void {
    try writer.print("\\x{x:0>2}", .{byte});
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

test "escapes every byte of an invalid UTF-8 sequence" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();
    try write(&output.writer, "x\xf0\x80y");
    try std.testing.expectEqualStrings("x\\xf0\\x80y", output.written());
}
