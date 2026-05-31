# zi context

Zi is a Zig coding agent. It borrows product semantics from `.references/pi-mono/`, but the implementation is Zi-shaped: bounded, explicit, and owned.

The goal is not to copy a TypeScript architecture. The goal is to preserve the parts users feel: session continuity, reliable tool behavior, prompt/resources, model selection, print/TUI/RPC modes, and observable cancellation.

## current architecture

```text
src/
  ai/              provider protocol, model catalog, provider registry, adapters
  agent/           generic agent loop, transcript, tool execution, queues, events
  coding_agent/    Zi app/session policy
  runtime/         operation/cancel/event/completion mechanisms
  tui/             Zi-owned terminal UI semantics over libvaxis
  main.zig         CLI shell
  root.zig         public package surface
```

## implemented coding-agent spine

```text
main.zig
  parses CLI args
  creates process/runtime
  dispatches to coding_agent modes
  does not own session or TUI policy

coding_agent.sdk
  createRuntimeHost()
  owns Runtime { services, host }
  deinit order: host shutdown/drain/deinit -> services deinit

RuntimeServices
  owns stable cwd and agent_dir copies
  owns SettingsManager
  owns ProviderRegistry and built-in provider instances
  exposes paths() as a borrowed view; does not store self-borrowing path fields

session_config
  resolves per-session host base options
  precedence: explicit option -> project settings -> global settings -> default
  provider/model settings are scope-atomic; do not mix project model with global provider

AgentSessionRuntimeHost
  owns current AgentSession
  owns session replacement/new-session lifecycle
  replacement builds next session before invalidating old session

AgentSession
  owns prompt resources, system prompt, builtin tools, session manager, agent
  owns bounded public AgentSessionEvent queue
  owns queue mirror and lifecycle state

tui.App
  owns TUI transcript, buffers, views, surfaces, slots, composer, and TUI events
  consumes coding_agent public events/snapshots through a frontend boundary
  does not own AgentSession, tools, providers, settings, or session persistence

agent.Agent
  owns transcript loop, provider stream, tool execution, steering/follow-up queues
```

## semantic contracts from pi-mono

preserve these behaviors, not the TypeScript shape:

- `AgentSession` is shared by print, TUI, RPC, and tests. it is not a TUI object.
- `prompt()` is session preflight, not a raw `Agent.prompt` call.
- session event policy is serialized and ordered.
- queue updates are visible to clients, but queue text is read through snapshots.
- tools are definition-first; core agent receives executable views.
- session history is append-only durable truth.
- retry and compaction are terminal session policies, not provider policies.
- TUI observes session state; it does not own agent/provider/tool execution.

## tui direction

Zi's TUI is an agent workspace over libvaxis, not a port of pi-mono's TUI. See:

```text
docs/adr/0002-tui-runtime-and-extension-surface.md
docs/adr/0003-tui-world-and-extension-primitives.md
```

libvaxis owns terminal mechanics:

```text
raw terminal setup/restore
alternate screen
input decoding
resize
screen/cell model
styles/colors
window clipping
terminal rendering
```

`src/tui` owns Zi UI semantics:

```text
TranscriptStore
BufferStore
ViewStore
SurfaceStack
SlotRegistry
InputComposer
ActionRegistry
KeymapRegistry
TuiCommand
TuiEvent
```

the built-in shell is a composition:

```text
Shell composition
  Header surface
  Transcript view
  Status surface
  Composer surface
```

it is not the architecture itself.

tui contracts:

- `Buffer != View != Surface`.
- transcript items are domain facts with durability: `ephemeral` or `persistent`.
- custom persistent transcript items are session facts and must go through the
  session-owner persistence path when persistence exists.
- composer is its own subsystem for prompt editing, `@file` completion, command
  dispatch, and future attachments.
- slots are named, bounded contribution points for built-ins and future Lua
  extensions.
- popovers, modals, autocomplete menus, command palettes, confirmations, and
  toasts are z-indexed surface policy, not special buffer kinds.
- surface render order is deterministic by `(layer, insertion_index)`.
- TUI events are bounded and drained.
- extensions request changes through commands; owners mutate.
- future Lua extensions use the same commands/events/actions/slots/renderers as
  built-in code.
- `src/tui/root.zig` exports only stable frontend-facing modules; lower layers
  stay internal unless tests intentionally target them.

relationship to `coding_agent`:

```text
tui -> coding_agent.sdk / AgentSessionRuntimeHost public API
tui <- AgentSessionEvent + owned snapshots
```

TUI must not reach into:

```text
host.currentSession().agent
session manager internals
provider internals
tool internals
settings/auth/model owners
```

`coding_agent` remains the owner of product/session policy. `tui` is a frontend
runtime that presents and commands that policy through the public boundary.

## public event surface

`AgentSessionEvent` is the public boundary:

```zig
pub const AgentSessionEvent = union(enum) {
    agent_event: agent.AgentEvent,
    queue_update: QueueUpdate,
    compaction_start: CompactionStart,
    session_info_changed: SessionInfoChanged,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,
};
```

notes:

- the queue is bounded.
- string payloads use owned text when stored in events.
- full queue text is not copied into each event; clients ask for `QueueSnapshot`.
- compaction/retry events are protocol vocabulary until behavior exists.

## runtime direction

Zi should grow toward a single owner/drain runtime model:

```text
operation -> backend -> completion -> bounded queue -> owner drain
```

near term, `std.Io.Future`, `std.Io.Select`, and `runtime.EventPipe` are acceptable mechanisms. the invariant matters more than the mechanism: producers emit events/completions; owners drain and mutate.

`--mode json` exposed the provider-streaming pressure point:

```text
agent asks provider for stream
provider performs HTTP/SSE synchronously
provider fills bounded EventPipe before returning
agent cannot drain until provider returns
long output fills the pipe and stalls
```

the fix is not a larger buffer. provider streaming must become operation-backed or pull-based so backend production and owner drain run concurrently with bounded memory and explicit cancellation.

`lalinsky/zio` is a credible runtime candidate because it implements Zig 0.16 `std.Io`, task spawning, cancellation, structured concurrency, and channels. do not import it merely for buffering or queue shape. assess it only against the concrete stream-operation requirement:

```text
start provider operation
backend runs concurrently under explicit owner
events/completions enter bounded queue
owner drains and mutates session state
cancel request wakes/interrupts backend
shutdown drains, joins, then deinits
```

future runtime vocabulary:

```text
Limits
OperationId        slot + generation eventually
Operation          owner, kind, state, cancel source/token
Completion         data from provider/tool/timer/wakeup to owner
CompletionQueue    fixed-capacity fifo
Wake               non-recursive next-tick signal
ShutdownState      running/stopping/draining/stopped
```

## cancellation and shutdown

cancellation is two-phase:

```text
request cancel
  -> state becomes cancel_requested or queued work is canceled
  -> keep progressing
  -> observe terminal completion: completed / failed / canceled
```

shutdown is two-phase:

```text
request shutdown
  -> stop accepting work
  -> request cancellation of active work
  -> keep draining
  -> all owned work terminal and queues empty
  -> stopped
  -> deinit allowed
```

`deinit()` for runtime, TUI, AgentSession, Agent, provider runners, and tool runners must not race active work.

## near-term work

highest value next slices:

1. keep TUI mutation behind `TuiCommand` and observable facts behind bounded `TuiEvent`.
2. add transcript renderers so transcript is the source of truth and buffers are projections.
3. add shell composition: header slot, transcript view, status slot, composer surface.
4. add composer actions for prompt editing, `@file` completion, and slash/command dispatch.
5. connect TUI to `AgentSessionRuntimeHost` only through live-run commands, public events,
   and owned snapshots.
6. finish provider/auth/model composition without moving policy into `main.zig`.
7. add an owned auth storage seam; env lookup is a fallback adapter, not the whole policy.
8. deepen `session_config` diagnostics for unresolved provider/model/settings.
9. add runtime limits and a real operation table before TUI concurrency.
10. add bounded tool runner before process/bash tools.

## rejected shortcuts

- global runtime singleton.
- literal pi-mono port.
- dependency-shaped service locator in `AgentSessionRuntimeHost`.
- unbounded queues or file reads.
- env-gated fake provider hooks in product CLI.
- callback listeners that mutate session state.
- JSON mode that emits only event tags.
- broad tool framework before bash/grep/find/ls/extensions prove the shape.
- TUI code reaching into `AgentSession` internals instead of the host public boundary.
- terminal cells as the extension UI API.
- write-only TUI event queues.
- stringly action ids for internal dispatch.
