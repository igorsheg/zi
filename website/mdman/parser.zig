//! Minimal Markdown parser for man page generation.
//!
//! Supports: headings, paragraphs, bold, italic, code, code blocks,
//! bullet lists, definition lists, and links.
//!
//! Usage:
//!   var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!   defer arena.deinit();
//!   const doc = try parse(arena.allocator(), source);

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Node = union(enum) {
    heading: Heading,
    paragraph: []const Span,
    code_block: CodeBlock,
    bullet_list: []const []const Span,
    definition: Definition,

    pub const Heading = struct {
        level: u8,
        text: []const u8,
    };

    pub const CodeBlock = struct {
        language: ?[]const u8,
        content: []const u8,
    };

    pub const Definition = struct {
        term: []const Span,
        description: []const Span,
    };
};

pub const Span = union(enum) {
    text: []const u8,
    bold: []const u8,
    italic: []const u8,
    code: []const u8,
    link: Link,

    pub const Link = struct {
        text: []const u8,
        url: []const u8,
    };
};

pub const Document = struct {
    nodes: []const Node,
};

/// Parse markdown source into a Document.
/// All allocations use the provided allocator (typically an arena).
/// Caller owns the allocator lifetime.
pub fn parse(allocator: Allocator, source: []const u8) !Document {
    var p = Parser{ .allocator = allocator, .source = source, .pos = 0 };
    return p.parse();
}

const Parser = struct {
    allocator: Allocator,
    source: []const u8,
    pos: usize,

    fn parse(self: *Parser) !Document {
        var nodes: std.ArrayListUnmanaged(Node) = .empty;

        while (!self.isAtEnd()) {
            self.skipBlankLines();
            if (self.isAtEnd()) break;

            if (try self.parseNode()) |node| {
                try nodes.append(self.allocator, node);
            }
        }

        return .{ .nodes = try nodes.toOwnedSlice(self.allocator) };
    }

    fn parseNode(self: *Parser) !?Node {
        const line = self.peekLine();

        if (std.mem.startsWith(u8, line, "## ")) {
            _ = self.consumeLine();
            return .{ .heading = .{ .level = 2, .text = line[3..] } };
        }
        if (std.mem.startsWith(u8, line, "# ")) {
            _ = self.consumeLine();
            return .{ .heading = .{ .level = 1, .text = line[2..] } };
        }

        if (std.mem.startsWith(u8, line, "```")) {
            return self.parseCodeBlock();
        }

        if (std.mem.startsWith(u8, line, "- ")) {
            return try self.parseBulletList();
        }

        if (self.isDefinitionStart()) {
            return try self.parseDefinition();
        }

        return try self.parseParagraph();
    }

    fn parseCodeBlock(self: *Parser) Node {
        const opening = self.consumeLine();
        const language = if (opening.len > 3) opening[3..] else null;

        const start = self.pos;
        while (!self.isAtEnd()) {
            const line = self.peekLine();
            if (std.mem.startsWith(u8, line, "```")) {
                const content = if (self.pos > start)
                    self.source[start .. self.pos - 1]
                else
                    "";
                _ = self.consumeLine();
                return .{ .code_block = .{ .language = language, .content = content } };
            }
            _ = self.consumeLine();
        }

        return .{ .code_block = .{ .language = language, .content = self.source[start..] } };
    }

    fn parseBulletList(self: *Parser) !Node {
        var items: std.ArrayListUnmanaged([]const Span) = .empty;

        while (!self.isAtEnd()) {
            const line = self.peekLine();
            if (!std.mem.startsWith(u8, line, "- ")) break;

            _ = self.consumeLine();
            const spans = try self.parseInline(line[2..]);
            try items.append(self.allocator, spans);
        }

        return .{ .bullet_list = try items.toOwnedSlice(self.allocator) };
    }

    fn parseDefinition(self: *Parser) !Node {
        const term_line = self.consumeLine();
        const term = try self.parseInline(term_line);

        const desc_line = self.consumeLine();
        const desc_text = std.mem.trimLeft(u8, desc_line[1..], " \t");

        var full_desc: std.ArrayListUnmanaged(u8) = .empty;
        try full_desc.appendSlice(self.allocator, desc_text);

        while (!self.isAtEnd()) {
            const next_line = self.peekLine();
            if (next_line.len == 0) break;
            if (!std.mem.startsWith(u8, next_line, "    ")) break;

            _ = self.consumeLine();
            try full_desc.append(self.allocator, ' ');
            try full_desc.appendSlice(self.allocator, std.mem.trimLeft(u8, next_line, " \t"));
        }

        const description = try self.parseInline(full_desc.items);

        return .{ .definition = .{ .term = term, .description = description } };
    }

    fn parseParagraph(self: *Parser) !Node {
        var text: std.ArrayListUnmanaged(u8) = .empty;

        while (!self.isAtEnd()) {
            const line = self.peekLine();
            if (line.len == 0 or
                std.mem.startsWith(u8, line, "# ") or
                std.mem.startsWith(u8, line, "## ") or
                std.mem.startsWith(u8, line, "```") or
                std.mem.startsWith(u8, line, "- "))
            {
                break;
            }
            if (self.isDefinitionStart()) break;

            if (text.items.len > 0) try text.append(self.allocator, ' ');
            try text.appendSlice(self.allocator, self.consumeLine());
        }

        const spans = try self.parseInline(text.items);
        return .{ .paragraph = spans };
    }

    fn parseInline(self: *Parser, text: []const u8) ![]const Span {
        var spans: std.ArrayListUnmanaged(Span) = .empty;

        var i: usize = 0;
        var text_start: usize = 0;

        while (i < text.len) {
            if (i + 1 < text.len and std.mem.eql(u8, text[i .. i + 2], "**")) {
                if (i > text_start) {
                    try spans.append(self.allocator, .{ .text = text[text_start..i] });
                }
                const end = std.mem.indexOf(u8, text[i + 2 ..], "**") orelse {
                    i += 1;
                    continue;
                };
                try spans.append(self.allocator, .{ .bold = text[i + 2 .. i + 2 + end] });
                i = i + 4 + end;
                text_start = i;
                continue;
            }

            if (text[i] == '*' and (i + 1 >= text.len or text[i + 1] != '*')) {
                if (i > text_start) {
                    try spans.append(self.allocator, .{ .text = text[text_start..i] });
                }
                const end = std.mem.indexOf(u8, text[i + 1 ..], "*") orelse {
                    i += 1;
                    continue;
                };
                try spans.append(self.allocator, .{ .italic = text[i + 1 .. i + 1 + end] });
                i = i + 2 + end;
                text_start = i;
                continue;
            }

            if (text[i] == '`') {
                if (i > text_start) {
                    try spans.append(self.allocator, .{ .text = text[text_start..i] });
                }
                const end = std.mem.indexOf(u8, text[i + 1 ..], "`") orelse {
                    i += 1;
                    continue;
                };
                try spans.append(self.allocator, .{ .code = text[i + 1 .. i + 1 + end] });
                i = i + 2 + end;
                text_start = i;
                continue;
            }

            if (text[i] == '[') {
                if (parseLink(text, i)) |result| {
                    if (i > text_start) {
                        try spans.append(self.allocator, .{ .text = text[text_start..i] });
                    }
                    try spans.append(self.allocator, .{ .link = result.link });
                    i = result.end;
                    text_start = i;
                    continue;
                }
            }

            i += 1;
        }

        if (text_start < text.len) {
            try spans.append(self.allocator, .{ .text = text[text_start..] });
        }

        return try spans.toOwnedSlice(self.allocator);
    }

    const LinkResult = struct { link: Span.Link, end: usize };

    fn parseLink(text: []const u8, start: usize) ?LinkResult {
        const close_bracket = std.mem.indexOf(u8, text[start + 1 ..], "]") orelse return null;
        const text_end = start + 1 + close_bracket;

        if (text_end + 1 >= text.len or text[text_end + 1] != '(') return null;

        const close_paren = std.mem.indexOf(u8, text[text_end + 2 ..], ")") orelse return null;
        const url_end = text_end + 2 + close_paren;

        return .{
            .link = .{
                .text = text[start + 1 .. text_end],
                .url = text[text_end + 2 .. url_end],
            },
            .end = url_end + 1,
        };
    }

    fn peekLine(self: *Parser) []const u8 {
        const end = std.mem.indexOf(u8, self.source[self.pos..], "\n") orelse self.source.len - self.pos;
        return self.source[self.pos .. self.pos + end];
    }

    fn consumeLine(self: *Parser) []const u8 {
        const line = self.peekLine();
        self.pos += line.len;
        if (self.pos < self.source.len and self.source[self.pos] == '\n') {
            self.pos += 1;
        }
        return line;
    }

    fn skipBlankLines(self: *Parser) void {
        while (!self.isAtEnd() and self.peekLine().len == 0) {
            _ = self.consumeLine();
        }
    }

    fn isAtEnd(self: *Parser) bool {
        return self.pos >= self.source.len;
    }

    fn isDefinitionStart(self: *Parser) bool {
        const line = self.peekLine();
        if (line.len == 0) return false;
        if (std.mem.startsWith(u8, line, "- ")) return false;

        const next_pos = self.pos + line.len + 1;
        if (next_pos >= self.source.len) return false;

        const rest = self.source[next_pos..];
        const next_end = std.mem.indexOf(u8, rest, "\n") orelse rest.len;
        const next_line = rest[0..next_end];

        return std.mem.startsWith(u8, next_line, ":");
    }
};

const testing = std.testing;

fn parseMarkdown(arena: *std.heap.ArenaAllocator, source: []const u8) !Document {
    return parse(arena.allocator(), source);
}

fn expectNodeCount(doc: Document, expected: usize) !void {
    try testing.expectEqual(expected, doc.nodes.len);
}

fn expectParagraph(node: Node) ![]const Span {
    return switch (node) {
        .paragraph => |spans| spans,
        else => error.ExpectedParagraph,
    };
}

fn expectCodeBlock(node: Node) !Node.CodeBlock {
    return switch (node) {
        .code_block => |code_block| code_block,
        else => error.ExpectedCodeBlock,
    };
}

fn expectBulletList(node: Node) ![]const []const Span {
    return switch (node) {
        .bullet_list => |items| items,
        else => error.ExpectedBulletList,
    };
}

fn expectDefinition(node: Node) !Node.Definition {
    return switch (node) {
        .definition => |definition| definition,
        else => error.ExpectedDefinition,
    };
}

fn expectHeading(node: Node, level: u8, text: []const u8) !void {
    const heading = switch (node) {
        .heading => |heading| heading,
        else => return error.ExpectedHeading,
    };
    try testing.expectEqual(level, heading.level);
    try testing.expectEqualStrings(text, heading.text);
}

fn expectText(span: Span, expected: []const u8) !void {
    switch (span) {
        .text => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedTextSpan,
    }
}

fn expectBold(span: Span, expected: []const u8) !void {
    switch (span) {
        .bold => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedBoldSpan,
    }
}

fn expectItalic(span: Span, expected: []const u8) !void {
    switch (span) {
        .italic => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedItalicSpan,
    }
}

fn expectCode(span: Span, expected: []const u8) !void {
    switch (span) {
        .code => |actual| try testing.expectEqualStrings(expected, actual),
        else => return error.ExpectedCodeSpan,
    }
}

fn expectLink(span: Span, text: []const u8, url: []const u8) !void {
    const link = switch (span) {
        .link => |link| link,
        else => return error.ExpectedLinkSpan,
    };
    try testing.expectEqualStrings(text, link.text);
    try testing.expectEqualStrings(url, link.url);
}

test "parse bold keeps surrounding text as text spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena, "This is **bold** text.\n");
    try expectNodeCount(doc, 1);

    const spans = try expectParagraph(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try expectText(spans[0], "This is ");
    try expectBold(spans[1], "bold");
    try expectText(spans[2], " text.");
}

test "parse italic keeps surrounding text as text spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena, "This is *italic* text.\n");
    try expectNodeCount(doc, 1);

    const spans = try expectParagraph(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try expectText(spans[0], "This is ");
    try expectItalic(spans[1], "italic");
    try expectText(spans[2], " text.");
}

test "parse inline code keeps surrounding text as text spans" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena, "Run `prise serve` now.\n");
    try expectNodeCount(doc, 1);

    const spans = try expectParagraph(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try expectText(spans[0], "Run ");
    try expectCode(spans[1], "prise serve");
    try expectText(spans[2], " now.");
}

test "parse link captures text and URL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena, "See [the docs](https://example.com) here.\n");
    try expectNodeCount(doc, 1);

    const spans = try expectParagraph(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), spans.len);
    try expectText(spans[0], "See ");
    try expectLink(spans[1], "the docs", "https://example.com");
    try expectText(spans[2], " here.");
}

test "parse fenced code block preserves language and content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena,
        \\```bash
        \\prise serve
        \\```
        \\
    );
    try expectNodeCount(doc, 1);

    const code_block = try expectCodeBlock(doc.nodes[0]);
    try testing.expectEqualStrings("bash", code_block.language.?);
    try testing.expectEqualStrings("prise serve", code_block.content);
}

test "parse consecutive bullet lines as one list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena,
        \\- First item
        \\- Second item
        \\- Third item
        \\
    );
    try expectNodeCount(doc, 1);

    const items = try expectBulletList(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), items.len);
    try expectText(items[0][0], "First item");
    try expectText(items[1][0], "Second item");
    try expectText(items[2][0], "Third item");
}

test "parse definition list term and description inline markup" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena,
        \\**-v**, **--verbose**
        \\:   Enable verbose output
        \\
    );
    try expectNodeCount(doc, 1);

    const definition = try expectDefinition(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 3), definition.term.len);
    try expectBold(definition.term[0], "-v");
    try expectText(definition.term[1], ", ");
    try expectBold(definition.term[2], "--verbose");
    try expectText(definition.description[0], "Enable verbose output");
}

test "parse mixed inline formatting in source order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena, "Use **bold** and *italic* and `code` together.\n");
    try expectNodeCount(doc, 1);

    const spans = try expectParagraph(doc.nodes[0]);
    try testing.expectEqual(@as(usize, 7), spans.len);
    try expectText(spans[0], "Use ");
    try expectBold(spans[1], "bold");
    try expectText(spans[2], " and ");
    try expectItalic(spans[3], "italic");
    try expectText(spans[4], " and ");
    try expectCode(spans[5], "code");
    try expectText(spans[6], " together.");
}

test "parse blank line separates paragraphs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena,
        \\First paragraph.
        \\
        \\Second paragraph.
        \\
    );
    try expectNodeCount(doc, 2);

    const first = try expectParagraph(doc.nodes[0]);
    const second = try expectParagraph(doc.nodes[1]);
    try expectText(first[0], "First paragraph.");
    try expectText(second[0], "Second paragraph.");
}

test "parse full manpage-shaped document structure" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const doc = try parseMarkdown(&arena,
        \\# NAME
        \\
        \\prise - terminal multiplexer
        \\
        \\## SYNOPSIS
        \\
        \\**prise** [*options*] [*command*]
        \\
        \\## OPTIONS
        \\
        \\**-h**, **--help**
        \\:   Show help message
        \\
    );
    try expectNodeCount(doc, 6);
    try expectHeading(doc.nodes[0], 1, "NAME");
    _ = try expectParagraph(doc.nodes[1]);
    try expectHeading(doc.nodes[2], 2, "SYNOPSIS");
    _ = try expectParagraph(doc.nodes[3]);
    try expectHeading(doc.nodes[4], 2, "OPTIONS");
    _ = try expectDefinition(doc.nodes[5]);
}
