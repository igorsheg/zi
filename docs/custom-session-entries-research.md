# Custom session entries and custom messages

Status: implemented, 2026-07-28

This note characterizes Pi Mono's durable custom-entry and custom-message model, compares it with Zi's current surface, and proposes a Pi-aligned implementation path that preserves and deepens Zi's ownership rules.

The review was checked against Zi `95ce3444`, Pi Mono `b6fb91e5`, and Pi's `a6f720e6` custom-message compaction fix. The last source is important provenance: Pi duplicated entry-to-context rules inside compaction, omitted top-level custom messages from budgeting, and later fixed the bug by routing compaction through its canonical `sessionEntryToContextMessages()` projector. Zi should remove the analogous duplication before adding another context-visible entry kind.

Pi remains the coding-agent architecture and behavior reference ([`reference-pins.md`](reference-pins.md), [`building-block-strategy.md`](building-block-strategy.md)). Extension infrastructure already lists custom messages and durable entries as deferred non-goals ([`extension-system-infrastructure-implementation-spec.md`](extension-system-infrastructure-implementation-spec.md) §3). [ADR 0023](adr/0023-session-journal-separates-custom-state-and-custom-messages.md) now accepts the split and its ownership rules. Compaction stays an append-only first-party marker ([ADR 0015](adr/0015-context-compaction-is-an-append-only-session-transaction.md)); it is a consumer of this substrate, not a substitute for it.

## Outcomes

A complete Zi implementation should provide:

1. one first reference use case where a durable `compaction` marker projects into provider context and exactly one transcript item without a client-authored row;
2. one durable journal entry for extension-private session state that never enters provider context;
3. one durable journal entry for conversation side-channel messages that projects into runtime `role: "custom"` messages;
4. Pi-compatible `display` semantics for custom messages: transcript visibility only, never context exclusion;
5. one `AgentSession` admission API for append, turn-trigger, steer, follow-up, and next-turn delivery;
6. one `AgentSession` admission API for appending custom state entries;
7. one bounded full-journal custom-state projection so an isolated extension worker can restore state without receiving `SessionManager`;
8. one canonical entry-to-context projector shared by live context, restore, and compaction;
9. coding-agent-owned context and presentation projections that restore identically after resume and compaction;
10. format-2 image-blob ownership for images inside custom messages;
11. default transcript rendering for displayed custom messages, without requiring extension UI code;
12. concrete source-attributed extension protocol operations for reading entries, appending entries, and sending messages;
13. hard per-value, aggregate, count, queue, and protocol bounds;
14. behavior tests for durability, restore, context inclusion, hidden display, compaction folding, nested worker requests, and client rebuild.

Optional extension renderer registration by `customType` remains a later capability.

## Non-goals

This capability does not require, in the first cut:

- Pi source-compatible extension modules;
- direct OpenTUI component factories from extensions;
- branch labels, session-name entries, or tree navigation;
- replacing the first-party `compaction` marker with a custom message;
- TUI-invented transcript rows on `compaction_end`;
- a generic command bus or frontend store for extension state;
- hidden-context injection as a first-party product feature beyond the Pi-compatible `display: false` path;
- package install or marketplace distribution.

## Recommendation

Align Zi with Pi's split:

| Kind                   | Journal                  | Runtime                     | Provider context | Transcript                |
| ---------------------- | ------------------------ | --------------------------- | ---------------- | ------------------------- |
| Ephemeral notice       | none                     | client feedback / status    | no               | no                        |
| Custom state entry     | `type: "custom"`         | journal entry only          | no               | only if a renderer exists |
| Custom message         | `type: "custom_message"` | `role: "custom"`            | yes, always      | iff `display: true`       |
| First-party compaction | `type: "compaction"`     | `role: "compactionSummary"` | yes, projected   | yes, projected            |

### Normative three-axis model

Durability, provider context, and presentation are independent decisions owned by different projections:

| Value                    | Session JSONL | Provider context  | Presentation                                  |
| ------------------------ | ------------- | ----------------- | --------------------------------------------- |
| Ephemeral notice         | absent        | absent            | current client only                           |
| Custom state entry       | present       | absent            | absent by default; active-path renderer later |
| Displayed custom message | present       | present           | present                                       |
| Hidden custom message    | present       | present           | absent                                        |
| Context-excluded Bash    | present       | absent            | present                                       |
| Compaction marker        | present       | projected summary | projected summary                             |

Here, **Session JSONL** means the durable session journal, not JSON output mode.

The ownership rule is:

- `SessionManager` decides and validates what is durable;
- the canonical context projection decides what enters `Agent.state.messages` and therefore provider conversion;
- `presentationMessages()` decides what clients may render or page;
- client-local feedback never enters `SessionManager`;
- `display` controls presentation only and never changes context inclusion.

No client or extension host may infer one axis from another. Every entry kind must have behavior tests for all three axes after live append, resume, and compaction.

### First real use case: the compaction transcript item

Compaction is the first reference-client proof of this model, but it remains a dedicated first-party entry rather than a custom message:

```text
session journal: type "compaction"
  -> provider context: role "compactionSummary"
  -> presentation: one dedicated [compaction] transcript item

compaction_start / compaction_end
  -> ephemeral progress, cancellation, and failure feedback only
```

A successful live compaction rebuilds presentation from the committed journal marker. The TUI must not append another summary from `compaction_end`. Resume projects the same marker into the same item, while failed or cancelled compaction creates no item. This deliberately keeps the three axes visible in one small, first-party example before extension-defined kinds exercise them.

The first-use-case acceptance is:

1. one successful compaction appends exactly one `compaction` journal row;
2. active provider context contains exactly one projected compaction summary plus the retained exact tail;
3. presentation contains exactly one dedicated compaction item;
4. live completion and resume produce the same item and order;
5. `compaction_end` may update ephemeral status but cannot create transcript identity;
6. failed and cancelled compactions append and render nothing;
7. no `custom` or `custom_message` row participates in this path.

Ship in this order:

1. **Lock the compaction transcript item** as the first three-axis acceptance case.
2. **Deepen the session projection module** so live context, restore, and compaction consume one entry-to-message rule.
3. **Journal + projections** for `custom` and `custom_message`, including custom images, aggregate state bounds, and pending-session durability.
4. **`AgentSession` APIs** that own closed delivery intents, persistence, bounded queues, and events.
5. **Default TUI/RPC/JSON presentation** from authoritative projections.
6. **Extension session operations** (`getSessionEntries`, `appendEntry`, `sendMessage`) over concrete bidirectional protocol frames.
7. **Optional renderers and `session_compact` producers** after the durable path is proven.

Do not collapse state entries and conversation messages into one type. Do not let the TUI or `ExtensionHost` mutate the journal directly. Do not teach `display: false` as "local only"; in Pi it means "hidden in the transcript, still sent to the model."

## Review findings that change the initial plan

### 1. Isolated workers need a read path, not only `appendEntry`

Pi extensions restore state by synchronously scanning `ctx.sessionManager.getEntries()`. Zi deliberately does not expose `SessionManager` to its extension worker. Adding only `appendEntry` would therefore create write-only state that cannot satisfy the durable-state golden path.

Zi needs a narrow asynchronous operation such as `getSessionEntries(customType)` backed by a bounded `SessionManager.customEntries(customType)` projection. It must read the complete append-only journal, including custom state folded out of the resident tail by compaction, without materializing all cold messages.

### 2. This is the first real pressure for nested bidirectional extension requests

A lifecycle handler must be able to read state, and an extension tool must be able to append state or send a message while the host is awaiting that same worker's lifecycle/tool result. A one-way notification cannot report persistence or capacity failure. A snapshot stuffed into `session_start` becomes stale on reload and either exceeds the 4 MiB frame bound or forces arbitrary loss.

The extension protocol should therefore gain three concrete worker-to-host requests and correlated results. This closes the unchecked "nested bidirectional requests cannot deadlock" item in the extension infrastructure spec under demonstrated product pressure. It must not become JSON-RPC or a generic command bus.

### 3. Custom messages share format-2 image ownership

`custom_message.content` admits text and images. Zi's format-2 journal externalizes images only inside `type: "message"` today. A correct implementation must externalize, verify, hydrate, account, roll back, and delete custom-message image blobs through the same `SessionManager` transaction. Treating custom content as plain JSON would regress the 64 MiB resumability invariant.

### 4. "Durable" must flush a pending session

Zi delays creating a persistent journal until the first assistant message. An idle `appendCustomEntry()` or displayed `sendCustomMessage()` before any assistant would currently exist only in memory. The first `custom` or `custom_message` append must flush the pending header and metadata just as the first assistant does. Model/thinking metadata alone should continue not to create an abandoned session.

### 5. Compaction currently duplicates context-entry policy

`SessionManager.projectSessionEntries()` and `compaction.ts::projectedExactEntries()` independently decide which journal entries produce context. Adding `custom_message` to only one would reproduce Pi's `a6f720e6` bug. Introduce one canonical `sessionEntryToContextMessage()`/context-entry projection and make both modules consume it before adding the new kind.

### 6. Pi's option bag admits contradictory delivery states

`triggerTurn: true` plus `deliverAs: "nextTurn"`, `deliverAs: "steer"` while idle, and `triggerTurn` while streaming are combinations Pi ignores contextually. `AgentSession` should instead receive a closed delivery intent:

```ts
type CustomMessageDelivery =
  | { readonly type: "append" }
  | { readonly type: "trigger_turn" }
  | { readonly type: "steer" }
  | { readonly type: "follow_up" }
  | { readonly type: "next_turn" }
```

The extension API may offer a Pi-shaped adapter if copyability is valuable, but it must validate and translate into this union at the process boundary. Zi does not need source compatibility with Pi's accidental combinations.

### 7. Deterministic aggregate bounds are better than a clock-based append rate

A token bucket would add mutable time policy without protecting restore or protocol frames. Bound per-entry bytes, aggregate custom-state bytes, aggregate custom-state count, queued deliveries, and in-flight worker requests instead. These are deterministic, restorable, and directly protect the owning resources.

# 1. Pi model

Inspected sources under `badlogic/pi-mono` / `earendil-works/pi-mono` coding-agent:

- `packages/coding-agent/src/core/session-manager.ts`
- `packages/coding-agent/src/core/messages.ts`
- `packages/coding-agent/src/core/agent-session.ts`
- `packages/coding-agent/src/core/extensions/{types,loader,runner}.ts`
- `packages/coding-agent/src/modes/interactive/interactive-mode.ts`
- `packages/coding-agent/src/modes/interactive/components/{custom-message,compaction-summary-message}.ts`
- examples: `entry-renderer.ts`, `message-renderer.ts`, `plan-mode/`, `tic-tac-toe.ts`, `file-trigger.ts`

Also recorded in [`pi-mono-extension-api-reference.md`](pi-mono-extension-api-reference.md).

## 1.1 Three layers

### Ephemeral UI

`ctx.ui.notify(...)`, status text, footer/header widgets.

- not written to JSONL
- not in provider context
- not a transcript identity
- lifetime is the current process/screen

Zi already has the analogous built-in workflow-notice path. The finite compaction-success notice (`Compacted 123k → ~24k…`) belongs here unless the product explicitly wants a durable row.

### `type: "custom"` — durable state entry

```ts
interface CustomEntry<T = unknown> {
  type: "custom"
  customType: string
  data?: T
  // id, parentId, timestamp
}
```

API: `pi.appendEntry(customType, data)`

Pi documents this as extension state persistence across reload. Extensions scan the journal for their `customType` and reconstruct internal state.

| Axis               | Behavior                                                 |
| ------------------ | -------------------------------------------------------- |
| Durable            | yes                                                      |
| Provider context   | no                                                       |
| Agent message list | no                                                       |
| Transcript         | only through `registerEntryRenderer(customType)`         |
| Typical uses       | plan-mode state, tool config, game save, preset snapshot |

### `type: "custom_message"` — durable conversation side-channel

```ts
interface CustomMessageEntry<T = unknown> {
  type: "custom_message"
  customType: string
  content: string | (TextContent | ImageContent)[]
  details?: T
  display: boolean
}
```

Projects to:

```ts
interface CustomMessage<T = unknown> {
  role: "custom"
  customType: string
  content: string | (TextContent | ImageContent)[]
  display: boolean
  details?: T
  timestamp: number
}
```

API: `pi.sendMessage({ customType, content, display, details }, options?)`

| Axis             | Behavior                                                                   |
| ---------------- | -------------------------------------------------------------------------- |
| Durable          | yes, as `custom_message`, not as a plain `message`                         |
| Provider context | **always**, via `convertToLlm` as a synthetic user message                 |
| `details`        | durable and renderer-visible; not LLM content                              |
| Transcript       | `display: true` shows; `display: false` hides                              |
| Delivery         | idle append, `triggerTurn`, or streaming `steer` / `followUp` / `nextTurn` |

Critical Pi semantics:

```text
display: false  ≠  excludeFromContext
display: false  =  hidden in TUI, still injected into the model
```

Plan-mode relies on this for hidden context blocks (`display: false`) beside visible status cards (`display: true`).

### First-party markers

`compaction` and `branch_summary` are not custom messages. They are top-level journal types that project into synthetic roles. The TUI styles compaction similarly to custom panels, but persistence and folding remain first-party.

Bash local execution is a third pattern: durable message with `excludeFromContext` for "show in transcript, omit from model." That flag exists on bash, not on custom messages.

## 1.2 Pi projection pipeline

```text
JSONL leaf path
  -> buildContextEntries()          // compaction-aware active path
  -> sessionEntryToContextMessages()
       message        -> AgentMessage
       custom_message -> role: "custom"
       compaction     -> role: "compactionSummary"
       custom         -> []
  -> agent.state.messages
  -> convertToLlm()
       custom            -> user content always
       compactionSummary -> wrapped checkpoint user message
       bash+exclude      -> dropped
  -> TUI / RPC
       custom.display ? render : skip
       custom entry     ? entryRenderer? : skip
```

Persistence rules in `AgentSession`:

- on `message_end`, `role: "custom"` becomes `appendCustomMessageEntry(...)`
- ordinary user/assistant/toolResult become `appendMessage(...)`
- bash, compaction summary, and branch summary are persisted on their own paths
- `appendEntry` emits `entry_appended` for plain custom state entries

Interactive rebuild after compaction walks compaction-aware entries, not a client-side shadow transcript. Plain custom entries on the active path can reappear through entry renderers; older folded entries remain in the full journal only.

## 1.3 Extension surface

```ts
pi.sendMessage(message, options?)
pi.appendEntry(customType, data?)
pi.registerMessageRenderer(customType, renderer)
pi.registerEntryRenderer(customType, renderer)
pi.on("session_compact", handler)
```

Default custom-message UI is a labelled panel (`[customType]` + markdown body). A registered message renderer may replace that chrome. Entry renderers are optional; without one, state entries stay invisible.

## 1.4 Worked examples

| Example                         | Mechanism                          | Why                                    |
| ------------------------------- | ---------------------------------- | -------------------------------------- |
| `plan-mode` hidden instructions | `sendMessage(..., display: false)` | model sees policy text; user does not  |
| `plan-mode` todo card           | `sendMessage(..., display: true)`  | user and model both see progress       |
| `plan-mode` mode flag           | `appendEntry("plan-mode", data)`   | reloadable state, not conversation     |
| `tic-tac-toe` move              | custom message + turn delivery     | conversation-shaped event              |
| `tic-tac-toe` / `snake` save    | `appendEntry`                      | private durable state                  |
| `file-trigger`                  | custom message + turn              | external event becomes prompt material |
| compaction UI                   | first-party `compaction` marker    | not a custom message                   |

# 2. Current Zi surface

## 2.1 Present

| Capability                              | Location                                      | Notes                                                           |
| --------------------------------------- | --------------------------------------------- | --------------------------------------------------------------- |
| Append-only journal                     | `SessionManager`                              | message, model_change, thinking_level_change, retry, compaction |
| Context vs presentation projections     | `activeMessages()` / `presentationMessages()` | already separates provider and transcript concerns              |
| `role: "custom"` validation             | session message schema                        | accepted inside `type: "message"`                               |
| `convertToLlm` custom → user            | `messages.ts`                                 | always includes custom content                                  |
| TUI custom panel when `display: true`   | `transcript/message-view.ts`                  | no `customType` label chrome yet                                |
| bash `excludeFromContext`               | context projection                            | presentation retains it                                         |
| Compaction marker → `compactionSummary` | session projection + TUI panel                | durable transcript item already exists                          |
| Ephemeral compaction notice             | `BuiltInNotificationPresenter`                | not JSONL                                                       |
| Extension host lifecycle/tools          | coding-agent extensions                       | custom messages/entries explicitly deferred                     |

## 2.2 Missing for Pi alignment

| Gap                                                                | Impact                                                                                        |
| ------------------------------------------------------------------ | --------------------------------------------------------------------------------------------- |
| No `type: "custom"` journal entry                                  | cannot store non-context extension state in-session                                           |
| No `type: "custom_message"` journal entry                          | customs can only be smuggled as ordinary messages                                             |
| No `AgentSession.sendCustomMessage`                                | no delivery/owner API                                                                         |
| No `AgentSession.appendCustomEntry`                                | no state-entry owner API                                                                      |
| No event path for plain custom entries in transcript rebuild       | TUI only reads presentation messages today                                                    |
| No extension bindings                                              | workers cannot call the substrate                                                             |
| No bounded custom-state read projection                            | workers could append state but could not restore it without exposing private `SessionManager` |
| Host/worker protocol has no worker-initiated correlated operations | lifecycle handlers and tools cannot safely await session mutations while the host awaits them |
| Pending sessions flush only on the first assistant                 | pre-turn custom state/messages would not actually be durable                                  |
| Format-2 image handling covers only `type: "message"`              | custom-message images would bypass blob ownership and aggregate storage accounting            |
| Compaction duplicates context-entry filtering                      | a new context-visible entry can be restored but omitted from budgeting or cut-point policy    |
| No message/entry renderer registry in product path                 | default rendering only                                                                        |
| Compaction does not emit extension `session_compact`               | extensions cannot react/produce follow-on entries yet                                         |

## 2.3 Important mismatch to resolve deliberately

Zi can already persist:

```ts
sessionManager.appendMessage({ role: "custom", customType: "x", content: "...", display: true, timestamp: Date.now() })
```

as a normal `type: "message"` row.

Pi deliberately does **not** do that. Custom messages are top-level `custom_message` entries so they are easy to find, distinct from LLM turns, and restored through the same projector as compaction/branch summaries.

**Alignment decision:** stop treating custom conversation side-channels as ordinary message entries. Add `custom_message` and `custom` journal types. Keep reading old `type: "message" + role: "custom"` rows as a legacy representation because released Zi already accepts them, but reject new writes through `appendMessage()` and route every supported producer through `appendCustomMessage()`. Legacy hidden rows must receive the same context/presentation semantics as the new top-level kind.

# 3. Target architecture for Zi

## 3.1 Ownership

```text
SessionManager
  validate and transactionally append journal entries and image blobs
  own the canonical entry -> context message rule
  own context, presentation, and bounded full-journal custom-state projections
  bound per-entry and aggregate custom state

AgentSession
  admit sendCustomMessage / appendCustomEntry / getCustomEntries
  translate closed delivery intents into append, turn, or bounded queue transitions
  emit committed entry and message lifecycle events
  keep provider context synchronized only for context-visible additions

ExtensionHost
  correlate concrete worker session operations
  attribute each request to one loaded extension source
  reject stale generations and forward only admitted operations to AgentSession
  never receive SessionManager or mutate the journal directly

Extension worker
  own pending operation promises and extension JavaScript state
  allow correlated session results while a lifecycle handler or tool is running

convertToLlm
  convert context-included runtime messages only

Clients (TUI, print, RPC)
  render authoritative projections and ordered events
  keep ephemeral notices local
  never append journal rows for custom kinds

Optional renderers later
  register bounded declarative presentation by customType
  never construct arbitrary OpenTUI renderables in coding-agent
```

This matches ADR guidance: coding-agent owns domain durability and projections; the TUI owns presentation mechanics only.

## 3.2 Journal types

```ts
type SessionJson = null | boolean | number | string | readonly SessionJson[] | { readonly [key: string]: SessionJson }

type CustomEntryData = { readonly type: "custom"; readonly customType: string; readonly data?: SessionJson }

type CustomMessageEntryData = {
  readonly type: "custom_message"
  readonly customType: string
  readonly content: string | readonly (TextContent | ImageContent)[]
  readonly display: boolean
  readonly details?: SessionJson
}
```

Recommended initial bounds:

- `customType`: lowercase ASCII `[a-z][a-z0-9._:/-]*`, at most 128 UTF-8 bytes;
- `data` / `details`: JSON-only, depth at most 32, at most 4096 nodes, at most 256 KiB serialized;
- custom-message content: text/image only, at most 1 MiB serialized before journal mutation;
- complete custom-state history: at most 2048 entries and 2 MiB of serialized entry data per session;
- worker session operations: share the existing 128 pending-request ceiling;
- unknown top-level fields on the two new entry kinds are rejected on restore;
- normal journal and aggregate image-blob limits still apply after these narrower limits.

The 2 MiB custom-state aggregate plus bounded entry envelopes fits beneath the 4 MiB extension protocol frame if a filtered read result reaches its maximum. These values are policy candidates to prove in tests, not an argument for a generic configurable limits object.

## 3.3 Projections

### Context (`activeMessages` / provider)

Include:

- ordinary context-visible messages
- `custom_message` → `role: "custom"`
- latest compaction marker → `compactionSummary`
- future branch summaries if added

Exclude:

- `type: "custom"` state entries
- bash with `excludeFromContext`
- retry-excluded failures per existing policy
- folded pre-compaction history

### Presentation (`presentationMessages` / transcript)

Include:

- ordinary messages, including context-excluded bash
- `custom_message` only when `display: true`
- compaction summary projection
- retry failures that remain presentationally relevant under current policy

Exclude:

- `custom_message` with `display: false`
- plain `custom` state entries from the message list

Plain custom state entries are not presentation messages. `SessionManager` should separately retain a bounded full-journal custom-state index because compaction removes cold parsed entries from the resident tail while extensions still need to restore their complete state log. `customEntries(customType)` reads that index without calling `entries()` or hydrating cold messages.

If entry renderers ship later, presentation gains a narrow active-path sequence of presentable entries. Do not render the full state index, subscribe the TUI directly to the journal, or force state entries through `AgentMessage` just to display them.

### Canonical entry projection and LLM conversion

Add one coding-agent projector and use it everywhere that reasons about context:

```ts
sessionEntryToContextMessage(entry): AgentMessage | undefined
```

It maps ordinary context-visible messages, `custom_message`, and first-party summary markers, and excludes custom state, retry markers, model/settings entries, and context-excluded Bash. `SessionManager.activeMessages()`, restore, and `compaction.ts` must consume this rule rather than switch on journal kinds independently.

Keep Pi's LLM conversion behavior:

```ts
case "custom":
  return [{ role: "user", content: normalize(content), timestamp }]
```

`details` never enter `convertToLlm`. A custom message can be a valid compaction cut point and must count toward prospective and retained-token budgets.

## 3.4 AgentSession API and transitions

```ts
type CustomMessageDelivery =
  | { readonly type: "append" }
  | { readonly type: "trigger_turn" }
  | { readonly type: "steer" }
  | { readonly type: "follow_up" }
  | { readonly type: "next_turn" }

type CustomMessageAdmission =
  | { readonly type: "appended"; readonly entry: CustomMessageEntry }
  | { readonly type: "queued"; readonly delivery: "steer" | "follow_up" | "next_turn" }
  | { readonly type: "turn_started"; readonly entry: CustomMessageEntry; readonly settled: Promise<void> }

sendCustomMessage(message: CustomMessageInput, delivery: CustomMessageDelivery): CustomMessageAdmission
appendCustomEntry(customType: string, data?: SessionJson): CustomEntry
getCustomEntries(customType: string): readonly CustomEntry[]
```

Behavioral matrix:

| Session activity                                            | Delivery                  | Effect                                                                 |
| ----------------------------------------------------------- | ------------------------- | ---------------------------------------------------------------------- |
| idle                                                        | `append`                  | commit journal + context/presentation projections; no turn             |
| idle                                                        | `trigger_turn`            | commit first, then start exactly one continuation from the new context |
| running                                                     | `steer`                   | admit into the bounded current-run steering queue                      |
| running                                                     | `follow_up`               | admit into the bounded current-run follow-up queue                     |
| idle or running                                             | `next_turn`               | admit into a bounded next-user-turn queue                              |
| wrong activity for explicit delivery                        | any                       | reject without mutation                                                |
| manual compaction, aborting, committed compaction, disposed | context-mutating delivery | reject without mutation                                                |

`trigger_turn` returns the run settlement in the admission value, but the extension protocol acknowledges the operation after the turn is admitted, not after the provider run settles. Waiting for the whole turn inside a lifecycle handler or extension tool can deadlock when that turn tries to call the same worker.

Persistence and queue rules:

- idle append and trigger-turn commit `custom_message` before publishing events;
- steer/follow-up become durable on the core `message_end` delivery boundary, matching ordinary queued input;
- next-turn messages remain ephemeral until the next user prompt admits the user/custom batch;
- custom and user pending deliveries share the existing 32-entry / 8 MiB owner bounds;
- the pending queue becomes a direct `user | custom` union, while `queuedInputs` continues to expose only restorable user drafts;
- interruption returns user input to the composer and discards undelivered custom queue items; disposal discards both;
- `appendCustomEntry` writes `custom`, emits `entry_appended`, and never mutates provider messages;
- custom state appends are allowed while an extension tool is running but rejected during compaction commit windows so they cannot stale a sampled marker accidentally.

## 3.5 Compaction interaction

Keep compaction as the first-party marker path.

After a successful compact:

1. the journal contains the new `compaction` entry;
2. context and presentation rebuild from the compaction-aware resident path;
3. pre-marker custom messages leave live projections when folded away;
4. post-marker custom messages remain;
5. custom state entries remain available through the bounded full-journal state index even when their parsed resident entry becomes cold;
6. future entry presentation uses only active-path state entries;
7. clients rebuild from authority and do not synthesize a second compaction row.

Optional later alignment with Pi:

- emit `session_compact` to extensions after commit
- an extension may `appendCustomEntry` or `sendCustomMessage` in response
- still no TUI-owned append on `compaction_end`

If the product goal is only "show that compaction happened," improve `compactionSummary` chrome. That does not require the custom-message substrate.

## 3.6 Client presentation

### TUI

Default custom-message item:

- transcript item contract unchanged
- label `[customType]`
- body from text content
- theme path aligned with existing custom panel colors
- `display: false` never creates a retained root

Compaction summary remains its own item kind. It may visually rhyme with custom panels, as in Pi, without sharing the journal type.

### Print / JSON / RPC

- text mode still prints only the final assistant response;
- JSON and RPC expose the two new `entry_appended` variants and displayed custom messages through existing ordered events/pages;
- hidden custom messages remain absent from message pages but their committed journal event is still observable to a trusted process client;
- custom state is model-private, not a credential secret; if a future use requires client-confidential state, it needs a different contract;
- RPC version-1 event types and docs must explicitly admit the new entry variants rather than relying on an accidental internal union widening;
- no terminal renderer is required for correctness.

### Ephemeral notices

Remain client-local:

- compact success toast
- extension `notify`-style warnings once that API exists
- auth/copy/paste notices

## 3.7 Alignment choices where Zi should tighten Pi

These preserve Pi's user-visible model while fitting Zi invariants:

1. **Resolve `display` in coding-agent presentation projection**, not only in the TUI switch. Hidden customs do not appear in `AgentSession.messages`.
2. **Share one entry-to-context projector** between restore, live projection, context accounting, and compaction.
3. **Use a closed delivery union** in `AgentSession`; reject impossible activity/delivery combinations at admission.
4. **Acknowledge extension message sends on admission**, never after a whole triggered turn.
5. **Keep a bounded all-journal custom-state index** rather than exposing `entries()` or retaining all cold messages.
6. **Flush pending persistence** on the first custom state/message transaction.
7. **Route custom images through the session image-blob transaction**.
8. **Do not double-append** compaction UI in the client after rebuild.
9. **Keep extension renderers out of the first slice** if default chrome is enough for parity evidence; register them only when the extension public API expands.

Zi does **not** need Pi's accidental overloads or in-process `SessionManager` exposure. It does need Pi's durable kinds, projection semantics, and observable delivery behavior.

# 4. Potential implementation

## Slice 0 — compaction transcript reference case

Files:

- `packages/coding-agent/src/{session-manager,agent-session}.ts`
- `packages/tui/src/interactive/transcript/message-view.ts`
- coding-agent compaction/session tests and TUI transcript performance tests

Work:

1. preserve the top-level `compaction` marker as the only durable authority;
2. project that marker into both active context and presentation;
3. render one dedicated `[compaction]` transcript item from presentation data;
4. keep `compaction_start` and `compaction_end` limited to progress, cancellation, failure feedback, and projection invalidation;
5. prohibit a TUI append or synthetic compaction summary on successful completion;
6. characterize equal-length projection replacement, resume, failure, cancellation, and retained native bounds.

Acceptance:

- live success and resume render exactly one equivalent compaction item;
- the provider receives the projected summary and exact retained tail;
- failed/cancelled compaction leaves journal, context, and transcript identity unchanged;
- a client event observer cannot turn one committed marker into two items;
- no custom entry kind is involved.

Zi already has most of this owner decomposition. This slice makes it the normative first example and improves the dedicated transcript chrome without rerouting compaction through custom infrastructure.

## Slice A — canonical projection and journal transaction

Files:

- `packages/coding-agent/src/session-manager.ts`
- `packages/coding-agent/src/messages.ts`
- `packages/coding-agent/src/compaction.ts`
- `packages/coding-agent/test/{session-manager,compaction}.test.ts`

Work:

1. add one canonical entry-to-context-message rule and remove compaction's duplicate kind filter;
2. extend `SessionEntryData` with `custom` and `custom_message`;
3. reject new `appendMessage(role: "custom")` writes while preserving legacy restore;
4. add `appendCustomEntry`, `appendCustomMessage`, and bounded `customEntries(customType)`;
5. validate custom type, JSON shape/depth/nodes, per-entry bytes, and aggregate state count/bytes;
6. externalize and hydrate custom-message images through the format-2 blob transaction;
7. flush pending persistence on the first custom state/message append;
8. project `custom_message` into context always and presentation only when `display: true`;
9. keep `custom` out of both message projections while retaining its bounded full-journal index.

Acceptance:

- hidden custom restores into context, not presentation;
- displayed custom restores into both;
- legacy `message/custom` restores with the same rules but cannot be newly appended;
- state entries remain queryable after compaction without materializing cold messages;
- pre-marker custom messages fold and post-marker custom messages remain;
- custom messages participate in compaction budgeting and safe cut points;
- a custom image uses, verifies, accounts, rolls back, and deletes its session blob;
- a custom append before any assistant creates a resumable persistent journal;
- malformed, oversized, over-depth, over-count, and over-aggregate values reject before mutation.

## Slice B — AgentSession admission and pending-delivery union

Files:

- `packages/coding-agent/src/agent-session.ts`
- queue, compaction, cancellation, and runtime tests under `packages/coding-agent/test/`

Work:

1. replace the user-only internal pending record with a direct `user | custom` union under the existing queue owner;
2. implement closed append, trigger-turn, steer, follow-up, and next-turn intents;
3. commit idle custom messages before triggering a continuation;
4. persist queued custom messages exactly once on delivered `message_end`;
5. implement `appendCustomEntry` and `getCustomEntries` owner APIs;
6. emit `entry_appended` and synthetic committed-message events in one documented order;
7. refuse forbidden activity transitions with stable errors;
8. preserve user queue restoration while discarding cancelled undelivered custom items;
9. invalidate context/memory caches only when their authoritative projection changes.

Acceptance:

- idle displayed custom appears in `session.messages` and the journal;
- idle hidden custom appears in provider context and not `session.messages`;
- state append never changes provider messages;
- trigger-turn starts exactly one turn with the message durably present first;
- steer/follow-up delivery ordering matches ordinary queued input and is bounded with it;
- next-turn delivery is admitted once with the next user batch;
- abort, compaction races, observer failure, stale completion, and disposal cannot double-append or deliver cancelled custom work.

## Slice C — client presentation

Files:

- `packages/tui/src/interactive/transcript/message-view.ts`
- transcript performance tests
- print/RPC tests as needed

Work:

1. render a default `[customType]` label plus bounded Markdown/text-and-image body for displayed customs;
2. keep `display: false` absent from retained roots;
3. rely on presentation projection identity with no client-side journal writes;
4. confirm compaction rebuild still uses authoritative equal-length rules;
5. explicitly extend JSON/RPC event contracts for both new entry variants.

Acceptance:

- interactive restore shows displayed customs and compaction summary;
- displayed tail appends retain unchanged transcript siblings;
- hidden customs never allocate transcript items;
- equal-length compaction replacement rebuilds correctly;
- text output remains assistant-only;
- JSON/RPC preserve committed entry-before-message ordering without credential/model leakage.

## Slice D — concrete bidirectional extension session operations

Files:

- `packages/extension-api/src/index.ts`
- `packages/coding-agent/src/extensions/{protocol,host,worker}.ts`
- `packages/coding-agent/src/agent-session.ts`
- extension protocol/host/worker/runtime tests

Public shape:

```ts
interface ExtensionAPI {
  getSessionEntries(customType: string): Promise<readonly ExtensionCustomEntry[]>
  appendEntry(customType: string, data?: JsonValue): Promise<ExtensionCustomEntry>
  sendMessage(message: ExtensionCustomMessage, delivery: ExtensionMessageDelivery): Promise<void>
}
```

The public `sendMessage` promise resolves when append/queue/turn admission succeeds. It does not await a triggered provider turn.

Protocol work:

1. add source-attributed `custom_entries_get`, `custom_entry_append`, and `custom_message_send` worker requests;
2. add correlated success/error responses as closed frame variants;
3. let the worker settle operation promises while lifecycle or tool execution is active;
4. let the host process these requests while awaiting the same generation, without changing the generation lifecycle state;
5. bind one concrete session-operations adapter from `AgentSession` into `ExtensionHost` and release it on disposal;
6. reject unbound, stale-source, stale-generation, over-capacity, forbidden-activity, and disposed requests;
7. distinguish malformed protocol frames (generation-fatal) from valid domain refusal (operation error);
8. keep requests/results inside existing frame, JSON, request-count, and writer-queue bounds.

Golden example:

- a `durable-counter` extension reads its `counter` entries during `session_start`;
- its registered tool appends the next counter entry while the host is awaiting that tool invocation;
- the tool sends one displayed custom message;
- a second compiled Zi process resumes the session and observes the incremented state.

Acceptance:

- lifecycle read and tool-time append complete without nested-request deadlock;
- a persistence/capacity refusal reaches the extension promise without killing the generation;
- malformed or oversized requests fail the generation with source attribution;
- replacement rejects stale operations and never applies them to a new session;
- worker crash/disposal leaves no partial row beyond the existing append transaction;
- the compiled example passes on all five release targets.

Later capabilities may add `session_compact` and declarative renderer registration. They do not widen these operations into a generic host callback API.

## Slice E — first-party producers

Optional product follow-ons once A–C exist:

1. richer compaction summary chrome using existing marker fields
2. any first-party system notice that must be durable and model-visible becomes a custom message with a reserved `customType` namespace, or stays a first-party entry if folding/policy is special
3. any first-party notice that must be durable and model-invisible becomes either:
   - a state entry plus presenter, or
   - a new first-party entry type, not a Pi custom message

# 5. Decision table

| Need                                      | Use                                                                                              |
| ----------------------------------------- | ------------------------------------------------------------------------------------------------ |
| Toast / transient status                  | client ephemeral feedback                                                                        |
| Reloadable extension private state        | `type: "custom"` / `appendCustomEntry`                                                           |
| Model should see text; user should see it | `custom_message` with `display: true`                                                            |
| Model should see text; user should not    | `custom_message` with `display: false`                                                           |
| User should see text; model should not    | **not** Pi custom message; use bash-style exclude, state entry + presenter, or first-party entry |
| Compaction checkpoint                     | first-party `compaction` marker                                                                  |
| Extension reaction after compact          | later `session_compact` + append APIs                                                            |

# 6. Risks

1. **Semantic trap of `display`.** Users and contributors will assume it means local-only. Docs, API names, and tests must state Pi's meaning repeatedly.
2. **Context bloat.** Hidden customs accumulate in provider context and compaction summaries. Bounds, accounting, and compaction folding are mandatory.
3. **Smuggling via ordinary messages.** If both `type: "message" role: "custom"` and `custom_message` remain writable, restore semantics fork. Preserve the former only as a legacy read path.
4. **Cold-state loss.** If extension restoration reads only `retainedEntries()`, compaction silently erases live extension state. The bounded full-journal custom-state index is part of correctness, not an optimization.
5. **Pending durability.** Calling a state entry durable while the session is still pending would lose it on exit. Custom transactions must trigger the first flush.
6. **Image ownership fork.** Custom images cannot introduce inline base64 or a second blob path.
7. **Nested protocol deadlock.** Waiting for a triggered turn or blocking host receive while an extension operation is pending can deadlock lifecycle/tool execution. Operation results must remain independently correlated and acknowledge admission.
8. **Renderer escape hatches.** Extension-provided OpenTUI trees would violate TUI ownership. If renderers ship, they return bounded declarative presentation, not free renderable construction.
9. **Streaming delivery complexity.** Idle append is enough for the first useful journal slice, but the pending queue should be deepened before exposing streaming delivery publicly.

# 7. Accepted ADR

[ADR 0023](adr/0023-session-journal-separates-custom-state-and-custom-messages.md) accepts the journal split, projection semantics, full-journal custom-state index, shared image transaction, closed `AgentSession` delivery ownership, and concrete isolated-worker operations proposed here.

This document remains the detailed implementation and provenance record. Where it conflicts with the ADR or later behavior tests, the accepted decision and implementation own the contract.

# 8. Immediate next step

If product priority is "commands and durable extension state," this substrate is now the right leverage bet:

1. ~~accept the ADR~~ — accepted as [ADR 0023](adr/0023-session-journal-separates-custom-state-and-custom-messages.md);
2. ~~lock Slice 0's compaction transcript item as the first three-axis use case~~ — covered by coding-agent and retained-transcript behavior tests;
3. ~~implement Slice A's canonical projector and journal transaction~~ — implemented with session-manager and compaction behavior tests;
4. ~~implement Slice B's closed AgentSession admissions~~ — implemented with delivery, interruption, and bounds tests;
5. ~~add default client presentation~~ — implemented for authoritative TUI, JSON, and RPC projections;
6. ~~use Slice D's `durable-counter` example to drive the concrete bidirectional protocol through compiled acceptance~~ — implemented with protocol-v3 operations and compiled-worker acceptance.

Do not start with renderer registration or `session_compact`. A state-only journal slice is useful internally, but it is not a complete public building block until an isolated extension can read, append, fail, resume, and demonstrate the contract against a compiled release.

If the product goal is only "compaction looks like Pi," skip this substrate and improve the first-party `compactionSummary` chrome instead. That remains a separate, much smaller presentation bet.
