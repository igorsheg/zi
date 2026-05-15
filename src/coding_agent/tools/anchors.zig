const std = @import("std");

pub const HASH_HEX_LEN: usize = 4;

pub const Anchor = struct {
    line: usize,
    hash: u16,
};

pub fn hashLine(line: []const u8) u16 {
    var h = std.hash.Wyhash.init(0x7a695f6c696e655f);
    h.update(line);
    return @truncate(h.final());
}

pub fn format(allocator: std.mem.Allocator, anchor: Anchor) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d}:{x:0>4}", .{ anchor.line, anchor.hash });
}

pub fn write(writer: *std.Io.Writer, line: usize, text: []const u8) !void {
    try writer.print("{d}:{x:0>4}:", .{ line, hashLine(text) });
}

pub fn parse(s: []const u8) !Anchor {
    const colon = std.mem.indexOfScalar(u8, s, ':') orelse return error.InvalidAnchor;
    if (colon == 0 or colon + 1 >= s.len) return error.InvalidAnchor;
    const line = try std.fmt.parseUnsigned(usize, s[0..colon], 10);
    const hash = try std.fmt.parseUnsigned(u16, s[colon + 1 ..], 16);
    if (line == 0) return error.InvalidAnchor;
    return .{ .line = line, .hash = hash };
}

pub const LineSpan = struct { start: usize, end: usize, next: usize };

pub fn lineSpanAt(content: []const u8, line_no: usize) ?LineSpan {
    if (line_no == 0) return null;
    var cur: usize = 1;
    var start: usize = 0;
    while (true) {
        const rel = std.mem.indexOfScalar(u8, content[start..], '\n');
        const end = if (rel) |r| start + r else content.len;
        const next = if (rel) |_| end + 1 else content.len;
        if (cur == line_no) return .{ .start = start, .end = end, .next = next };
        if (rel == null) return null;
        start = next;
        cur += 1;
    }
}

pub fn resolve(content: []const u8, anchor: Anchor) !LineSpan {
    const span = lineSpanAt(content, anchor.line) orelse return error.LineOutOfRange;
    if (hashLine(content[span.start..span.end]) != anchor.hash) return error.StaleAnchor;
    return span;
}

pub fn findCandidates(allocator: std.mem.Allocator, content: []const u8, wanted_hash: u16, max: usize) ![]Anchor {
    var out: std.ArrayList(Anchor) = .empty;
    errdefer out.deinit(allocator);
    var line_no: usize = 1;
    var start: usize = 0;
    while (true) {
        const rel = std.mem.indexOfScalar(u8, content[start..], '\n');
        const end = if (rel) |r| start + r else content.len;
        if (hashLine(content[start..end]) == wanted_hash) {
            try out.append(allocator, .{ .line = line_no, .hash = wanted_hash });
            if (out.items.len >= max) break;
        }
        if (rel == null) break;
        start = end + 1;
        line_no += 1;
    }
    return out.toOwnedSlice(allocator);
}

test "parse and resolve anchor" {
    const a = try parse("2:0000");
    try std.testing.expectEqual(@as(usize, 2), a.line);
    const h = hashLine("b");
    const span = try resolve("a\nb\n", .{ .line = 2, .hash = h });
    try std.testing.expectEqualStrings("b", "a\nb\n"[span.start..span.end]);
}
