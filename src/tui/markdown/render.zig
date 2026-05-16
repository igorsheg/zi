const std = @import("std");
const ast = @import("ast.zig");
const theme_mod = @import("../theme.zig");
const themes_builtin = @import("../../themes/builtin.zig");
const display_wrap_mod = @import("../wrap/display.zig");
const grapheme_mod = @import("../grapheme.zig");

pub const Span = struct {
    text: []const u8,
    fg: ast.Color,
    bg: ast.Color,
    attrs: ast.Attributes,
};

pub const RenderedLine = struct {
    spans: []const Span,
};

pub const code_inline_bg = ast.Color.default;

const FlatRun = struct {
    start: usize,
    end: usize,
    style: ast.Style,
};

const FlatText = struct {
    text: []const u8,
    runs: []const FlatRun,
};

const FlatTableCell = struct {
    flat: FlatText,
    alignment: ast.Alignment,
};

pub fn renderDocument(
    doc: ast.Document,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    return renderBlocks(doc.blocks, width, theme, base_style, code_block_indent, arena, width_method);
}

fn renderBlocks(
    blocks: []const ast.BlockNode,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    if (width == 0) return &.{};

    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer lines.deinit(arena);

    for (blocks, 0..) |node, idx| {
        if (idx > 0 and (node.separated or needsSemanticGap(blocks[idx - 1].block, node.block))) {
            try lines.append(arena, .{ .spans = &.{} });
        }
        const rendered = try renderBlock(node.block, width, theme, base_style, code_block_indent, arena, width_method);
        try lines.appendSlice(arena, rendered);
    }

    while (lines.items.len > 0 and lines.items[lines.items.len - 1].spans.len == 0) {
        lines.items.len -= 1;
    }

    return try lines.toOwnedSlice(arena);
}

fn needsSemanticGap(prev: ast.Block, next: ast.Block) bool {
    _ = next;
    return switch (prev) {
        .heading, .code_block, .quote, .thematic_break, .table => true,
        else => false,
    };
}

fn renderBlock(
    block: ast.Block,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    return switch (block) {
        .paragraph => |p| renderParagraph(p.inlines, width, theme, base_style, arena, width_method),
        .heading => |h| renderHeading(h, width, theme, arena, width_method),
        .code_block => |cb| renderCodeBlock(cb, width, theme, code_block_indent, arena, width_method),
        .list => |list| renderList(list, width, theme, base_style, code_block_indent, arena, width_method),
        .quote => |quote| renderQuote(quote, width, theme, code_block_indent, arena, width_method),
        .thematic_break => renderThematicBreak(width, theme, arena),
        .table => |table| renderTable(table, width, theme, base_style, arena, width_method),
    };
}

fn renderParagraph(
    inlines: []const ast.Inline,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    const flat = try flattenInlines(inlines, base_style, theme, arena);
    return try wrapFlatText(flat, width, arena, width_method);
}

fn renderHeading(h: ast.Heading, width: u32, theme: *const theme_mod.Theme, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) std.mem.Allocator.Error![]const RenderedLine {
    var heading_attrs: ast.Attributes = .{ .bold = true };
    if (h.level == 1) heading_attrs.underline = true;
    const style = ast.Style{
        .fg = theme.fg(.md_heading),
        .bg = ast.Color.default,
        .attrs = heading_attrs,
    };

    const flat = try flattenInlines(h.inlines, style, theme, arena);
    if (h.level >= 3) {
        const prefix_len = @as(usize, h.level) + 1;
        const prefix = try arena.alloc(Span, 1);
        const prefix_text = try arena.alloc(u8, prefix_len);
        @memset(prefix_text[0..h.level], '#');
        prefix_text[h.level] = ' ';
        prefix[0] = .{ .text = prefix_text, .fg = style.fg, .bg = style.bg, .attrs = style.attrs };
        return try wrapWithPrefix(prefix, @intCast(prefix_len), flat, width, arena, width_method);
    }
    return try wrapFlatText(flat, width, arena, width_method);
}

fn renderCodeBlock(
    cb: ast.CodeBlock,
    width: u32,
    theme: *const theme_mod.Theme,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer lines.deinit(arena);

    const opening = if (cb.info.len > 0)
        try std.fmt.allocPrint(arena, "```{s}", .{cb.info})
    else
        "```";
    try lines.append(arena, .{ .spans = try singleSpan(
        opening,
        theme.fg(.md_code_block_border),
        ast.Color.default,
        .{ .dim = true },
        arena,
    ) });

    const indent_width: u32 = @intCast(grapheme_mod.strWidth(code_block_indent, width_method));
    const avail = if (width > indent_width) width - indent_width else 1;
    for (cb.lines) |line| {
        const chunks = try hardWrap(line, avail, arena, width_method);
        if (chunks.len == 0) {
            try lines.append(arena, .{ .spans = try prefixedCodeLine(code_block_indent, "", theme, arena) });
            continue;
        }
        for (chunks) |chunk| {
            try lines.append(arena, .{ .spans = try prefixedCodeLine(code_block_indent, chunk, theme, arena) });
        }
    }

    try lines.append(arena, .{ .spans = try singleSpan(
        "```",
        theme.fg(.md_code_block_border),
        ast.Color.default,
        .{ .dim = true },
        arena,
    ) });

    return try lines.toOwnedSlice(arena);
}

fn prefixedCodeLine(indent: []const u8, chunk: []const u8, theme: *const theme_mod.Theme, arena: std.mem.Allocator) ![]const Span {
    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer spans.deinit(arena);
    try spans.append(arena, .{ .text = indent, .fg = theme.fg(.md_code_block), .bg = ast.Color.default, .attrs = .{} });
    if (chunk.len > 0) {
        try spans.append(arena, .{ .text = chunk, .fg = theme.fg(.md_code_block), .bg = ast.Color.default, .attrs = .{} });
    }
    return try spans.toOwnedSlice(arena);
}

fn renderList(
    list: ast.List,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer lines.deinit(arena);

    for (list.items, 0..) |item, idx| {
        const bullet_text = if (list.ordered)
            try std.fmt.allocPrint(arena, "{d}. ", .{list.start + idx})
        else
            "- ";
        const prefix_width: u32 = @intCast(grapheme_mod.strWidth(bullet_text, width_method));
        const content_width = if (width > prefix_width) width - prefix_width else 1;
        const rendered_item = try renderBlocks(item.blocks, content_width, theme, base_style, code_block_indent, arena, width_method);
        const prefix = try arena.alloc(Span, 1);
        prefix[0] = .{ .text = bullet_text, .fg = theme.fg(.md_list_bullet), .bg = ast.Color.default, .attrs = .{} };
        const wrapped = try applyPrefixToLines(prefix, prefix_width, rendered_item, arena);
        try lines.appendSlice(arena, wrapped);
    }

    return try lines.toOwnedSlice(arena);
}

fn renderQuote(
    quote: ast.Quote,
    width: u32,
    theme: *const theme_mod.Theme,
    code_block_indent: []const u8,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    const prefix_width: u32 = 2;
    const content_width = if (width > prefix_width) width - prefix_width else 1;
    const quote_style = ast.Style{
        .fg = theme.fg(.md_quote),
        .bg = ast.Color.default,
        .attrs = .{ .italic = true },
    };
    const inner = try renderBlocks(quote.blocks, content_width, theme, quote_style, code_block_indent, arena, width_method);
    const prefix = try arena.alloc(Span, 1);
    prefix[0] = .{ .text = "│ ", .fg = theme.fg(.md_quote_border), .bg = ast.Color.default, .attrs = .{ .dim = true } };
    return try applyPrefixToLines(prefix, prefix_width, inner, arena);
}

fn renderThematicBreak(width: u32, theme: *const theme_mod.Theme, arena: std.mem.Allocator) std.mem.Allocator.Error![]const RenderedLine {
    const hr_width: usize = @min(width, 80);
    const text = try makeRepeatedRune(0x2500, @intCast(hr_width), arena);
    const span = try singleSpan(text, theme.fg(.md_hr), ast.Color.default, .{ .dim = true }, arena);
    const result = try arena.alloc(RenderedLine, 1);
    result[0] = .{ .spans = span };
    return result;
}

fn renderTable(
    table: ast.Table,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    const num_cols = table.alignments.len;
    if (num_cols == 0) return &.{};

    const border_overhead: u32 = @intCast(3 * num_cols + 1);
    if (width <= border_overhead) {
        return try renderTableFallback(table, width, theme, base_style, arena, width_method);
    }

    const available_for_cells = width - border_overhead;
    if (available_for_cells < num_cols) {
        return try renderTableFallback(table, width, theme, base_style, arena, width_method);
    }

    var natural_widths = try arena.alloc(u32, num_cols);
    var min_word_widths = try arena.alloc(u32, num_cols);
    const header_cells = try arena.alloc(FlatTableCell, num_cols);
    const body_cells = try arena.alloc(FlatTableCell, num_cols * table.rows.len);
    @memset(natural_widths, 1);
    @memset(min_word_widths, 1);

    for (0..num_cols) |i| {
        const inlines = if (i < table.header.len) table.header[i].inlines else &.{};
        const flat = try flattenInlines(inlines, .{
            .fg = base_style.fg,
            .bg = base_style.bg,
            .attrs = mergeAttrs(base_style.attrs, .{ .bold = true }),
        }, theme, arena);
        header_cells[i] = .{ .flat = flat, .alignment = table.alignments[i] };
        natural_widths[i] = flatWidth(flat, width_method);
        min_word_widths[i] = longestWordWidth(flat.text, 30, width_method);
    }
    for (table.rows, 0..) |row, row_idx| {
        for (0..num_cols) |i| {
            const inlines = if (i < row.cells.len) row.cells[i].inlines else &.{};
            const flat = try flattenInlines(inlines, base_style, theme, arena);
            body_cells[row_idx * num_cols + i] = .{ .flat = flat, .alignment = table.alignments[i] };
            natural_widths[i] = @max(natural_widths[i], flatWidth(flat, width_method));
            min_word_widths[i] = @max(min_word_widths[i], longestWordWidth(flat.text, 30, width_method));
        }
    }

    const column_widths = try computeColumnWidths(natural_widths, min_word_widths, available_for_cells, arena);

    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer lines.deinit(arena);

    try lines.append(arena, .{ .spans = try borderLine("┌─", "─┬─", "─┐", column_widths, theme, arena) });

    const header_rows = try renderFlatTableRow(header_cells, column_widths, theme, base_style, arena, width_method);
    try lines.appendSlice(arena, header_rows);

    const separator = try borderLine("├─", "─┼─", "─┤", column_widths, theme, arena);
    try lines.append(arena, .{ .spans = separator });

    for (table.rows, 0..) |_, row_idx| {
        const row_start = row_idx * num_cols;
        const row_lines = try renderFlatTableRow(body_cells[row_start .. row_start + num_cols], column_widths, theme, base_style, arena, width_method);
        try lines.appendSlice(arena, row_lines);
        if (row_idx + 1 < table.rows.len) {
            try lines.append(arena, .{ .spans = separator });
        }
    }

    try lines.append(arena, .{ .spans = try borderLine("└─", "─┴─", "─┘", column_widths, theme, arena) });
    return try lines.toOwnedSlice(arena);
}

fn renderTableFallback(
    table: ast.Table,
    width: u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    var blocks: std.ArrayListUnmanaged(ast.BlockNode) = .empty;
    errdefer blocks.deinit(arena);

    var line_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer line_buf.deinit(arena);

    line_buf.clearRetainingCapacity();
    for (table.header, 0..) |cell, i| {
        if (i > 0) try line_buf.appendSlice(arena, " | ");
        try appendPlainInlineText(&line_buf, cell.inlines, arena);
    }
    try blocks.append(arena, .{ .block = .{ .paragraph = .{ .inlines = try singleTextNode(line_buf.items, arena) } } });

    for (table.rows) |row| {
        line_buf.clearRetainingCapacity();
        for (row.cells, 0..) |cell, i| {
            if (i > 0) try line_buf.appendSlice(arena, " | ");
            try appendPlainInlineText(&line_buf, cell.inlines, arena);
        }
        try blocks.append(arena, .{ .block = .{ .paragraph = .{ .inlines = try singleTextNode(line_buf.items, arena) } }, .separated = true });
    }

    return try renderBlocks(blocks.items, width, theme, base_style, "  ", arena, width_method);
}

fn renderFlatTableRow(
    cells: []const FlatTableCell,
    column_widths: []const u32,
    theme: *const theme_mod.Theme,
    base_style: ast.Style,
    arena: std.mem.Allocator,
    width_method: grapheme_mod.WidthMethod,
) std.mem.Allocator.Error![]const RenderedLine {
    const num_cols = column_widths.len;
    var cell_line_sets = try arena.alloc([]const []const Span, num_cols);
    var max_lines: usize = 1;

    for (0..num_cols) |i| {
        const wrapped = try wrapFlatTextToSpans(cells[i].flat, column_widths[i], arena, width_method);
        if (wrapped.len > max_lines) max_lines = wrapped.len;
        cell_line_sets[i] = try alignCellLines(wrapped, column_widths[i], cells[i].alignment, arena, width_method);
    }

    var rows: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer rows.deinit(arena);

    for (0..max_lines) |line_idx| {
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(arena);
        try spans.append(arena, .{ .text = "│ ", .fg = theme.fg(.md_hr), .bg = ast.Color.default, .attrs = .{ .dim = true } });
        for (0..num_cols) |col| {
            const empty = try blankSpanLine(column_widths[col], base_style, arena);
            try spans.appendSlice(arena, if (line_idx < cell_line_sets[col].len) cell_line_sets[col][line_idx] else empty);
            if (col + 1 < num_cols) {
                try spans.append(arena, .{ .text = " │ ", .fg = theme.fg(.md_hr), .bg = ast.Color.default, .attrs = .{ .dim = true } });
            } else {
                try spans.append(arena, .{ .text = " │", .fg = theme.fg(.md_hr), .bg = ast.Color.default, .attrs = .{ .dim = true } });
            }
        }
        try rows.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
    }

    return try rows.toOwnedSlice(arena);
}

fn alignCellLines(lines: []const []const Span, width: u32, alignment: ast.Alignment, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) std.mem.Allocator.Error![]const []const Span {
    var result: std.ArrayListUnmanaged([]const Span) = .empty;
    errdefer result.deinit(arena);

    for (lines) |line| {
        try result.append(arena, try padAlignedSpans(line, width, alignment, arena, width_method));
    }
    if (result.items.len == 0) {
        try result.append(arena, try blankSpanLine(width, .{ .fg = ast.Color.default, .bg = ast.Color.default, .attrs = .{} }, arena));
    }
    return try result.toOwnedSlice(arena);
}

fn computeColumnWidths(natural: []const u32, minimums: []const u32, available: u32, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u32 {
    const num_cols = natural.len;
    var widths = try arena.alloc(u32, num_cols);

    var min_sum: u32 = 0;
    for (minimums, 0..) |min_width, i| {
        widths[i] = @max(1, min_width);
        min_sum += widths[i];
    }

    if (min_sum > available) {
        for (0..num_cols) |i| widths[i] = 1;
        var remaining = available - @as(u32, @intCast(num_cols));
        var i: usize = 0;
        while (remaining > 0) : (i = (i + 1) % num_cols) {
            widths[i] += 1;
            remaining -= 1;
        }
        return widths;
    }

    const natural_sum = sumU32(natural);
    if (natural_sum <= available) {
        @memcpy(widths, natural);
        return widths;
    }

    var remaining = available - min_sum;
    while (remaining > 0) {
        var grew = false;
        for (0..num_cols) |i| {
            if (remaining == 0) break;
            if (widths[i] < natural[i]) {
                widths[i] += 1;
                remaining -= 1;
                grew = true;
            }
        }
        if (!grew) break;
    }
    return widths;
}

fn sumU32(values: []const u32) u32 {
    var total: u32 = 0;
    for (values) |value| total += value;
    return total;
}

fn applyPrefixToLines(prefix: []const Span, prefix_width: u32, lines: []const RenderedLine, arena: std.mem.Allocator) ![]const RenderedLine {
    var result: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer result.deinit(arena);

    if (lines.len == 0) {
        try result.append(arena, .{ .spans = prefix });
        return try result.toOwnedSlice(arena);
    }

    const indent = try spaces(prefix_width, arena);
    for (lines, 0..) |line, idx| {
        var spans: std.ArrayListUnmanaged(Span) = .empty;
        errdefer spans.deinit(arena);
        if (idx == 0) {
            try spans.appendSlice(arena, prefix);
        } else if (prefix_width > 0) {
            try spans.append(arena, .{ .text = indent, .fg = ast.Color.default, .bg = ast.Color.default, .attrs = .{} });
        }
        try spans.appendSlice(arena, line.spans);
        try result.append(arena, .{ .spans = try spans.toOwnedSlice(arena) });
    }

    return try result.toOwnedSlice(arena);
}

fn flattenInlines(inlines: []const ast.Inline, base_style: ast.Style, theme: *const theme_mod.Theme, arena: std.mem.Allocator) !FlatText {
    var text: std.ArrayListUnmanaged(u8) = .empty;
    errdefer text.deinit(arena);
    var runs: std.ArrayListUnmanaged(FlatRun) = .empty;
    errdefer runs.deinit(arena);

    try appendInlineContent(inlines, base_style, theme, &text, &runs, arena);
    return .{ .text = try text.toOwnedSlice(arena), .runs = try runs.toOwnedSlice(arena) };
}

fn appendInlineContent(
    inlines: []const ast.Inline,
    style: ast.Style,
    theme: *const theme_mod.Theme,
    text: *std.ArrayListUnmanaged(u8),
    runs: *std.ArrayListUnmanaged(FlatRun),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    for (inlines) |node| {
        switch (node) {
            .text => |slice| try appendStyledText(text, runs, slice, style, arena),
            .line_break => try appendStyledText(text, runs, "\n", style, arena),
            .code => |slice| try appendStyledText(text, runs, slice, .{
                .fg = theme.fg(.md_code),
                .bg = code_inline_bg,
                .attrs = .{},
            }, arena),
            .strong => |children| try appendInlineContent(children, .{
                .fg = style.fg,
                .bg = style.bg,
                .attrs = mergeAttrs(style.attrs, .{ .bold = true }),
            }, theme, text, runs, arena),
            .emphasis => |children| try appendInlineContent(children, .{
                .fg = style.fg,
                .bg = style.bg,
                .attrs = mergeAttrs(style.attrs, .{ .italic = true }),
            }, theme, text, runs, arena),
            .strikethrough => |children| try appendInlineContent(children, .{
                .fg = style.fg,
                .bg = style.bg,
                .attrs = mergeAttrs(style.attrs, .{ .strikethrough = true }),
            }, theme, text, runs, arena),
            .link => |link| try appendLink(link, style, theme, text, runs, arena),
        }
    }
}

fn appendLink(
    link: ast.Link,
    base_style: ast.Style,
    theme: *const theme_mod.Theme,
    text: *std.ArrayListUnmanaged(u8),
    runs: *std.ArrayListUnmanaged(FlatRun),
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    const link_style = ast.Style{
        .fg = theme.fg(.md_link),
        .bg = ast.Color.default,
        .attrs = mergeAttrs(base_style.attrs, .{ .underline = true }),
    };
    try appendInlineContent(link.label, link_style, theme, text, runs, arena);

    const href_for_compare = if (std.mem.startsWith(u8, link.href, "mailto:")) link.href[7..] else link.href;
    const should_append_url = switch (link.kind) {
        .explicit => !(inlinePlainTextEql(link.label, link.href) or inlinePlainTextEql(link.label, href_for_compare)),
        else => false,
    };
    if (should_append_url) {
        const suffix = try std.fmt.allocPrint(arena, " ({s})", .{link.href});
        try appendStyledText(text, runs, suffix, .{
            .fg = theme.fg(.md_link_url),
            .bg = ast.Color.default,
            .attrs = base_style.attrs,
        }, arena);
    }
}

fn inlinePlainTextEql(inlines: []const ast.Inline, expected: []const u8) bool {
    var offset: usize = 0;
    if (!inlinePlainTextEqlAt(inlines, expected, &offset)) return false;
    return offset == expected.len;
}

fn inlinePlainTextEqlAt(inlines: []const ast.Inline, expected: []const u8, offset: *usize) bool {
    for (inlines) |node| {
        switch (node) {
            .text, .code => |slice| {
                if (offset.* + slice.len > expected.len) return false;
                if (!std.mem.eql(u8, expected[offset.* .. offset.* + slice.len], slice)) return false;
                offset.* += slice.len;
            },
            .line_break => {
                if (offset.* >= expected.len or expected[offset.*] != '\n') return false;
                offset.* += 1;
            },
            .strong, .emphasis, .strikethrough => |children| {
                if (!inlinePlainTextEqlAt(children, expected, offset)) return false;
            },
            .link => |nested| {
                if (!inlinePlainTextEqlAt(nested.label, expected, offset)) return false;
            },
        }
    }
    return true;
}

fn inlinePlainText(inlines: []const ast.Inline, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(arena);
    try appendPlainInlineText(&out, inlines, arena);
    return try out.toOwnedSlice(arena);
}

fn appendPlainInlineText(out: *std.ArrayListUnmanaged(u8), inlines: []const ast.Inline, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
    for (inlines) |node| {
        switch (node) {
            .text => |slice| try out.appendSlice(arena, slice),
            .code => |slice| try out.appendSlice(arena, slice),
            .line_break => try out.append(arena, '\n'),
            .strong => |children| try appendPlainInlineText(out, children, arena),
            .emphasis => |children| try appendPlainInlineText(out, children, arena),
            .strikethrough => |children| try appendPlainInlineText(out, children, arena),
            .link => |link| try appendPlainInlineText(out, link.label, arena),
        }
    }
}

fn appendStyledText(
    text: *std.ArrayListUnmanaged(u8),
    runs: *std.ArrayListUnmanaged(FlatRun),
    slice: []const u8,
    style: ast.Style,
    arena: std.mem.Allocator,
) std.mem.Allocator.Error!void {
    if (slice.len == 0) return;
    const start = text.items.len;
    try text.appendSlice(arena, slice);
    const end = text.items.len;
    if (runs.items.len > 0) {
        const last = &runs.items[runs.items.len - 1];
        if (last.end == start and last.style.eql(style)) {
            last.end = end;
            return;
        }
    }
    try runs.append(arena, .{ .start = start, .end = end, .style = style });
}

fn wrapFlatText(flat: FlatText, width: u32, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) ![]const RenderedLine {
    if (width == 0) return &.{};
    return try wrapFlatTextToRendered(flat, width, arena, width_method);
}

fn wrapFlatTextToRendered(flat: FlatText, width: u32, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) ![]const RenderedLine {
    const wrapped = try display_wrap_mod.wordWrap(flat.text, width, arena, width_method);
    var lines: std.ArrayListUnmanaged(RenderedLine) = .empty;
    errdefer lines.deinit(arena);
    for (wrapped) |line| {
        try lines.append(arena, .{ .spans = try reconstructSpans(line.start, line.end, flat, arena) });
    }
    return try lines.toOwnedSlice(arena);
}

fn wrapFlatTextToSpans(flat: FlatText, width: u32, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) ![]const []const Span {
    const wrapped = try display_wrap_mod.wordWrap(flat.text, width, arena, width_method);
    var lines: std.ArrayListUnmanaged([]const Span) = .empty;
    errdefer lines.deinit(arena);
    for (wrapped) |line| {
        try lines.append(arena, try reconstructSpans(line.start, line.end, flat, arena));
    }
    return try lines.toOwnedSlice(arena);
}

fn wrapWithPrefix(prefix: []const Span, prefix_width: u32, flat: FlatText, total_width: u32, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) ![]const RenderedLine {
    const content_width = if (total_width > prefix_width) total_width - prefix_width else 1;
    const wrapped = try wrapFlatTextToRendered(flat, content_width, arena, width_method);
    return try applyPrefixToLines(prefix, prefix_width, wrapped, arena);
}

fn reconstructSpans(start: usize, end: usize, flat: FlatText, arena: std.mem.Allocator) ![]const Span {
    if (flat.runs.len == 1) {
        const run = flat.runs[0];
        const s = @max(run.start, start);
        const e = @min(run.end, end);
        if (s >= e) return &.{};
        const spans = try arena.alloc(Span, 1);
        spans[0] = .{ .text = flat.text[s..e], .fg = run.style.fg, .bg = run.style.bg, .attrs = run.style.attrs };
        return spans;
    }

    var spans: std.ArrayListUnmanaged(Span) = .empty;
    errdefer spans.deinit(arena);
    for (flat.runs) |run| {
        if (run.end <= start) continue;
        if (run.start >= end) break;
        const s = @max(run.start, start);
        const e = @min(run.end, end);
        if (s < e) {
            try spans.append(arena, .{ .text = flat.text[s..e], .fg = run.style.fg, .bg = run.style.bg, .attrs = run.style.attrs });
        }
    }
    return try spans.toOwnedSlice(arena);
}

fn flatWidth(flat: FlatText, width_method: grapheme_mod.WidthMethod) u32 {
    return @intCast(grapheme_mod.strWidth(flat.text, width_method));
}

fn longestWordWidth(text: []const u8, cap: u32, width_method: grapheme_mod.WidthMethod) u32 {
    var longest: u32 = 1;
    var start: usize = 0;
    var in_word = false;
    for (text, 0..) |c, idx| {
        if (c == ' ' or c == '\t' or c == '\n') {
            if (in_word) {
                longest = @max(longest, @as(u32, @intCast(grapheme_mod.strWidth(text[start..idx], width_method))));
                in_word = false;
            }
        } else if (!in_word) {
            in_word = true;
            start = idx;
        }
    }
    if (in_word) {
        longest = @max(longest, @as(u32, @intCast(grapheme_mod.strWidth(text[start..], width_method))));
    }
    return @min(longest, cap);
}

fn hardWrap(text: []const u8, width: u32, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) ![]const []const u8 {
    var parts: std.ArrayListUnmanaged([]const u8) = .empty;
    errdefer parts.deinit(arena);
    if (text.len == 0) return &.{};

    var rest = text;
    while (rest.len > 0) {
        const chunk = grapheme_mod.sliceToWidth(rest, width, width_method);
        if (chunk.len == 0) break;
        try parts.append(arena, chunk);
        rest = rest[chunk.len..];
    }
    return try parts.toOwnedSlice(arena);
}

fn borderLine(left: []const u8, mid: []const u8, right: []const u8, widths: []const u32, theme: *const theme_mod.Theme, arena: std.mem.Allocator) std.mem.Allocator.Error![]const Span {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(arena);
    try buf.appendSlice(arena, left);
    for (widths, 0..) |width, idx| {
        const fill = try makeRepeatedRune(0x2500, width, arena);
        try buf.appendSlice(arena, fill);
        if (idx + 1 < widths.len) {
            try buf.appendSlice(arena, mid);
        } else {
            try buf.appendSlice(arena, right);
        }
    }
    return try singleSpan(try buf.toOwnedSlice(arena), theme.fg(.md_hr), ast.Color.default, .{ .dim = true }, arena);
}

fn padAlignedSpans(spans: []const Span, width: u32, alignment: ast.Alignment, arena: std.mem.Allocator, width_method: grapheme_mod.WidthMethod) std.mem.Allocator.Error![]const Span {
    const used: u32 = @intCast(visibleWidthSpans(spans, width_method));
    if (used >= width) return spans;
    const remaining = width - used;
    const left_pad: u32 = switch (alignment) {
        .right => remaining,
        .center => remaining / 2,
        else => 0,
    };
    const right_pad = remaining - left_pad;

    var result: std.ArrayListUnmanaged(Span) = .empty;
    errdefer result.deinit(arena);
    if (left_pad > 0) try result.append(arena, .{ .text = try spaces(left_pad, arena), .fg = ast.Color.default, .bg = ast.Color.default, .attrs = .{} });
    try result.appendSlice(arena, spans);
    if (right_pad > 0) try result.append(arena, .{ .text = try spaces(right_pad, arena), .fg = ast.Color.default, .bg = ast.Color.default, .attrs = .{} });
    return try result.toOwnedSlice(arena);
}

fn blankSpanLine(width: u32, style: ast.Style, arena: std.mem.Allocator) std.mem.Allocator.Error![]const Span {
    if (width == 0) return &.{};
    return try singleSpan(try spaces(width, arena), style.fg, style.bg, style.attrs, arena);
}

fn visibleWidthSpans(spans: []const Span, width_method: grapheme_mod.WidthMethod) usize {
    var total: usize = 0;
    for (spans) |span| total += grapheme_mod.strWidth(span.text, width_method);
    return total;
}

fn spaces(count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    const buf = try arena.alloc(u8, count);
    @memset(buf, ' ');
    return buf;
}

fn makeRepeatedRune(cp: u21, count: u32, arena: std.mem.Allocator) std.mem.Allocator.Error![]const u8 {
    var chunk: [4]u8 = undefined;
    const len = std.unicode.utf8Encode(cp, &chunk) catch unreachable;
    const out = try arena.alloc(u8, @as(usize, count) * len);
    for (0..count) |i| {
        @memcpy(out[i * len ..][0..len], chunk[0..len]);
    }
    return out;
}

fn singleSpan(text: []const u8, fg: ast.Color, bg: ast.Color, attrs: ast.Attributes, arena: std.mem.Allocator) std.mem.Allocator.Error![]const Span {
    const spans = try arena.alloc(Span, 1);
    spans[0] = .{ .text = text, .fg = fg, .bg = bg, .attrs = attrs };
    return spans;
}

fn singleTextNode(text: []const u8, arena: std.mem.Allocator) std.mem.Allocator.Error![]const ast.Inline {
    const nodes = try arena.alloc(ast.Inline, 1);
    nodes[0] = .{ .text = try arena.dupe(u8, text) };
    return nodes;
}

fn mergeAttrs(base: ast.Attributes, overlay: ast.Attributes) ast.Attributes {
    return .{
        .bold = base.bold or overlay.bold,
        .dim = base.dim or overlay.dim,
        .italic = base.italic or overlay.italic,
        .underline = base.underline or overlay.underline,
        .blink = base.blink or overlay.blink,
        .inverse = base.inverse or overlay.inverse,
        .hidden = base.hidden or overlay.hidden,
        .strikethrough = base.strikethrough or overlay.strikethrough,
    };
}

test "renderer wraps tables and preserves quote and heading styling" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");
    const doc = try parser.parseDocument(
        "### Heading with `code`\n\n> Quote with **bold**\n\n| Col | Value |\n| --- | ---: |\n| `identifier` | 123 |\n",
        arena.allocator(),
    );

    const lines = try renderDocument(doc, 24, themes_builtin.dark(), .{
        .fg = ast.Color.default,
        .bg = ast.Color.default,
        .attrs = .{},
    }, "  ", arena.allocator(), .wcwidth);

    try std.testing.expect(lines.len > 0);
    try std.testing.expect(std.mem.eql(u8, lines[0].spans[0].text, "### "));
    try std.testing.expect(lines[0].spans[0].attrs.bold);

    var saw_quote_border = false;
    var saw_inline_code_bg = false;
    var saw_table_border = false;
    for (lines) |line| {
        for (line.spans) |span| {
            if (std.mem.eql(u8, span.text, "│ ")) saw_quote_border = true;
            if (span.bg.eql(code_inline_bg)) saw_inline_code_bg = true;
            if (std.mem.indexOf(u8, span.text, "┌") != null) saw_table_border = true;
        }
    }
    try std.testing.expect(saw_quote_border);
    try std.testing.expect(saw_inline_code_bg);
    try std.testing.expect(saw_table_border);
}

test "renderer wraps without splitting grapheme clusters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const parser = @import("parser.zig");
    const doc = try parser.parseDocument("e\u{0301}x 👩‍🚀y", arena.allocator());
    const lines = try renderDocument(doc, 2, themes_builtin.dark(), .{
        .fg = ast.Color.default,
        .bg = ast.Color.default,
        .attrs = .{},
    }, "  ", arena.allocator(), .wcwidth);

    try std.testing.expect(lines.len >= 3);
    try std.testing.expectEqualStrings("e\u{0301}x", lines[0].spans[0].text);
    try std.testing.expectEqualStrings("👩‍🚀", lines[1].spans[0].text);
    try std.testing.expectEqualStrings("y", lines[2].spans[0].text);
}
