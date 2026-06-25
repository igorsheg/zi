# PRD: End-to-End Operational Error Surfacing

## Problem Statement

Users need Zi to explain operational failures that originate in provider/model/runtime work clearly and consistently all the way from the AI provider boundary, through the coding-agent session owner, to the concrete TUI frontend. Today, failures can degrade into low-level error names, generic failed operation states, or transient assistant error text. This makes common situations such as missing credentials, provider authentication failure, rate limiting, context overflow, malformed provider responses, transport errors, and cancellation harder to understand and recover from.

The reference behavior is pi-mono. Implementors should consult the live `.references/pi-mono/` checkout while working, especially the ai, agent, coding-agent, and interactive-mode paths. Do not treat the findings in this PRD as a frozen porting spec; use them as direction and verify current reference behavior against live pi-mono.

## Solution

Zi should surface operational failures as bounded, typed, user-actionable facts. Provider and runtime failures should become terminal assistant/session facts where appropriate, not unstructured crashes or bare Zig error names. The coding-agent owner should preserve enough bounded failure detail for frontends to render useful statuses and recovery guidance. The TUI should display clear messages for common operational failure categories without learning provider internals.

The expected user experience is simple: when something fails, the user sees what failed, whether it was canceled or retryable, and what they can do next. The implementation should stay Zi-shaped: one owner mutation path, bounded resident data, protocol facts over ambient state, and no speculative broad framework.

## User Stories

1. As a Zi user, I want missing provider credentials to be explained in plain language, so that I know how to authenticate or configure the provider.
2. As a Zi user, I want invalid or expired credentials to be distinguished from generic provider failure, so that I do not waste time retrying an impossible request.
3. As a Zi user, I want rate limits to be identified clearly, so that I understand whether waiting or retrying is appropriate.
4. As a Zi user, I want provider server errors to be described as provider-side failures, so that I understand the problem is not necessarily my prompt or local environment.
5. As a Zi user, I want network or transport failures to be described clearly, so that I can check connectivity or retry.
6. As a Zi user, I want malformed provider responses to be reported as provider/protocol failures, so that I know the model response could not be interpreted.
7. As a Zi user, I want context overflow to be identified separately from ordinary failure, so that I understand why compaction or summarization may happen.
8. As a Zi user, I want cancellation to be shown as cancellation, not failure, so that intentional interruption is not alarming.
9. As a Zi user, I want the final operation state to agree with the visible transcript/status, so that the UI does not say both failed and completed ambiguously.
10. As a Zi user, I want failure messages to remain visible after event overflow recovery, so that the important terminal reason is not lost.
11. As a Zi user, I want retries to explain what is being retried and why, so that automatic recovery feels observable.
12. As a Zi user, I want failed retries to preserve the final reason, so that I know why recovery stopped.
13. As a Zi user, I want successful retries to clear recovery status, so that stale error messages do not remain after recovery.
14. As a Zi user, I want TUI status messages to be concise, so that errors are readable in a terminal viewport.
15. As a Zi user, I want raw provider details to be bounded, so that huge error bodies do not flood the transcript or UI.
16. As a Zi user, I want provider identity and model identity preserved where useful, so that I can diagnose model/provider configuration issues.
17. As a Zi user, I want slash-command and prompt-submission rejections to remain distinct from provider failures, so that local command problems are not confused with model problems.
18. As a Zi user, I want queue-full and event-overflow failures to remain bounded and recoverable, so that the UI continues operating under load.
19. As a Zi user, I want print, RPC, and TUI clients to receive consistent failure facts, so that behavior does not depend on frontend.
20. As a TUI user, I want the composer to remain responsive while failures and retries are reported, so that error reporting does not block input.
21. As a TUI user, I want foreground input rendering to remain independent from background failure ingestion, so that provider errors do not cause UI jank.
22. As a session owner, I want durable session history to include terminal assistant failure facts before they can be dropped from resident windows, so that resume and snapshots remain truthful.
23. As an implementor, I want provider operational errors to cross boundaries as protocol facts, so that higher layers do not string-match Zig error names.
24. As an implementor, I want programmer errors to still fail fast, so that invalid internal states are not hidden as user-facing operational failures.
25. As an implementor, I want allocation failure to remain explicit and handled according to existing owner-loop rules, so that error surfacing does not silently corrupt state.
26. As an implementor, I want a small typed taxonomy rather than a large exception hierarchy, so that the system stays maintainable.
27. As an implementor, I want the AI layer to own provider/wire interpretation, so that coding-agent and TUI do not learn provider-specific HTTP details.
28. As an implementor, I want coding-agent to own session and public-client failure facts, so that frontends receive bounded snapshots/events instead of callbacks.
29. As an implementor, I want the TUI adapter to translate client facts into domain-neutral TUI commands/statuses, so that core TUI remains agent-agnostic.
30. As an implementor, I want tests at the highest practical seam, so that behavior is specified without locking in incidental helper structure.
31. As a maintainer, I want the implementation to reference live pi-mono behavior during development, so that Zi preserves the intended user feel without becoming a TypeScript port.
32. As a maintainer, I want failure details to have explicit byte bounds, so that provider error bodies and retained events cannot grow without policy.
33. As a maintainer, I want one mutation path for applying failure facts, so that snapshots, events, persistence, retry state, and UI status stay consistent.
34. As a maintainer, I want error categories to be stable enough for frontend presentation, so that future provider changes do not break TUI behavior.
35. As a maintainer, I want unknown failures to degrade gracefully, so that unclassified operational errors are still visible and bounded.

## Implementation Decisions

- Preserve the existing architecture boundaries: AI interprets provider/wire failures, agent runs generic stream/tool loops, coding-agent owns session/public-client policy, and frontends translate public facts into UI behavior.
- Use the live pi-mono checkout as behavioral reference during implementation. Avoid hard-coding the preliminary research findings as final requirements when pi-mono has a more precise or newer behavior.
- Operational provider/model/runtime failures should become terminal assistant/session facts where possible. Programmer errors and impossible internal states should continue to fail fast.
- Introduce only the smallest typed error surface needed for current behavior. The likely shape is a compact category plus bounded message and optional retry/auth/context metadata, but the exact schema should be decided against live pi-mono and current Zi code.
- Public client protocol should carry enough bounded terminal failure detail that a frontend can render useful status even if intermediate stream events were dropped and recovered by snapshot/replay.
- The coding-agent event drain remains the single writer for message-derived session state, public events, persistence, and retry/compaction accounting.
- Failure details must have named byte/count bounds and an explicit overflow/truncation policy.
- TUI product code remains agent-agnostic. Any coding-agent error fact to TUI status/transcript mapping belongs in the concrete frontend adapter, not core TUI.
- The TUI should display actionable concise status for known categories and a safe generic message for unknown categories.
- Retry and compaction decisions should not depend on brittle string matching where a typed fact is available.
- Existing rejection semantics for invalid commands, busy state, and queue overflow should remain separate from provider operation failures.
- Existing cancellation semantics should remain observable as cancellation, not generic failure.

## Pi-mono Behavioral Alignment

Live pi-mono behavior is string-based, but the product behavior is clear:

- Provider/open failures become assistant-visible terminal errors rather than crashes where possible.
- Cancellation is rendered as cancellation/aborted, not as an alarming generic failure.
- Context overflow is special: it is detected after an assistant error, excluded from ordinary retry, and routed into one compact-and-retry recovery attempt. If that recovery fails, pi-mono emits a clear compaction failure message telling the user to reduce context or switch to a larger model.
- Retryable provider failures are transient categories in practice: overloaded/provider returned error/rate limit/429/5xx/service unavailable/server/internal/network/connection/websocket/fetch/upstream reset/timeout/terminated/retry-delay failures. Auto-retry emits start/end facts, removes the failed assistant message from runtime context, and keeps the failed message in durable/session history.
- Non-retryable provider limit/auth-like failures should stop with the final reason visible.
- Provider-side retry exists below the session for Codex responses: rate limits and transient HTTP/network errors are retried before surfacing the final failure, respecting retry-after headers where practical.
- The interactive UI turns assistant error messages into visible transcript/status output. Retry start/end and compaction start/end are observable product events.
- pi-mono preserves user feel, not a stable typed protocol: it relies on regular expressions and error-message text for several policies. Zi should preserve the behavior with typed facts first and bounded string fallback second.

Zi alignment decisions:

- Keep Zi's typed `OperationalFailure` as the stable boundary fact instead of porting pi-mono's regex-as-policy shape.
- Keep string fallback for unknown/legacy/provider messages because pi-mono has broad provider coverage and custom-provider behavior.
- Expand Zi's context-overflow matcher toward pi-mono's documented patterns, but keep it behind `category == context_overflow` when the provider can classify directly.
- Preserve pi-mono's runtime/durable split: failed retry messages are removed from runtime agent context before retry, but persisted/session-visible failure facts remain.
- Do not make core TUI provider-aware. Pi-mono's interactive mode owns product rendering; Zi's equivalent owner is the concrete frontend adapter.

## Working Design

Build the smallest useful surface: one AI-owned operational failure value, copied into existing stream/message facts, then projected by the coding-agent owner into public client events and snapshots. Do not add a global error bus, exception hierarchy, or frontend-specific provider table.

### Failure fact

The typed fact should be compact and stable enough for policy and presentation:

```text
OperationalFailure
  category: auth_missing | auth_rejected | rate_limited | context_overflow |
            provider_unavailable | transport | malformed_response |
            canceled | unknown
  message: bounded UTF-8 user-facing summary
  detail: optional bounded raw/provider detail for diagnostics
  retryable: yes | no | unknown
  provider: optional bounded provider id
  model: optional bounded model id
```

Initial byte policy:

- `message`: cap at 512 bytes, UTF-8 prefix truncation with an ellipsis marker where practical.
- `detail`: cap at 2048 bytes, same truncation policy; never copy full provider bodies into resident state.
- `provider` and `model`: reuse existing model/provider text caps at public protocol boundaries.

These caps are deliberately small because terminal status and public events are resident facts. If a later need requires larger diagnostic bodies, add a spill/pull path instead of raising resident caps casually.

### Ownership and mutation path

```text
provider/wire adapter
  -> ai stream terminal error fact
  -> agent terminal assistant message/event
  -> coding-agent event drain
       -> queue/status mirror
       -> public ClientEvent
       -> durable session history on message_end
       -> retry/compaction terminal policy
  -> concrete frontend adapter
       -> tui Command/status/transcript append
```

Only the provider/wire adapter classifies HTTP, SSE, JSON, and credential details. The agent loop transports the fact and remains generic. The coding-agent event drain is the only place that mutates public events, retry accounting, queue mirrors, and persistence. Core `src/tui` never learns provider/model/error categories; `src/frontends/tui` translates client facts into domain-neutral transcript/status commands.

### Category policy

- `auth_missing`: credential lookup produced no usable credential before the request. Not retryable. Message should point at auth/configuration, not provider outage.
- `auth_rejected`: provider rejected credentials, for example unauthorized/forbidden responses. Not retryable without user action.
- `rate_limited`: provider says too many requests or quota pressure. Retryable when provider metadata or status makes that credible.
- `context_overflow`: provider/model says the request exceeds context/token limits. This is distinct from generic failure so compaction policy can react without string matching.
- `provider_unavailable`: provider-side 5xx or overload. Usually retryable.
- `transport`: network, DNS, TLS, connection, timeout, or SSE transport failure. Retryable unknown/yes depending on current retry policy.
- `malformed_response`: provider returned a response Zi could not parse or map to protocol. Not a programmer error if the bytes came from outside the process.
- `canceled`: cancellation intent reached the operation. This is terminal but not failure.
- `unknown`: bounded fallback for operational errors that cannot yet be classified.

Programmer errors remain assertions, unreachable cases, or ordinary Zig errors that fail tests fast. Allocation failure remains `OutOfMemory`, not an operational provider failure.

### Public protocol shape

Prefer extending existing facts over adding parallel events:

- AI stream `error` payload should carry the typed failure next to the old coarse reason, or replace the coarse reason only if all call sites can be updated in one small change.
- `ClientEvent.operation_finished` should expose the final failure fact when the operation failed or was canceled.
- Snapshots should retain the latest terminal operation failure so replay/event-overflow recovery can still explain why the visible run ended.
- Durable assistant history should preserve terminal assistant failure text/fact before resident transcript windows can evict it.

### First implementation slice

1. Add the typed failure value and copy/deinit/json helpers at the AI protocol boundary.
2. Classify the errors already visible in the current OpenAI responses/Codex responses path: missing credential, HTTP auth/rate-limit/5xx, malformed JSON/SSE, transport/unknown, cancellation.
3. Carry the fact through `agent.AgentEvent` copies without changing tool execution semantics.
4. Teach `coding_agent.event_drain` and `client_protocol` to include the terminal fact in public failure/cancel outcomes and snapshots.
5. Map the public fact in `src/frontends/tui` and print/RPC frontends; leave `src/tui` untouched except for existing generic status/transcript commands if needed.
6. Add focused tests at the public protocol seam before broadening provider coverage.

## Testing Decisions

- Prefer the highest seam that observes user-visible behavior: session runtime/client protocol behavior for end-to-end facts, and the TUI frontend adapter for display translation.
- Avoid tests that assert private helper names or internal construction order unless those are true invariants.
- Add focused provider/AI tests for operational failures becoming bounded terminal error facts rather than raw setup errors where feasible.
- Add coding-agent tests that failed operations carry durable/public failure detail and still follow the owner order: queue/status mirror, public event, persistence, terminal policy.
- Add tests for missing credentials, provider HTTP failure, cancellation, context overflow, retryable failure, and unknown failure fallback.
- Add tests for event overflow/snapshot recovery preserving the terminal failure reason at the public boundary.
- Add TUI adapter tests that typed client failure facts become concise status/transcript output without importing provider details into core TUI.
- Reuse prior art from existing tests around assistant error messages, auto-retry start/end, compaction failure, public event overflow, history snapshots, and TUI client event application.
- Good tests should assert externally visible facts: terminal assistant message shape, operation outcome, public client event content, durable/snapshot presence, and rendered status text category.
- Bounds tests should cover oversized provider error bodies and ensure truncation/degradation rather than owner-loop failure.

## Out of Scope

- Porting pi-mono architecture or exception hierarchy directly.
- Adding a broad centralized error framework before concrete current needs require it.
- Changing core TUI to know about agents, providers, models, sessions, or HTTP.
- Reworking all provider implementations beyond what is needed to surface current operational errors consistently.
- Building a new retry scheduler or compaction system unrelated to error surfacing.
- Changing tool-result error behavior except where it interacts with shared public failure presentation.
- Solving full auth UX, login flows, or settings UI beyond displaying actionable failure guidance.
- Guaranteeing identical wording to pi-mono where Zi has a clearer bounded equivalent.
- Treating allocation failure as a user-facing provider error.

## Implementation Checklist

Done:

- [x] Add typed AI `OperationalFailure` fact with compact category, bounded message/detail policy, retryability, provider, and model.
- [x] Attach operational failures to assistant terminal messages/events.
- [x] Preserve operational failures through owned agent-event/message copying and deinit.
- [x] Classify missing provider credentials for OpenAI Responses and OpenAI Codex Responses.
- [x] Classify basic HTTP provider failures: rejected credentials, rate limit, provider unavailable, context-overflow-ish, and unknown.
- [x] Bound HTTP provider error bodies and SSE/provider formatted error text at the AI boundary.
- [x] Expose terminal failure facts on `operation_finished` public client events.
- [x] Use typed failure facts first for retry/context-overflow policy, with bounded string fallback.
- [x] Preserve operational failures in durable session JSONL load/store round trips.
- [x] Render typed failures in print mode and the concrete TUI frontend adapter without making core TUI provider-aware.
- [x] Align the PRD with live pi-mono product behavior rather than porting its string/regex architecture.

Remaining:

- [x] Snapshot/event-overflow recovery exposes the latest terminal failure explicitly, not only through history projection.
- [x] Cancellation carries a typed `.canceled` fact on public operation completion.
- [x] Stream-open transport errors classify as `transport` instead of `unknown` where the provider/runtime boundary can know that.
- [x] Stream-open malformed JSON/provider protocol failures classify as `malformed_response`.
- [x] Mid-stream transport and malformed SSE failures become terminal assistant facts instead of bubbling as raw stream errors.
- [x] Context overflow fallback matching covers the important pi-mono patterns while retaining typed-first policy.
- [x] Retry start/end public events carry typed failure facts where available, with string fallback preserved.
- [x] RPC/JSON tests assert typed failure shape for public events.
- [x] Codex provider retry-after behavior reviewed against pi-mono and documented as intentionally different for this PRD: Zi retries bounded transient Codex failures with capped exponential backoff today, but does not parse provider `retry-after` headers yet because error surfacing only requires the final surfaced failure to be typed, bounded, and truthful. Header-directed retry timing belongs to provider retry policy follow-up work, not this error-surfacing slice.
- [x] Focused frontend coverage exists for concise category rendering at the public boundary; stale-error clearing is handled by existing operation status cleanup and is not a separate PRD blocker.

## Completion Notes

This PRD is complete for the intended error-surfacing slice. Zi now has a typed, bounded operational failure fact from AI/provider boundaries through agent copying, coding-agent public protocol, durable session history, snapshots/replay recovery, retry/cancel completion facts, and concrete frontend presentation. Remaining improvements such as provider-specific retry-after timing are policy refinements, not missing error-surfacing plumbing.

Definition of done for this PRD:

- provider/runtime operational failures have a typed category where Zi can know it;
- unknown operational failures still surface as bounded facts;
- final public operation facts agree with transcript/status state;
- durable history and snapshots preserve terminal failure truth;
- retry and compaction policy no longer depends only on brittle string matching;
- core TUI remains agent/provider agnostic;
- programmer errors and allocation failure are not hidden as provider failures.

## Further Notes

This PRD intentionally leaves exact type names, field names, and wording open. The implementor should inspect live pi-mono at implementation time and then choose the smallest Zi-shaped protocol changes that preserve the behavior users feel: clear terminal errors, observable cancellation, bounded details, durable session truth, and frontend-independent public facts.

Proposed main test seam: coding-agent session runtime/client protocol, with focused AI/provider tests below it and concrete TUI adapter tests above it only where presentation mapping needs coverage.
