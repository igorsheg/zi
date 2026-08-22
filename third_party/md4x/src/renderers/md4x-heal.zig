// MD4X: Markdown parser for C
// (https://github.com/unjs/md4x)
//
// Copyright (c) 2026 Pooya Parsa <pooya@pi0.io>
//
// Based on logic from https://github.com/vercel/streamdown/tree/main/packages/remend
// Written by Hayden Bleasel <https://github.com/haydenbleasel>
// Copyright (c) 2023 Vercel Inc.
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
// Zig port of src/renderers/md4x-heal.c — byte-for-byte identical behavior.

const std = @import("std");

const c_allocator = std.heap.c_allocator;

// The original C uses `char` (signed on most platforms). We mirror its
// comparisons faithfully. Since all comparisons in the C code are either
// against ASCII literals (positive) or use is_word_char-style ranges, the
// signedness of `char` does not change any branch outcome here. We store
// bytes as u8 and compare against u8 literals.

// ***************************
// ***  Growable buffer    ***
// ***************************

const HEAL_BUF = struct {
    data: ?[*]u8,
    size: u32,
    cap: u32,
    err: c_int,
};

fn buf_init(buf: *HEAL_BUF, initial_cap: u32) void {
    // malloc(initial_cap). C malloc(0) may return NULL or a valid pointer;
    // initial_cap here is always input_size + 64 >= 64, so non-zero.
    const mem = c_allocator.alloc(u8, initial_cap) catch {
        buf.data = null;
        buf.size = 0;
        buf.cap = 0;
        buf.err = 0;
        return;
    };
    buf.data = mem.ptr;
    buf.size = 0;
    buf.cap = initial_cap;
    buf.err = 0;
}

fn buf_append(buf: *HEAL_BUF, s: [*]const u8, len: u32) void {
    if (len == 0 or buf.err != 0) return;
    // `+%` here used to DEFINE the wrap it was supposed to guard against: once
    // `size + len` passed 2^32 the test read false, no realloc happened, and the
    // @memcpy below wrote past the end of a buffer that was never grown — a plain
    // heap overflow, well-defined even in ReleaseSafe. Fail instead: `err` is
    // what md_heal already turns into a clean -1.
    const needed: u32 = std.math.add(u32, buf.size, len) catch {
        buf.err = 1;
        return;
    };
    if (needed > buf.cap) {
        // Saturating so the 1.5x step cannot wrap; @max so a saturated-but-short
        // step still covers the demand.
        const new_cap: u32 = @max(buf.cap +| buf.cap / 2 +| len +| 64, needed);
        const old = buf.data.?[0..buf.cap];
        const p = c_allocator.realloc(old, new_cap) catch {
            buf.err = 1;
            return;
        };
        buf.data = p.ptr;
        buf.cap = new_cap;
    }
    const dst = buf.data.? + buf.size;
    @memcpy(dst[0..len], s[0..len]);
    buf.size = needed;
}

fn buf_append_ch(buf: *HEAL_BUF, c: u8) void {
    var ch = c;
    buf_append(buf, @ptrCast(&ch), 1);
}

fn buf_free(buf: *HEAL_BUF) void {
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
}

// ***************************
// ***  Utility helpers    ***
// ***************************

fn is_word_char(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
        (c >= '0' and c <= '9') or c == '_';
}

fn is_escaped(text: [*]const u8, pos_in: u32) bool {
    var n: u32 = 0;
    var pos = pos_in;
    while (pos > 0 and text[pos - 1] == '\\') {
        n +%= 1;
        pos -%= 1;
    }
    return (n % 2) != 0;
}

// Check if position i is part of a ``` sequence
fn is_triple_backtick(text: [*]const u8, size: u32, i: u32) bool {
    if (i + 2 < size and text[i] == '`' and text[i + 1] == '`' and text[i + 2] == '`')
        return true;
    if (i >= 1 and i + 1 < size and text[i - 1] == '`' and text[i] == '`' and text[i + 1] == '`')
        return true;
    if (i >= 2 and text[i - 2] == '`' and text[i - 1] == '`' and text[i] == '`')
        return true;
    return false;
}

// Find the start of the current line (returns index after preceding newline)
fn line_start(text: [*]const u8, pos_in: u32) u32 {
    var pos = pos_in;
    while (pos > 0 and text[pos - 1] != '\n')
        pos -%= 1;
    return pos;
}

// Find the end of the current line (returns index of newline or size)
fn line_end(text: [*]const u8, size: u32, pos_in: u32) u32 {
    var pos = pos_in;
    while (pos < size and text[pos] != '\n')
        pos +%= 1;
    return pos;
}

// Check if a line is a horizontal rule (3+ of same marker with only whitespace)
fn is_horizontal_rule(text: [*]const u8, size: u32, marker_pos: u32, marker: u8) bool {
    const ls = line_start(text, marker_pos);
    const le = line_end(text, size, marker_pos);
    var count: u32 = 0;
    var i: u32 = ls;
    while (i < le) : (i +%= 1) {
        if (text[i] == marker) {
            count +%= 1;
        } else if (text[i] != ' ' and text[i] != '\t') {
            return false;
        }
    }
    return count >= 3;
}

// ***************************
// ***  Context tracking   ***
// ***************************

fn in_fenced_code_block(text: [*]const u8, size: u32, pos: u32) bool {
    _ = size;
    var inside = false;
    var i: u32 = 0;
    while (i < pos) {
        if (text[i] == '`' and i + 2 < pos and text[i + 1] == '`' and text[i + 2] == '`') {
            if (!is_escaped(text, i))
                inside = !inside;
            i +%= 3;
            while (i < pos and text[i] != '\n') i +%= 1;
        } else {
            i +%= 1;
        }
    }
    return inside;
}

fn count_fences(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < size) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            if (!is_escaped(text, i))
                count +%= 1;
            i +%= 3;
            while (i < size and text[i] == '`') i +%= 1;
        } else {
            i +%= 1;
        }
    }
    return count;
}

fn count_single_backticks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and !is_escaped(text, i) and !is_triple_backtick(text, size, i))
            count +%= 1;
    }
    return count;
}

fn in_complete_inline_code(text: [*]const u8, size: u32, pos: u32) bool {
    var i: u32 = 0;
    var in_code: bool = false;
    var code_start: u32 = 0;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and !is_escaped(text, i) and !is_triple_backtick(text, size, i)) {
            if (!in_code) {
                in_code = true;
                code_start = i;
            } else {
                if (pos > code_start and pos < i)
                    return true;
                in_code = false;
            }
        }
    }
    return false;
}

// "Is `pos` inside a `$`/`$$` math span?" — as a **resumable** cursor rather
// than a function that answers from scratch.
//
// This used to be `in_math_block(text, size, pos)`, which restarted its scan at
// offset 0 on every call. Its callers ask once per candidate marker while
// walking the document forward, so the pair was O(n^2): a heal of a 565 KB
// document cost 10.9 billion instructions (~400x an HTML render of the same
// file, 72% of it in `count_single_asterisks` alone), and a document of `'*a '`
// repeats grew 4x per doubling — 240 KB took 4.2 s, with ~1 MB extrapolating
// past a minute. Since `heal()` is exported to both JS bindings and `--heal`
// applies to every renderer, that was reachable from untrusted input.
//
// The loop body below is the original verbatim, with `i` promoted to a field so
// the scan resumes where it left off. That is exact, not approximate, **as long
// as the queried positions never decrease** — which is why `at()` is documented
// as requiring that, and why both call sites drive it from their own forward
// loop index. Total cost across a whole pass is now O(n).
const MathScanner = struct {
    text: [*]const u8,
    size: u32,
    i: u32 = 0,
    in_block: bool = false,
    in_inline: bool = false,

    fn init(text: [*]const u8, size: u32) MathScanner {
        return .{ .text = text, .size = size };
    }

    /// Equivalent to the old `in_math_block(text, size, pos)`.
    /// `pos` must be >= every `pos` previously passed to this instance.
    fn at(self: *MathScanner, pos: u32) bool {
        while (self.i < self.size and self.i < pos) : (self.i +%= 1) {
            if (self.text[self.i] == '\\') {
                self.i +%= 1;
                continue;
            }
            if (self.text[self.i] == '$') {
                if (self.i + 1 < self.size and self.text[self.i + 1] == '$') {
                    self.in_block = !self.in_block;
                    self.i +%= 1;
                } else if (!self.in_block) {
                    self.in_inline = !self.in_inline;
                }
            }
        }
        return self.in_block or self.in_inline;
    }
};

// "Is `pos` inside a `](url)` destination, or inside an HTML tag?" — the
// forward-cursor form of the former `in_link_url` / `in_html_tag`.
//
// Those two walked **backward** from `pos` until they met a delimiter, which
// reads as bounded by the line length — and is, right up until the input has no
// newlines. Then each walk runs back to offset 0 and the caller
// (`count_single_underscores`, which queries both once per `_`) is O(n^2) all
// over again: 240 KB of `'_a '` repeats took 13 s. Fixing only the math scanner
// left this one, which is why the underscore case barely improved at first.
//
// Both predicates depend on nothing but the **nearest preceding delimiter**, so
// tracking that as we sweep forward answers each query in O(1) with no change
// in meaning. Like MathScanner, this is exact only for non-decreasing `pos`.
const LineContextScanner = struct {
    text: [*]const u8,
    i: u32 = 0,
    // Nearest preceding member of {'\n', '(', ')'} and of {'\n', '>', '<'}.
    // `ch == 0` means "none seen yet", which no branch below treats as a hit.
    link_ch: u8 = 0,
    link_idx: u32 = 0,
    html_ch: u8 = 0,
    html_idx: u32 = 0,

    fn init(text: [*]const u8) LineContextScanner {
        return .{ .text = text };
    }

    fn advance(self: *LineContextScanner, pos: u32) void {
        while (self.i < pos) : (self.i +%= 1) {
            switch (self.text[self.i]) {
                '\n' => {
                    self.link_ch = '\n';
                    self.link_idx = self.i;
                    self.html_ch = '\n';
                    self.html_idx = self.i;
                },
                '(', ')' => {
                    self.link_ch = self.text[self.i];
                    self.link_idx = self.i;
                },
                '<', '>' => {
                    self.html_ch = self.text[self.i];
                    self.html_idx = self.i;
                },
                else => {},
            }
        }
    }

    /// Equivalent to the old `in_link_url(text, pos)`.
    fn inLinkUrl(self: *LineContextScanner, pos: u32) bool {
        if (pos == 0) return false;
        self.advance(pos);
        // Nearest delimiter must be '(' — a '\n' or ')' terminates the scan
        // with false, exactly as the backward walk did.
        if (self.link_ch != '(') return false;
        const j = self.link_idx;
        return j >= 1 and self.text[j - 1] == ']';
    }

    /// Equivalent to the old `in_html_tag(text, pos)`.
    fn inHtmlTag(self: *LineContextScanner, pos: u32) bool {
        if (pos == 0) return false;
        self.advance(pos);
        if (self.html_ch != '<') return false;
        const j = self.html_idx;
        // The original's `if (i < pos)`: a '<' sitting immediately before `pos`
        // has no character after it to classify, so it is not a tag.
        if (j + 1 >= pos) return false;
        const next = self.text[j + 1];
        return (next >= 'a' and next <= 'z') or
            (next >= 'A' and next <= 'Z') or next == '/';
    }
};

// "Is `pos` inside an unterminated ``` fence?" — the resumable form of
// `in_fenced_code_block`, for the one caller that asks repeatedly.
//
// `heal_comparison_operators` queries it once per `- > 5`-shaped list line
// while sweeping forward, and `in_fenced_code_block` restarts at offset 0 every
// time, so the pair was O(n^2): 400 KB of `'- > 5\n'` repeats took 10.3 s and
// grew 4x per doubling. Every other caller asks exactly once, so they keep
// using the plain function.
//
// The loop body is the original's, with `i` promoted to a field. Two details of
// the original are region-bounded rather than prefix-pure, and both are carried
// in state instead:
//
//   * the fence test is `i + 2 < pos`, i.e. "the ``` fits entirely inside
//     [0, pos)". A backtick within two bytes of `pos` is therefore undecided —
//     it may start a fence once the region grows — so the cursor stops in front
//     of it rather than consuming it. That cannot change the answer for `pos`:
//     the original steps over those bytes with its else branch, which touches
//     no state.
//   * the "skip to the end of the fence line" inner loop is also bounded by
//     `pos`, so it can be left unfinished. `skipping` records that and the next
//     query resumes inside it.
//
// Everything the cursor does commit is region-independent, so resuming is exact
// rather than approximate — provided the queried positions never decrease and
// `text[0..pos]` never changes after being queried. The caller guarantees both:
// it appends its output and queries at its own append cursor.
const FenceScanner = struct {
    i: u32 = 0,
    inside: bool = false,
    skipping: bool = false,

    /// Equivalent to `in_fenced_code_block(text, _, pos)`.
    /// `pos` must be >= every `pos` previously passed to this instance.
    fn at(self: *FenceScanner, text: [*]const u8, pos: u32) bool {
        while (self.i < pos) {
            const c = text[self.i];
            if (self.skipping) {
                if (c != '\n') {
                    self.i +%= 1;
                    continue;
                }
                // The original's skip loop stops *at* the newline; the outer
                // loop then steps over it below.
                self.skipping = false;
            }
            if (c == '`') {
                if (self.i + 2 >= pos) break;
                if (text[self.i + 1] == '`' and text[self.i + 2] == '`') {
                    if (!is_escaped(text, self.i))
                        self.inside = !self.inside;
                    self.i +%= 3;
                    self.skipping = true;
                    continue;
                }
            }
            self.i +%= 1;
        }
        return self.inside;
    }
};

// ***************************
// ***  Setext headings    ***
// ***************************

fn heal_setext_heading(buf: *HEAL_BUF) void {
    if (buf.size == 0) return;
    const data = buf.data.?;

    const le: u32 = buf.size;
    var ls: u32 = le;
    while (ls > 0 and data[ls - 1] != '\n') ls -%= 1;

    if (le - ls < 1 or le - ls > 2) return;
    const marker = data[ls];
    if (marker != '-' and marker != '=') return;
    var count: c_int = 1;
    var i: u32 = ls + 1;
    while (i < le) : (i +%= 1) {
        if (data[i] != marker) return;
        count += 1;
    }
    if (count > 2) return;

    if (ls == 0) return;
    const prev_le: u32 = ls - 1;
    if (prev_le == 0) return;
    i = prev_le;
    while (i > 0 and data[i - 1] != '\n') i -%= 1;
    if (i == prev_le) return;

    buf_append(buf, "\xE2\x80\x8B", 3);
}

// ***************************
// ***  Code block heal    ***
// ***************************

fn heal_code_block(buf: *HEAL_BUF) void {
    const fences = count_fences(buf.data.?, buf.size);
    if (fences % 2 != 0) {
        if (buf.size > 0 and buf.data.?[buf.size - 1] != '\n')
            buf_append_ch(buf, '\n');
        buf_append(buf, "```", 3);
    }
}

// ***************************
// ***  Inline code heal   ***
// ***************************

fn heal_inline_code(buf: *HEAL_BUF) void {
    const fences = count_fences(buf.data.?, buf.size);
    if (fences % 2 != 0) return;

    const singles = count_single_backticks(buf.data.?, buf.size);
    if (singles % 2 != 0) {
        buf_append_ch(buf, '`');
    }
}

// ***************************
// ***  Emphasis healing   ***
// ***************************

fn count_double_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '*' and i + 1 < size and text[i + 1] == '*') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_double_underscores(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '_' and i + 1 < size and text[i + 1] == '_') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_triple_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var consecutive: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            if (consecutive >= 3) count +%= consecutive / 3;
            consecutive = 0;
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '*') {
            consecutive +%= 1;
        } else {
            if (consecutive >= 3) count +%= consecutive / 3;
            consecutive = 0;
        }
    }
    if (consecutive >= 3) count +%= consecutive / 3;
    return count;
}

fn count_single_asterisks(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    var math = MathScanner.init(text, size);
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] != '*') continue;

        const prev: u8 = if (i > 0) text[i - 1] else 0;
        const next: u8 = if (i + 1 < size) text[i + 1] else 0;

        if (prev == '\\') continue;
        if (math.at(i)) continue;

        if (prev != '*' and next == '*') {
            const next2: u8 = if (i + 2 < size) text[i + 2] else 0;
            if (next2 == '*') {
                count +%= 1;
                continue;
            }
            continue;
        }
        if (prev == '*') continue;

        if (is_word_char(prev) and is_word_char(next)) continue;

        {
            const prev_ws = (prev == 0 or prev == ' ' or prev == '\t' or prev == '\n');
            const next_ws = (next == 0 or next == ' ' or next == '\t' or next == '\n');
            if (prev_ws and next_ws) continue;
        }

        count +%= 1;
    }
    return count;
}

fn count_single_underscores(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    var math = MathScanner.init(text, size);
    var lctx = LineContextScanner.init(text);
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] != '_') continue;

        const prev: u8 = if (i > 0) text[i - 1] else 0;
        const next: u8 = if (i + 1 < size) text[i + 1] else 0;

        if (prev == '\\') continue;
        if (math.at(i)) continue;
        if (lctx.inLinkUrl(i)) continue;
        if (lctx.inHtmlTag(i)) continue;
        if (prev == '_' or next == '_') continue;
        if (is_word_char(prev) and is_word_char(next)) continue;

        count +%= 1;
    }
    return count;
}

fn count_double_tildes(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '~' and i + 1 < size and text[i + 1] == '~') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn count_double_dollars(text: [*]const u8, size: u32) u32 {
    var count: u32 = 0;
    var i: u32 = 0;
    var in_code: bool = false;
    while (i < size) : (i +%= 1) {
        if (text[i] == '`' and i + 2 < size and text[i + 1] == '`' and text[i + 2] == '`') {
            in_code = !in_code;
            i +%= 2;
            continue;
        }
        if (in_code) continue;
        if (text[i] == '$' and i + 1 < size and text[i + 1] == '$') {
            count +%= 1;
            i +%= 1;
        }
    }
    return count;
}

fn is_meaningful_char(c: u8) bool {
    return c != ' ' and c != '\t' and c != '\n' and c != '\r' and
        c != '*' and c != '_' and c != '~' and c != '`';
}

fn has_meaningful_content(text: [*]const u8, start: u32, end: u32) bool {
    var i: u32 = start;
    while (i < end) : (i +%= 1) {
        if (is_meaningful_char(text[i]))
            return true;
    }
    return false;
}

// Index of the last meaningful byte in `text[0..end)`, or null when there is
// none — i.e. the single number that answers `has_meaningful_content(text,
// start, end)` for **every** `start`, as `last >= start`.
//
// The predicate is monotone in `start` for a fixed `end`: widening the range
// leftward can only add candidates. `heal_strikethrough`'s two descending loops
// each hold `end` fixed and let `start` fall, so each of them asked the same
// monotone question over a range that GREW every iteration — O(n^2), and
// reachable from untrusted input (`heal()` is exported to the JS bindings and
// `--heal` applies to every renderer). `'~~ '*n + '~'` — the trailing `~` is
// what arms the first loop's guard — took 2.09 s at 100 KB, 4.32 s at 200 KB
// and 31.6 s at 400 KB. Hoisting one backward scan out of each loop makes every
// query a comparison and the whole healer O(n).
//
// This is deliberately a precomputed index rather than a resumable cursor like
// `MathScanner` / `LineContextScanner` / `FenceScanner`. Those exist because
// their predicates carry a **state machine** that must be advanced in document
// order, so they are exact only for non-decreasing queries. This one is
// stateless and its callers walk **backward**, which a forward cursor could not
// serve at all; a single hoisted scan is both simpler and exact for any query
// order.
fn last_meaningful_index(text: [*]const u8, end: u32) ?u32 {
    var i: u32 = end;
    while (i > 0) {
        i -%= 1;
        if (is_meaningful_char(text[i]))
            return i;
    }
    return null;
}

fn match_bold_at_end(text: [*]const u8, size: u32) u32 {
    if (size < 3) return size;

    // for(i = size - 1; i >= 2; i--) { ...; if(i == 2) break; }
    var i: u32 = size - 1;
    while (i >= 2) {
        if (text[i - 1] == '*' and text[i - 2] == '*') {
            blk: {
                if (i >= 3 and text[i - 3] == '*') break :blk;
                if (text[i] == '*') break :blk;
                {
                    var j: u32 = i;
                    var has_double_star = false;
                    while (j + 1 < size) : (j +%= 1) {
                        if (text[j] == '*' and text[j + 1] == '*') {
                            has_double_star = true;
                            break;
                        }
                    }
                    if (!has_double_star) return i - 2;
                }
            }
        }
        if (i == 2) break;
        i -%= 1;
    }
    return size;
}

fn heal_bold(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const marker_pos = match_bold_at_end(text, size);
    if (marker_pos >= size) return;

    if (in_complete_inline_code(text, size, marker_pos)) return;

    if (!has_meaningful_content(text, marker_pos + 2, size)) return;

    if (is_horizontal_rule(text, size, marker_pos, '*')) return;

    const pairs = count_double_asterisks(text, size);
    if (pairs % 2 != 0) {
        if (text[size - 1] == '*' and size > marker_pos + 3) {
            buf_append_ch(buf, '*');
        } else {
            buf_append(buf, "**", 2);
        }
    }
}

fn heal_italic_asterisk(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const singles = count_single_asterisks(text, size);
    if (singles % 2 != 0) {
        buf_append_ch(buf, '*');
    }
}

fn heal_italic_double_underscore(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;
    var pairs: u32 = undefined;

    if (in_fenced_code_block(text, size, size)) return;

    if (size >= 4 and text[size - 1] == '_' and
        text[size - 2] != '_' and text[size - 2] != '\\')
    {
        pairs = count_double_underscores(text, size);
        if (pairs % 2 != 0) {
            buf_append_ch(buf, '_');
            return;
        }
    }

    pairs = count_double_underscores(text, size);
    if (pairs % 2 != 0) {
        buf_append(buf, "__", 2);
    }
}

fn heal_italic_underscore(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const singles = count_single_underscores(text, size);
    if (singles % 2 != 0) {
        var end: u32 = size;
        while (end > 0 and buf.data.?[end - 1] == '\n') end -%= 1;

        if (end < size) {
            const tail_len: u32 = size - end;
            const tail = c_allocator.alloc(u8, tail_len) catch {
                buf.err = 1;
                return;
            };
            @memcpy(tail[0..tail_len], (buf.data.? + end)[0..tail_len]);
            buf.size = end;
            buf_append_ch(buf, '_');
            buf_append(buf, tail.ptr, tail_len);
            c_allocator.free(tail);
        } else {
            buf_append_ch(buf, '_');
        }
    }
}

fn heal_bold_italic(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    {
        var i: u32 = 0;
        var all_stars = true;
        while (i < size) : (i +%= 1) {
            if (text[i] != '*') {
                all_stars = false;
                break;
            }
        }
        if (all_stars) return;
    }

    const triples = count_triple_asterisks(text, size);
    if (triples % 2 != 0) {
        const doubles = count_double_asterisks(text, size);
        const singles = count_single_asterisks(text, size);
        if (doubles % 2 == 0 and singles % 2 == 0) return;
        buf_append(buf, "***", 3);
    }
}

// ***************************
// ***  Strikethrough heal ***
// ***************************

fn heal_strikethrough(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    if (size >= 4 and text[size - 1] == '~' and
        text[size - 2] != '~' and text[size - 2] != '\\')
    {
        // Every query in this loop is `has_meaningful_content(text, i + 1,
        // size - 1)` — `end` fixed, `start` falling — so one scan answers all
        // of them. Hoisted out of the loop rather than computed per iteration:
        // that is the whole fix.
        const last = last_meaningful_index(text, size - 1);
        var i: u32 = size - 2;
        while (i > 0) {
            if (text[i] == '~' and i > 0 and text[i - 1] == '~') {
                if (last != null and last.? >= i + 1) {
                    buf_append_ch(buf, '~');
                    return;
                }
            }
            i -%= 1;
        }
    }

    const pairs = count_double_tildes(text, size);
    if (pairs % 2 != 0) {
        // Same shape, with `end` fixed at `size` this time.
        const last = last_meaningful_index(text, size);
        // for(i = size; i >= 2; i--)
        var i: u32 = size;
        while (i >= 2) : (i -%= 1) {
            if (text[i - 2] == '~' and text[i - 1] == '~') {
                if (i < size and last != null and last.? >= i) {
                    buf_append(buf, "~~", 2);
                    return;
                }
            }
        }
    }
}

// ***************************
// ***  KaTeX heal         ***
// ***************************

fn heal_katex(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    const pairs = count_double_dollars(text, size);
    if (pairs % 2 != 0) {
        var has_newline = false;
        // for(i = size; i >= 2; i--)
        var i: u32 = size;
        while (i >= 2) : (i -%= 1) {
            if (text[i - 2] == '$' and text[i - 1] == '$') {
                var j: u32 = i;
                while (j < size) : (j +%= 1) {
                    if (text[j] == '\n') {
                        has_newline = true;
                        break;
                    }
                }
                break;
            }
        }
        if (has_newline) {
            if (size > 0 and text[size - 1] != '\n')
                buf_append_ch(buf, '\n');
        }
        buf_append(buf, "$$", 2);
    }
}

// ***************************
// ***  Link/image heal    ***
// ***************************

// The index type is i64, not c_int: `size` is a u32, so a c_int cursor cannot
// represent an offset at or past 2 GiB. `@as(c_int, @intCast(size)) - 1` panicked
// there in Debug/ReleaseSafe and truncated negative under the shipping
// ReleaseFast, silently turning these healers into no-ops on a >= 2 GiB
// document. The walks still need a signed cursor (they terminate by stepping
// past index 0), so widen rather than unsign — see .agents/conventions.md.
fn find_matching_open_bracket(text: [*]const u8, close_idx: u32) i64 {
    var depth: i64 = 0;
    var i: i64 = @intCast(close_idx);
    while (i >= 0) : (i -= 1) {
        const u: u32 = @intCast(i);
        if (text[u] == ']') {
            depth += 1;
        } else if (text[u] == '[') {
            depth -= 1;
            if (depth == 0) return i;
        }
    }
    return -1;
}

fn heal_links_and_images(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    if (in_fenced_code_block(text, size, size)) return;

    // Case 1: Incomplete URL — [text](url  (no closing paren)
    {
        var i: i64 = @as(i64, size) - 1;
        while (i >= 1) : (i -= 1) {
            const u: u32 = @intCast(i);
            if (text[u] == '(' and text[u - 1] == ']') {
                var j: u32 = @intCast(i + 1);
                var has_close = false;
                while (j < size) : (j +%= 1) {
                    if (text[j] == ')') {
                        has_close = true;
                        break;
                    }
                    if (text[j] == '\n') break;
                }
                if (!has_close) {
                    const open = find_matching_open_bracket(text, @intCast(i - 1));
                    if (open >= 0) {
                        const open_u: u32 = @intCast(open);
                        const is_image = (open > 0 and text[open_u - 1] == '!');
                        if (is_image) {
                            const img_start: u32 = @intCast(open - 1);
                            buf.size = img_start;
                            while (buf.size > 0 and (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                                buf.size -%= 1;
                        } else {
                            buf.size = @intCast(i + 1);
                            buf_append(buf, ")", 1);
                        }
                        return;
                    }
                }
                break;
            }
        }
    }

    // Case 2: Incomplete text — [text  (no closing ])
    {
        var i: i64 = @as(i64, size) - 1;
        while (i >= 0) : (i -= 1) {
            const u: u32 = @intCast(i);
            if (text[u] == '[' and !is_escaped(text, u)) {
                var j: u32 = @intCast(i + 1);
                var has_close = false;
                while (j < size) : (j +%= 1) {
                    if (text[j] == ']' and !is_escaped(text, j)) {
                        has_close = true;
                        break;
                    }
                }
                if (!has_close) {
                    const is_image = (i > 0 and text[u - 1] == '!');
                    if (is_image) {
                        buf.size = @intCast(i - 1);
                        while (buf.size > 0 and (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                            buf.size -%= 1;
                    } else {
                        const after: u32 = @intCast(i + 1);
                        // memmove(buf->data + i, buf->data + after, buf->size - after)
                        const n: u32 = buf.size - after;
                        std.mem.copyForwards(u8, buf.data.?[u .. u + n], buf.data.?[after .. after + n]);
                        buf.size -%= 1;
                    }
                    return;
                }
                // A closer was found after this `[`. The search range only
                // grows as `i` walks left, so that same closer sits after every
                // earlier `[` too and none of them can heal either — the rest
                // of the walk is pure work. Bailing here is what makes the case
                // O(n) instead of O(n^2): without it, `'['*(n-1) + ']'` re-ran
                // the forward scan once per bracket (26 s at 400 KB).
                break;
            }
        }
    }
}

// ***************************
// ***  HTML tag heal      ***
// ***************************

fn heal_html_tag(buf: *HEAL_BUF) void {
    const text = buf.data.?;
    const size = buf.size;

    var i: i64 = @as(i64, size) - 1;
    while (i >= 0) : (i -= 1) {
        const u: u32 = @intCast(i);
        if (text[u] == '>') return;
        if (text[u] == '\n') return;
        if (text[u] == '<') {
            if (@as(u32, @intCast(i + 1)) < size) {
                const next = text[u + 1];
                if ((next >= 'a' and next <= 'z') or
                    (next >= 'A' and next <= 'Z') or next == '/')
                {
                    if (!in_fenced_code_block(text, size, u)) {
                        buf.size = u;
                        while (buf.size > 0 and
                            (buf.data.?[buf.size - 1] == ' ' or buf.data.?[buf.size - 1] == '\t'))
                            buf.size -%= 1;
                    }
                }
            }
            return;
        }
    }
}

// ***************************
// ***  Comparison ops     ***
// ***************************

// The scan itself was always linear; the two things it did per escaped `>` were
// not. It rescanned the whole prefix for fences (see `FenceScanner`) and it
// memmoved the entire tail one byte right per inserted backslash, so a document
// of `'- > 5\n'` repeats cost O(n^2) twice over — 10.3 s at 400 KB, growing 4x
// per doubling. Both are reachable from untrusted input (`heal()` is exported to
// the JS bindings and `--heal` applies to every renderer).
//
// So the escaped copy is now *appended* to a second buffer instead of being
// spliced in place: `out` holds the source prefix with every backslash inserted
// so far, `copied` is how much of `src` has been flushed into it, and the whole
// pass is O(n). `src` is never mutated, which is also what makes the resumable
// fence scan sound — its committed prefix cannot be rewritten underneath it.
//
// `out` is what the in-place version's buffer held at the same point, byte for
// byte, so `fences.at(out.data, out.size)` sees exactly what
// `in_fenced_code_block(buf.data, size, gt_pos)` used to: the source prefix
// carrying the earlier insertions. That equality is the whole correctness
// argument — keep the flush *before* the query.
fn heal_comparison_operators(buf: *HEAL_BUF) void {
    const src = buf.data.?;
    const size = buf.size;

    // Allocated lazily, on the first line that reaches the fence check: a
    // document with no comparison-operator candidate pays nothing.
    var out: HEAL_BUF = .{ .data = null, .size = 0, .cap = 0, .err = 0 };
    var copied: u32 = 0;
    var fences: FenceScanner = .{};

    var i: u32 = 0;
    while (i < size) {
        while (i < size and (src[i] == ' ' or src[i] == '\t')) i +%= 1;

        var is_list = false;
        if (i < size) {
            if (src[i] == '-' or src[i] == '*' or src[i] == '+') {
                const after = i + 1;
                if (after < size and src[after] == ' ') {
                    is_list = true;
                    i = after + 1;
                }
            } else if (src[i] >= '0' and src[i] <= '9') {
                var j = i;
                while (j < size and src[j] >= '0' and src[j] <= '9') j +%= 1;
                if (j < size and (src[j] == '.' or src[j] == ')')) {
                    j +%= 1;
                    if (j < size and src[j] == ' ') {
                        is_list = true;
                        i = j + 1;
                    }
                }
            }
        }

        if (is_list and i < size and src[i] == '>') {
            const gt_pos = i;
            i +%= 1;
            if (i < size and src[i] == '=') {
                i +%= 1;
            }
            while (i < size and src[i] == ' ') i +%= 1;
            if (i < size and src[i] == '$') i +%= 1;
            if (i < size and src[i] >= '0' and src[i] <= '9') {
                if (out.data == null) {
                    buf_init(&out, size +| 64);
                    if (out.data == null) {
                        buf.err = 1;
                        return;
                    }
                }
                buf_append(&out, src + copied, gt_pos - copied);
                copied = gt_pos;
                if (out.err != 0) {
                    buf.err = 1;
                    buf_free(&out);
                    return;
                }
                if (!fences.at(out.data.?, out.size)) {
                    buf_append_ch(&out, '\\');
                    if (out.err != 0) {
                        buf.err = 1;
                        buf_free(&out);
                        return;
                    }
                }
            }
        }

        while (i < size and src[i] != '\n') i +%= 1;
        if (i < size) i +%= 1;
    }

    // No candidate line: `buf` was never touched, so there is nothing to swap.
    if (out.data == null) return;

    buf_append(&out, src + copied, size - copied);
    if (out.err != 0) {
        buf.err = 1;
        buf_free(&out);
        return;
    }

    // Every later healer re-reads `buf.data`, so handing over the new buffer
    // here is safe; `src` is dead from this point.
    const prev_err = buf.err;
    buf_free(buf);
    buf.* = out;
    buf.err = prev_err;
}

// ***************************
// ***  Main heal function ***
// ***************************

pub fn md_heal(
    input: [*]const u8,
    input_size: c_uint,
    process_output: *const fn ([*]const u8, c_uint, ?*anyopaque) void,
    userdata: ?*anyopaque,
) c_int {
    var buf: HEAL_BUF = undefined;

    if (input_size == 0) {
        return 0;
    }

    // Saturating: `+%` wrapped to a 63-byte allocation for an input within 64
    // bytes of 4 GiB. At the ceiling the allocation simply fails and md_heal
    // returns -1; buf_append's own checked growth covers the rest.
    buf_init(&buf, input_size +| 64);
    if (buf.data == null) return -1;

    buf_append(&buf, input, input_size);

    // Strip trailing single space (preserve double space for line break)
    if (buf.size > 0 and buf.data.?[buf.size - 1] == ' ') {
        if (buf.size < 2 or buf.data.?[buf.size - 2] != ' ')
            buf.size -%= 1;
    }

    heal_comparison_operators(&buf);
    heal_html_tag(&buf);
    heal_setext_heading(&buf);
    heal_links_and_images(&buf);
    heal_bold_italic(&buf);
    heal_bold(&buf);
    heal_italic_double_underscore(&buf);
    heal_italic_asterisk(&buf);
    heal_italic_underscore(&buf);
    heal_inline_code(&buf);
    heal_strikethrough(&buf);
    heal_katex(&buf);
    heal_code_block(&buf);

    if (buf.err != 0) {
        buf_free(&buf);
        return -1;
    }

    if (buf.size > 0)
        process_output(buf.data.?, buf.size, userdata);

    buf_free(&buf);
    return 0;
}

// ***************************
// ***  Tests              ***
// ***************************

// `buf_append` used to compute its own bounds check with explicitly wrapping
// operators, so past 2^32 bytes it *defined* the wrap it existed to prevent:
// `buf.size +% len > buf.cap` read false, no realloc happened, and the @memcpy
// wrote `len` bytes past a buffer that was never grown. `+%` is well-defined
// even in ReleaseSafe, so no build mode caught it.
//
// The real boundary needs >4 GiB of buffered output, which the CLI now refuses
// at the input and wasm32 cannot reach at all, so the counter is seeded instead.
// This file is reachable from `src/fuzz.zig` (via `lib.zig`), so the case runs
// under `zig build fuzz-zig`.
test "buf_append: the size counter cannot wrap past its own capacity check" {
    var buf: HEAL_BUF = undefined;
    buf_init(&buf, 64);
    defer buf_free(&buf);
    try std.testing.expect(buf.data != null);

    // Ordinary appends are unchanged, including a grow whose 1.5x step is
    // shorter than the demand (@max covers it).
    buf_append(&buf, "abc", 3);
    try std.testing.expectEqual(@as(u32, 3), buf.size);
    try std.testing.expectEqual(@as(c_int, 0), buf.err);

    const big = [_]u8{'z'} ** 1000;
    buf_append(&buf, &big, big.len);
    try std.testing.expectEqual(@as(u32, 1003), buf.size);
    try std.testing.expectEqual(@as(c_int, 0), buf.err);
    try std.testing.expect(buf.cap >= 1003);
    try std.testing.expectEqualStrings("abc", buf.data.?[0..3]);

    // The boundary: one byte short of 2^32, plus two. Must set `err` — which
    // md_heal turns into a clean -1 — and leave the buffer untouched.
    const saved_cap = buf.cap;
    buf.size = std.math.maxInt(u32) - 1;
    buf_append(&buf, "xy", 2);
    try std.testing.expectEqual(@as(c_int, 1), buf.err);
    try std.testing.expectEqual(std.math.maxInt(u32) - 1, buf.size);
    try std.testing.expectEqual(saved_cap, buf.cap);

    // `err` latches, so every later append is a no-op and md_heal reports -1.
    buf_append(&buf, "abc", 3);
    try std.testing.expectEqual(@as(c_int, 1), buf.err);

    buf.size = 1003;
    buf.err = 0;
}
