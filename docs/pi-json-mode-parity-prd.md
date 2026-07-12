# PRD: strict Pi parity for JSON event stream mode

- Status: ready for implementation
- Date: 2026-07-12
- Product owner: print frontend
- Primary implementation owners: `src/agent`, `src/coding_agent/AgentSession.zig`, `src/frontends/print/print_mode.zig`
- Behavioral authority: `.references/pi` at commit `81de5702c6816538ea97d05d9060fe435b80bf35`
- Refactor policy: nuclear; breaking internal APIs and high churn are allowed; compatibility layers are forbidden

## 1. Purpose

Zi advertises `--mode json` as a JSON-lines event stream. Its current implementation serializes the generic `agent.AgentEvent` stream directly from `session.agent`. That produces valid JSON lines, but it does not match the product behavior of the local Pi reference:

- it omits the session header;
- several base agent events omit Pi payload fields;
- tool-result message lifecycle ordering differs;
- session-owned retry, compaction, and final-settlement facts are absent;
- JSON mode observes `agent.Agent` rather than the complete `AgentSession` behavior;
- bounded transport copies currently alter event payload semantics before JSON serialization;
- tests assert substrings rather than the Pi event contract.

This work makes Zi's JSON mode match Pi strictly at the behavior and product level for every behavior Zi supports.

This is not an opportunity to design a better protocol. Pi's behavior is the specification.

## 2. Non-negotiable product rule

For a scenario supported by both products:

> Given equivalent session state, prompt, model responses, tool results, retry settings, and compaction settings, Zi emits the same JSON record kinds, field names, field meanings, and event order as the pinned Pi reference.

Allowed implementation differences are invisible mechanism differences only: Zig types, allocation strategy, bounded pipes, task runtime, persistence implementation, and ownership layout.

When Pi behavior is unclear, implementation stops until a focused characterization test against `.references/pi` establishes the answer. The implementer must not fill ambiguity with a Zi-specific design.

## 3. Behavioral sources of truth

Use these sources in descending order:

1. `.references/pi/packages/coding-agent/src/modes/print-mode.ts`
2. `.references/pi/packages/coding-agent/src/core/agent-session.ts`
3. `.references/pi/packages/agent/src/types.ts`
4. `.references/pi/packages/agent/src/agent-loop.ts`
5. `.references/pi/packages/coding-agent/docs/json.md`
6. Pi tests, especially:
   - `packages/coding-agent/test/print-mode.test.ts`
   - `packages/coding-agent/test/suite/agent-session-retry-events.test.ts`
   - `packages/coding-agent/test/suite/agent-session-compaction.test.ts`
   - `packages/coding-agent/test/suite/regressions/6363-agent-settled-event.test.ts`

Source and tests override prose documentation if they disagree. Record every discovered disagreement in the implementation PR and follow source/test behavior.

Do not follow Pi's internal layering, dependency choices, extension framework, tree-session model, or JavaScript implementation. Only shared user-observable JSON behavior is authoritative.

## 4. Nuclear refactor policy

This work may replace internal APIs outright. It is acceptable to change every caller of an affected type in one patch series.

Required policy:

- No deprecated declarations.
- No old/new event variants living side by side.
- No aliases for renamed fields or event types.
- No compatibility serializers.
- No adapters that translate a legacy Zi event shape into the Pi shape.
- No feature flags selecting old versus new JSON behavior.
- No duplicate subscription APIs kept “for now.”
- No frontend-local mirror event model.
- No generic client protocol, wire protocol, ViewModel, Engine, or event translation tier.
- No stale tests pinning the pre-refactor behavior.
- No commented-out old implementation.

When `AgentEvent` changes, update all producers and consumers directly. When `AgentSession` becomes the owner of session-level subscription, move callers to the final API and delete superseded paths.

High source churn is acceptable. Behavioral drift is not.

## 5. Explicit non-goals

This PRD does not add or redesign:

- RPC mode;
- an independently versioned Zi JSON protocol;
- `run_start`, `run_end`, or any other Zi-invented event;
- a reduced or normalized public event vocabulary;
- batching, envelopes, acknowledgements, request ids, or commands over stdin;
- alternate field names, aliases, or convenience summaries;
- a frontend projection of `AgentSessionEvent`;
- Pi extensions, branching, tree navigation, session naming, custom entries, or other Pi-only product features;
- producer-side pacing or UI-oriented throttling;
- a new dependency.

Do not add a JSON line-size policy, redaction policy, schema version, or truncation behavior that Pi does not have. Existing Zi input, tool-output, session, and runtime bounds remain mandatory mechanism constraints, but they must not silently change the meaning of an emitted event.

## 6. Pi JSON stream contract

### 6.1 Framing

JSON mode writes UTF-8 NDJSON to stdout:

- one complete JSON object per line;
- each object ends with `\n`;
- no human-readable text is written to stdout;
- records are flushed in event order;
- stderr remains for process diagnostics and errors, matching Pi;
- no array wrapper or terminal summary is added.

### 6.2 First record

Before subscribing and before submitting the initial prompt, Pi writes the current session header when one exists:

```json
{"type":"session","version":3,"id":"uuid","timestamp":"...","cwd":"/path"}
```

Optional Pi field:

```json
{"parentSession":"..."}
```

Zi must expose and serialize its existing session header with the exact Pi field names:

- `type`
- `version`
- `id`
- `timestamp`
- `cwd`
- `parentSession`, only when present

The implementation must characterize Pi's no-session/in-memory behavior before deciding whether Zi's explicit `--no-session` mode emits a header. It must not infer the answer from Zi's nullable persistence internals.

### 6.3 Base agent events

The final `agent.AgentEvent` shape must match Pi for shared message types:

```text
agent_start
  { type }

agent_end
  { type, messages }

turn_start
  { type }

turn_end
  { type, message, toolResults }

message_start
  { type, message }

message_update
  { type, message, assistantMessageEvent }

message_end
  { type, message }

tool_execution_start
  { type, toolCallId, toolName, args }

tool_execution_update
  { type, toolCallId, toolName, args, partialResult }

tool_execution_end
  { type, toolCallId, toolName, result, isError }
```

Required corrections to the current Zi shape include:

- `agent_end.messages`;
- `turn_end.message`;
- `turn_end.toolResults`;
- `message_update.message`.

These payloads are part of the core event, not JSON-frontend decoration.

### 6.4 Session events

Pi's `AgentSessionEvent` is the base agent stream plus session-owned policy facts. Zi must expose the same event names and fields whenever the equivalent Zi behavior exists:

```text
agent_end
  { type, messages, willRetry }

agent_settled
  { type }

queue_update
  { type, steering, followUp }

compaction_start
  { type, reason }

compaction_end
  { type, reason, result?, aborted, willRetry, errorMessage? }

auto_retry_start
  { type, attempt, maxAttempts, delayMs, errorMessage }

auto_retry_end
  { type, success, attempt, finalError? }
```

Pi also defines:

```text
entry_appended
session_info_changed
thinking_level_changed
```

Zi must emit these only where Zi already has equivalent product behavior. This PRD does not authorize adding Pi-only custom entries, session naming, extensions, or interactive mutation to print mode merely to exercise those records. If a shared Zi state transition exists, use Pi's event name and shape; otherwise leave the unsupported feature absent.

### 6.5 Compaction result

On successful compaction, `compaction_end.result` matches Pi's `CompactionResult`:

```text
summary: string
firstKeptEntryId: string
tokensBefore: number
estimatedTokensAfter?: number
details?: unknown
```

Zi has no extension-provided compaction details today. Omit `details`; do not emit `null` or synthesize an empty object.

If Zi can calculate `estimatedTokensAfter` with the same meaning as Pi, emit it. If not, first characterize whether omission is accepted by Pi's own shape and tests; the field is optional in Pi. Do not substitute a differently defined estimate.

Reasons are exactly:

```text
manual
threshold
overflow
```

Boolean and optional-field semantics must match Pi:

- success: `result` present, `aborted: false`;
- cancellation: `result` absent, `aborted: true`, error omitted when Pi omits it;
- failure: `result` absent, `aborted: false`, `errorMessage` present when Pi provides it;
- `willRetry` describes whether compaction success proceeds into automatic resubmission.

## 7. Required event ordering

Ordering is product behavior. Tests must pin exact order after coalescing only repeated `message_update` records for readability.

### 7.1 One successful prompt

```text
session
agent_start
turn_start
message_start:user
message_end:user
message_start:assistant
message_update...
message_end:assistant
turn_end
agent_end
agent_settled
```

`agent_end` includes the run's `messages` and `willRetry: false` at the session-event seam.

### 7.2 Tool call followed by final answer

```text
session
agent_start
turn_start
message_start:user
message_end:user
message_start:assistant
message_update...
message_end:assistant
tool_execution_start
[tool_execution_update...]
tool_execution_end
message_start:toolResult
message_end:toolResult
turn_end
turn_start
message_start:assistant
message_update...
message_end:assistant
turn_end
agent_end
agent_settled
```

Zi currently omits `message_start:toolResult`; this must be corrected at the producer.

### 7.3 Retry that succeeds

The exact fixture must be generated from the pinned Pi reference. At minimum it must prove:

- the failed attempt emits `agent_end` with `willRetry: true`;
- `auto_retry_start` carries Pi's attempt numbering, configured maximum, delay, and source error text;
- the next attempt has its own `agent_start`/`agent_end` lifecycle;
- successful recovery emits one `auto_retry_end` with `success: true` and the final attempt count;
- one `agent_settled` terminates the complete logical operation;
- no additional Zi-only retry records appear.

### 7.4 Retry exhaustion

The exact fixture must prove:

- attempts are numbered like Pi;
- each retrying `agent_end` has `willRetry: true`;
- the final `agent_end` has `willRetry: false`;
- `auto_retry_end` has `success: false`, the final attempt, and Pi-compatible `finalError` behavior;
- `agent_settled` is last.

### 7.5 Overflow compaction and resubmission

The exact fixture must prove:

- failed agent attempt lifecycle;
- `agent_end.willRetry` follows Pi's compaction/retry meaning;
- `compaction_start` reason is `overflow`;
- `compaction_end` carries the Pi result shape and `willRetry: true` on successful recovery;
- resubmitted prompt lifecycle follows Pi;
- `agent_settled` occurs once after all recovery work.

### 7.6 Threshold compaction

The exact fixture must prove Pi ordering relative to the successful agent attempt and final settlement. Do not assume ordering from Zi's current post-success maintenance flow; characterize Pi and match it.

## 8. Ownership and implementation shape

### 8.1 `agent.Agent`

`agent.Agent` remains the product-agnostic owner of provider/tool turn mechanics.

It must emit complete Pi-shaped base `AgentEvent`s. The loop already knows the necessary facts:

- current partial message for `message_update.message`;
- assistant message and tool-result batch for `turn_end`;
- messages produced by the run for `agent_end`.

Do not reconstruct these later in a frontend.

### 8.2 `AgentSession`

`AgentSession` owns retry, compaction, persistence, queues, and final operation settlement. Therefore it owns direct publication of Pi-shaped session events.

The final session subscription interface must be small and concrete. It may expose a typed `AgentSessionEvent` union and bounded listener slots, but it must not become a generic event bus or protocol framework.

Required dataflow:

```text
agent loop
  -> complete AgentEvent
  -> AgentSession applies persistence/session policy
  -> AgentSession directly notifies typed subscribers
  -> concrete frontend consumes the borrowed event during that call
```

There is no envelope, sequence number, registry, ViewModel, queue mirror, or conversion into a frontend protocol.

`AgentSession` may enrich `agent_end` with `willRetry` only at the point where the decision is known. It must preserve Pi-observable ordering. If this requires changing when settlement policy is evaluated, change the owner API rather than buffering an unbounded event or adding a compatibility path.

### 8.3 TUI

The TUI remains a direct consumer of `agent.AgentEvent` for its bounded `Transcript` fold unless the nuclear refactor proves one direct `AgentSessionEvent` subscription is simpler and preserves all gen-3 invariants.

Do not force session-policy records through `Transcript`. `Loop` already owns retry, compaction, queue, and foreground status. It may consume direct typed session facts where useful, but must not mirror them into another model.

### 8.4 Print frontend

`src/frontends/print/print_mode.zig` must:

1. emit the session header before prompt submission;
2. subscribe to `AgentSession`, not `session.agent`;
3. serialize each borrowed `AgentSessionEvent` directly;
4. preserve synchronous record ordering;
5. continue driving one `RunHandle` through retry and compaction policy;
6. emit no frontend-invented events.

Text mode remains final-answer output and must not accidentally begin emitting JSON session events.

## 9. Boundedness and lifetimes

Strict Pi behavior does not waive Zi's bounded-work rules.

- Listener count is fixed-capacity with reject-on-full policy.
- Subscriber calls are synchronous; events are borrowed for the duration of the call.
- A subscriber that retains an event must copy it explicitly.
- JSON mode writes one event directly to its supplied writer and backpressures on that write; it does not queue output.
- Runtime event pipes retain their fixed capacity and backpressure/failure policy.
- Every message, tool argument, tool result, image, details object, and session line remains subject to its existing owning input/output cap.
- No additional full transcript copy is retained solely for JSON mode.
- `agent_end.messages` means messages produced by that run, matching Pi, not the full durable session transcript. The producer must own or borrow this slice safely through synchronous dispatch.
- `turn_end.toolResults` is the current turn's result slice, matching Pi.

The current compact event-copy path alters semantic payloads by emptying partial content and truncating selected tool arguments. That path may remain only if the resulting event is still semantically identical to Pi for every public field. Otherwise replace it. Do not add a second “full JSON” event pipeline beside a compact TUI pipeline.

## 10. JSON encoding rules

Wire names match Pi exactly, including camelCase:

- `assistantMessageEvent`
- `toolCallId`
- `toolName`
- `partialResult`
- `isError`
- `toolResults`
- `willRetry`
- `followUp`
- `maxAttempts`
- `delayMs`
- `errorMessage`
- `finalError`
- `firstKeptEntryId`
- `tokensBefore`
- `estimatedTokensAfter`
- `parentSession`

Optional fields are omitted when absent, as Pi's `JSON.stringify` does. Do not encode absent optional fields as `null` unless Pi emits `null` for that field.

Message roles, content tags, stop reasons, operational failure values, usage fields, tool call tags, and assistant stream event tags remain pinned to Pi casing already represented by Zi's custom `jsonStringify` methods.

Add compile-time or exhaustive-switch pressure so a new event cannot compile without an explicit JSON encoding decision.

## 11. Exit and stderr semantics

Match Pi's `runPrintMode` behavior, including its asymmetry between text and JSON mode.

- Text mode inspects the final assistant message and returns non-zero for `error` or `aborted`.
- JSON mode emits the event stream and does not independently convert an assistant error event into process failure.
- A thrown/operational failure of running print mode itself writes a diagnostic to stderr and exits non-zero.
- JSON stdout remains parseable NDJSON even when stderr contains diagnostics.

Zi currently returns `PromptFailed` for a final failed verdict in both text and JSON modes. Change this if characterization of the pinned Pi source confirms the JSON-mode difference. Pin the result with a front-door CLI test.

Do not add a JSON terminal error object. Pi communicates assistant failures through its existing message/session events.

## 12. Unsupported Pi features

Strict parity applies to shared behavior, not Pi's entire feature inventory.

The following remain out of scope unless already present in Zi:

- extension custom entries and `entry_appended` arising from them;
- session names and `session_info_changed`;
- branch and tree events;
- extension-provided custom messages and compaction details;
- project trust events;
- package or model-registry extension events.

Tests and docs must clearly distinguish “unsupported feature, therefore no event” from “supported behavior with a mismatched event.”

## 13. Implementation phases

### Phase 0: executable Pi characterization

Before changing Zi behavior:

1. Record the pinned Pi commit in fixture metadata.
2. Produce normalized Pi fixtures for:
   - simple text response;
   - thinking plus text streaming;
   - one tool call plus final answer;
   - operational error without retry;
   - retry success;
   - retry exhaustion;
   - overflow compaction and resubmission;
   - threshold compaction;
   - cancellation where practical;
   - fresh, resumed, and no-session header behavior.
3. Record exact event order and exact object keys.
4. Record JSON-mode exit status and stderr for success and assistant failure.

Fixtures may normalize nondeterministic values only:

- session id;
- timestamps;
- cwd;
- provider response ids;
- durations or generated temp paths.

They must not normalize event types, field presence, booleans, attempt numbers, reasons, message roles, content, or ordering.

### Phase 1: replace incomplete base events

Change `agent.AgentEvent` to the final Pi shape and update every producer, copy/deinit function, state fold, TUI consumer, test, and JSON encoder.

Delete the old payloadless `turn_end` and `agent_end` forms. Do not retain constructors or aliases for them.

Correct tool-result lifecycle to emit both `message_start` and `message_end`.

### Phase 2: make `AgentSession` the session event owner

Add the final direct typed subscription path and emit supported Pi session events from the policy decisions that own them.

Move print JSON subscription from `session.agent` to `AgentSession`.

Delete any superseded public event queue, callback, or helper rather than adapting it.

### Phase 3: header and print semantics

Emit the Pi-shaped session header before subscription/prompt execution.

Align JSON-mode stderr and exit behavior with Pi. Keep text behavior unchanged except where the refactor requires direct correction to Pi parity.

### Phase 4: parity fixtures and docs

Replace substring tests with parsed record assertions and exact normalized fixtures. Update website JSON documentation with Pi-compatible event shapes and examples. Do not describe guarantees Pi does not provide.

## 14. Test plan

### 14.1 Unit tests

`src/agent`:

- every base event serializes with exact Pi keys;
- `message_update.message` tracks the current partial;
- `turn_end` carries the final assistant message and current tool results;
- `agent_end.messages` contains only messages produced by that run;
- tool results emit start then end;
- copy/deinit paths cover every payload and remain leak-free;
- event-pipe copies preserve public semantics.

`AgentSession`:

- session subscriber sees base and policy events in exact order;
- `agent_end.willRetry` is correct for success, retry, exhaustion, overflow recovery, and cancellation;
- retry start/end fields match Pi attempt semantics;
- compaction start/end fields match Pi success, failure, and cancellation semantics;
- `agent_settled` occurs exactly once after the complete operation;
- queues emit complete `queue_update` snapshots when equivalent queue mutations occur;
- listener capacity rejects overflow deterministically.

Print frontend:

- header is the first JSON record;
- every line parses independently as one JSON object;
- no text contaminates stdout;
- writer failure stops the run safely and drains owned work;
- text mode remains plain text;
- JSON assistant failure exit semantics match Pi.

### 14.2 Exact event-order fixtures

Add table-driven fixtures for every scenario in §13 Phase 0. Compare:

- number of records;
- record type order;
- exact key sets per record;
- field values after narrow nondeterministic normalization;
- stdout framing;
- stderr;
- process exit status.

Do not use substring presence as the primary oracle.

### 14.3 Front-door tests

Use `ZI_ENABLE_FAUX_PROVIDER=1` and normal CLI/provider resolution.

At minimum:

```sh
zi --mode json "hi"
zi --mode json --continue "hi"
zi --mode json --no-session "hi"
```

Add scripted faux scenarios for tool calls, retries, compaction, and failures. If the faux provider cannot express a required Pi scenario, deepen it with bounded scripted behavior rather than injecting private callbacks around `RuntimeServices`.

### 14.4 Differential review

For each fixture, retain:

- pinned Pi normalized output;
- Zi normalized output;
- a test or script that compares them.

The comparison tooling is test-only. It must not become a runtime compatibility layer or production dependency.

## 15. Documentation requirements

Update:

- `website/docs/man/10-cli.md`
- `website/docs/man/18-frontends.md`
- add or expand a focused JSON event stream reference under `website/docs/man/`

Documentation must state:

- first line is the session header when available;
- subsequent lines are Pi-compatible `AgentSessionEvent`s;
- exact event and payload inventory for supported Zi behavior;
- retries and compaction produce multiple agent lifecycles inside one settled operation;
- `agent_settled` marks completion of session policy for the prompt;
- JSON mode stderr and exit behavior;
- unsupported Pi-only event sources.

Do not call the format a newly versioned Zi protocol. The session header's `version` is the session format version, matching Pi; it is not a new event-schema version.

## 16. Acceptance criteria

This PRD is complete only when all of the following are true:

- [ ] `.references/pi` commit `81de5702c6816538ea97d05d9060fe435b80bf35` is recorded in fixture metadata.
- [ ] JSON stdout begins with the Pi-shaped session header whenever the characterized Pi behavior does.
- [ ] Base `AgentEvent` payloads match Pi for all shared events.
- [ ] Tool-result messages emit `message_start` followed by `message_end`.
- [ ] JSON mode subscribes to the complete `AgentSession` event stream.
- [ ] `agent_end` includes `messages` and Pi-compatible `willRetry`.
- [ ] `turn_end` includes `message` and `toolResults`.
- [ ] `message_update` includes both `message` and `assistantMessageEvent`.
- [ ] Retry start/end events match Pi names, fields, attempt semantics, and order.
- [ ] Compaction start/end events match Pi names, fields, reason semantics, and order.
- [ ] `agent_settled` appears exactly once at the Pi-equivalent settlement point.
- [ ] Tool args, partial messages, and results visible in JSON have Pi-equivalent semantics rather than transport-preview semantics.
- [ ] Every output line is independently valid JSON followed by LF.
- [ ] JSON-mode exit status and stderr match characterized Pi behavior.
- [ ] Exact normalized fixtures cover success, tools, failure, retry, compaction, resume, and no-session behavior.
- [ ] No new event names or fields were invented.
- [ ] No compatibility layer, shim, alias, deprecated API, duplicate serializer, or old event path remains.
- [ ] No Engine, ViewModel, client protocol, generic event bus, or frontend projection was introduced.
- [ ] Existing TUI, persistence, retry, compaction, and print-text behavior remains correct.

## 17. Mechanical deletion checks

Adapt these expressions to final naming, but preserve their intent:

```sh
# JSON must not subscribe below AgentSession.
! rg 'session\.agent\.subscribe|agent\.subscribe' src/frontends/print

# No legacy payloadless terminal event construction remains.
! rg 'emit(?:Event)?\(\.turn_end\)|emit(?:Event)?\(\.agent_end\)' src/agent src/coding_agent

# No compatibility vocabulary.
! rg 'Legacy|Compat|Deprecated|old_event|new_event|json_v2' src/agent src/coding_agent src/frontends/print

# No forbidden architecture tiers.
! rg 'client_protocol|view_model|engine_drain|wire_protocol' src
```

The first expression does not prohibit direct agent subscriptions in the TUI transcript path. It prohibits JSON mode from bypassing `AgentSession` policy.

## 18. Quality gates

Run:

```sh
zig build test
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
git diff --check
```

Also run the focused differential fixture suite and front-door JSON scenarios three times if any timing-sensitive retry or cancellation test is involved.

The final PR description must include:

- pinned Pi commit;
- event matrix before and after;
- exact fixtures added;
- any intentional unsupported Pi event source and why it is out of scope;
- JSON success/failure exit-status evidence;
- proof that every removed API has no surviving callers;
- every gate run and any gate omitted.

## 19. Review rubric

Reject the implementation if any answer is “yes”:

1. Did it invent an event, field, envelope, or terminal summary absent from Pi?
2. Did it preserve the old Zi event API through an alias or adapter?
3. Does JSON mode still observe `session.agent` directly?
4. Does a frontend reconstruct facts already known by `agent.Agent` or `AgentSession`?
5. Are retry or compaction transitions inferred from neighboring events instead of emitted by their owner?
6. Does any public JSON field contain a bounded preview while appearing to be Pi's authoritative value?
7. Is ordering tested only through substring presence?
8. Did the refactor add a protocol tier, event bus, mirror model, or unbounded queue?
9. Did it copy Pi's architecture rather than only its behavior?
10. Did it retain dead code to reduce migration churn?

The desired result is a destructive simplification: one complete base event shape, one complete session-policy event path, and one JSON frontend that writes those facts exactly as Pi does.
