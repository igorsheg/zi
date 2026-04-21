# extension state scopes, persistence, and rebinding

## status

contract for `zi-fex.9`.
it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-events.md](./extensions-events.md), [extensions-retained-objects.md](./extensions-retained-objects.md), and [extensions-jobs-subagents.md](./extensions-jobs-subagents.md).

## decision

- extension state splits into six scopes:
  1. runtime-root provenance
  2. namespace/generation runtime
  3. global persisted state
  4. workspace/project persisted state
  5. session-live state
  6. session-persisted state
- runtime-root scope is **identity and provenance**, not a mutable durable junk drawer.
- namespace/generation scope owns registrations, callbacks, services, caches, and any other non-persisted retained runtime state.
- session-live scope owns leases bound to one `{ generation, namespace, session }`.
  ui, progress, provider instances, jobs, and similar live handles live here.
- global, workspace, and session-persisted state are **host-owned stores**.
  extensions do not persist through tui widgets, tui-local caches, or mailbox payloads.
- durable state is keyed by a stable **state owner id**: `{ runtime_root_id, extension_id }`.
  generation ids are never part of the durable key.
- reload, new, resume, and fork never rebind live handles from the old generation.
  the host creates a fresh generation, surfaces fresh binding ids, and extensions rehydrate from persisted state if needed.
- lifecycle reasons are first-class: `startup`, `reload`, `new`, `resume`, `fork`, `exit`.
- lifecycle payloads and bound context surface stable identifiers for runtime-root, state owner, generation, namespace, workspace, and session.

## model

```text
canonical runtime roots
        │
        │ discover + precedence
        v
┌──────────────────────────────────────────────────────────────┐
│ runtime-root provenance                                      │
│  runtime_root_id                                             │
│  extension_id                                                │
│  state_owner_id = { runtime_root_id, extension_id }          │
└───────────────────────────────┬──────────────────────────────┘
                                │
                                │ fresh every generation
                                v
┌──────────────────────────────────────────────────────────────┐
│ namespace / generation                                       │
│  generation_id                                               │
│  namespace_id = { generation_id, state_owner_id }            │
│                                                              │
│  owns: tools, commands, observers, interceptors, providers,  │
│        jobs, caches, services, lua refs, callback state      │
└───────────────┬──────────────────────────────────────────────┘
                │
                │ bind to one workspace + one session
                v
    ┌──────────────────────────────┬──────────────────────────────┐
    │ persisted stores             │ session-live retained state  │
    │                              │                              │
    │ global       host-owned      │ ui / progress / jobs         │
    │ workspace    host-owned      │ provider instances           │
    │ session      host + session  │ working/status state         │
    │                              │ transcript attachments       │
    └──────────────┬───────────────┴──────────────┬───────────────┘
                   │                              │
                   │ rehydrate on bind           │ revoked at unbind
                   v                              v
             fresh generation              stale-handle death
```

short version:

- **rebind by state, never by pointer**.
- persisted data may survive.
- live handles do not.

## identifiers

these ids are part of the contract.

| id | meaning | stability |
| --- | --- | --- |
| `runtime_root_id` | canonical discovered root identity from [runtime-roots.md](./runtime-roots.md) | stable only while the same root keeps the same identity |
| `extension_id` | discovered extension id inside that root | stable by discovery shape |
| `state_owner_id` | durable owner key `{ runtime_root_id, extension_id }` | stable across generations if the same extension from the same root wins again |
| `generation_id` | one extension runtime generation | new on every reload and every session replacement |
| `namespace_id` | live namespace key `{ generation_id, state_owner_id }` | unique per generation |
| `workspace_id` | normalized active workspace/project identity for the bound runtime | stable only while binding targets the same workspace |
| `session_id` | active session identity | stable only while bound to that session |
| `session_file` | persisted session file path, if any | stable only while bound to that session file |

rules:

- extensions may cache ids.
  they must not infer liveness from ids alone except where this contract says the id is durable.
- `state_owner_id` is the durable join key.
  `namespace_id` is the live join key.
- if precedence changes and a different root wins the same `extension_id`, that is a different `state_owner_id`.
  no implicit durable-state migration happens across that boundary.

## lifecycle payload contract

`session_start` and `session_shutdown` must surface the same binding identity set.
ordinary tool, command, observer, and interceptor contexts should be able to read the current binding ids too, so extensions do not need to cache a prior lifecycle event just to know where they are.

payload shape:

- `reason` — one of `startup`, `reload`, `new`, `resume`, `fork`, `exit`
- `binding` — `{ runtime_root_id, state_owner_id, generation_id, namespace_id, workspace_id, session_id, session_file? }`
- `previous?` — previous binding ids when the event starts a replacement generation
- `next?` — next binding ids when the event shuts down a generation and the host already knows the target
- `fork_parent_entry_id?` — the fork point when the flow is `fork`

rules:

- `session_start(reason=startup)` has no `previous`.
- `session_shutdown(reason=exit)` has no `next`.
- `session_start(reason=reload)` keeps `session_id` but changes `generation_id` and `namespace_id`.
- `session_start(reason=new|resume|fork)` changes both session and generation ids.
- the `binding` object is the source of truth. ad hoc string fields outside it are diagnostics only.

## scopes

| scope | owner | key | persisted | examples | cleanup edge |
| --- | --- | --- | --- | --- | --- |
| runtime-root provenance | host discovery | `runtime_root_id` | n/a | root descriptors, precedence provenance, resource anchors | next discover |
| namespace/generation | namespace | `namespace_id` | no | tool/command/event registrations, provider registrations, services, caches, lua refs | teardown |
| global | host | `{ state_owner_id, global }` | yes | user-wide extension prefs, auth-adjacent extension config, durable caches not tied to one workspace | explicit clear only |
| workspace/project | host | `{ state_owner_id, workspace_id }` | yes | per-repo prefs, indexes, project-local extension data | explicit clear or workspace change |
| session-live | host retained store + namespace lease | `{ namespace_id, session_id, handle }` | no | ui/status/progress/provider-instance/job/subagent handles | unbind |
| session-persisted | host/session store | `{ state_owner_id, session_id, key }` | yes | per-session extension checkpoints, per-session user choices, resumable workflow metadata | explicit clear or new session |

### why runtime-root is not a durable write scope

runtime roots already define discovery order and collision ownership.
that makes them the right provenance key, but the wrong mutable store.

if zi let extensions treat runtime-root as a writable durable bucket, two bad things happen:

1. precedence changes would silently retarget old state to new winners.
2. discovery metadata would become a backdoor persistence layer.

so the rule is simpler:

- runtime-root contributes identity.
- durable writes go to global, workspace, or session-persisted stores.

### persisted state shape

persisted extension state is logically a map:

```text
scope + state_owner_id + key -> value | tombstone
```

rules:

- values are semantic data, not borrowed host objects.
- last write wins within one scope/key stream.
- delete writes a tombstone.
- session replay reduces along the active branch only.
- session-persisted state does not enter llm context unless the extension separately emits a `custom_message` or another context-bearing entry.

implementation freedom:

- global/workspace stores may use any host-owned file format.
- session-persisted state may be implemented with explicit session metadata entries.
- the public contract is the logical map and replay behavior, not the raw wire format.

## flow contract

### startup bind

```text
process start
   -> discover runtime roots
   -> create generation g1
   -> load/register namespaces
   -> bind workspace w + session s
   -> load visible persisted state for {global, workspace w, session s}
   -> publish session_start(reason=startup)
```

effects:

- namespace/generation state starts fresh.
- session-live handles start fresh.
- global/workspace/session-persisted state is loaded from durable storage for the chosen binding target.

### reload

```text
session s, generation g
   -> session_shutdown(reason=reload)
   -> unbind session-live leases for g
   -> discover runtime roots again
   -> create generation g+1
   -> load/register
   -> bind generation g+1 to same workspace + same session s
   -> reload visible persisted state for {global, workspace, session s}
   -> session_start(reason=reload)
   -> teardown generation g
```

survives:

- global persisted state
- workspace persisted state
- session-persisted state for the same session
- session id and session file

resets:

- runtime-root discovery result
- namespace/generation state
- every session-live handle
- provider instances, jobs, ui handles, progress handles, working/status leases

### new session

```text
session a, generation g
   -> session_before_switch(reason=new)
   -> session_shutdown(reason=new)
   -> unbind g from session a
   -> teardown g
   -> discover roots for current cwd
   -> create generation h
   -> bind workspace w + fresh session b
   -> load visible persisted state for {global, workspace w, session b}
   -> session_start(reason=new)
```

survives:

- global persisted state
- workspace persisted state for the same workspace

resets:

- session-persisted state, because session `b` is new
- namespace/generation state
- all session-live handles

### resume session

```text
session a, generation g
   -> session_before_switch(reason=resume)
   -> session_shutdown(reason=resume)
   -> unbind g from session a
   -> teardown g
   -> discover roots for resumed session's workspace
   -> create generation h
   -> bind workspace w' + resumed session b
   -> load visible persisted state for {global, workspace w', session b}
   -> session_start(reason=resume)
```

survives:

- global persisted state
- workspace persisted state only if `w' == w`; otherwise the new binding sees the resumed workspace's store
- session-persisted state from resumed session `b`

resets:

- namespace/generation state
- all session-live handles
- old workspace binding if the resumed session points elsewhere

### fork session

```text
session a, generation g
   -> session_before_fork(reason=fork)
   -> session_shutdown(reason=fork)
   -> unbind g from session a
   -> teardown g
   -> discover roots for fork target workspace
   -> create generation h
   -> bind workspace w' + forked session b
   -> reconstruct session-persisted snapshot from the forked branch prefix
   -> session_start(reason=fork)
```

survives:

- global persisted state
- workspace persisted state only for the target workspace
- session-persisted state that existed on the forked branch prefix

resets:

- namespace/generation state
- every session-live handle
- any session-persisted writes that existed only after the fork point on the old branch

### exit

```text
session s, generation g
   -> session_shutdown(reason=exit)
   -> unbind g
   -> teardown g
   -> process exit
```

survives:

- global/workspace/session-persisted state that was already committed

resets:

- namespace/generation state
- every session-live handle

## lifecycle hooks and persisted state

### `session_directory`

this runs before session bind.
it has no session id, no session-live scope, and no bound namespace state.

it may:

- read global persisted state
- influence workspace/session selection indirectly by choosing the target cwd

it must not:

- read or write session-live state
- assume any bound session-persisted state exists yet

### `session_before_switch` and `session_before_fork`

these run on the old bound generation before `session_shutdown`.

they may:

- read current binding ids
- read current session-persisted state
- flush final writes to global/workspace/session-persisted state
- veto the replacement flow

they must not:

- create live handles for the next generation
- stash old live handles expecting the next generation to adopt them

### `session_start`

this is the first callback where the new generation may use all three things together:

1. current binding ids
2. current persisted stores
3. fresh session-live lease creation

if an extension needs to recreate ui, providers, or jobs from durable state, this is the edge.

### `session_shutdown`

this is the last callback where the old generation may still see the current session binding.

it is the edge for:

- flushing session-persisted checkpoints
- flushing global/workspace writes that depend on the old session outcome
- cancelling jobs and provider work while the old binding is still meaningful

it is not an escape hatch to keep old live handles alive.

after unbind, those handles are dead.

## rebind rules by class

| class | scope | across reload/new/resume/fork |
| --- | --- | --- |
| tool registrations | namespace/generation | die with old generation; new generation re-registers or disappears |
| command registrations | namespace/generation | die with old generation; new generation re-registers or disappears |
| observer/interceptor handlers | namespace/generation | die with old generation; new generation re-registers or disappears |
| provider registrations | namespace/generation | die with old generation; new generation re-registers or disappears |
| provider instances / bound services | session-live | die at unbind; next generation creates fresh instances if needed |
| ui/status/progress/surface handles | session-live | die at unbind; next generation must reacquire fresh leases |
| jobs / subagents / timers / watchers | session-live by default | die at unbind; host cancels or detaches them by policy, never silently rebinds them |
| runtime caches / services | namespace/generation unless explicitly persisted | die at teardown |
| global/workspace/session-persisted data | persisted store | survives by scope; next generation reads it back |

for jobs and subagents, the doctrine is the same:

- live execution dies.
- durable intent or checkpoints may survive.
- restart is an explicit new launch by the new generation.

## stale-handle prevention

old generation objects must fail closed.

required rules:

- extensions never receive raw pointers to `RuntimeHost`, `AgentSession`, tui components, provider instances, or merged registries.
- every retained live handle is validated against at least `{ namespace_id, session_id, class, local_id, revoked }`.
- host methods reject or ignore stale-handle mutations by policy.
  they never retarget the mutation into the new generation.
- lifecycle dispatch stops before unbind completes.
  the old generation gets no more session-visible callbacks after that edge.
- old lua refs, callback chains, provider queues, and registry ownership die with the old namespace generation.
- persisted state rehydration copies semantic data into new host-owned records.
  it does not carry old host object identity forward.

mental model:

```text
old generation g, session a                     new generation h, session b

 tool/command/provider regs   -----X
 ui/progress/job handles      -----X
 provider instances           -----X
 old lua refs / callbacks     -----X
                                   \
                                    \  rehydrate semantic data only
                                     v
                        persisted stores -> fresh regs -> fresh handles
```

## relationship to the other docs

- [runtime-roots.md](./runtime-roots.md) stays authoritative for root normalization, precedence, and discovery order.
  this doc says those roots also define extension provenance through `runtime_root_id` and `state_owner_id`.
- [extensions-lifecycle.md](./extensions-lifecycle.md) stays authoritative for phase order.
  this doc says which state scopes survive each phase transition.
- [extensions-events.md](./extensions-events.md) should carry the reasons and binding ids defined here.
  event payloads are where extensions observe the swap.
- [extensions-retained-objects.md](./extensions-retained-objects.md) stays authoritative for host-owned live objects.
  this doc classifies those objects as session-live and therefore non-rebindable.
- [extensions-jobs-subagents.md](./extensions-jobs-subagents.md) stays authoritative for job/subagent semantics.
  this doc adds that their live handles die at unbind unless a later contract defines a different retained class.

## current zi seams this replaces or tightens

- `src/coding_agent/runtime_host.zig` already replaces the whole `AgentSession` for `/new` and `/resume`.
  this doc makes that swap an explicit extension contract instead of an implementation accident.
- `src/coding_agent/agent_session.zig` already destroys the extension runner and lua state during session replacement.
  this doc says every live extension-visible handle dies on that edge too.
- `src/coding_agent/extensions/runner.zig` models a one-way `stub -> bound` runtime.
  this doc tightens the missing half: unbind, teardown, and fresh-generation rebinding by recreation, not by rebinding one runner.
- `src/coding_agent/extensions/context.zig` still exposes `ctx.has_ui` plus `ctx.ui = nil`.
  this doc replaces nullable reach-through with session-live host leases and explicit rebinding rules.
- `src/coding_agent/extensions/api.zig` and `src/coding_agent/extensions/registries/provider_queue.zig` still model load-time registrations against one runner generation.
  this doc says provider/tool/command state is namespace/generation-scoped and never crosses swap implicitly.
- `src/coding_agent/session/store.zig` already has explicit non-context `custom` entries.
  this doc tightens their role: session-visible durable extension state belongs in the session persistence contract, not in ui state.

## parity target

pi-mono already proves three capability classes matter:

- extension context/runtime state
- provider/runtime registration state
- explicit non-context session persistence for extension data

zi keeps those capabilities, but with stricter ownership:

- durable state keys are root-qualified through `state_owner_id`
- live handles are session-live leases, not ambient objects
- rebinding happens by replay + reacquire, not by pointer survival

## non-goals

this doc does not define:

- the concrete api method names for reading/writing each state scope
- the on-disk file format for global or workspace persisted state
- migration rules across changed `runtime_root_id` values
- widget layout precedence or provider selection policy details
- a long-lived job class that survives unbind

those belong in follow-on api docs.
