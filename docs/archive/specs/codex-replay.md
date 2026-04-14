# Codex replay parity spec

## Status

Draft.

## Problem

When using OpenAI Codex (`openai-codex-responses`), zi's editor-border context counter can:

- accumulate within a turn,
- then reset or collapse on the next prompt,
- especially around tool-use turns and follow-up prompts.

This is a product-level bug, but the likely root cause is **not** in the TUI and **not** in session context math. The remaining drift appears to live in zi's **Codex/OpenAI Responses replay substrate**.

The doctrine for this work is strict:

- **pi-mono is the source of truth**
- we should not invent a new low-level model or policy if pi-mono already solved the replay problem
- fixes must reduce entropy, not add new configuration seams or provider-specific hacks at higher layers

## Core conclusion

The correct direction is to align zi with pi-mono in two specific areas:

### A. Codex event normalization seam

zi must add the equivalent of pi-mono's Codex-specific normalization layer before shared responses processing.

pi-mono has a dedicated Codex path:

- `packages/ai/src/providers/openai-codex-responses.ts`
- `processStream(...)`
- `mapCodexEvents(parseSSE(response))`

This is not accidental. Codex is not treated as just a raw alias of generic responses processing; pi-mono gives it a dedicated normalization seam.

### B. Responses replay conversion seam

zi must align its replay/build-input path with pi-mono's split:

- `transformMessages(...)`
- then `convertResponsesMessages(...)`

pi-mono files:

- `packages/ai/src/providers/transform-messages.ts`
- `packages/ai/src/providers/openai-responses-shared.ts`

zi currently hand-rolls equivalent behavior inside a monolithic writer/converter path in `src/ai/openai_responses_core.zig`. That shape is high-risk because subtle replay drift accumulates there: dropped blocks, wrong ordering, wrong normalization, synthetic tool-result handling drift, etc.

## Why this spec exists

We already found one real Codex drift:

- zi was dropping commentary text for Codex tool-call assistant replay
- pi-mono does not do that
- removing that drift improved behavior, but did not fully fix the bug

That is strong evidence that:

1. the bug is in replay semantics,
2. pi-mono has already hit and solved at least some of these papercuts,
3. the right answer is to copy the **architecture and observable behavior**, not to patch context accounting at a higher layer.

## Non-goals

This spec does **not** permit:

- adding a new model-level context-accounting policy seam
- adding Codex-only heuristics to `getContextUsage()`
- adding TUI-only fixes for the context chip
- masking zero usage in the estimator layer
- inventing a third cross-thread communication pattern

If a proposed fix needs any of the above, it is probably compensating for lower-layer drift rather than removing it.

## Product invariants

For Codex, zi must satisfy these invariants:

1. **Replay parity**
   - The request payload zi sends for Codex follow-up turns must match pi-mono's replay semantics.
   - Same preserved messages.
   - Same dropped messages.
   - Same tool call / tool result normalization.
   - Same synthetic-tool-result behavior.
   - Same treatment of thinking/text/signatures/phases.

2. **Terminal event parity**
   - The final assistant message produced from a Codex stream must be assembled from the same normalized event semantics as pi-mono.
   - Same terminal event selection.
   - Same stop-reason mapping.
   - Same usage extraction point.

3. **Context counter stability**
   - The context chip must not collapse on a new prompt due to replay drift.
   - If the transcript grows monotonically from the user's point of view, the displayed context usage should not reset to zero absent compaction or an actually empty transcript.

4. **No new entropy**
   - No model flags.
   - No provider-specific policy buried in session accounting.
   - No extra TUI branching.

## Architectural requirements

### R1. Preserve layer responsibilities

- **L2 (AI provider substrate)** owns Codex event normalization and replay conversion semantics.
- **L4/L5 (agent/session)** consume final assistant messages and generic session context accounting.
- **L3 (TUI)** remains a dumb consumer of snapshots.

If the UI shows a wrong number because Codex replay is wrong, the fix belongs in L2, not in L3/L5.

### R2. Codex must have an explicit wrapper seam

zi currently routes Codex straight into the generic responses core. This is too collapsed.

The implementation must introduce a Codex-specific seam equivalent in role to pi-mono's:

- parse SSE
- map Codex events into normalized Responses events
- feed normalized events into shared response assembly

The point is not syntax parity. The point is preserving the same **place in the architecture** where Codex-specific normalization happens.

### R3. Replay conversion must be decomposed

zi should not continue to accumulate replay semantics inside one large `writeInputOpts(...)` path.

Instead, match pi-mono's conceptual split:

1. transform message stream
2. convert transformed messages into Responses input items

This makes it possible to reason about parity in two bounded stages:

- transformation rules
- wire conversion rules

### R4. Shared logic stays shared

Only Codex-specific normalization should live in the Codex wrapper seam.

Generic OpenAI Responses logic should remain shared:

- response-item assembly
n- tool-call id normalization helpers when they are truly shared
- usage parsing from `response.completed`
- generic replay serialization once transformed messages are already correct

The implementation should not fork the full responses stack unless pi-mono does.

## Boundary and seam requirements

### Seam A: Codex event normalization

Introduce a seam whose role mirrors pi-mono's `mapCodexEvents(...)`.

#### Responsibilities

- consume raw Codex SSE events
- normalize terminal event types (`response.done`, `response.completed`, `response.incomplete`) into the shape shared processing expects
- preserve `response.usage`, `status`, and terminal semantics exactly as pi-mono does
- terminate processing at the same boundary as pi-mono

#### Must not do

- mutate session/accounting state directly
- reach into TUI state
- add provider policy above stream assembly

### Seam B: transform messages

Introduce or extract a transform stage that mirrors pi-mono's `transformMessages(...)` responsibilities.

#### Responsibilities

- normalize tool call IDs consistently
- update tool-result IDs via the mapping
- preserve or convert thinking blocks exactly as pi-mono does
- drop errored/aborted assistant messages exactly as pi-mono does
- synthesize missing tool results exactly as pi-mono does
- preserve same-model vs cross-model behavior

#### Must not do

- write JSON directly
- mix transformation with transport serialization

### Seam C: convert transformed messages to Responses input

After transform stage, a conversion stage should mirror pi-mono's `convertResponsesMessages(...)`.

#### Responsibilities

- encode assistant text/reasoning/tool calls into Responses API items
- preserve IDs and phases the same way pi-mono does
- preserve tool result ordering and grouping
- respect same-model replay behavior

#### Must not do

- contain Codex-only ad hoc message dropping rules unless present in pi-mono

## Memory ownership requirements

This work touches low-level provider/replay code. It must not weaken ownership discipline.

### M1. No borrowed scratch leakage

Any SSE-parsed slices or temporary JSON-backed strings must not escape their owning scratch lifetime.

If the Codex normalization seam is added:

- parsed event data may borrow scratch only within that seam's processing step
- anything stored into long-lived partial/final assistant state must be duplicated into the correct owning allocator

### M2. Preserve existing allocator lifetimes

- stream-turn allocations remain turn-owned
- persistent transcript data remains owned by the agent history arena
- queue/event payloads crossing threads remain `msg_allocator` owned

No half-migration of ownership is allowed.

### M3. No hidden retained allocations in normalization glue

If a Codex event mapper buffers state, its lifetime must be explicit and bounded to the stream.

## Thread ownership requirements

This spec does not introduce any new cross-thread architecture.

### T1. No new channels

Only existing channels remain valid:

- `request_queue` for TUI -> agent mutations
- `event_queue` for agent -> TUI snapshots/events

### T2. No TUI reads into provider/session internals

Codex replay fixes must not rely on the TUI inspecting agent/provider state.

### T3. Status updates remain snapshot-driven

Any improvement in context-chip stability must come from better provider/session behavior, not from bypassing `status_snapshot`.

## Observable behavior to match from pi-mono

The implementation must be traced against pi-mono for these behaviors:

### Replay/build-input behavior

From:

- `packages/ai/src/providers/transform-messages.ts`
- `packages/ai/src/providers/openai-responses-shared.ts`

Must verify:

- assistant text blocks replayed or skipped
- thinking blocks replayed, converted, or dropped
- tool call id normalization
- tool result id remapping
- synthetic orphan tool result insertion
- same-model vs cross-model replay rules
- errored/aborted assistant filtering

### Codex stream behavior

From:

- `packages/ai/src/providers/openai-codex-responses.ts`
- `packages/ai/test/openai-codex-stream.test.ts`

Must verify:

- SSE parsing boundary behavior
- terminal event normalization
- stop-reason mapping
- usage extraction timing and fields
- behavior when stream stays open after terminal event

## Implementation plan

### Phase 1: Codex event seam extraction

1. Introduce a Codex-specific event-mapping layer in the Zig Codex wrapper.
2. Make shared responses processing consume normalized events, not raw Codex assumptions.
3. Add focused tests against Codex terminal event behavior using pi-mono fixtures/patterns.

### Phase 2: Replay-path decomposition

1. Extract a transform stage from current `openai_responses_core.zig` replay logic.
2. Extract a conversion stage from the remaining wire serializer path.
3. Compare each stage against pi-mono line-by-line for observable behavior.

### Phase 3: Conformance verification

For the same transcript fixture, compare zi vs pi-mono on:

- transformed message sequence
- serialized Responses input payload
- final assistant message after Codex tool-use turn
- resulting session context usage behavior on the next prompt

## Acceptance criteria

1. No new model-level context accounting flags or provider-specific session-accounting policies exist.
2. Codex uses an explicit normalization seam before shared Responses processing.
3. Replay conversion is decomposed into transformation + conversion stages.
4. zi no longer contains Codex-only ad hoc replay drops that pi-mono does not have.
5. The context chip no longer resets to zero on the next prompt in the reproduced Codex scenario.
6. `zig build` passes.
7. Tests added are boundary/conformance oriented, not implementation-spray.

## Testing doctrine for this spec

Prefer:

1. **Conformance tests** from pi-mono event/payload patterns
2. **Boundary tests** for replay input -> final assistant -> context usage

Avoid:

- per-helper unit-test spray
- mocks above the network/transport boundary
- tests that pin a zi-only workaround

## Rationale

pi-mono likely already hit these Codex papercuts:

- odd terminal event behavior
- sessionful replay quirks
- tool-call id normalization
- orphan tool results
- same-model replay subtleties

The right move is to benefit from that prior work by aligning our seams and behavior, not by inventing new low-level policy knobs.

This spec therefore prefers:

- **copy the architecture where it matters**
- **port the observable behavior exactly**
- **keep thread and ownership boundaries clean**
- **reduce entropy rather than adding compensating configuration**
