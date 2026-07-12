# Frame loop plan: enforce the 60fps invariant structurally

Status: in progress
Owner: TUI frontend (`src/frontends/tui/interactive.zig`) + session runtime step path

Progress:

- Step 1: done — debug watchdog, owner-loop trace phase, flood test, AGENTS contract.
- Step 2a: done — session open/switch builds the next slot on a completion worker; one in-flight load, reject policy.
- Step 2b: done — clipboard copy, clipboard image paste, and prompt image attachment read/encode run on a frontend worker.
- Step 2d: done — jsonl append bound named at the persistence site.
- Step 2c: done — measured, no-go for render writer thread (see note in 2c).
- Step 2e: in progress — stream update copies now use compact delta events on public/emit paths; 1MB accumulated-partial flood gate added. Trace improved `prompt_progress_apply` 40.104ms -> 8.604ms and `owner_loop` 45.256ms -> 22.768ms. Latest trace isolated remaining apply cost to session apply (`8.418ms`), with write-tool arg preview/output work as the visible hog; tool execution args and write previews are now bounded before TUI presentation.
- Step 3, Step 4: not done; reclassified as hygiene/deletion, not perf (flush and
  intervals are proven cheap). Do after 2e.

## Invariant (the contract this plan enforces)

> An owner-loop iteration between waits never exceeds the frame budget, and the
> owner loop never performs an operation whose latency is not bounded by memory
> speed.

Today this is observed (60 trace phases) but never enforced. The plan converts
it into a failing test, then removes the violations, then deletes the scheduler
accretion that grew around them.

Do the steps in order. Step 1 is cheap and makes every later step verifiable.
Steps 2a–2b are the user-visible freezes; they matter more than any scheduler
elegance. Step 3 is the structural cleanup and is a net deletion.

---

## Step 1 — Make the invariant a contract

**Change**

- Add a frame watchdog to `InteractiveController.run`: measure each iteration
  between `waitForFrontendWake` returns. In debug builds, `std.debug.assert`
  iteration time <= `frame_budget_ms_max` (start at 50ms to avoid flakes, then
  ratchet down). Exempt explicitly-blocking states: external editor, shutdown,
  resize storm.
- Add one CI test: synthetic session flood (large assistant stream + chatty
  tool output + history page) driven through the controller with a fake clock
  or real clock threshold; fail if any iteration exceeds the budget.
- Name the second half of the contract in `AGENTS.md` tui section: "the owner
  loop performs no filesystem read of unbounded size, no subprocess wait, and
  no blocking network I/O."

**Files**: `src/frontends/tui/interactive.zig`, `AGENTS.md`, one new test.

**Done when**: the flood test exists, passes, and demonstrably fails if a
`sleep(20ms)` is injected into the drain path.

---

## Step 2 — Remove unbounded-latency work from the owner thread

These are the actual freezes. No throttle tuning fixes them.

### 2a. Session open/replace off the owner thread

`replaceSession` -> `openSession` (`src/coding_agent/session_runtime.zig:1008`)
reads and parses the entire session jsonl and builds resources/tools/agent
inline inside `applyCommand`, i.e. inside `stepTimed`, i.e. on the UI thread.
`/resume` and session switch freeze the UI for the full load.

**Change**

- Reuse the existing `completion_load` worker pattern (already used for file
  index, file query, resume listing). Add a load kind `session_open`.
- `switch_session` / `new_session` command: capture inputs, spawn worker that
  builds the *complete* next slot (services + `AgentSession`), publish the
  built slot through the completion slot, swap in `finishReadyCompletionLoad`
  on the owner path. This keeps the existing rule "build the next slot
  completely before swapping" — it just builds it off-thread.
- While a session open is in flight: reject a second open with `.busy`, keep
  the current session live, show a status line ("opening session...").
  Bound: one in-flight session open, reject policy.
- Cancellation: if the runtime shuts down mid-load, join the worker, deinit
  the half-built slot in the worker's own scope. No owner memory is touched
  until swap.

**Files**: `src/coding_agent/session_runtime.zig`.

**Done when**: switching to a multi-MB session keeps the composer echoing
keystrokes (flood test variant), and slot-swap tests still pass.

### 2b. Clipboard and image attachment off the owner thread

`spawnAndWait` (`interactive.zig:1049`), `clipboard_image.read`, and
`readPromptImageAttachment` (file read + base64) run inline on paste/submit.

**Change**

- Run clipboard read/copy and image read+encode on a worker (same
  wake-on-complete pattern as `InputReader`: worker thread, bounded result
  slot, `frontend_wake`). One in-flight clipboard operation; reject further
  requests while busy.
- On completion the owner drains the result and mutates the composer. Errors
  become status lines, as today.

**Files**: `src/frontends/tui/interactive.zig`,
`src/frontends/tui/clipboard_image.zig`, `src/frontends/tui/clipboard_text.zig`.

**Done when**: a slow `pbpaste` (test shim with sleep) does not stall echo.

### 2c. Measure the tty flush before touching it

`vx.render(tty.writer())` in `Terminal.renderIfDirtyTimed` is a synchronous
flush; on a slow tty (ssh/tmux) it blocks the loop, and the adaptive backoff
only degrades background frames — foreground typed-echo frames still block.

**Change (measurement only, no code)**

- Collect `render_flush_foreground` / `render_flush_background` maxima from
  real ssh/tmux sessions via the existing `ZI_TUI_TRACE`.
- Only if flush p-max is a real problem (> a few ms sustained): move the tty
  write to a writer thread with a 1-frame buffer, drop-and-recompose on
  overflow. That is a separate design; do not build it speculatively.

**Done when**: numbers exist and a go/no-go note is appended to this doc.

**Go/no-go note 2026-07-03**: local trace `/var/folders/wn/khflxq4j4x37dqnh2j1b_hc40000gn/T/zi-tui-trace-572053949282625.log` showed `render_flush_foreground` max 3.868ms and `render_flush_background` max 6.481ms. Decision: no-go for render writer thread; flush is not the current freeze source. The slow samples point at `session_step_prompt_progress_apply` around 40ms instead.

### 2e. Fix O(message^2) streaming apply — the real 40ms

Trace verdict from 2c: `session_step_prompt_progress_apply` max ~40ms is the
frame killer. Root cause: every `message_update` delta event carries a full
snapshot of the accumulated partial assistant message, deep-copied up to 3x
per delta on the owner thread:

1. `Agent.emitFromLoop` (`src/agent/Agent.zig:474`) — `copyAgentEvent` of the
   whole partial into the event scratch arena.
2. `setStreamingMessage` (`src/agent/Agent.zig:496`) — arena reset +
   `copyAgentMessage` of the whole partial, per delta.
3. `OwnedAgentEvent.init` (`src/coding_agent/client_protocol.zig:546`) — whole
   partial copied again into the public ClientEvent queue, where the frontend
   reads only the delta text back out.

Cost per event grows linearly with accumulated message size — the
"progressively janky during long answers" feel. Budgets cannot save this:
`stepPromptProgressBounded` checks time *between* events, so one 40ms event
blows the frame.

**Change**

- `setStreamingMessage` becomes an in-place append of the delta into the
  streaming arena's partial; no reset+full-copy per event. The Agent stays the
  single owner of the accumulated partial.
- Public event path: strip `partial` from `message_update` before the
  `OwnedAgentEvent` deep copy. Carry the delta plus a bounded projection:
  content index, event kind, and (for toolcall events) the one partial tool
  call that `applyToolCallPreview` consumes. Frontend switches to that
  projection.
- If clean, push delta-first events to the source (`ai` stream event shape,
  `src/agent/loop.zig` transport copy) so every downstream copy collapses.
  Snapshot-on-reconnect stays served by history snapshot, not partials.

**Regression gate**

- Extend the flood test: one assistant message accumulating to ~1MB in small
  deltas; assert per-iteration cost stays flat over message length (the step-1
  watchdog fires if not). Re-run `ZI_TUI_TRACE`:
  `prompt_progress_apply` max should drop from ~40ms to <1ms and stay flat.

**Files**: `src/agent/Agent.zig`, `src/agent/root.zig`, `src/agent/loop.zig`,
`src/coding_agent/client_protocol.zig`, `src/coding_agent/AgentSession.zig`,
`src/frontends/tui/interactive.zig`.

**Trace note 2026-07-03**: after compact stream-event copies, local trace `/var/folders/wn/khflxq4j4x37dqnh2j1b_hc40000gn/T/zi-tui-trace-574676579004333.log` showed `owner_loop` max 19.654ms and `session_step_prompt_progress_apply` max 11.706ms, down from 45.256ms / 40.104ms. Follow-up trace `/var/folders/wn/khflxq4j4x37dqnh2j1b_hc40000gn/T/zi-tui-trace-577365493045791.log` showed `prompt_progress_apply` 8.604ms, `session_apply` 8.418ms, `pending_tool_output` 4.430ms, and render tool/build work in the same range. The write tool path was the visible hog: full write content was still being copied through tool execution args and previewed line-by-line before truncation. Tool execution args now use bounded preview copies and write call previews only queue visible lines.

**Done when**: the 1MB flood passes the watchdog and trace shows flat
per-event apply cost.

### 2d. Name the persistence policy

The jsonl append on `message_end` (`AgentSession.zig:1137`) runs inside the
step path. It is a small buffered append with no fsync, almost certainly fine.

**Change**: add a comment naming the bound ("single bounded append, no fsync;
move to worker if trace shows it") and a `session_step` trace check in the
flood test. No code motion.

---

## Step 3 — One frame scheduler (net deletion)

> Reclassified after 2c/2e findings: this step is auditable-loop hygiene and
> code deletion, **not** a responsiveness fix. Flush maxima (3.9ms fg / 6.5ms
> bg) and pacing intervals are not the bottleneck. Do it after 2e, expect no
> feel change, and treat any feel change as a regression.

Today the cadence is emergent from four mechanisms: `RenderThrottle` (4
priorities + adaptive backoff + 3 interval fields), per-kind presentation
intervals (12/16/32/100/200ms), loop wake delays (0/16/30000ms) +
`clampWakeDelayToDeadline` + `App.nextDeadlineMs`, and `renderIfDue` called
from two sites with a reason enum. The 12ms `assistant_reveal_interval_ms`
exists only to phase-beat the 16ms animation tick — a constant tuned against
another constant.

**Target model**

Two render classes, one deadline, one budget:

```text
loop:
  deadline = min(app.nextDeadlineMs, pending_ui_work.dueAtMs, animation.dueAtMs)
  wake     = wait(min(deadline - now, idle_max))
  budget   = frame_budget (one value, threaded down)
  drain input                (foreground; may consume budget freely)
  step session + drain events (remaining budget)
  apply due presentation work (remaining budget)
  if dirty and (foreground_requested or now >= render_due):
      render once; render_due = now + max(min_interval, 3 * last_render_cost)
```

**Change**

- Every pacing policy becomes a pure `dueAtMs()` on its owner
  (`presentation_queue.Queue.nextIntervalMs` already is one; convert it to an
  absolute deadline). The loop computes one `next_deadline` and sleeps to it.
- Replace `FramePriority {none, background, scroll, foreground}` with one bit:
  `foreground_requested` (typed input / resize) plus `render_due_ms`. Scroll is
  foreground.
- Delete: `RenderThrottle.pending` priority lattice, `backgroundDue`,
  `requestBackgroundFrame`, `requested_background_interval_ms`,
  `render_request_interval_ms`, `BackgroundRenderReason`, and the second
  `renderIfDue` call site. Keep the one good idea — cost-based backoff
  (`3 * last_render_cost`) — as a single line in the render-due computation.
- Set `assistant_reveal_interval_ms = animation_frame_interval_ms` (16). The
  12ms phase trick dies with the dual scheduler.
- Per-phase constants (`client_event_drain_time_budget_ns`,
  `pending_ui_work_time_budget_ns`, per-tick caps) collapse into one frame
  budget passed as *remaining* time. Keep count caps as safety bounds; drop
  the independent time constants.

**Files**: `src/frontends/tui/interactive.zig`,
`src/frontends/tui/presentation_queue.zig`.

**Done when**: diff is net-negative in the scheduler code, flood test from
step 1 still passes, streaming/scrolling feel is unchanged by eye.

---

## Step 4 — Shrink the pipeline and the trace

**Change**

- Route all transcript mutation through the presentation queue where event
  ordering allows, removing the direct-apply/queued dual path
  (`appendMessage` vs `queueMessage`). One pacing point, one byte bound, one
  drop policy. History/snapshot replay may stay direct (it is not paced), but
  say so in a comment.
- After step 3 lands, delete trace phases that existed only to debug the
  three-scheduler interaction (`noteForegroundWithPendingBackground`,
  `background_render_*_count`, the accept-to-queue/queue-wait chain if the
  numbers are flat). Keep: wait phases, session step, drain, draw, flush,
  watchdog. Target well under half of the current 60 phases.

**Done when**: `trace.zig` fits on a screen and the flood test still explains
where time goes.

---

## Explicitly not doing

- No render thread / double-buffered flush without 2c numbers.
- No generic scheduler/registry abstraction; the loop stays concrete.
- No transcript/layout changes — memoized layout, bounded eviction, and
  O(viewport) draw are already correct.

## Gates per step

```sh
zig build test
zig build
zig fmt --check src
```

plus the step-1 flood test once it exists.
