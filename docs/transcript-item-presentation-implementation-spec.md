# Transcript item and tool chrome implementation spec

Status: implemented

This specification defines the transcript presentation language and the ownership cutover that supports it. It amends the TUI chrome and spacing sections of [`tool-presentation-implementation-spec.md`](tool-presentation-implementation-spec.md). The existing coding-agent `ToolPresentation` contract, tool lifecycle authority, transcript projection bounds, and stable invocation identity remain unchanged.

See [ADR 0013](adr/0013-tool-invocations-keep-one-transcript-identity.md) for tool identity and placement, [ADR 0014](adr/0014-tool-presentation-is-semantic-data.md) for the coding-agent presentation boundary, and [`tui-performance-implementation-spec.md`](tui-performance-implementation-spec.md) for retained projection and hot-path constraints.

## Outcomes

The implementation must produce:

1. one canonical **transcript item** contract with one clear native-subtree owner;
2. exactly one blank row between visible transcript items;
3. assistant messages that transparently compose thinking, Markdown, tool, omission, and error items;
4. one generic open-rail language for every tool and lifecycle state;
5. lifecycle-colored structural chrome with quiet evidence and no configured tool background;
6. stable tool identity through argument streaming, execution, completion, expansion, and reparenting;
7. unchanged coding-agent tool semantics and no built-in tool-name branches in the TUI;
8. structural tests for spacing, colors, selection, bounds, identity, constrained width, and cleanup.

## Non-goals

This work does not:

- change `ToolPresentation`, its body primitives, projector validation, or built-in result details;
- add recursive or flat tool-section data to `packages/coding-agent`;
- create a generic render tree, frontend projection schema, block framework, or broad `BlockContent` trait;
- add per-tool renderer registration or extension-provided native components;
- add per-row tool focus, expansion state, navigation, or copy commands;
- group adjacent tool invocations or remove their one-row separation;
- animate the open rail, add a completion flash, or add another timer or renderer scheduler;
- change user-message surfaces, Markdown styling, composer styling, or transcript navigation;
- change the 200-message, 64-tool, 12-row compact, or 200-row detailed bounds;
- flatten `AgentSession` messages into a copied frontend timeline.

## Canonical language

**Transcript item** is one visually independent unit in the transcript. It owns one native root and exactly one trailing blank row. A transcript item is not the same as an `AgentMessage`.

**Transcript sequence** is a spacing-neutral owner that orders transcript items. An assistant message is a transcript sequence because one assistant message can contain several visual items.

**Tool chrome** is the lifecycle marker, subordinate rail, section separator, closing cap, and spacing around one tool invocation. It is terminal presentation owned by the TUI, not coding-agent semantic data.

**Tool evidence** is the bounded body content, notice, or action hint subordinate to the tool header. Ordinary evidence recedes visually; semantic commands, diffs, warnings, and errors keep their established colors.

**Open rail** is the tool shape formed by a header followed by optional `│`, `├─`, and `╰───` rows. It groups evidence without a top or right border and without a background panel.

# 1. Transcript item ownership

## Shared contract

The shared TUI-only contract is deliberately narrow:

```ts
interface TranscriptItemView {
  readonly root: Renderable
  destroy(): void
}
```

The contract carries no generic payload, `kind`, update callback, style options, fold state, or arbitrary metadata. Concrete owners retain concrete operations such as `ToolCallView.update(frame)`. Do not introduce a base class solely to implement this interface.

A concrete owner may be a class or a member of an existing direct discriminated union. It creates its native subtree, updates only that subtree, clears native selection before removing selectable descendants, and destroys every resource it creates.

## Item taxonomy

The following visible units are transcript items:

- one user message;
- one contiguous thinking block;
- one contiguous assistant Markdown block;
- one tool invocation;
- one custom, branch-summary, or compaction-summary message;
- one transcript-level history or tool-omission marker;
- one standalone assistant error.

These are not transcript items:

- an `AgentMessage` merely because it is persisted as one message;
- a tool result that completes an already retained tool invocation;
- tool body rows, notices, omission lines, separators, or action hints;
- Markdown paragraphs and wrapped lines inside one assistant Markdown item;
- transparent message and sequence roots;
- transcript navigation overlays or the composer.

Historical `bashExecution` messages project through `ToolCallView` and therefore remain tool transcript items.

## Spacing invariant

Every transcript item root has:

```ts
marginTop: 0
marginBottom: 1
```

A transcript sequence root has no top or bottom margin. Parents do not add another gap around item children. Internal item padding and intrinsic Markdown paragraph layout are not inter-item spacing and remain owned by the concrete item.

The transcript has:

- no synthetic blank row before its first item;
- exactly one blank row between every pair of items;
- one trailing blank row after the final item, providing separation from the composer.

No code derives spacing from neighboring item kinds. Remove the current interaction between tool `marginTop`, assistant `#syncBottomMargin()`, thinking `followedByAnswer`, message-root bottom margins, and tool-root bottom margins.

## Assistant message projection

`StreamingAssistantView` remains the retained owner of an assistant message's visual sequence. Its root is spacing-neutral and is not a transcript item. It owns ordered concrete item views for visible semantic parts.

Adjacent source parts of the same visible kind belong to one transcript item. The owner may retain one native child per source part; raw provider part boundaries must not introduce inter-item margins or force unrelated siblings to rebuild. A transition between thinking, answer, tool, omission, and error kinds creates an item boundary.

The retained order remains source order:

```text
thinking item
assistant Markdown item
tool item
assistant Markdown item
assistant error item
```

Empty thinking and text parts produce no item. When a visible kind changes, rebuild only the suffix beginning at that boundary, as required by the existing hot-path specification.

A committed tool result does not add spacing or a second item. It updates the existing keyed `ToolCallView`. If that invocation is no longer retained at its originating assistant position, the existing standalone fallback behavior creates or promotes one tool item at the result position.

## Lifetime and placement

The native subtree owner and the placement owner remain distinct where reparenting requires it:

- `ToolCallView` owns its native subtree;
- `TranscriptView` admits, indexes, reparents, and ultimately destroys keyed tool views;
- `StreamingAssistantView` hosts embedded tool roots but does not gain lifecycle authority over an invocation created by `TranscriptView`;
- message-sequence owners order their item roots without copying authoritative message content into another timeline.

The owner that creates a non-tool transcript item destroys it. Transparent sequence roots destroy only resources they own. Existing stale-callback and selection-clearing rules remain mandatory.

# 2. Tool visual grammar

## Header-only form

A tool with no visible subordinate content is one line:

```text
◆ Read config.ts

```

There is no empty rail or closing cap. The blank line is the transcript item's trailing gap.

## Open-rail form

A tool with visible subordinate content uses this grammar:

```text
◆ Action subject · facts · status
│ contextual input
├─
│ evidence
│ notice
│ action hint
╰───

```

The logical structural glyphs are:

```ts
header marker: "◇ " | "◈ " | "◆ "
body row:      "│ "
separator:     "├─"
closing cap:   "╰───"
```

Existing root padding may place the logical glyphs one cell inside the transcript. The glyphs themselves stay fixed-width and never stretch to terminal width.

Rules:

1. Every visual subordinate row, including wrapped continuations and blank output rows, begins with `│ `.
2. `├─` appears only when an exact secondary context/input group and a body/evidence group are both visible.
3. `├─` is one structural row with no synthetic blank row before or after it.
4. Notices and action hints continue under the body rail without another separator.
5. `╰───` appears whenever at least one secondary, body, notice, or action-hint row is visible.
6. A cap is part of the tool item; the following blank row is the item gap and is still present.
7. Omission rows such as `… middle output · Ctrl+O details` are evidence rows and retain the rail.
8. Tool chrome is non-selectable.

## Bash context and output

A Bash invocation with a human description keeps the exact command as subordinate input:

```text
◆ Run the full TUI test suite · timeout 180s
│ $ bun run --filter @with-zi/tui test
├─
│ … earlier output · Ctrl+O details
│ 146 tests passed
╰───

```

Without a human description, the exact command remains the header subject and is not duplicated:

```text
◆ Run bun test
│ … earlier output · Ctrl+O details
│ 146 tests passed
╰───

```

The separator is therefore generic: it follows visible `header.secondary` content only when a visible body follows. `ToolCallView` does not branch on the Bash tool name.

## Edit evidence

Edit keeps the same grammar without an input section:

```text
◆ Edit prompt-store.test.ts +3/-3
│ 39     const prompt = createPromptStore(mode, slash)
│ 40
│ 41     try {
│ 42 −     prompt.draftChanged("/rev", 4)
│ … middle output · Ctrl+O details
│ 43 +     expect(prompt.activatePicker("/rev path", 4)).toBe(true)
╰───

```

Read source, Write source, task output, operational failures, and generic tool bodies use the same single-section form.

# 3. Lifecycle language

## Glyphs and tones

Glyph shape represents lifecycle only. Detailed density never changes it.

| Lifecycle state | Glyph | Chrome tone                                      | Generic header treatment    |
| --------------- | ----- | ------------------------------------------------ | --------------------------- |
| `preparing`     | `◇`   | muted                                            | current partial facts       |
| `ready`         | `◇`   | accent                                           | current `waiting` status    |
| `running`       | `◈`   | stepped dim-to-accent marker; static accent rail | current elapsed timing      |
| `done`          | `◆`   | success                                          | no generic success word     |
| `failed`        | `◆`   | error                                            | semantic status or `failed` |
| `aborted`       | `◆`   | error                                            | current `aborted` status    |

Every `│`, `├─`, and `╰───` belonging to one invocation uses the current lifecycle tone. Markers do too except while running, when `◈` pulses between the dim and accent endpoints. Keep the existing `ToolHeader.status` precedence and verb-first header language. Do not add generic `done` or `success` prose.

Zi adopts the running-marker sample from Grok Build's synchronized bullet-and-rail wave, not its animated rail or completion flash. The marker uses eight discrete phases—`dim → 25% → 50% → 75% → accent → 75% → 50% → 25%`—at one phase per 100 ms. All visible running markers derive their phase from the same transcript-supplied timestamp. The rail remains static accent, terminal states do not flash, and no tool owns a timer, RAF loop, renderer scheduler, or live request. The existing visibility-gated transcript live request drives both timing and marker refresh.

## Density is not lifecycle

Remove `glyphs.toolExpanded` from tool presentation. `app.tools.expand` remains a mode-owned global density action:

- compact mode uses `preview.compact`;
- detailed mode uses `preview.detailed`;
- compact omission lines retain the effective `Ctrl+O details` hint;
- detailed omission lines omit that hint;
- no tool header adds `details`, a chevron, or another density marker;
- density changes never replace a tool root.

If a persistent global density indicator is ever needed, it belongs once in global UI rather than on every tool item.

## Timing

Keep the existing timing semantics:

- a visible running invocation may show elapsed time;
- a completed duration appears only in detailed mode and only if this TUI observed the running transition;
- background handoff may say `started in` according to `ToolTimingPolicy`;
- restored invocations never invent timing;
- timing refresh does not reproject tool data or rebuild body rows.

# 4. Color and background

## Transparent tool surface

No tool renderable configures a background color. This includes:

- the tool root and header;
- secondary command/context rows;
- terminal, source, diff, and text body rows;
- omission rows;
- notices and action hints;
- separator and closing-cap rows.

Remove `theme.surface.panel` from tool body rows. Do not replace it with `theme.surface.app`; allowing the inherited terminal/transcript surface is the intended transparent behavior. Diff additions and deletions use foreground semantics only. Native selection highlighting is not a configured tool background and remains OpenTUI-owned.

## Foreground hierarchy

| Element                                  | Tone                                  |
| ---------------------------------------- | ------------------------------------- |
| Lifecycle marker, rail, separator, cap   | lifecycle tone from the table above   |
| Header label and ordinary subject        | existing primary/bold treatment       |
| Terminal output                          | `theme.text.toolOutput`               |
| Source content                           | `theme.text.toolOutput`               |
| Plain normal body text                   | `theme.text.toolOutput`               |
| Source line-number gutter                | muted or dim                          |
| Diff context and diff line-number gutter | `theme.diff.context` or muted         |
| Diff additions/deletions and markers     | existing added/removed tones          |
| Bash command and arguments               | existing shell syntax tones           |
| Omission rows and action hints           | muted                                 |
| Warning/error body text and notices      | existing semantic warning/error tones |
| Path and task subjects                   | existing link/accent treatment        |

Bulk evidence therefore recedes while the narrow structural spine communicates lifecycle. Do not recolor semantic diff lines or Bash command tokens to the lifecycle tone.

# 5. Tool content and density

## Existing semantic contract remains

`packages/coding-agent/src/tools/presentation/types.ts` remains unchanged:

```text
ToolPresentation
  header
  optional body
  notices
  compact/detailed preview
  timing
```

The TUI derives visible groups only from those existing fields plus the mode-owned action hint. It does not parse body text, infer sections from labels, or add built-in name dispatch.

Unknown tools retain the current bounded generic text body. `Arguments` and `Result` labels remain within that body; this milestone does not add section data merely to render another separator.

## Compact baseline

| Tool/outcome                          | Compact presentation              |
| ------------------------------------- | --------------------------------- |
| Read success                          | header only                       |
| Write success                         | header only                       |
| Kill-task success                     | header only                       |
| Edit success                          | bounded diff, rail, cap           |
| Bash with useful output               | bounded output, rail, cap         |
| Bash without useful output            | header only                       |
| Task output                           | bounded output, rail, cap         |
| Any operational failure with evidence | bounded error/evidence, rail, cap |
| Unknown tool                          | bounded generic body, rail, cap   |

Projectors remain authoritative for whether a body is useful in compact and detailed density. Shared chrome makes different semantic densities coherent; it does not force every tool to the same height.

## Preterminal baseline

Preserve current preterminal behavior:

- Read, Write, and Edit remain header-only while preparing, waiting, and running unless their current projector supplies visible evidence;
- Bash and task-output invocations may expose bounded live terminal evidence;
- action hints remain subordinate rows while applicable;
- the first visible output can add a separator and body without replacing the tool root;
- terminal completion recolors lifecycle chrome and applies the current projector's compact policy in place.

## Bounds

The existing body limits remain evidence limits:

```text
compact body rows  <= 12
detailed body rows <= 200
notices             <= 8
projected tools     <= 64
projected messages  <= 200
```

A fixed header, optional secondary context, one separator, bounded notices, one action hint, one cap, and one trailing item gap sit outside the body-row budget. Their counts are independently fixed or already bounded, so total native retention remains bounded.

Hidden previews still short-circuit before line splitting and wrapping. Adding chrome must not cause a hidden body to allocate row renderables.

# 6. Native composition and selection

## Target tool shape

`ToolCallView` remains the cohesive invocation owner:

```text
ToolCallView item root (marginBottom: 1, transparent)
  primary ToolHeaderView
  optional subordinate context rows
  optional separator row
  optional ToolBodyView rows
  optional ToolNoticeView rows
  optional action-hint row
  optional closing-cap row
```

`ToolCallView` owns the structural policy and lifecycle tone. Concrete child owners may create their own native row resources, but they receive the closed chrome decision; they do not choose glyphs, section boundaries, lifecycle colors, or footer visibility.

Move the secondary subject out of header-internal layout if necessary so it participates in the same subordinate rail and separator grammar. Do not introduce a recursive section renderer or generic component registry.

The header, body subtree of unchanged primitive type, notice rows, separator, footer, and action hint update in place. A body primitive change may replace only the body subtree after clearing native selection.

## Selection and copy

Structural chrome is presentation-only:

- marker, outer rail, separator, cap, omission rows, and action hints are non-selectable;
- selecting terminal/plain output copies content without outer rail glyphs;
- selecting source excludes the outer rail and line-number gutter;
- selecting a diff excludes the outer rail and line-number gutter but preserves semantic `+`/`−` markers and changed text;
- selecting a Bash command excludes the decorative `$ ` prompt while preserving the command;
- path links retain their current exact target and selectable path behavior.

Use separate native chrome/content renderables where needed; do not depend on post-copy string stripping. Removing or replacing selectable rows clears native selection first, preserving the existing ownership rule.

## Width

Width-dependent work remains TUI-owned:

1. reserve the header marker or subordinate rail width first;
2. apply existing whole-fact admission to header details;
3. retain compact basename/path behavior and detailed path behavior;
4. wrap evidence using the remaining cells after the rail and source/diff gutter;
5. repeat `│ ` on every wrapped continuation;
6. truncate fixed chrome only when the terminal is narrower than the chrome itself;
7. never allow a narrow width to create an unbounded row count.

Header roots and unchanged body row roots remain stable across resize where their semantic role is unchanged.

# 7. Hot-path constraints

This cutover must preserve the existing transcript performance model:

- `TranscriptView` still reconciles from one semantic notification stream;
- a streaming change updates only the changed assistant suffix or tool invocation;
- committed item roots remain stable until reset or bounded eviction;
- tool roots remain stable through every lifecycle and placement transition;
- adjacent same-kind assistant parts do not create avoidable roots or gaps;
- removing distributed margin coordination must not add a layout effect or second state machine;
- running-tool refresh updates timing and any lifecycle chrome that actually changed, not projector data;
- transparent rows avoid redundant background assignments;
- every new row collection remains bounded by existing body and notice limits;
- destroyed screens and item owners reject stale callbacks and release every native resource they created.

Status transitions may recolor retained rail glyphs because that is a visible semantic change. They must not recreate content rows solely to change that color.

# 8. Implementation sequence

The branch may use internal slices, but the mergeable result has one spacing path and one tool renderer.

## Slice A — characterize the language

Add failing fixtures for:

- one-row separation across user, thinking, Markdown, tool, omission, summary, and error items;
- header-only and open-rail tool forms;
- lifecycle glyph and chrome colors for all six states;
- transparent tool rows and muted ordinary evidence;
- Bash secondary command plus separator;
- Edit diff without a separator;
- fixed closing cap and post-item gap;
- structural selection exclusion;
- global detail toggling without glyph replacement.

## Slice B — transcript item ownership

- add the narrow package-private `TranscriptItemView` contract under `interactive/transcript/`;
- make concrete transcript item owners adopt one trailing margin;
- make assistant message roots spacing-neutral;
- coalesce adjacent same-kind assistant parts into one item boundary;
- remove `followedByAnswer`, tool `marginTop`, `#syncBottomMargin()`, and other neighbor-dependent spacing coordination;
- keep message append, suffix invalidation, tool reparenting, and projection bounds unchanged.

## Slice C — tool chrome

- replace the expansion glyph with lifecycle-only glyph selection;
- change ready to the pending hollow glyph while retaining `waiting` text;
- introduce subordinate rail, semantic separator, and closing-cap renderables;
- place secondary command/context, body, notices, and action hints inside the shared grammar;
- remove configured body backgrounds;
- map ordinary evidence to the quiet output tone;
- separate structural chrome from selectable content;
- preserve body and tool root identity through lifecycle and density updates.

## Slice D — cleanup and acceptance

- delete replaced margin and panel code;
- update visual fixtures and documentation;
- run coding-agent tests to prove the semantic presentation contract did not change;
- run the complete TUI suite;
- inspect normal, narrow, running, failed, detailed, restored, and adjacent-tool frames.

No feature flag, compatibility adapter, old glyph path, or dual spacing implementation remains after the cutover.

# 9. Acceptance tests

## Transcript structure

Tests must prove:

- exactly one blank row between every transcript-item combination;
- no gap is doubled at an `AgentMessage` boundary;
- no gap is lost when a tool result commits into an embedded tool item;
- adjacent assistant parts of one visible kind have no internal item gap;
- the final item retains one row before the composer;
- eviction, reset, compaction rebuild, and session replacement preserve the same rhythm.

## Tool language

Fixtures must cover:

- preparing, ready, running, done, failed, and aborted headers;
- header-only Read/Write/Kill success;
- running and completed Bash with and without a description;
- successful Edit diff, omitted middle, and detailed mode;
- Read/Write source details;
- task output and kill-task failure;
- generic arguments/result body;
- notices-only and action-hint-only subordinate content;
- empty output and trailing-LF behavior;
- constrained widths and wrapped continuations.

For each applicable fixture, assert marker, rail, separator, footer, one-row gap, foreground tone, and absence of configured background.

## Identity and performance

Retain or extend structural tests proving:

- one `ToolCallView.root` survives argument, ready, running, progress, terminal, and commit transitions;
- adding/removing separator and footer does not replace that root;
- unchanged sibling tool and assistant-item roots retain identity;
- density changes retain roots and remain bounded;
- hidden previews create no body rows;
- ordinary streaming text does not reproject unchanged tools;
- status recoloring does not reconstruct body content;
- disposal destroys every added chrome and item resource.

## Selection

Native-selection fixtures must prove:

- copied terminal/source/diff content omits the outer rail and closing cap;
- command copy omits `$ `;
- source gutters are decorative while diff markers remain semantic;
- collapsing, body-kind replacement, eviction, and reset clear affected selection before destruction.

# 10. Documentation amendments

When implementation lands:

- mark this specification implemented;
- update the TUI chrome wording in `docs/tool-presentation-implementation-spec.md`;
- retain ADR 0014's shallow semantic-data decision while describing the transparent lifecycle-colored open rail;
- link this specification from ADR 0013, `docs/tui-architecture.md`, and the TUI performance specification;
- update visual evidence in `docs/parity-roadmap.md` if fixture paths or accepted behavior descriptions change.
