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
// Zig port of src/renderers/md4x-ansi.c — byte-for-byte identical behavior.

const std = @import("std");

// MD_* types now come from the Zig-native
// abi module (replacing md4x.h / entity.h / md4x-heal.h); this renderer needs
// no external C header of its own — the debug sink's stderr write lives in the
// shared md4x-diag.zig.
const c = @import("abi");
// Sibling units are imported directly (one Zig module per artifact), not
// resolved through link-time C-ABI symbols. `abi` holds types only.
const md4x = @import("../md4x.zig");
const entity = @import("../entity.zig");
const heal = @import("md4x-heal.zig");
const scan = @import("../scan.zig");
const diag = @import("md4x-diag.zig");
const hl = @import("md4x-highlight.zig");

// Shared component property parser, from the shared md4x-props.zig module
// (previously reimplemented inline here). The ANSI renderer only consumes the
// string props (to resolve ::alert{type="..."} colors). Local aliases preserve
// the original call-site names used below.

const props = @import("md4x-props.zig");

const MD_PARSED_PROPS = props.MD_PARSED_PROPS;
const md_parse_props = props.md_parse_props;

const c_allocator = std.heap.c_allocator;

// Renderer flags (mirrors md4x-ansi.h). Heal flag value is shared (0x0100).
const MD_ANSI_FLAG_DEBUG: c_uint = 0x0001;
const MD_ANSI_FLAG_SKIP_UTF8_BOM: c_uint = 0x0002;
const MD_ANSI_FLAG_NO_COLOR: c_uint = 0x0004;
// 0x0008 was MD_ANSI_FLAG_CODE_META, the code-block offset trailer the JS
// bindings used to splice highlighted blocks into the finished output. The
// renderer now calls the highlighter itself -- see md4x-highlight.zig -- so the
// flag, and the byte-offset bookkeeping it needed, are gone. The bit is left
// unused rather than reassigned, so a caller passing the old value gets a
// no-op instead of NO_COLOR or SHOW_URLS.
const MD_ANSI_FLAG_SHOW_URLS: c_uint = 0x0010;
const MD_ANSI_FLAG_SHOW_FRONTMATTER: c_uint = 0x0020;
const MD_ANSI_FLAG_HEAL: c_uint = 0x0100;

// ANSI escape sequences
const ANSI_RESET = "\x1b[0m";
const ANSI_BOLD = "\x1b[1m";
const ANSI_BOLD_OFF = "\x1b[22m";
const ANSI_DIM = "\x1b[2m";
const ANSI_DIM_OFF = "\x1b[22m";
const ANSI_ITALIC = "\x1b[3m";
const ANSI_ITALIC_OFF = "\x1b[23m";
const ANSI_STRIKETHROUGH = "\x1b[9m";
const ANSI_STRIKE_OFF = "\x1b[29m";
// Highlight (`==x==`). Reverse video rather than a background colour: it is the
// only spelling that stays legible on both light and dark terminal themes.
const ANSI_REVERSE = "\x1b[7m";
const ANSI_REVERSE_OFF = "\x1b[27m";

const ANSI_COLOR_BLUE = "\x1b[34m";
const ANSI_COLOR_CYAN = "\x1b[36m";
const ANSI_COLOR_MAGENTA = "\x1b[35m";
const ANSI_COLOR_YELLOW = "\x1b[33m";
const ANSI_COLOR_GREEN = "\x1b[32m";
const ANSI_COLOR_RED = "\x1b[31m";
const ANSI_COLOR_DEFAULT = "\x1b[39m";

// Compound styles
const ANSI_HEADING = "\x1b[1;35m";
const ANSI_LINK = "\x1b[4;34m";
const ANSI_LINK_URL = "\x1b[2;34m";

// OSC 8 hyperlinks: \033]8;;URL\033\\ to open, \033]8;;\033\\ to close
const ANSI_HYPERLINK_OPEN = "\x1b]8;;";
const ANSI_HYPERLINK_SEP = "\x1b\\";
const ANSI_HYPERLINK_CLOSE = "\x1b]8;;\x1b\\";

// Box-drawing characters (UTF-8)
const HORIZONTAL_RULE = "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80" ++
    "\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80";

// Blockquote bar (UTF-8: vertical bar U+2502)
const QUOTE_BAR = "\xe2\x94\x82";

// Alert bar (UTF-8: left half block U+258C ▌)
const ALERT_BAR = "\xe2\x96\x8c";

// Non-optional — see the note on `md4x-json.zig`'s ProcessOutputFn.
const ProcessOutputFn = *const fn ([*c]const c.MD_CHAR, c.MD_SIZE, ?*anyopaque) void;

/// Options for `md_ansi_ex`. Re-exported by lib.zig. The plain `md_ansi` entry
/// point is this with no options at all.
pub const MD_ANSI_OPTS = extern struct {
    /// Called once per fenced/indented code block -- see md4x-highlight.zig.
    highlighter: ?*const hl.Highlighter = null,
};

// Longest line indent (blockquote bars, alert bar, list indent, plus the code
// block's own two spaces) handed to a highlighter and re-applied to its output.
// A deeper nesting than this truncates the prefix rather than growing a buffer
// per code block; the same 256 bytes the code-meta JSON used to carry.
const MAX_CODE_PREFIX = 256;

const MD_ANSI = struct {
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    flags: c_uint,
    image_nesting_level: c_int,
    quote_depth: c_int,
    list_depth: c_int,
    ol_counter: c_int,
    in_code_block: bool,
    need_newline: bool, // pending newline before next block
    need_indent: bool, // emit indent prefix on next code text
    li_opened: bool, // just opened a list item (bullet already printed)
    in_alert: bool, // inside an alert block
    alert_color: ?[*:0]const u8, // ANSI color escape for current alert bar
    component_nesting: c_int, // block component nesting depth
    in_comp_frontmatter: bool, // inside component frontmatter (suppress output)

    // Syntax-highlight hook. While a code block is rendered with a highlighter
    // installed, nothing is emitted: the block's sanitized text accumulates in
    // `hl_code` and leave_block either emits the highlighter's reply or renders
    // the block itself. `hl_prefix` is the per-line indent, captured once at
    // the top of the block and applied to either.
    highlighter: ?*const hl.Highlighter,
    hl_active: bool,
    hl_code: hl.Buf,
    hl_prefix: [MAX_CODE_PREFIX]u8,
    hl_prefix_size: c.MD_SIZE,
};

// AppendFn mirrors the C `void (*fn_append)(MD_ANSI*, const MD_CHAR*, MD_SIZE)`.
const AppendFn = *const fn (*MD_ANSI, [*]const u8, c.MD_SIZE) void;

// *********************************************
// ***  ANSI rendering helper functions  ***
// *********************************************

// The renderer's single sink. `process_output` is swapped to a capture callback
// while the indent prefix or a highlighted code block is being collected, which
// is why every write goes through here rather than the caller's callback.
fn render_verbatim(r: *MD_ANSI, text: [*]const u8, size: c.MD_SIZE) void {
    r.process_output(@ptrCast(text), size, r.userdata);
}

fn render_verbatim_lit(r: *MD_ANSI, comptime lit: []const u8) void {
    render_verbatim(r, lit.ptr, @intCast(lit.len));
}

// Document bytes are never handed to a terminal verbatim. A C0 control byte
// coming out of the source document is *executed* by the terminal, not shown:
// ESC opens a CSI/OSC/DCS sequence, BEL and ESC-backslash terminate an OSC
// string, CR/BS rewrite the line already printed. Every path that copies
// document-derived text into the output goes through render_sanitized (body
// text) or render_url_ctrl_escaped (OSC 8 link destinations) instead of
// render_verbatim; render_verbatim stays for the renderer's own literals.
//
// This is independent of MD_ANSI_FLAG_NO_COLOR, which gates only the renderer's
// own escape codes -- with the document's own controls neutralised here, that
// flag now really does yield the plain-text output docs/renderers.md promises.
//
// Substitution rule for body text: the offending byte becomes its Unicode
// "control picture" (U+2400 + ch, U+2421 for DEL). One input byte in, one
// character cell out, so table columns and code-block indentation keep their
// alignment -- which stripping would break and caret notation (`^[`, two cells)
// would break differently -- and the reader still sees which byte was there.
// TAB and LF are passed through: the renderer emits them itself as layout and
// neither can begin a control sequence.
fn render_sanitized(r: *MD_ANSI, data: [*]const u8, size: c.MD_SIZE) void {
    var beg: c.MD_SIZE = 0;
    var off: c.MD_SIZE = 0;

    while (true) {
        // The `lt` threshold covers the whole C0 range in one vector compare;
        // TAB/LF are the two members filtered back out here.
        off = @intCast(scan.indexOfAnyPos("\x7f", 0x20, data, off, size));
        while (off < size and (data[off] == '\t' or data[off] == '\n'))
            off = @intCast(scan.indexOfAnyPos("\x7f", 0x20, data, off + 1, size));

        if (off > beg)
            render_verbatim(r, data + beg, off - beg);
        if (off >= size)
            break;

        const cp: c_uint = if (data[off] == 0x7f) 0x2421 else 0x2400 + @as(c_uint, data[off]);
        // U+2400..U+2421 all encode as three UTF-8 bytes.
        const pic = [_]u8{
            @intCast(0xe0 | (cp >> 12)),
            @intCast(0x80 | ((cp >> 6) & 0x3f)),
            @intCast(0x80 | (cp & 0x3f)),
        };
        render_verbatim(r, &pic, 3);

        off += 1;
        beg = off;
    }
}

// Link destinations are interpolated into an OSC 8 hyperlink
// (ESC ] 8 ; ; URL ESC backslash). An OSC string ends at BEL or ST and xterm
// aborts it on the other C0 controls, so a control byte in the destination
// closes the sequence early and hands everything after it to the terminal as a
// fresh command -- the `\033]0;title\007` window-title attack. Escaping cannot
// be done *inside* an OSC string, so the bytes are removed from the URL
// instead: percent-encode them, which is what the HTML renderer already does
// for href="..." and is also the only legal spelling of them in a URI
// (RFC 3986), so the hyperlink keeps working rather than being dropped.
//
// Bytes >= 0x20 are left alone. Unlike HTML there is no quoted attribute here
// to break out of, so they are inert, and percent-encoding them the way
// md4x-html.zig's render_url_escaped does would rewrite every existing
// hyperlink. Raw 0x80-0x9F are likewise left alone: in the UTF-8 terminals this
// renderer targets they are continuation bytes of a legitimate non-ASCII URL,
// not C1 controls.
fn render_url_ctrl_escaped(r: *MD_ANSI, data: [*]const u8, size: c.MD_SIZE) void {
    const hex_chars = "0123456789ABCDEF";
    var beg: c.MD_SIZE = 0;
    var off: c.MD_SIZE = 0;

    while (true) {
        off = @intCast(scan.indexOfAnyPos("\x7f", 0x20, data, off, size));

        if (off > beg)
            render_verbatim(r, data + beg, off - beg);
        if (off >= size)
            break;

        const esc = [_]u8{ '%', hex_chars[data[off] >> 4], hex_chars[data[off] & 0xf] };
        render_verbatim(r, &esc, 3);

        off += 1;
        beg = off;
    }
}

fn render_ansi(r: *MD_ANSI, comptime code: []const u8) void {
    if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0)
        render_verbatim_lit(r, code);
}

// Runtime-variant of render_ansi for the alert_color pointer (sentinel string).
fn render_ansi_ptr(r: *MD_ANSI, code: [*:0]const u8) void {
    if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0) {
        const slice = std.mem.span(code);
        render_verbatim(r, slice.ptr, @intCast(slice.len));
    }
}

fn render_indent(r: *MD_ANSI) void {
    var i: c_int = 0;
    while (i < r.quote_depth) : (i += 1) {
        render_ansi(r, ANSI_DIM);
        render_verbatim_lit(r, "  " ++ QUOTE_BAR ++ " ");
        render_ansi(r, ANSI_DIM_OFF);
    }
    if (r.in_alert and r.alert_color != null) {
        render_ansi_ptr(r, r.alert_color.?);
        render_verbatim_lit(r, ALERT_BAR ++ " ");
        render_ansi(r, ANSI_COLOR_DEFAULT);
    }
    i = 0;
    while (i < r.list_depth) : (i += 1) {
        render_verbatim_lit(r, "  ");
    }
}

fn render_newline(r: *MD_ANSI) void {
    render_verbatim_lit(r, "\n");
}

// Render a blank separator line with alert bar prefix when inside an alert.
fn render_separator(r: *MD_ANSI) void {
    render_newline(r);
    if (r.in_alert and r.alert_color != null) {
        render_ansi_ptr(r, r.alert_color.?);
        render_verbatim_lit(r, ALERT_BAR);
        render_ansi(r, ANSI_COLOR_DEFAULT);
        render_newline(r);
    }
}

fn hex_val(ch: u8) c_uint {
    if ('0' <= ch and ch <= '9')
        return ch - '0';
    if ('a' <= ch and ch <= 'f')
        return ch - 'a' + 10;
    if ('A' <= ch and ch <= 'F')
        return ch - 'A' + 10;
    return 0;
}

fn render_utf8_codepoint(r: *MD_ANSI, codepoint: c_uint, fn_append: AppendFn) void {
    const utf8_replacement_char = [_]u8{ 0xef, 0xbf, 0xbd };

    var utf8: [4]u8 = undefined;
    var n: usize = undefined;

    if (codepoint <= 0x7f) {
        n = 1;
        utf8[0] = @truncate(codepoint);
    } else if (codepoint <= 0x7ff) {
        n = 2;
        utf8[0] = @intCast(0xc0 | ((codepoint >> 6) & 0x1f));
        utf8[1] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    } else if (codepoint <= 0xffff) {
        n = 3;
        utf8[0] = @intCast(0xe0 | ((codepoint >> 12) & 0xf));
        utf8[1] = @intCast(0x80 + ((codepoint >> 6) & 0x3f));
        utf8[2] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    } else {
        n = 4;
        utf8[0] = @intCast(0xf0 | ((codepoint >> 18) & 0x7));
        utf8[1] = @intCast(0x80 + ((codepoint >> 12) & 0x3f));
        utf8[2] = @intCast(0x80 + ((codepoint >> 6) & 0x3f));
        utf8[3] = @intCast(0x80 + ((codepoint >> 0) & 0x3f));
    }

    // Surrogates (U+D800..U+DFFF) are not Unicode scalar values, so encoding
    // them as an ordinary 3-byte sequence yields malformed UTF-8. CommonMark
    // requires them -- like U+0000 -- to be rendered as U+FFFD.
    if (0 < codepoint and codepoint <= 0x10ffff and
        (codepoint < 0xd800 or codepoint > 0xdfff))
        fn_append(r, &utf8, @intCast(n))
    else
        fn_append(r, &utf8_replacement_char, 3);
}

fn render_entity(r: *MD_ANSI, text: [*]const u8, size: c.MD_SIZE, fn_append: AppendFn) void {
    if (size > 3 and text[1] == '#') {
        var codepoint: c_uint = 0;

        if (text[2] == 'x' or text[2] == 'X') {
            var i: c.MD_SIZE = 3;
            while (i < size - 1) : (i += 1)
                codepoint = 16 *% codepoint +% hex_val(text[i]);
        } else {
            var i: c.MD_SIZE = 2;
            while (i < size - 1) : (i += 1)
                codepoint = 10 *% codepoint +% (text[i] - '0');
        }

        render_utf8_codepoint(r, codepoint, fn_append);
        return;
    } else {
        if (entity.entity_lookup(text[0..size])) |cps| {
            render_utf8_codepoint(r, cps[0], fn_append);
            if (cps[1] != 0)
                render_utf8_codepoint(r, cps[1], fn_append);
            return;
        }
    }

    fn_append(r, text, size);
}

fn render_attribute(r: *MD_ANSI, attr: *const c.Attribute, fn_append: AppendFn) void {
    const total = attr.size();
    var i: usize = 0;
    while (i < attr.substr_types.len and attr.substr_offsets[i] < total) : (i += 1) {
        const ttype = attr.substr_types[i];
        const off = attr.substr_offsets[i];
        const size = attr.substr_offsets[i + 1] - off;
        const text: [*]const u8 = attr.text.ptr + off;

        switch (ttype) {
            c.TextType.nullchar => render_utf8_codepoint(r, 0x0000, render_verbatim),
            c.TextType.entity => render_entity(r, text, size, fn_append),
            else => fn_append(r, text, size),
        }
    }
}

// Case-insensitive compare for short ASCII strings.
fn ci_eq(a: [*c]const c.MD_CHAR, a_size: c.MD_SIZE, b: []const u8) bool {
    const ap: [*]const u8 = @ptrCast(a);
    var i: c.MD_SIZE = 0;
    while (i < a_size and i < b.len and b[i] != 0) : (i += 1) {
        var ca = ap[i];
        var cb = b[i];
        if (ca >= 'A' and ca <= 'Z') ca += 32;
        if (cb >= 'A' and cb <= 'Z') cb += 32;
        if (ca != cb) return false;
    }
    return (i == a_size and i == b.len);
}

// Map alert/component type name to ANSI color, or null if not an alert name.
fn alert_type_color(name: [*c]const c.MD_CHAR, size: c.MD_SIZE) ?[*:0]const u8 {
    if (size == 0 or name == null)
        return null;

    if (ci_eq(name, size, "note")) return ANSI_COLOR_BLUE;
    if (ci_eq(name, size, "info")) return ANSI_COLOR_BLUE;
    if (ci_eq(name, size, "tip")) return ANSI_COLOR_GREEN;
    if (ci_eq(name, size, "success")) return ANSI_COLOR_GREEN;
    if (ci_eq(name, size, "important")) return ANSI_COLOR_MAGENTA;
    if (ci_eq(name, size, "warning")) return ANSI_COLOR_YELLOW;
    if (ci_eq(name, size, "caution")) return ANSI_COLOR_RED;
    if (ci_eq(name, size, "danger")) return ANSI_COLOR_RED;

    return null;
}

// *****************************************
// ***  Syntax-highlight hook            ***
// *****************************************
//
// See md4x-highlight.zig. `hl_begin` captures the code block's line indent and
// diverts the renderer's sink for the rest of the block, so `hl_end` can either
// hand the block to the highlighter -- re-applying that indent to the reply --
// or write the captured default rendering out unchanged. A declining
// highlighter therefore reproduces the no-highlighter output byte for byte.

// Capture buffer for redirecting output to capture the indent prefix.
const ANSI_CAPTURE_BUF = struct {
    buf: [*]u8,
    size: c.MD_SIZE,
    cap: c.MD_SIZE,
};

fn ansi_capture_append(text: [*c]const c.MD_CHAR, size: c.MD_SIZE, userdata: ?*anyopaque) void {
    const cap: *ANSI_CAPTURE_BUF = @ptrCast(@alignCast(userdata.?));
    const n: c.MD_SIZE = if (cap.size + size <= cap.cap) size else (cap.cap - cap.size);
    if (n > 0) {
        @memcpy(cap.buf[cap.size .. cap.size + n], @as([*]const u8, @ptrCast(text))[0..n]);
        cap.size += n;
    }
}

// Enter a code block with a highlighter installed: snapshot the line indent the
// block's lines will carry, then start collecting the block instead of emitting
// it. The default rendering is deferred rather than captured-and-discarded --
// see the same note in md4x-html.zig.
fn hl_begin(r: *MD_ANSI) void {
    r.hl_code.reset();

    // The prefix is what render_indent + the code block's own two spaces emit,
    // which depends on the current quote/list/alert nesting. Rendering it into
    // a scratch buffer is how the renderer already measured it for the
    // code-meta JSON; these bytes never reach the caller.
    var cap = ANSI_CAPTURE_BUF{ .buf = &r.hl_prefix, .size = 0, .cap = r.hl_prefix.len };
    const saved_out = r.process_output;
    const saved_ud = r.userdata;
    r.process_output = ansi_capture_append;
    r.userdata = &cap;
    render_indent(r);
    render_verbatim_lit(r, "  ");
    r.process_output = saved_out;
    r.userdata = saved_ud;
    r.hl_prefix_size = cap.size;

    r.hl_active = true;
}

// Collect one chunk of a code block's text instead of emitting it.
//
// The chunk is written through the renderer's own text handling, into the
// buffer rather than the terminal: sanitized for `.code`, U+FFFD for a U+0000.
// Handing over the raw document bytes instead would let a `\x1b[…` sequence
// written inside a fenced block reach the terminal through a highlighter that
// echoes its input -- the one thing render_sanitized exists to prevent -- and
// the decline path renders straight from this buffer, so the sanitizing has to
// happen here either way.
//
// Every text type is routed here, not just `.code`: a NUL byte inside a fenced
// block arrives as `.nullchar`, and letting that one fall through to the switch
// below emitted it into the output stream *before* the deferred block, and left
// it out of what the highlighter saw.
fn hl_capture(r: *MD_ANSI, text_type: c.TextType, text: [*]const u8, size: c.MD_SIZE) void {
    // The parser sends each line's newline as its own callback; it needs no
    // sanitizing and no indent (hl_emit_code re-derives the indent per line).
    if (text_type == c.TextType.code and size == 1 and text[0] == '\n') {
        r.hl_code.append("\n", 1);
        return;
    }
    const saved_out = r.process_output;
    const saved_ud = r.userdata;
    r.process_output = hl.Buf.sink;
    r.userdata = &r.hl_code;
    if (text_type == c.TextType.nullchar)
        render_utf8_codepoint(r, 0x0000, render_verbatim)
    else
        render_sanitized(r, text, size);
    r.process_output = saved_out;
    r.userdata = saved_ud;
}

fn hl_end(r: *MD_ANSI, det: *const c.BlockCodeDetail) void {
    r.hl_active = false;

    // A collection that hit OOM holds a prefix of the block, not the block:
    // render what there is rather than hand the highlighter a truncated
    // program (see the `err` note in md4x-highlight.zig).
    const h = r.highlighter.?;
    const code = r.hl_code.slice();
    const replacement: ?[]const u8 = if (r.hl_code.err) null else h.highlight(h.ctx, &.{
        .code = code,
        .lang = det.lang.text,
        .filename = det.filename.text,
        .highlights = det.highlights,
        .prefix = r.hl_prefix[0..r.hl_prefix_size],
    });

    if (replacement) |text| {
        hl_emit_replacement(r, text);
        h.release(h.ctx, text);
        return;
    }

    render_ansi(r, ANSI_DIM);
    hl_emit_code(r, code);
    render_ansi(r, ANSI_DIM_OFF);
}

fn hl_emit_prefix(r: *MD_ANSI) void {
    if (r.hl_prefix_size > 0)
        render_verbatim(r, &r.hl_prefix, r.hl_prefix_size);
}

// Emit the block's own text where the deferred rendering would have put it.
// This reproduces the `need_indent` walk in the text callback: the indent goes
// in front of every non-empty line, and an empty line is just its newline.
fn hl_emit_code(r: *MD_ANSI, code: []const u8) void {
    var rest = code;
    while (rest.len > 0) {
        const nl = std.mem.indexOfScalar(u8, rest, '\n') orelse {
            hl_emit_prefix(r);
            render_verbatim(r, rest.ptr, @intCast(rest.len));
            return;
        };
        if (nl > 0) {
            hl_emit_prefix(r);
            render_verbatim(r, rest.ptr, @intCast(nl));
        }
        render_newline(r);
        rest = rest[nl + 1 ..];
    }
}

// Write the highlighter's reply where the block's `DIM … DIM_OFF` region would
// have gone: every non-empty line gets the block's indent, and the block always
// ends in a newline (the default rendering does, and the paragraph after it
// relies on that). The reply is NOT sanitized -- ANSI escapes are what a
// terminal highlighter returns.
fn hl_emit_replacement(r: *MD_ANSI, text: []const u8) void {
    var it = std.mem.splitScalar(u8, text, '\n');
    var first = true;
    while (it.next()) |line| {
        if (!first)
            render_newline(r);
        first = false;
        if (line.len > 0) {
            hl_emit_prefix(r);
            render_verbatim(r, line.ptr, @intCast(line.len));
        }
    }
    if (!std.mem.endsWith(u8, text, "\n"))
        render_newline(r);
}

// **************************************
// ***  ANSI renderer implementation  ***
// **************************************

fn enter_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    switch (detail.*) {
        .doc => {},

        .quote => {
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            r.quote_depth += 1;
        },

        .ul => {
            if (r.need_newline and r.list_depth == 0) {
                render_separator(r);
                r.need_newline = false;
            }
        },

        .ol => |*ol| {
            if (r.need_newline and r.list_depth == 0) {
                render_separator(r);
                r.need_newline = false;
            }
            r.ol_counter = @intCast(ol.start);
        },

        .li => |*li| {
            render_indent(r);
            if (li.is_task) {
                if (li.task_mark == 'x' or li.task_mark == 'X') {
                    render_ansi(r, ANSI_COLOR_GREEN);
                    render_verbatim_lit(r, "[x] ");
                    render_ansi(r, ANSI_COLOR_DEFAULT);
                } else {
                    render_verbatim_lit(r, "[ ] ");
                }
            } else {
                // Check parent: is this inside OL or UL? We track via ol_counter.
                if (r.ol_counter > 0) {
                    var buf: [16]u8 = undefined;
                    const s = std.fmt.bufPrint(&buf, "{d}. ", .{r.ol_counter}) catch unreachable;
                    render_ansi(r, ANSI_DIM);
                    render_verbatim(r, s.ptr, @intCast(s.len));
                    render_ansi(r, ANSI_DIM_OFF);
                    r.ol_counter += 1;
                } else {
                    render_ansi(r, ANSI_DIM);
                    render_verbatim_lit(r, "* ");
                    render_ansi(r, ANSI_DIM_OFF);
                }
            }
            r.list_depth += 1;
            r.li_opened = true;
        },

        .hr => {
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            render_verbatim_lit(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
            r.need_newline = true;
        },

        .h => {
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            render_indent(r);
            render_ansi(r, ANSI_HEADING);
        },

        .code => {
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            r.in_code_block = true;
            r.need_indent = true;
            // With a highlighter installed the block is collected instead of
            // emitted, dim wrapper included -- see hl_begin.
            if (r.highlighter != null) {
                hl_begin(r);
            } else {
                render_ansi(r, ANSI_DIM);
            }
        },

        .html => {},

        .p => {
            if (r.need_newline and !r.li_opened) {
                render_separator(r);
                r.need_newline = false;
            }
            if (!r.li_opened)
                render_indent(r);
            r.li_opened = false;
        },

        .table => {
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
        },

        .thead => {},

        .tbody => {},

        .tr => {
            render_indent(r);
        },

        .th => {
            render_ansi(r, ANSI_BOLD);
        },

        .td => {},

        .frontmatter => {
            if (r.component_nesting > 0) {
                r.in_comp_frontmatter = true;
            } else if (r.flags & MD_ANSI_FLAG_SHOW_FRONTMATTER != 0) {
                render_ansi(r, ANSI_DIM);
            } else {
                r.in_comp_frontmatter = true;
            }
        },

        .component => |*comp| {
            var color = alert_type_color(comp.tag_name.text.ptr, comp.tag_name.size());
            var title: []const u8 = comp.tag_name.text;

            // Use explicit title if provided (e.g. :::danger STOP).
            if (comp.title.len > 0) {
                title = comp.title;
            }

            // For ::alert{type="..."}, resolve color from the type prop.
            if (color == null and ci_eq(comp.tag_name.text.ptr, comp.tag_name.size(), "alert")) {
                var parsed: MD_PARSED_PROPS = undefined;
                md_parse_props(comp.raw_props.ptr, @intCast(comp.raw_props.len), &parsed);
                var pi: c_int = 0;
                while (pi < parsed.n_props) : (pi += 1) {
                    const prop = &parsed.props[@intCast(pi)];
                    if (prop.type == .string and ci_eq(prop.key, prop.key_size, "type")) {
                        color = alert_type_color(prop.value, prop.value_size);
                        if (comp.title.len == 0) {
                            title = if (prop.value) |v| v[0..prop.value_size] else &.{};
                        }
                        break;
                    }
                }
                if (color == null) color = ANSI_COLOR_YELLOW;
            }

            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            r.component_nesting += 1;
            if (color != null) {
                // Render as alert-style box
                r.alert_color = color;
                render_indent(r);
                render_ansi_ptr(r, color.?);
                render_verbatim_lit(r, ALERT_BAR ++ " ");
                render_ansi(r, ANSI_BOLD);
                render_sanitized(r, title.ptr, @intCast(title.len));
                render_ansi(r, ANSI_BOLD_OFF);
                render_ansi(r, ANSI_COLOR_DEFAULT);
                render_newline(r);
                r.in_alert = true;
            } else {
                render_ansi(r, ANSI_COLOR_CYAN);
            }
        },

        .alert => |*det| {
            var color = alert_type_color(det.type_name.text.ptr, det.type_name.size());
            if (color == null) color = ANSI_COLOR_YELLOW;
            if (r.need_newline) {
                render_separator(r);
                r.need_newline = false;
            }
            r.alert_color = color;
            // Render title line: ▌ TYPE
            render_indent(r);
            render_ansi_ptr(r, color.?);
            render_verbatim_lit(r, ALERT_BAR ++ " ");
            render_ansi(r, ANSI_BOLD);
            if (det.type_name.text.len > 0)
                render_sanitized(r, det.type_name.text.ptr, det.type_name.size());
            render_ansi(r, ANSI_BOLD_OFF);
            render_ansi(r, ANSI_COLOR_DEFAULT);
            render_newline(r);
            // Set in_alert after title so render_indent doesn't double-bar
            r.in_alert = true;
        },

        .template => {
            // Transparent — content renders normally within parent component.
        },

        .footnote_def_section => {
            // Set off the definitions from the body with a rule, the same one
            // that separates a table head from its body.
            render_separator(r);
            r.need_newline = false;
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            render_verbatim_lit(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
        },

        .footnote_def => |*d| {
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "[{d}] ", .{d.id}) catch unreachable;
            render_verbatim(r, s.ptr, @intCast(s.len));
            render_ansi(r, ANSI_DIM_OFF);
        },
    }

    return 0;
}

fn leave_block_callback(detail: *const c.BlockDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    switch (std.meta.activeTag(detail.*)) {
        .doc => {},

        .quote => {
            r.quote_depth -= 1;
        },

        .ul => {
            r.ol_counter = 0;
            r.li_opened = false;
            r.need_newline = true;
        },

        .ol => {
            r.ol_counter = 0;
            r.li_opened = false;
            r.need_newline = true;
        },

        .li => {
            r.list_depth -= 1;
            render_newline(r);
        },

        .hr => {},

        .h => {
            render_ansi(r, ANSI_RESET);
            render_newline(r);
            r.need_newline = true;
        },

        .code => {
            // `switch (activeTag(...))` above yields no payload, so the block's
            // own detail (lang/filename/highlights) is read back from the union.
            if (r.hl_active) {
                hl_end(r, &detail.code);
            } else {
                render_ansi(r, ANSI_DIM_OFF);
            }
            r.in_code_block = false;
            r.need_newline = true;
        },

        .html => {},

        .p => {
            render_newline(r);
            r.need_newline = true;
        },

        .table => {
            r.need_newline = true;
        },

        .thead => {
            render_indent(r);
            render_ansi(r, ANSI_DIM);
            render_verbatim_lit(r, HORIZONTAL_RULE);
            render_ansi(r, ANSI_DIM_OFF);
            render_newline(r);
        },

        .tbody => {},

        .tr => {
            render_newline(r);
        },

        .th => {
            render_ansi(r, ANSI_BOLD_OFF);
            render_verbatim_lit(r, "\t");
        },

        .td => {
            render_verbatim_lit(r, "\t");
        },

        .frontmatter => {
            if (r.in_comp_frontmatter) {
                r.in_comp_frontmatter = false;
            } else {
                render_ansi(r, ANSI_DIM_OFF);
                r.need_newline = true;
            }
        },

        .component => {
            r.component_nesting -= 1;
            if (r.in_alert) {
                r.in_alert = false;
                r.alert_color = null;
            } else {
                render_ansi(r, ANSI_COLOR_DEFAULT);
            }
            r.need_newline = true;
        },

        .alert => {
            r.in_alert = false;
            r.alert_color = null;
            r.need_newline = true;
        },

        .template => {
            // Transparent — no output needed.
        },

        .footnote_def_section => {
            r.need_newline = true;
        },

        .footnote_def => {
            render_newline(r);
        },
    }

    return 0;
}

fn enter_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    if (detail.* == .img)
        r.image_nesting_level += 1;

    if (r.image_nesting_level > 0 and detail.* != .img)
        return 0;

    switch (detail.*) {
        .em => render_ansi(r, ANSI_ITALIC),
        .strong => render_ansi(r, ANSI_BOLD),
        .a => |*a| {
            // OSC 8 hyperlink: makes text clickable in supported terminals
            if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0 and a.href.text.len > 0) {
                render_verbatim_lit(r, ANSI_HYPERLINK_OPEN);
                render_attribute(r, &a.href, render_url_ctrl_escaped);
                render_verbatim_lit(r, ANSI_HYPERLINK_SEP);
            }
            render_ansi(r, ANSI_LINK);
        },
        .img => {
            // Images are suppressed — alt text is silently skipped via image_nesting_level
        },
        .code => render_ansi(r, ANSI_COLOR_CYAN),
        .del => render_ansi(r, ANSI_STRIKETHROUGH),
        .mark => render_ansi(r, ANSI_REVERSE),
        .latexmath => render_ansi(r, ANSI_COLOR_YELLOW),
        .latexmath_display => render_ansi(r, ANSI_COLOR_YELLOW),
        .component => render_ansi(r, ANSI_COLOR_CYAN),
        .span => {}, // Transparent: no special styling
        // Self-contained span: the whole marker is emitted here. Only the
        // numeric id reaches the terminal — no document-derived bytes — so
        // there is nothing for render_sanitized to strip.
        .footnote_ref => |*d| {
            render_ansi(r, ANSI_DIM);
            var buf: [32]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "[{d}]", .{d.id}) catch unreachable;
            render_verbatim(r, s.ptr, @intCast(s.len));
            render_ansi(r, ANSI_DIM_OFF);
        },
    }

    return 0;
}

fn leave_span_callback(detail: *const c.SpanDetail, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));

    if (detail.* == .img)
        r.image_nesting_level -= 1;

    if (r.image_nesting_level > 0)
        return 0;

    switch (detail.*) {
        .em => render_ansi(r, ANSI_ITALIC_OFF),
        .strong => render_ansi(r, ANSI_BOLD_OFF),
        .a => |*a| {
            render_ansi(r, ANSI_RESET);
            // Close OSC 8 hyperlink
            if (r.flags & MD_ANSI_FLAG_NO_COLOR == 0 and a.href.text.len > 0)
                render_verbatim_lit(r, ANSI_HYPERLINK_CLOSE);
            // Show URL as dim fallback for terminals without OSC 8
            if (r.flags & MD_ANSI_FLAG_SHOW_URLS != 0 and a.href.text.len > 0 and !a.is_autolink) {
                render_ansi(r, ANSI_LINK_URL);
                render_verbatim_lit(r, " (");
                render_attribute(r, &a.href, render_url_ctrl_escaped);
                render_verbatim_lit(r, ")");
                render_ansi(r, ANSI_RESET);
            }
        },
        .img => {},
        .code => render_ansi(r, ANSI_COLOR_DEFAULT),
        .del => render_ansi(r, ANSI_STRIKE_OFF),
        .mark => render_ansi(r, ANSI_REVERSE_OFF),
        .latexmath => render_ansi(r, ANSI_COLOR_DEFAULT),
        .latexmath_display => render_ansi(r, ANSI_COLOR_DEFAULT),
        .component => render_ansi(r, ANSI_COLOR_DEFAULT),
        .span => {}, // Transparent: no special styling
        .footnote_ref => {}, // enter_span already emitted the marker.
    }

    return 0;
}

fn text_callback(text_type: c.TextType, text_slice: []const c.MD_CHAR, userdata: ?*anyopaque) c.CallbackResult {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));
    const text: [*]const u8 = text_slice.ptr;
    const size: c.MD_SIZE = @intCast(text_slice.len);

    // Suppress component frontmatter text.
    if (r.in_comp_frontmatter)
        return 0;

    // A code block being collected for the highlighter emits nothing here --
    // see hl_capture.
    if (r.hl_active) {
        hl_capture(r, text_type, text, size);
        return 0;
    }

    switch (text_type) {
        .nullchar => {
            render_utf8_codepoint(r, 0x0000, render_verbatim);
        },

        .br => {
            render_newline(r);
            render_indent(r);
        },

        .softbr => {
            if (r.image_nesting_level == 0) {
                render_newline(r);
                render_indent(r);
            } else {
                render_verbatim_lit(r, " ");
            }
        },

        .html => {
            // Raw HTML: suppress in terminal output
        },

        .entity => {
            // A numeric character reference decodes to an arbitrary code point,
            // so `&#27;` is a raw ESC unless the decoded bytes are sanitized too.
            render_entity(r, text, size, render_sanitized);
        },

        .code => {
            if (r.in_code_block) {
                // Inside code block: the parser sends each line and its \n
                // as separate callbacks. We use need_indent to track when
                // we need to emit the indent prefix at line start.
                if (size == 1 and text[0] == '\n') {
                    render_newline(r);
                    r.need_indent = true;
                } else {
                    if (r.need_indent) {
                        render_indent(r);
                        render_verbatim_lit(r, "  ");
                        r.need_indent = false;
                    }
                    render_sanitized(r, text, size);
                }
            } else {
                // Inline code span
                render_sanitized(r, text, size);
            }
        },

        else => {
            render_sanitized(r, text, size);
        },
    }

    return 0;
}

fn debug_log_callback(msg: []const u8, userdata: ?*anyopaque) void {
    const r: *MD_ANSI = @ptrCast(@alignCast(userdata.?));
    if (r.flags & MD_ANSI_FLAG_DEBUG != 0)
        diag.logMessage(msg);
}

// **************************************
// ***  Heal-before-render wrapper    ***
// **************************************

const MD4X_HEAL_BUF = struct {
    data: ?[*]u8,
    size: c_uint,
    cap: c_uint,
    err: c_int,
};

fn md4x_heal_buf_append(text: [*c]const u8, size: c_uint, userdata: ?*anyopaque) void {
    const buf: *MD4X_HEAL_BUF = @ptrCast(@alignCast(userdata.?));
    if (buf.err != 0) return;
    if (buf.size + size > buf.cap) {
        const new_cap: c_uint = buf.cap + buf.cap / 2 + size + 256;
        if (buf.data) |old| {
            const p = c_allocator.realloc(old[0..buf.cap], new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        } else {
            const p = c_allocator.alloc(u8, new_cap) catch {
                buf.err = 1;
                return;
            };
            buf.data = p.ptr;
        }
        buf.cap = new_cap;
    }
    @memcpy(buf.data.?[buf.size .. buf.size + size], @as([*]const u8, @ptrCast(text))[0..size]);
    buf.size += size;
}

// Run md_heal and return the healed buffer. Caller must free buf.data.
// Returns 0 on success, -1 on error.
fn md4x_heal_input(input: [*c]const c.MD_CHAR, input_size: c.MD_SIZE, buf: *MD4X_HEAL_BUF) c_int {
    buf.data = null;
    buf.size = 0;
    buf.cap = 0;
    buf.err = 0;
    const ret = heal.md_heal(@ptrCast(input), input_size, md4x_heal_buf_append, buf);
    if (buf.err != 0) return -1;
    return ret;
}

fn heal_buf_free(buf: *MD4X_HEAL_BUF) void {
    if (buf.data) |d| {
        c_allocator.free(d[0..buf.cap]);
    }
}

pub fn md_ansi(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    renderer_flags: c_uint,
) c_int {
    return md_ansi_ex(input, input_size, process_output, userdata, renderer_flags, null);
}

pub fn md_ansi_ex(
    input: [*c]const c.MD_CHAR,
    input_size: c.MD_SIZE,
    process_output: ProcessOutputFn,
    userdata: ?*anyopaque,
    renderer_flags: c_uint,
    opts: ?*const MD_ANSI_OPTS,
) c_int {
    var input_ptr = input;
    var size = input_size;

    // Heal-before-render: run md_heal first, then render the healed output.
    if (renderer_flags & MD_ANSI_FLAG_HEAL != 0) {
        var hbuf: MD4X_HEAL_BUF = undefined;
        if (md4x_heal_input(input, input_size, &hbuf) != 0) {
            heal_buf_free(&hbuf);
            return -1;
        }
        const ret = md_ansi_ex(@ptrCast(hbuf.data), hbuf.size, process_output, userdata, renderer_flags & ~MD_ANSI_FLAG_HEAL, opts);
        heal_buf_free(&hbuf);
        return ret;
    }

    const parser: c.Parser = .{
        .enter_block = enter_block_callback,
        .leave_block = leave_block_callback,
        .enter_span = enter_span_callback,
        .leave_span = leave_span_callback,
        .text = text_callback,
        .debug_log = debug_log_callback,
    };

    // zeroInit rather than zeroes: `process_output` is a non-optional function
    // pointer, which has no zero value.
    var render: MD_ANSI = std.mem.zeroInit(MD_ANSI, .{ .process_output = process_output });
    render.userdata = userdata;
    render.flags = renderer_flags;
    if (opts) |o| render.highlighter = o.highlighter;

    // Consider skipping UTF-8 byte order mark (BOM).
    if (renderer_flags & MD_ANSI_FLAG_SKIP_UTF8_BOM != 0 and @sizeOf(c.MD_CHAR) == 1) {
        const bom = [_]u8{ 0xef, 0xbb, 0xbf };
        if (size >= bom.len and std.mem.eql(u8, @as([*]const u8, @ptrCast(input_ptr))[0..bom.len], &bom)) {
            input_ptr += bom.len;
            size -= bom.len;
        }
    }

    const ret = md4x.md_parse(@ptrCast(input_ptr), size, &parser, @ptrCast(&render));

    // A parse aborted inside a code block drops that block's collected text
    // with the buffer -- the output is truncated at the abort either way.
    render.hl_code.deinit();

    return ret;
}
