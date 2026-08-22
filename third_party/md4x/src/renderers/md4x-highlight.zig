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

//! Syntax-highlight hook shared by the HTML and ANSI renderers.
//!
//! A host (the WASM / NAPI glue, the CLI, a Zig consumer) installs a
//! `Highlighter`; the renderer then calls it once per fenced/indented code
//! block, *during* the render, and emits whatever comes back in place of its
//! own `<pre><code>…</code></pre>` (HTML) or `DIM … DIM_OFF` (ANSI) rendering.
//!
//! This replaced a postprocessing pass: the renderer used to append a JSON
//! array of byte offsets after the body (`MD_*_FLAG_CODE_META`) and the JS
//! caller spliced the highlighted blocks in afterwards. That pass had to decode
//! the output prefix once per code block to convert byte offsets to JS string
//! indices — quadratic in the number of blocks — and it could only ever splice
//! what the offsets described, so every renderer change that moved a byte had
//! to keep them in sync (see the block-component skew regressions in
//! `packages/md4x/test/_suite.mjs`). Calling out at the block boundary needs no
//! offsets at all.
//!
//! The renderer never allocates the replacement: `highlight` returns host-owned
//! bytes and `release` gives them back once they are copied into the output, so
//! the wasm (libc `malloc` in linear memory) and napi (`napi_get_value_string_utf8`
//! into a `malloc` buffer) glues keep their own allocator.

const std = @import("std");
const c = @import("abi");

const c_allocator = std.heap.c_allocator;

/// One code block, as handed to the host.
///
/// Every slice borrows renderer/parser memory that stays alive only for the
/// duration of the `highlight` call — a host that needs the bytes later must
/// copy them. `lang` / `filename` are the raw info-string substrings (what the
/// old `MD_*_FLAG_CODE_META` JSON carried, minus its 64/256-byte truncation).
pub const Request = struct {
    /// Block content, exactly as the renderer would have emitted it before its
    /// own escaping: HTML hands over the raw document bytes (U+0000 already
    /// substituted with U+FFFD), ANSI hands over the control-sanitized text —
    /// see `render_sanitized` there. Both include the trailing newline the
    /// parser emits for the final line.
    code: []const u8,
    lang: []const u8 = &.{},
    filename: []const u8 = &.{},
    /// Expanded line numbers from the `{1-3,5}` info-string syntax.
    highlights: []const c_uint = &.{},
    /// ANSI only: the per-line indent the renderer would have written in front
    /// of each code line (blockquote bars, list indent, plus two spaces). The
    /// renderer re-applies it to the replacement, so a highlighter neither sees
    /// it in `code` nor has to emit it. Empty for HTML.
    prefix: []const u8 = &.{},
};

/// The host-side hook. Both function pointers are required: a `highlight` that
/// can return bytes without a matching `release` would leak once per block.
pub const Highlighter = struct {
    ctx: ?*anyopaque = null,

    /// Returns the replacement output for `req`, or null to decline — declining
    /// makes the renderer emit its own default rendering for that block, byte
    /// for byte, so a host may decline per block (unknown language) or for the
    /// rest of the document (the highlighter threw) without the output ever
    /// being half-rendered.
    highlight: *const fn (ctx: ?*anyopaque, req: *const Request) ?[]const u8,

    /// Hands back what `highlight` returned, once it has been copied out.
    release: *const fn (ctx: ?*anyopaque, text: []const u8) void,
};

/// Growable byte buffer used to divert a renderer's output sink while a code
/// block is rendered, so the default rendering can be thrown away when the
/// highlighter accepts the block (and emitted verbatim when it declines).
///
/// `err` latches an allocation failure: the captured bytes are then a prefix of
/// the block rather than the block, so the renderer skips the hook and emits
/// what it has. That degrades one code block on OOM instead of substituting a
/// truncated block for the real one.
pub const Buf = struct {
    data: ?[*]u8 = null,
    size: c.MD_SIZE = 0,
    cap: c.MD_SIZE = 0,
    err: bool = false,

    pub fn append(self: *Buf, text: [*]const u8, size: c.MD_SIZE) void {
        if (self.size + size > self.cap) {
            const new_cap: c.MD_SIZE = self.cap + self.cap / 2 + size + 256;
            const p = if (self.data) |old|
                (c_allocator.realloc(old[0..self.cap], new_cap) catch {
                    self.err = true;
                    return;
                }).ptr
            else
                (c_allocator.alloc(u8, new_cap) catch {
                    self.err = true;
                    return;
                }).ptr;
            self.data = p;
            self.cap = new_cap;
        }
        if (size > 0)
            @memcpy(self.data.?[self.size .. self.size + size], text[0..size]);
        self.size += size;
    }

    pub fn slice(self: *const Buf) []const u8 {
        return if (self.data) |d| d[0..self.size] else &.{};
    }

    /// Keeps the allocation for the next code block — a document with many of
    /// them reuses one buffer.
    pub fn reset(self: *Buf) void {
        self.size = 0;
        self.err = false;
    }

    pub fn deinit(self: *Buf) void {
        if (self.data) |d| c_allocator.free(d[0..self.cap]);
        self.* = .{};
    }

    /// `ProcessOutputFn` shape, for swapping into a renderer's sink. The
    /// renderer passes the `Buf` as its userdata for as long as it is diverted.
    pub fn sink(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
        const self: *Buf = @ptrCast(@alignCast(userdata.?));
        self.append(@ptrCast(text), size);
    }
};
