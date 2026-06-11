const std = @import("std");

pub const tool_tail_preview_bytes_max: usize = 50 * 1024;
pub const tool_tail_preview_lines_max: usize = 2000;

pub const TailAppendResult = struct {
    bytes: []u8,
    dropped_bytes: usize,
    dropped_lines: usize,
    last_line_partial: bool = false,
};

pub const TailOptions = struct {
    max_bytes: usize = tool_tail_preview_bytes_max,
    max_lines: usize = tool_tail_preview_lines_max,
};

const TailWindow = struct {
    start: usize,
    end: usize,
    last_line_partial: bool = false,
};

pub fn appendTail(
    allocator: std.mem.Allocator,
    old: []const u8,
    delta: []const u8,
) !TailAppendResult {
    return appendTailWithOptions(allocator, old, delta, .{});
}

pub fn appendTailWithOptions(
    allocator: std.mem.Allocator,
    old: []const u8,
    delta: []const u8,
    options: TailOptions,
) !TailAppendResult {
    const combined_len = old.len + delta.len;
    const combined = try allocator.alloc(u8, combined_len);
    defer allocator.free(combined);
    @memcpy(combined[0..old.len], old);
    @memcpy(combined[old.len..], delta);

    const window = tailWindow(combined, options.max_bytes, options.max_lines);
    const bytes = try allocator.dupe(u8, combined[window.start..window.end]);
    return .{
        .bytes = bytes,
        .dropped_bytes = window.start,
        .dropped_lines = countLines(combined[0..window.start]),
        .last_line_partial = window.last_line_partial,
    };
}

// Mirrors pi-mono truncateTail(): keep complete trailing lines under both
// limits. The only partial-line case is a single huge final line, where the
// UTF-8-safe suffix is more useful than an empty preview.
fn tailWindow(bytes: []const u8, max_bytes: usize, max_lines: usize) TailWindow {
    if (bytes.len == 0 or max_bytes == 0 or max_lines == 0) return .{ .start = bytes.len, .end = bytes.len };
    const total_lines = countLines(bytes);
    if (total_lines <= max_lines and bytes.len <= max_bytes) return .{ .start = 0, .end = bytes.len };

    var end = bytes.len;
    if (end > 0 and bytes[end - 1] == '\n') end -= 1;

    var output_lines: usize = 0;
    var output_bytes: usize = 0;
    var start = end;
    while (end > 0 and output_lines < max_lines) {
        var line_start = end;
        while (line_start > 0 and bytes[line_start - 1] != '\n') line_start -= 1;
        const line_bytes = end - line_start;
        const separator_bytes: usize = if (output_lines > 0) 1 else 0;
        if (output_bytes + separator_bytes + line_bytes > max_bytes) {
            if (output_lines == 0) {
                return .{
                    .start = utf8SuffixStart(bytes[0..end], max_bytes),
                    .end = end,
                    .last_line_partial = true,
                };
            }
            break;
        }
        start = line_start;
        output_bytes += separator_bytes + line_bytes;
        output_lines += 1;
        if (line_start == 0) break;
        end = line_start - 1;
    }
    return .{ .start = start, .end = if (bytes.len > 0 and bytes[bytes.len - 1] == '\n') bytes.len - 1 else bytes.len };
}

fn utf8SuffixStart(bytes: []const u8, max_bytes: usize) usize {
    if (bytes.len <= max_bytes) return 0;
    var start = bytes.len - max_bytes;
    while (start < bytes.len and (bytes[start] & 0xc0) == 0x80) : (start += 1) {}
    return start;
}

fn countLines(bytes: []const u8) usize {
    if (bytes.len == 0) return 0;
    var count: usize = 1;
    for (bytes) |byte| {
        if (byte == '\n') count += 1;
    }
    if (bytes[bytes.len - 1] == '\n') count -= 1;
    return count;
}
