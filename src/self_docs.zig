const std = @import("std");
const embedded = @import("self_docs_embedded");
const md = @import("mdman_parser");

pub const SearchHit = struct {
    doc: embedded.Doc,
    heading: []const u8,
    score: usize,
    excerpt: []const u8,
};

pub fn writeTopicList(writer: anytype) !void {
    try writer.writeAll("Zi docs\n\n");
    try writer.writeAll("Usage:\n  zi --man [topic]\n  zi --docs <query>\n\n");
    try writer.writeAll("Topics:\n");
    for (embedded.docs) |doc| {
        try writer.print("  {s:<12} {s}\n", .{ doc.slug, doc.title });
    }
}

pub fn writeMan(writer: anytype, topic: ?[]const u8) !bool {
    const requested = topic orelse {
        try writeTopicList(writer);
        return true;
    };
    const doc = findDoc(requested) orelse return false;
    try writer.writeAll(stripFrontmatter(doc.body));
    if (doc.body.len == 0 or doc.body[doc.body.len - 1] != '\n') try writer.writeByte('\n');
    return true;
}

pub fn writeSearch(allocator: std.mem.Allocator, writer: anytype, query: []const u8) !void {
    const hits = try search(allocator, query, 4);
    defer allocator.free(hits);

    if (hits.len == 0) {
        try writer.print("No zi docs found for \"{s}\".\n\n", .{query});
        try writeTopicList(writer);
        return;
    }

    try writer.print("Found {d} zi doc section{s} for \"{s}\".\n", .{ hits.len, if (hits.len == 1) "" else "s", query });
    for (hits) |hit| {
        try writer.print("\n{s}#{s}\n", .{ hit.doc.path, hit.heading });
        try writer.writeAll(hit.excerpt);
        if (hit.excerpt.len == 0 or hit.excerpt[hit.excerpt.len - 1] != '\n') try writer.writeByte('\n');
    }
}

pub fn search(allocator: std.mem.Allocator, query: []const u8, limit: usize) ![]SearchHit {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var hits: std.ArrayListUnmanaged(SearchHit) = .empty;
    const q = try normalizeAlloc(arena.allocator(), query);

    for (embedded.docs) |doc| {
        const topic_score = topicScore(doc, q);
        const parsed = try md.parse(arena.allocator(), doc.body);
        var current_heading: []const u8 = doc.title;
        var section_buf: std.ArrayListUnmanaged(u8) = .empty;
        defer section_buf.deinit(arena.allocator());

        for (parsed.nodes) |node| {
            switch (node) {
                .heading => |h| {
                    if (section_buf.items.len > 0) {
                        const s = try scoreSection(arena.allocator(), q, doc, current_heading, section_buf.items, topic_score);
                        if (s > 0) try appendHit(allocator, &hits, doc, current_heading, s, section_buf.items);
                        section_buf.clearRetainingCapacity();
                    }
                    current_heading = h.text;
                },
                else => try appendNodeText(arena.allocator(), &section_buf, node),
            }
        }
        if (section_buf.items.len > 0) {
            const s = try scoreSection(arena.allocator(), q, doc, current_heading, section_buf.items, topic_score);
            if (s > 0) try appendHit(allocator, &hits, doc, current_heading, s, section_buf.items);
        }
    }

    std.mem.sort(SearchHit, hits.items, {}, struct {
        fn lessThan(_: void, a: SearchHit, b: SearchHit) bool {
            return a.score > b.score;
        }
    }.lessThan);

    if (hits.items.len > limit) {
        for (hits.items[limit..]) |hit| allocator.free(hit.excerpt);
        hits.shrinkRetainingCapacity(limit);
    }
    return hits.toOwnedSlice(allocator);
}

pub fn freeHits(allocator: std.mem.Allocator, hits: []SearchHit) void {
    for (hits) |hit| allocator.free(hit.excerpt);
    allocator.free(hits);
}

fn appendHit(allocator: std.mem.Allocator, hits: *std.ArrayListUnmanaged(SearchHit), doc: embedded.Doc, heading: []const u8, score: usize, text: []const u8) !void {
    const max_len: usize = 1800;
    const excerpt_src = std.mem.trim(u8, text[0..@min(text.len, max_len)], " \t\r\n");
    const excerpt = try allocator.dupe(u8, excerpt_src);
    try hits.append(allocator, .{ .doc = doc, .heading = heading, .score = score, .excerpt = excerpt });
}

fn topicScore(doc: embedded.Doc, q: []const u8) usize {
    if (std.ascii.eqlIgnoreCase(q, doc.slug)) return 100;
    if (containsIgnoreCase(doc.title, q)) return 80;
    for (doc.aliases) |alias| if (std.ascii.eqlIgnoreCase(alias, q)) return 70;
    return 0;
}

fn scoreSection(allocator: std.mem.Allocator, q: []const u8, doc: embedded.Doc, heading: []const u8, body: []const u8, base: usize) !usize {
    var score = base;
    const h = try normalizeAlloc(allocator, heading);
    const b = try normalizeAlloc(allocator, body);
    if (containsIgnoreCase(h, q)) score += 60;
    if (containsIgnoreCase(b, q)) score += 40;

    var it = std.mem.tokenizeAny(u8, q, " \t\r\n._-/`(){}[]<>,:;\"'");
    var matched: usize = 0;
    while (it.next()) |tok| {
        if (tok.len < 2) continue;
        if (containsIgnoreCase(h, tok)) {
            score += 20;
            matched += 1;
        } else if (containsIgnoreCase(b, tok)) {
            score += 5;
            matched += 1;
        } else if (containsIgnoreCase(doc.slug, tok)) {
            score += 8;
            matched += 1;
        }
    }
    if (matched > 1) score += matched * 6;
    return score;
}

fn normalizeAlloc(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    const out = try allocator.alloc(u8, text.len);
    for (text, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(haystack, needle) != null;
}

fn findDoc(topic: []const u8) ?embedded.Doc {
    for (embedded.docs) |doc| {
        if (std.ascii.eqlIgnoreCase(topic, doc.slug)) return doc;
        for (doc.aliases) |alias| if (std.ascii.eqlIgnoreCase(topic, alias)) return doc;
    }
    return null;
}

fn stripFrontmatter(body: []const u8) []const u8 {
    if (!std.mem.startsWith(u8, body, "---\n") and !std.mem.startsWith(u8, body, "---\r\n")) return body;
    var it = std.mem.splitScalar(u8, body, '\n');
    var offset: usize = 0;
    _ = it.next() orelse return body;
    offset += 4;
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, "\r");
        offset += line_raw.len + 1;
        if (std.mem.eql(u8, line, "---")) return body[@min(offset, body.len)..];
    }
    return body;
}

fn appendNodeText(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), node: md.Node) !void {
    switch (node) {
        .paragraph => |spans| try appendSpans(allocator, out, spans),
        .bullet_list => |items| for (items) |spans| {
            try out.appendSlice(allocator, "- ");
            try appendSpans(allocator, out, spans);
        },
        .definition => |def| {
            try appendSpans(allocator, out, def.term);
            try out.appendSlice(allocator, ": ");
            try appendSpans(allocator, out, def.description);
        },
        .code_block => |code| try out.appendSlice(allocator, code.content),
        .heading => {},
    }
    try out.append(allocator, '\n');
}

fn appendSpans(allocator: std.mem.Allocator, out: *std.ArrayListUnmanaged(u8), spans: []const md.Span) !void {
    for (spans) |span| switch (span) {
        .text, .bold, .italic, .code => |text| try out.appendSlice(allocator, text),
        .link => |link| try out.appendSlice(allocator, link.text),
    };
    try out.append(allocator, '\n');
}
