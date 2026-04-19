# Heavy CLI agent workflow simulation

## Goal
Trace a realistic TUI ↔ agent ownership path, then pivot into targeted follow-up inspection.

## First-pass findings

### Canonical docs checked
- `docs/README.md`
- `docs/runtime.md`
- `docs/architecture.md`

### Runtime shape
- zi uses two mailbox-backed long-lived channels:
  - request queue: TUI → agent
  - event queue: agent/helper → TUI
- Cross-thread payloads must be fully owned and allocated from `msg_allocator`.
- The TUI consumes semantic snapshots and rebuilds local presentation state.

### Concrete request channel
From `src/coding_agent/request.zig`:
- `AgentRequest` variants currently include:
  - `prompt`
  - `resume_session`
  - `new_session`
  - `set_model`
  - `set_thinking_level`
  - `enqueue_queued_input`
  - `restore_queued_inputs`
  - `refresh_status_snapshot`
  - `shutdown`
- `RequestQueue` is a mailbox with `.unbounded` policy and `.pipe` wakeup.
- Payload cleanup is centralized in `AgentRequest.deinit`.

### Concrete event channel
From `src/tui/ui_event.zig`:
- `UiEvent` carries conversation state, status snapshots, request/prompt lifecycle events, model/thinking change outcomes, retry/login events, and session outcomes.
- `status_snapshot` is explicitly semantic transport, not UI-chip transport.
- Cleanup is centralized in `UiEvent.deinit`.

### TUI integration seam
From `src/tui/interactive.zig`:
- `Interactive` owns both `event_queue` and `request_queue` handles.
- `run()` starts the long-lived agent thread, primes status via snapshot publication, then drains `event_queue` in the main loop.
- `deinit()` performs ordered shutdown:
  1. abort active prompt if needed
  2. enqueue shutdown
  3. close request transport
  4. join agent thread

## Follow-up questions
1. Where exactly does the agent owner loop drain and dispatch `AgentRequest` variants?
2. Which handlers publish `status_snapshot` and `conversation_state`?
3. How do slash-command UI actions map into request queue submissions?

## Next targeted files to inspect
- `src/tui/interactive.zig` owner-loop and request dispatch section
- `src/tui/interactive.zig` status snapshot publication helpers
- `src/tui/interactive.zig` `/model`, `/resume`, and startup action enqueue paths
