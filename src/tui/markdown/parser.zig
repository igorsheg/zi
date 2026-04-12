const std = @import("std");
const ast = @import("ast.zig");

pub fn parseDocument(source: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.Document {
    const lines = try splitLines(source, arena);
    return .{ .blocks = try parseBlocks(lines, arena) };
}

fn splitLines(source: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
    var lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer lines.deinit(arena);

    var start: usize = 0;
    while (start <= source.len) {
        if (start == source.len) break;
        const rest = source[start..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const end = if (nl) |idx| start + idx else source.len;
        var line = source[start..end];
        if (line.len > 0 and line[line.len - 1] == '\r') {
            line = line[0 .. line.len - 1];
        }
        try lines.append(arena, line);
        if (nl == null) break;
        start = end + 1;
    }

    return try lines.toOwnedSlice(arena);
}

fn parseBlocks(lines: []const []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const ast.BlockNode {
    var blocks: std.ArrayListUnmanaged(ast.BlockNode) = .empty;
    errdefer blocks.deinit(arena);

    var i: usize = 0;
    var skipped_blank = false;
    while (i < lines.len) {
        while (i < lines.len and isBlankLine(lines[i])) : (i += 1) {
            skipped_blank = true;
        }
        if (i >= lines.len) break;

        var block = try parseNextBlock(lines, &i, arena);
        block.separated = skipped_blank and blocks.items.len > 0;
        try blocks.append(arena, block);
        skipped_blank = false;
    }

    return try blocks.toOwnedSlice(arena);
}

fn parseNextBlock(lines: []const []const u8, index: *usize, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.BlockNode {
    const line = lines[index.*];

    if (detectFenceStart(line)) |fence| {
        return .{ .block = .{ .code_block = try parseCodeBlock(lines, index, fence, arena) } };
    }
    if (detectHeading(line)) |heading| {
        index.* += 1;
        return .{ .block = .{ .heading = .{
            .level = heading.level,
            .inlines = try parseInlines(heading.content, arena),
        } } };
    }
    if (isThematicBreak(line)) {
        index.* += 1;
        return .{ .block = .thematic_break };
    }
    if (canStartTable(lines, index.*)) {
        return .{ .block = .{ .table = try parseTable(lines, index, arena) } };
    }
    if (detectBlockquoteMarker(line)) |_| {
        return .{ .block = .{ .quote = try parseQuote(lines, index, arena) } };
    }
    if (detectListMarker(line)) |_| {
        return .{ .block = .{ .list = try parseList(lines, index, arena) } };
    }
    return .{ .block = .{ .paragraph = try parseParagraph(lines, index, arena) } };
}

const HeadingMatch = struct {
    level: u8,
    content: []const u8,
};

fn detectHeading(line: []const u8) ?HeadingMatch {
    const trimmed = trimLeftSpaces(line);
    if (trimmed.len == 0 or trimmed[0] != '#') return null;

    var level: u8 = 0;
    var pos: usize = 0;
    while (pos < trimmed.len and trimmed[pos] == '#' and level < 6) : (pos += 1) {
        level += 1;
    }
    if (level == 0 or pos >= trimmed.len or trimmed[pos] != ' ') return null;
    return .{
        .level = level,
        .content = std.mem.trimRight(u8, trimmed[pos + 1 ..], " \t"),
    };
}

const FenceStart = struct {
    indent_cols: usize,
    info: []const u8,
};

fn detectFenceStart(line: []const u8) ?FenceStart {
    const indent_cols = leadingIndentCols(line);
    if (indent_cols > 3) return null;
    const trimmed = trimLeftSpaces(line);
    if (!std.mem.startsWith(u8, trimmed, "```")) return null;
    return .{
        .indent_cols = indent_cols,
        .info = std.mem.trim(u8, trimmed[3..], " \t"),
    };
}

fn parseCodeBlock(lines: []const []const u8, index: *usize, fence: FenceStart, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.CodeBlock {
    _ = fence.indent_cols;
    index.* += 1;

    var code_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer code_lines.deinit(arena);

    while (index.* < lines.len) {
        const line = lines[index.*];
        const trimmed = trimLeftSpaces(line);
        if (std.mem.startsWith(u8, trimmed, "```")) {
            index.* += 1;
            break;
        }
        try code_lines.append(arena, line);
        index.* += 1;
    }

    return .{
        .info = fence.info,
        .lines = try code_lines.toOwnedSlice(arena),
    };
}

fn parseParagraph(lines: []const []const u8, index: *usize, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.Paragraph {
    var paragraph_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer paragraph_lines.deinit(arena);

    while (index.* < lines.len) {
        const line = lines[index.*];
        if (isBlankLine(line)) break;

        if (paragraph_lines.items.len > 0 and startsNewBlock(lines, index.*)) break;

        try paragraph_lines.append(arena, line);
        index.* += 1;
    }

    const combined = try combineParagraphLines(paragraph_lines.items, arena);
    return .{ .inlines = try parseInlines(combined, arena) };
}

fn combineParagraphLines(lines: []const []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);

    for (lines, 0..) |line, idx| {
        var piece = line;
        if (idx > 0) {
            const prev = lines[idx - 1];
            const prev_trimmed_len = trimRightSpaces(prev);
            const prev_trimmed = prev[0..prev_trimmed_len];
            if (endsWithHardBreak(prev)) {
                if (prev_trimmed.len > 0 and prev_trimmed[prev_trimmed.len - 1] == '\\') {
                    // previous iteration already emitted the raw text, so trim the backslash now
                    if (out.items.len > 0) out.items.len -= 1;
                }
                try out.append(arena, '\n');
                piece = trimLeftSpaces(line);
            } else {
                try out.append(arena, ' ');
                piece = trimLeftSpaces(line);
            }
        }
        try out.appendSlice(arena, piece);
    }

    return try out.toOwnedSlice(arena);
}

fn endsWithHardBreak(line: []const u8) bool {
    const trimmed_len = trimRightSpaces(line);
    if (trimmed_len == 0) return false;
    if (trimmed_len + 2 <= line.len) return true;
    return line[trimmed_len - 1] == '\\';
}

fn startsNewBlock(lines: []const []const u8, idx: usize) bool {
    const line = lines[idx];
    if (detectFenceStart(line) != null) return true;
    if (detectHeading(line) != null) return true;
    if (isThematicBreak(line)) return true;
    if (detectBlockquoteMarker(line) != null) return true;
    if (detectListMarker(line) != null) return true;
    if (canStartTable(lines, idx)) return true;
    return false;
}

const QuoteMarker = struct {
    content: []const u8,
};

fn detectBlockquoteMarker(line: []const u8) ?QuoteMarker {
    var pos: usize = 0;
    var spaces: usize = 0;
    while (pos < line.len and spaces < 4 and line[pos] == ' ') : (pos += 1) {
        spaces += 1;
    }
    if (pos >= line.len or line[pos] != '>') return null;
    pos += 1;
    if (pos < line.len and line[pos] == ' ') pos += 1;
    return .{ .content = line[pos..] };
}

fn parseQuote(lines: []const []const u8, index: *usize, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.Quote {
    var quote_lines: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer quote_lines.deinit(arena);

    var saw_explicit = false;
    while (index.* < lines.len) {
        const line = lines[index.*];
        if (detectBlockquoteMarker(line)) |marker| {
            try quote_lines.append(arena, marker.content);
            index.* += 1;
            saw_explicit = true;
            continue;
        }
        if (saw_explicit and !isBlankLine(line) and !startsNewBlock(lines, index.*)) {
            try quote_lines.append(arena, line);
            index.* += 1;
            continue;
        }
        break;
    }

    return .{ .blocks = try parseBlocks(quote_lines.items, arena) };
}

const ListMarker = struct {
    indent_cols: usize,
    ordered: bool,
    start_number: usize,
    marker_end: usize,
    bullet_text: []const u8,
    content: []const u8,
    content_indent_cols: usize,
};

fn detectListMarker(line: []const u8) ?ListMarker {
    var pos: usize = 0;
    while (pos < line.len and line[pos] == ' ') : (pos += 1) {}
    const indent_cols = pos;
    if (pos >= line.len) return null;

    if ((line[pos] == '-' or line[pos] == '*' or line[pos] == '+') and pos + 1 < line.len and line[pos + 1] == ' ') {
        const marker_end = pos + 2;
        return .{
            .indent_cols = indent_cols,
            .ordered = false,
            .start_number = 1,
            .marker_end = marker_end,
            .bullet_text = line[pos..marker_end],
            .content = line[marker_end..],
            .content_indent_cols = indent_cols + 2,
        };
    }

    const digit_start = pos;
    while (pos < line.len and std.ascii.isDigit(line[pos])) : (pos += 1) {}
    if (pos == digit_start) return null;
    if (pos + 1 >= line.len) return null;
    if ((line[pos] != '.' and line[pos] != ')') or line[pos + 1] != ' ') return null;

    const start_number = std.fmt.parseInt(usize, line[digit_start..pos], 10) catch return null;
    const marker_end = pos + 2;
    return .{
        .indent_cols = indent_cols,
        .ordered = true,
        .start_number = start_number,
        .marker_end = marker_end,
        .bullet_text = line[digit_start..marker_end],
        .content = line[marker_end..],
        .content_indent_cols = indent_cols + marker_end - digit_start,
    };
}

fn parseList(lines: []const []const u8, index: *usize, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.List {
    const first = detectListMarker(lines[index.*]).?;

    var items: std.ArrayListUnmanaged(ast.ListItem) = .empty;
    errdefer items.deinit(arena);

    while (index.* < lines.len) {
        const marker = detectListMarker(lines[index.*]) orelse break;
        if (marker.indent_cols != first.indent_cols or marker.ordered != first.ordered) break;
        try items.append(arena, try parseListItem(lines, index, marker, arena));

        const blank_start = index.*;
        while (index.* < lines.len and isBlankLine(lines[index.*])) : (index.* += 1) {}
        if (index.* >= lines.len) break;
        const next_marker = detectListMarker(lines[index.*]) orelse {
            index.* = blank_start;
            break;
        };
        if (next_marker.indent_cols != first.indent_cols or next_marker.ordered != first.ordered) {
            index.* = blank_start;
            break;
        }
    }

    return .{
        .ordered = first.ordered,
        .start = first.start_number,
        .items = try items.toOwnedSlice(arena),
    };
}

fn parseListItem(lines: []const []const u8, index: *usize, marker: ListMarker, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.ListItem {
    var normalized: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer normalized.deinit(arena);

    try normalized.append(arena, marker.content);
    index.* += 1;

    while (index.* < lines.len) {
        const line = lines[index.*];
        if (isBlankLine(line)) {
            const next_nonblank = findNextNonblank(lines, index.* + 1);
            if (next_nonblank) |next_idx| {
                const next_indent = leadingIndentCols(lines[next_idx]);
                if (next_indent >= marker.content_indent_cols) {
                    try normalized.append(arena, "");
                    index.* += 1;
                    continue;
                }
            }
            break;
        }

        if (detectListMarker(line)) |next_marker| {
            if (next_marker.indent_cols == marker.indent_cols and next_marker.ordered == marker.ordered) {
                break;
            }
        }

        const indent_cols = leadingIndentCols(line);
        if (indent_cols >= marker.content_indent_cols) {
            try normalized.append(arena, removeIndent(line, marker.content_indent_cols));
            index.* += 1;
            continue;
        }
        break;
    }

    return .{ .blocks = try parseBlocks(normalized.items, arena) };
}

fn findNextNonblank(lines: []const []const u8, start: usize) ?usize {
    var idx = start;
    while (idx < lines.len) : (idx += 1) {
        if (!isBlankLine(lines[idx])) return idx;
    }
    return null;
}

fn canStartTable(lines: []const []const u8, idx: usize) bool {
    if (idx + 1 >= lines.len) return false;
    if (!looksLikeTableRow(lines[idx])) return false;
    return isAlignmentRow(lines[idx + 1]);
}

fn looksLikeTableRow(line: []const u8) bool {
    return std.mem.indexOfScalar(u8, line, '|') != null;
}

fn parseTable(lines: []const []const u8, index: *usize, arena: std.mem.Allocator) std.mem.Allocator.Error!ast.Table {
    const header_cells_raw = try splitTableRow(lines[index.*], arena);
    const alignments = (try parseAlignmentRow(lines[index.* + 1], arena)).?;

    var header_cells: std.ArrayListUnmanaged(ast.TableCell) = .empty;
    errdefer header_cells.deinit(arena);
    for (header_cells_raw, 0..) |cell, col| {
        if (col >= alignments.len) break;
        try header_cells.append(arena, .{ .inlines = try parseInlines(cell, arena) });
    }

    var rows: std.ArrayListUnmanaged(ast.TableRow) = .empty;
    errdefer rows.deinit(arena);

    index.* += 2;
    while (index.* < lines.len) {
        const line = lines[index.*];
        if (isBlankLine(line) or !looksLikeTableRow(line)) break;

        const cells_raw = try splitTableRow(line, arena);
        var cells: std.ArrayListUnmanaged(ast.TableCell) = .empty;
        errdefer cells.deinit(arena);

        for (0..alignments.len) |col| {
            const cell_text = if (col < cells_raw.len) cells_raw[col] else "";
            try cells.append(arena, .{ .inlines = try parseInlines(cell_text, arena) });
        }

        try rows.append(arena, .{ .cells = try cells.toOwnedSlice(arena) });
        index.* += 1;
    }

    return .{
        .alignments = alignments,
        .header = try header_cells.toOwnedSlice(arena),
        .rows = try rows.toOwnedSlice(arena),
    };
}

fn isAlignmentRow(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0 or std.mem.indexOfScalar(u8, trimmed, '|') == null) return false;

    var working = trimmed;
    if (working[0] == '|') working = working[1..];
    if (working.len > 0 and working[working.len - 1] == '|') working = working[0 .. working.len - 1];
    if (working.len == 0) return false;

    var start: usize = 0;
    var saw_cell = false;
    var pos: usize = 0;
    while (pos <= working.len) : (pos += 1) {
        if (pos == working.len or working[pos] == '|') {
            const cell = std.mem.trim(u8, working[start..pos], " \t");
            if (!isAlignmentCell(cell)) return false;
            saw_cell = true;
            start = pos + 1;
        }
    }
    return saw_cell;
}

fn isAlignmentCell(cell: []const u8) bool {
    if (cell.len < 3) return false;
    const left = cell[0] == ':';
    const right = cell[cell.len - 1] == ':';
    const core = cell[@intFromBool(left) .. cell.len - @intFromBool(right)];
    if (core.len == 0) return false;
    for (core) |c| {
        if (c != '-') return false;
    }
    return true;
}

fn parseAlignmentRow(line: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error!?[]const ast.Alignment {
    const cells = try splitTableRow(line, arena);
    if (cells.len == 0) return null;

    var alignments: std.ArrayListUnmanaged(ast.Alignment) = .empty;
    errdefer alignments.deinit(arena);

    for (cells) |cell| {
        const trimmed = std.mem.trim(u8, cell, " \t");
        if (!isAlignmentCell(trimmed)) return null;

        const left = trimmed[0] == ':';
        const right = trimmed[trimmed.len - 1] == ':';
        try alignments.append(arena, if (left and right)
            .center
        else if (left)
            .left
        else if (right)
            .right
        else
            .none);
    }

    return try alignments.toOwnedSlice(arena);
}

fn splitTableRow(line: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const []const u8 {
    var trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len == 0) return &.{};
    if (trimmed[0] == '|') trimmed = trimmed[1..];
    if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '|') trimmed = trimmed[0 .. trimmed.len - 1];

    var cells: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer cells.deinit(arena);

    var start: usize = 0;
    var pos: usize = 0;
    var in_code = false;
    while (pos <= trimmed.len) : (pos += 1) {
        if (pos == trimmed.len or (!in_code and trimmed[pos] == '|')) {
            try cells.append(arena, std.mem.trim(u8, trimmed[start..pos], " \t"));
            start = pos + 1;
            continue;
        }
        if (trimmed[pos] == '`') in_code = !in_code;
        if (trimmed[pos] == '\\' and pos + 1 < trimmed.len) pos += 1;
    }

    return try cells.toOwnedSlice(arena);
}

fn isThematicBreak(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    if (trimmed.len < 3) return false;
    const ch = trimmed[0];
    if (ch != '-' and ch != '*' and ch != '_') return false;

    var count: usize = 0;
    for (trimmed) |c| {
        if (c == ch) {
            count += 1;
        } else if (c != ' ' and c != '\t') {
            return false;
        }
    }
    return count >= 3;
}

fn parseInlines(source: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const ast.Inline {
    var parser = InlineParser{
        .source = source,
        .arena = arena,
    };
    return parser.parse();
}

const InlineParser = struct {
    source: []const u8,
    arena: std.mem.Allocator,
    pos: usize = 0,
    text_buf: std.ArrayListUnmanaged(u8) = .empty,
    nodes: std.ArrayListUnmanaged(ast.Inline) = .empty,

    fn parse(self: *InlineParser) std.mem.Allocator.Error![]const ast.Inline {
        errdefer self.text_buf.deinit(self.arena);
        errdefer self.nodes.deinit(self.arena);

        while (self.pos < self.source.len) {
            if (self.tryEscape()) continue;
            if (try self.tryCode()) continue;
            if (try self.tryLink()) continue;
            if (try self.tryDelimited("**", .strong)) continue;
            if (try self.tryDelimited("~~", .strikethrough)) continue;
            if (try self.tryDelimited("*", .emphasis)) continue;
            if (try self.tryDelimited("_", .emphasis)) continue;
            if (try self.tryAutolink()) continue;

            try self.text_buf.append(self.arena, self.source[self.pos]);
            self.pos += 1;
        }

        try self.flushText();
        return try self.nodes.toOwnedSlice(self.arena);
    }

    fn tryEscape(self: *InlineParser) bool {
        if (self.pos + 1 >= self.source.len) return false;
        if (self.source[self.pos] != '\\') return false;
        if (!isMarkdownSpecial(self.source[self.pos + 1])) return false;
        self.text_buf.append(self.arena, self.source[self.pos + 1]) catch return false;
        self.pos += 2;
        return true;
    }

    fn tryCode(self: *InlineParser) std.mem.Allocator.Error!bool {
        if (self.source[self.pos] != '`') return false;
        const close = findUnescaped(self.source, self.pos + 1, "`") orelse return false;
        try self.flushText();
        try self.nodes.append(self.arena, .{ .code = self.source[self.pos + 1 .. close] });
        self.pos = close + 1;
        return true;
    }

    fn tryLink(self: *InlineParser) std.mem.Allocator.Error!bool {
        if (self.source[self.pos] != '[') return false;
        const close_bracket = findMatchingBracket(self.source, self.pos, '[', ']') orelse return false;
        if (close_bracket + 1 >= self.source.len or self.source[close_bracket + 1] != '(') return false;
        const close_paren = findMatchingParen(self.source, close_bracket + 1) orelse return false;

        try self.flushText();
        const label_src = self.source[self.pos + 1 .. close_bracket];
        const href = std.mem.trim(u8, self.source[close_bracket + 2 .. close_paren], " \t");
        var nested = InlineParser{ .source = label_src, .arena = self.arena };
        const label = try nested.parse();
        try self.nodes.append(self.arena, .{ .link = .{
            .kind = .explicit,
            .label = label,
            .href = href,
        } });
        self.pos = close_paren + 1;
        return true;
    }

    const DelimitedKind = enum { strong, emphasis, strikethrough };

    fn tryDelimited(self: *InlineParser, delimiter: []const u8, kind: DelimitedKind) std.mem.Allocator.Error!bool {
        if (!std.mem.startsWith(u8, self.source[self.pos..], delimiter)) return false;
        const close = findUnescaped(self.source, self.pos + delimiter.len, delimiter) orelse return false;
        try self.flushText();
        const inner_src = self.source[self.pos + delimiter.len .. close];
        var nested = InlineParser{ .source = inner_src, .arena = self.arena };
        const inner = try nested.parse();
        const node: ast.Inline = switch (kind) {
            .strong => .{ .strong = inner },
            .emphasis => .{ .emphasis = inner },
            .strikethrough => .{ .strikethrough = inner },
        };
        try self.nodes.append(self.arena, node);
        self.pos = close + delimiter.len;
        return true;
    }

    fn tryAutolink(self: *InlineParser) std.mem.Allocator.Error!bool {
        if (scanUrl(self.source, self.pos)) |match| {
            try self.flushText();
            const label = try self.singleTextInline(match.text);
            try self.nodes.append(self.arena, .{ .link = .{
                .kind = .autolink_url,
                .label = label,
                .href = match.href,
            } });
            self.pos = match.end;
            return true;
        }
        if (scanEmail(self.source, self.pos)) |match| {
            try self.flushText();
            const label = try self.singleTextInline(match.text);
            const href = try std.fmt.allocPrint(self.arena, "mailto:{s}", .{match.text});
            try self.nodes.append(self.arena, .{ .link = .{
                .kind = .autolink_email,
                .label = label,
                .href = href,
            } });
            self.pos = match.end;
            return true;
        }
        return false;
    }

    fn singleTextInline(self: *InlineParser, text: []const u8) std.mem.Allocator.Error![]const ast.Inline {
        const result = try self.arena.alloc(ast.Inline, 1);
        result[0] = .{ .text = text };
        return result;
    }

    fn flushText(self: *InlineParser) std.mem.Allocator.Error!void {
        if (self.text_buf.items.len == 0) return;
        const text = try self.arena.dupe(u8, self.text_buf.items);
        try self.nodes.append(self.arena, .{ .text = text });
        self.text_buf.clearRetainingCapacity();
    }
};

const ScanMatch = struct {
    text: []const u8,
    href: []const u8,
    end: usize,
};

fn scanUrl(source: []const u8, start: usize) ?ScanMatch {
    const rest = source[start..];
    const prefix_len: usize = if (std.mem.startsWith(u8, rest, "https://")) 8 else if (std.mem.startsWith(u8, rest, "http://")) 7 else return null;
    _ = prefix_len;
    if (start > 0 and isAutolinkBoundary(source[start - 1])) return null;
    var end = start;
    while (end < source.len and !isUrlTerminator(source[end])) : (end += 1) {}
    end = trimAutolinkEnd(source, start, end);
    if (end <= start) return null;
    const text = source[start..end];
    return .{ .text = text, .href = text, .end = end };
}

fn scanEmail(source: []const u8, start: usize) ?ScanMatch {
    if (start > 0 and isAutolinkBoundary(source[start - 1])) return null;
    var at_pos: ?usize = null;
    var end = start;
    while (end < source.len and !isUrlTerminator(source[end])) : (end += 1) {
        if (source[end] == '@') at_pos = end;
    }
    const at = at_pos orelse return null;
    if (at == start or at + 1 >= end) return null;
    if (!looksLikeEmailLocal(source[start..at])) return null;
    if (!looksLikeEmailDomain(source[at + 1 .. end])) return null;

    const text = source[start..end];
    return .{ .text = text, .href = text, .end = end };
}

fn looksLikeEmailLocal(local: []const u8) bool {
    if (local.len == 0) return false;
    for (local) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '%' or c == '+' or c == '-')) return false;
    }
    return true;
}

fn looksLikeEmailDomain(domain: []const u8) bool {
    if (domain.len < 3) return false;
    var dot = false;
    for (domain) |c| {
        if (c == '.') {
            dot = true;
        } else if (!(std.ascii.isAlphanumeric(c) or c == '-')) {
            return false;
        }
    }
    return dot;
}

fn trimAutolinkEnd(source: []const u8, start: usize, end_inclusive: usize) usize {
    var end = end_inclusive;
    while (end > start) {
        const c = source[end - 1];
        if (c == '.' or c == ',' or c == ';' or c == '!' or c == '?') {
            end -= 1;
            continue;
        }
        if (c == ')' and countByte(source[start..end], '(') < countByte(source[start..end], ')')) {
            end -= 1;
            continue;
        }
        break;
    }
    return end;
}

fn countByte(text: []const u8, target: u8) usize {
    var count: usize = 0;
    for (text) |c| {
        if (c == target) count += 1;
    }
    return count;
}

fn isAutolinkBoundary(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '/' or c == ':';
}

fn isUrlTerminator(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '<' or c == '>' or c == '"';
}

fn findMatchingBracket(source: []const u8, open_pos: usize, open_ch: u8, close_ch: u8) ?usize {
    var depth: usize = 0;
    var pos = open_pos;
    while (pos < source.len) : (pos += 1) {
        if (source[pos] == '\\' and pos + 1 < source.len) {
            pos += 1;
            continue;
        }
        if (source[pos] == open_ch) {
            depth += 1;
        } else if (source[pos] == close_ch) {
            depth -= 1;
            if (depth == 0) return pos;
        }
    }
    return null;
}

fn findMatchingParen(source: []const u8, open_pos: usize) ?usize {
    return findMatchingBracket(source, open_pos, '(', ')');
}

fn findUnescaped(source: []const u8, start: usize, delimiter: []const u8) ?usize {
    if (delimiter.len == 0 or start >= source.len) return null;
    var pos = start;
    while (pos + delimiter.len <= source.len) : (pos += 1) {
        if (source[pos] == '\\') {
            pos += 1;
            continue;
        }
        if (std.mem.eql(u8, source[pos .. pos + delimiter.len], delimiter)) return pos;
    }
    return null;
}

fn isMarkdownSpecial(c: u8) bool {
    return switch (c) {
        '*', '`', '~', '#', '-', '_', '[', ']', '(', ')', '\\', '>', '+', '!' => true,
        else => false,
    };
}

fn isBlankLine(line: []const u8) bool {
    for (line) |c| {
        if (c != ' ' and c != '\t') return false;
    }
    return true;
}

fn trimLeftSpaces(line: []const u8) []const u8 {
    var pos: usize = 0;
    while (pos < line.len and (line[pos] == ' ' or line[pos] == '\t')) : (pos += 1) {}
    return line[pos..];
}

fn leadingIndentCols(line: []const u8) usize {
    var cols: usize = 0;
    for (line) |c| {
        switch (c) {
            ' ' => cols += 1,
            '\t' => cols += 4 - (cols % 4),
            else => break,
        }
    }
    return cols;
}

fn removeIndent(line: []const u8, indent_cols: usize) []const u8 {
    var pos: usize = 0;
    var cols: usize = 0;
    while (pos < line.len and cols < indent_cols) {
        switch (line[pos]) {
            ' ' => cols += 1,
            '\t' => cols += 4 - (cols % 4),
            else => break,
        }
        pos += 1;
    }
    return line[pos..];
}

fn trimRightSpaces(line: []const u8) usize {
    var end = line.len;
    while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}
    return end;
}

test "markdown parser builds nested lists tables links and quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const doc = try parseDocument(
        "# Title\n\n- parent\n  - child\n\n| Name | Value |\n| --- | ---: |\n| [site](https://example.com) | 42 |\n\n> Foo\nbar\n",
        arena.allocator(),
    );

    try std.testing.expectEqual(@as(usize, 4), doc.blocks.len);
    try std.testing.expect(doc.blocks[0].block == .heading);
    try std.testing.expect(doc.blocks[1].block == .list);
    try std.testing.expect(doc.blocks[2].block == .table);
    try std.testing.expect(doc.blocks[3].block == .quote);

    const list = doc.blocks[1].block.list;
    try std.testing.expectEqual(@as(usize, 1), list.items.len);
    try std.testing.expectEqual(@as(usize, 2), list.items[0].blocks.len);

    const table = doc.blocks[2].block.table;
    try std.testing.expectEqual(@as(usize, 2), table.alignments.len);
    try std.testing.expectEqual(ast.Alignment.right, table.alignments[1]);

    const quote = doc.blocks[3].block.quote;
    try std.testing.expectEqual(@as(usize, 1), quote.blocks.len);
    try std.testing.expect(quote.blocks[0].block == .paragraph);
}
