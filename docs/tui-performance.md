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
  -> chrome composition
  -> screen paint
  -> Vaxis cell diff and synchronous terminal flush
```

`Loop` owns input, viewport policy, run driving, timers, and frame composition.
`Transcript` owns bounded transcript items and every derived transcript layout
cache and line index. `layout.zig` is pure text presentation mechanism. Vaxis
owns terminal cells and diffing.

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
- Terminal frame cadence: fixed 16 ms start-to-start floor. Timing statistics
  never control scheduling.

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
thresholds. PTY tests additionally gate autonomous frame cadence, input latency,
resize storms, transcript eviction, and synthetic streaming without periodic
input.

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
