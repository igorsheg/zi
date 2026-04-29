//! HTML output renderer.

const std = @import("std");
const parser = @import("parser.zig");
const Node = parser.Node;
const Span = parser.Span;
const Document = parser.Document;

pub const Options = struct {
    fragment: bool = false,
    page_label: []const u8 = "ZI(1)",
    page_title: []const u8 = "zi manual",
    prev_label: ?[]const u8 = null,
    prev_url: ?[]const u8 = null,
    next_label: ?[]const u8 = null,
    next_url: ?[]const u8 = null,
    markdown_url: ?[]const u8 = null,
};

/// Render a Document to HTML format.
/// All allocations use the provided allocator (typically an arena).
pub fn render(allocator: std.mem.Allocator, doc: Document, title: []const u8, options: Options) ![]const u8 {
    var buffer: std.ArrayListUnmanaged(u8) = .empty;
    const writer = buffer.writer(allocator);

    if (!options.fragment) {
        try writer.print(
            \\<!DOCTYPE html>
            \\<html>
            \\<head>
            \\  <meta charset="utf-8">
            \\  <title>{s}</title>
            \\  <style>
            \\    body {{ font-family: system-ui, sans-serif; max-width: 800px; margin: 2rem auto; padding: 0 1rem; }}
            \\    pre {{ background: #f5f5f5; padding: 1rem; overflow-x: auto; }}
            \\    code {{ background: #f5f5f5; padding: 0.2rem 0.4rem; }}
            \\    dt {{ font-weight: bold; margin-top: 1rem; }}
            \\    dd {{ margin-left: 2rem; }}
            \\  </style>
            \\</head>
            \\<body>
            \\
        , .{title});
    }

    try writer.writeAll("<div class=\"manual-mast\"><span aria-hidden=\"true\">");
    try escapeAndWrite(writer, options.page_label);
    try writer.writeAll("</span><span aria-hidden=\"true\">");
    try escapeAndWrite(writer, options.page_title);
    try writer.writeAll("</span><span class=\"manual-view\"><span aria-hidden=\"true\">");
    try escapeAndWrite(writer, options.page_label);
    try writer.writeAll("</span>");
    if (options.markdown_url) |url| {
        try writer.writeAll("<a href=\"");
        try escapeAndWrite(writer, url);
        try writer.writeAll("\">md</a>");
    }
    try writer.writeAll("</span></div>\n");

    try writer.writeAll("<div class=\"manual-layout\">\n<article class=\"manual-prose\">\n");
    for (doc.nodes) |node| {
        try renderNode(writer, node);
    }
    try renderPager(writer, options);
    try writer.writeAll("</article>\n");
    try renderToc(writer, doc);
    try writer.writeAll("</div>\n");

    if (!options.fragment) {
        try writer.writeAll("</body>\n</html>\n");
    }

    return buffer.toOwnedSlice(allocator);
}

fn renderNode(writer: anytype, node: Node) !void {
    switch (node) {
        .heading => |h| {
            const tag = if (h.level == 1) "h1" else "h2";
            const id = slugify(h.text);
            try writer.print("<{s} id=\"{s}\"><a class=\"manual-anchor\" href=\"#{s}\">", .{ tag, id, id });
            try escapeAndWrite(writer, h.text);
            try writer.print("<span aria-hidden=\"true\">#</span></a></{s}>\n", .{tag});
        },
        .paragraph => |spans| {
            try writer.writeAll("<p>");
            try renderSpans(writer, spans);
            try writer.writeAll("</p>\n");
        },
        .code_block => |cb| {
            if (cb.language) |lang| {
                try writer.writeAll("<figure class=\"manual-code\"><figcaption>");
                try escapeAndWrite(writer, lang);
                try writer.print("</figcaption><pre><code class=\"language-{s}\">", .{lang});
            } else {
                try writer.writeAll("<figure class=\"manual-code\"><pre><code>");
            }
            try escapeAndWrite(writer, cb.content);
            try writer.writeAll("</code></pre></figure>\n");
        },
        .bullet_list => |items| {
            try writer.writeAll("<ul>\n");
            for (items) |item| {
                try writer.writeAll("  <li>");
                try renderSpans(writer, item);
                try writer.writeAll("</li>\n");
            }
            try writer.writeAll("</ul>\n");
        },
        .definition => |def| {
            try writer.writeAll("<dl>\n  <dt>");
            try renderSpans(writer, def.term);
            try writer.writeAll("</dt>\n  <dd>");
            try renderSpans(writer, def.description);
            try writer.writeAll("</dd>\n</dl>\n");
        },
    }
}

fn renderToc(writer: anytype, doc: Document) !void {
    try writer.writeAll("<aside class=\"manual-toc\" aria-label=\"page contents\"><p>on this page</p><ol>\n");
    for (doc.nodes) |node| {
        if (node == .heading and node.heading.level > 1) {
            const id = slugify(node.heading.text);
            try writer.print("<li><a href=\"#{s}\">", .{id});
            try escapeAndWrite(writer, node.heading.text);
            try writer.writeAll("</a></li>\n");
        }
    }
    try writer.writeAll("</ol></aside>\n");
}

fn renderPager(writer: anytype, options: Options) !void {
    if (options.prev_label == null and options.next_label == null) return;

    try writer.writeAll("<nav class=\"manual-pager\" aria-label=\"manual pages\">\n");
    if (options.prev_label) |label| {
        if (options.prev_url) |url| {
            try writer.writeAll("<a class=\"manual-pager-prev\" href=\"");
            try escapeAndWrite(writer, url);
            try writer.writeAll("\"><span>previous</span>");
            try escapeAndWrite(writer, label);
            try writer.writeAll("</a>\n");
        }
    }
    if (options.next_label) |label| {
        if (options.next_url) |url| {
            try writer.writeAll("<a class=\"manual-pager-next\" href=\"");
            try escapeAndWrite(writer, url);
            try writer.writeAll("\"><span>next</span>");
            try escapeAndWrite(writer, label);
            try writer.writeAll("</a>\n");
        }
    }
    try writer.writeAll("</nav>\n");
}

fn renderSpans(writer: anytype, spans: []const Span) !void {
    for (spans) |span| {
        switch (span) {
            .text => |t| try escapeAndWrite(writer, t),
            .bold => |t| {
                try writer.writeAll("<strong>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</strong>");
            },
            .italic => |t| {
                try writer.writeAll("<em>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</em>");
            },
            .code => |t| {
                try writer.writeAll("<code>");
                try escapeAndWrite(writer, t);
                try writer.writeAll("</code>");
            },
            .link => |l| {
                try writer.writeAll("<a href=\"");
                try escapeAndWrite(writer, l.url);
                try writer.writeAll("\">");
                try escapeAndWrite(writer, l.text);
                try writer.writeAll("</a>");
            },
        }
    }
}

fn escapeAndWrite(writer: anytype, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try writer.writeAll("&lt;"),
            '>' => try writer.writeAll("&gt;"),
            '&' => try writer.writeAll("&amp;"),
            '"' => try writer.writeAll("&quot;"),
            else => try writer.writeByte(c),
        }
    }
}

fn slugify(text: []const u8) []const u8 {
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    var len: usize = 0;

    for (text) |c| {
        if (len >= S.buf.len) break;
        if (c >= 'A' and c <= 'Z') {
            S.buf[len] = c + 32;
            len += 1;
        } else if ((c >= 'a' and c <= 'z') or (c >= '0' and c <= '9')) {
            S.buf[len] = c;
            len += 1;
        } else if (c == ' ' or c == '-' or c == '_') {
            if (len > 0 and S.buf[len - 1] != '-') {
                S.buf[len] = '-';
                len += 1;
            }
        }
    }

    while (len > 0 and S.buf[len - 1] == '-') len -= 1;

    return S.buf[0..len];
}
