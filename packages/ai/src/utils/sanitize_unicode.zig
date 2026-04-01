const std = @import("std");

/// Removes invalid UTF-8 sequences from text.
///
/// In Zig, strings are UTF-8 by convention. This function scans for invalid
/// UTF-8 byte sequences and removes them, returning a clean UTF-8 string.
///
/// This is the Zig equivalent of the TypeScript `sanitizeSurrogates()` which
/// removes unpaired UTF-16 surrogates. Since Zig uses UTF-8, we remove invalid
/// byte sequences instead.
///
/// Valid multi-byte UTF-8 sequences are preserved. Only truly invalid sequences
/// are removed.
pub fn sanitizeSurrogates(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    if (text.len == 0) {
        return try allocator.dupe(u8, "");
    }
    
    // First pass: determine valid UTF-8 sequences
    // We build a new string with only valid UTF-8
    var result = std.ArrayList(u8).init(allocator);
    errdefer result.deinit();
    
    var i: usize = 0;
    while (i < text.len) {
        const remaining = text.len - i;
        const first_byte = text[i];
        
        // Single-byte ASCII (0x00-0x7F)
        if (first_byte <= 0x7F) {
            try result.append(first_byte);
            i += 1;
            continue;
        }
        
        // 2-byte sequence (0xC2-0xDF followed by 0x80-0xBF)
        if (first_byte >= 0xC2 and first_byte <= 0xDF) {
            if (remaining >= 2 and isContinuationByte(text[i + 1])) {
                try result.append(first_byte);
                try result.append(text[i + 1]);
                i += 2;
            } else {
                // Invalid sequence, skip
                i += 1;
            }
            continue;
        }
        
        // 3-byte sequence
        if (first_byte >= 0xE0 and first_byte <= 0xEF) {
            if (remaining >= 3 and 
                isContinuationByte(text[i + 1]) and 
                isContinuationByte(text[i + 2])) {
                // Check for overlong encodings and invalid surrogates
                const valid = switch (first_byte) {
                    0xE0 => text[i + 1] >= 0xA0, // overlong check
                    0xED => text[i + 1] <= 0x9F, // surrogate half check
                    else => true,
                };
                if (valid) {
                    try result.append(first_byte);
                    try result.append(text[i + 1]);
                    try result.append(text[i + 2]);
                    i += 3;
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
            continue;
        }
        
        // 4-byte sequence
        if (first_byte >= 0xF0 and first_byte <= 0xF4) {
            if (remaining >= 4 and 
                isContinuationByte(text[i + 1]) and 
                isContinuationByte(text[i + 2]) and 
                isContinuationByte(text[i + 3])) {
                // Check for overlong and out-of-range
                const valid = switch (first_byte) {
                    0xF0 => text[i + 1] >= 0x90, // overlong check
                    0xF4 => text[i + 1] <= 0x8F, // > U+10FFFF check
                    else => true,
                };
                if (valid) {
                    try result.append(first_byte);
                    try result.append(text[i + 1]);
                    try result.append(text[i + 2]);
                    try result.append(text[i + 3]);
                    i += 4;
                } else {
                    i += 1;
                }
            } else {
                i += 1;
            }
            continue;
        }
        
        // Invalid leading byte, skip
        i += 1;
    }
    
    return result.toOwnedSlice();
}

/// Check if a byte is a valid UTF-8 continuation byte (0x80-0xBF).
fn isContinuationByte(b: u8) bool {
    return b >= 0x80 and b <= 0xBF;
}
