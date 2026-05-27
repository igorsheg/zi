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
  main.zig         CLI shell
  root.zig         public package surface
```

## implemented coding-agent spine

```text
main.zig
  parses one prompt
  creates coding_agent sdk runtime
  calls print_mode

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

near term, `std.Io.Future` and `runtime.EventPipe` are acceptable mechanisms. the invariant matters more than the mechanism: producers emit events/completions; owners drain and mutate.

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

1. finish provider/auth/model composition without moving policy into `main.zig`.
2. add an owned auth storage seam; env lookup is a fallback adapter, not the whole policy.
3. make OpenAI/Codex provider registration compile cleanly only when its dependencies are correct.
4. deepen `session_config` diagnostics for unresolved provider/model/settings.
5. add real print json mode only when it can serialize meaningful event payloads.
6. add runtime limits and a real operation table before TUI concurrency.
7. add bounded tool runner before process/bash tools.

## rejected shortcuts

- global runtime singleton.
- literal pi-mono port.
- dependency-shaped service locator in `AgentSessionRuntimeHost`.
- unbounded queues or file reads.
- env-gated fake provider hooks in product CLI.
- callback listeners that mutate session state.
- JSON mode that emits only event tags.
- broad tool framework before bash/grep/find/ls/extensions prove the shape.
