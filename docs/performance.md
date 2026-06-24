# Performance and Responsiveness

Zi's TUI goal is not to have many features. It is to make the small feature set feel polished, deterministic, and responsive under real agent load.

The core product invariant:

```text
The composer must stay responsive. User input must not compete with model/tool progress for an unbounded owner-loop turn.
```

## What we learned

Dogfooding exposed stalls while the agent streamed text and ran tools, especially bash/cx calls with large output. Symptoms included:

- composer cursor blink pausing
- scroll input feeling stuck
- streamed transcript text arriving in chunky, low-FPS bursts
- terminal feeling blocked around tool-call transitions

The first assumption was that tool/session event handling was blocking the UI. Trace data showed a more precise picture: the bottlenecks moved as we fixed them.

## Changes made

### Foreground input priority

The TUI owner loop now polls terminal input before doing background session work. Input and command wakes are treated as foreground work; agent/session/public-event drains are background work.

### Bounded session/event draining

Session public-event draining is bounded per turn. If more events remain, the wake is re-set and the owner loop yields back to input/render scheduling.

### Pending UI work queue

The frontend adapter now stages background transcript/tool work in a bounded pending UI queue. This queue covers streamed assistant text, thinking text, tool output, tool structure, tool footers, and model-driven status changes.

Pending work has explicit bounds:

- max item count
- max resident bytes
- max bytes per turn
- max items per turn
- max elapsed time per turn

Adjacent streamed chunks are coalesced up to a bounded size to reduce mutation churn.

### Streaming tool finalization

Streaming tools such as bash no longer replay/replace their full final output in the TUI at tool end. The streamed transcript is the display truth; final tool events update status/footer metadata.

### Frame priority

Zi now distinguishes frame classes:

```text
foreground: composer/input interaction
scroll: transcript navigation, coalescible under flush debt
background: model/tool transcript progress and animation
```

Foreground frames may render immediately. Background frames are coalesced and adaptively throttled based on measured render cost. Shimmer/status animation is background work and is intentionally deprioritized under load.

### Collapsed tool render asymptotics

A major hotspot was collapsed tool rendering. Collapsed tools still counted/wrapped the entire retained output each frame. Large bash/cx output made render draw O(tool output bytes), even when only a few tail rows were visible.

This was refactored so collapsed tools inspect only bounded visible windows:

- head collapse counts only enough rows to know whether a hint is needed
- tail collapse scans a bounded suffix

This produced the largest improvement.

### Trace instrumentation

`ZI_TUI_TRACE=1` records bounded in-memory timing data and writes a report to a temp file on shutdown:

```sh
ZI_TUI_TRACE=1 zig build run -- ...
```

The report includes phase maximums, slow samples, rendered frame counts, foreground/background split, pending work categories, and trace path.

## Trace-driven results

Early stress traces showed:

```text
pending_ui_work:          ~200ms
render_draw_foreground:   ~150ms
render_draw_background:   ~130ms
render_flush_background:  ~150ms
```

After bounded pending work and collapsed-tool fixes, representative traces improved to roughly:

```text
pending_ui_work:          ~20ms
render_draw_foreground:   ~30ms
render_draw_background:   ~40-80ms under stress
render_flush_foreground:  low single-digit ms in good runs
```

Typing became smooth. The remaining perceived low FPS is mostly transcript streaming presentation, not input latency.

## Current diagnosis

Zi now protects composer input much better, but streamed LLM text can still feel chunky because background transcript presentation is intentionally throttled to protect input and terminal flush.

This means the next problem is not raw event latency. It is presentation cadence:

```text
SSE chunk timing should not directly define TUI text reveal timing.
```

Network/model deltas are data ingress. Transcript reveal is UI presentation policy.

## Desired direction

Introduce a typewriter/presentation buffer for streamed assistant text:

```text
SSE/model deltas -> adapter-owned reveal buffer
frame cadence -> reveal bounded text into App transcript
render -> stable perceived stream
```

Policy goals:

- keep composer/input foreground and immediate
- reveal assistant text at a stable 20-30fps under normal load
- adapt reveal rate when backlog grows
- reduce reveal cadence when user is scrolled away or terminal render cost is high
- flush remaining text at message end through bounded turns, not one giant synchronous mutation
- keep tool output coalesced/chunked; it does not need word-by-word smoothness

## Principles

- Measure before broad changes.
- Fix asymptotics before adding concurrency.
- Terminal flush is the slowest TUI resource; treat it as scheduled work with priority and backpressure.
- Foreground frames and background frames are different product facts.
- A pretty shimmer must never spend the user's latency budget.
- The model may lag behind the UI. The composer may not lag behind the user.

## Non-goals for now

- Do not switch away from Vaxis based on these traces. The major wins came from Zi's own render policy and asymptotics, not from terminal substrate changes.
- Do not add worker concurrency until pure, separable CPU projection remains expensive after bounded work and render asymptotics are fixed.
- Do not optimize tiny phases while render/presentation cadence dominates perceived responsiveness.
