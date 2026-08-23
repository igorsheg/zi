const std = @import("std");

pub fn write(writer: *std.Io.Writer, text: []const u8, allow_newlines: bool) std.Io.Writer.Error!void {
    if (!std.unicode.utf8ValidateSlice(text)) {
        for (text) |byte| {
            if (byte >= 0x20 and byte < 0x7f) {
                try writer.writeByte(byte);
            } else if (allow_newlines and byte == '\n') {
                try writer.writeByte('\n');
            } else if (byte == '\t') {
                try writer.writeByte('\t');
            } else {
                try writer.writeAll("�");
            }
        }
        return;
    }

    var iterator = std.unicode.Utf8View.initUnchecked(text).iterator();
    while (iterator.peek(1).len != 0) {
        const scalar_start = iterator.i;
        const scalar = iterator.nextCodepoint().?;
        const codepoint = text[scalar_start..iterator.i];
        if (allow_newlines and scalar == '\n') {
            try writer.writeByte('\n');
        } else if (scalar == '\t') {
            try writer.writeByte('\t');
        } else if (scalar < 0x20 or (scalar >= 0x7f and scalar <= 0x9f)) {
            try writer.writeAll("�");
        } else {
            try writer.writeAll(codepoint);
        }
    }
}

test "safe text replaces terminal controls and malformed UTF-8" {
    var output: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output.deinit();

    try write(&output.writer, "safe\x1b[2J\rtext\u{009b}tail\x9b", true);
    try std.testing.expectEqualStrings("safe�[2J�text��tail�", output.written());
}
