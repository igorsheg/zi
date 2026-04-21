# retained objects: progress, ui surfaces, subagents, and runtime state

## status

contract for `zi-fex.5`.
it follows [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions.md](./extensions.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

more specific retained-family contracts live in [tools](./extensions-tools.md), [jobs/subagents](./extensions-jobs-subagents.md), [ui contract](./extensions-ui-contract.md), and [state rebinding](./extensions-state-rebinding.md).

## decision

- progress, status, working-message state, ui surfaces, transcript attachments, subagent state, and extension-visible runtime/session/provider state are **host-owned retained objects**.
- each retained object lives inside one `{ generation, namespace }` lease domain.
- extensions may supply semantic intent and metadata, but they do not own tui components, cross-thread lifetimes, mailbox payloads, or redraw cadence.
- live ui updates publish **family-scoped semantic snapshots** from host-owned retained state.
  the normal bus is not one extension-streamed full-state blob.
- `session_shutdown` is the last lifecycle publication where a bound namespace may mutate its retained objects.
  `unbind` revokes every session-scoped lease.
  `teardown` destroys any retained runtime state that still exists for that namespace.

## model

one retained object means five things at once:

1. the host owns the authoritative record.
2. the record has an opaque handle or lease id.
3. the handle is valid only for one generation and one namespace.
4. semantic publication is host-shaped.
5. tui materialization, if any, is tui-owned.

```text
extension code
   │
   │  semantic intent
   │  metadata
   ▼
┌──────────────────────────────────────────────────────────────┐
│ host retained store                                         │
│  generation g                                               │
│  namespace n                                                │
│                                                              │
│  progress handles        status / working state             │
│  ui surface leases       transcript attachment records      │
│  subagent records        runtime/session/provider state     │
└───────────────┬──────────────────────────────────────────────┘
                │
                │ family-scoped semantic publication
                │ revisioned, coalesced, host-timed
                ▼
┌──────────────────────────────────────────────────────────────┐
│ tui thread                                                   │
│  snapshot caches                                             │
│  retained transcript rows                                    │
│  retained renderer state                                     │
│  widget/header/footer/editor materialization                 │
│  layout, focus, paint cadence                                │
└──────────────────────────────────────────────────────────────┘
```

corollary:

- if a consumer needs to render, it reads a published semantic view.
- if a consumer needs to mutate, it goes back through the owner.
- if an extension wants something to outlive a callback, it asks the host for a retained object.

## retained classes

| class | authoritative owner | extension supplies | published across owner boundary | cleanup edge |
| --- | --- | --- | --- | --- |
| progress handles | agent-owned host state | label, phase, totals, status, child relationships, terminal reason | progress semantic view only; never a live tui object | unbind for active handles, teardown for namespace-owned records |
| status items | agent-owned host state | key + text or clear intent | status family snapshot | unbind |
| working-message state | agent-owned host state | message text or restore-default intent | status family snapshot | unbind |
| widget/panel handles | host-owned surface leases | slot, ordering hints, semantic payload, optional renderer/factory reference defined by the ui contract | surface family snapshot or invalidation | unbind |
| header/footer/title/editor handles | host-owned singleton slot leases | semantic payload or factory reference defined by the ui contract | surface family snapshot or invalidation | unbind |
| transcript attachments | agent-owned transcript semantics | attachment metadata, labels, render hints, lifecycle intent | transcript semantic snapshot | unbind if session-local; otherwise teardown when the owning transcript object dies |
| retained presentation objects derived from transcript or tool results | tui-owned presentation cache | at most metadata or precomputed host payload | do not cross as live objects; only ids, semantic revisions, or payload descriptors cross | tui drop or rebuild on semantic invalidation |
| namespace-scoped runtime state / caches / services | agent-owned runtime state | implementation data only | none by default | teardown |
| provider registrations | agent-owned runtime state | provider name, config, provenance | none unless another contract surfaces a semantic view | teardown or explicit unregister |
| provider instances / bound provider services | agent-owned session state | config or runtime callbacks | none unless another contract surfaces a semantic view | unbind |
| subagent state | agent-owned host state | spawn request, labels, observer hooks, semantic annotations | subagent semantic view and/or progress view | unbind for active runs, teardown for retained namespace data |

## ownership split

### agent-owned semantic state

these objects are part of product semantics, even when the tui renders them:

- progress handles
- status items
- working-message state
- transcript attachments that affect transcript meaning
- subagent state
- namespace/runtime/session/provider state

if the state must survive a callback, participate in lifecycle cleanup, or be observable by more than one consumer, the host owns it on the agent side.

a semantic object may have a published view, but the published view is not the object itself.

### tui-owned presentation

the tui owns:

- component instances
- layout trees
- focus state
- scroll state
- retained renderer caches
- editor/header/footer/widget materialization
- any presentation object built from semantic publication

a tui object may outlive one paint, but it does not become extension-owned just because an extension requested it.

the extension contract is about slots, handles, semantic payloads, and invalidation.
it is not about borrowing component pointers across threads.

### extension-provided metadata

extensions may provide:

- labels, status text, working text
- progress totals and annotations
- transcript attachment metadata
- ui payloads or host-approved renderer/factory references
- runtime/service configuration
- provider configuration
- subagent configuration and semantic annotations

that data is **input to** host-owned retained objects.
it is not ownership of the resulting object.

## semantic publication

semantic publication crosses the owner boundary as **family-scoped snapshots**.

that means:

- status publishes status semantics
- progress publishes progress semantics
- surfaces publish surface semantics
- transcript publishes transcript semantics, including attachment descriptors
- subagents publish subagent semantics

normal steady-state publication is **not**:

- a giant extension-owned ui blob
- a full tui tree dump
- a mailbox payload that exists only to satisfy one view
- a stream of direct tui mutation commands

allowed full-state snapshots still exist for bootstrap, restore, debug, or explicit recovery flows.
they are not the normal live-update architecture.

### publication shape

the host chooses the transport shape, but every family must preserve these rules:

- semantic meaning lives in the payload, not view formatting.
- publication is revision-aware.
- consumers may drop stale revisions.
- consumers may rebuild local presentation caches from the latest semantic view.
- publication does not transfer ownership of the underlying object.

for singleton families such as title or working message, the semantic view may be just the resolved visible state plus provenance.
for collection families such as progress handles or widgets, the semantic view may be a changed-record set plus enough metadata to resolve adds, updates, and removals.

## coalescing and update rules

cheap frequent updates are host-coalesced.

rules:

- scalar field writes are last-write-wins within one object revision stream.
- the host may collapse many progress ticks or working-message rewrites into one published update.
- terminal transitions must flush: create, complete, fail, cancel, attach, detach, revoke, and destroy are hard boundaries.
- redraw cadence is host policy.
- extensions do not force one mailbox send per mutation.
- the normal live-ui bus must stay incremental and family-scoped.

practical reading:

- progress counts can update fast.
  the host may publish only the newest visible value.
- working-message churn can update fast.
  the host may publish only the newest text.
- transcript semantic changes may use existing conversation coalescing rules, but attachment add/remove and terminal tool/subagent edges are hard flush points.

```text
many extension writes
   │
   ├─ set progress current=41
   ├─ set progress current=42
   ├─ set progress current=43
   ├─ set working="indexing"
   └─ set working="indexing src/"
   ▼
host coalescer
   │
   ├─ keep latest visible scalar state
   ├─ preserve hard lifecycle edges
   └─ publish on host cadence
   ▼
latest semantic snapshot(s)
```

## scope and leases

all retained handles are opaque and generation-tagged.

a valid handle implies all of these still match:

- generation
- namespace
- object class
- session binding, if the class is session-scoped
- object not yet revoked

recommended mental model:

```text
handle = { generation, namespace, class, local_id, lease_state }
```

this is a contract statement, not a wire-format requirement.

the point is simple: generation swap must make stale handles obviously invalid.

rules:

- the host validates lease scope on every mutation.
- a namespace may not mutate another namespace's retained objects.
- merged views do not own the underlying objects.
- visibility does not change ownership.
- losing a slot arbitration does not transfer ownership to the visible winner.
- nothing from generation `n` leaks into generation `n+1` unless a later contract defines explicit migration.

## lifetime rules

### generation-scoped

generation-scoped objects survive across callbacks while one namespace generation is alive.

examples:

- runtime caches/services
- provider registrations
- namespace-owned metadata for surface handles
- detached semantic records that are not session-visible after unbind but still need orderly teardown

these die at teardown.

### session-scoped

session-scoped objects survive across callbacks only while one generation is bound to one session.

examples:

- visible status items
- working-message state
- active progress handles
- visible widget/header/footer/title/editor occupancy
- bound provider instances
- active subagents
- transcript attachments attached to the active session transcript

these die at unbind.

### callback-scoped

callback-scoped data is not a retained object class.
it is ordinary temporary data and must not be smuggled into cross-thread live ownership.

## cleanup

### `session_shutdown`

`session_shutdown` is the last session-visible publication.

during `session_shutdown`:

- existing retained objects may publish terminal semantic state
- existing long-running work may be cancelled or flushed
- the namespace must not assume any object survives past unbind
- new long-lived session-scoped leases must not be created

### unbind

unbind revokes the session binding.

after unbind:

- every session-scoped lease for that namespace is invalid
- no more session-visible callbacks fire for that namespace
- visible status, working-message state, progress, surface occupancy, transcript attachments, bound provider instances, and active subagent state are withdrawn or cancelled
- stale handle mutations are ignored or rejected by host policy; they are never reattached to the new binding implicitly

### reload

reload is a generation swap on the same session.

```text
old generation g
   │
   ├─ session_shutdown(reason=reload)
   ├─ unbind leases for g
   ├─ discover + load generation g+1
   ├─ bind g+1 to same session
   ├─ session_start(reason=reload)
   └─ teardown g
```

consequences:

- no ui/progress/status/subagent handle from `g` is valid in `g+1`
- the new generation must acquire fresh leases
- tui presentation objects derived from `g` are invalidated by host publication, not reused by extension fiat

### session replacement

new-session, resume, and fork replace both the session binding and the generation.

```text
session a, generation g
   │
   ├─ session_shutdown(reason=new|resume|fork)
   ├─ unbind g from session a
   ├─ teardown g
   ├─ discover + load generation h for session b
   ├─ bind h to session b
   └─ session_start(reason=new|resume|fork)
```

consequences:

- session-local retained objects never cross the replacement boundary
- runtime-local retained objects also do not cross, because session replacement creates a fresh generation
- migration, if ever needed, must be an explicit later contract

## what this tightens in current zi

this contract exists because current seams are truthful, but still split across the wrong owners.

- `src/coding_agent/extensions/runner.zig` models `stub -> bound`, but retained-object lifetime still needs explicit lease revocation, unbind, and teardown semantics.
- `src/coding_agent/agent_session.zig` binds extension runtime with `.ui = null`, and `src/coding_agent/extensions/context.zig` publishes `ctx.has_ui` plus `ctx.ui = nil`.
  v2 needs a host-owned ui lease surface, not a nullable reach-through.
- `src/tui/status_data.zig` currently stores extension statuses inside tui-owned state.
  v2 moves semantic authority to the host, then publishes status semantics to the tui.
- `src/tui/interactive.zig` and `src/tui/ui_event.zig` already show the right publication doctrine: bounded snapshot traffic, lossy coalescing for cheap updates, and separate lifecycle delivery for terminal outcomes.
  this doc turns that runtime shape into the retained-object rule.
- `src/tui/conversation_projection.zig`, `src/tui/transcript.zig`, and `src/tui/renderers/builtins.zig` already distinguish semantic input from retained presentation caches.
  this doc makes that split normative for extension-visible attachments and surfaces too.
- `src/coding_agent/runtime_host.zig` and `src/coding_agent/agent_session.zig` already tear down extension state on session replacement.
  this doc makes the cleanup expectations explicit for every retained-object class.

## pi-mono capability parity, without pi-mono ownership leakage

pi-mono proves the product surface is worth keeping: status, working message, widgets, footer/header/title/editor controls, and runtime/provider state exist there already.

zi keeps that capability, but with stricter ownership:

- extension api names may stay familiar
- object ownership moves to host-retained records
- tui component lifetime stays tui-owned
- cross-thread publication stays semantic and host-shaped

so parity is about capability, not about copying pi-mono's in-memory object graph into zi's owner boundary.

## forbidden shapes

the following are rejected as the normal architecture:

- one giant full-state ui blob streamed from extension code to drive live ui
- direct tui → extension reach-through for status, progress, widget, or subagent mutation
- extension-owned tui component instances crossing threads
- stale handles from an old generation silently mutating the new generation
- treating mailbox payloads as the public product contract

## non-goals

this contract does not yet define:

- the concrete extension api names for every retained class
- exact widget/layout precedence rules between competing namespaces
- transcript attachment payload schema
- provider api schema
- subagent event payload schema
- snapshot transport encoding

those belong in the follow-on ui, provider, subagent, and session-state contracts.
