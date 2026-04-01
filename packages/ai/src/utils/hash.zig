const std = @import("std");

/// Fast deterministic hash to shorten long strings.
/// Port of the MurmurHash-like algorithm from TypeScript.
/// Returns a 13-character base-36 encoded hash.
pub fn shortHash(str: []const u8) [13]u8 {
    // Initial seed values matching the TS implementation
    var h1: u32 = 0xdeadbeef;
    var h2: u32 = 0x41c6ce57;
    
    // Multipliers matching TS Math.imul constants
    const c1: u32 = 2654435761;
    const c2: u32 = 1597334677;
    
    // Mix each character into the hash
    for (str) |ch| {
        // h1 = Math.imul(h1 ^ ch, 2654435761)
        h1 = (h1 ^ ch) *% c1;
        // h2 = Math.imul(h2 ^ ch, 1597334677)
        h2 = (h2 ^ ch) *% c2;
    }
    
    // Final mixing (avalanche)
    // h1 = Math.imul(h1 ^ (h1 >>> 16), 2246822507) ^ Math.imul(h2 ^ (h2 >>> 13), 3266489909)
    const mix1: u32 = 2246822507;
    const mix2: u32 = 3266489909;
    
    h1 = ((h1 ^ (h1 >> 16)) *% mix1) ^ ((h2 ^ (h2 >> 13)) *% mix2);
    
    // h2 = Math.imul(h2 ^ (h2 >>> 16), 2246822507) ^ Math.imul(h1 ^ (h1 >>> 13), 3266489909)
    h2 = ((h2 ^ (h2 >> 16)) *% mix1) ^ ((h1 ^ (h1 >> 13)) *% mix2);
    
    // Convert to base-36: (h2 >>> 0).toString(36) + (h1 >>> 0).toString(36)
    // In Zig: h2 first (as unsigned), then h1
    var result: [13]u8 = undefined;
    
    // Clear and write base-36 representation
    @memset(&result, 0);
    
    var buf_idx: usize = 0;
    var temp_buf: [16]u8 = undefined;
    
    // Convert h2 to base-36
    var h2_val = h2;
    if (h2_val == 0) {
        temp_buf[0] = '0';
        buf_idx = 1;
    } else {
        buf_idx = 0;
        while (h2_val > 0) : (h2_val /= 36) {
            const digit = h2_val % 36;
            temp_buf[buf_idx] = if (digit < 10) '0' + @as(u8, @intCast(digit)) else 'a' + @as(u8, @intCast(digit - 10));
            buf_idx += 1;
        }
    }
    
    // Reverse h2 digits into result
    var result_idx: usize = 0;
    var i: usize = buf_idx;
    while (i > 0) : (i -= 1) {
        result[result_idx] = temp_buf[i - 1];
        result_idx += 1;
    }
    
    // Convert h1 to base-36
    var h1_val = h1;
    if (h1_val == 0) {
        temp_buf[0] = '0';
        buf_idx = 1;
    } else {
        buf_idx = 0;
        while (h1_val > 0) : (h1_val /= 36) {
            const digit = h1_val % 36;
            temp_buf[buf_idx] = if (digit < 10) '0' + @as(u8, @intCast(digit)) else 'a' + @as(u8, @intCast(digit - 10));
            buf_idx += 1;
        }
    }
    
    // Reverse h1 digits into result
    i = buf_idx;
    while (i > 0) : (i -= 1) {
        result[result_idx] = temp_buf[i - 1];
        result_idx += 1;
    }
    
    // Pad remaining with zeros if needed
    while (result_idx < 13) : (result_idx += 1) {
        result[result_idx] = 0;
    }
    
    return result;
}
