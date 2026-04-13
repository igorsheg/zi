# Replay architecture spec

## Status

Draft.

## Why this spec exists

We fixed a real Codex replay bug where zi serialized a replayed assistant message with an invalid `phase` value because a slice borrowed from a temporary JSON parse arena escaped into later request serialization.

That bug was not a threading violation. It was an ownership/modeling failure in the replay substrate.

The current replay path is too easy to get wrong because it still mixes:

1. streaming partial UI state,
2. persisted final assistant state,
3. replay transformation policy,
4. wire-format encoding.

This spec defines the architecture zi should move to so replay is a modeled core system, not a recurring source of incidental bugs.

This is a cross-provider spec. Replay is a core part of zi, not an OpenAI/Codex-only concern.

However, sequencing matters:

- **first** close strict pi-mono parity on the actively broken OpenAI Responses / Codex path,
- **then** consolidate replay into the staged architecture described here,
- **then** roll the same ownership/modeling rules across other providers with meaningful replay complexity.

## Source of truth

pi-mono remains the oracle for observable behavior.

This spec is about improving zi's internal architecture while preserving pi-mono parity for:

- provider stream normalization,
- final assistant assembly,
- replay transformation,
- replay input serialization.

The first concrete rollout target is OpenAI Responses / Codex because that path is currently the most replay-sensitive and has already produced real follow-up failures.

If the implementation architecture changes but observable behavior drifts from pi-mono, the implementation is wrong.

## Non-goals

This spec does not allow:

- new model flags,
- new context-accounting modes,
- TUI-side fixes for replay/accounting bugs,
- new cross-thread communication paths,
- provider-specific replay policy outside the provider/replay substrate.

## Core conclusion

Replay must be modeled as a staged, owned pipeline.

The architecture should separate four concerns explicitly:

1. transport,
2. provider event normalization,
3. final assistant assembly,
4. replay transformation + replay encoding.

The critical design rule is:

> Deltas are for UI. Final item payloads are for persistence and replay.

## Product invariants

1. **Replay state is final-state only**
   - persisted assistant replay metadata must come from final provider item payloads, not provisional streamed state.

2. **Replay data is owned**
   - no replay field may borrow from parse scratch, SSE buffers, temporary JSON trees, or stack-local builders.

3. **Provider-specific behavior has explicit seams**
   - provider quirks live in provider normalization / provider request encoding seams, not in session accounting or TUI logic.

4. **Transformation and encoding are distinct**
   - message replay policy is decided before wire serialization begins.

5. **pi-mono remains the oracle**
   - same kept/dropped messages, same replayed reasoning/text/tool-call semantics, same ordering, same terminal behavior.

## Scope and rollout

Replay architecture is a global concern, but rollout should be staged.

### Global rule

Every provider with replay semantics must eventually follow the same model:

- explicit normalization seam,
- final-state assembly,
- replay transform,
- replay encode,
- owned replay data with no scratch leakage.

### Rollout order

1. **OpenAI Responses / Codex**
   - highest priority because it is actively broken and pi-mono already provides the target seams.
2. **Other providers with complex replay semantics**
   - Anthropic
   - OpenAI Completions / compat paths
   - Google / Bedrock where replay metadata and thought/tool signatures matter
3. **Providers with simpler replay surfaces**
   - adopt the ownership and transform/encode split only as needed by their product surface

### Sequencing rule

This spec does **not** authorize inventing a new replay architecture before parity is complete on the currently broken path.

The immediate execution order is:

1. finish strict pi-mono parity for OpenAI Responses / Codex replay + assembly,
2. add conformance diffs/fixtures,
3. then land the modeled replay architecture here,
4. then roll the same structure across other providers.

## Architectural split

### Stage A. Transport

**Responsibility:**
- HTTP request/response
- SSE or websocket byte transport
- status/error envelope handling

**Must not do:**
- Codex-specific semantic normalization
- assistant replay policy
- transcript transformation

**Suggested file shape:**
- `src/ai/openai_responses_transport.zig`

### Stage B. Provider event normalization

**Responsibility:**
- convert raw provider events into a shared normalized Responses event vocabulary
- Codex-specific normalization lives here
- normalize terminal boundaries and terminal event semantics

**Must not do:**
- mutate session/accounting state
- build replay payloads
- embed TUI/UI concerns

**Suggested file shape:**
- `src/ai/openai_responses_events.zig`
- `src/ai/openai_codex_events.zig`

### Stage C. Final assistant assembly

**Responsibility:**
- consume normalized Responses events
- emit UI deltas during stream
- construct final assistant message for persistence
- preserve replay metadata from final `output_item.done` payloads

**Critical rule:**
- provisional item state may drive UI deltas
- only final item payloads may define persisted replay state

**Must not do:**
- serialize next-turn replay input
- decide cross-model replay policy

**Suggested file shape:**
- `src/ai/openai_responses_assembly.zig`

### Stage D. Replay transformation

**Responsibility:**
- transform transcript messages into replay-safe messages
- normalize tool call IDs
- remap tool result IDs
- drop errored/aborted assistant messages
- synthesize missing tool results
- preserve same-model vs cross-model behavior

**Must not do:**
- write JSON
- emit provider-specific transport objects directly

**Suggested file shape:**
- `src/ai/openai_responses_replay_transform.zig`

### Stage E. Replay encoding

**Responsibility:**
- convert replay-safe messages into Responses API input items
- emit exact wire shape expected by OpenAI/Codex Responses
- preserve ordering and ids exactly

**Must not do:**
- re-decide replay policy already settled in transform stage
- read from borrowed scratch

**Suggested file shape:**
- `src/ai/openai_responses_replay_encode.zig`

## Replay IR

zi should introduce a dedicated replay IR between transformation and encoding.

The IR exists to make illegal states unrepresentable and to encode ownership clearly.

### Desired properties

- every string is owned by the replay allocator,
- every JSON blob that must round-trip is explicitly owned,
- phase/id/tool-call identity is typed, not hidden in ad hoc strings,
- replay encoding reads from this IR only.

### Suggested shape

#### `ReplayMessage`
- `.user`
- `.assistant`
- `.tool_result`

#### `ReplayAssistantBlock`
- `.reasoning`
- `.text`
- `.function_call`

#### `ReplayReasoning`
- `raw_item_json: []const u8`
- represents the exact reasoning item to replay verbatim

#### `ReplayText`
- `text: []const u8`
- `meta: ReplayTextMeta`

#### `ReplayTextMeta`
- `id: []const u8`
- `phase: ?ReplayPhase`

#### `ReplayPhase`
- `.commentary`
- `.final_answer`
- optionally `.other: []const u8` if forward-compat preservation is required

#### `ReplayFunctionCall`
- `call_id: []const u8`
- `item_id: ?[]const u8`
- `name: []const u8`
- `arguments: std.json.Value` or owned JSON string, chosen consistently

#### `ReplayToolResult`
- `call_id: []const u8`
- `content: ...`

## Ownership doctrine for replay

Replay must follow explicit ownership boundaries.

### O1. No borrowed scratch escapes

Anything derived from:
- SSE parser buffers,
- `std.json.parseFromSlice` temporary allocators,
- stack-local formatting buffers,
- per-delta scratch arenas,

must be duplicated before entering:
- final assistant persisted state,
- replay IR,
- cross-function structures that outlive the parse step.

### O2. Constructors return owned state

Helpers that parse metadata must return owned values, not borrowed slices.

Examples of the intended rule:
- `parseTextSignatureOwned(...)`
- `buildReplayReasoningOwned(...)`
- `finalizeFunctionCallOwned(...)`

### O3. Replay IR is the ownership boundary

Once data enters replay IR, later stages must not need to parse temporary external state again.

### O4. JSON round-trip fields are explicit

If a provider item must be replayed byte-for-byte or semantically unchanged, store it explicitly as owned replay data.

Do not hide round-trip-critical data inside incidental text buffers or transient signatures.

## Partial state vs final state

The architecture must distinguish these two models explicitly.

### Partial render state

Used for:
- `text_delta`
- `thinking_delta`
- `toolcall_delta`
- live transcript rendering

Allowed sources:
- incremental deltas
- provisional item metadata

### Final persisted state

Used for:
- final assistant message persistence
- subsequent turn replay
- session serialization

Allowed sources:
- final `response.output_item.done` payloads
- final terminal response payload

### Hard rule

Partial state may never be persisted directly unless the provider contract explicitly makes it final.

## Provider seam rule

Provider-specific logic must remain confined to explicit normalization and request-shape seams.

No provider may introduce replay-policy drift in:
- session accounting,
- agent state management,
- TUI rendering,
- transcript persistence semantics.

The first concrete target remains Codex / OpenAI Responses, where provider-specific responsibilities include:
- transport/header quirks,
- request-body quirks specific to Codex,
- terminal event normalization into shared Responses semantics.

Other providers should follow the same rule:
- provider quirks live in provider seams,
- replay policy lives in replay transform / replay encode,
- UI and session layers stay generic.

## Testing doctrine for replay architecture

Tests must sit at behavior/conformance boundaries, not helper granularity.

### Priority tests

#### First rollout target: OpenAI Responses / Codex

1. **Codex terminal normalization conformance**
   - `response.done` / `response.completed` / `response.incomplete`
   - same terminal behavior as pi-mono

2. **Responses replay payload conformance**
   - real transcript fixture
   - compare serialized `input` payload against pi-mono

3. **Tool-call turn followed by follow-up prompt**
   - exact shape that historically produced follow-up 400s

4. **Same-provider different-model handoff**
   - reasoning + tool-call replay parity

5. **Orphan tool-call replay**
   - synthetic tool result parity

#### Follow-on provider rollout

For other providers, add conformance tests only where the provider has real replay semantics worth preserving:

- preserved reasoning/thought signatures,
- provider-specific tool-call identity normalization,
- cross-model replay behavior,
- provider-specific final-state assembly quirks.

### Explicitly avoid

- per-helper unit test spray
- tests for private implementation mechanics
- tests that pin zi-only workarounds

## Migration plan

### Phase 0. Finish strict parity on the broken path

- complete strict pi-mono parity for OpenAI Responses / Codex replay + assembly
- diff real follow-up payloads against pi-mono
- close known request/replay drift before broader architectural movement

### Phase 1. Extract stage boundaries

- split transport from normalization
- split assembly from replay
- keep behavior unchanged

### Phase 2. Introduce replay IR

- transform transcript messages into owned replay IR
- stop feeding raw transcript messages directly into wire encoding

### Phase 3. Make final-state assembly authoritative

- ensure persisted replay metadata comes only from final item payloads
- deltas remain UI-only

### Phase 4. Add conformance fixtures

- compare zi and pi-mono replay payloads on real multi-turn transcripts
- especially OpenAI Responses / Codex tool-use follow-up turns

### Phase 5. Roll the same replay model across other providers

- apply the same ownership and transform/encode rules provider by provider
- only where the provider has replay complexity that justifies the seam

### Phase 6. Delete obsolete monolithic seams

- remove remaining monolithic replay/writer paths once the staged pipeline is fully authoritative

## Acceptance criteria

1. Replay transformation and replay encoding are separate modules.
2. Replay uses a dedicated owned IR.
3. Persisted replay metadata comes from final provider item payloads, not provisional deltas.
4. No replay field borrows from temporary parse scratch.
5. Provider-specific behavior is confined to explicit normalization/request seams.
6. Conformance tests exist for follow-up turns that previously produced OpenAI Responses / Codex 400s.
7. The replay architecture is defined as a global subsystem, with staged provider rollout rather than Codex-only treatment.
8. `zig build` passes after each migration phase.

## Design summary

The replay system should be treated as a first-class core subsystem.

The correct model is not “serialize whatever the stream happened to accumulate.”
The correct model is:

- normalize provider events,
- assemble final assistant state,
- transform transcript into owned replay IR,
- encode replay IR into exact provider wire input.

That architecture keeps pi-mono parity while making lifetime and replay correctness structurally easier to maintain across the providers that need replay, without prematurely inventing a new system before parity is complete.
