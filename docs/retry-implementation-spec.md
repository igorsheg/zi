# Retry implementation specification

Status: implemented for agent turns and manual/automatic compaction

This document maps Pi's retry behavior to OpenZi's current owners. It distinguishes visible coding-agent retries from provider/SDK retries and context-overflow recovery so the implementation does not collapse three different policies into one loop.

## Sources

Primary parity source:

- `earendil-works/pi` at OpenZi's pinned `0e6909f0` reference, including:
  - `packages/ai/src/utils/retry.ts`
  - `packages/ai/src/types.ts`
  - `packages/agent/src/agent.ts`
  - `packages/agent/src/agent-loop.ts`
  - `packages/coding-agent/src/core/agent-session.ts`
  - `packages/coding-agent/src/core/settings-manager.ts`
  - `packages/coding-agent/src/core/sdk.ts`
  - `packages/coding-agent/src/modes/interactive/components/status-indicator.ts`
  - `packages/coding-agent/src/modes/interactive/components/countdown-timer.ts`
  - `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
  - `packages/coding-agent/src/modes/print-mode.ts`
  - `packages/coding-agent/src/modes/rpc/`
  - retry, stream-option, status, print, and RPC tests

Post-pin research:

- `8e53e0e4` (2026-07-21), which applies the same retry policy to compaction and branch-summary model calls.
- `243f64be` (2026-07-21), which corrects an aborted retried call from being reported as successful.
- Pi `origin/main` at `a5afc3f17` was inspected on 2026-07-22 for the resulting behavior.

The post-pin commits are research inputs, not a silent change to `docs/reference-pins.md` or OpenZi's installed `@earendil-works/pi-*` `0.80.6` dependencies.

## Retry language

**Provider retry** is a retry performed inside an SDK or provider transport before it returns one assistant result. It is not visible as a coding-agent retry countdown.

**Agent-turn retry** restarts a failed assistant turn after the provider has returned an assistant error. It is owned by `AgentSession`, visible to clients, and keeps one logical prompt active.

**Summarization retry** repeats one model call used by manual/automatic compaction or future branch summarization. It uses the owning operation's cancellation signal and the same configured retry policy, but it does not restart an agent turn.

**Overflow recovery** excludes a context-overflow response, compacts the conversation, and continues once. It is not a transient provider retry and retains its independent one-recovery budget.

## Pi's layered policy

### Provider/SDK layer

`SimpleStreamOptions` exposes:

- `timeoutMs`;
- `maxRetries`;
- `maxRetryDelayMs`.

Pi's coding-agent settings place these under `retry.provider`. The documented defaults are:

```json
{ "retry": { "provider": { "maxRetries": 0, "maxRetryDelayMs": 60000 } } }
```

The coding agent also applies a five-minute HTTP idle timeout by default.

The important policy is that provider retries default to zero. Anthropic and OpenAI SDK adapters explicitly receive `maxRetries: 0` unless configured otherwise, and the Codex fetch implementation also defaults to zero. This prevents a provider SDK from sleeping invisibly through a long quota reset before `AgentSession` can classify the error, show a countdown, or let the user cancel.

When provider retries are explicitly enabled, supporting transports handle retryable HTTP responses and network failures internally. Codex recognizes `Retry-After` and `retry-after-ms`; `maxRetryDelayMs` caps server-requested waits. This layer has its own attempt budget and must not be confused with the outer agent-turn budget.

### Retry classification

Pi AI exports `isRetryableAssistantError()`. It classifies a completed assistant message; it does not own retry attempts or timing.

The message must have `stopReason: "error"` and a non-empty `errorMessage`. Retryable patterns include:

- overload, rate-limit, too-many-requests, and HTTP 429;
- HTTP 500, 502, 503, 504, and 524;
- service unavailable and internal/server errors;
- provider-returned-error wrappers;
- network, connection, fetch, socket, timeout, and termination failures;
- WebSocket closure/errors;
- premature stream endings;
- provider-requested retry-delay cap failures;
- explicit “retry your request” guidance;
- gRPC `ResourceExhausted` failures.

Non-retryable account and quota patterns take precedence even when the message also contains 429:

- OpenCode Go/free usage limits;
- monthly/subscription limits and available-balance requirements;
- `insufficient_quota`;
- budget, quota, and billing exhaustion.

Context overflow is checked before this classifier and routed to compaction. Aborted messages are never retried.

OpenZi's installed `pi-ai` already exports the classifier used by the pinned implementation. Pi current main adds one further early-EOF phrase for OpenAI Responses; adopting that requires a dependency refresh or a deliberate local compatibility decision.

### Agent-turn retry

Pi's `AgentSession` performs the following sequence:

1. The core agent completes a low-level run with an assistant error.
2. Normal `message_end`, persistence, `turn_end`, and `agent_end` events occur.
3. The session excludes context overflow, then classifies the assistant error.
4. If retry is enabled and its consecutive-failure budget remains, the session emits `auto_retry_start` with attempt, maximum attempts, delay, and error text.
5. The failed assistant message remains in the append-only session but is removed from the live agent context.
6. The session waits with an abortable exponential backoff.
7. It calls `agent.continue()` from the preceding user or tool-result message.
8. A successful assistant response emits `auto_retry_end { success: true }` and resets the consecutive-failure counter.
9. Exhaustion emits `auto_retry_end { success: false, finalError }` and leaves the final failure terminal.
10. `agent_settled` occurs only after retries, overflow recovery, tool work, and queued continuations are finished.

The default outer policy is enabled with three retries and a two-second base delay:

```text
initial call
retry 1 after 2s
retry 2 after 4s
retry 3 after 8s
```

There is no jitter in the inspected implementation. `maxRetries` means retries after the initial call, so three retries permit four provider calls.

The retry counter resets on the first non-error assistant response. A retry that returns tool calls therefore remains inside the original `prompt()` settlement until those tools and the subsequent model turn finish, but a later model failure starts a fresh consecutive-failure budget.

Pi extends `agent_end` with `willRetry`. This distinguishes a low-level run boundary from the final `agent_settled` boundary for JSON/RPC clients, extensions, queue presentation, and status integrations.

### Summarization retry on current Pi main

Pi's post-pin `8e53e0e4` change adds a reusable `retryAssistantCall()` primitive beside the classifier in `pi-ai`. Manual compaction, automatic compaction, and branch summarization pass the same `settings.retry` policy to each assistant-producing summary call.

For each call the helper:

1. samples once;
2. returns success, abort, or a non-retryable error immediately;
3. retries transient errors with the same exponential backoff;
4. uses the compaction or branch operation's signal to cancel its sleep and request;
5. reports schedule, attempt-start, and finished callbacks.

Coding-agent translates those callbacks to summarization retry events. The interactive client temporarily replaces the compaction or branch indicator with the retry countdown, then restores the owning operation indicator when the next attempt starts.

The budget is per assistant-producing call, not a global budget for the complete multi-chunk compaction. OpenZi already bounds compaction to eight chunks and 120 seconds; retry work must remain under that existing operation deadline.

The immediate follow-up `243f64be` is relevant acceptance evidence: if a retried request is aborted, retry completion is unsuccessful rather than successful merely because `stopReason` is no longer `"error"`.

### Interactive behavior

Pi shows:

```text
Retrying (1/3) in 2s... (esc to cancel)
```

The countdown updates once per second. Escape cancels the retry wait. During summarization, the existing compaction or branch owner remains responsible for cancellation.

The failed assistant attempt is rendered before the countdown. Pi's imperative TUI retains that rendered row even though the failed message was removed from the live agent context.

### Print, JSON, and RPC behavior

Print mode does not implement retry policy. It awaits `AgentSession.prompt()`, so text mode receives only the final successful response or terminal failure.

JSON mode subscribes to session events and therefore exposes failed attempt lifecycle, retry events, later attempts, and one final `agent_settled` event in source order.

Pi RPC additionally exposes `set_auto_retry` and `abort_retry`. OpenZi has deliberately deferred RPC, so those commands are not part of the first OpenZi slice. The client-independent session state and operations must still leave room for them.

## Pi behavior that OpenZi should not copy blindly

### Unbounded configured backoff

Pi reads numeric retry settings without the strict bounds OpenZi requires. Exponential delay can therefore become impractically large. OpenZi must validate persisted/runtime settings and bound attempts, each delay, cumulative waits, and the containing operation.

### Retry persistence and resume

Pi persists each failed assistant attempt, removes it only from the live agent state, and appends the successful retry as a descendant of that failed entry. Its inspected session-context projection does not explicitly exclude retry failures on resume, and the retry tests do not cover resume reconstruction.

OpenZi resolves this with append-only retry markers and separate context/presentation projections. Failed attempts remain durable and visible but never re-enter provider context after retry, resume, or later compaction.

### Timer ownership

Pi's countdown component owns a one-second interval. OpenZi's terminal constraints prohibit an independent presentation timer. The countdown should derive seconds from the retry deadline during the existing renderer-owned live lifecycle and release that live request with the status owner.

### Provider retries are not the default auto-retry experience

Enabling provider/SDK retries by default would duplicate budgets and hide waits. The visible session retry should remain the default. Provider retry configuration can be plumbed independently, with zero attempts by default.

## Implemented OpenZi boundaries

| Concern                        | Owner                                     | Implemented behavior                                                                |
| ------------------------------ | ----------------------------------------- | ----------------------------------------------------------------------------------- |
| Provider result classification | `pi-ai` dependency                        | Transient classifier used after overflow is excluded                                |
| Agent run lifecycle            | `AgentSession`                            | Retry waiting is an explicit run phase inside one prompt settlement                 |
| Agent failure persistence      | `SessionManager`                          | Append-only retry markers retain failures while excluding provider context          |
| Transcript projection          | `SessionManager`                          | Stable append projection retains failed attempts; compaction explicitly replaces it |
| Manual/automatic compaction    | `AgentSession` + `compaction.ts`          | Each summary sample uses the same policy within eight chunks and 120 seconds        |
| Settings                       | `SettingsManager`                         | Strict flat retry fields with global/project/runtime layering and scoped enablement |
| Interactive status             | `PromptView` + `ShimmerTextView`          | Deadline-derived countdown reuses the existing renderer live lifecycle              |
| Interruption                   | `AgentSession` + semantic `app.interrupt` | Escape restores queued input and cancels provider, compaction, or retry backoff     |
| Headless modes                 | `runPrintMode`                            | Text and JSON inherit retry behavior from their caller-owned `AgentSession`         |

The existing `Activity`/`RunPhase` union remains the state owner. Retry waiting is not a second manager or an independent boolean. It is a phase of an admitted agent run or of an admitted compaction operation.

## Implemented scope

The first slice delivers:

1. bounded, visible agent-turn retry for transient assistant errors;
2. the same policy for each manual and automatic compaction summary call;
3. separate overflow compact-and-continue limited to one recovery;
4. zero provider/SDK retry attempts by default;
5. inherited text and JSON behavior through `AgentSession`;
6. a policy boundary ready for future branch summarization;
7. no automatic retry for tools, shell commands, file mutations, authentication, persistence writes, or model changes.

The phrase “across the board” should mean every model-producing coding-agent operation, not arbitrary side effects.

## Required ownership and invariants

### SettingsManager

A validated retry policy must have:

- enabled/disabled state;
- a bounded retry count;
- a bounded base delay;
- a hard bound on effective per-attempt and cumulative waits;
- global/project/runtime layering consistent with existing settings.

Provider timeout/retry settings are a separate nested concern even if they land in the same settings patch. Provider retry attempts remain zero by default.

### AgentSession

`AgentSession` must own:

- retry admission after a completed assistant failure;
- consecutive attempt identity;
- the retry deadline and abort controller;
- context exclusion of failed attempts;
- one logical run settlement;
- event order;
- queue behavior;
- cancellation, shutdown, and disposal transitions.

The implementation should extend the existing explicit activity unions. It should not add `isRetrying`, attempt counters, timers, and controllers as independently coordinated mutable fields.

### Compaction

Compaction keeps its operation identity, controller, chunk bound, and 120-second deadline. Retry wraps one summary sample without becoming a second compaction state machine. A stale or cancelled compaction cannot schedule or commit a retry.

### TUI

The TUI renders authoritative retry status and reports semantic interruption. It does not classify provider errors, calculate backoff policy, or start retry effects.

The retry countdown should piggyback the existing prompt working-status live lifecycle. It should derive display seconds from a deadline and avoid `setInterval`, polling, or a second FPS owner.

### Persistence

A durable failed attempt and active provider context are different projections of one append-only session. The chosen representation must prove:

- failed attempts are never silently deleted from the journal;
- retries continue from the preceding valid user/tool boundary;
- resumed sessions do not feed excluded failures back to the provider;
- terminal presentation does not need to copy message text into a store.

## Characterization matrix

### Classification

- overload, 429 throttling, 5xx, timeout, socket loss, premature EOF, and explicit retry guidance;
- quota/billing/subscription limits are terminal;
- context overflow goes only to overflow recovery;
- abort is terminal;
- error text and events are bounded.

### Agent-turn transitions

- transient failure then success;
- multiple transient failures then success;
- exact budget exhaustion;
- retry disabled;
- cancellation during backoff;
- cancellation after backoff as the next attempt starts;
- shutdown and disposal during backoff;
- observer failure cannot corrupt retry state;
- stale completion cannot continue a replaced/disposed session;
- retry success containing tool calls settles only after the complete tool loop;
- one `agent_settled` after the whole chain;
- consecutive budget resets after a successful assistant/tool-use response.

### Queue transitions

- steering/follow-up admitted before the failure;
- input admitted from `agent_end` while retry is pending;
- retry continuation ordering relative to both queues;
- Escape restores all still-pending input exactly once;
- queue bounds remain unchanged throughout backoff.

### Persistence and resume

- every attempt has stable append order;
- active retry context excludes prior failed attempts;
- successful and exhausted retry journals restore deterministically;
- torn-tail recovery cannot resurrect an excluded failure into provider context;
- compaction after retry preserves the same exclusion.

### Compaction

- manual and automatic compaction retry transient summary failures;
- quota and deterministic validation failures are not retried;
- each retry remains inside the eight-chunk and 120-second bounds;
- cancellation during retry produces the owning compaction's cancellation outcome;
- no marker commits from stale retry completion;
- overflow recovery still occurs at most once.

### Client behavior

- TUI shows attempt/max/countdown/error context and Escape hint;
- countdown uses renderer lifecycle work and cleans up on replacement/disposal;
- text mode returns only final success or terminal failure;
- JSON mode preserves attempt event order and emits one final settlement;
- no credentials or unbounded provider error text enter retry events.

## Accepted decisions and deferred follow-ups

- Retry failures receive append-only `retry` markers. Active and resumed provider context and compaction input exclude marked failures, while the stable transcript projection retains their original assistant rows.
- `/settings` edits `retryEnabled` with explicit global/project scope. Validated files/runtime overrides also expose `retryMaxRetries` and `retryBaseDelayMs`.
- OpenZi accepts at most three retries and a 17-second base delay. The `1x + 2x + 4x` sequence is therefore always below two minutes; defaults remain Pi's 2, 4, and 8 seconds.
- JSON parity keeps `auto_retry_start/end`, extends `agent_end` with `willRetry`, and uses separate `summarization_retry_*` events carrying compaction operation identity.
- Provider/SDK retries remain zero by default. Provider timeout and `maxRetryDelayMs` configuration are deferred to a separate transport slice.
- Future branch summarization consumes the same retry policy and event discipline when branch navigation lands.
