// Shim over zi's terminal_render.Text for the fx presentation leaf modules.
// Ported from vercel-labs/fx src/core/shared/display_width.zig at commit 5ed3be1.
// Only the functions the ported files use are exposed here; terminal_render
// owns grapheme segmentation and display width via uucode.
// Licensed under Apache-2.0 and adapted for Zi.
const std = @import("std");
const Text = @import("../../terminal_render/root.zig").Text;

/// Skips ANSI escape sequences while measuring styled text. terminal_render has no
/// equivalent of this function, so it is implemented here minimally: escape
/// sequences run from ESC (0x1b) through a terminating byte in 0x40..0x7e,
/// with CSI private-marker bytes skipped conservatively.
pub fn visibleWidthIgnoringAnsi(text: []const u8) usize {
    var width: usize = 0;
    var span_start: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            width +|= Text.displayWidth(text[span_start..i]);
            i = ansiSequenceEnd(text, i);
            span_start = i;
            continue;
        }
        i += 1;
    }
    width +|= Text.displayWidth(text[span_start..]);
    return width;
}

fn ansiSequenceEnd(text: []const u8, start: usize) usize {
    var i = start + 1;
    if (i >= text.len) return i;
    switch (text[i]) {
        // CSI: parameter and intermediate bytes, then a final byte 0x40..0x7e.
        '[' => {
            i += 1;
            while (i < text.len and text[i] >= 0x20 and text[i] <= 0x3f) : (i += 1) {}
            if (i < text.len) i += 1;
            return i;
        },
        // OSC: terminated by BEL or ST (ESC \).
        ']' => {
            i += 1;
            while (i < text.len and text[i] != 0x07) : (i += 1) {
                if (text[i] == 0x1b and i + 1 < text.len and text[i + 1] == '\\') return i + 2;
            }
            return @min(i + 1, text.len);
        },
        // Two-byte escape such as ESC ( B.
        else => return @min(start + 2, text.len),
    }
}

test "visibleWidthIgnoringAnsi skips escapes" {
    try std.testing.expectEqual(@as(usize, 5), visibleWidthIgnoringAnsi("\x1b[1mhello\x1b[22m"));
}
