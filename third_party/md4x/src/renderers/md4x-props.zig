// SPDX-License-Identifier: MIT
//
// Shared component property parser for the md4x renderers.
//
// This is the Zig counterpart of the (orphaned) header-only md4x-props.h. The C
// header's md_parse_props() is `static`, so @cImport mistranslates its body
// (array-index post-increment) and cannot link it cleanly. The parser is ported
// to Zig here and shared by the AST, HTML, and ANSI renderers. Behavior is kept
// byte-for-byte identical to the C source.
//
// Imported (not @cImport'd into a clashing symbol) by each renderer lib: Zig
// compiles its own internal copy per importing artifact, so there is no
// exported-symbol collision and no build.zig change is required.

const std = @import("std");

// MD_* types now come from the Zig-native abi module (replacing md4x.h).
const c = @import("abi");

pub const MD_MAX_PROPS: usize = 32;
pub const MD_CLASS_BUF_SIZE: usize = 512;

// Prop kind. Explicit c_int tag values mirror the C MD_PROP_TYPE enum
// (STRING=0, BOOLEAN=1, BIND=2) so callers may compare against the tags
// directly as well as switch on them.
pub const MD_PROP_TYPE = enum(c_int) {
    string = 0, // key="value", key='value', or key=value
    boolean = 1, // bare word (no value)
    bind = 2, // :key='value' (JSON passthrough)
};

pub const MD_PROP = struct {
    type: MD_PROP_TYPE = .string,
    key: [*]const u8 = undefined,
    key_size: c.MD_SIZE = 0,
    value: ?[*]const u8 = null,
    value_size: c.MD_SIZE = 0,
};

// Parse result. Only the four scalars carry a meaningful default: the two
// arrays are valid exactly over `props[0..n_props]` and `class_buf[0..class_len]`,
// and md_parse_props() writes every byte in those ranges before a consumer can
// read it (see the reset comment there). They are therefore `undefined` rather
// than zeroed — a `.{}` here must stay as cheap as the reset the parser does.
pub const MD_PARSED_PROPS = struct {
    props: [MD_MAX_PROPS]MD_PROP = undefined,
    n_props: c_int = 0,
    class_buf: [MD_CLASS_BUF_SIZE]u8 = undefined,
    class_len: c.MD_SIZE = 0,
    id: ?[*]const u8 = null,
    id_size: c.MD_SIZE = 0,
    /// Emission position of `#id` / the merged `.class` among the key-value
    /// props, so a consumer can reproduce SOURCE order instead of flushing the
    /// shorthands first and last. `-1` when the shorthand is absent.
    ///
    /// The unit is a *slot*: one per key-value prop, plus one for the id and one
    /// for the merged class, so the three kinds share a single ordering. Both
    /// record the position of their FIRST occurrence (`#a #b` keeps `a`'s slot
    /// and `b`'s value; every `.class` merges into the one buffer at the first
    /// one's slot) — the same "position from first insertion, value from last
    /// write" rule JS object spread uses.
    id_slot: c_int = -1,
    class_slot: c_int = -1,
};

/// One emittable attribute of a parse result, in source order.
pub const Slot = union(enum) {
    /// `#id` shorthand — emitted under the attribute name `id`.
    id: []const u8,
    /// Merged `.class` shorthands — emitted under the attribute name `class`.
    class: []const u8,
    /// A key-value, boolean or bind prop.
    prop: *const MD_PROP,
};

/// Whether a parse result carries an explicit `id`, written either as the
/// `#id` shorthand or as an ordinary `id="..."` key-value prop. Both emit under
/// the attribute name `id`, so a caller that would otherwise supply one of its
/// own (a heading's generated slug) must treat them alike — emitting both puts
/// two `id` attributes on one tag and a duplicate key in the AST.
pub fn parsedHasId(parsed: *const MD_PARSED_PROPS) bool {
    if (parsed.id != null and parsed.id_size > 0) return true;
    var i: usize = 0;
    while (i < @as(usize, @intCast(parsed.n_props))) : (i += 1) {
        const p = &parsed.props[i];
        if (p.key_size == 2 and std.mem.eql(u8, p.key[0..2], "id")) return true;
    }
    return false;
}

/// Walk a parse result in **source order**. `md_parse_props` accumulates the
/// `#id` and the `.class` run out of band (last-wins / merged), and emitting
/// them around the prop list reordered the attributes: `{#status .badge
/// data-state="x"}` came out as id, data-state, class. The JSON key order is
/// observable to AST consumers, so both renderers iterate slots instead.
pub const SlotIterator = struct {
    parsed: *const MD_PARSED_PROPS,
    slot: c_int = 0,
    next_prop: c_int = 0,

    pub fn next(self: *SlotIterator) ?Slot {
        const p = self.parsed;
        const total = p.n_props +
            @as(c_int, @intFromBool(p.id_slot >= 0)) +
            @as(c_int, @intFromBool(p.class_slot >= 0));
        while (self.slot < total) {
            const s = self.slot;
            self.slot += 1;
            if (s == p.id_slot)
                return .{ .id = p.id.?[0..p.id_size] };
            if (s == p.class_slot)
                return .{ .class = (&p.class_buf)[0..p.class_len] };
            if (self.next_prop < p.n_props) {
                const idx: usize = @intCast(self.next_prop);
                self.next_prop += 1;
                return .{ .prop = &p.props[idx] };
            }
        }
        return null;
    }
};

pub fn slots(parsed: *const MD_PARSED_PROPS) SlotIterator {
    return .{ .parsed = parsed };
}

/// The attribute name a slot emits under. Note a `.bind` prop's key already has
/// its leading `:` stripped by the parse, which is the name the HTML renderer
/// emits; the AST renderer re-adds the `:` itself.
pub fn slotKey(s: Slot) []const u8 {
    return switch (s) {
        .id => "id",
        .class => "class",
        .prop => |p| p.key[0..p.key_size],
    };
}

/// True when the prop string defines `key` — used to decide which component
/// frontmatter (YAML) keys an inline `{...}` shadows. Inline attributes take
/// precedence over YAML block props (`.agents/comark/components.md:182`).
pub fn propsHaveKey(parsed: *const MD_PARSED_PROPS, key: []const u8) bool {
    var it = slots(parsed);
    while (it.next()) |s| {
        if (std.mem.eql(u8, slotKey(s), key)) return true;
    }
    return false;
}

// The slot the next attribute to be recorded would occupy: one per key-value
// prop pushed so far, plus one each for an already-seen `#id` / `.class`.
// Derived rather than tracked, so the three prop-push sites need no bookkeeping.
fn next_slot(out: *const MD_PARSED_PROPS) c_int {
    return out.n_props +
        @as(c_int, @intFromBool(out.id_slot >= 0)) +
        @as(c_int, @intFromBool(out.class_slot >= 0));
}

// Parse a raw component property string (`key="value" bool #id .class :bind='json'`)
// into the structured MD_PARSED_PROPS form. All key/value pointers are zero-copy
// references into `raw` (not NUL-terminated — use the *_size fields).
pub fn md_parse_props(raw: ?[*]const u8, size: c.MD_SIZE, out: *MD_PARSED_PROPS) void {
    // Reset only the four scalars. This used to be `out.* = .{}`, which LLVM
    // lowers to a `memset(out, 0, 1560)` even in ReleaseFast — a 1 KB `props`
    // array plus a 512-byte `class_buf` cleared once per attributed span, link,
    // image and component in the document.
    //
    // Leaving the two arrays undefined is sound because every byte a consumer
    // may read is written by this parse before it becomes readable:
    //
    //   * `props[0..n_props]` — each of the three push sites (quoted value,
    //     unquoted value, bare boolean) assigns all five MD_PROP fields in
    //     straight-line code immediately after bumping `n_props`, with no
    //     branch or early exit in between, so an entry is never half-populated.
    //     Every consumer stops at `n_props`: `render_html_component_props`
    //     (html), `jsonWriteParsedProps` (ast) and the `::alert{type=…}` scan
    //     (ansi). `MD_PROP.key` already defaulted to `undefined`, so no caller
    //     could have been reading a zeroed entry anyway.
    //   * `class_buf[0..class_len]` — `class_len` only ever advances over bytes
    //     this function just wrote: the separator space is stored *before* the
    //     `+= 1`, and the `@memcpy` fills exactly the range the following
    //     `+= len` claims (if either bound check fails, `class_len` does not
    //     move). Both consumers pass `class_len` as an explicit length.
    //
    // The reset must stay ahead of the `size == 0` return: the ANSI caller
    // passes a possibly-empty `raw_props` and then reads `n_props`.
    out.n_props = 0;
    out.class_len = 0;
    out.id = null;
    out.id_size = 0;
    out.id_slot = -1;
    out.class_slot = -1;

    if (raw == null or size == 0)
        return;
    const r = raw.?;

    var i: c.MD_OFFSET = 0;
    while (i < size) {
        // Skip whitespace.
        while (i < size and (r[i] == ' ' or r[i] == '\t'))
            i += 1;
        if (i >= size)
            break;

        if (r[i] == '#') {
            // #id shorthand → store as id (last wins).
            i += 1;
            const start = i;
            while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                i += 1;
            if (i > start) {
                // Last wins for the value, first wins for the position.
                if (out.id_slot < 0) out.id_slot = next_slot(out);
                out.id = r + start;
                out.id_size = i - start;
            }
        } else if (r[i] == '.') {
            // .class shorthand → append to merged class buffer.
            i += 1;
            const start = i;
            while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}' and r[i] != '.')
                i += 1;
            if (i > start) {
                const len = i - start;
                if (out.class_len > 0 and out.class_len + 1 < MD_CLASS_BUF_SIZE) {
                    out.class_buf[out.class_len] = ' ';
                    out.class_len += 1;
                }
                if (out.class_len + len < MD_CLASS_BUF_SIZE) {
                    // The slot is claimed only once bytes are actually in the
                    // buffer, so a `.class` that did not fit cannot leave an
                    // empty `class=""` slot behind.
                    if (out.class_slot < 0) out.class_slot = next_slot(out);
                    @memcpy(out.class_buf[out.class_len .. out.class_len + len], (r + start)[0..len]);
                    out.class_len += len;
                }
            }
        } else {
            // key="value", key='value', key=value, :key='json', or bare boolean.
            var key_start = i;
            var is_bind = false;

            if (r[i] == ':') {
                is_bind = true;
                i += 1;
                key_start = i;
            }

            while (i < size and r[i] != '=' and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                i += 1;

            if (i > key_start and i < size and r[i] == '=') {
                // key=...
                const key_end = i;
                i += 1; // skip '='

                if (i < size and (r[i] == '"' or r[i] == '\'')) {
                    // Quoted value.
                    const quote = r[i];
                    i += 1;
                    const val_start = i;
                    while (i < size and r[i] != quote)
                        i += 1;

                    if (out.n_props < MD_MAX_PROPS) {
                        const p = &out.props[@intCast(out.n_props)];
                        out.n_props += 1;
                        p.type = if (is_bind) .bind else .string;
                        p.key = r + key_start;
                        p.key_size = key_end - key_start;
                        p.value = r + val_start;
                        p.value_size = i - val_start;
                    }
                    if (i < size) i += 1; // skip closing quote
                } else {
                    // Unquoted value.
                    const val_start = i;
                    while (i < size and r[i] != ' ' and r[i] != '\t' and r[i] != '}')
                        i += 1;

                    if (out.n_props < MD_MAX_PROPS) {
                        const p = &out.props[@intCast(out.n_props)];
                        out.n_props += 1;
                        p.type = if (is_bind) .bind else .string;
                        p.key = r + key_start;
                        p.key_size = key_end - key_start;
                        p.value = r + val_start;
                        p.value_size = i - val_start;
                    }
                }
            } else if (i > key_start) {
                // Bare word → boolean prop.
                if (out.n_props < MD_MAX_PROPS) {
                    const p = &out.props[@intCast(out.n_props)];
                    out.n_props += 1;
                    p.type = .boolean;
                    p.key = r + key_start;
                    p.key_size = i - key_start;
                    p.value = null;
                    p.value_size = 0;
                }
            } else {
                // Skip unrecognized character to avoid infinite loop.
                i += 1;
            }
        }
    }
}
