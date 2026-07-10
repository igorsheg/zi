# Transcript vertical rhythm

This document maps the current transcript from source event to terminal row and
records the UX contract Zi should converge on. It is deliberately row-based:
terminal text has a fixed line height of one cell, so vertical rhythm is the
number, role, and surface of physical rows.

The behavioral reference is `.references/pi/`; Zi keeps its own gen-3 ownership
and rendering architecture.

## Ownership and render path

```text
AgentEvent / restored session entry
  -> Transcript item mutation
  -> Transcript item layout + item rhythm
  -> Transcript line index and visible-row materialization
  -> Loop viewport policy
  -> chrome frame composition
  -> screen paint into Vaxis cells
```

- `src/tui/Transcript.zig` owns item order, item layout, outer item spacing, and
  all transcript-derived line state.
- `src/tui/blocks.zig` owns the rows inside a tool item.
- `src/tui/layout.zig` and `src/tui/markdown.zig` turn source text into physical
  rows but do not own spacing between transcript items.
- `src/tui/Loop.zig` owns the viewport and selects a contiguous visible range.
- `src/tui/chrome.zig` places those rows above queues, status, and composer. It
  does not add spacing between transcript items.
- `src/tui/screen.zig` paints one `screen.Line` into one terminal row. There is
  no independent line-height setting.

No second transcript model or layout index should be introduced to implement
this contract.

## Row vocabulary

The diagrams below use these row roles:

| Token | Meaning |
|---|---|
| `C` | Content row containing one or more spans |
| `B` | Semantic blank row originating in content |
| `P` | Blank panel-padding row with the item's surface |
| `M` | Transparent one-row margin between items |
| `T` | Title row |
| `R+` / `R-` | Tool top/bottom rail row |
| `RB` | Tool body row beginning with `│ ` |
| `F` | Tool footer row |

A surface row is painted to the full terminal width. A transparent row inherits
the app surface.

## Global geometry

Current constants in `Transcript.zig`:

| Property | Current value | Effect |
|---|---:|---|
| Terminal line height | 1 cell | Every `screen.Line` consumes exactly one row |
| Transcript inset | 1 column | Every non-empty item row begins with one space |
| Reserved right inset | 1 column | Item wrapping width is `max(W - 2, 0)` |
| User panel padding Y | 1 row | One panel row above and below user content |
| Item bottom margin | 1 row | Every non-empty item ends in one transparent row |
| Custom panel padding Y | 1 row | One panel row above and below custom content |
| Tool internal body inset | 2 columns | `│ ` follows the transcript's one-column inset |

The right inset is reserved during wrapping but is not emitted as a text span.
A row surface, when present, still fills the terminal width.

Empty content lines have no leading-space span. Their horizontal inset is only
conceptual; panel surfaces still fill the row.

For terminal width `W`:

```text
transcript inner width = max(W - 2, 0)
tool body text width   = max(W - 2 - width("│ "), 0)
                       = max(W - 4, 0)
```

At widths `0..2`, layout makes progress one UTF-8 scalar at a time and painting
clips to the terminal. This is safe but not a useful reading layout.

## Global item rhythm

`applyItemRhythm` currently applies this grammar to every non-empty item:

```text
[optional item-specific top padding]
[content rows]
[optional item-specific bottom padding]
M
```

The margin belongs to the preceding item. Therefore:

- two adjacent non-empty items have exactly one transparent row between them;
- an empty assistant item contributes no row and no margin;
- the last non-empty item leaves one row between transcript content and lower
  chrome while the viewport follows the tail;
- source-authored trailing blank rows stack with the outer margin.

Each cached transcript line has a parallel typed `RowRole`: content, semantic
blank, panel padding, or item margin. The cache asserts equal line/role lengths.
Viewport logic skips and snaps away from item margins only, preserving
source-authored semantic blank paragraphs.

## Item summary matrix

Let `N` be the number of physical content rows after wrapping and before outer
item rhythm.

| Item | Current row grammar | Current height |
|---|---|---:|
| User | `P C×N P M` | `N + 3` |
| Assistant, visible | `C×N M` | `N + 1` |
| Assistant, empty | nothing | `0` |
| Tool | tool rows, then `M` | `N + 1`, `N >= 1` |
| Notice | `C×N M` | `N + 1` |
| Compaction, collapsed | `P T B C P M` | `6` at ordinary widths |
| Compaction, expanded | `P T B C B C×N P M` | `N + 7` |
| Custom | `P T×K B C×N P M` when titled | `K + N + 4` |

`layout.wrapPlain("")` produces one blank content row, so an empty user or
notice is not considered empty. An empty assistant is elided. This is an
inconsistent empty-item policy.

## User item

### Source and content

A user item contains all text and image blocks from one `UserMessage`.

- Text blocks are appended directly in source order.
- Adjacent text blocks receive no automatic newline.
- An image block is represented as `[Image]` or `[Image: <known mime>]`.
- An image placeholder starts on a new source line when prior text does not end
  in `\n`.
- Content is plain-wrapped, not Markdown-rendered.
- Source text is capped at 256 KiB; truncation adds `[output truncated]` when
  room permits.

### Rows

For one visual line:

```text
P  panel background
C  " <user text>" on panel background
P  panel background
M  transparent
```

For `N` wrapped or source-authored rows:

```text
P C×N P M
```

All panel rows use `surface.user_message`. Content wraps at `W - 2` and each
non-empty row receives the one-column transcript inset.

### State changes

User items do not stream. Restored and live user messages use the same fold and
same layout.

## Assistant item

Assistant items contain ordered text and thinking parts plus a terminal stop
state. Tool calls become separate tool items; tool-call slots in the assistant
are cleared.

### Empty and tool-call-only assistant

An assistant with no visible text or thinking returns zero rows. It does not add
an outer margin. This prevents a tool-call-only turn from creating a blank row
in addition to the tool item's separation.

### Plain text, streaming or settled

```text
C×N M
```

- Text is Markdown-rendered.
- It wraps at `W - 2`.
- It has no panel surface and no vertical padding.
- Streaming a single text part uses the incremental Markdown path; only the
  unstable suffix is reflowed.
- The one-row item margin is present during streaming, so the active answer
  keeps a stable cushion above lower chrome.

### Thinking hidden

Current behavior:

| State | Rows |
|---|---|
| Thinking is streaming, no answer yet | `Thinking...`, then `M` |
| Thinking and answer are streaming | `Thinking...`, `B`, answer rows, then `M` |
| Settled thinking followed by answer | thinking omitted; answer rows, then `M` |
| Settled thinking only | item elided |

The hidden label is muted and italic. A semantic blank row separates it from a
following streamed answer. Settling removes the transient label and blank row.

### Thinking shown

Visible thinking has trailing CR/LF removed before layout.

Intended visual role:

```text
thinking rows: muted + italic
answer rows:   normal Markdown
```

Assistant parts are laid out independently. Thinking rows remain muted and
italic, answer rows remain normal Markdown, and one semantic blank row separates
a thinking part from the following answer. Part boundaries no longer depend on
a source trailing newline.

### Aborted and errored

The terminal status is an independent error-styled row. When partial assistant
content exists, one semantic blank row separates it from `aborted` or
`error: <message>`. An empty failed assistant starts directly with the status
row, and successful partial content retains its original style.

### Source newline behavior

Settled assistant text and thinking trim trailing CR/LF before layout, preserving
internal blank paragraphs. The incremental streaming path may temporarily show
an unstable trailing blank row until the final message reconciles. Tool bodies
also suppress a trailing empty physical line.

## Tool item

A tool item always has a title row, so it is never layout-empty.

### Outer geometry

The transcript adds one leading column to every non-empty tool row. Inside the
tool body, `blocks.zig` adds `│ `.

```text
 T   " <title>"
 R+  " ╭───"
 RB  " │ <body>"
 R-  " ╰───"
 F   " [metadata • duration]"
 M
```

The title is clipped to one inner-width row and never wraps. Body and footer
rows can wrap.

### Generic row grammar

```text
T
[ R+ RB×V R- ] when body is visible
[ F×K ]         when footer or duration exists
M
```

Therefore:

```text
tool height = 1 title
            + (visible body ? 2 rail rows + V body rows : 0)
            + K footer rows
            + 1 outer margin
```

The footer directly follows the bottom rail or title; it has no internal blank
row. The outer margin follows the footer.

### Status surfaces and rail styles

| Status | Title/body row surface | Rail/status style | Title suffix |
|---|---|---|---|
| Pending | pending panel | muted | none |
| Running | pending panel | accent | none |
| Done | transparent/app | success | none |
| Failed | error panel | error | ` (error)` |
| Aborted | error panel | error | ` (aborted)` |

The title text keeps its presentation style; the status color is strongest on
the rail and surface rather than on the title itself.

### Body visibility

A body exists when there is a non-empty running tail, settled body text, or a
body-truncated marker.

| Mode | Pending/running | Done | Failed/aborted | Expanded done |
|---|---|---|---|---|
| `visible` | visible when body exists | visible | visible | visible |
| `hidden_on_success` | visible when body exists | hidden | visible | visible |
| `summary_only` | visible when body exists | visible | visible | visible |

`summary_only` is not structurally different inside `blocks.zig`; tool metadata
resolution decides which summary body survives.

### Running tail

Tools configured with `show_tail` retain at most five normalized physical lines,
with at most 200 bytes per retained line.

- `\r\n` becomes one line break.
- Bare `\r` resets the current line, matching progress output.
- Tab becomes two spaces.
- Empty tail lines do not produce body text rows.
- Wrapped tail rows still carry `│ ` on every visual row.

When a tail first appears, the tool grows from title/footer rows to
`T R+ RB... R- F M`.

### Collapsed body

- Head mode keeps the first configured number of physical lines and places the
  omission hint after them.
- Tail mode places the omission hint first, then keeps the last configured
  number of physical lines.
- The line cap counts source physical lines, not wrapped visual rows. A long
  retained line can therefore consume multiple terminal rows.
- A source body ending in `\n` does not add an empty row before the omission
  marker or bottom rail.
- Omission hints are body rows and retain the rail.

### Expanded body

Expanded mode renders the full bounded body. The body is capped at 64 KiB, so
expansion is structurally bounded but can still occupy many wrapped rows.

Ctrl+O changes the layout key globally and relayouts all tools through the
bounded transcript relayout state machine.

### Footer and duration

A footer is rendered as:

```text
[<tool metadata>]
[Elapsed S.Ts]
[Took S.Ts]
[<metadata> • <duration>]
```

- Running, done, and failed tools may show duration when configured.
- Aborted tools freeze elapsed time when abort is observed and show `Ran S.Ts`.
- Duration display changes at 100 ms ticks without changing row count in normal
  widths.
- Footer text is capped before wrapping.

### Built-in tool matrix

| Tool | Presentation | Body mode | Collapsed preview | Live updates | Duration |
|---|---|---|---|---|---|
| `bash` | command | visible | last 5 lines | last 5 lines | yes |
| `read` | file | hidden on success | first 10 lines | suppressed | no |
| `symbols` | symbols | visible | first 10 lines | suppressed | no |
| `edit` | patch | visible | first 10 lines | suppressed | no |
| `write` | file | summary only | first 10 lines | suppressed | no |
| unknown/custom | generic | visible | last 5 lines | suppressed | no |

Additional vertical behavior:

- `bash` begins as title-only; while running it gains a duration footer, and
  gains the rail/body as output arrives.
- Successful collapsed `read` shrinks to title plus optional footer; Ctrl+O
  reveals its body.
- `write` can show a source-content preview from streamed arguments before
  execution. Result metadata can preserve that preview while suppressing raw
  final result content.
- `symbols` rows are plain tool body rows.
- `edit` diff rows share the same rhythm as generic body rows; only color varies.

## Notice item

Notices use plain wrapping, no panel, no vertical padding, and one outer margin:

```text
C×N M
```

| Level | Text style |
|---|---|
| Info | muted |
| Warn | warning |
| Error | error |

Repeated notices are intentionally separate items, so each receives a one-row
gap. Transcript notices are durable visible facts and are not generically
coalesced; repeating transient progress belongs in status chrome. An empty
notice currently becomes `B M`.

Run progress, retry countdown, and most transient working state do not use
notice rows; they live in the one-row status chrome below the transcript.

## Compaction item

Compaction uses the custom-message surface and responds to the global Ctrl+O
expansion state.

Collapsed:

```text
P
T  [compaction]
B
C  Compacted from <tokens_before> tokens (ctrl+o to expand)
P
M
```

Expanded:

```text
P
T  [compaction]
B
C  Compacted from <tokens_before> tokens
B
C  full Markdown summary
P
M
```

The summary is retained up to the transcript's 256 KiB per-item cap and can add
an `[output truncated]` source row at the cap. Internal blank paragraphs are
preserved and terminal CR/LF is trimmed for display.

## Custom item

The default custom item stores:

- title = custom message kind;
- body = JSON encoding of the payload.

With a title:

```text
P  custom panel surface
T  custom label style, custom panel surface
B  custom panel surface
C  JSON body as Markdown, custom panel surface
P  custom panel surface
M  transparent
```

The panel has one row of top and bottom padding, matching the user panel and the
reference box rhythm. A string payload is visibly JSON-quoted.

## Source text to physical rows

### Plain wrapping

Used by user, notice, compaction labels/metadata, tool title rails/footer, and
some tool text.

- Every source `\n` commits a physical row.
- Empty physical lines become blank rows.
- A trailing `\n` creates a final blank row in `wrapPlain`.
- Long lines are hard-wrapped by display columns.

### Markdown wrapping

Used by assistant and custom body.

- Blank source lines become blank rows.
- Headings remove the `# ` prefix but do not add extra vertical space.
- Fenced-code opening and closing markers each consume a row.
- Block quote markers are removed; no additional quote padding row is added.
- Horizontal rule `---` becomes one eight-character row.
- Inline emphasis changes spans only and never changes row count.
- Prose wrapping is display-cell aware and prefers the latest whitespace or
  punctuation boundary.
- Wrap-only whitespace is omitted at a visual line boundary.
- Long unbroken Unicode tokens make progress by grapheme and hard-wrap.
- Fenced code and tool bodies retain hard wrapping because whitespace is
  meaningful.

### Trailing-newline policy

| Content path | Trailing newline |
|---|---|
| User plain text | trimmed for settled display |
| Assistant text | trimmed when settled; unstable tail may show while streaming |
| Assistant thinking | trimmed |
| Notice | trimmed |
| Custom Markdown body | trimmed |
| Compaction summary | trimmed |
| Tool body | suppressed |

Internal blank paragraphs remain content rows. Terminal CR/LF does not stack
with the transcript-owned outer margin.

## Viewport rhythm

### Follow mode

`viewportStart(rows)` selects the last `rows` indexed transcript lines. Since a
non-empty tail item ends in `M`, follow mode normally reserves the viewport's
last transcript row as separation from lower chrome.

### Anchored mode

The anchor is `(item_seq, line_in_item)`. Relayout resolves it back into the
item. If the resolved line is an empty transparent row, resolution walks
backward to a prior non-separator row.

### Leading separator suppression

Before materializing visible rows, `Loop` skips empty transparent rows at the
viewport top, while leaving at least one transcript line. It does not backfill
from earlier rows after skipping, so the frame can materialize fewer transcript
rows and chrome fills the remainder with app-surface blanks.

Semantic blank paragraphs can have the same visual shape as margins, but their
typed row role keeps them visible and anchorable.

### Short transcript

When the transcript uses fewer rows than its allocation, chrome leaves the
transcript top-aligned and inserts elastic app-surface blank rows between the
transcript tail and lower chrome. The transcript is not bottom-aligned to the
composer.

This is the chosen policy: early conversation content keeps a stable visual
origin and does not move upward after each append. The composer remains pinned
to the bottom.

## Chrome interaction

For height `H >= 3`, rows are composed in this order:

```text
transcript rows
optional scratch row when spare space exists
elastic blank fill
viewport hint and queued-message rows (0..4 total)
status row (0 or 1)
composer rows
picker panel rows (0 or 8, clipped by height)
completion popup rows (0..8, clipped by height)
```

The composer consumes:

```text
content rows = clamp(visual editor rows, 1, min(5, floor(0.3H)))
outer rows   = content rows + 2 when H >= 6 and W >= 4
```

The two extra rows are composer borders, not transcript spacing.

Special heights:

| Height | Layout |
|---:|---|
| 0 | no rows |
| 1 | one unbordered editor row |
| 2 | one priority row + one unbordered editor row |
| 3+ | normal row planner |

At height 2, priority is status, queue/viewport hint, transcript, scratch, then
blank. When the transcript owns the priority row, follow mode gives the last
content row priority over the decorative tail margin.

## Bounds that constrain rhythm

| Bound | Value | Vertical consequence |
|---|---:|---|
| Transcript items | 2,000 | oldest complete items evicted |
| Transcript source bytes | 8 MiB | oldest complete items evicted |
| Per-item text | 256 KiB | truncation marker can add one source row |
| Tool body | 64 KiB | expanded tool remains finite |
| Tool tail | 5 × 200 bytes | running preview remains finite |
| Visible materialization | 512 rows max | one frame cannot materialize more |
| Pending relayout | 128 items or about 256 KiB/step | width/expand changes publish atomically |

Eviction removes whole item grammars, including their outer margins. Viewport
anchors then clamp to the oldest retained item.

## Current test coverage

Covered directly:

- user panel top/bottom padding, left inset, image placeholder, and margin;
- visible-thinking trailing-newline trimming;
- custom panel padding, title/body blank row, and margin;
- compaction panel padding and collapsed/expanded summary rows;
- tool rail repetition across wrapped body rows;
- hidden successful tool body and expanded reveal;
- duration footer outside the rail;
- no blank row before a collapsed marker when tool body ends in `\n`;
- tool-call-only assistant elision;
- viewport anchoring, eviction clamp, width-relayout clamp, and one-row content priority;
- typed content/semantic-blank/panel-padding/item-margin roles and anchor behavior;
- every ordered pair of user, assistant, tool, notice, compaction, and custom items;
- pending -> running -> done/failed/aborted tool row transitions;
- widths 0, 1, 2, 3, 4, 8, and normal with line/role invariants;
- queue, status, viewport-hint, picker, popup, and combined chrome allocation;
- word-aware ASCII/Unicode prose wrapping and hard-wrapped fenced code;
- built-in bash/read/write/symbols/edit presentation paths.

Remaining focused coverage opportunities:

- source-leading and empty-item policy per item;
- additional exact-text narrow-width goldens beyond the invariant matrix;
- manual visual review of representative tail-to-composer gaps.

## Audit findings

### Resolved in this audit

1. Mixed assistant thinking and answer parts now retain boundaries and semantic
   styles, with one explicit blank row between them.
2. Assistant terminal failures now use an independent error row with no leading
   blank for empty failures and no recoloring of partial answer text.
3. Settled assistant trailing CR/LF no longer stacks blank rows on the outer
   item margin.
4. A one-row transcript viewport now gives content priority over the tail
   margin.
5. Custom panels now have one row of top and bottom surface padding.
6. Compaction now renders a padded collapsed/expanded summary block with token
   count and bounded full Markdown summary.

### P1: remaining hierarchy and consistency

7. **Empty-item policy differs by kind.** Empty assistant disappears; empty user
   and notice consume multiple rows.
8. **The complete matrix still needs selective visual review.** Deterministic
   tests now cover every item pair, tool status, pathological width, and lower
   chrome combination, but exact visual approval remains a product task.

### Product decisions fixed by this audit

- Short transcripts remain top-aligned.
- Aborted duration-bearing tools freeze elapsed time and render `Ran S.Ts`.
- Transcript notices remain distinct; transient repetition belongs in status
  chrome rather than generic transcript coalescing.

## Recommended target contract

These recommendations preserve the direct `Transcript` owner and existing
bounded layout architecture.

1. Keep one-cell line height, one-column transcript inset, and one outer row
   between non-empty items.
2. Give content priority over outer margin when the transcript allocation is one
   row. Preserve the margin whenever at least two transcript rows fit.
3. Keep row roles inside `Transcript` layout state so viewport policy never
   infers semantics from an empty transparent `screen.Line`.
4. Render assistant parts independently:
   - thinking muted/italic;
   - answer normal Markdown;
   - one explicit blank between thinking and following answer;
   - terminal error on its own error-styled row;
   - no accidental concatenation.
5. Trim terminal CR/LF for assistant, notice, custom body, and generated display
   text; preserve internal blank paragraphs. The outer margin owns inter-item
   separation.
6. Elide empty items unless they carry an explicit visible state or placeholder.
7. Use panel padding for custom and compaction blocks, with one panel row above
   and below.
8. Keep tool title, rail, body, bottom rail, and footer vertically adjacent;
   only the outer `M` separates a tool from neighboring items.
9. Keep short transcripts top-aligned unless a deliberate product decision and
   PTY evidence justify changing the conversation's visual anchor.
10. Keep deterministic row-role fixtures updated whenever rhythm constants or
    item grammars change.

## Acceptance fixture matrix

A complete headless rhythm suite should assert row text, row role/surface, and
row count for at least these fixtures at wide and narrow widths:

1. one-line and multiline user;
2. user with internal blank, trailing newline, image, and truncation marker;
3. streaming assistant text before and after a wrap boundary;
4. hidden thinking only, hidden thinking -> answer, and settled hidden thinking;
5. visible thinking only and visible thinking -> answer;
6. partial answer -> aborted and partial answer -> error;
7. tool-call-only assistant followed by one and multiple tools;
8. each tool at pending, running-no-output, running-tail, done, failed, aborted;
9. each body mode collapsed and expanded;
10. head and tail omission hints with wrapped retained lines;
11. body with internal blank lines and terminal newline;
12. footer-only and body-plus-footer tools;
13. info, warning, error, empty, multiline, and trailing-newline notices;
14. compact and expanded compaction summary;
15. titled and untitled custom item;
16. every pair of adjacent item classes, asserting exactly one outer margin;
17. follow-tail with 1, 2, and many transcript rows available;
18. anchored viewport beginning on content, semantic blank, and outer margin;
19. queue/status/picker/popup combinations around the same transcript tail;
20. width 0, 1, 2, 3, normal, and resize transitions.

PTY evidence should then cover only mechanics that headless rows cannot prove:
real resize storms, scroll input, streamed updates without input, and the visual
tail-to-composer gap in representative terminal sizes.
