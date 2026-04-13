# Wrap architecture split: shared primitives, surface-owned layout

## status

proposal after editor nuclear refactor phase 1.
no production migration yet.

## question

Should zi go back to a single generic `src/tui/word_wrap.zig` used directly by editor + transcript + text + markdown, or should wrapping live inside each surface?

## answer

**high-level wrapping/layout must be surface-owned. low-level wrap primitives should be shared.**

In other words:

- **shared generic layer**: grapheme width, wrap opportunities, byte/column conversion, low-level break-finding
- **surface-owned layer**: virtual lines, whitespace policy, viewport semantics, cursor mapping, caching/invalidation, prefix/chrome integration

This matches the OpenTUI lesson much better than a single top-level `word_wrap()` authority.

## current zi audit

### 1. editor

Current files:

- `src/tui/editor/layout.zig`
- `src/tui/editor/view.zig`
- `src/tui/editor/buffer.zig`
- `src/tui/word_wrap.zig`

Current shape:

- good: editor now owns its own layout/view/cache authority
- still transitional: `editor/layout.zig` calls shared `word_wrap.zig` internally

Important observation:

`src/tui/word_wrap.zig` encodes **display-text policy**:

- strips leading whitespace on continuation lines
- trims trailing whitespace on all lines
- wraps for presentation, not editing

The editor has already had to compensate for this by preserving raw byte spans while still calling that helper. That is a smell: the editor is trying to use a display wrapper as a primitive for an editing surface.

### 2. transcript

Current direct use:

- `src/tui/transcript.zig:725`
- `src/tui/transcript.zig:767`

Shape:

- tool result fallback uses `word_wrap_mod.wordWrap(result_text, w, allocator)` in both render fallback and measure fallback
- this is **display wrapping**, not editor wrapping
- today it is also a one-shot path, not a retained virtual-line cache

Conclusion:

- transcript fallback should not share editor layout machinery
- transcript may eventually want its own cached display-wrap path, but that is separate from editor concerns

### 3. text component

Current direct use:

- `src/tui/components/text.zig`

Shape:

- uses `word_wrap.zig`
- has its own tiny width/content cache
- semantics are clearly display-oriented

Conclusion:

- this is a good candidate for a shared **display-wrap** layer
- not for sharing editor semantics

### 4. markdown

Current direct use:

- `src/tui/markdown/render.zig:602`
- `src/tui/markdown/render.zig:612`

Shape:

- flatten styled text
- wrap flat text
- reconstruct spans per wrapped slice

Conclusion:

- markdown needs span-preserving display wrap
- this is again presentation wrapping, not editor wrapping

## OpenTUI lesson

Relevant references:

- `.references/opentui/packages/core/src/zig/utf8.zig`
- `.references/opentui/packages/core/src/zig/text-buffer-segment.zig`
- `.references/opentui/packages/core/src/zig/text-buffer-view.zig`
- `.references/opentui/packages/core/src/zig/editor-view.zig`

What OpenTUI actually does:

1. **shared primitive layer**
   - `utf8.findWrapBreaks(...)` discovers wrap opportunities
   - `TextChunk.getWrapOffsets(...)` caches those opportunities per chunk

2. **text/view layer owns virtual lines**
   - `text-buffer-view.zig` builds `virtual_lines`
   - caches width-dependent results
   - invalidates when text/view parameters change

3. **editor view owns cursor/viewport semantics**
   - `editor-view.zig` handles logical↔visual cursor mapping
   - desired visual column
   - scroll margin
   - cursor visibility

That split is the real lesson.

OpenTUI does **not** treat “word wrap” as a single reusable finished product consumed directly by every surface.
It treats wrap discovery as shared infrastructure and layout policy as surface-owned.

## decision

### A. editor wrapping stays inside the editor stack

Keep these responsibilities in `src/tui/editor/`:

- virtual-line construction
- whitespace preservation policy
- logical↔visual cursor mapping
- desired visual column
- viewport + scroll margin
- layout invalidation and caching

The editor should not call a top-level generic API that already decided how continuation whitespace and trailing whitespace behave.

### B. generic `word_wrap.zig` should not remain the architectural center

It may continue to exist temporarily, but it should become one of:

1. a **display-wrap** helper for presentational surfaces only, or
2. a lower-level **wrap-break primitive** split into smaller reusable utilities

What it should **not** be:

- the shared authority for both transcript/text display and editor layout

### C. shared code belongs below layout policy

The reusable layer should answer questions like:

- where are legal wrap opportunities?
- what grapheme/byte/column offsets correspond to those opportunities?
- how do I step text by grapheme/column safely?

It should **not** answer questions like:

- should continuation lines strip leading spaces?
- should trailing spaces be hidden?
- what is a virtual line for this surface?
- what does the cursor mean on a wrapped continuation?

Those are surface questions.

## recommended module split

### shared low-level primitives

Possible future files:

```text
src/tui/wrap/
  breaks.zig        // find wrap opportunities, maybe from utf8/graphemes
  metrics.zig       // byte↔col, grapheme stepping, width helpers
  types.zig         // WrapBreak, WrapRun, maybe generic structs
```

These should be policy-light.

### display-wrap layer

For presentation surfaces only:

```text
src/tui/display_wrap.zig
```

Owns semantics such as:

- trim trailing whitespace for display
- strip or collapse leading continuation whitespace if desired
- produce plain line slices for non-editing surfaces

Consumers:

- `components/text.zig`
- transcript fallback text wrapping
- markdown flat-text wrapping if semantics match

### editor-owned layout

Keep in:

```text
src/tui/editor/layout.zig
src/tui/editor/view.zig
```

The editor should build its own virtual lines from shared break primitives, with editor-specific policy:

- preserve exact bytes
- preserve cursor-addressable whitespace
- never let display trimming redefine editing structure

## migration recommendation

### phase 1 — document the split

Done by this note.

### phase 2 — stop treating `word_wrap.zig` as editor policy

Refactor editor layout to depend on lower-level wrap primitives rather than `word_wrap()`.

Target outcome:

- editor layout builds virtual lines directly
- editor no longer compensates for display-wrap trimming behavior

### phase 3 — rename `word_wrap.zig` by role

Depending on how extraction lands:

- if it remains presentational, rename toward `display_wrap.zig`
- if split further, keep only the presentation layer there and move primitives into `wrap/`

### phase 4 — audit transcript/text/markdown for shared display-wrap compatibility

If all three want the same presentational behavior, let them share a display wrapper.
If one diverges, split at the display layer too.

## audit result by surface

### editor

- **must own** layout
- **must not** depend on presentation-trimming semantics
- **should share** low-level wrap break helpers only

### transcript fallback

- **may share** display-wrap helper
- **should not** share editor layout/view code
- future improvement: cache fallback wrapped output if it becomes hot

### text component

- **good candidate** for shared display-wrap helper
- already has surface-local caching

### markdown

- **may share** display-wrap helper if span reconstruction semantics remain compatible
- still owns markdown-specific flatten/reconstruct logic

## final recommendation

Answering the original two questions directly:

### 1. should it be a generic module again, shared by editor and transcript?

**No at the layout level. Yes at the primitive level.**

- shared generic **primitive** layer: yes
- shared generic **finished wrapping/layout** layer for editor + transcript: no

### 2. implemented per use case?

**Yes for layout/view policy.**

Each surface should own:

- line model
- whitespace policy
- caching/invalidation
- viewport/cursor behavior if any

## concrete next step

Do a focused follow-up that:

1. extracts low-level wrap-break discovery from the current shared path
2. updates `src/tui/editor/layout.zig` to use those primitives directly
3. reclassifies `src/tui/word_wrap.zig` as a display-only helper, or renames it accordingly
