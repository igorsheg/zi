# Session resume transcript reconstruction

## Status

Proposed.

## Purpose

Close pi-mono parity for **resume transcript reconstruction**.

This spec is intentionally about only one path:

```text
session file -> buildSessionContext() -> owned resumed message snapshot -> TUI transcript reconstruction
```

It is **not** a provider replay spec.
It does not cover:
- OpenAI Responses / Codex replay payloads
- `transformMessages()` / provider replay transforms
- request serialization for follow-up turns
- same-model vs cross-model replay policy

Those belong to `docs/replay.md` and provider-specific replay work.

## Problem statement

zi can resume a session and restore agent state, but the visible transcript rebuild is currently lossy.

Today the `/resume` path projects the resumed session into a narrow TUI payload that only carries:
- user text
- assistant text blocks
- assistant thinking blocks

That drops transcript-relevant state that pi-mono reconstructs on resume, including:
- assistant tool calls
- tool results
- compaction summaries
- branch summaries
- displayable custom messages
- assistant aborted/error state needed to render failed tool executions

The result is a resumed session that is functionally loaded but visually partial.

## Success criteria

1. **A resumed session looks like I never quit it in the first place.**
   - the reconstructed transcript matches pi-mono behavior for the same saved session
   - tool calls, tool results, summaries, displayable custom messages, and failed/aborted tool rows all reappear correctly

2. **The transcript reconstruction path is a clear system, not a patch.**
   - the boundary between session state, cross-thread payload, and TUI rendering is explicit
   - testing can target the boundary directly
   - extending resume rendering for new message surfaces is localized
   - debugging can answer “did we clone the wrong messages?” separately from “did we render them wrong?”

## pi-mono source of truth

Implementing agents should start from these exact files before changing zi code.

### Session context resolution
- `.references/pi-mono/packages/coding-agent/src/core/session-manager.ts:310-417`
  - `buildSessionContext(...)`
  - walks leaf -> root
  - applies compaction / branch / custom-message semantics
  - yields `messages`, `thinkingLevel`, `model`

### Resume transcript reconstruction
- `.references/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts:2687-2749`
  - `renderSessionContext(...)`
  - the main oracle for how resumed messages become transcript rows

### Message-to-chat rendering behavior
- `.references/pi-mono/packages/coding-agent/src/modes/interactive/interactive-mode.ts:2591-2679`
  - `addMessageToChat(...)`
  - the oracle for visible treatment of:
    - user
    - assistant
    - toolResult
    - compactionSummary
    - branchSummary
    - custom display messages

### Model / thinking restoration context
- `.references/pi-mono/packages/coding-agent/src/core/sdk.ts:194-237`
  - session-derived model + thinking restore behavior
- `.references/pi-mono/packages/coding-agent/src/core/sdk.ts:335-338`
  - existing session messages seeded into agent state

The observable target is:
- same resumed transcript semantics
- same ordering
- same pending-tool/result matching behavior
- same failed-tool rendering behavior for aborted/error assistant turns

## Current zi drift

The current lossy boundary lives here:
- `src/tui/ui_event.zig:16-40`
  - `ResumedAssistantBlock`
  - `ResumedEntry`
- `src/tui/ui_event.zig:142-160`
  - `UiEvent.session_resumed`
- `src/tui/interactive.zig:1148-1180`
  - TUI-side resume handler rebuilding transcript from the narrow payload
- `src/tui/interactive.zig:2339-2463`
  - agent-thread resume handler projecting `loaded.messages` into the narrow payload

The session context layer itself is not the primary drift:
- `src/session/context.zig`

The major drift is the cross-thread resume payload and the TUI-side reconstruction path.

## Design decision

For resume transcript reconstruction, zi should **stop inventing a narrower ad-hoc message projection**.

Instead, zi should publish a **fully owned resumed message snapshot** and reconstruct the transcript from that snapshot on the TUI thread.

In other words:

```text
resolved session context
  -> clone full AgentMessage[] into msg_allocator
  -> publish UiEvent.session_resumed(messages, restore_warning)
  -> TUI applies a dedicated session-resume renderer
```

This keeps the boundary explicit without introducing a second lossy message model.

## Why this boundary is the right one

### 1. It respects existing subsystem boundaries
- session logic stays in `src/session/`
- cross-thread ownership stays in the event queue contract
- TUI rendering stays in `src/tui/`
- provider replay remains completely separate

### 2. It uses the durable shared data contract
The resumed transcript should be rebuilt from the same resolved `AgentMessage[]` that the agent uses for the resumed session context.

That means the handoff surface is the authoritative session result, not a second reduced interpretation of it.

### 3. It avoids repeating the current bug class
The current `ResumedEntry` design drift happened because the payload was too narrow.

A full owned `AgentMessage[]` snapshot avoids reopening the same omission class every time a new transcript-visible message surface appears.

## Proposed subsystem split

### A. Session context resolution
**Owner:** session layer / agent thread

Existing responsibility:
- open session file
- build resumed context from the current leaf
- restore model / thinking state
- load agent state

No TUI logic belongs here.

### B. Owned message snapshot
**Owner:** shared data-format / ownership seam

Introduce a shared deep-clone/free facility for resumed messages.

Suggested location:
- `src/agent/message_memory.zig`

Suggested responsibilities:
- `cloneMessage(...)`
- `cloneMessages(...)`
- `freeMessage(...)`
- `freeMessages(...)`

This module should deep-clone every `AgentMessage` variant that can appear in resumed session context, including nested JSON via `json_util.cloneJsonValue`.

This is a data ownership module, not a TUI module.

### C. Session resume renderer
**Owner:** TUI layer

Introduce a dedicated resume renderer module.

Suggested location:
- `src/tui/session_resume_render.zig`

Suggested responsibilities:
- `applySessionMessages(transcript, resolver, messages)`
- `seedEditorHistory(editor, messages)`

This module should encode zi's equivalent of pi-mono's:
- `renderSessionContext(...)`
- `addMessageToChat(...)`

`interactive.zig` should orchestrate, not contain the reconstruction logic.

### D. Interactive orchestration
**Owner:** composition root / request-event wiring

`src/tui/interactive.zig` should only:
- handle `resume_session` on the agent thread
- call the shared message clone helper into `msg_allocator`
- publish `.session_resumed`
- on the TUI thread, clear transcript, call the resume renderer, set status text, scroll

It should not embed message-type-specific reconstruction logic beyond orchestration.

## Thread and allocator ownership

This design must obey `docs/runtime.md`.

### Agent thread owns
- `ca.session_store`
- `ca.agent.state`
- session open/build logic
- model/thinking restoration

### TUI thread owns
- `Transcript`
- transcript items/components
- editor history
- status text and visible UI state

### Cross-thread payload rule
Anything crossing from agent thread to TUI thread must be allocated from `msg_allocator`.

That means:
- the `[]AgentMessage` slice backing storage
- every nested string/slice inside each message
- every nested `std.json.Value`
- any warning text like `restore_warning`

No borrowed slices from session parse arenas, `agent_arena`, or stack locals may cross the queue.

## Session-resumed event shape

Replace the current narrow payload with a full owned message snapshot.

Conceptually:

```zig
session_resumed: struct {
    messages: []agent_protocol.AgentMessage,
    restore_warning: ?[]u8 = null,
}
```

`UiEvent.deinit` should free this payload via the shared `freeMessages(...)` helper.

This is a published snapshot, not a live borrow of agent state.

## Resume renderer behavior

The new resume renderer must mirror pi-mono's visible behavior.

### For assistant messages
1. render the assistant message body
2. preserve text / thinking / tool-call block order
3. for each tool call block:
   - create the tool execution row
   - set arguments
   - mark args complete
4. if the assistant stop reason is `aborted` or `error`:
   - mark each tool execution row as failed using the same user-visible semantics as pi-mono's resumed failed-tool rendering

### For tool results
- route each tool result to the matching pending tool execution row by `tool_call_id`
- clear pending routing state after the full apply pass

### For compaction summaries
- render as first-class transcript content, not inline hardcoded text in `interactive.zig`

### For branch summaries
- render as first-class transcript content

### For custom messages
- respect display semantics
- displayable custom messages should reconstruct visibly
- hidden custom messages should remain non-visible

### For user messages
- repopulate editor history from resumed user messages
- transcript rendering should preserve the same visible behavior as the non-resume path

## Transcript surface guidance

If the transcript currently lacks dedicated entry points for resumed summary/custom surfaces, add them in the TUI layer rather than reintroducing ad-hoc rendering in `interactive.zig`.

Good options:
- transcript convenience methods
- transcript-owned renderables/components
- a dedicated helper module in `src/tui/`

Bad option:
- hand-coded one-off rebuild logic in the `/resume` event handler

## Explicit non-goals

This spec does not include:
- provider replay architecture
- request-body replay transforms
- session-tree algorithm changes beyond parity fixes
- new cross-thread channels
- TUI reads into agent-owned state
- a lossy replacement for `AgentMessage[]`

## Debuggability goals

The design should make these questions easy to answer independently:

1. **Did the session context produce the right messages?**
   - inspect `buildSessionContext(...)`
2. **Did the agent publish the right owned snapshot?**
   - inspect cloned `[]AgentMessage` event payload
3. **Did the TUI apply the messages correctly?**
   - inspect `session_resume_render.zig`

If answering those requires tracing through ad-hoc message reshaping in `interactive.zig`, the design is wrong.

## Testing doctrine for this work

Boundary tests only. No helper test spray.

Recommended tests:

1. **`test "resumed session reconstructs tool call rows and tool results"`**
   - assistant tool calls + later tool results rebuild exactly

2. **`test "resumed session preserves assistant text thinking and tool call ordering"`**
   - mixed assistant block ordering survives resume

3. **`test "resumed aborted assistant renders failed tool rows"`**
   - aborted/error assistant stop reason reconstructs failed tool executions

4. **`test "resumed session includes summaries and displayable custom messages"`**
   - compaction summary, branch summary, and displayable custom messages appear

Prefer real session fixtures derived from pi-mono over hand-written synthetic JSON when practical.

## Acceptance criteria

1. `UiEvent.session_resumed` carries a full owned resumed message snapshot instead of a narrow ad-hoc projection.
2. Resume transcript reconstruction lives in a dedicated TUI module rather than `interactive.zig` ad-hoc logic.
3. The agent thread owns session resolution and publishes only owned `msg_allocator` payloads.
4. The TUI thread owns transcript application and does not read agent-owned session state directly.
5. Resumed transcript behavior matches pi-mono for:
   - assistant text/thinking/tool calls
   - tool results
   - compaction summaries
   - branch summaries
   - displayable custom messages
   - aborted/error tool execution reconstruction
6. The implementation remains explicitly separate from provider replay architecture.

## Design summary

The right system for resume transcript reconstruction is:

- resolve session context once,
- clone the resulting `AgentMessage[]` into an owned cross-thread snapshot,
- apply that snapshot through a dedicated TUI resume renderer that mirrors pi-mono's `renderSessionContext(...)` behavior.

That yields the product outcome we want — a resumed session that looks like zi was never quit — while preserving subsystem boundaries, thread ownership, allocator ownership, and a clear place to test and debug the feature.