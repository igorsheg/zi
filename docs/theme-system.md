# Theme System

Status: **Spec / proposal — not yet implemented**
Owner: TUI
Target: full replacement of `src/tui/theme.zig` (nuclear refactor, no compat layer)

## Motivation

The current theme system (`src/tui/theme.zig`) has three problems:

1. **No opaque surfaces.** The modal list picker (model picker, session picker,
   login picker) renders with a transparent background, letting the editor
   bleed through behind it. There is no semantic token for "floating modal
   background" because there is no concept of surface tiers — we only have
   ad-hoc bg tokens like `user_message_bg`, `tool_pending_bg`, etc.
2. **Inconsistent granularity.** 48 foreground tokens (including 6
   `thinking_*` levels and 5 redundant "text" variants) but only 6 background
   tokens. Some tokens describe UI concepts (`border`), others describe
   features (`bash_mode`), others describe states (`tool_pending_bg`). No
   unifying mental model.
3. **No ecosystem compatibility.** Theme values are hard-coded in Zig
   (`Theme.dark`), so users cannot bring their own themes and we cannot
   consume themes from other projects.

This spec proposes a nuclear refactor that merges the best ideas from three
production TUI theme systems — pi-mono, OpenCode, and Neovim — into a single
flat token namespace with surface tiers, hue-gradient thinking levels,
256-color fallback, HTML export tokens, and sacred `Color.default` discipline.

## Prior art

The design is directly informed by studying five theming traditions. The two
primary sources — **pi-mono** and **OpenCode** — are production TUI coding
agents with real users; they each solve problems the other doesn't, and this
spec explicitly merges them.

| System         | What we borrow                                            |
| -------------- | --------------------------------------------------------- |
| **pi-mono**    | 256-color fallback with perceptual quantization, hue-gradient thinking levels (6 distinct colors, not opacity), `vars` block for palette reuse, separate `dark.json` / `light.json` files, `export` block for HTML session export, battle-tested 51-token set. |
| **OpenCode**   | Single flat namespace, surface-tier prefix convention, contrast-based `selectedListItemText` fallback, diagnostic naming (`info` included), granular markdown tokens (14), `defs` palette variables, ~35 community theme JSON files. |
| **Neovim**     | Semantic group vocabulary (`NormalFloat`, `Pmenu`, `Visual`) — the conceptual foundation for "floating surface" as a first-class token. |
| **Tailwind**   | Surface-tier discipline (`background` → `panel` → `element` → `menu`) as explicit layers of elevation — neither pi-mono nor OpenCode have this, and its absence is exactly what causes the picker bleed-through bug. |
| **Ghostty/Kitty** | `Color.default` is sacred. The user picked their terminal background for a reason. Never auto-fill it unless the token explicitly demands it (modals, selection). |

### pi-mono references

Source files under `.references/pi-mono/` (also upstream at
[badlogic/pi-mono](https://github.com/badlogic/pi-mono)):

- `packages/coding-agent/src/modes/interactive/theme/theme.ts` — the
  canonical `Theme` class (lines 342–441), `ThemeColor` / `ThemeBg` type
  unions (lines 99–152), 256-color quantization with perceptual distance
  (`rgbTo256`, lines 241–272), `detectColorMode` terminal probing
  (lines 160–185), and variable-reference resolution (`resolveVarRefs`,
  `resolveThemeColors`, lines 309–336).
- `packages/coding-agent/src/modes/interactive/theme/theme-schema.json` —
  JSON Schema for theme files. Defines the `vars` / `colors` / `export`
  top-level shape.
- `packages/coding-agent/src/modes/interactive/theme/dark.json` — reference
  dark theme. Notable: `"text": ""` convention (empty string ⇒ terminal
  default), `thinkingOff` → `thinkingXhigh` as a **hue gradient** (gray →
  blue → purple → magenta), not a brightness ramp.
- `packages/coding-agent/src/modes/interactive/theme/light.json` —
  companion light theme (separate file, not variant object).

### OpenCode references

Source files from
[anomalyco/opencode](https://github.com/anomalyco/opencode):

- `packages/plugin/src/tui.ts` — canonical `TuiThemeCurrent` type definition
  (~52 tokens, flat namespace, surface-tier naming).
- `packages/opencode/src/cli/cmd/tui/context/theme.tsx` — runtime theme
  loading, JSON resolution with `defs` references, variant handling
  (`{ dark, light }`), and the `selectedForeground` contrast-fallback
  function (~30 lines, luminance-weighted).
- `packages/opencode/src/cli/cmd/tui/context/theme/opencode.json` — reference
  theme JSON with `defs` (palette variables) and `theme` (token → variant
  object mapping).
- `packages/opencode/src/cli/cmd/tui/context/theme/*.json` — ~35 community
  theme files: `aura`, `ayu`, `carbonfox`, `catppuccin*`, `cobalt2`,
  `cursor`, `dracula`, `everforest`, `flexoki`, `github`, `gruvbox`,
  `kanagawa`, `material`, `matrix`, `mercury`, `monokai`, `nightowl`,
  `nord`, `one-dark`, `palenight`, `rosepine`, `solarized`, `synthwave84`,
  `tokyonight`, `vercel`, `vesper`, `zenburn`, etc.

## Principles

1. **`Color.default` is sacred.** It means "the user's terminal color,
   leave it alone." Only surfaces that *must* be opaque (modals, selection)
   override it. Never auto-fill content areas. Corresponds to pi-mono's
   `""` empty-string convention, promoted here to a first-class rule.
2. **Semantic over visual.** Tokens describe *what something is*, never
   *what it looks like*. No `gray_3`, no `dark_blue`.
3. **Single flat namespace.** One enum, one lookup function. Token names
   encode whether they're fg or bg (`background_*` prefix). Matches
   OpenCode and every ecosystem theme format (base16, VSCode, Neovim
   highlight groups). Pi-mono splits into `ThemeColor` / `ThemeBg` — we
   don't, because the flat approach composes better with JSON loading.
4. **Surface tiers are first-class.** Four explicit elevation layers
   (`background` → `panel` → `element` → `menu`). Neither pi-mono nor
   OpenCode's flat surface list captures elevation explicitly. This is the
   single biggest structural improvement over both systems, and it's what
   directly fixes the model picker bleed-through.
5. **Diagnostics use standard names.** `success` / `warning` / `error` /
   `info` — matches LSP, Neovim, VSCode, OpenCode. Pi-mono is missing
   `info`; we add it.
6. **Thinking is a hue gradient, not opacity.** Six distinct color tokens
   (`thinking_off` through `thinking_xhigh`), following pi-mono's lead.
   OpenCode's `thinkingOpacity` scalar cannot express a gray → blue →
   purple → magenta ramp that communicates reasoning effort visually.
7. **Terminal compatibility is not optional.** Themes must render correctly
   on 256-color terminals (Terminal.app, screen, Linux console). The
   renderer performs perceptual truecolor → 256 quantization at emit time;
   themes remain authored in hex. Ported from pi-mono's `rgbTo256`.
8. **Themes are data.** Default themes live as Zig constants for Phase 1
   (zero-dep, comptime), but the token set and JSON format are designed to
   be loadable from external theme files in Phase 3.
9. **Export-ready.** Reserve tokens for HTML session export (pi-mono's
   `export` block). Session transcripts will be rendered to HTML eventually;
   having the export palette in the theme avoids a second parallel system.

## Token set

**Total: 64 tokens.** Derived from OpenCode's 52-token structure, extended
with pi-mono's 6 thinking levels, 3 tool-state backgrounds, and 3 export
tokens. Naming is `snake_case` per Zig convention. Every token has a
documented mapping to its equivalent in pi-mono (`pm`), OpenCode (`oc`), and
Neovim highlight groups (`nvim`) where one exists.

```zig
pub const Token = enum {
    // ── Accents (3 tiers) ───────────────────────────────────
    /// Brand / primary accent. App name, active prompts, key highlights.
    /// pm: accent · oc: primary · nvim: Special, Identifier
    primary,
    /// Secondary accent. Labels, tags, alt highlights.
    /// pm: (none — closest: customMessageLabel) · oc: secondary · nvim: Type
    secondary,
    /// Tertiary accent. Subtle highlights, decorative.
    /// pm: borderAccent · oc: accent
    accent,

    // ── Diagnostics (4 — LSP/Neovim standard) ───────────────
    /// Green. Tool success, test pass, diff-added fg.
    /// pm: success · oc: success · nvim: DiagnosticOk
    success,
    /// Yellow. Warnings, deprecations, unsaved state, bash mode.
    /// pm: warning · oc: warning · nvim: DiagnosticWarn
    warning,
    /// Red. Errors, tool failures, diff-removed fg.
    /// pm: error · oc: error · nvim: DiagnosticError
    @"error",
    /// Blue/cyan. Info messages, hints. Pi-mono doesn't have this token;
    /// zi adds it for LSP/Neovim alignment.
    /// pm: (none) · oc: info · nvim: DiagnosticInfo
    info,

    // ── Text (2 tiers + computed) ───────────────────────────
    /// Primary text. Usually Color.default — respects terminal fg.
    /// pm: text (= "") · oc: text · nvim: Normal
    text,
    /// De-emphasized text: timestamps, metadata, placeholders, hints.
    /// pm: muted · oc: textMuted · nvim: Comment, NonText
    text_muted,
    /// Selected list item fg. Computed fallback via `Theme.selectedFg`
    /// (luminance-based contrast) when set to Color.default.
    /// pm: (none — latent bug) · oc: selectedListItemText
    selected_list_item_text,

    // ── Surfaces (4 tiers — THE key structural improvement) ──
    /// Root editor/transcript background. Usually Color.default — respects
    /// the user's terminal bg.
    /// pm: (none — implicit) · oc: background · nvim: Normal (bg)
    background,
    /// Static chrome: sidebar, footer, header. Subtle lift from background.
    /// pm: (none — userMessageBg / customMessageBg are feature-specific,
    /// not a reusable panel layer) · oc: backgroundPanel
    /// nvim: StatusLine, TabLine
    background_panel,
    /// Interactive elements: input fields, selected rows, inline highlights.
    /// pm: selectedBg · oc: backgroundElement · nvim: CursorLine, PmenuSel
    background_element,
    /// Floating surfaces: modals, pickers, popups, command palette.
    /// MUST be opaque. This is the fix for the model picker bleed-through.
    /// pm: (none — the bug pi-mono also has) · oc: backgroundMenu
    /// nvim: NormalFloat, Pmenu
    background_menu,

    // ── Borders (3 tiers) ───────────────────────────────────
    /// Default borders on inactive panes.
    /// pm: border · oc: border
    border,
    /// Focused pane / active modal border.
    /// pm: borderAccent · oc: borderActive · nvim: FloatBorder (active)
    border_active,
    /// Inner separators: search input → list, hunk dividers.
    /// pm: borderMuted · oc: borderSubtle
    border_subtle,

    // ── Tool states (3 — preserved from pi-mono) ────────────
    /// Background while a tool call is pending/streaming.
    /// pm: toolPendingBg · oc: (none — uses backgroundElement)
    tool_pending_bg,
    /// Background for completed tool calls. Usually Color.default —
    /// success is quiet.
    /// pm: toolSuccessBg · oc: (none)
    tool_success_bg,
    /// Background for failed tool calls. Red-tinted.
    /// pm: toolErrorBg · oc: (none — uses diff_removed_bg)
    tool_error_bg,

    // ── Diff (12 — matches OpenCode) ────────────────────────
    /// pm: toolDiffAdded · oc: diffAdded
    diff_added,
    /// pm: toolDiffRemoved · oc: diffRemoved
    diff_removed,
    /// pm: toolDiffContext · oc: diffContext
    diff_context,
    /// pm: (none) · oc: diffHunkHeader
    diff_hunk_header,
    /// Inner word-level highlight within an added line.
    /// pm: (none) · oc: diffHighlightAdded
    diff_highlight_added,
    /// pm: (none) · oc: diffHighlightRemoved
    diff_highlight_removed,
    /// pm: (none) · oc: diffAddedBg
    diff_added_bg,
    /// pm: (none) · oc: diffRemovedBg
    diff_removed_bg,
    /// pm: (none) · oc: diffContextBg
    diff_context_bg,
    /// pm: (none) · oc: diffLineNumber
    diff_line_number,
    /// pm: (none) · oc: diffAddedLineNumberBg
    diff_added_line_number_bg,
    /// pm: (none) · oc: diffRemovedLineNumberBg
    diff_removed_line_number_bg,

    // ── Markdown (14 — matches OpenCode, granular on purpose) ──
    /// pm: (none — uses text) · oc: markdownText
    markdown_text,
    /// pm: mdHeading · oc: markdownHeading
    markdown_heading,
    /// pm: mdLink · oc: markdownLink
    markdown_link,
    /// pm: mdLinkUrl · oc: markdownLinkText
    markdown_link_text,
    /// pm: mdCode · oc: markdownCode
    markdown_code,
    /// pm: mdCodeBlock · oc: markdownCodeBlock
    markdown_code_block,
    /// pm: mdQuote · oc: markdownBlockQuote
    markdown_block_quote,
    /// pm: (none) · oc: markdownEmph
    markdown_emph,
    /// pm: (none) · oc: markdownStrong
    markdown_strong,
    /// pm: mdHr · oc: markdownHorizontalRule
    markdown_horizontal_rule,
    /// pm: mdListBullet · oc: markdownListItem
    markdown_list_item,
    /// pm: (none) · oc: markdownListEnumeration
    markdown_list_enumeration,
    /// pm: (none) · oc: markdownImage
    markdown_image,
    /// pm: (none) · oc: markdownImageText
    markdown_image_text,

    // ── Syntax (9 — the de-facto standard, shared across pm/oc) ──
    /// pm: syntaxComment · oc: syntaxComment · nvim: Comment
    syntax_comment,
    /// pm: syntaxKeyword · oc: syntaxKeyword · nvim: Keyword
    syntax_keyword,
    /// pm: syntaxFunction · oc: syntaxFunction · nvim: Function
    syntax_function,
    /// pm: syntaxVariable · oc: syntaxVariable · nvim: Identifier
    syntax_variable,
    /// pm: syntaxString · oc: syntaxString · nvim: String
    syntax_string,
    /// pm: syntaxNumber · oc: syntaxNumber · nvim: Number
    syntax_number,
    /// pm: syntaxType · oc: syntaxType · nvim: Type
    syntax_type,
    /// pm: syntaxOperator · oc: syntaxOperator · nvim: Operator
    syntax_operator,
    /// pm: syntaxPunctuation · oc: syntaxPunctuation · nvim: Delimiter
    syntax_punctuation,

    // ── Thinking levels (6 — hue gradient, not opacity) ─────
    // Rationale: pi-mono ships a distinct *hue* per reasoning level
    // (gray → blue → purple → magenta) to visually communicate effort.
    // OpenCode's single `thinkingOpacity` scalar cannot express this.
    // zi follows pi-mono here.
    /// Thinking disabled. Darkest gray.
    /// pm: thinkingOff
    thinking_off,
    /// Minimal reasoning. Slightly brighter gray.
    /// pm: thinkingMinimal
    thinking_minimal,
    /// Low reasoning. Shifting toward blue.
    /// pm: thinkingLow
    thinking_low,
    /// Medium reasoning. Blue.
    /// pm: thinkingMedium
    thinking_medium,
    /// High reasoning. Purple.
    /// pm: thinkingHigh
    thinking_high,
    /// Extra-high reasoning. Magenta.
    /// pm: thinkingXhigh
    thinking_xhigh,

    // ── Export (3 — for HTML session export) ────────────────
    // Reserved for rendering session transcripts to HTML. Kept in the
    // theme so a single theme file drives both terminal and HTML output.
    /// HTML page background.
    /// pm: export.pageBg
    export_page_bg,
    /// HTML card background (messages, tool calls).
    /// pm: export.cardBg
    export_card_bg,
    /// HTML info panel background (sidebar, metadata).
    /// pm: export.infoBg
    export_info_bg,
};
```

### Token count breakdown

| Group          | Count | Source                                   |
| -------------- | ----: | ---------------------------------------- |
| Accents        |     3 | pm+oc merged                             |
| Diagnostics    |     4 | oc (pm + `info`)                         |
| Text           |     3 | oc                                       |
| Surfaces       |     4 | oc (the critical tier system)            |
| Borders        |     3 | pm+oc merged                             |
| Tool states    |     3 | pm (preserved — oc has no equivalent)    |
| Diff           |    12 | oc (pm has only 3)                       |
| Markdown       |    14 | oc (pm has 10)                           |
| Syntax         |     9 | pm+oc (identical)                        |
| Thinking       |     6 | pm (oc has single opacity scalar)        |
| Export         |     3 | pm (oc has no equivalent)                |
| **Total**      |  **64** |                                        |

### Old zi tokens → new tokens

| Old token                           | New token                                |
| ----------------------------------- | ---------------------------------------- |
| `accent`                            | `primary`                                |
| `border_accent`                     | `border_active` (closer semantic)        |
| `text`                              | `text` (kept, stays `Color.default`)     |
| `muted`                             | `text_muted`                             |
| `dim`                               | `text_muted` + `attrs.dim` at render time |
| `border_muted`                      | `border_subtle`                          |
| `thinking_text`                     | drop — use `thinking_off` / `_minimal`   |
| `thinking_off` … `thinking_xhigh` (6) | **kept** as `thinking_off` … `thinking_xhigh` — hue gradient preserved |
| `user_message_text`, `custom_message_text`, `tool_title`, `tool_output` | `text` / `text_muted` — redundant in pi-mono, all were `""` or `gray` |
| `custom_message_label`              | `secondary`                              |
| `bash_mode`                         | `warning` (both are yellow, semantically close) |
| `selected_bg`                       | `background_element`                     |
| `user_message_bg`                   | `background_panel`                       |
| `custom_message_bg`                 | `background_panel`                       |
| `tool_pending_bg`                   | **kept** as `tool_pending_bg`            |
| `tool_success_bg`                   | **kept** as `tool_success_bg`            |
| `tool_error_bg`                     | **kept** as `tool_error_bg`              |
| `md_*` (10 tokens)                  | `markdown_*` (14 — expanded)             |

**Net change:** 48 fg + 6 bg = 54 tokens → 64 tokens (+10). The growth
comes from: 4-tier surfaces (+3 vs 1 ad-hoc `selected_bg`), expanded diff
(+9), expanded markdown (+4), export (+3), and `info` diagnostic (+1).
Consolidation recovers some: dropped `dim`, `thinking_text`, and the four
redundant `*_text` / `*_title` tokens (−6).

## Theme struct

```zig
// src/tui/theme.zig
const std = @import("std");
const Color = @import("cell.zig").Color;

pub const Token = enum { /* … as above … */ };

pub const Theme = struct {
    colors: [@typeInfo(Token).@"enum".fields.len]Color,

    pub fn get(self: *const Theme, t: Token) Color {
        return self.colors[@intFromEnum(t)];
    }

    /// Resolve the thinking-level color for a given reasoning level.
    /// Convenience wrapper around `get()` — see pi-mono's
    /// `getThinkingBorderColor` (theme.ts:418-436) for the same pattern.
    pub fn thinking(self: *const Theme, level: ThinkingLevel) Color {
        return self.get(switch (level) {
            .off => .thinking_off,
            .minimal => .thinking_minimal,
            .low => .thinking_low,
            .medium => .thinking_medium,
            .high => .thinking_high,
            .xhigh => .thinking_xhigh,
        });
    }

    /// Resolve the foreground color for a selected list item.
    ///
    /// If the theme sets `selected_list_item_text` to a concrete color, use
    /// it. Otherwise fall back to a luminance-based contrast pick against
    /// the provided `bg` — mirrors OpenCode's `selectedForeground` helper
    /// in `packages/opencode/src/cli/cmd/tui/context/theme.tsx`.
    ///
    /// When `bg` itself is `Color.default` (terminal-driven, unknown at
    /// compile time), fall back to `primary` — the theme's most prominent
    /// accent is the best guess for "will be readable".
    pub fn selectedFg(self: *const Theme, bg: Color) Color {
        const explicit = self.get(.selected_list_item_text);
        if (!explicit.is_default) return explicit;
        if (bg.is_default) return self.get(.primary);
        const lum = 0.299 * @as(f32, @floatFromInt(bg.r)) +
                    0.587 * @as(f32, @floatFromInt(bg.g)) +
                    0.114 * @as(f32, @floatFromInt(bg.b));
        return if (lum > 127.5) Color.rgb(0, 0, 0) else Color.rgb(255, 255, 255);
    }

    pub const dark: Theme = buildDark();
    // pub const light: Theme = buildLight();  // future
};
```

## Default dark theme

Values are illustrative; the final palette will be tuned during
implementation. The palette section (`p.*`) is the only place raw colors
appear — every token derives from a named palette entry. The structure
mirrors pi-mono's `dark.json` `vars` block.

```zig
fn buildDark() Theme {
    const p = struct {
        // Surface scale (darkest → lightest)
        const bg_0 = Color.rgb(0x0A, 0x0A, 0x0A); // background (≈ terminal)
        const bg_1 = Color.rgb(0x14, 0x14, 0x14); // panel
        const bg_2 = Color.rgb(0x1E, 0x1E, 0x1E); // element
        const bg_3 = Color.rgb(0x28, 0x28, 0x28); // menu (most lifted)

        // Tool state backgrounds (from pi-mono dark.json)
        const tool_pending = Color.rgb(0x28, 0x28, 0x32);
        const tool_success = Color.rgb(0x28, 0x32, 0x28);
        const tool_error   = Color.rgb(0x3C, 0x28, 0x28);

        // Text scale
        const fg_1 = Color.rgb(0x80, 0x80, 0x80); // text_muted

        // Border scale
        const border_0 = Color.rgb(0x3C, 0x3C, 0x3C); // subtle
        const border_1 = Color.rgb(0x48, 0x48, 0x48); // default
        const border_2 = Color.rgb(0x60, 0x60, 0x60); // active

        // Accents
        const teal   = Color.rgb(0x7A, 0xA8, 0x9F);
        const blue   = Color.rgb(0x7F, 0xB4, 0xCA);
        const purple = Color.rgb(0x93, 0x8A, 0xA9);

        // Diagnostics
        const green  = Color.rgb(0x87, 0xA9, 0x87);
        const yellow = Color.rgb(0xE6, 0xC3, 0x84);
        const red    = Color.rgb(0xE4, 0x68, 0x76);
        const cyan   = Color.rgb(0x56, 0xB6, 0xC2);

        // Thinking hue gradient (from pi-mono dark.json — preserved intact)
        const thinking_off_c     = Color.rgb(0x50, 0x50, 0x50); // darkGray
        const thinking_minimal_c = Color.rgb(0x6E, 0x6E, 0x6E); // #6e6e6e
        const thinking_low_c     = Color.rgb(0x5F, 0x87, 0xAF); // #5f87af
        const thinking_medium_c  = Color.rgb(0x81, 0xA2, 0xBE); // #81a2be
        const thinking_high_c    = Color.rgb(0xB2, 0x94, 0xBB); // #b294bb
        const thinking_xhigh_c   = Color.rgb(0xD1, 0x83, 0xE8); // #d183e8

        // Export (HTML) — from pi-mono dark.json
        const export_page = Color.rgb(0x18, 0x18, 0x1E);
        const export_card = Color.rgb(0x1E, 0x1E, 0x24);
        const export_info = Color.rgb(0x3C, 0x37, 0x28);
    };

    var t: Theme = .{ .colors = undefined };
    const set = struct {
        fn f(th: *Theme, tok: Token, c: Color) void {
            th.colors[@intFromEnum(tok)] = c;
        }
    }.f;

    // Accents
    set(&t, .primary,   p.teal);
    set(&t, .secondary, p.blue);
    set(&t, .accent,    p.purple);

    // Diagnostics
    set(&t, .success,  p.green);
    set(&t, .warning,  p.yellow);
    set(&t, .@"error", p.red);
    set(&t, .info,     p.cyan);

    // Text
    set(&t, .text,                    Color.default); // ← sacred
    set(&t, .text_muted,              p.fg_1);
    set(&t, .selected_list_item_text, Color.default); // ← computed fallback

    // Surfaces
    set(&t, .background,         Color.default); // ← sacred
    set(&t, .background_panel,   p.bg_1);
    set(&t, .background_element, p.bg_2);
    set(&t, .background_menu,    p.bg_3);        // ← fixes picker bleed-through

    // Borders
    set(&t, .border,        p.border_1);
    set(&t, .border_active, p.border_2);
    set(&t, .border_subtle, p.border_0);

    // Tool states (preserved from pi-mono)
    set(&t, .tool_pending_bg, p.tool_pending);
    set(&t, .tool_success_bg, Color.default); // quiet success
    set(&t, .tool_error_bg,   p.tool_error);

    // Thinking (hue gradient, pi-mono values preserved)
    set(&t, .thinking_off,     p.thinking_off_c);
    set(&t, .thinking_minimal, p.thinking_minimal_c);
    set(&t, .thinking_low,     p.thinking_low_c);
    set(&t, .thinking_medium,  p.thinking_medium_c);
    set(&t, .thinking_high,    p.thinking_high_c);
    set(&t, .thinking_xhigh,   p.thinking_xhigh_c);

    // Export (HTML)
    set(&t, .export_page_bg, p.export_page);
    set(&t, .export_card_bg, p.export_card);
    set(&t, .export_info_bg, p.export_info);

    // Diff / Markdown / Syntax — set similarly, omitted for brevity.

    return t;
}
```

### Sacred defaults

Three tokens **must** default to `Color.default` in every dark/light theme
unless the theme explicitly overrides them:

| Token                         | Why                                              |
| ----------------------------- | ------------------------------------------------ |
| `text`                        | Users pick their terminal fg for a reason.       |
| `background`                  | Users pick their terminal bg for a reason.       |
| `selected_list_item_text`     | Computed at render time via `selectedFg()`.      |

A fourth token **should** default to `Color.default` but themes may override:

| Token                         | Why                                              |
| ----------------------------- | ------------------------------------------------ |
| `tool_success_bg`             | Success is quiet. Matches pi-mono's `tool_success_bg = ""` in some presets. |

Every other surface token (`background_panel`, `background_element`,
`background_menu`) **must** be a concrete RGB value — they exist specifically
to lift content off the terminal background.

## Terminal compatibility: 256-color fallback

Themes are authored in hex (truecolor). The renderer quantizes to 256-color
at emit time when the terminal doesn't support truecolor. This is a direct
port of pi-mono's `rgbTo256` in `theme.ts:241-272`.

### Detection

Mirrors pi-mono's `detectColorMode` (`theme.ts:160-185`):

```zig
pub const ColorMode = enum { truecolor, color_256 };

pub fn detectColorMode(env: *const std.process.EnvMap) ColorMode {
    // COLORTERM=truecolor|24bit → truecolor
    if (env.get("COLORTERM")) |c| {
        if (std.mem.eql(u8, c, "truecolor") or std.mem.eql(u8, c, "24bit"))
            return .truecolor;
    }
    // Windows Terminal
    if (env.get("WT_SESSION") != null) return .truecolor;

    const term = env.get("TERM") orelse "";
    // Limited terminals
    if (term.len == 0 or std.mem.eql(u8, term, "dumb") or std.mem.eql(u8, term, "linux"))
        return .color_256;
    // Apple Terminal
    if (env.get("TERM_PROGRAM")) |p| {
        if (std.mem.eql(u8, p, "Apple_Terminal")) return .color_256;
    }
    // GNU screen without explicit COLORTERM
    if (std.mem.eql(u8, term, "screen") or
        std.mem.startsWith(u8, term, "screen-") or
        std.mem.startsWith(u8, term, "screen."))
        return .color_256;

    return .truecolor;
}
```

### Quantization

Perceptual RGB → 256-color index. Direct port of pi-mono's algorithm:

```zig
// 6×6×6 color cube values (indices 16-231)
const CUBE_VALUES = [_]u8{ 0, 95, 135, 175, 215, 255 };

// Grayscale ramp (indices 232-255)
// GRAY_VALUES[i] = 8 + i*10, i in 0..24

/// Weighted Euclidean distance (human-eye green sensitivity).
/// pi-mono: theme.ts:233-239 (`colorDistance`).
fn colorDistance(r1: u8, g1: u8, b1: u8, r2: u8, g2: u8, b2: u8) f32 { ... }

/// Convert truecolor RGB to nearest xterm-256 index.
/// pi-mono: theme.ts:241-272 (`rgbTo256`).
///
/// Strategy: find closest cube entry and closest gray entry, pick the
/// one with smaller weighted distance — but only prefer gray when the
/// color is nearly neutral (spread < 10). This preserves tinted colors
/// that have close gray neighbors.
pub fn rgbTo256(r: u8, g: u8, b: u8) u8 { ... }
```

### Renderer integration

The quantization happens at **ANSI emit time**, not at theme load time.
This keeps the `Color` struct and `Token` enum mode-agnostic; the same
theme instance serves both truecolor and 256-color terminals. The
renderer holds a `ColorMode` and picks the right SGR sequence:

```zig
// src/tui/renderer.zig (sketch)
fn writeFg(self: *Renderer, c: Color) !void {
    if (c.is_default) return self.writer.writeAll("\x1b[39m");
    switch (self.mode) {
        .truecolor => try self.writer.print("\x1b[38;2;{};{};{}m", .{ c.r, c.g, c.b }),
        .color_256 => try self.writer.print("\x1b[38;5;{}m", .{ rgbTo256(c.r, c.g, c.b) }),
    }
}
```

## JSON theme format (phase 3)

zi's native format follows **pi-mono's convention**: one file per theme,
flat structure, `vars` block for palette reuse, separate `dark.json` and
`light.json` rather than variant objects. A second loader path accepts
OpenCode's single-file variant format for ecosystem compatibility.

### Native format (pi-mono style)

Structure from
`.references/pi-mono/packages/coding-agent/src/modes/interactive/theme/dark.json`
— the only changes are the token set (our 64 tokens vs pi-mono's 51) and
the drop of the `name` field (filename is authoritative):

```json
{
  "$schema": "https://zi.dev/theme.json",
  "vars": {
    "teal":    "#7aa89f",
    "blue":    "#7fb4ca",
    "purple":  "#938aa9",
    "red":     "#e46876",
    "yellow":  "#e6c384",
    "green":   "#87a987",
    "cyan":    "#56b6c2",
    "bg_0":    "",
    "bg_1":    "#141414",
    "bg_2":    "#1e1e1e",
    "bg_3":    "#282828",
    "fg_muted": "#808080"
  },
  "colors": {
    "primary":           "teal",
    "secondary":         "blue",
    "accent":            "purple",
    "success":           "green",
    "warning":           "yellow",
    "error":             "red",
    "info":              "cyan",
    "text":              "",
    "text_muted":        "fg_muted",
    "background":        "bg_0",
    "background_panel":  "bg_1",
    "background_element": "bg_2",
    "background_menu":   "bg_3",
    "border":            "#484848",
    "border_active":     "#606060",
    "border_subtle":     "#3c3c3c",
    "thinking_off":      "#505050",
    "thinking_minimal":  "#6e6e6e",
    "thinking_low":      "#5f87af",
    "thinking_medium":   "#81a2be",
    "thinking_high":     "#b294bb",
    "thinking_xhigh":    "#d183e8"
  },
  "export": {
    "export_page_bg": "#18181e",
    "export_card_bg": "#1e1e24",
    "export_info_bg": "#3c3728"
  }
}
```

Key properties (all borrowed from pi-mono):

- **`vars` block** for palette reuse. Values are hex strings, 256-color
  integers (0–255), or empty string `""` meaning `Color.default`.
- **`colors` block** maps tokens to either a literal value or a var
  reference (by name). Resolved recursively with cycle detection (see
  pi-mono `resolveVarRefs`, `theme.ts:309-325`).
- **`export` block** is kept separate because those tokens only apply to
  HTML output, not the terminal. Pi-mono uses an optional object here;
  zi does the same.
- **Empty string = `Color.default`.** Pi-mono's `fgAnsi("")` emits
  `\x1b[39m` (reset). We preserve this semantics — `""` in JSON maps to
  `Color{ .is_default = true }` in Zig.
- **One file per theme.** `dark.json`, `light.json`, `catppuccin.json`, …
  The filename (minus extension) is the theme name.

### OpenCode compatibility mode (loader option)

OpenCode's single-file format packs both variants into each token:

```json
{
  "$schema": "https://opencode.ai/theme.json",
  "defs": {
    "darkStep1": "#0a0a0a",
    "lightStep1": "#ffffff"
  },
  "theme": {
    "background":     { "dark": "darkStep1", "light": "lightStep1" },
    "backgroundMenu": { "dark": "#141414",   "light": "#f5f5f5"    }
  }
}
```

The loader detects the format by top-level key (`colors` = pi-mono style,
`theme` = OpenCode style) and routes to the appropriate parser. Both
produce the same internal `Theme` struct.

### Loader responsibilities

A future `theme_loader.zig` will:

1. **Parse the outer shape** to detect format (`colors` vs `theme` key).
2. **For pi-mono format:**
   - Parse `vars` into a `std.StringHashMap(ColorValue)`.
   - Walk `colors`, resolving each token value (recursive var lookup with
     cycle detection). Empty string → `Color.default`. Integer 0–255 →
     256-color index (stored as `Color` with a flag for later). Hex →
     RGB parse.
   - Walk `export` the same way.
3. **For OpenCode format:**
   - Parse `defs` into the same hashmap.
   - Walk `theme`, picking the `dark` or `light` key per the active mode,
     resolving var references.
   - Map OpenCode's `camelCase` token names to zi's `snake_case`
     (`backgroundMenu` → `.background_menu`).
4. **Partial themes are valid.** Missing tokens stay at the default
   theme's value — users can ship a theme that only overrides accents.
5. **Emit diagnostics on unknown tokens.** Forward compat: future zi
   tokens should load cleanly on old themes with a warning, not an error.

### Ecosystem

Two ecosystems come for free:

1. **pi-mono themes** — 2 built-in (`dark.json`, `light.json`) plus
   whatever users have in `~/.config/pi-mono/themes/`. The token set is a
   subset of ours, so they load with expected warnings for our 13 extra
   tokens (thinking is actually covered — pi-mono has the same 6 —
   leaving only surfaces and expanded diff as gaps).

2. **OpenCode themes** — ~35 files under
   `packages/opencode/src/cli/cmd/tui/context/theme/`:
   `aura`, `ayu`, `carbonfox`, `catppuccin`, `catppuccin-frappe`,
   `catppuccin-macchiato`, `cobalt2`, `cursor`, `dracula`, `everforest`,
   `flexoki`, `github`, `gruvbox`, `kanagawa`, `lucent-orng`, `material`,
   `matrix`, `mercury`, `monokai`, `nightowl`, `nord`, `one-dark`,
   `opencode`, `orng`, `osaka-jade`, `palenight`, `rosepine`, `solarized`,
   `synthwave84`, `tokyonight`, `vercel`, `vesper`, `zenburn`. These load
   via the compat path and ship as-is.

## Migration plan

This is a **nuclear refactor** — no compat shims, no deprecation period. All
callsites update in one PR.

### Phase 1 — Token enum + dark theme (atomic)

1. Rewrite `src/tui/theme.zig` with the new `Token` enum, `Theme` struct,
   `selectedFg()`, `thinking()`, and `buildDark()`. Delete `FgColor`,
   `BgColor`, and the old `Theme.dark`.
2. Update every `theme.fg(.foo)` / `theme.bg(.foo)` callsite to
   `theme.get(.foo)`. Known call sites today:
   - `src/tui/components/header.zig`
   - `src/tui/components/list_picker.zig`
   - `src/tui/components/select_list.zig`
   - `src/tui/components/markdown.zig`
   - `src/tui/renderers/builtins.zig`
   - `src/tui/transcript.zig`
   - `src/tui/interactive.zig`
   - `src/main.zig`
3. Apply the "Old zi tokens → new tokens" mapping table.
4. Thinking levels stay 1:1 (just renamed `thinking_*` → `thinking_*`).
   Callsites that pick a level pass through the new `theme.thinking(level)`
   helper instead of hard-coding the variant.

### Phase 2 — Fix the picker bug (the whole reason we're here)

1. `ListPicker.render()` fills its region with `theme.get(.background_menu)`
   before drawing borders or content. Add a small helper
   `Region.fill(bg: Color)` to `buffer.zig` if it doesn't exist.
2. Border color switches from `theme.get(.border)` to
   `theme.get(.border_active)` — pickers are always focused when visible.
3. Selected row: `background_element` bg + `Theme.selectedFg()` for fg.
4. Verify the model picker, session picker, and login picker all render
   opaque against the transcript/editor behind them.

### Phase 3 — 256-color fallback

1. Port pi-mono's `detectColorMode`, `colorDistance`, `findClosestCubeIndex`,
   `findClosestGrayIndex`, and `rgbTo256` to `src/tui/color_quantize.zig`.
2. Add `ColorMode` to the renderer; select at startup via env probe.
3. Update SGR emission in `src/tui/renderer.zig` to quantize when
   `mode == .color_256`.
4. Test on Terminal.app and a `screen` session.

### Phase 4 — JSON loading (separate PR, later)

1. Add `src/tui/theme_loader.zig` with the native + OpenCode-compat
   resolver paths described above.
2. Add `--theme <name>` CLI flag and `theme = "<name>"` config key.
3. Embed zi's default `dark.json` / `light.json` via `@embedFile`.
4. Optional: `/theme <name>` slash command for live switching.
5. Optional: ship OpenCode theme files under `assets/themes/opencode/`
   for drop-in compatibility, or document how users can fetch them.

### Phase 5 — HTML export (much later)

1. Session → HTML renderer consumes the `export_*` tokens.
2. Out of scope for this spec beyond reserving the tokens.

## Open questions

1. **Light themes & mode switching.** Phase 1 ships dark only. Should zi
   later (a) detect terminal background via OSC 11 and auto-switch, like
   mac-system-theme pi-mono extensions do, or (b) require an explicit
   config key / CLI flag? Leaning (a) as the default with (b) as override.
2. **Per-component overrides.** Should components like `ListPicker` expose
   `bg_override: ?Color` fields? **No.** If you need a differently-colored
   picker, add a new token (e.g. `background_menu_alt`) — callsite-level
   color overrides defeat the point of a theme system.
3. **Thinking gradient in 256-color mode.** Six hues mapped to xterm-256
   may collide after quantization. Worth a visual smoke test; if two
   adjacent levels end up identical, we can nudge the hex values to
   increase separation in the quantized space.
4. **Bash mode color.** Pi-mono has `bashMode` as its own token (yellow).
   zi reuses `warning` — both are yellow, both mean "unusual, pay
   attention". If usage diverges (e.g. bash mode needs to coexist with a
   warning banner) we can add a dedicated `shell` token later.
5. **`selected_list_item_text` in 256-color mode.** The contrast-based
   fallback returns pure white (#ffffff) or pure black (#000000); both
   quantize cleanly to indices 15 / 16. Worth a sanity check.
6. **256-color integer values in JSON themes.** pi-mono accepts raw
   integers (0–255) as color values. Supporting this means the internal
   `Color` struct needs a discriminator ("rgb" vs "indexed"). Leaning
   **yes, support it** — it's a small delta and matters for terminals
   where the user has remapped the 16 ANSI palette to something specific.

## Non-goals

- **Live theme hot-reload from disk.** Nice to have, not day-one.
- **Per-user color tweaks via config file.** If the theme JSON isn't
  enough, ship your own theme file.
- **Rainbow syntax highlighting.** The 9 syntax tokens are a minimal set;
  richer treesitter-style highlighting is a separate concern.
- **Animation / transitions.** Terminal; not a thing.
- **OSC 4 palette overrides.** Changing the terminal's own 16-color
  palette is too invasive; we stick to xterm-256 and truecolor.

## Summary

| Decision              | Value                                                     |
| --------------------- | --------------------------------------------------------- |
| Token count           | 64 (no scalars)                                           |
| Namespace             | Single flat `Token` enum                                  |
| Fg/Bg split           | None — encoded in token names (`background_*`)            |
| Surface tiers         | 4 (`background` → `panel` → `element` → `menu`)           |
| Diagnostic naming     | `success` / `warning` / `error` / `info`                  |
| Thinking              | 6 distinct hue tokens (pi-mono gradient preserved)        |
| Tool states           | 3 bg tokens preserved from pi-mono                        |
| Export (HTML)         | 3 bg tokens preserved from pi-mono                        |
| Markdown              | 14 tokens (granular, matches OpenCode)                    |
| Syntax                | 9 tokens (identical in pi-mono and OpenCode)              |
| Diff                  | 12 tokens (matches OpenCode)                              |
| 256-color fallback    | Yes — ported from pi-mono `rgbTo256` (Phase 3)            |
| JSON format (native)  | pi-mono style: `vars` + `colors` + `export`, one file per theme |
| JSON format (compat)  | OpenCode variant-object format via detection              |
| Default values        | Zig comptime for Phase 1; JSON loader in Phase 4          |
| Ecosystem             | pi-mono themes (2+custom) + OpenCode themes (~35)         |
| Compat layer          | None internal — nuclear refactor, all callsites in one PR |
| Sacred `Color.default` | `text`, `background`, `selected_list_item_text`          |
| Borrowed from pi-mono | 256-color fallback, `vars` block, hue gradient thinking, `export` block, tool-state backgrounds, one-file-per-theme convention |
| Borrowed from OpenCode | Flat namespace, surface tiers (implicit), `selectedForeground` contrast fallback, granular diff+markdown, `info` diagnostic, `defs` palette variables, community theme JSONs |
| Borrowed from Neovim  | Semantic group names (`NormalFloat`, `Pmenu`, `Visual`) as conceptual anchors |
| Genuinely new         | Explicit 4-tier surface hierarchy (neither pm nor oc have this), sacred `Color.default` as a first-class principle, dual-format JSON loader |

## The bottom line

This spec is **not pi-mono's theme system**, and it is **not OpenCode's
theme system**. It is a merge that:

- Takes pi-mono's production-tested hue gradient, 256-color fallback,
  `vars`/`colors`/`export` file shape, tool-state backgrounds, and
  battle-tested naming where pi-mono got it right.
- Takes OpenCode's flat namespace, `selectedForeground` contrast fallback,
  expanded diff + markdown granularity, `info` diagnostic, and ~35 free
  themes.
- Adds the **4-tier surface hierarchy** that neither system has — the
  single structural insight that fixes the bug that started this whole
  conversation.

The immediate payoff: **the model picker stops bleeding through**. The
long-term payoff: production-quality terminal compatibility, a dual
ecosystem of pi-mono + OpenCode themes, HTML export already wired into
the same theme format, and a clean mental model (four surfaces, three
accents, four diagnostics, two text tiers, six thinking hues) that scales
to whatever UI we build next.
