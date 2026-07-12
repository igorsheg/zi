# Implementation PRD: always-responsive, visually locked TUI

- Status: ready for implementation
- Date: 2026-07-11
- Product owner: TUI frontend
- Primary implementation owner: `src/tui/Loop.zig`

## 1. Purpose

Zi does not need another TUI architecture or a broader feature surface. Its
gen-3 structure is already the right one: one interactive owner loop, direct
`AgentSession` driving, one bounded `Transcript`, concrete chrome, and Vaxis as
the terminal mechanism.

This PRD closes the remaining gaps between that architecture and the product
promise:

> The composer always feels immediate, streamed work never monopolizes the
> owner loop, slow local operations never freeze the terminal, canonical screens
> remain visually intentional, and adding a builtin tool cannot silently ship a
> generic UI.

The work is deliberately narrow. It extracts useful properties from Nova,
Zag, and pz—bounded work, explicit lifecycle feedback, compile-time coverage,
and scenario-driven UX verification—without importing their frameworks,
terminal stacks, plugin systems, or projection layers.

## 2. Relationship to existing documents

The following documents remain binding:

- `CONTEXT.md` and `AGENTS.md` define current ownership and layer rules.
- `docs/gen3-tui-plan.md` remains the architecture and behavior record.
- `docs/tui-performance.md` remains the transcript/layout performance contract.
- `docs/runtime-zio-capabilities.md` remains the runtime contract if runtime
  behavior is touched.

`docs/frame-loop-plan.md`, `docs/big-bang-plan.md`, and the parity documents are
historical evidence. Their old completion claims do not override current code.

This PRD adds post-gen-3 hardening and completes behavior already promised by
the gen-3 plan. It does not supersede gen-3's trap list. If an implementation
step appears to require an Engine, ViewModel, protocol envelope, second
transcript, generic scheduler, renderer thread, or local terminal emulator,
stop and redesign the step.

## 3. User-visible outcome

After this work:

1. Typing remains visibly responsive during a maximum-rate real agent event
   stream, including when the runtime event pipe already has a backlog.
2. Opening `/resume`, switching sessions, and preparing prompt images never
   perform disk reads, session parsing, base64 encoding, or shutdown waits on
   the TUI owner loop.
3. The status row truthfully reports `Loading sessions…`, `Opening session…`,
   `Restoring session…`, `Preparing images…`, or `Canceling…` only while that
   state is outstanding.
4. Up/Down moves through visual rows in a multiline composer; history is entered
   only from the first or last visual row, as required by gen-3 behavior B27.
5. Canonical frames are reviewed and locked as semantic, human-readable
   goldens. PTY tests coordinate on state instead of relying only on sleeps and
   accumulated ANSI history.
6. Every builtin tool has an explicit presentation contract. Unknown external
   tools retain a safe generic fallback.

No new end-user feature category is introduced.

## 4. Success criteria

### 4.1 Responsiveness

- Input-to-flush p99 remains below 16 ms during a real `RunHandle`/`EventPipe`
  burst with concurrent typing.
- Dropped input bytes remain zero in every responsiveness gate.
- The existing rendered-frame ceiling remains 33 ms for this implementation.
  Do not replace the p99 product metric with a brittle universal 16 ms wall-clock
  assertion.
- At most `agent_events_per_iteration_max = 8` live agent events are applied by
  one `RunDriver.pump` call.
- Interactive session restore folds at most 16 durable entries and targets at
  most 256 KiB of measured work per owner iteration. One first entry may exceed
  the byte target to guarantee progress, but remains bounded by the existing
  1 MiB session-line limit.
- Exhausting an event or restore budget schedules its continuation at the next
  normal 16 ms frame deadline. An input wake may run earlier, and input is
  always drained before another work batch.
- No listed filesystem read, session parse, base64 encode, subprocess wait, or
  session-shutdown wait runs inside `Loop.dispatch`, `Loop.tick`,
  `Runner.tick`, frame composition, painting, or terminal flush.
- Accepted prompt images contain at most 768 KiB of encoded data in aggregate.
  Completion performs at most one image-data-sized owner-loop copy. The maximum
  accepted payload scenario must still meet the input-latency and rendered-frame
  gates above while typing across the completion boundary.

Eight events per frame-deadline batch permits up to 500 applied events per
second. A full 64-event pipe drains in at most eight batches while giving input
priority between them. This is a fairness quantum, not a second pacing system:
it reuses the one existing frame deadline. If one bounded event can itself break
the frame budget, fix that event's payload/copying work; do not add a
producer-side reveal queue or adaptive throttle.

### 4.2 UX quality

- A cancellation request produces visible truthful feedback in the next
  rendered frame unless the operation reaches its terminal `aborted` state in
  the same iteration. Settlement must never be delayed merely to show an
  intermediate animation.
- Multiline vertical navigation is grapheme-safe, uses the same wrapping
  calculation as composer rendering, and preserves the preferred display column
  across consecutive Up/Down presses.
- Canonical snapshot diffs include row text, row surface, span styles, and
  cursor position.
- Visual assertions cannot pass only because text appeared earlier and was
  later erased.

### 4.3 Maintainability

- `Loop` remains the sole mutation authority for interactive product state.
- Workers receive immutable inputs and publish owned results. They never receive
  `*Loop`, `*Transcript`, or terminal authority.
- Every new accumulation and concurrent operation has a fixed cap and named
  overflow policy.
- A new builtin tool without explicit display policy fails compilation.
- No new dependency and no new public runtime abstraction are introduced.

## 5. Owners and dataflow

| Fact or operation | Owner | Worker authority | Completion/application site |
|---|---|---|---|
| Active `RunHandle`, retry, compaction, event fairness | `RunDriver` inside `Loop` | Existing agent producer owns only its bounded event pipe | `RunDriver.pump` called by `Loop.pumpDriver` |
| Session picker rows and session-operation state | `Loop` | Read directories/files and build an owned result | `Loop.tick` |
| Current live session pointer and swap | `Loop` | Build a complete next `AgentSession`; never mutate the current session; existing torn-tail repair is the only permitted durable side effect | `Loop.tick`, after old-session shutdown is observed |
| Restored-entry cursor and fold budget | `Loop`; content/layout remains owned by `Transcript` | None | `Loop.tick` through existing restore helpers |
| Pending prompt-image preparation | `Loop` | Read bounded files and encode owned `ai.ImageContent` | `Loop.tick` |
| Editor text, cursor, and history | `Editor` | None | `Loop.dispatch` through `Editor` methods |
| Preferred vertical display column | `Loop` | None | Vertical input dispatch; reset by other cursor/edit actions and width changes |
| Composer wrap calculation | Pure TUI presentation helper | None | Shared by chrome rendering and vertical cursor targeting |
| Transcript content/layout | `Transcript` | None added by this PRD | Existing `Transcript.apply` and `prepareLayout` |
| Builtin tool display classification | `coding_agent/tool_metadata.zig` | None | Compile-time contract in the builtin registry |
| Golden artifacts | Test code only | None | Headless frame/grid tests |

The runtime shape remains:

```text
input wake
  -> Runner drains input
  -> RunDriver applies at most 8 live events
  -> Loop advances concrete tasks/timers
  -> compose -> paint -> synchronous flush

background task
  -> owned task result
  -> existing owner wake/deadline resumes Loop
  -> Loop.tick inspects the concrete task slot
  -> Loop applies or destroys the result
```

No worker callback mutates owner state.

## 6. Binding bounds and policies

| Resource | Bound | At the bound |
|---|---:|---|
| Live agent events applied per owner iteration | 8 | Stop draining and schedule the next batch at the existing frame deadline |
| Existing live prompt event pipe | 64 events | Existing producer backpressure; no UI drop policy |
| Session operations | 1 listing/opening/switching operation | Reject a second operation with a status notice |
| New prompt-image preparation tasks | 1 | Reject a second submission attempt; preserve editor text |
| Session-listing deadline | 5 seconds | Request cooperative cancel; keep the slot drain-only |
| Session-opening deadline | 30 seconds | Request cooperative cancel; keep the old session current and the slot drain-only |
| Prompt-image deadline | 10 seconds | Request cooperative cancel; keep the captured prompt recoverable in history |
| Committed old-session drain | Existing 5-second shutdown bound | Escalate through the terminal-restored fatal exit; never deinit unsettled state |
| New-task shutdown drain | Existing 5-second shutdown bound | Restore terminal and terminate with failure rather than deinit task-visible memory |
| Active RunDriver/AgentSession process drain | Existing 5-second shutdown bound | Same terminal-restored fatal exit; never deinit unsettled state |
| Session directory scan | 512 entries | Existing truncation policy |
| Session summaries | 128 summaries, 64 KiB scanned per summary | Existing truncation/fallback policy |
| Restored session | 64 MiB, 16,384 entries | Existing load rejection policy |
| Interactive restore fold | 16 entries and a 256 KiB work target per iteration; one first entry may reach the 1 MiB session-line cap | Stop and continue at the existing frame deadline |
| Prompt images | 4 images, 768 KiB encoded data in aggregate | Reject before starting the agent run |
| Prompt snapshot | `Editor.capacity` bytes | Reject before starting work |
| Semantic golden output | 2 MiB per fixture | Fail the test with `SnapshotTooLarge` |
| Typed scenario | 128 steps and 32 checkpoints | Reject fixture construction |
| Per-checkpoint wait | 5 seconds | Fail the scenario with the checkpoint name |

Session work and prompt-image work use separate concrete slots because they
have different results and lifecycle. At most two new tasks can therefore be in
flight, in addition to the already bounded file-index/query and clipboard task
slots. Do not replace these fields with a generic operation registry.

## 7. Phase P0 — fair `RunHandle` event application

### 7.1 Problem

`RunDriver.pumpPromptHandle` and `pumpCompactionHandle` currently poll in a
`while (true)` loop until the pipe is empty or settled. The pipe has a fixed
capacity, but a concurrent producer can refill it while the owner drains.
`Runner.tick` drains input once before this work, so a sustained producer can
delay the next input drain and the frame that makes typed text visible.

The existing synthetic flood calls transcript code directly and does not prove
fairness at the `RunHandle`/`EventPipe` seam.

### 7.2 Required implementation

1. Add `agent_events_per_iteration_max: usize = 8` next to the other concrete
   TUI work bounds in `Loop.zig`.
2. In prompt and compaction pumping, count only `.live` results against the
   bound. `.empty` returns normally. `.settled` follows the existing settle and
   deinit path immediately.
3. After the eighth `.live` result, stop polling even if more data may exist.
   Record conservative `progress_pending` and `awaiting_render` state. No further
   agent batch may apply until a frame containing this batch has flushed.
4. `Loop.markRendered` clears `awaiting_render` and arms the next batch deadline
   at `frame_start_ns + frame_floor_ns`. Include that deadline in the existing
   `Loop.nextTimerDeadlineNs` calculation. Producer wakes before the deadline may
   run the owner, but cannot apply another batch. Input is still drained and
   painted immediately; an input-triggered frame also satisfies
   `awaiting_render`.
5. At the armed deadline, apply the next batch. Its cap again waits for a
   containing frame before rearming. The next poll clears `progress_pending` on
   `.empty` or `.settled`. Exactly
   eight terminal events may therefore cause one extra deadline poll; that is
   acceptable.
6. Do not peek into, mirror, or replace `EventPipe`, and do not self-wake
   immediately after budget exhaustion. Under a full pipe, producer backpressure
   plus the deadline prevents a busy loop.
7. Preserve event order, persistence-before-live-mutation rules, retry,
   compaction, settlement, and `RunHandle` ownership exactly as today.
8. Add deterministic trace counters:
   `agent_events_applied_per_iteration_max` and
   `agent_event_budget_exhaustion_count`, plus
   `gated_driver_poll_skip_count`. These counters observe policy; they do not
   control scheduling. Do not unregister the pipe wake or add a second wake:
   after an eight-event drain, at most eight refills plus one terminal signal can
   wake a gated single-producer pipe before it is full/backpressured again.

### 7.3 Tests

- Focused driver test with more than three batches proves no pump applies more
  than eight live events.
- The same test proves exact event order and no loss across batch boundaries.
- A terminal result immediately after a full batch settles exactly once on the
  following iteration.
- A fake-clock test proves budget exhaustion cannot apply another agent batch
  before the frame deadline, while input arriving before that deadline is still
  painted immediately.
- Cancellation with a partial backlog still drains/settles safely.
- A faux-provider PTY test emits through the normal provider-resolution and
  `RunHandle` path while typing continuously. It must report:
  input p99 below 16 ms, zero dropped bytes, and at least one budget exhaustion.
- A producer-only steady-state flood proves no agent work applies before the
  containing frame and next frame deadline. Between exhausted batches,
  `gated_driver_poll_skip_count` is at most
  `agent_events_per_iteration_max + 1`; the current wake contract may produce
  these bounded no-op iterations, so no stricter iteration/render ratio is
  asserted.
- The timing-sensitive PTY gate runs serialized three times.

### 7.4 P0 rejection conditions

- No elapsed-time checks inside the event-drain loop.
- No producer sleeps, token pacing, reveal queue, second scheduler, or dropped
  agent event.
- No new event type or translation layer.

## 8. Phase P1 — move blocking local work off the owner loop

### 8.1 Concrete state

Add one concrete `SessionOperation` union owned by `Loop`:

```text
idle
listing(task, apply_result)
opening(task, apply_result, success_notice)
draining_previous(next_session, success_notice)
restoring(next_entry_index, source_bytes, success_notice)
```

Add one concrete `PromptImagePreparation` slot owned by `Loop`:

```text
task
expanded_prompt_snapshot (<= Editor.capacity)
referenced temp paths (<= 4)
apply_result
```

Each task state also owns `deadline_ns` and one concrete `runtime.CancelSource`.
`apply_result` is set to false on cancellation, dismissal, or deadline.
Cancellation from input requests the source and becomes discard-on-completion;
it never calls blocking `runtime.Task.cancel` or waits on the owner loop. A task
result is still observed and destroyed before its captured memory can be
released.

The operational constants live in `Loop.zig`:

```text
session_listing_deadline_ns = 5 * ns_per_s
session_opening_deadline_ns = 30 * ns_per_s
prompt_image_deadline_ns = 10 * ns_per_s
```

`Loop.nextTimerDeadlineNs` includes every active operation deadline. `Loop.tick`
compares only its supplied `now_ns`; workers never read wall time or create
timers.

New operations use `task_runtime.spawn` with explicit `std.Io`, cooperative
yields, and the cancel token between directory entries, session summaries,
session JSONL entries, and 256 KiB image/file-read chunks. Do not use the current
`spawnBlocking` handle for these operations: its cancellation path waits for a
running blocking function and is therefore unsuitable for owner-loop cancel.
These checks bound cooperative cancellation without adding a generic worker
protocol. A single OS I/O completion remains a mechanism boundary; therefore
process shutdown has the terminal policy below instead of pretending request
means completion.

Thread the concrete cancel token through the existing listing/open/load helpers
needed by these three operations. Wrapping the current monolithic call in a task
without adding its bounded yield/check points does not satisfy this phase. The
token is mechanism, not product policy, and must not become a global or generic
operation API.

If a new task, committed old-session drain, active `RunDriver`, or current
`AgentSession` has not reached its terminal condition within the existing
five-second process-shutdown bound, restore the terminal, emit a diagnostic,
and terminate the process with failure without deinitializing any memory still
visible to that work or `RuntimeServices`. The OS then reclaims the isolated
state. This exceptional exit is safer than racing deinit and is testable in a
PTY child. Interactive operation remains responsive while a timed-out task
drains, but another operation using the same slot is rejected.

Authority remains explicit: `Loop` reports the undrained condition;
`tui/root.zig` restores the terminal and returns that terminal condition; `cli`
owns the final process exit before its ordinary runtime/services deinit path can
run. This is a direct typed return, not a new protocol tier.

The exceptional return must suppress every normal defer that would release
runner, `Loop`, session, task captures, `RuntimeServices`, or runtime memory.
`cli` must call `std.process.exit(1)` immediately on that condition, before its
own cleanup defers can execute. Normal exits retain the existing complete cleanup
order; only the explicitly undrained terminal condition takes this OS-reclaim
path.
Task completion does not add a wake source. `Loop` polls every concrete slot
after the existing wake/deadline resumes the one frame loop; the existing
bounded resize poll is the completion-latency fallback.

### 8.2 Session listing

Replace synchronous work in `openSessionPicker` with a concrete `runtime.Task`
using the same one-slot ownership pattern as file indexing and clipboard image
paste.

Required behavior:

1. Listing starts only while the driver is idle, the prompt-image slot is fully
   idle, no clipboard task is active, and the session slot is idle. Otherwise
   preserve the editor and show the applicable busy notice.
2. Opening `/resume` immediately opens an empty session picker and starts one
   runtime listing task.
3. The composer remains the omni input. Filtering typed while loading is applied
   to the rows when the result arrives.
4. The status row reads `Loading sessions… (esc to cancel)`.
5. ESC dismisses the picker and sets `apply_result = false`; it does not wait.
6. Completion populates rows only if the session picker is still current and
   `apply_result` is true. Otherwise the summary list is deinitialized.
7. A listing error leaves the current session and editor untouched and produces
   one bounded warning notice.
8. A second listing request is rejected; it does not start another task.
9. At the five-second deadline, request cooperative cancellation, close the
   picker, show one timeout notice, and retain the task only for draining. The
   current session becomes fully usable immediately.

### 8.3 Session opening and switching

Replace synchronous work in `switchSession` and the timed wait in
`shutdownSessionForSwitch`.

Required behavior:

1. Session opening may start only while `RunDriver` is idle, the prompt-image
   slot is fully idle, no clipboard task is active, and no other session
   operation exists.
2. Copy every borrowed `OpenSpec` slice needed by the task. The worker may borrow
   `RuntimeServices` only because the operation is drained before services
   deinit; it receives no `Loop`, `Transcript`, terminal, or current-session
   pointer.
3. The worker builds the complete next `AgentSession`, including restored
   history/resources/tools, before publishing success.
   Restoring may perform the existing bounded, idempotent repair of a torn final
   JSONL line in the selected session file. That repair is permitted even if the
   UI later cancels or discards the opened session; it restores the last valid
   durable prefix and does not select/mutate interactive session state. No other
   durable fact may be written by the worker.
4. The current session remains live and unchanged while opening. The picker and
   command text may clear after the operation starts; any new composer draft is
   preserved across success or failure.
5. While opening, typing remains enabled. Submit is rejected without clearing
   the draft. The status row reads `Opening session… (esc to cancel)`.
6. ESC sets `apply_result = false`. A late successful session is shut down and
   deinitialized without ever becoming current.
7. On worker success, first perform an owner-side prepare step while the old
   session remains current: validate the operation is still accepted, subscribe
   the next session to the existing `Transcript`, and initialize the bounded
   restore cursor. Do not clear the transcript or mutate the old session yet.
   If prepare fails, request shutdown of the next session, observe completion,
   deinitialize it, and keep the old session and transcript unchanged. This
   cleanup uses the existing five-second shutdown bound; failure to settle uses
   the terminal-restored fatal escalation instead of unsafe deinit.
8. Requesting shutdown of the old session is the commit point. After it, the
   transition is non-cancelable. Enter `draining_previous`, arm the existing
   five-second shutdown deadline, and poll `shutdownComplete` from `Loop.tick`;
   never wait in a loop. Deadline expiry uses the terminal-restored fatal
   escalation because rollback and unsafe deinit are both forbidden.
9. Only after shutdown is observed may `Loop` deinitialize the old session,
   move the complete next session into the existing session slot, bind it,
   clear the old presentation fold, and enter `restoring`.
10. Open or owner-prepare failure leaves the old session fully usable.
11. At the 30-second opening deadline, request cooperative cancellation and
    keep the old session current. A late result is handled as canceled success
    and destroyed. Editing/scrolling remains available, but submit stays
    disabled until the opening task drains because it may still be completing
    durable torn-tail repair.

Listing/opening/owner-prepare is cancelable; `draining_previous` and `restoring`
are not. After the commit point the truthful status is `Switching session…`
followed by `Restoring session…`. Any fallible error after the commit point is a
fatal frontend error: safely shut down the new current session and return an
error rather than presenting a partially restored session as success. There is
no rollback to an already stopped old session.

Interactive restore is a bounded owner continuation:

1. Split the current all-at-once restore into begin, step, and finish operations.
   `Loop` owns the durable-entry index; `Transcript` remains the only owner of
   presentation items and derived layout.
2. One restore step processes at most 16 durable entries or approximately
   256 KiB of measured work, whichever is reached first. One entry may be processed
   atomically to guarantee progress; it remains bounded by the existing session
   line and Transcript item caps.
   `restoreWorkBytes(entry)` is a pure, allocation-free, saturating walk over the
   retained entry: sum every byte slice that restore inspects/copies plus a fixed
   64-byte charge for each message/content/JSON node, clamped to
   `max_session_line_bytes`. If the next entry exceeds the remaining byte target
   after at least one entry was processed, defer it. If it is first, process it
   atomically. Unit tests lock this accounting for every `SessionEntry` variant.
3. Budget exhaustion marks the restore state `awaiting_render`. After a frame
   containing that restore batch flushes, `Loop.markRendered` arms the next
   restore deadline using the existing 16 ms frame floor. Input wakes and paints
   immediately, but another restore step waits for both the containing frame and
   that deadline.
4. The new session is current while restoring, but submit is rejected without
   clearing the composer until the fold is complete. The status row reads
   `Restoring session…`.
5. Live agent runs cannot start during restore, so restored and live events
   cannot interleave out of order.
6. Finish refreshes token totals and editor history, re-pins the viewport,
   updates the terminal title, shows the success notice, and returns the session
   operation to idle exactly once.

Startup restore may still complete before the first interactive frame, but it
must reuse the same restore-step implementation rather than retaining a second
all-at-once fold path.

Normally an idle session becomes stopped immediately. The explicit drain state
exists to make the lifecycle correct even if that implementation detail changes.
Do not deinitialize worker-visible or agent-visible memory after an arbitrary
timeout.

### 8.4 Prompt-image preparation

No-image prompts retain the current direct submit path.

Image-bearing preparation starts only while `RunDriver` is idle. An
image-bearing steer or follow-up during an active/retrying/compacting run is
rejected without clearing the editor. Text-only steer/follow-up behavior remains
unchanged. This removes a race in which prepared images could outlive the run
they were intended to steer.

For a prompt containing tracked clipboard-image paths:

1. Scanning the at-most-`Editor.capacity` prompt and copying at most four paths
   may remain owner-loop work. File reads and base64 encoding may not.
2. Replace the current image-data limit with the explicit TUI constants
   `prompt_image_count_max = 4` and
   `prompt_image_encoded_bytes_total_max = 768 * 1024`. The worker checks
   file lengths, base64 expansion, aggregate size, and integer overflow before
   allocating raw buffers. This deliberately replaces the current 80 MiB
   per-image ceiling: it is incompatible with both the always-responsive
   contract and the durable session's 1 MiB JSONL line cap. A worst-case
   serialized user-message fixture must prove that 768 KiB of image data plus
   maximum escaped prompt/MIME/JSON overhead remains below
   `session_manager.max_session_line_bytes`.
3. Snapshot the expanded prompt, push it into history, pin the referenced temp
   paths to the operation, then clear the submitted text from the composer. The
   user may immediately type the next draft. This is the only history/clear
   commit point for the captured submission.
4. Process images sequentially in the worker. Peak worker memory is one bounded
   raw image plus at most 768 KiB of accumulated encoded output.
5. The status row reads `Preparing images… (esc to cancel)`.
6. Input edits remain foreground work and never affect the captured submission.
   ESC sets `apply_result = false`; it never waits for the background task.
7. On accepted success, submit the captured text/images exactly once regardless
   of the new draft currently in the composer.
8. Add a move-based `SavedPrompt` path for the normal-submit case so the worker
   result is not duplicated merely to enter `SavedPrompt`. The one remaining
   bounded copy into `agent.Agent`'s message arena records its byte count and is
   covered by the maximum-payload input/frame gate at the 768 KiB aggregate
   maximum.
9. After accepted success, call the existing normal
   `RunDriver.submitPrompt` path with the captured prompt. Completion must not
   push history, clear, or otherwise mutate the new draft currently in the
   editor. Release the captured temp files exactly once only after
   `startPromptHandle` succeeds.
10. Failure or cancellation never overwrites the current draft. Keep the
    captured prompt in history and return its still-valid temp paths to Loop's
    bounded tracked-path set so Up can recover and retry it. Show one notice that
    names history recovery. Successful submission deletes the pinned temp files
    only after the existing agent path has copied their data.
11. A second submit while preparation is in flight is rejected without clearing
    its text. New clipboard-image paste and every session listing/open request
    are rejected until the prompt-image slot is fully idle.
12. At the 10-second deadline, request cooperative cancellation and preserve
    history/current draft exactly as for user cancellation. Editing may continue,
    but all submit variants remain rejected until the image slot drains so the
    captured prompt remains the most recent recoverable history entry.
13. Owner-side start failure after successful preparation is recoverable: clear
    any partially installed `SavedPrompt`, free encoded buffers, return pinned
    paths to Loop's tracked set, keep the history/current draft untouched, and
    show one failure notice. No temp path is deleted before the start commit.

The worker result owns all encoded image and MIME buffers. Ownership transfers
to `SavedPrompt`/`AgentSession` only during accepted completion; all canceled
and failed paths free it in the completion branch. Temp-path ownership is
equally explicit: paths are pinned by the operation while the worker can read
them, then deleted on success or returned to Loop's bounded tracked set on
failure/cancellation.

### 8.5 Status and ESC priority

Status priority becomes:

```text
exit -> exit hint -> session operation (including restore) -> prompt-image preparation
     -> clipboard image paste -> retry/compaction -> active run -> idle
```

ESC priority becomes:

```text
picker/completion
  -> cancelable session listing/opening or prompt-image operation
  -> retry/compaction/agent run
  -> idle no-op
```

A canceled concrete task remains owned until its terminal result is observed.
Its status changes to `Canceling…` (or `Canceling image preparation…`), and a
conflicting new request remains rejected. Because `apply_result` is already
false, repeated ESC does not issue another task cancellation request and may
continue down the centralized cascade.

New user-facing copy is fixed for this work:

| State | Copy |
|---|---|
| Listing sessions | `Loading sessions… (esc to cancel)` |
| Opening next session | `Opening session… (esc to cancel)` |
| Draining the previous session | `Switching session…` |
| Folding restored entries | `Restoring session…` |
| Preparing prompt images | `Preparing images… (esc to cancel)` |
| Discarding image preparation | `Canceling image preparation…` |
| Outstanding run cancellation | `Canceling…` |
| Conflicting session request during listing/opening | `busy: session operation in progress — esc to cancel` |
| Conflicting request after session commit | `busy: switching sessions` |
| Conflicting submit | `busy: preparing images — esc to cancel` |
| Image submit while run active | `wait for the current run before sending images` |
| Listing deadline | `session listing timed out` |
| Opening deadline | `session opening timed out` |
| Recoverable image failure | `image preparation failed — press up to recover the prompt` |
| Recoverable image cancellation | `image preparation canceled — press up to recover the prompt` |
| Image deadline | `image preparation timed out — press up to recover the prompt` |

### 8.6 Operation compatibility and temp-path ownership

| Request | Allowed | Rejected/preserved behavior |
|---|---|---|
| Insert/edit/scroll/resize | During every non-shutdown phase | Never blocked by agent or local task work |
| Text-only submit | Existing `RunDriver` rules; also while a canceled listing merely drains | Reject during any session opening/switch/restore, accepted listing, or any occupied prompt-image slot; keep text |
| Start session listing/opening | Driver idle, prompt slot fully idle, no clipboard task, session slot idle | Reject without changing picker/editor/session |
| Start prompt-image preparation | Driver idle, session slot idle, clipboard task idle, prompt slot idle | Reject without clearing editor/history |
| Start clipboard-image paste | Session slot idle, prompt slot fully idle, tracked paths below four | Reject with existing bounded notice; active agent run alone is allowed |
| New session/image operation while an old canceled task drains | Session work requires both session and prompt slots idle; image work requires both slots idle | Reject the conflicting operation; only the explicitly allowed text-only work may continue |
| File-index/query completion | Any non-shutdown phase | Existing stale/cancel policy remains independent |
| Process shutdown | No new operation | Request every concrete cancel source, drain up to five seconds, then use the exceptional terminal-restored failure exit from §8.1 |

Temp paths have exactly one owner. Ordinary pasted paths belong to Loop's
tracked set. Starting prompt preparation moves the referenced paths into its
pinned set, so editor clear and clipboard cleanup cannot delete worker-visible
files. Success deletes them after the agent copy. Failure/cancellation moves
them back to Loop; the prohibition on new paste/session work while the prompt
slot is occupied guarantees the original four-path capacity remains available.
Loop deinit never deletes a pinned path before the task drains.

`draining_previous` and `restoring` are non-cancelable commit phases. ESC during
them does not roll back or emit a cancel hint; it continues down the centralized
cascade, which is otherwise idle because session transition requires an idle
driver.

### 8.7 P1 tests

- A deliberately slow session listing task runs while at least 100 input actions
  are typed and painted. No input is dropped and the picker applies the result
  only when still current.
- Maximum directory and summary bounds remain enforced.
- A multi-MiB restored-session fixture opens while typing remains responsive.
- A maximum-entry restore proves no step exceeds 16 entries or its 256 KiB work
  target except for one first entry bounded by 1 MiB; input is accepted between
  steps, and live submission is rejected without clearing the draft until
  restore finishes.
- Session open failure, cancellation, late success, and stale success all keep
  or destroy the correct session exactly once.
- The old session is never deinitialized before `shutdownComplete`.
- Slow prompt-image read/encoding keeps the composer editable.
- The four-image aggregate cap rejects encoded data above 768 KiB before run start,
  and the maximum accepted completion still satisfies the input/frame gates
  while typing across that completion.
- Image-bearing submission while the driver is not idle is rejected without
  clearing the draft; text-only steering/follow-up remains unchanged.
- Edited, canceled, failed, and successful image preparations preserve or clear
  captured history, the current draft, and temp files according to §8.4.
- Owner-side prompt-start failure after preparation returns path ownership and
  leaks neither `SavedPrompt` nor encoded image buffers.
- Loop shutdown drains every new task result and passes allocator leak checks.
- A PTY child with a deliberately non-cooperative task proves the five-second
  shutdown escalation restores the terminal and exits with failure without a
  deinit race.

## 9. Phase P2 — truthful cancellation and multiline navigation

### 9.1 Cancellation feedback

`PromptRun` already owns the runtime cancellation state. Do not mirror that fact
as an independent UI lifecycle.

Required change:

1. Expose a narrow read-only `RunHandle` query for whether cancellation is
   outstanding, or return an explicit first-request/already-requested result from
   `cancelRequest`.
2. Make repeated cancellation requests idempotent at the `PromptRun` owner.
3. `statusView` renders `Canceling…` only while the handle reports an outstanding
   cancellation request.
4. If cancellation reaches terminal `aborted` in the same owner iteration,
   render the terminal state directly. Do not defer settlement for visual effect.
5. Queued text restoration and aborted tool state occur exactly once.

Tests cover first request, repeated ESC, late events, same-iteration settlement,
queued-text restoration, and one terminal aborted notice.

### 9.2 Multiline visual navigation

Gen-3 behavior B27 requires Up/Down to navigate the composer visually and enter
history only at its boundaries. The current direct Up/Down-to-history mapping is
a conformance gap.

Required behavior:

1. Rename the input operations from history-specific names to vertical intent.
2. Use the exact same soft-wrap and Unicode display-width calculation for
   rendering and cursor targeting. There must not be a second wrapping
   implementation.
3. Consecutive Up/Down presses preserve a preferred display column. Reset that
   column after horizontal movement, insertion, deletion, history replacement,
   Home/End, any direct cursor relocation, or composer-width change.
4. Up on any visual row except the first moves to the previous visual row. Up on
   the first visual row invokes previous history.
5. Down on any visual row except the last moves to the next visual row. Down on
   the last visual row invokes next history.
6. Clamp to the nearest grapheme boundary when the target row is shorter.
7. Paste markers remain atomic cursor units.

The shared calculation may remain a public pure helper in `chrome.zig`; extract
a concrete composer-layout helper only if sharing it in place would duplicate or
obscure the algorithm. It must own no mutable state. `Loop` owns one bounded
`preferred_editor_column_cells` value; `Editor` remains the owner of text,
history, and the actual cursor byte.

Tests cover hard newlines, soft wraps, wide Unicode, combining sequences, short
target rows, repeated preferred-column movement, paste markers, first/last row
history transitions, and narrow composer widths.

## 10. Phase P3 — semantic goldens and signal-driven scenarios

### 10.1 Three test layers

1. **Semantic frame goldens.** Serialize the existing `screen.Frame` with fixed
   `now_ns`: dimensions, cursor, each row's text and row surface, and each span's
   style. This is the primary human visual-review artifact.
2. **Painted-grid checks.** Drive the existing headless `Runner`/Vaxis screen and
   assert the final visible cells and cursor. This proves semantic frames are
   painted as intended without creating a second terminal model.
3. **PTY mechanics and latency.** Keep the real PTY for input decoding, resize,
   alt-screen lifecycle, terminal restoration, provider resolution, and timing.
   Fixed sleeps may remain only as deadlines; scenario advancement should wait
   for a named trace/state signal wherever possible.

Accumulated raw ANSI output is not a visual oracle. A substring may be used to
coordinate a PTY step, but final visual assertions belong to semantic frame or
painted-grid checkpoints.

Do not implement an ANSI parser. Do not add Ghostty, pz's VScreen, or a second
cell buffer. A PTY final-grid assertion is permitted only if a directly reusable
vendored Vaxis API can provide it without copying terminal parsing or screen
state into Zi. It is not required for this phase because the headless Vaxis grid
covers the painting seam.

### 10.2 Snapshot format and update policy

- Add one test-only serializer with a 2 MiB allocating-writer cap.
- Encode text with Zig/JSON string escaping so whitespace and control characters
  are unambiguous.
- Normalize styles structurally: foreground, background, underline, and boolean
  attributes. Use a fixed timestamp for shimmer fixtures.
- Store approved files under `docs/baselines/tui/`.
- Ordinary tests compare only. Rewriting requires an explicit
  `ZI_UPDATE_TUI_GOLDENS=1` test invocation; CI never rewrites artifacts.
- A golden change must be reviewed as product output, not accepted as mechanical
  churn.

Required initial fixtures:

- startup/idle at 80×24;
- visible thinking transitioning to answer;
- hidden thinking transitioning to answer;
- live, completed, failed, and aborted tools;
- scrolled transcript with new output below;
- retry, compaction, preparing, opening, and cancellation statuses;
- completion and session picker;
- multiline composer with Unicode at 40×10;
- combined queue/status/composer chrome at 80×24;
- representative tool-heavy transcript at 120×32.

### 10.3 Typed scenarios

Add a small test-only union of concrete steps, capped as specified in §6:

```text
dispatch input action
apply agent event
advance owner tick to explicit timestamp
resize
checkpoint semantic frame
checkpoint painted grid
```

This is a fixture helper, not a general scenario language. It has no parser,
plugin surface, dynamic registry, or product runtime state.

### 10.4 P3 gate

- Every required fixture is approved and deterministic across three runs.
- Deleting or restyling a visible row produces a readable golden diff.
- A test that prints then erases a string proves the final-grid assertion does
  not pass on stale output.
- PTY tests no longer use raw accumulated output as the sole proof of final
  layout.

## 11. Phase P4 — compile-time builtin tool UX coverage

### 11.1 Problem

The builtin registry and `tool_metadata.kind` independently enumerate builtin
names. An unclassified new builtin silently falls back to `.custom`, compiling
successfully with generic title/body/collapse/live-update behavior.

The generic fallback is correct for external tools but incorrect as the default
for a Zi builtin.

### 11.2 Required implementation

1. Expose an authoritative `explicit_builtin_names` array or equivalent
   `hasExplicitBuiltinPolicy` predicate from `tool_metadata.zig`.
2. Add a bidirectional compile-time check in `tool_registry.zig`:
   every `default_active_tool_names` entry has explicit metadata, and every
   explicit builtin metadata entry names a registered builtin.
3. Preserve `.custom` for names outside the builtin set.
4. Keep the check concrete. Do not create a generic UI registry or move TUI
   rendering authority into tool execution code.
5. Add table-driven unit coverage for every builtin's complete call, partial
   arguments, successful result, failed result, collapse direction, body mode,
   and live-update policy.

The compiler error must name the missing or orphaned tool.

### 11.3 P4 gate

- Adding a temporary builtin name without metadata fails compilation.
- Adding temporary orphaned metadata fails compilation.
- Existing read/bash/edit/write presentation fixtures remain green.
- Unknown custom tools still render safely with the generic policy.

## 12. Persistence and frontend scope

- All work in P0–P3 is TUI-only. The print frontend remains unchanged.
- P4 changes shared neutral tool metadata but does not give print mode TUI state.
- No new durable session entry, settings key, cache file, or protocol field is
  introduced.
- Session creation/restoration keeps existing persistence policy and continues
  to build completely before swap.
- Prompt text and images are persisted only through the existing
  `AgentSession` path after preparation succeeds.
- Golden files are test artifacts, not runtime persistence.

## 13. Error and shutdown contract

Every concrete task path must implement all of these outcomes:

| Outcome | Owner action |
|---|---|
| Start rejected | Keep current state and input; show one bounded notice |
| Worker success, current | Move owned result into owner state exactly once |
| Worker success, canceled/stale | Deinitialize the entire result; apply no interactive mutation. A completed idempotent torn-tail repair may remain |
| Worker error | Preserve current session/editor; show one bounded notice |
| Owner shutdown while running | Request cancellation, observe/join within five seconds, then deinit; otherwise suppress deinit and use the terminal-restored fatal exit |
| Session open succeeds during shutdown | Request shutdown on the new session, drain it, then deinit it |
| Committed old session misses drain deadline | Do not roll back or deinit it; report the undrained terminal condition and use the fatal exit |
| Wake coalesces | Poll every owned task slot after waking; payload never lives in the wake |

No callback may run after `Loop.deinit`. No task may retain a pointer into picker,
editor, scratch, transcript, or current-session storage.

## 14. Implementation sequence and merge policy

Implement phases in order. Each phase is independently reviewable and must leave
all gates green before the next begins:

1. **P0:** event fairness and real-pipe responsiveness gate;
2. **P1:** session/image tasks and nonblocking session swap;
3. **P2:** truthful cancellation and multiline vertical navigation;
4. **P3:** semantic goldens, painted-grid checks, and typed scenarios;
5. **P4:** compile-time builtin display-policy coverage.

P0 and P1 are release-blocking for the “always responsive” claim. P2 is the
highest-value interaction polish. P3 is what lets visual quality scale without
fear. P4 is small but mandatory insurance against future tool UX drift.

Do not combine these phases with unrelated features or large file moves. Keeping
state in `Loop.zig` is preferred over splitting ownership merely to reduce file
length. Pure leaf helpers and test-only serializers may be separated when that
makes their lack of mutation authority obvious.

## 15. Verification

Every phase runs its focused tests plus the repository gates appropriate for a
TUI change:

```sh
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

Timing-sensitive PTY gates run serialized three times. E2E provider tests use
`ZI_ENABLE_FAUX_PROVIDER=1` and normal provider resolution. They must not inject
private stream callbacks around `RuntimeServices`.

The final PR description must include:

- the maximum agent events applied in one iteration;
- input p50/p90/p99 and dropped-byte count for the real-pipe flood;
- owner-loop/frame maxima for the slow session and image scenarios;
- the list of added/changed golden fixtures;
- proof that every new task is drained on shutdown;
- any gate not run and why.

## 16. Explicit non-goals

- No renderer thread, async terminal writer, double buffer, or damage-rectangle
  framework.
- No generic widget tree, TUI SDK, task registry, scheduler, operation registry,
  or scenario language.
- No producer-side pacing, reveal queue, UI throttle, token drop, or extra time
  constant.
- No Engine, ViewModel, client protocol, wire protocol, projection corridor, or
  mirrored transcript.
- No custom ANSI parser, terminal screen, width engine, style encoding, or raw
  mode implementation.
- No new pane, lane, plugin, Lua, or multi-agent window architecture.
- No session branching, tree navigation, mouse interaction, or unrelated coding
  agent features.
- No dependency addition.

## 17. Definition of done

This PRD is complete only when all of the following are true:

- [ ] A continuously refilled agent event pipe cannot monopolize one owner-loop
      iteration.
- [ ] Input is drained between every full agent-event batch.
- [ ] Event/restore continuation uses the existing frame deadline and the
      producer-only flood proves there is no unbounded non-rendering busy spin.
- [ ] Session listing, session-file parsing, prompt-image file reads, base64
      encoding, and session-switch shutdown waits are absent from the owner
      loop.
- [ ] Interactive restored-entry folding obeys its count/byte budget and yields
      to input between batches.
- [ ] Every new task has one owner, one slot, explicit cancellation/discard
      semantics, an operational deadline, and shutdown drain/escalation
      coverage.
- [ ] Committed session switch and process shutdown never deinitialize an
      unsettled RunHandle, AgentSession, or task; the exceptional exit suppresses
      ordinary defers before immediate CLI termination.
- [ ] The worst-case accepted image message serializes below the 1 MiB durable
      line limit and completion never clears the user's newer draft.
- [ ] The real-pipe flood meets p99 input-to-flush below 16 ms with zero input
      drops in three serialized runs.
- [ ] Cancellation feedback is immediate and truthful without delaying
      settlement.
- [ ] Multiline Up/Down navigation satisfies gen-3 behavior B27 at hard and soft
      wraps.
- [ ] Canonical semantic frames and painted grids are human-reviewed and stored
      under `docs/baselines/tui/`.
- [ ] PTY tests do not use stale accumulated output as the sole visual oracle.
- [ ] Missing or orphaned builtin tool display policy fails compilation.
- [ ] `docs/tui-performance.md` records the new event, restore, task, and image
      bounds; `docs/gen3-tui-evidence.md` points B6/B10, B15/B16, and B27 at the
      new evidence.
- [ ] All repository gates in §15 pass.
- [ ] No non-goal in §16 was introduced.
