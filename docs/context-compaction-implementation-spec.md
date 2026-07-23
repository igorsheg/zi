# Context compaction implementation spec

Status: implemented

This specification defines Zi's first context-compaction system. It compares Pi's coding-agent compaction at `earendil-works/pi@0e6909f0` with Grok Build's open-source full-replace system at `xai-org/grok-build@98c3b243`, then selects the parts that fit Zi's current ownership model.

The primary decision is deliberate: Zi should port Pi's append-only, tail-preserving compaction shape, not Grok Build's whole-session replacement architecture. Grok Build contributes failure, accounting, validation, and preflight lessons. It does not replace Pi as the coding-agent behavior and architecture reference.

## Outcomes

The first implementation must provide:

1. automatic compaction before the selected model runs out of context;
2. one manual `/compact [focus]` operation shared by every client through `AgentSession`;
3. provider-reported context accounting plus bounded estimates for messages added after the last response;
4. append-only persistence that keeps the full journal while deriving a smaller active provider context;
5. an exact recent tail, including structurally valid assistant/tool-result groups;
6. iterative summaries that carry prior compaction state forward;
7. one bounded overflow compact-and-retry attempt;
8. explicit operation, cancellation, failure, and settlement transitions;
9. no history mutation until a summary has been generated, validated, and durably appended;
10. context usage, compaction progress, and failure presentation in the TUI;
11. behavior tests for restore, repeated compaction, queues, tool loops, overflow, cancellation, and stale completion;
12. hard bounds on summary input, output, chunks, retained metadata, and operation duration.

## Non-goals

The first implementation does not add:

- Grok Build's full-replace conversation assembly;
- a dedicated compaction model;
- speculative two-pass prefire;
- memory flushes, semantic memory search, transcript pointers, or segment sidecars;
- a second persisted transcript or materialized session index;
- background-task resurrection or persisted claims that process-scoped tasks remain alive after resume;
- extension compaction hooks;
- branch summarization or tree navigation;
- lossy request-time tool-result pruning as a substitute for durable compaction;
- a `CompactionManager`, generic state-machine framework, command bus, or frontend compaction owner;
- transient provider retry policy in the original compaction slice; the later retry milestone wraps each summary sample without changing this transaction;
- config compatibility with Pi or Grok Build.

# 1. Reference comparison

## Pi Mono

Relevant sources at the pinned commit:

- `packages/coding-agent/src/core/compaction/compaction.ts`
- `packages/coding-agent/src/core/compaction/utils.ts`
- `packages/coding-agent/src/core/messages.ts`
- `packages/coding-agent/src/core/session-manager.ts`
- `packages/coding-agent/src/core/agent-session.ts`
- `packages/coding-agent/test/compaction.test.ts`
- `packages/coding-agent/test/agent-session-auto-compaction-queue.test.ts`

Pi:

- appends a compaction marker to the existing journal;
- injects the latest summary as a synthetic user-like message;
- keeps an exact recent suffix selected by a token budget;
- may split a very large turn while keeping assistant/tool-result structure valid;
- folds the previous summary into later summaries;
- uses the current model, authentication, and thinking level;
- triggers at `contextWindow - reserveTokens`;
- anchors accounting at the last valid assistant usage and estimates the trailing messages;
- checks after a run and before the next prompt;
- recognizes provider overflow and allows one compact-and-retry recovery;
- persists deterministic read/modified file lists beside the summary.

Keep:

- the append-only marker and active-context projection;
- exact recent-tail retention;
- iterative summary updates;
- provider usage plus trailing estimates;
- current-model sampling;
- explicit manual, threshold, and overflow reasons;
- deterministic file-operation carry-forward;
- the structured checkpoint prompt;
- overflow recovery bounded to one retry.

Change:

- compaction is admitted by Zi's explicit `AgentSession` activity states; manual compaction does not silently abort unrelated work;
- the provider-boundary hook also checks tool-result growth before the next model request;
- a failed overflow response remains durable for transcript/history purposes but is explicitly excluded from the replacement provider context;
- prior compaction markers never reappear as duplicate summaries in a later active context;
- summary input, output, metadata, and elapsed time receive hard bounds;
- invalid or non-reducing output never commits;
- journal append ordering must not mutate in-memory state before the durable append succeeds;
- lifecycle events carry one closed outcome rather than coordinating `aborted`, `result`, and `errorMessage` optionals.

## Grok Build

Relevant sources at the pinned commit:

- `crates/common/xai-grok-compaction/src/code_compaction/`
- `crates/common/xai-grok-compaction/src/select.rs`
- `crates/codegen/xai-chat-state/src/actor/state.rs`
- `crates/codegen/xai-chat-state/src/actor/mutations.rs`
- `crates/codegen/xai-chat-state/src/compaction_utils.rs`
- `crates/codegen/xai-grok-shell/src/session/compaction.rs`
- `crates/codegen/xai-grok-shell/src/session/compaction_config.rs`
- `crates/codegen/xai-grok-shell/src/session/helpers/session_compact.rs`

Grok Build:

- normally triggers at 85% of the current model's context window;
- combines the last provider count with estimates for later user/tool content;
- checks before every model sample, after large tool outputs, after a context-length error, and when switching to a smaller model;
- summarizes the whole conversation and rebuilds a fresh context;
- deterministically re-injects the system prompt, project instructions, latest real user query, and live task/MCP/todo/plan state;
- validates and cleans model output before replacement;
- retries transient/degenerate summaries but not deterministic failures;
- steps compaction input down from verbatim to fitted to lossy when the summary request itself overflows;
- suppresses repeated automatic failures according to their cause;
- persists checkpoints and optional transcript/segment recovery artifacts;
- has an optional, currently opt-in two-pass prefire path.

Keep:

- pre-sampling checks, especially after tool results;
- accounting for content added after provider usage was reported;
- safe assistant/tool-result boundaries;
- output validation before state replacement;
- no identical retry for a deterministic context-length failure;
- bounded operation time and bounded summary artifacts;
- explicit suppression of repeated automatic failure within one run;
- current model context-window changes as part of trigger policy;
- a commit that replaces active context only after durable checkpoint persistence.

Reject for this milestone:

- full replacement of every exact conversational turn;
- actor, ACP, remote-session, and multi-agent ownership;
- persisted live-state reconstruction for resources Zi already supplies through the current system prompt;
- claims that `SessionShell` tasks can survive process/session disposal;
- request artifacts, raw transcript pointers, segment stores, and cloud audit paths;
- memory flush and retrieval;
- full-replace input ladders that silently drop old source turns;
- degenerate-summary heuristics calibrated to Grok's production prompt and models;
- speculative prefire and a dedicated compaction model.

## Decision matrix

| Concern           | Pi                                            | Grok Build                                     | Zi decision                                                      |
| ----------------- | --------------------------------------------- | ---------------------------------------------- | ---------------------------------------------------------------- |
| Replacement shape | Summary + exact recent tail                   | Whole-session rebuild                          | Pi                                                               |
| Durable source    | Append-only journal marker                    | Checkpoint files + replacement records         | Pi, with transactional append ordering                           |
| Trigger           | Remaining-token reserve                       | Usage percentage                               | Pi reserve, clamped to the model window                          |
| Provider boundary | Post-run and pre-prompt                       | Before each sample and after tools             | Grok-strength boundary checks through Pi agent hooks             |
| Accounting        | Last valid usage + trailing estimate          | Provider total + mutation delta                | Combined model, owned in `AgentSession`                          |
| Tool integrity    | Never start retained context at a tool result | Validate/sanitize tool pairs                   | Safe cut planner plus restored-journal validation                |
| Re-compaction     | Update previous summary                       | Re-summarize prior summary in full replacement | Pi iterative update                                              |
| Output validation | Provider error only                           | Empty/degenerate/truncation checks             | Non-empty, bounded, structurally usable, reducing                |
| Input overflow    | No fallback ladder                            | Verbatim → fitted → lossy                      | Bounded sequential chunks; never silently discard source entries |
| Overflow recovery | One compact-and-continue                      | Compact and resubmit with suppression          | One compact-and-continue per run                                 |
| Live state        | File operation appendix                       | Broad deterministic state reminder             | File operations only in the first milestone                      |
| UI                | Compaction status + rebuilt transcript        | Notifications and context diagnostics          | Zi-owned status, usage, and active transcript reset              |

# 2. Canonical language

**Durable journal** is the complete append-only `SessionManager` entry sequence. Compaction never deletes its earlier messages.

**Active context** is the smaller, compaction-aware `AgentMessage[]` sent to Pi agent core and providers. It is derived from the durable journal and is the authoritative `AgentSession.messages` value.

**Compaction marker** is the durable entry that records one summary, its exact retained boundary, accounting facts, reason, and bounded deterministic details.

**Retained tail** is the exact context-visible suffix kept after the summary. It may begin at a user message or assistant message, but never at a tool result.

**Summary source** is the prior compaction summary plus the active messages that the new marker removes from exact context.

**Context usage** is the selected model's current context-window occupancy. It is either provider-anchored or locally estimated; these qualities remain explicit.

**Overflow recovery** is the single automatic sequence that excludes one failed overflow response from active context, compacts, and continues from the preceding user/tool input. It is not general provider retry.

# 3. Owners

| Concern                                                                                         | Owner                                                      |
| ----------------------------------------------------------------------------------------------- | ---------------------------------------------------------- |
| Compaction admission, operation identity, cancellation, automatic policy, and commit            | `AgentSession`                                             |
| Durable entries, compaction marker validation, append ordering, and active-entry projection     | `SessionManager`                                           |
| Pure token estimates, safe cut planning, bounded serialization, and summary prompt construction | `packages/coding-agent/src/compaction.ts`                  |
| Custom summary message type and provider conversion                                             | `packages/coding-agent/src/messages.ts`                    |
| Selected model request and credentials                                                          | Existing Pi agent stream function / `ModelRegistry` wiring |
| Effective global/project settings                                                               | `SettingsManager`                                          |
| Slash intent and terminal workflow                                                              | `SlashController` and `PromptStore`                        |
| Active transcript reset and summary rendering                                                   | `TranscriptView`                                           |
| Context/status text and cancellation key routing                                                | `PromptView`                                               |
| Final session disposal and bounded shutdown settlement                                          | Existing runtime/CLI owners                                |

There is no mutable compaction store in the TUI. `PromptStore` may retain only its admitted command operation and feedback. It does not retain the summary, active context, token timeline, or a second compaction state.

# 4. Session state and transitions

Compaction becomes part of `AgentSession` activity, not an independent set of flags.

The implementation should preserve the existing top-level activity states and add explicit compaction phases. The concrete TypeScript may differ, but it must represent these states directly:

```ts
type CompactionReason = "manual" | "threshold" | "overflow"

type RunPhase =
  | { readonly type: "agent" }
  | {
      readonly type: "compacting"
      readonly operationId: number
      readonly reason: "threshold" | "overflow"
      readonly controller: AbortController
    }

type Activity =
  | { readonly type: "idle" }
  | {
      readonly type: "running"
      readonly runId: number
      readonly phase: RunPhase
      readonly autoCompactions: number
      readonly overflowRecoveries: 0 | 1
      readonly settled: Promise<void>
    }
  | { readonly type: "aborting"; readonly runId: number; readonly settled: Promise<void> }
  | {
      readonly type: "compacting"
      readonly operationId: number
      readonly reason: "manual"
      readonly controller: AbortController
      readonly settled: Promise<void>
    }
  | { readonly type: "failed"; readonly runId: number; readonly cause: unknown }
  | { readonly type: "disposed"; readonly settled: Promise<void> }
```

The owner may factor shared fields without hiding the domain states behind a generic machine.

Allowed transitions:

```text
idle
  -> running(agent)
  -> compacting(manual)
  -> disposed

running(agent)
  -> running(compacting threshold|overflow)
  -> aborting
  -> failed
  -> idle
  -> disposed

running(compacting)
  -> running(agent)        success, cancellation, or recoverable auto failure
  -> aborting
  -> disposed

compacting(manual)
  -> idle                  success, cancellation, or failure
  -> disposed

aborting
  -> idle | failed | disposed
```

Rules:

1. Manual `compact()` is admitted only from `idle`, with a selected model and idle authentication/model mutation.
2. Manual compaction never implicitly aborts a provider run. A busy call is rejected.
3. Automatic compaction is admitted only by the active run owner at a provider boundary.
4. At most four automatic compactions and one overflow recovery are admitted in one run. Reaching either bound suppresses further attempts until that run settles.
5. One operation ID owns generation and commit. Cancellation, disposal, model replacement, or a newer operation makes its completion stale.
6. Model mutation and whole-session replacement remain inadmissible while compaction is active.
7. Queued steering/follow-up input remains owned by the running session during automatic compaction and is delivered after a successful context replacement.
8. Manual compaction accepts no concurrent prompt or queued input.
9. `waitForIdle()` includes manual and automatic compaction settlement.
10. `dispose()` aborts the compaction request, prevents commit, clears listeners, and preserves creator-owned bounded settlement.

# 5. Persistent journal and active-context projection

## Entry schema

Add a direct `compaction` variant to `SessionEntryData`:

```ts
export interface CompactionDetails {
  readonly readFiles: readonly string[]
  readonly modifiedFiles: readonly string[]
  readonly omittedReadFiles: number
  readonly omittedModifiedFiles: number
}

type SessionEntryData =
  | { readonly type: "message"; readonly message: AgentMessage }
  | { readonly type: "model_change"; readonly provider: string; readonly modelId: string }
  | { readonly type: "thinking_level_change"; readonly thinkingLevel: ThinkingLevel }
  | {
      readonly type: "compaction"
      readonly reason: CompactionReason
      readonly summary: string
      readonly firstKeptEntryId: string
      readonly tokensBefore: number
      readonly estimatedTokensAfter: number
      readonly details: CompactionDetails
      readonly excludedFailureEntryId?: string
    }
```

`excludedFailureEntryId` exists only for overflow recovery. It identifies the one durable assistant error entry that must not be returned to the provider after compaction. The transcript record remains in the journal. General context-exclusion lists are not introduced.

The existing session header remains version 1 because this is an additive validated entry variant. A future incompatible header change remains a separate migration decision.

## Bounds

The first implementation uses:

```ts
const maxCompactionInstructionsBytes = 16 * 1024
const maxCompactionSummaryBytes = 128 * 1024
const maxCompactionFilePaths = 256
const maxCompactionPathBytes = 4096
const maxCompactionChunks = 8
const maxCompactionOperationMs = 10 * 60_000
const maxSerializedToolResultChars = 2_000
```

Settings and model-relative token budgets add further bounds. A persisted entry violating these limits invalidates the session rather than entering active state.

## Append ordering

`SessionManager` currently mutates `#entries` and `#leafId` before `appendFileSync()` can fail. The compaction milestone must reverse that ownership leak for every appended entry:

1. construct and validate the complete next entry;
2. append its JSONL record when persistence is enabled;
3. only after the append succeeds, mutate `#entries` and `#leafId`;
4. return the committed entry, not only its ID.

A failed append therefore leaves both durable and in-memory journal state at the old leaf. `AgentSession` must not replace `agent.state.messages` unless `appendCompaction()` returns the committed marker.

The existing torn-final-line recovery remains valid for process death during append. Malformed completed records still invalidate the journal.

## Zi summary message

Pi agent-core's root export loads its harness declaration, which already owns a weaker `compactionSummary` variant without post-compaction accounting. Redeclaring the same `CustomAgentMessages` key cannot strengthen that property safely. `messages.ts` therefore owns a narrow public facade that excludes Pi's variant and replaces it with:

```ts
export interface CompactionSummaryMessage {
  readonly role: "compactionSummary"
  readonly summary: string
  readonly tokensBefore: number
  readonly estimatedTokensAfter: number
  readonly timestamp: number
}
```

Zi exports this narrowed `AgentMessage`; journal admission validates it at runtime. The explicit Pi boundary still accepts Pi's broader union because Pi appends only base provider messages while Zi is the sole producer of summary messages. `convertToLlm()` maps the summary to one user message with a fixed continuation preamble and bounded summary text. `createAgentSession()` installs this converter on the Pi `Agent`. The TUI continues to receive the typed `compactionSummary` message and never parses the provider preamble.

## Active-entry projection

`SessionManager.activeEntries()` and `activeMessages()` derive the current context:

1. Resolve the latest valid compaction marker.
2. If none exists, return every context-visible message entry.
3. Resolve `firstKeptEntryId` to an earlier context-visible entry.
4. Return the latest marker's synthetic summary first.
5. Return context-visible message entries from `firstKeptEntryId` through the marker's parent range.
6. Skip every older compaction marker; its information is already folded into the latest summary.
7. Skip `excludedFailureEntryId`.
8. Append context-visible entries after the latest marker, again skipping only the explicitly excluded failure.
9. Ignore model, thinking, and other metadata entries for provider context while retaining them for restoration policy.

Repeated compaction may point to an entry that physically precedes an older marker. Skipping older markers is therefore required; a raw contiguous slice would inject duplicate summaries.

On open, semantic validation requires:

- `firstKeptEntryId` exists and precedes the marker;
- it names a context-visible entry;
- `excludedFailureEntryId`, when present, precedes the marker and names an assistant error;
- numeric fields are finite non-negative integers;
- summary/details satisfy their bounds;
- projected context does not begin with a tool result after the synthetic summary.

`SessionManager.entries()` remains the full durable journal. Session statistics and future history views use it deliberately; provider execution and the current TUI transcript use the active projection.

# 6. Context accounting

## Public state

Expose one derived union from `AgentSession`:

```ts
export type ContextUsage =
  | { readonly type: "unavailable"; readonly reason: "no_model" | "unknown_window" }
  | { readonly type: "measured"; readonly tokens: number; readonly contextWindow: number; readonly percent: number }
  | { readonly type: "estimated"; readonly tokens: number; readonly contextWindow: number; readonly percent: number }
```

`percent` is clamped for display but `tokens` is not clamped; overflow remains visible.

## Accounting algorithm

`AgentSession` owns a small private accounting value; it does not rescan the full durable journal on every TUI update.

1. A successful, non-aborted assistant message with non-zero usage becomes the provider anchor.
2. Use `usage.totalTokens` when non-zero; otherwise sum input, output, cache-read, and cache-write fields.
3. User, tool-result, custom, and other context-visible messages after that anchor add bounded local estimates. Any non-zero trailing estimate changes the public quality from `measured` to `estimated`.
4. The assistant response that supplied the usage is already represented by that usage and is not added again.
5. Error, aborted, and all-zero assistant messages do not replace the last valid anchor; their visible text is a trailing estimate if it remains in active context.
6. After compaction, every provider usage from a physically earlier journal entry is stale, including usage on exact messages retained across the marker. Accounting resets to an estimate of the new active context.
7. The first valid provider response committed after the marker restores `measured` quality.
8. On restore, only an assistant usage physically appended after the latest marker can be a provider anchor. Otherwise estimate the projected active context once.
9. Model change keeps the token estimate but recomputes the context window and percentage. Automatic compaction is considered at the next admitted provider boundary, not hidden inside `setModel()`.

The message estimator follows Pi's established semantics:

- text uses a conservative UTF-8 byte/4 estimate;
- images use a fixed token estimate rather than base64 length;
- assistant text, thinking, tool names, and serialized arguments count;
- tool-result text counts;
- compaction summary text and deterministic file appendix count;
- malformed external values are rejected before estimation.

## Effective budget

Settings are model-independent, so derive safe values for the selected model:

```text
effectiveReserve = min(configuredReserve, floor(contextWindow / 4))
triggerTokens    = contextWindow - effectiveReserve
effectiveKeep    = min(configuredKeep, floor((contextWindow - effectiveReserve) / 2))
modelOutputCap   = model.maxTokens > 0 ? model.maxTokens : effectiveReserve
summaryMaxTokens = min(modelOutputCap, floor(effectiveReserve * 0.8))
```

Every value has a minimum effective value of 1. A model with a missing or non-positive context window exposes `unknown_window` and disables automatic compaction; manual compaction still fails with a clear unsupported-model error rather than guessing.

Automatic compaction triggers when projected usage is strictly greater than `triggerTokens`. The pre-prompt projection includes the prospective user text and images. The between-turn projection includes tool results and queued steering content already admitted into the Pi loop context.

# 7. Cut planning

`prepareCompaction()` is pure. It receives validated active entries, the latest marker if any, an optional overflow failure entry to exclude, effective settings, and the accounting snapshot.

Algorithm:

1. Form the logical active message sequence without the overflow failure.
2. Walk backward, accumulating estimated tokens until `effectiveKeep` is reached.
3. Select the nearest safe boundary at or after that position.
4. A safe boundary may start at a user or assistant message; it may never start at a tool result.
5. If the boundary starts at an assistant tool-call message, all of that message's corresponding contiguous tool results remain in the retained tail.
6. Non-context metadata adjacent to the retained entry remains durable but does not affect the token budget.
7. The summary source is the previous narrative summary, if present, plus exact active messages before the retained boundary.
8. A split inside one user turn is allowed. The discarded prefix is summarized with an explicit instruction that the exact recent suffix remains; Zi uses one iterative summary stream rather than Pi's second turn-prefix request.
9. File operations are accumulated from prior `CompactionDetails` and successfully completed discarded Read/Write/Edit call-result pairs, then bounded and sorted. Attempted failures do not become claimed file operations.
10. If no exact message would be summarized, return `nothing_to_compact`; excluding an overflow failure alone is not useful compaction.
11. If no safe retained entry exists, return `nothing_to_compact`; compaction never creates a context ending only in an unusable assistant/tool fragment.

The plan contains IDs and immutable message references, not copied mutable journal state. Commit revalidates that the journal leaf and active model still match the admitted plan.

# 8. Summary generation

## Prompt

Use Pi's concise checkpoint sections as the baseline:

```text
## Goal
## Constraints & Preferences
## Progress
### Done
### In Progress
### Blocked
## Key Decisions
## Next Steps
## Critical Context
```

The fixed system instruction says to summarize rather than continue, preserve exact paths/symbols/errors, and output only the checkpoint. A repeated compaction receives the prior narrative in a separate `<previous-summary>` block and is told to update it rather than discard it. `/compact <focus>` adds a bounded `Additional focus` instruction.

The summary request:

- uses the selected model snapshot;
- uses the session's effective thinking level when supported;
- goes through the same `Agent.streamFn` and credential owner as normal requests;
- includes no tools;
- is not emitted as assistant transcript events;
- does not enter the provider-context accounting for the coding turn;
- is cancelled by the operation's signal and the 120-second total deadline.

## Serialization

Serialize the summary source as labelled text instead of replaying it as live chat. This reduces continuation/tool-use confusion.

Rules:

- user, assistant, thinking, tool-call, and tool-result content have explicit labels;
- image content becomes `[image: <mime>]`;
- each tool result is capped at 2,000 characters with an explicit omitted-character count;
- malformed tool arguments are represented by bounded JSON rather than throwing;
- provider error text is bounded;
- secret authentication input never exists in the session journal and therefore cannot enter compaction;
- file lists are not entrusted to the model; they are appended deterministically from `CompactionDetails` when constructing the active summary message.

## Chunking

Compaction must not silently discard source entries when its own request is too large.

1. Derive the request-input budget from the selected model window, `summaryMaxTokens`, and fixed prompt overhead.
2. Partition serialized source at message boundaries.
3. Split a single oversized textual item at UTF-8 boundaries with labelled part markers.
4. Process chunks sequentially. The first chunk creates or updates the prior summary; each later chunk updates the result from the previous chunk.
5. Admit at most eight chunks for the whole operation.
6. If the provider reports context overflow for a chunk, split that chunk into smaller parts without resending the identical payload, subject to the same eight-chunk total.
7. If the source still cannot fit, fail without a marker or active-context mutation.

This is the useful part of Grok Build's input ladder without its silent verbatim-to-lossy history dropping.

## Validation

For every model response:

- stop reason `error` or `aborted` fails the operation;
- concatenate text-channel content only; thinking is not summary content;
- trim surrounding whitespace;
- reject empty output;
- reject output above 128 KiB;
- reject a result containing no visible text after normalization;
- do not parse or persist tool calls from a compaction response.

Before commit, estimate the old and candidate active messages with the same local estimator. Reject the candidate when `estimatedTokensAfter >= estimatedTokensBefore`; provider-anchored `tokensBefore` is retained for diagnostics but is not used as the other side of this reduction comparison. Automatic compaction also rejects a candidate whose retained boundary or summary would create an invalid provider sequence.

The original compaction milestone did not retry transient network/provider failures. The later retry milestone now wraps each summary sample with the bounded session policy while retaining this operation's eight-chunk and 120-second limits. Empty output, deterministic overflow, authentication failure, and cancellation are never retried unchanged. See [`retry-implementation-spec.md`](retry-implementation-spec.md).

# 9. Transaction and run integration

## Prepare, sample, validate, commit

Every manual or automatic operation follows one path:

```text
admit operation and record state
  -> snapshot model, settings, journal leaf, active entries, and accounting
  -> prepare pure plan
  -> generate bounded summary
  -> validate output and projected reduction
  -> revalidate operation identity, journal leaf, model, and cancellation
  -> append compaction marker durably
  -> derive active messages from SessionManager
  -> assign agent.state.messages
  -> update context accounting
  -> emit committed entry and completed compaction event
```

No summary, message replacement, file list, or context count becomes authoritative before the append commits.

A stale completion is dropped. It cannot append a marker, assign agent state, emit success, or resume a provider turn.

## Initial provider boundary

Before `agent.prompt()`:

1. expand the prompt template/skill exactly once;
2. estimate the current active context plus prospective user text/images;
3. if over threshold and automatic compaction is enabled, compact existing active history;
4. then admit the user message to Pi agent core.

The prospective user input is not persisted before compaction. If existing history has nothing removable, continue normally and let provider overflow handling report an oversized standalone prompt.

## Tool-loop and post-response boundary

Install Pi agent core's `prepareNextTurnWithContext` callback during `createAgentSession()`.

After each completed assistant/tool batch:

1. all emitted messages have already been appended by `AgentSession`;
2. compute usage from the callback's exact next-turn context;
3. compact when the threshold is crossed;
4. on success, return an `AgentLoopTurnUpdate` whose context contains the newly derived active messages and unchanged system prompt/tools;
5. on automatic failure, emit the failure, suppress further threshold attempts for that run, and return the original callback context;
6. queued steering/follow-up delivery then continues through Pi's normal drain boundary.

The callback catches all compaction failures. It never turns an optional maintenance failure into a malformed Pi agent event sequence.

## Overflow recovery

When a provider assistant message satisfies `pi-ai`'s `isContextOverflow(message, contextWindow)`:

1. persist the assistant failure normally and remember its committed entry ID;
2. if automatic compaction is disabled or this run already used overflow recovery, stop with the provider failure visible;
3. prepare compaction with that one failure entry excluded from replacement context;
4. commit the marker;
5. verify the new active context ends in a user or tool-result message accepted by `agent.continue()`;
6. call `agent.continue()` exactly once;
7. if the retry overflows, do not compact/retry again in that run;
8. emit a bounded error directing the user to `/compact`, a larger-context model, or a new session.

The failed response remains in `SessionManager.entries()` and JSON event history. `activeMessages()` omits it because the marker names it explicitly.

# 10. Public API and events

## API

Add narrow session APIs:

```ts
export interface CompactionResult {
  readonly reason: CompactionReason
  readonly summary: string
  readonly firstKeptEntryId: string
  readonly tokensBefore: number
  readonly estimatedTokensAfter: number
  readonly compactedEntries: number
  readonly details: CompactionDetails
}

export type CompactionStatus =
  | { readonly type: "idle" }
  | { readonly type: "running"; readonly operationId: number; readonly reason: CompactionReason }

class AgentSession {
  get compactionStatus(): CompactionStatus
  get contextUsage(): ContextUsage
  compact(customInstructions?: string): Promise<CompactionResult>
  setCompactionEnabled(enabled: boolean, scope: SettingsScope): CompactionEnabledMutation
}
```

Do not expose `prepareCompaction()`, abort controllers, model stream details, or a mutable compaction state object through `AgentSession`.

Existing interruption methods own cancellation:

- run interruption aborts automatic compaction and the provider run;
- manual compaction cancellation is admitted by `abort()`/`takeQueuedInputsAndAbort()` without inventing queued-input state;
- terminal shutdown discards queued input, cancels compaction, restores the terminal, and then joins settlement as today.

## Events

Add closed lifecycle events:

```ts
type CompactionOutcome =
  | { readonly type: "completed"; readonly result: CompactionResult }
  | { readonly type: "cancelled" }
  | { readonly type: "failed"; readonly message: string }

type AgentSessionEvent =
  | { readonly type: "compaction_start"; readonly operationId: number; readonly reason: CompactionReason }
  | {
      readonly type: "compaction_end"
      readonly operationId: number
      readonly reason: CompactionReason
      readonly outcome: CompactionOutcome
    }
  | { readonly type: "compaction_enabled_changed"; readonly enabled: boolean }
  | /* existing events */
```

The committed marker also produces the existing `entry_appended` event. Observers cannot turn a committed marker into a failed operation; post-commit observer failures are isolated like other durable session changes.

# 11. Settings

Use flat Zi-owned settings so global/project layering stays shallow and obvious:

```ts
export interface AgentSettings {
  // existing fields
  compactionEnabled: boolean
  compactionReserveTokens: number
  compactionKeepRecentTokens: number
}
```

Defaults:

```text
compactionEnabled          true
compactionReserveTokens    16384
compactionKeepRecentTokens 20000
```

Persisted values must be integers. `enabled` is a boolean; token values are between 1 and 1,000,000. Model-relative clamping still applies at runtime.

The first TUI settings slice exposes only `compactionEnabled` as `On | Off`, with explicit global/project scope and shadowing behavior. Reserve and retained-tail token values are config-file settings in the first milestone; no numeric editor is added to `PickerStack` without broader numeric-setting pressure.

A setting mutation persists first, derives the effective layered value, then emits `compaction_enabled_changed`. A failed write leaves live behavior unchanged. Changes during a run affect the next automatic admission boundary; they do not cancel an already admitted operation.

# 12. TUI behavior

## Command

Add the coding-agent descriptor:

```text
/compact [focus]  Compact context, optionally preserving a specified focus
```

`SlashController` emits:

```ts
{ readonly type: "compact"; readonly instructions: string }
```

`PromptStore` owns a `compacting` workflow with operation/session identity. It invokes `AgentSession.compact()`, rejects stale completion after session replacement, and reports:

- success: `Compacted 123k → ~24k context tokens.`
- cancellation: no error;
- failure: the bounded coding-agent message.

The composer remains the only input/focus owner. The command argument never enters the normal user transcript.

## Status and cancellation

`PromptView` derives its working row from session state:

```text
Working…
Compacting…
Cancelling…
```

Automatic compaction remains part of a running turn, so the composer can still collect bounded steering/follow-up input. Manual compaction blocks prompt submission until it settles. Escape routes through the existing semantic interrupt action; no compaction-specific chord is hard-coded.

## Context usage

Append bounded context information to the composer bottom title:

```text
model-id (thinking) · 42% ctx
model-id · ~18% ctx
```

`measured` omits `~`; `estimated` includes it. Unavailable usage omits the context suffix rather than showing a false zero.

The title reads `AgentSession.contextUsage` directly on prompt revisions. No frontend token counter or copied usage atom is introduced.

## Transcript replacement

A completed compaction event explicitly invalidates the transcript projection even if message count happens not to decrease.

`TranscriptView`:

1. clears native selection before destroying selected rows;
2. resets retained message/tool indexes from `AgentSession.messages`;
3. renders the `compactionSummary` panel followed by the exact retained tail;
4. discards transient tool views that no longer exist in active context;
5. preserves the existing 200-message and 64-tool projection bounds;
6. rejects callbacks from a destroyed/replaced screen;
7. returns navigation to follow-tail after the authoritative history replacement.

The TUI does not parse the summary, inspect journal markers, calculate retained boundaries, or read old session files.

# 13. Print and JSON modes

Automatic compaction remains inside `AgentSession`, so print and future RPC modes receive the same context behavior without importing TUI policy.

Text print mode writes only the final assistant text as today; compaction status is not mixed into stdout.

JSON mode emits ordered session events, including `compaction_start`, committed `entry_appended`, and `compaction_end`. Every payload is already bounded. A failed/cancelled operation emits no compaction entry.

# 14. Failure, cancellation, and suppression

| Situation                          | Required behavior                                                               |
| ---------------------------------- | ------------------------------------------------------------------------------- |
| Nothing removable                  | Manual rejects with `Nothing to compact`; automatic no-ops                      |
| Missing/unknown model window       | Manual explains unsupported accounting; automatic disabled                      |
| Authentication failure             | No marker; manual rejects; automatic fails visibly and suppresses this run      |
| Empty/oversized summary            | No marker; same failure handling                                                |
| Non-reducing summary               | No marker; same failure handling                                                |
| Compaction request overflow        | Split the source; never retry identical input; fail after chunk bound           |
| Transient provider/network failure | Retry the same summary sample within the owning operation's bounded policy      |
| Journal append failure             | No in-memory leaf or active-context mutation                                    |
| Escape during manual compaction    | Abort request, emit cancelled, return idle                                      |
| Escape during automatic compaction | Abort request and active run, preserve normal queue-restoration semantics       |
| Shutdown/disposal                  | Abort, prevent stale commit, join through existing bounded settlement           |
| Session replacement attempt        | Reject while compaction/run is active                                           |
| Threshold auto failure             | Continue original run context and suppress more threshold attempts for that run |
| Second overflow in one run         | Do not compact again; surface actionable failure                                |
| Observer throws after commit       | Keep committed state; isolate observer failure                                  |

Suppression is run-local in the first milestone. Grok Build's persistent reason-scoped suppression is valuable at its scale, but Zi should not persist a failure policy before repeated real-world failures demonstrate the need.

# 15. Structural bounds

The implementation must prove:

- no more than one compaction operation per session at a time;
- no more than four automatic compactions and one overflow recovery per run;
- no more than eight summary chunks per operation;
- no compaction operation longer than ten minutes;
- no summary or custom instruction above its byte bound;
- no unbounded file-operation arrays;
- no context beginning at an orphan tool result;
- no duplicate prior marker in active context;
- no old provider usage treated as measured after a marker;
- no active-context mutation before durable append;
- no stale operation commit after cancellation, replacement, or disposal;
- no TUI-owned summary or token timeline;
- no independent scheduler, polling loop, or background prefire task; the single owner-scoped operation deadline is allowed.

# 16. Acceptance tests

## Pure compaction

Add `packages/coding-agent/test/compaction.test.ts` covering:

- provider usage calculation and trailing estimates;
- image, thinking, tool argument, tool result, and summary estimates;
- model-relative reserve/keep clamping;
- threshold boundary behavior;
- user and assistant cut points;
- tool-result boundary safety, including parallel tool calls;
- a split large turn;
- repeated compaction carrying the previous summary;
- no duplicate old marker in projected context;
- deterministic file lists and omission counts;
- bounded serialization and UTF-8 item splitting;
- eight-chunk refusal;
- custom focus bounds;
- empty, oversized, non-text, and non-reducing summary rejection.

## Session manager

Extend `packages/coding-agent/test/session-manager.test.ts` with:

- compaction entry round-trip;
- active messages after one and multiple markers;
- a retained boundary physically before an older marker;
- excluded overflow failure durability versus active omission;
- invalid/missing boundary rejection;
- invalid failure-reference rejection;
- torn final compaction line recovery;
- completed malformed marker rejection;
- append failure leaving entries and leaf unchanged;
- in-memory sessions using the same projection.

## Agent session

Add `packages/coding-agent/test/agent-session-compaction.test.ts` covering:

- manual success and result fields;
- manual busy/model/auth admission failures;
- manual cancellation and settlement;
- no-work behavior;
- selected model, thinking level, credential owner, and stream function use;
- pre-prompt automatic compaction including prospective input;
- threshold compaction after a final assistant response;
- tool-result growth compacted before the next model request;
- queued steering/follow-up continuing after replacement;
- automatic failure continuing with original context and suppressing repeats;
- one overflow compact-and-continue;
- durable but context-excluded overflow failure;
- second overflow stopping without a loop;
- disabled automatic compaction;
- model-window change on the next provider boundary;
- measured → estimated → measured context usage;
- persistent and in-memory sessions;
- stale completion after abort/dispose;
- replacement rejection during compaction;
- ordered start, entry, and end events;
- listener failure after durable commit.

Use the faux provider/stream harness. No acceptance property depends on live APIs or wall-clock timing.

## TUI

Add or extend terminal tests for:

- `/compact` completion and exact parsing;
- focus argument forwarding without a user transcript entry;
- `Compacting…` and cancellation presentation;
- global/project auto-compaction setting and shadowing;
- measured and estimated context title text;
- summary panel and retained-tail rebuild;
- selection cleanup and follow-tail reset;
- queued input visible during automatic compaction;
- stale workflow completion after session replacement;
- constrained-width frames;
- transcript/message/tool bounds after replacement.

## Print/JSON

Verify:

- text mode emits no compaction status prose;
- JSON mode preserves start → entry → end ordering;
- failure/cancellation emits no marker;
- automatic compaction affects the next provider context in non-terminal mode.

# 17. Implementation sequence

## Slice 1 — journal and messages

- add `messages.ts` and the summary-message declaration/converter;
- add the validated compaction entry;
- make append ordering transactional;
- implement active-entry/message projection;
- restore single/repeated markers with behavior tests.

No provider call or TUI change lands in this slice.

## Slice 2 — accounting and planning

- add context usage types and incremental accounting;
- port/adapt Pi's estimators, cut planning, serialization, iterative prompt, and file tracking;
- add model-relative budgets, chunking, and pure validation tests.

## Slice 3 — manual transaction

- add explicit manual compaction activity;
- sample through the existing model stream owner;
- validate, append, replace active messages, emit lifecycle events, cancel, and settle;
- expose `compact()` and `compactionStatus`.

## Slice 4 — automatic boundaries and overflow

- install `prepareNextTurnWithContext`;
- add prospective pre-prompt checks;
- integrate threshold compaction with queue continuation;
- add overflow exclusion and one `agent.continue()` recovery;
- add per-run bounds/suppression.

## Slice 5 — settings and terminal behavior

- add flat settings and mutation;
- add `/compact` intent/workflow;
- render status, context usage, feedback, and authoritative transcript reset;
- fix constrained and cancellation fixtures.

## Slice 6 — modes and evidence

- add print/JSON behavior tests;
- update architecture, parity evidence, and ADRs from proposed to accepted/implemented only after all acceptance tests pass;
- run package and repository checks.

# 18. Completion criteria

The effort is complete only when:

1. a long tool-using run compacts before its next provider request without an orphan tool result;
2. overflow can recover exactly once without hiding the failed durable event;
3. restart reconstructs the same active context from the append-only journal;
4. repeated compaction injects one latest summary, not a chain of old markers;
5. cancellation or persistence failure cannot partially replace context;
6. automatic compaction works identically in interactive, print, and future client use of `AgentSession`;
7. the TUI derives status and usage without owning policy or copied history;
8. every queue, chunk, output, metadata list, operation, and retained terminal projection is bounded;
9. all structural and behavior tests above pass;
10. `docs/parity-roadmap.md` records concrete test evidence before marking context usage/compaction complete.
