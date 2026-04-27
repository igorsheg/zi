# jobs, subagents, and `zi.system`

## status

contract for `zi-fex.7`.
it follows [extensions.md](./extensions.md), [runtime.md](./runtime.md), [extensions-lifecycle.md](./extensions-lifecycle.md), [extensions-retained-objects.md](./extensions-retained-objects.md), [extensions-events.md](./extensions-events.md), and [runtime-roots.md](./runtime-roots.md).

## decision

- generic jobs/processes and zi-native subagents are separate public classes.
- today's `zi.spawn` is a **transitional helper over a lower-level process substrate**.
  it is not the v2 public subagent contract.
- `zi.system` exists in v2 as the low-level host-owned namespace for os-facing retained primitives.
  it sits beneath and beside subagents, not above them.
- first-class subagents get their own public class.
  they are product objects with retained identity, scheduler ownership, semantic publication, and default presentation.
- subagents may internally use `zi.system` process execution, but that composition stays host-private.
  the public contract does not reduce subagents to generic child-process callbacks.
- extension-visible child updates are semantic publications and observer events scheduled by the host.
  raw stdout/jsonl callbacks are transport, not api.
- bounded concurrency, queueing, abort propagation, and redraw/publication cadence are host responsibilities.
- v2 preserves pi-mono-level subagent capability — isolated context, per-child config, streaming progress, bounded parallelism, chainable orchestration, usage, and rich output — without copying pi-mono's example-level subprocess implementation.

## why the split exists

subagents look like processes at the os boundary, but they are not "just processes" at the product boundary.

one generic process api cannot honestly carry both meanings:

- a generic process job is "run this external work and report job semantics".
- a subagent is "run a child zi agent with isolated context and publish agent semantics".

if v2 collapses them into one api, one of two bad things happens:

1. the process api accretes agent-specific fields and becomes a weird pseudo-subagent api.
2. the subagent api loses retained state, progress semantics, and rich presentation and degrades into callback soup.

v2 should do neither.

## model

```text
extension code
   │
   ├─ generic os work
   │    │
   │    └─ `zi.system.*`
   │         │
   │         ├─ process jobs
   │         ├─ timers
   │         ├─ watchers
   │         └─ other host-owned system primitives
   │
   └─ zi-native agent delegation
        │
        └─ first-class subagents
             │
             ├─ isolated child zi run
             ├─ subagent retained record
             ├─ progress retained record(s)
             ├─ transcript / presentation descriptors
             └─ observer publication
```

put differently:

```text
os-facing substrate            product-facing orchestration
────────────────────           ────────────────────────────
`zi.system.process`     ──┐
`zi.system.timer`       ──┼─ host scheduler ──> retained objects ──> tui presentation
`zi.system.watcher`     ──┘                         │
                                                    ├─ job semantics
                                                    └─ subagent semantics
```

`zi.system` is where the host exposes generic retained primitives.
subagents are where zi exposes child-agent semantics.

## public classes

| class | what the host understands | retained object | default presentation | expected use |
| --- | --- | --- | --- | --- |
| generic job/process | process lifecycle, exit status, stdout/stderr or declared outputs, timer/watcher edges | job record | minimal unless another contract adds more | shelling out, watchers, one-shot external work |
| first-class subagent | agent lifecycle, child progress, tool/message edges, usage, terminal result, queue state | subagent record plus linked progress/transcript descriptors | rich by default | delegated zi-native work with isolated context |

rules:

- job/process apis do not imply child-agent semantics.
- subagent apis do imply child-agent semantics.
- a subagent may be implemented with a child process.
  that does not make the public subagent contract a process contract.
- chain and parallel orchestration are compositions over first-class subagents.
  they do not need their own raw subprocess transport surface.

## classifying today's `zi.spawn`

`zi.spawn` currently mixes two layers:

- **substrate behavior** — spawn a child process, parse jsonl, forward abort, surface per-event callbacks.
- **subagent-shaped config** — child `zi` task, child model, child tools, child system append, child cwd.

that makes it useful today, but wrong as a v2 contract anchor.

so the classification is explicit:

- `zi.spawn` is a **transitional helper**.
- it is built on a **lower-level process substrate**.
- it carries some **subagent convenience**.
- it is **not** the future first-class subagent api.
- it is **not** the future generic process api either, because it is already too zi-shaped.

v2 therefore splits its current mixed role:

- generic retained process/job semantics move under `zi.system`.
- first-class child-agent semantics move under the subagent surface.
- any temporary `zi.spawn` compatibility layer should be documented as legacy/shim behavior, not doctrine.

## `zi.system`

### role

`zi.system` is the low-level namespace for host-owned primitives that touch the outside world but are not themselves zi-native agent product objects.

examples:

- process jobs
- timers
- file watchers
- maybe future host facts such as environment or platform queries

non-examples:

- tui internals
- mailbox internals
- raw owner-thread wakeups
- direct thread or fd borrowing across the api boundary
- first-class subagents

### layer

`zi.system` sits **beneath/beside** subagents:

```text
                 +----------------------+
                 |   first-class        |
                 |     subagents        |
                 | product semantics    |
                 +----------+-----------+
                            |
                            | may use
                            v
                 +----------------------+
                 |     `zi.system`      |
                 | host-owned substrate |
                 | process/timer/watch  |
                 +----------+-----------+
                            |
                            v
                 +----------------------+
                 | os / files / child   |
                 | processes / clocks   |
                 +----------------------+
```

this keeps the architecture honest:

- `zi.system` is generic.
- subagents are semantic.
- the host may compose them.
- extensions are not forced to.

## first-class subagent contract

first-class subagents must carry this bundle directly.

| capability | contract |
| --- | --- |
| isolated context | each subagent runs with its own child-agent context window and runtime state. no implicit message or tool-state sharing with the parent beyond explicit input/config. |
| config | child config includes cwd, model, tool set, system prompt or system append, plus future runtime-root/agent-definition inputs defined by the resource contracts. |
| progress/event streaming | child semantic edges publish through host-owned retained state and observer events. no raw stdout callback table is the public shape. |
| abort propagation | parent run abort, namespace teardown, and explicit child cancel all converge on one host-owned cancellation path. queued children may be dropped; running children must receive abort promptly. |
| bounded concurrency / queueing | launch goes through a host scheduler with explicit policy. callers can request queue behavior, but the host may enforce tighter caps. |
| retained state | the child has a stable retained record while it exists, including queue/running/terminal state and semantic metadata needed for presentation and observation. |
| default rich presentation | the product renders a useful collapsed and expanded view from retained semantics without each extension building custom tui. |
| result collection | callers can observe live state and can also explicitly await or collect final result state through a scheduler-owned join surface. |

### scheduling shape

subagents should not be one giant blocking call.

the clean shape is two-phase:

1. **create / enqueue** — non-suspending, returns a retained handle or id.
2. **await / collect** — optional, yieldable, waits for terminal state or returns the latest retained snapshot.

that gives v2 the thing current `zi.spawn` lacks:

- creation without immediate callback nesting
- observation without raw read-loop hooks
- waiting without making launch and lifecycle the same api call

## scheduler and ownership rules

### owner split

- the host owns the scheduler, queue, subprocess handles, protocol parsing, and publication cadence.
- the namespace owns the request, observer registrations, and cancellation intent for children it created.
- the tui owns materialized views.
- extensions do not own child-process handles, reader loops, or tui components.

### extension execution rule

no extension code runs inline on:

- child stdout read loops
- watchdog threads
- timer threads
- watcher callbacks from the os

those paths may parse, buffer, and commit retained semantic state.
extension-visible work resumes later on the agent thread under the host scheduler.

that is the anti-callback-soup rule.

### queueing rule

subagent launch requests enter a scheduler-owned queue.

minimum guarantees:

- queue state is retained and observable
- concurrency is bounded
- ordering policy is explicit
- queue admission failure is explicit
- abort removes queued children before launch when possible
- namespace teardown cancels queued and running children

`src/agent3/control.zig` already shows the right shape: explicit queue modes, versioned snapshots, and owner-controlled drain.
`src/coding_agent/request.zig` already shows the other half: bounded mailbox admission with explicit rejection.
subagent scheduling should follow those doctrines instead of inventing callback-local queues.

## retained-state and publication fit

subagents plug into the retained-object contract directly.

a running child owns at least:

- one subagent retained record
- zero or more linked progress records
- optional transcript attachment or presentation descriptors for default rich rendering

publication rules:

- child semantic state publishes as the **subagent family**.
- child progress publishes as the **progress family**.
- transcript-visible child summaries or attachments publish through the **transcript family** when the transcript contract needs them.
- terminal edges are hard flush points, same as other retained-object terminal transitions.

practical consequence:

- fast child progress churn may coalesce.
- terminal child transitions must flush.
- the tui rebuilds presentation from semantic snapshots.
- extensions do not stream their own full child-ui trees across the owner boundary.

## event fit

subagents and generic jobs have explicit observer publication in the event contract.

`extensions-events.md` defines:

- `subagent_start`
- `subagent_update`
- `subagent_end`
- `job_start`
- `job_update`
- `job_end`

rules:

- these are observe-only classes.
- payloads are semantic subagent/job objects, not raw `AgentEvent` passthrough.
- publication happens after retained-state commit, so observers see committed state.
- update events may coalesce progress churn; terminal events are hard flush points.
- child-internal tool/message transport may feed these payloads, but is not itself the public event type system.

## parity target from pi-mono

v2 must preserve the product capability pi-mono demonstrates:

- delegated child agents with isolated context
- per-child model/tools/system-prompt/cwd config
- streaming progress while children run
- bounded parallel fan-out
- sequential chain orchestration
- abort propagation
- usage + terminal result retention
- useful default collapsed/expanded rendering

but v2 should preserve that capability at the retained-object and scheduler layer.
it should not copy pi-mono's exact "extension tool spawns `pi --mode json` and manually parses lines" implementation.

that implementation is proof that the product capability matters.
it is not proof that the implementation layer is the right public contract for zi.

## seams this tightens in current zi

this contract replaces or tightens these current seams:

- `src/coding_agent/extensions/api.zig`
  - today's top-level `zi.spawn` is split conceptually into a `zi.system` substrate role and a separate first-class subagent role.
- `src/coding_agent/extensions/runner.zig`
  - the single `current_spawn_request` / `current_spawn_result` slot becomes scheduler-owned retained job/subagent state rather than the whole concurrency model.
- `src/coding_agent/extensions/lua_tool.zig`
  - "yield only through `zi.spawn`" becomes a temporary implementation detail, not the long-term execution doctrine.
- `src/spawn/spawn.zig` and `src/spawn/types.zig`
  - raw child-process launching, jsonl parsing, and per-event callbacks become private substrate concerns.
- `src/agent3/control.zig`
  - queue-mode and versioned-snapshot doctrine should inform public scheduling semantics for subagents/jobs.
- `src/coding_agent/request.zig`
  - bounded admission and explicit rejection should inform public queue semantics for subagents/jobs.

## non-goals

this contract does not define:

- the final lua surface spelling for each subagent/job call
- final detailed payload schemas beyond the semantic cores in `extensions-events.md`
- the full generic job api surface beyond its role and ownership class
- custom ui authoring for child presentation
- persistent state migration across generation changes
