# tools: definition, phases, overrides, and renderer inheritance

## status

contract for `zi-fex.6`.
it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-events.md](./extensions-events.md), [extensions-retained-objects.md](./extensions-retained-objects.md), [extensions-ui-contract.md](./extensions-ui-contract.md), [extensions-jobs-subagents.md](./extensions-jobs-subagents.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

until shared docs are updated, this doc is the tool-specific authority where those docs still speak in older provisional terms.

## decision

- tools stay **definition-first**.
  one namespace-owned tool definition is the product unit.
- the public capability classes are explicit: identity, parameter schema, prompt metadata, prepare, execute, progress, result/details, and presentation.
  v2 does not hide those behind one vague callback bag.
- the tool lifecycle is explicit: `register -> prepare -> validate -> before_tool_call -> execute -> progress publication -> after_tool_result -> finalize -> render`.
- tool-name collisions are deterministic and root-driven.
  tool override is not a special second mechanism; it is a higher-precedence claim on the same canonical tool key.
- builtins are just the last root for definition claiming, but builtin **presentation families** remain available as inheritance sources for builtin-like tools.
- progress is a retained-object family.
  partial semantic tool output is a separate tool-run publication, not the progress transport.
- tool rendering is slot-based and host-owned.
  the public slots are `call` and `result`.
- today's `zi.register_tool`, `render_result`, `ctx.update`, and `zi.spawn` are transitional substrate.
  v2 splits them into more truthful families instead of documenting the transitional shape as doctrine.

## model

there are two public retained objects in the tool contract.

| object | scope | owner | purpose |
| --- | --- | --- | --- |
| `tool_registration` | generation-scoped | namespace | definition claim: schema, execution seam, prompt metadata, presentation metadata, provenance |
| `tool_run` | session-scoped | host | one execution record: phase, args, partial semantic result, terminal result, linked progress handles, renderer resolution |

`progress_handle` remains part of the retained-object contract.
it is linked from a `tool_run`, not smuggled through the tool-result channel.

```text
runtime root order
   │
   ├─ register tool definitions
   │    └─ first claimant wins visible tool name
   │
   └─ assistant emits tool call
         │
         v
   +-------------+
   |   prepare   |
   +-------------+
         │
         v
   +-------------+
   |  validate   |
   +-------------+
         │
         v
   +--------------------+
   | before_tool_call   |
   | replace / cancel   |
   +--------------------+
         │
         ├──────── blocked / invalid replacement ───────┐
         │                                               │
         v                                               │
   +-------------+                                       │
   |  execute    |                                       │
   +-------------+                                       │
      │       │                                          │
      │       ├─ progress publication ──> progress family│
      │       │                                          │
      │       └─ partial semantic patch ─> tool_run      │
      │                                                  │
      └──────────────────────────────┬───────────────────┘
                                     v
                           +--------------------+
                           | after_tool_result  |
                           +--------------------+
                                     │
                                     v
                           +--------------------+
                           |      finalize      |
                           +--------------------+
                                     │
                                     v
                           +--------------------+
                           |       render       |
                           +--------------------+
```

## definition capability classes

v2 tool definitions carry these classes directly.

| class | required | contract |
| --- | --- | --- |
| identity | yes | `name`, `label`, `description`. `name` is the collision key and the llm-visible tool id. |
| parameter schema | yes | canonical input schema for host validation. the host owns validation; tools do not get ad hoc schema bypasses. |
| prompt metadata | no | one-line prompt snippet plus guideline bullets. metadata belongs to the definition, not to a later wrapper. |
| prepare | no | non-yielding pre-validation normalizer over raw tool-call args. use for compatibility shims and canonicalization only. |
| execute | yes | yieldable tool body. it owns side effects and returns the terminal tool result. |
| progress | no | declaration that the tool may create and mutate retained progress handles linked to the current `tool_run`. |
| result/details | yes | terminal result shape is always `{ content, details?, is_error }`. partial semantic patches use the same field families, but as patches rather than full terminal results. |
| presentation | no | slot metadata for `call` and `result`. each slot may be `custom`, `inherit_builtin(<family>)`, or `default`. |

corollaries:

- `prepare` is public for builtin and extension tools equally.
  v2 does not keep a richer builtin-only prepare seam.
- `presentation` is public for `call` and `result` separately.
  v2 does not keep one result-only rendering hook for extensions while builtins get richer private slots.
- `result/details` is one semantic class, not three unrelated loopholes.
  partial patches and terminal overrides use the same field meanings.

## phase boundaries

### 1. register

`register` creates or updates a namespace-owned `tool_registration` claim.
it usually happens during lifecycle load/register, but the semantic meaning is simple either way: one namespace contributes one definition keyed by tool name.

register decides:

- claim key: tool name
- provenance: runtime root + namespace
- prompt metadata visibility
- builtin-family inheritance metadata
- which seams exist for later phases

`register` is generation-scoped.
it dies at teardown.

### 2. prepare

`prepare` is the tool's own pre-validation seam.

rules:

- input is the raw llm tool-call argument object.
- output is a candidate argument object for the schema.
- `prepare` is non-yielding.
- `prepare` must not mutate host state, publish progress, or render.
- `prepare` may fail.
  failure produces a host-owned synthetic error result and skips `execute`.

this seam exists to normalize old/new argument shapes without weakening the schema contract.

### 3. validate

the host validates prepared args against the tool's parameter schema.

rules:

- validation happens before interception sees the call.
- invalid args produce a synthetic error result owned by the host.
- the schema is authoritative for whether a tool body may run.

### 4. before_tool_call

`before_tool_call` is the interception seam over the semantic tool call.

input core:

- `tool_call_id`
- `tool_name`
- validated args
- assistant message / run context, per the events contract

allowed outcomes:

- continue unchanged
- replace args
- cancel with reason

replacement semantics:

- replacement args replace the whole argument object.
- the host MUST re-run the same validation rule before leaving `before_tool_call`.
- that revalidation is a guard inside this phase, not a second public phase.

cancellation semantics:

- first cancellation wins.
- cancellation produces a synthetic terminal result.
- the call still goes through `after_tool_result`, `finalize`, and balanced execution-end publication.

### 5. execute

`execute` is the only tool-body phase.

rules:

- it may yield under the host scheduler.
- it may call subagent or system-process surfaces defined elsewhere.
- it may mutate retained progress handles and the current `tool_run` partial semantic view.
- it returns exactly one terminal result.

`execute` does not own transcript rows, tui components, redraw cadence, or render caches.

### 6. progress publication

progress publication is zero-or-more host-owned retained updates during `execute`.

progress is **not** a disguised partial result.

progress publication may update:

- label
- phase text
- totals / current counts
- parent-child relationships
- status
- terminal reason

those updates flow through the retained-object progress family from [extensions-retained-objects.md](./extensions-retained-objects.md).

a tool may also publish **partial semantic result patches** during execution, but those are separate writes to the current `tool_run` semantic view:

```text
ctx.progress.*        -> progress family
ctx.result.update(...) -> tool_run partial semantic view
```

patch semantics for `ctx.result.update(...)` are fieldwise and shallow:

- `content` replaces the current preview content array in full
- `details` replaces the current preview details value in full
- `is_error` replaces the preview error bit
- omitted fields keep the current preview value

no deep merge exists for `content` or `details`.

### 7. after_tool_result

`after_tool_result` is the last rewrite seam for terminal tool output.

it runs for every terminal outcome, including:

- normal tool completion
- prepare failure
- validation failure
- cancellation/block
- execution failure

override semantics are fieldwise and shallow:

- `content` replaces the terminal content array in full
- `details` replaces the terminal details value in full
- `is_error` replaces the terminal error bit
- omitted fields keep the pre-override terminal value

this keeps result rewriting deterministic and pi-mono-grade without inventing deep-merge folklore.

### 8. finalize

`finalize` is the host commit boundary.

the host must:

- seal the terminal `tool_run` semantic state
- resolve linked progress handles to terminal state
- emit `tool_result` / `tool_execution_end` in the defined order
- commit the final tool-result message to transcript/session state
- drop or revoke execution-local ephemeral state

`finalize` is where "what actually happened" becomes committed product semantics.

### 9. render

`render` is host-owned presentation over the `tool_run` semantic view.

rules:

- render reads semantic state; it does not own it
- render work is side-effect free and host-scheduled
- paint/input hot paths never call extension code directly
- missing or rejected render output falls back open to default presentation

this is just the ui contract applied to tool calls and tool results.

## event fit

the phase model specializes the events doc for tools.

```text
prepare
  -> validate
  -> tool_execution_start
  -> before_tool_call
  -> execute
       ├─ progress family publication
       └─ tool_execution_update*   (partial semantic patches only)
  -> after_tool_result
  -> tool_result
  -> tool_execution_end
```

rules:

- `tool_execution_start` publishes the validated pre-interception call.
- `tool_execution_update` is **not** the general progress bus in v2.
  it is the observer edge for partial semantic tool-result changes.
- progress consumers read the progress family from retained publication.
- `tool_result` stays the last rewrite seam before `tool_execution_end`.

that is the tool-specific narrowing this doc applies back onto [extensions-events.md](./extensions-events.md).

## deterministic override and collision semantics

### registration collisions

tool override is one registration-class rule, not a pile of exceptions.

- key: tool name
- precedence source: canonical runtime-root order from [runtime-roots.md](./runtime-roots.md)
- within-root order: deterministic discovery order, then registration order inside one namespace
- winner: first claimant for that tool name
- losers: ignored for visibility, may emit diagnostics

so the concrete rule stays:

```text
explicit > user > project > builtin
```

with first claimant wins.

builtins are simply the last root.
a builtin does not get a secret override privilege once a higher-precedence definition has claimed the name.

### what does and does not merge

on a name collision, the losing definition contributes **nothing** to the visible tool definition except where builtin renderer inheritance explicitly says otherwise.

that means no implicit merge of:

- schema
- prompt metadata
- prepare logic
- execute logic
- progress capability
- result semantics

override is whole-definition replacement at the tool-registration level.

### interception overrides

tool-call and tool-result rewriting are distinct from registration collisions.

they compose like this:

1. registration chooses the visible tool definition by name.
2. `before_tool_call` may replace or cancel one execution.
3. `after_tool_result` may replace terminal result fields for that execution.

that keeps source precedence and per-call policy overrides from bleeding into each other.

## builtin renderer inheritance

builtin renderer inheritance is a product capability for tools that preserve a builtin semantic family.

### builtin family

a builtin family is a host-declared semantic contract with named presentation slots.

examples of likely families:

- `read`
- `write`
- `edit`
- `grep`
- `find`
- `bash`
- `ls`

family meaning matters more than implementation origin.
a non-builtin tool may still declare itself builtin-like for presentation if it preserves that family's semantic input/output shape.

### public slots

the public slots are:

| slot | input | default fallback |
| --- | --- | --- |
| `call` | validated args + call presentation context | generic host call header |
| `result` | partial/final semantic result + expansion context | generic host result view |

slot inheritance is independent.
a tool may inherit one slot and customize the other.

### resolution order

for each slot, the host resolves presentation in this order:

1. the tool's own custom slot renderer
2. an explicit `inherit_builtin(<family>)` declaration for that slot
3. implicit same-name builtin-family inheritance when the visible tool overrides a builtin of the same name and does not opt out
4. generic host default

rules:

- inheritance source is builtin family metadata, not a displaced extension definition.
- inheritance is per slot.
- inheritance borrows semantic behavior, not ownership.
  builtin renderer state stays host-owned and generation-local.
- if the tool's semantic shape is not actually compatible with the inherited builtin family, host behavior may reject the inherited slot and fall back to default presentation.

### why same-name implicit inheritance exists

same-name builtin override is the common product case:

```text
user/project tool named "read"
   overrides builtin "read" execution
   but still wants builtin read presentation
```

making that case require bespoke copy/paste renderer code would be clown behavior.

so v2 keeps the pleasant part, but makes it explicit and slot-local.

## progress is retained state, not the partial-result bus

v2 splits two things that current zi overloads together:

1. **progress** — how far the work is, what phase it is in, whether it has children, whether it completed/cancelled/failed
2. **partial semantic result** — what the tool currently wants the user to read as evolving output

that split matters because they coalesce differently, render differently, and survive different ui policies.

```text
execute body
   │
   ├─ progress tick / phase / child -> progress handle(s)
   │                                  -> retained progress snapshot
   │
   └─ partial semantic output patch  -> tool_run semantic view
                                      -> tool_execution_update observer
```

practical consequences:

- a spinner/progress bar no longer requires fake text blocks in `partial_result`
- a tool can stream semantic output without pretending that output is also progress metadata
- the tui can show progress and partial output in different places from different retained inputs
- host coalescing can be cheap for progress ticks without dropping meaningful semantic output edges

## what today's surfaces become in v2

| today | v2 meaning | note |
| --- | --- | --- |
| `zi.register_tool(def)` | `zi.tools.register(def)` | first-class tool registration stays, but lives under an explicit tool namespace and accepts the full definition model above |
| `render_result` | `presentation.result` | one result slot inside the tool definition's presentation class |
| no public call-render hook for extension tools | `presentation.call` | v2 makes the call slot public too |
| `ctx.update(partial)` | split into `ctx.progress.*` and `ctx.result.update(patch)` | progress and partial semantic result become different families |
| `zi.spawn(...)` | leaves the tool contract | child-agent work belongs to first-class subagents; generic process work belongs to `zi.system.process`; tools may call those surfaces from `execute`, but `zi.spawn` is not the doctrine shape |

this doc deliberately does **not** keep `ctx.update` as the conceptual center.
it is the overloaded old shape.

## relation to the other docs

- [runtime.md](./runtime.md) stays authoritative for the owner split: tool execution is agent-side; tui presentation is tui-side.
- [runtime-roots.md](./runtime-roots.md) stays authoritative for root precedence and first-claimant-wins collision policy.
- [extensions-lifecycle.md](./extensions-lifecycle.md) stays authoritative for generation creation, bind, unbind, teardown, and scheduler ownership.
  this doc only specializes those rules for tools.
- [extensions-events.md](./extensions-events.md) stays authoritative for observer/interceptor families.
  this doc narrows the tool-specific meaning of `tool_execution_start`, `tool_execution_update`, `tool_result`, and `tool_execution_end`.
- [extensions-retained-objects.md](./extensions-retained-objects.md) stays authoritative for progress handles, lease scope, coalescing, and cleanup.
  this doc says tool progress must use that model.
- [extensions-ui-contract.md](./extensions-ui-contract.md) stays authoritative for renderer purity, host-owned presentation, fail-open fallback, and transcript/surface ownership.
  this doc says tools use the `call` and `result` slots from that doctrine.
- [extensions-jobs-subagents.md](./extensions-jobs-subagents.md) stays authoritative for what replaces `zi.spawn`.

## what this replaces or tightens in current zi

- current extension tools register identity, schema, prompt metadata, execute, and optional `render_result`, but not a public prepare seam or call-render slot.
  v2 makes those capability classes explicit and uniform.
- current collision behavior is real but still split across discovery, bootstrap, and registry implementation.
  v2 makes one root-driven override rule authoritative.
- current progress streaming overloads `tool_execution_update.partial_result`.
  v2 moves progress to retained objects and leaves `tool_execution_update` for semantic partial-result publication.
- current early tool failures and blocked calls take a different finalize path from executed calls.
  v2 routes every terminal outcome through one `after_tool_result -> finalize` contract.
- current tool rendering mixes builtin name-based renderer lookup with extension `render_result` only.
  v2 defines public call/result slots plus builtin-family inheritance and fallback rules.
- current `zi.spawn` still mixes subprocess transport and subagent-shaped behavior.
  v2 removes it from the tool contract and treats it as legacy substrate split by the jobs/subagents contract.

## non-goals

this doc does not yet pin down:

- the exact lua syntax for `zi.tools.register`, `ctx.progress.*`, or `ctx.result.update(...)`
- the full schema of a `tool_run` publication payload
- the exact builtin-family list and every builtin family's semantic compatibility table
- transcript attachment schema for tool-owned rich results
- conformance tests for each builtin family

those belong in the api and conformance follow-ons.
