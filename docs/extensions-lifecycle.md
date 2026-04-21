# extension lifecycle, namespace, and scheduler contract

## status

contract for `zi-fex.3`.
it follows [runtime.md](./runtime.md), [runtime-roots.md](./runtime-roots.md), and the [v2 cutover adr](./adr/extensions-v2-cutover.md).

## decision

- extension execution is agent-owned.
- each loaded extension owns one namespace per generation.
- merged registries are shared views over namespace-owned registrations; they do not own those registrations.
- lifecycle phases are explicit: discover, load/register, bind, `session_start` publication, steady-state execution, `session_shutdown` publication, unbind, teardown.
- reload is a generation swap.
- new-session, resume, and fork are session-replacement rebind flows.
- all extension code runs on the agent thread under a host scheduler.
- tui paint/render/input hot paths do not call lua directly.
- coalescing, redraw cadence, and coroutine resume policy are host responsibilities.

## runtime fit

this contract is the extension-side form of the runtime doctrine:

- [runtime.md](./runtime.md) defines the owner model: agent thread owns lua and extension execution; tui consumes published state.
- [runtime-roots.md](./runtime-roots.md) defines discovery inputs and precedence: every generation rebuilds from the canonical root list.

more specific follow-ons: [jobs/subagents](./extensions-jobs-subagents.md), [ui contract](./extensions-ui-contract.md), and [state rebinding](./extensions-state-rebinding.md).

put differently:

```text
runtime roots ──> discover ──> load/register ──> bind ──> session_start
                                                      │
                                                      v
                                             steady-state execution
                                                      │
                                                      v
teardown <── unbind <── session_shutdown <────────────┘
```

## namespace ownership

each loaded extension gets a namespace keyed by its generation plus its discovered extension identity.

a namespace is the owner record for every retained thing created on that extension's behalf.
this stays true even when zi exposes a merged view such as "all tools" or "all commands".

a merged registry answers product questions like "which tool wins for name x?".
it does not become the owner.
when a namespace dies, everything owned by that namespace dies with it, whether or not a merged registry had exposed it.

### namespace-owned retained classes

| class | ownership rule |
| --- | --- |
| tools | the namespace owns the registration, handler, schema, and any generation-local execution state for that tool |
| commands | the namespace owns the command registration and handler, even if command lookup exposes one merged slash-command surface |
| shortcuts | the namespace owns the shortcut registration; conflict resolution only picks the visible winner |
| flags | the namespace owns the flag declaration and any namespace-scoped retained value derived from it |
| providers | the namespace owns the provider registration and its teardown responsibility; the host-owned provider registry exposes the merged view |
| ui handles / surfaces | the namespace owns the lease or handle; the host owns the backing tui object and publication path |
| progress handles | the namespace owns the lease or handle; the host owns rendering cadence and publication |
| jobs / subagents / watchers / timers | the namespace owns the job identity, callbacks, and cancellation responsibility; the host owns the scheduler and OS-facing primitives |
| renderer state | the namespace owns any retained presentation state or renderer handle; the host owns paint cadence, buffers, and final drawing |
| caches / services / state | if the extension retains it across calls, it belongs to the namespace unless another contract says otherwise |

rules:

- ownership is per namespace, not per merged registry.
- losing a conflict does not transfer ownership to the winner.
- nothing from generation `n` is reused by generation `n+1` unless a later contract explicitly defines migration.
- host-owned primitives may outlive a callback, but their lease is still namespace-scoped and must be revoked at unbind.

## lifecycle phases

### 1. discover

discovery is pure root walking.
it reruns the [runtime-roots](./runtime-roots.md) normalization and precedence rules for the current flow, builds the canonical ordered root list, and discovers candidate extensions without executing extension code.

discover produces:

- a new generation id
- an ordered extension candidate set
- the root/precedence context each candidate belongs to

### 2. load/register

load/register creates the generation-local runtime and executes extension load code.
this is where an extension declares what its namespace contributes.

load/register may create or retain namespace-local state, but it is still session-unbound.
that means:

- registrations are allowed
- private caches/services/state are allowed
- session-bound objects are not live yet
- no tui-thread reach-through is allowed

load/register is non-suspending.
it must run to completion on the agent thread without yielding.
if an extension needs long work, it defers that work until steady-state through an explicit job/task surface.

### 3. bind

bind attaches the loaded namespace set for one generation to one concrete session.
this is the point where session-local host actions become valid.

examples:

- session context helpers become live
- provider registrations become active in the host view
- ui/progress/job leases may now be created
- command/session-control actions become callable

bind is non-suspending and ordered.
a namespace is either unbound or bound to exactly one session; there is no half-bound public state.

### 4. `session_start` publication

after bind succeeds, the host publishes `session_start` to the newly bound generation.
this is the first session-visible lifecycle event for that generation.

`session_start` publication is non-suspending.
handlers may schedule steady-state jobs, but they do not own redraw cadence or resume policy and must not block publication.

### 5. steady-state execution

steady-state is the only phase where ordinary extension work runs.
all such work is agent-thread work scheduled by the host.

### 6. `session_shutdown` publication

before a bound generation stops owning a session, the host publishes `session_shutdown` to that generation.
this is the last session-visible lifecycle event for that generation.

`session_shutdown` publication is non-suspending.
it is the extension's last chance to flush or cancel namespace-owned work while the session binding still exists.
a `session_shutdown` handler must not assume it can keep the namespace alive past unbind.

### 7. unbind

unbind revokes the session binding.
after unbind:

- the generation receives no more session-visible callbacks
- all namespace-scoped host leases are invalid
- the namespace is no longer part of any active merged runtime view

unbind is ordered after `session_shutdown` publication and before teardown.

### 8. teardown

teardown destroys the generation-local runtime and releases every retained object still owned by the namespace.
this includes registrations that never won visibility.

teardown is final.
a torn-down namespace is never rebound.

## scheduler contract

all extension code runs on the agent thread.
the host scheduler decides when extension work starts, when a yielded task resumes, and when published state reaches the tui.
extensions never call themselves from the tui thread.

```text
tui thread
  ├─ input
  ├─ layout / paint
  ├─ redraw requests
  └─ snapshot reads
        │
        │  request queue / run controls / published snapshots
        v
agent thread
  ├─ discover / load / bind / unbind / teardown
  ├─ lifecycle publication
  ├─ tool execution
  ├─ command execution
  ├─ provider callbacks
  └─ jobs / subagents / timers / watchers
```

### which work may suspend

these execution classes may suspend or yield, but only under the host scheduler and only on the agent thread:

- tool bodies
- command bodies
- provider callbacks that are explicitly surfaced as extension execution
- explicit jobs, subagents, watchers, and timers

when one of these yields, the host owns:

- resume ordering
- fairness against other agent-thread work
- cancellation and abort delivery
- snapshot publication while the task is suspended

### which work must not suspend

these classes are always non-suspending:

- discover
- load/register
- bind
- `session_start` publication
- observer/interceptor dispatch on hot decision points
- `session_shutdown` publication
- unbind
- teardown
- any render or input preparation step whose output feeds a tui hot path

if a feature needs suspension, it must move into one of the explicit steady-state execution classes above.

### hot paths that never execute arbitrary extension code inline

the following paths may enqueue work, coalesce state, or consume published snapshots, but they must not call lua or arbitrary extension code inline:

- tui input dispatch
- tui layout / paint / render
- redraw coalescing and frame cadence
- mailbox producers and wakeups
- snapshot publication
- any other fast producer path whose job is transport, not product semantics

that means the host, not the extension author, owns:

- when redraw happens
- how multiple updates coalesce
- when a yielded coroutine resumes
- how abort/run-control signals interleave with extension work

extensions produce semantic intent.
the host turns that intent into scheduling and presentation.

## reload / generation swap

reload keeps the same session and swaps generations.

visible guarantees:

```text
old generation (bound to session s)
  │
  ├─ publish session_shutdown { reason = reload }
  ├─ unbind old generation from session s
  ├─ discover current runtime roots again
  ├─ load/register new generation
  ├─ bind new generation to session s
  ├─ publish session_start { reason = reload }
  └─ teardown old generation
```

rules:

- only one generation is bound to a session at a time.
- the old generation receives no steady-state callbacks after unbind starts.
- the new generation receives no steady-state callbacks before bind completes.
- namespace-owned objects never cross the generation boundary implicitly.
- host-visible merged registries update as part of the swap, not incrementally one callback at a time.

an implementation may prebuild the next generation earlier, but it must preserve the visible ordering above.

## session replacement rebind

new-session, resume, and fork replace the session binding target.
these flows rerun discovery from the [runtime-roots](./runtime-roots.md) source of truth, because cwd, settings, packages, and project-local roots may have changed.

visible guarantees:

```text
old generation (bound to session a)
  │
  ├─ publish session_shutdown { reason = new | resume | fork }
  ├─ unbind old generation from session a
  ├─ teardown old generation
  ├─ discover roots for replacement session b
  ├─ load/register generation for session b
  ├─ bind to session b
  └─ publish session_start { reason = new | resume | fork }
```

rules:

- session replacement is not an in-place rebind of existing namespaces.
  it is unbind old session → create next generation → bind next session.
- a generation bound to session `a` is never rebound to session `b`.
- the replacement generation starts from fresh namespace ownership, even when the same extension id is discovered again.
- any session-local host lease from the old session is invalid before the new generation starts.

## abort and run control

this contract fits zi's owner-loop model from [runtime.md](./runtime.md):

- request queue for owner-thread mutation and work submission
- dedicated run-control surfaces for in-flight abort / steering / follow-up
- published snapshots for render-speed reads

extension scheduling must fit those surfaces.
it must not smuggle product semantics through ad hoc cross-thread callbacks or direct tui → lua reach-through.

## seams this contract tightens

this contract exists because a few current seams are still truthful only in pieces:

- bootstrap currently collapses discovery, load, lua-state setup, and base-tool registration into one construction step.
  v2 separates discover, load/register, bind, and publication as distinct phases.
- the current runner models only `stub -> bound`.
  v2 adds explicit unbind, teardown, generation swap, and session-replacement guarantees.
- the current scheduler already treats tool execution as the only yieldable lua path.
  v2 keeps the host-owned scheduler doctrine and extends it to every extension execution class instead of growing ad hoc exceptions.
- current slash-command execution still has a direct interactive-thread path.
  v2 moves extension command execution under the agent-owned scheduler.
- current request/snapshot mailboxes already show the right owner boundaries.
  v2 makes those boundaries the extension contract instead of incidental implementation detail.

## non-goals

this contract does not define:

- the detailed event payload schema for every extension event; see [extensions-events.md](./extensions-events.md)
- provider api shapes
- retained-object api details for ui/progress/jobs/state persistence; see [extensions-retained-objects.md](./extensions-retained-objects.md)
- extension author ergonomics beyond the lifecycle and scheduler rules above
