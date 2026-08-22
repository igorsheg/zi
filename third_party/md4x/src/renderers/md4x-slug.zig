// MD4X: Markdown parser for C
// (https://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
//
// Permission is hereby granted, free of charge, to any person obtaining a
// copy of this software and associated documentation files (the "Software"),
// to deal in the Software without restriction, including without limitation
// the rights to use, copy, modify, merge, publish, distribute, sublicense,
// and/or sell copies of the Software, and to permit persons to whom the
// Software is furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS
// OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
// FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
// IN THE SOFTWARE.
//
// Heading text accumulation + GitHub-compatible slugging, shared by the AST and
// meta renderers.
//
// Both renderers publish heading ids, and they used to have no way to agree:
// the AST built its text from tree nodes (entities unresolved) while meta built
// it from the SAX text stream (entities resolved), so `# A &amp; B` slugged two
// different ways depending on which entry point a consumer called. Everything
// that decides what a heading's id is therefore lives here, is driven from the
// SAX `text` callback in both renderers, and is byte-identical by construction.

const std = @import("std");

const c = @import("abi");
const util = @import("../parser/util.zig");
const entity = @import("../entity.zig");
const props = @import("md4x-props.zig");

/// Accumulated heading text. Owned by the caller's allocator.
pub const TextBuf = std.ArrayListUnmanaged(u8);

const Error = std.mem.Allocator.Error;

/// U+FFFD REPLACEMENT CHARACTER in UTF-8.
const replacement = "\u{FFFD}";

// ============================================================================
// Heading text
// ============================================================================

/// Fold one SAX `text` event into a heading's plain-text form.
///
/// Raw inline HTML is deliberately DROPPED rather than appended. A heading's
/// text is its rendered content, so `## a <b>x</b>` reads "a x" — appending the
/// tag bytes instead put them through the slugger (`a-bxb`) and made the id
/// disagree with what GitHub, and any consumer rendering the same heading,
/// produces. Comments arrive as the same `.html` type and are dropped with them.
pub fn appendText(
    buf: *TextBuf,
    alloc: std.mem.Allocator,
    text_type: c.TextType,
    text: []const u8,
) Error!void {
    switch (text_type) {
        .softbr, .br => try buf.append(alloc, ' '),
        .nullchar => try buf.appendSlice(alloc, replacement),
        .entity => try appendEntity(buf, alloc, text),
        .html => {},
        else => try buf.appendSlice(alloc, text),
    }
}

fn hexVal(ch: u8) u32 {
    if (ch >= '0' and ch <= '9') return ch - '0';
    if (ch >= 'a' and ch <= 'f') return ch - 'a' + 10;
    if (ch >= 'A' and ch <= 'F') return ch - 'A' + 10;
    return 0;
}

/// Longest UTF-8 form an entity can resolve to: a named entity may name two
/// codepoints (`&NotEqualTilde;` → U+2242 U+0338), each up to 4 bytes.
pub const entity_max_len = 8;

/// Resolve an HTML entity (`&amp;`, `&#38;`, `&#x26;`) to its UTF-8 form,
/// written into `out` and returned as a subslice of it. `null` means the entity
/// is not recognized; the parser passes an unknown one through verbatim and so
/// must every caller.
///
/// This mirrors the HTML renderer's `render_entity()` exactly — same numeric
/// parse, same U+FFFD fold for a codepoint that is not a Unicode scalar — so a
/// consumer of any renderer's output reads the same characters. It is public
/// because the AST renderer resolves entities too: a `.entity` text event whose
/// bytes reached the tree as source (`"A &amp; B"`) left the node disagreeing
/// with the `id` slugged from that same text, and forced every consumer that is
/// not md4x's own HTML renderer to reimplement this function.
pub fn resolveEntity(text: []const u8, out: *[entity_max_len]u8) ?[]const u8 {
    var utf8: [4]u8 = undefined;

    if (text.len > 3 and text[1] == '#') {
        var codepoint: u32 = 0;
        if (text[2] == 'x' or text[2] == 'X') {
            for (text[3 .. text.len - 1]) |ch|
                codepoint = 16 *% codepoint +% hexVal(ch);
        } else {
            for (text[2 .. text.len - 1]) |ch|
                codepoint = 10 *% codepoint +% (ch - '0');
        }
        const enc = encodeUtf8(codepoint, &utf8);
        @memcpy(out[0..enc.len], enc);
        return out[0..enc.len];
    }

    if (entity.entity_lookup(text)) |cps| {
        const first = encodeUtf8(cps[0], &utf8);
        @memcpy(out[0..first.len], first);
        var n = first.len;
        if (cps[1] != 0) {
            const second = encodeUtf8(cps[1], &utf8);
            @memcpy(out[n..][0..second.len], second);
            n += second.len;
        }
        return out[0..n];
    }

    return null;
}

/// Resolve an HTML entity to UTF-8 and append it, or append it verbatim when it
/// is not recognized.
fn appendEntity(buf: *TextBuf, alloc: std.mem.Allocator, text: []const u8) Error!void {
    var out: [entity_max_len]u8 = undefined;
    try buf.appendSlice(alloc, resolveEntity(text, &out) orelse text);
}

/// Encode a codepoint as UTF-8 into `out`, returning the written subslice.
/// U+0000, the surrogate range and anything above U+10FFFF are not Unicode
/// scalar values; CommonMark requires them to render as U+FFFD.
fn encodeUtf8(codepoint: u32, out: *[4]u8) []const u8 {
    if (codepoint == 0 or codepoint > 0x10ffff or
        (0xd800 <= codepoint and codepoint <= 0xdfff))
        return replacement;

    const n = std.unicode.utf8Encode(@intCast(codepoint), out) catch return replacement;
    return out[0..n];
}

// ============================================================================
// Explicit ids
// ============================================================================

/// The explicit id from a heading's trailing `{...}` run, if it has one, in
/// either the `#id` shorthand or the `id="..."` key-value spelling. `null` means
/// the heading has no explicit id and the generated slug applies.
///
/// This lives here rather than in each renderer because an explicit id is the
/// *other* half of the "what is this heading's id" question that `slugify`
/// answers. `meta.headings` used to answer it without this half: `## Custom
/// {#my-anchor}` published `my-anchor` from the AST (and from the HTML anchor)
/// but the generated `custom` from meta, so a table of contents built from
/// `parseMeta` linked to a fragment the rendered document does not carry.
///
/// The returned slice borrows `raw_attrs`, which points into the parser's input
/// buffer; a caller that keeps the id past the parse must copy it.
pub fn explicitId(raw_attrs: []const u8) ?[]const u8 {
    if (raw_attrs.len == 0) return null;

    var parsed: props.MD_PARSED_PROPS = .{};
    props.md_parse_props(raw_attrs.ptr, @intCast(raw_attrs.len), &parsed);
    // The shorthand and the key-value spelling both land on the attribute name
    // `id`, so either one has to suppress the generated slug.
    if (!props.parsedHasId(&parsed)) return null;

    if (parsed.id) |p| {
        if (parsed.id_size > 0) return p[0..parsed.id_size];
    }
    var i: usize = 0;
    while (i < @as(usize, @intCast(parsed.n_props))) : (i += 1) {
        const p = &parsed.props[i];
        if (p.key_size == 2 and std.mem.eql(u8, p.key[0..2], "id")) {
            // A valueless `{id}` is a boolean prop: it still occupies the `id`
            // attribute, so it suppresses the slug and contributes nothing.
            const v = p.value orelse return "";
            return v[0..p.value_size];
        }
    }
    return null;
}

// ============================================================================
// Slugging
// ============================================================================

// True for a codepoint `github-slugger` strips outright.
//
// Its removal set is a generated character class covering, in effect:
// C0/C1 controls and DEL, every ASCII punctuation character except `-` and `_`,
// the Unicode punctuation/symbol characters, and the invisible classes — spaces
// (Z*) and format characters (Cf). `md_is_unicode_punct` is CommonMark's P+S
// definition, which the parser already carries for emphasis flanking; the
// invisible classes are handled separately below.
//
// The two invisible classes matter more than they look. Format characters put
// U+200D ZERO WIDTH JOINER into ids for any multi-part emoji (`:family_...:`,
// `:man_technologist:` — roughly a third of `src/emoji.zig` contains one), plus
// U+FEFF BOM and the U+202x bidi overrides. Unicode spaces put a literal
// U+3000 IDEOGRAPHIC SPACE and friends there. Both yield ids that cannot be
// typed into a URL fragment, so neither may survive into an anchor.
//
// U+0020 never reaches this function: the caller turns it into `-` first.
fn isStripped(codepoint: u32) bool {
    if (codepoint < 0x20 or codepoint == 0x7f) return true;
    if (codepoint >= 0x80 and codepoint <= 0x9f) return true;
    // Kept by `github-slugger` even though both are Unicode punctuation.
    if (codepoint == '-' or codepoint == '_') return false;
    // Z* — U+00A0 included, which is whitespace rather than punctuation.
    if (util.md_is_unicode_whitespace(codepoint)) return true;
    if (isFormatChar(codepoint)) return true;
    return util.md_is_unicode_punct(codepoint);
}

// The Unicode `Cf` (format) general category: zero-width and directionality
// controls that carry no visible text and must never reach an id.
fn isFormatChar(codepoint: u32) bool {
    return switch (codepoint) {
        0x00ad, // SOFT HYPHEN
        0x0600...0x0605, // ARABIC NUMBER SIGN..ARABIC NUMBER MARK ABOVE
        0x061c, // ARABIC LETTER MARK
        0x06dd, // ARABIC END OF AYAH
        0x070f, // SYRIAC ABBREVIATION MARK
        0x0890...0x0891, // ARABIC POUND/PIASTRE MARK ABOVE
        0x08e2, // ARABIC DISPUTED END OF AYAH
        0x180e, // MONGOLIAN VOWEL SEPARATOR
        0x200b...0x200f, // ZWSP, ZWNJ, ZWJ, LRM, RLM
        0x202a...0x202e, // LRE, RLE, PDF, LRO, RLO
        0x2060...0x2064, // WORD JOINER..INVISIBLE PLUS
        0x2066...0x206f, // LRI..NOMINAL DIGIT SHAPES
        0xfeff, // ZERO WIDTH NO-BREAK SPACE (BOM)
        0xfff9...0xfffb, // INTERLINEAR ANNOTATION ANCHOR..TERMINATOR
        0x110bd, // KAITHI NUMBER SIGN
        0x110cd, // KAITHI NUMBER SIGN ABOVE
        0x13430...0x1343f, // EGYPTIAN HIEROGLYPH FORMAT CONTROLS
        0x1bca0...0x1bca3, // SHORTHAND FORMAT CONTROLS
        0x1d173...0x1d17a, // MUSICAL SYMBOL BEGIN BEAM..END PHRASE
        0xe0001, // LANGUAGE TAG
        0xe0020...0xe007f, // TAG CHARACTERS
        => true,
        else => false,
    };
}

/// Slugify heading text the way `github-slugger` does: case-fold, strip the
/// punctuation/control set above, and turn each space into `-`. Runs are NOT
/// collapsed and the result is NOT trimmed — `"a  b"` slugs to `"a--b"` — which
/// is the behavior GitHub's anchors have, not an oversight.
///
/// Case *folding* rather than lowercasing is the one deliberate divergence: the
/// parser's fold tables are what this build ships, and the two differ only for a
/// handful of codepoints (`ß` folds to `ss`, `İ` to `i` + U+0307). The result is
/// self-consistent across every md4x entry point either way.
pub fn slugify(alloc: std.mem.Allocator, text: []const u8) Error![]u8 {
    var out: TextBuf = .empty;
    errdefer out.deinit(alloc);
    try out.ensureTotalCapacity(alloc, text.len);

    var fold: util.MD_UNICODE_FOLD_INFO = .{};
    var buf: [4]u8 = undefined;
    var off: usize = 0;
    while (off < text.len) {
        var char_size: c.MD_SIZE = 1;
        const codepoint = util.md_decode_utf8(text.ptr + off, @intCast(text.len - off), &char_size);
        off += char_size;

        if (codepoint == ' ') {
            try out.append(alloc, '-');
            continue;
        }
        if (isStripped(codepoint)) continue;

        util.md_get_unicode_fold_info(codepoint, &fold);
        for (fold.codepoints[0..fold.n_codepoints]) |cp|
            try out.appendSlice(alloc, encodeUtf8(cp, &buf));
    }

    return out.toOwnedSlice(alloc);
}

/// Disambiguates repeated slugs within one document, mirroring the stateful
/// `github-slugger` instance: the first `## Same` keeps `same`, the next takes
/// `same-1`, and a heading whose own slug is already `same-1` becomes
/// `same-1-1`. Without this the second link in a table of contents is dead.
///
/// Both the keys and the returned slugs are allocated from `alloc` and live as
/// long as it does; the caller must not free an individual slug.
pub const Slugger = struct {
    /// Slug -> number of extra headings that have collided with it.
    occurrences: std.StringHashMapUnmanaged(u32) = .empty,

    pub fn deinit(self: *Slugger, alloc: std.mem.Allocator) void {
        self.occurrences.deinit(alloc);
    }

    /// Slugify `text` and make the result unique within this document.
    pub fn slug(self: *Slugger, alloc: std.mem.Allocator, text: []const u8) Error![]const u8 {
        const base = try slugify(alloc, text);
        // A heading with no sluggable text (`#`, `## `, `### ###`) has no id to
        // publish. Returning it unregistered keeps every such heading id-less,
        // rather than numbering the second one `-1` off an empty base.
        if (base.len == 0) return base;
        var result: []const u8 = base;
        while (self.occurrences.contains(result)) {
            // The counter tracked is always the *base* slug's, so a run of N
            // identical headings numbers 1..N-1 rather than restarting.
            const counter = self.occurrences.getPtr(base).?;
            counter.* += 1;
            result = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, counter.* });
        }
        try self.occurrences.put(alloc, result, 0);
        return result;
    }
};

// ============================================================================
// Tests
// ============================================================================

const testing = std.testing;

fn expectSlug(expected: []const u8, input: []const u8) !void {
    const got = try slugify(testing.allocator, input);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "slugify matches github-slugger" {
    try expectSlug("hello-world", "Hello World");
    try expectSlug("hello-world", "Hello, World!");
    try expectSlug("c", "C++");
    try expectSlug("a--b", "a  b");
    try expectSlug("héllo-wörld", "Héllo Wörld!");
    try expectSlug("äöü", "ÄÖÜ");
    try expectSlug("snake_case-and-kebab-case", "snake_case and kebab-case");
    try expectSlug("", "!!!");
    // U+00A0 is stripped, not turned into a separator: `github-slugger`
    // replaces only U+0020.
    try expectSlug("ab", "a\u{00A0}b");
    // Symbols go, but the spaces that flanked them still become separators.
    try expectSlug("math---x", "math × ÷ x");
}

test "Slugger disambiguates collisions" {
    var s: Slugger = .{};
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    defer s.deinit(alloc);

    try testing.expectEqualStrings("same", try s.slug(alloc, "Same"));
    try testing.expectEqualStrings("same-1", try s.slug(alloc, "Same"));
    try testing.expectEqualStrings("same-2", try s.slug(alloc, "Same"));
    // A heading that literally spells the disambiguated form takes the next
    // free name rather than stealing one already handed out.
    try testing.expectEqualStrings("same-1-1", try s.slug(alloc, "Same 1"));
    try testing.expectEqualStrings("other", try s.slug(alloc, "Other"));
}

test "explicitId reads both spellings" {
    try testing.expectEqualStrings("my-anchor", explicitId("#my-anchor").?);
    try testing.expectEqualStrings("kv-id", explicitId("id=\"kv-id\"").?);
    try testing.expectEqualStrings("x", explicitId(".cls #x data-a=\"b\"").?);
    // A valueless `{id}` still occupies the attribute, so it suppresses the
    // generated slug while contributing nothing.
    try testing.expectEqualStrings("", explicitId("id").?);
    // No id in the run: the generated slug applies.
    try testing.expect(explicitId("") == null);
    try testing.expect(explicitId(".cls") == null);
    try testing.expect(explicitId("#") == null);
}

test "appendText resolves entities and drops raw HTML" {
    var buf: TextBuf = .empty;
    defer buf.deinit(testing.allocator);

    try appendText(&buf, testing.allocator, .normal, "A ");
    try appendText(&buf, testing.allocator, .entity, "&amp;");
    try appendText(&buf, testing.allocator, .normal, " ");
    try appendText(&buf, testing.allocator, .html, "<b>");
    try appendText(&buf, testing.allocator, .normal, "B");
    try appendText(&buf, testing.allocator, .html, "</b>");
    try appendText(&buf, testing.allocator, .softbr, "\n");
    try appendText(&buf, testing.allocator, .entity, "&#x1F600;");

    try testing.expectEqualStrings("A & B \u{1F600}", buf.items);
}

test "resolveEntity covers every spelling the AST renderer feeds it" {
    var out: [entity_max_len]u8 = undefined;

    try testing.expectEqualStrings("&", resolveEntity("&amp;", &out).?);
    try testing.expectEqualStrings("&", resolveEntity("&#38;", &out).?);
    try testing.expectEqualStrings("&", resolveEntity("&#x26;", &out).?);
    try testing.expectEqualStrings("&", resolveEntity("&#X26;", &out).?);
    try testing.expectEqualStrings("—", resolveEntity("&mdash;", &out).?);

    // A named entity may resolve to TWO codepoints; the buffer is sized for it.
    try testing.expectEqualStrings("\u{2242}\u{0338}", resolveEntity("&NotEqualTilde;", &out).?);

    // Not a Unicode scalar value -> U+FFFD, matching the HTML renderer.
    try testing.expectEqualStrings(replacement, resolveEntity("&#0;", &out).?);
    try testing.expectEqualStrings(replacement, resolveEntity("&#xD800;", &out).?);
    try testing.expectEqualStrings(replacement, resolveEntity("&#x110000;", &out).?);

    // Named lookup is case-SENSITIVE: `&AMP;` is its own HTML5 entity, `&Amp;`
    // is not one at all.
    try testing.expectEqualStrings("&", resolveEntity("&AMP;", &out).?);
    try testing.expect(resolveEntity("&Amp;", &out) == null);

    // Unrecognized: null, so the caller keeps the source spelling.
    try testing.expect(resolveEntity("&nosuchentity;", &out) == null);
}
