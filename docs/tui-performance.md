# TUI performance contract

Zi's TUI is a concrete single-owner product, not a reusable widget framework.
This document defines the work and ownership rules that keep transcript growth
from changing interactive behavior.

## Pipeline

```text
input and agent producers
  -> bounded owned state + payload-free owner wake
  -> Loop dispatch/tick
  -> Transcript content mutation and layout invalidation
  -> Transcript prepareLayout and visible-line lookup
  -> chrome authoritative region RowPlan and composition
  -> screen paint
  -> Vaxis cell diff and synchronous terminal flush
```

`Loop` owns input, viewport policy, run driving, timers, and frame composition.
`Transcript` owns bounded transcript items and every derived transcript layout
cache and line index. `chrome` composes borrowed Transcript, Attention, Activity,
Composer, and optional Listbox views using one authoritative `RowPlan`.
`layout.zig` is pure text presentation mechanism. Vaxis owns terminal cells and
diffing.

No other TUI module may mutate transcript layout state or maintain a mirror of
its line index.

## Layout invalidation

Each transcript item has exactly one invalidation state:

```text
clean < source_appended < rebuild
```

`rebuild` dominates `source_appended`; `source_appended` dominates `clean`.
Content mutation and invalidation happen together inside `Transcript`. Callers
do not set cache fields.

- `source_appended` means the source retained its prefix. Incremental Markdown
  wrapping may retain committed physical and visual lines and reflow only the
  unstable suffix.
- `rebuild` means previous derived lines cannot be reused.
- A `LayoutKey` contains only facts that affect transcript layout: width, tool
  expansion, and thinking visibility. Terminal height does not invalidate text
  wrapping.

## Bounds

- Transcript retention: 2,000 items and 8 MiB of source text; oldest items are
  evicted at either cap.
- Per-item text: 256 KiB.
- Complete relayout: its pending-cache slice processes at most 128 items or
  approximately 256 KiB of source per prepare step. Active-key mutations are
  repaired separately. A single item is processed atomically and remains bounded
  by the per-item cap.
- Relayout queue: one coalesced pending layout key. A newer key replaces the
  pending job; returning to the active key cancels it.
- Relayout memory: one active cache and at most one pending derived cache per
  item. Pending caches are published together, so frames never observe a mixed
  line index.
- Visible materialization: at most `screen.row_capacity` rows.
- Live agent application: at most 8 `.live` `RunHandle` results per owner
  iteration. A full batch must be flushed, then waits for the next normal 16 ms
  frame deadline before another batch.
- Interactive restore: at most 16 durable entries and a 256 KiB measured-work
  target per step. One first entry may exceed the target, bounded by the 1 MiB
  session-line cap. Restore continuation uses the same frame deadline gate.
- Prompt images: at most 4 images and 768 KiB of base64 data in aggregate.
  Reads and encoding run in one concrete background task and check cancellation
  between 256 KiB chunks.
- Session work: one concrete listing/opening/switch/restore operation. Listing
  and opening run off-loop with 5-second and 30-second deadlines; the old
  session remains current until the replacement is complete and its shutdown
  has been observed.
- Terminal frame cadence: fixed 16 ms start-to-start floor. Timing statistics
  never control scheduling.
- Process shutdown: `Loop` requests each concrete cancellation source and polls
  its foreground operation, agent-run state, and sessions for at most five
  seconds. Normal deinitialization runs only after every worker-visible owner is
  terminal. An
  undrained deadline restores the terminal and returns a typed condition to the
  CLI, which exits immediately without running memory-releasing defers.

While a complete relayout is pending, the active layout remains renderable and
input remains owner-loop foreground work. Initial layout has no active history,
so transcript rows appear when the first bounded relayout publishes; chrome and
input remain live meanwhile.

## Work guarantees

For ordinary frames:

- Stream append work depends on new bytes and the unstable item suffix, not the
  number of retained items.
- Prefix repair starts at the earliest changed item.
- Absolute-line lookup is binary over item prefixes.
- Visible collection is proportional to visible terminal rows.
- Invisible tool updates do not invalidate transcript layout.
- Duration-bearing tools invalidate only when their displayed 100 ms tick
  changes.

Complete width, expansion, or thinking-visibility changes are the only normal
operations allowed to visit every retained item, and they run through the one
bounded relayout state machine.

## Instrumentation and regression tests

Trace output separates apply, layout, paint, and flush time and records:

- items laid out;
- source bytes processed;
- line-index entries repaired;
- visible lines materialized;
- maximum items and source bytes processed by one frame.

Tests should prefer these deterministic work counters over wall-clock
thresholds. Trace output also records maximum agent events per iteration,
event-budget exhaustion, gated polls, and maximum restored entries/work bytes
per step. PTY tests additionally gate autonomous frame cadence, input latency,
resize storms, transcript eviction, synthetic streaming, and a real faux-provider
`RunHandle`/`EventPipe` flood without periodic input.

A new transcript feature must prove:

1. which `Transcript` mutation owns it;
2. whether each update is invisible, append-only, or structural;
3. its source/output bounds;
4. that steady streaming work does not grow with retained history;
5. that it does not add another timer, render queue, line index, or terminal
   mechanism.

## Non-goals

Zi does not add a widget tree, generic damage rectangles, a renderer thread, a
second cell buffer, a generic cache manager, or an OpenTUI-style text framework.
The retained state here is only the concrete transcript layout needed by Zi;
Vaxis remains the terminal renderer.
