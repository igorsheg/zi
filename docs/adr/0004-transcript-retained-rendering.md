# adr 0004: keep transcript rendering virtualized and history-bounded

status: accepted

date: 2026-05-30

## context

zi's tui must support long coding sessions and a responsive retained interface. those constraints are incompatible with treating the transcript projection buffer as the durable transcript or with rebuilding all history on every frame.

the frame budget is fixed by the human interface. at 30fps, a frame has about 33ms. therefore transcript rendering must be proportional to the viewport and the active tail item, not to total session history.

unbounded session length is allowed only in durable storage. unbounded in-memory transcript buffers, event queues, layout caches, and render work are bugs.

this ADR closes the ADR 0002 open question for buffer history and rendered viewport caches. scroll-state ownership remains a separate layout decision until the shell and surface model need it.

## decision

zi separates transcript rendering into three layers:

```text
durable transcript log
  append-only session jsonl, unbounded on disk

resident transcript window
  bounded in-memory transcript items needed by the live view

virtualized transcript view
  cached item layout, visible-row render, deterministic surface composition
```

the retained render path is:

```text
AgentSessionEvent / TuiCommand
  -> TranscriptStore or resident TranscriptWindow
  -> TranscriptRenderer
  -> layout cache keyed by item revision and view width
  -> visible rows
  -> Surface compositor
  -> libvaxis cells
```

the current in-tree implementation may keep a small resident `TranscriptStore` while the durable session integration is being connected, but it must not encode the transcript projection buffer as the source of truth for transcript history. the projection buffer is a cache and may be rebuilt or discarded.

## invariants

- render work per frame is `O(viewport_rows + visible_item_count)`.
- mutations mark transcript items, layout records, views, or surfaces dirty; they do not synchronously force a terminal paint.
- the compositor paints on an explicit frame tick and coalesces all mutations since the previous frame.
- within one frame window, `N` queued deltas to the active assistant item produce at most one tail layout update and one terminal paint.
- streaming deltas mutate one active assistant transcript item.
- a streaming delta invalidates only that item's cached layout.
- appending to the active assistant item performs layout work proportional to appended bytes plus the current wrapped-line tail, not to total item bytes.
- resizing invalidates layout by width, not transcript data.
- scrolling changes an offset and never relayouts all history.
- deep scrollback cache misses never block the frame.
- persistent transcript items must reach durable session jsonl before they can be evicted from the resident window.
- scrollback paging uses a separate bounded cache; it must not grow the live resident window without evicting within bounds.
- ephemeral transcript items either remain resident for the session or are explicitly excluded from scrollback. there must be no accidental gaps.
- durable persistent custom items are written through the session owner, not the renderer.
- extension renderers produce bounded view content, not terminal cell mutations.

## bounds

initial bounds are deliberately small and explicit:

```text
resident transcript items: bounded by TranscriptStore.item_count_max until TranscriptWindow lands
resident transcript bytes: 32 MiB target maximum when TranscriptWindow lands
single transcript text payload: 64 KiB
single custom payload: 64 KiB
projection buffer: Buffer.max_bytes
event queue: App.event_count_max
layout cache: at most 8 viewport-heights of rows and 4 MiB of cached layout data
frame cadence: at most one terminal paint per 33ms frame window under streaming load
```

when `TranscriptWindow` lands, evicting an item from the resident window is not data loss. durable items live in the session jsonl log, and persistent items may not be evicted until that write has completed. evicted ephemeral items may be dropped only according to their explicit lifetime and scrollback policy.

the byte values above are starting bounds, not promises of final tuning. changing them requires updating this ADR or a successor ADR with the new bound and reason.

## immediate implementation rule

the first renderer slice removes transcript/chat dual-write and keeps the
projection transcript-shaped:

```text
commands and agent events mutate transcript items
TranscriptView owns scroll/follow-tail state
render asks TranscriptView for visible rows
libvaxis paints cells
```

there must be one transcript mutation path and one projection path. no caller may append formatted transcript text directly into the transcript projection buffer.

adr 0008 defers the generic transcript renderer registry, surface compositor,
and buffer/view registries until a second concrete owner proves the abstraction.

## future work

- add `TranscriptWindow`, backed by durable session jsonl for persistent items.
- add revision-keyed layout records per transcript item and width.
- add incremental tail wrapping for active assistant messages.
- add a frame scheduler that coalesces dirty state and paints at most once per frame interval.
- add viewport-row virtualization so the compositor asks for only visible transcript rows.
- add asynchronous scrollback paging with placeholder rows on cache miss.
- add a bounded transcript renderer registry for lua extension item types.

## rejected alternatives

- keep every rendered chat line in memory forever. this violates bounded resource use.
- render `TranscriptItem` as `[]const []const u8` per frame. this hides allocation and makes frame cost scale with history.
- allow extensions to draw terminal cells directly. this bypasses ownership, clipping, z-order, and testability.
- make the projection buffer the durable transcript. this fuses storage, working set, and projection into one failure-prone knob.
