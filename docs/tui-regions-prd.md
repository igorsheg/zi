# Refactor PRD: make TUI frame regions explicit

- Status: ready for implementation
- Date: 2026-07-13
- Product owner: TUI frontend
- Primary implementation owners: `src/tui/Loop.zig` and `src/tui/chrome.zig`
- Refactor policy: preserve product behavior; breaking internal APIs are allowed;
  compatibility layers are forbidden

## 1. Purpose

Zi's gen-3 TUI has the correct ownership architecture: one interactive `Loop`,
one bounded `Transcript`, one omni composer, direct `AgentSession` driving, and
Vaxis as terminal mechanism. This PRD does not replace that architecture. It
makes the final frame as easy to understand in code as it is on screen.

Today `chrome.Snapshot` presents a flat collection of status, composer-label,
transcript, queue, viewport, popup, picker, scratch, and styling fields. The
final screen has a simpler product shape than that interface suggests. Related
facts are produced and constrained in different methods, and the overloaded
word "status" covers current activity, transcript outcomes, tool state,
queued work, picker feedback, and ambient session facts.

The product requirement is:

> A maintainer adding or changing a visible TUI fact should be able to identify
> its owner, destination, row bound, lifetime, and test by following one named
> frame region, without learning a widget framework or a second state model.

The target frame has five concrete regions:

```text
Frame
├── Transcript
├── Attention
├── Activity
├── Composer
└── Listbox
```

The terminal title remains outside the frame.

## 2. Why this work matters

The current code makes ordinary extension questions more expensive than they
need to be:

- Does a new progress message belong in the status row or transcript?
- Which fact displaces queued prompts on a small terminal?
- Are picker and completion rows the same visual mechanism?
- Which fields are current composer metadata rather than transient status?
- Which row count is authoritative for both materialization and composition?
- Is a field active product behavior, a dormant slot, or historical residue?
- Can a presentation helper retain state, schedule a timer, or request focus?

The desired improvement is not fewer files or a generic rendering abstraction.
It is a smaller conceptual interface:

1. **Named destinations:** every visible fact has an obvious region.
2. **Local policy:** each region's content and row bound are described together.
3. **Preserved ownership:** regions render owner facts; they do not become
   independent owners.
4. **Compiler-visible variants:** mutually exclusive presentation modes use
   tagged unions rather than combinations of booleans and nullable fields.
5. **Deletion:** dormant slots and duplicate paint paths are removed when no
   binding behavior requires them.
6. **Focused tests:** tests describe product regions and routing decisions.

## 3. Relationship to existing architecture

The following remain binding:

- `CONTEXT.md` and `AGENTS.md` define ownership, layers, and bounded-work rules.
- `docs/gen3-tui-plan.md` remains the architecture record and trap list.
- `docs/tui-performance.md` remains the transcript and frame-work contract.
- `docs/tui-responsiveness-ux-prd.md` remains the responsiveness and lifecycle
  contract.
- `docs/tui-legibility-refactor-prd.md` remains the owner-locality contract.
- `docs/transcript-vertical-rhythm.md` remains the transcript row contract.

This PRD deepens the current `Loop -> Transcript/chrome -> screen -> Vaxis`
path. It must not introduce an Engine, ViewModel, render protocol, client
protocol, second transcript, widget tree, generic scheduler, render thread,
focus tree, or local terminal mechanism.

The gen-3 plan explicitly chose the low-level Vaxis path and forbids `vxfw` and
`vaxis.widgets` in the TUI product. This PRD borrows the useful idea of explicit
visual composition without adopting a widget runtime.

## 4. Vocabulary

### 4.1 Region

A **region** is one fixed part of Zi's product frame with a named purpose and an
explicit row policy. A region is not a generic interface, runtime node, state
owner, focus target, event handler, or extension point.

### 4.2 Region view

A **region view** is a small borrowed value used for one composition call. It
contains already-owned facts needed to paint a region. It owns no product state
and is not retained after frame composition.

Examples include `ActivityView`, `AttentionView`, `ComposerView`, and
`ListboxView`. Exact declaration names may change during implementation if a
smaller interface emerges, but the ownership rule may not.

### 4.3 Activity

**Activity** answers one question: "What is Zi doing right now?" It is ephemeral,
global to the current TUI operation, and occupies zero or one row.

### 4.4 Attention

**Attention** contains bounded temporary facts that are not transcript history
but require awareness: unseen transcript lines and queued prompts.

### 4.5 Notice

A **notice** is scrollable transcript feedback. It remains a `Transcript` item
and is not routed through Activity merely because it is status-like text.

### 4.6 Listbox

A **listbox** is the shared visual shape for completion and picker rows. The
composer remains the only text input and focus owner. Completion and picker may
retain distinct typed sizing and selection policies.

## 5. User-visible outcome

This is primarily an internal legibility refactor. Canonical frames and input
behavior should remain unchanged.

After the work:

1. Current operation text still appears in the one-row Activity region.
2. Queued prompts and the new-lines hint still appear in the bounded Attention
   region with the same priority and small-terminal behavior.
3. Notices, assistant outcomes, tool status, and compaction blocks remain in the
   Transcript.
4. Cwd, context, model, and thinking facts remain Composer metadata.
5. Completion and picker rows retain their existing interactions and layout,
   but use one clearly named Listbox presentation concept.
6. The terminal title remains an out-of-frame terminal side effect.
7. No new focus behavior, animation cadence, layout behavior, or user-facing
   status copy is introduced by this refactor.

If characterization finds that current behavior contradicts a binding product
contract, treat that as a separate explicit bug decision. Do not silently
resolve product drift as structural cleanup.

## 6. Current frame and reasoning hotspots

The current concrete render order in `chrome.compose` is approximately:

```text
transcript lines
optional scratch row
viewport hint and queue lines
status row
composer
picker or completion popup
```

The main reasoning hotspots are:

1. `chrome.Snapshot` is flat even though its fields form several visual
   concepts.
2. `StatusView` is named after an overloaded product term; it specifically
   represents current Activity.
3. viewport-hint and queue facts are materialized by `Loop`, but their shared
   row cap and displacement policy are completed in `chrome`.
4. picker and completion have separate view types and paint functions despite
   sharing listbox visuals; their real sizing differences are implicit.
5. `scratch_text` is renderable but has no current producer.
6. composer bottom labels exist in the snapshot but have no current `Loop`
   producer.
7. some cached session facts are not currently rendered. Binding behavior must
   be checked before retaining, wiring, or deleting them.
8. tests often speak in terms of flat snapshot fields rather than the product
   region being protected.

## 7. Target frame model

### 7.1 Overview

The target composition path is:

```text
Loop-owned state + Transcript-owned state
  -> borrowed region views
  -> one authoritative RowPlan
  -> chrome composition in screen order
  -> screen.Frame
  -> Vaxis paint
  -> synchronous terminal flush
```

A representative shape is:

```zig
pub const FrameView = struct {
    transcript_lines: []const screen.Line,
    attention: AttentionView,
    activity: ActivityView,
    composer: ComposerView,
    listbox: ?ListboxView,
};
```

This declaration is illustrative, not a requirement to preserve these exact
names. The implementation should prefer the smallest concrete interface that
makes the five regions obvious.

`FrameView` and its nested values are borrowed for the duration of
`chrome.compose`. They are not stored by `chrome`, assigned revisions, compared
between frames, or mirrored from `Loop` state.

### 7.2 Transcript region

**Purpose:** conversation and scrollable session presentation.

**Contains:**

- user and assistant messages;
- assistant terminal `aborted` and `error` markers;
- tool blocks and tool-local status;
- notices;
- compaction blocks;
- custom transcript messages.

**Owner:** `Transcript` owns content, retention, layout caches, line index, and
visible-line materialization. `Loop` owns viewport policy.

**Row policy:** receives the rows left by concrete chrome planning. Visible
materialization remains capped by `screen.row_capacity`.

**Non-change:** no generic scroll widget, second line index, transcript mirror,
or per-block widget tree.

### 7.3 Attention region

**Purpose:** temporary awareness of queued or currently unseen work.

**Contains:**

- `↓ {d} new lines`;
- `steering: {s}`;
- `follow-up: {s}`;
- `alt+q edits queued messages`.

**Owner:** `Loop` owns viewport and asks `AgentSession` for borrowed queue
echoes. `chrome` owns only row placement and clipping.

**Row policy:** zero to four rows.

**Existing priority to preserve:**

1. the viewport hint, when present;
2. visible queue echo lines in their current order;
3. the queue action hint when capacity remains.

At most three queue echoes are materialized by the TUI. A viewport hint may
displace the action hint. The underlying `Agent` queue limits and rejection
policy remain unchanged.

The Attention implementation must make this policy readable in one contiguous
place. It must not retain queue text, copy the queue model, or infer agent
state.

### 7.4 Activity region

**Purpose:** answer "What is Zi doing right now?"

**Owner:** `Loop` derives the view directly from its current exit,
foreground-operation, run, retry, compaction, cancellation, and transcript-run
facts.

**Row policy:** zero or one row.

**Precedence to preserve:**

1. exit requested;
2. first-Ctrl+C exit hint;
3. foreground operation;
4. outstanding run cancellation;
5. retry wait;
6. compaction;
7. active agent run;
8. absent while idle.

**Current activity families:**

- exiting;
- loading, opening, switching, or restoring sessions;
- preparing images or reading a clipboard image;
- running an extension prompt command;
- canceling outstanding work;
- waiting for retry;
- compacting context;
- working on an agent run.

`StatusView` should be renamed or replaced with a name specific to Activity.
Tool status types and transcript notice levels retain their existing names.

Activity animation remains driven by `Loop`'s nearest owned deadline. The
region may describe an effect such as shimmer, but it may not schedule ticks,
start a spinner task, own a dirty flag, or read the clock independently.

### 7.5 Composer region

**Purpose:** render the omni input and continuously current session metadata.

**Contains:**

- borrowed `Editor` content and cursor;
- composer border and surface;
- cwd label;
- context usage/window label;
- model and thinking label;
- any currently binding composer-border visual policy.

**Owner:** `Loop` owns the concrete composer state; `Editor` owns editing
mechanics. `chrome` renders borrowed state.

**Row policy:** preserve the existing bounded editor policy: at least the
small-terminal input row when the frame has height, bordered when dimensions
permit, and capped expansion based on the existing composer row calculation.

Composer metadata is ambient state, not Activity and not a Notice. The region
must not acquire its own focus model or mutate `Editor`.

Dormant bottom-label fields should be deleted unless phase 0 identifies a
binding producer or product requirement. Existing metadata caches must be
retained, wired, or removed only after checking binding product documents and
current tests.

### 7.6 Listbox region

**Purpose:** render bounded completion or picker choices associated with the
composer.

**Contains:**

- completion candidates and non-selectable progress rows such as indexing or
  searching;
- picker rows and metadata;
- selected-row marker;
- local empty state such as `no matches`.

**Owner:** `Loop`'s concrete composer state owns candidates, picker stack,
filtering, selection, dismissal, and async query policy. The Listbox region owns
only presentation.

**Row policy:** zero to eight visible rows.

Completion and picker are mutually exclusive presentation variants. Preserve
their real differences explicitly:

- completion uses its bounded visible content count;
- picker reserves its current fixed-height panel where space permits;
- picker and completion keep their current placement relative to the composer;
- selected-row windowing remains owned by the concrete composer logic unless a
  deeper, smaller interface is proven during implementation.

Prefer one private row-painting mechanism with typed completion/picker variants.
Do not erase differences behind boolean flags or add generic focusable list
widgets.

### 7.7 Terminal title

The terminal title remains outside the frame:

```text
zi - <session title> - <cwd basename>
```

It remains a direct `Loop` fact applied by `Terminal`. It is not a sixth frame
region and is not routed through chrome.

## 8. Feedback routing policy

New visible facts must use this decision table:

| Question | Destination |
|---|---|
| What is Zi doing right now? | Activity |
| Is work queued or hidden below an anchored viewport? | Attention |
| Must the user find the outcome later? | Transcript notice or block |
| Is progress/outcome tied to one assistant or tool? | That transcript block |
| Is the fact continuously true of the current session/input? | Composer metadata |
| Does it only concern completion or a picker? | Listbox |
| Does no destination fit? | Do not add it until the product behavior is defined |

Examples:

- Compaction progress belongs in Activity; the compaction summary belongs in a
  Transcript block; an actionable compaction failure belongs in a Notice.
- Tool running/done/error state belongs in its tool block, not in global
  Activity unless the whole agent run has a distinct global state.
- Current model belongs in Composer metadata; authentication availability while
  choosing a model belongs in Listbox; a user-requested model-change outcome may
  remain a Notice if product behavior requires historical confirmation.
- File indexing progress shown only because completion is open belongs in
  Listbox, not Activity.

This PRD establishes routing vocabulary. It does not remove existing duplicate
user feedback unless the implementing change receives an explicit product
decision and updates focused snapshots.

## 9. Ownership and lifetime rules

### 9.1 Mutable owners remain unchanged

- `Loop` owns interactive product state, viewport policy, composer state,
  foreground operations, run state, deadlines, and frame composition.
- `Transcript` owns transcript content and all derived transcript layout state.
- `Editor` owns editing mechanics under the concrete composer.
- `AgentSession` and `agent.Agent` own runtime/session facts and queued work.
- `chrome` owns no mutable product state.
- `screen` owns no application state.

### 9.2 Region views are ephemeral

A region view:

- borrows slices, lines, labels, and owner pointers;
- is valid only for the composition call that received it;
- performs no allocation unless existing bounded frame composition requires it;
- is never subscribed to events;
- carries no revision or opaque identifier;
- has no `init`, `deinit`, `update`, or lifecycle unless it demonstrably owns a
  resource—which these presentation views should not.

### 9.3 No independent invalidation

There remains one frame dirty policy in `Loop`, plus `Transcript`'s existing
content/layout invalidation. Regions do not add dirty flags, damage rectangles,
memo registries, or render queues.

Rendering remains:

```text
compose -> paint -> synchronous flush -> clear dirty after success
```

## 10. Authoritative row planning

`chrome.RowPlan` remains the one authoritative allocation for final
composition. Its fields should align with the named regions rather than expose
independent popup/picker calculations where a typed Listbox variant can express
the real policy.

The plan must continue to protect:

- a usable composer whenever frame height is nonzero;
- Activity precedence on constrained frames;
- the bounded Attention cap;
- completion/picker bounds;
- exact agreement between transcript materialization and final composition;
- total planned rows not exceeding terminal height.

The current bounded two-pass viewport transaction remains valid:

1. derive initial borrowed views needed for planning;
2. compute a provisional plan;
3. apply pending viewport motion using provisional transcript capacity;
4. recompute the viewport hint;
5. compute the final authoritative plan;
6. materialize transcript and listbox rows for that plan;
7. compose exactly that plan.

Do not turn the two passes into an incremental layout tree or expose separate
capacity APIs again.

## 11. Bounds and performance requirements

The refactor must preserve all existing bounds, including:

- Activity: zero or one row;
- Attention: zero to four rows;
- visible queue echoes: at most three plus the bounded action hint;
- Listbox: at most eight visible rows;
- completion candidates: existing fixed maximum;
- picker rows and stack: existing fixed maxima;
- Composer: existing bounded row calculation and editor capacity;
- visible transcript lines: at most `screen.row_capacity`;
- Transcript retention: 2,000 items and 8 MiB source text;
- per-item and relayout limits from `docs/tui-performance.md`;
- terminal frame cadence and agent/restore work budgets.

The implementation must add:

- no new heap allocation on an ordinary frame solely to represent regions;
- no additional pass over retained transcript items;
- no generic child traversal;
- no dynamic dispatch;
- no region registry;
- no extra clock sampling or animation deadline;
- no second cell buffer.

Performance traces should remain equivalent. If regrouping changes measured
layout, materialization, paint, or flush work, investigate before accepting the
change.

## 12. Internal API direction

The desired interface is concrete and small:

```text
Loop.activityView(now)       -> borrowed ActivityView
Loop attention materializer  -> borrowed AttentionView
Loop composer state          -> borrowed ComposerView
Loop listbox materializer    -> optional typed ListboxView
Transcript.collectVisible    -> borrowed visible lines
chrome.planRows              -> authoritative RowPlan
chrome.compose               -> screen.Frame
```

This is not a mandate to create one method or file per line. Prefer contiguous
private declarations and owner methods. Extract a file only if deletion would
force several callers to duplicate meaningful bounded presentation mechanism.

`chrome.zig` may remain a somewhat large, deep concrete module. File length is
not a reason to distribute frame policy.

## 13. Explicit non-goals

This PRD does not add:

- `vxfw` or `vaxis.widgets` usage;
- a `Widget`, `Region`, or `Renderable` interface;
- a retained visual tree or VNode description;
- region IDs or recursive lookup;
- generic flexbox, constraints, or z-index layout;
- capture/target/bubble event routing;
- region-local focus;
- region-local timers or animation tasks;
- a status, notice, contribution, or plugin registry;
- runtime-loaded UI contributions;
- a second transcript or viewport representation;
- a new dependency;
- new user-visible status copy or visual redesign;
- refactoring solely to make `Loop.zig` or `chrome.zig` shorter.

## 14. Implementation sequence

### Phase 0 — Characterize the current frame

1. Record the current render order and every active `chrome.Snapshot` producer.
2. Identify focused tests for Activity precedence, Attention displacement,
   composer dimensions, completion sizing, picker sizing, and small terminals.
3. Add missing characterization tests before structural edits.
4. Check every apparently dormant field against binding product documents and
   current callers.
5. Record any product-contract discrepancy separately; do not mix a behavioral
   fix into the structural baseline without explicit approval.

**Gate:** tests fail when Activity precedence, Attention priority, listbox
placement, or authoritative transcript capacity is changed.

### Phase 1 — Establish Activity vocabulary

1. Rename or replace `StatusView` with the concrete Activity name.
2. Rename status-row planning fields to Activity-specific names where this does
   not collide with tool status.
3. Keep derivation directly on `Loop`; do not store an Activity value.
4. Add a table-driven precedence test covering every foreground-operation and
   run-state family.
5. Preserve current text, styles, shimmer behavior, and deadlines.

**Gate:** one exhaustive owner method derives Activity; no other module infers
foreground or run state.

### Phase 2 — Make Attention one bounded region

1. Group viewport hint and queue-line frame inputs under one borrowed view.
2. Concentrate the four-row cap and displacement order in one chrome path.
3. Keep queue formatting and source facts with `Loop` and `AgentSession`.
4. Test zero, partial, full, and displaced states at normal and constrained
   heights.

**Gate:** the complete visible Attention policy can be read in one contiguous
implementation and no queue mirror exists.

### Phase 3 — Group Composer presentation

1. Replace flat composer label/style fields with one borrowed Composer view.
2. Preserve the existing editor row calculation, cursor placement, clipping,
   border behavior, and omni-input ownership.
3. Delete unproduced bottom-label fields unless phase 0 establishes binding
   behavior.
4. Give any cached-but-unrendered metadata an explicit disposition consistent
   with binding product contracts.

**Gate:** composer tests operate through one presentation input; no editing,
focus, completion, picker, settings, or session mutation moves into chrome.

### Phase 4 — Unify Listbox presentation

1. Represent completion and picker as mutually exclusive typed variants.
2. Share selection-marker, row-surface, and row-span painting.
3. Preserve completion content sizing and picker fixed-panel sizing explicitly.
4. Preserve selected-row windowing, no-match behavior, progress rows, and the
   composer-as-filter invariant.
5. Remove superseded popup/picker paint functions only after parity tests pass.

**Gate:** one listbox paint mechanism exists, while completion and picker policy
remain distinguishable without boolean combinations or opaque IDs.

### Phase 5 — Align the authoritative plan and frame input

1. Group final `chrome.compose` input by the five regions.
2. Align `RowPlan` names with those regions.
3. Preserve the provisional/final viewport planning transaction.
4. Assert every supplied region fits the final plan.
5. Expand width/height matrix tests, including heights 0, 1, and 2.

**Gate:** `Loop.composeFrameAt()` reads in screen-region order, and one final
plan controls both materialization and composition.

### Phase 6 — Delete residue and update architecture vocabulary

1. Delete `scratch_text` and its backing state if it remains producerless and
   no binding test requires it.
2. Delete obsolete aliases, flat fields, duplicate paint functions, and tests
   tied only to removed interfaces.
3. Update `CONTEXT.md` and relevant TUI docs with the region vocabulary after
   implementation proves the final names.
4. Do not retain forwarding fields or deprecated compatibility constructors.

**Gate:** the change is net-neutral or net-negative in conceptual surface and
contains no dormant replacement abstraction.

## 15. Testing requirements

### 15.1 Activity

Headless tests must prove:

- every Activity family renders its current copy;
- precedence is exit > exit hint > foreground operation > cancellation > retry
  > compaction > working > idle;
- idle consumes zero rows;
- working and compaction use the existing shimmer path;
- retry countdown changes on the existing cadence without adding a timer.

### 15.2 Attention

Headless tests must prove:

- no facts consume zero rows;
- one to three queue echoes retain order and labels;
- the action hint appears only when capacity remains;
- the viewport hint appears first;
- the viewport hint can displace the action hint at the four-row cap;
- constrained frames preserve the existing Activity and composer priorities.

### 15.3 Composer

Headless tests must prove:

- cwd and right-side metadata alignment and clipping;
- Unicode display-column behavior;
- bordered and unbordered small-terminal behavior;
- cursor placement across wrapped rows;
- any binding border-style policy;
- no dormant label silently reserves space.

### 15.4 Listbox

Headless tests must prove:

- completion and picker share row visuals;
- their sizing policies remain distinct;
- selection remains visible through windowing;
- non-selectable progress rows render correctly;
- `no matches` renders without a selected row;
- picker metadata and authentication state remain visible;
- listbox absence consumes zero rows.

### 15.5 Whole frame

Semantic snapshots and matrix tests must prove:

- canonical frames are unchanged unless an explicit product decision updates a
  baseline;
- every width/height case fits exactly within terminal height;
- transcript materialization uses final planned capacity;
- the composer remains usable at the smallest supported heights;
- viewport anchors survive resize and appended transcript content;
- picker/completion interactions remain on the real `Loop` path.

Run existing PTY scenarios for streaming, abort, resize, completion, picker,
session restore/switch, and responsiveness. This refactor should not require a
new PTY mechanism.

## 16. Success criteria

The refactor is complete when:

1. The final frame is represented by Transcript, Attention, Activity, Composer,
   and optional Listbox regions.
2. `Loop` and `Transcript` retain their current mutation authority.
3. Region views are borrowed frame inputs, not retained models.
4. Every region has an explicit content and row bound.
5. `Loop.composeFrameAt()` and `chrome.compose()` are readable in screen order.
6. One authoritative `RowPlan` governs materialization and composition.
7. Activity precedence is exhaustive and tested.
8. Attention displacement is local and tested.
9. Completion and picker share presentation without gaining a generic widget
   seam or second focus model.
10. Dormant frame slots and superseded interfaces are deleted or have an
    explicitly documented binding purpose.
11. No allocation, work-bound, responsiveness, or shutdown regression is
    introduced.
12. No compatibility layer remains.

## 17. Rejection criteria

Stop and redesign if an implementation proposal requires:

- persistent region objects synchronized with `Loop`;
- a generic region/widget interface;
- event dispatch to regions;
- region-local focus, dirty state, or timers;
- dynamic registration or ordering;
- opaque IDs to find presentation nodes;
- another layout/cache/index representation;
- importing product owners into `chrome`;
- routing agent/session facts through a new protocol;
- broad rewrites of `Transcript`, `Editor`, `screen`, or terminal lifecycle to
  accommodate the region vocabulary.

## 18. Required validation

For the implementation change, run:

```sh
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

Also run the focused semantic snapshot and width/height matrix tests added by
this PRD. Report any gate not run.
