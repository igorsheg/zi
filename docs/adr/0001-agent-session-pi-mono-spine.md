# ADR 0001: Shape `coding_agent.AgentSession` after pi-mono semantics, translated through Tiger Style

## Status

Accepted.

## Context

Zi is a standalone Zig project, but its coding-agent architecture intentionally follows `.references/pi-mono/` behavior and product semantics where useful. `AGENTS.md` makes that project constraint explicit: Zi architecture follows `.references/pi-mono/` contracts, rewritten with Tiger Style bounds, ownership, and explicit control flow.

The immediate design question is how to introduce `src/coding_agent/AgentSession.zig` without copying TypeScript structure directly or accidentally inventing a different product model.

Pi-mono's `AgentSession` is the reference behavior:

- It is the shared lifecycle/session abstraction for interactive, print, and RPC modes, not a TUI object.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:1-14`.
- It receives the core `Agent`, `SessionManager`, settings, resources, model registry, and tool controls as dependencies.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:141-168`.
- Construction subscribes to agent events, installs tool hooks, then builds the runtime/tool registry.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:308-331`.
- Event handling is serialized and owns session policy: queue mirror updates, extension event emission, public listener emission, persistence, retry, and compaction checks.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:447-580`.
- Tool management is definition-first. Rich `ToolDefinition` metadata is preserved, then wrapped into core `AgentTool` values.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/extensions/types.ts:421-471`, `.references/pi-mono/packages/coding-agent/src/core/tools/tool-definition-wrapper.ts:29-44`, `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:2227-2316`.
- Active tool names rebuild the base system prompt from resource and tool metadata.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:792-813`, `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:893-927`, `.references/pi-mono/packages/coding-agent/src/core/system-prompt.ts:8-25`.
- Prompt submission is a session-level preflight pipeline, not a direct pass-through to `Agent.prompt`.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/agent-session.ts:942-1085`.
- Session entries are append-only tree nodes; `buildSessionContext()` is the boundary that converts session history into agent context.
  - Evidence: `.references/pi-mono/packages/coding-agent/src/core/session-manager.ts:658-668`.

Tiger Style constraints from `AGENTS.md` change the implementation shape:

- One owner mutates each resource.
- Queues, retries, batches, loops, and concurrency are bounded.
- Runtime mechanisms are not app policy.
- Completions/events are data, not authority.
- Cancellation intent is separate from cancellation completion.
- Future maintainers should not have to remember ambient callback ordering or hidden async mutation.

## Decision

`coding_agent.AgentSession` is the Zi app-policy spine above `agent.Agent`.

It owns the coding-agent policy that pi-mono centralizes in `AgentSession`, but expressed as small Zig-owned state machines and bounded drains rather than TypeScript promise chains and mutable maps.

The durable shape is:

```text
coding_agent.AgentSession
  owns app policy and session lifecycle

  ├─ agent.Agent
  │    core loop, transcript, tool execution, steering/follow-up queues
  │
  ├─ SessionManager / SessionStore
  │    append-only session tree, branch context, persistence
  │
  ├─ PromptResources / ResourceLoader-equivalent
  │    context files, skills, system prompt overrides, future extensions/prompts/themes
  │
  ├─ ToolRegistry
  │    definition-first catalog, active tool names, AgentTool views
  │
  ├─ SystemPromptState
  │    base prompt options, base prompt text, active-tool prompt metadata
  │
  ├─ EventDrain
  │    bounded serialized handling of agent events
  │
  └─ deferred policy subsystems
       extensions, prompt templates, model registry/settings, retry, compaction, bash, tree navigation
```

`agent.Agent` remains the lower-level loop/runtime owner. It does not own coding-agent policy such as resource loading, settings persistence, active tool name semantics, extension events, compaction, or bash recording.

## Implementation rules

### 1. Keep `AgentSession` phase-oriented

Initialization must be explicit and ordered:

1. Load resources.
2. Build the base tool definition catalog.
3. Build active tool registry from names.
4. Build base system prompt from active tools and resources.
5. Initialize or attach `agent.Agent`.
6. Attach event drain/persistence.

The phase order mirrors pi-mono's constructor/runtime build semantics, but avoids hidden callback dependence.

### 2. Use definition-first tools

Zi should not make the session registry a raw `[]agent.AgentTool` list long-term.

Use a coding-agent `ToolDefinition`-equivalent that can carry:

- name
- label
- LLM description
- JSON parameter schema
- prompt snippet
- prompt guidelines
- source info
- execution mode
- owned implementation/context

Then expose borrowed `agent.AgentTool` views to the core agent.

This preserves pi-mono's semantic split between product/tool metadata and core LLM execution shape.

### 3. Use comptime adapters only at the heterogeneous boundary

Use concrete typed tool structs for implementation and erase them only when inserting them into a definition-first runtime registry.

The accepted shape is:

```text
concrete ReadTool/EditTool/WriteTool
  -> ToolDefinition.init(&tool, metadata)
  -> ToolRegistry active definitions
  -> borrowed agent.AgentTool views
  -> agent.Agent
```

This is not a generic registry framework. Comptime only generates the tiny adapter from a concrete tool pointer to the uniform `agent.AgentTool` view. Runtime vtables exist only at the boundary where heterogeneous tools must share one list.

A broader comptime binder or closed tool-union framework is still deferred until bash, grep/find/ls, extension tools, and registry lifetimes stabilize.

### 4. Serialize session event policy through an owner drain

Pi-mono uses a Promise chain to serialize event processing. Zi should translate this into either:

- direct synchronous processing when the owner already emits on one stack, or
- a bounded event queue drained by `AgentSession` if events can arrive from runtime completions or concurrent sources.

The ordering invariant is:

```text
agent event
  -> queue mirror update
  -> extension/session hooks          (future)
  -> public `AgentSessionEvent` queue
  -> persistence
  -> terminal policy: retry/compaction/queued continue
```

Only the drain/apply site may mutate `SessionManager`, session queue mirrors, retry state, compaction state, or prompt state.

Pi-mono exposes this stream as `session.subscribe(listener)`. Zi exposes the same behavioral boundary as a bounded event queue drained explicitly by clients. This preserves event ordering without callback reentrancy or hidden listener mutation.

### 5. Public clients communicate through events, commands, snapshots, and a runtime host

`AgentSession` owns one current session's app policy. It should not own mode-specific frontend behavior or session replacement.

The public boundary is:

```text
TUI / CLI / print / RPC adapter
  -> AgentSessionRuntimeHost
     owns current session replacement: new / switch / fork / import / teardown / rebind
  -> AgentSession
     owns one session's prompt, queue mirror, persistence, tool/resource policy, events
  -> agent.Agent
     owns the transcript loop, tool execution, steering/follow-up queues
```

Zi's client-facing read side is:

```text
AgentSessionEvent stream
  -> bounded public event queue
  -> explicit drain by frontend/host
  -> owned snapshots for status, queue contents, tools, and session metadata
```

Zi's write side starts as direct session/host methods while the method set stabilizes. A serialized RPC protocol should be an adapter over the same command/event/snapshot semantics, not a separate app-policy path.

### 6. Prompting goes through session preflight

The public prompt API should become session-level, not `agent.promptText` pass-through.

The eventual pipeline is:

```text
prompt input
  -> command handling                 (future)
  -> input hooks                      (future)
  -> skill/template expansion         (skills first, templates future)
  -> streaming queue decision
  -> pending app-message flush        (bash/custom future)
  -> model/auth preflight             (future)
  -> pre-prompt compaction check      (future)
  -> construct user/app messages
  -> before-agent-start hooks         (future)
  -> agent prompt
  -> retry/idle wait                  (future)
```

A skeleton may implement no-op phases, but the function names and control flow should preserve this seam.

### 7. Session history is source of durable truth

`SessionManager` owns append-only history and branch structure. `AgentSession` may replace `agent.state.messages` from `SessionManager.buildSessionContext()` after compaction, tree navigation, resume, or fork.

Core `Agent` state is runtime context, not the only durable source of truth.

### 8. Encode deferred subsystems explicitly

Do not smuggle future behavior into loose booleans or nullable callbacks.

Deferred subsystems should have named placeholders or later owned structs:

- extension runtime
- model/settings registry
- retry policy
- compaction policy
- bash execution/recording
- tree navigation/fork/switch

Each subsystem must answer Tiger Style boundary questions before implementation:

```text
What can go wrong?
What is the maximum bound?
Who owns each resource?
Where is mutation allowed?
Which errors are handled?
Which invariants must always hold?
What is the slowest resource involved?
What must future maintainers not have to remember?
```

## Consequences

### Positive

- Zi keeps behavioral parity with pi-mono where it matters: session spine, tool metadata, event policy, prompt preflight, and durable session tree semantics.
- Zig implementation remains explicit about ownership and lifetimes.
- Future extensions, compaction, retry, and bash fit into known seams instead of forcing a later rewrite.
- Tool prompt metadata can be added without changing core `agent.Agent`.

### Negative

- The first `AgentSession` implementation is slightly more structured than a raw wrapper around `agent.Agent`.
- Some pi-mono features remain deferred, so early code must resist pretending those policies exist.
- Definition-first tools require an extra layer before all metadata is useful.

## Rejected approaches

### Raw `AgentSession = Agent + resources + tools`

Rejected because it misses pi-mono's main semantic contribution: `AgentSession` is policy owner for prompt preflight, event serialization, tool registry, settings/model changes, compaction, retry, bash, and tree navigation.

### Port pi-mono literally

Rejected because TypeScript promise chains, mutable maps, and extension object lifetimes do not directly satisfy Zi's Tiger Style constraints. Zi should preserve behavior, not implementation mechanics.

### Add a broad comptime tool framework first

Rejected for now because a broad binder or closed tool-union framework would solve local boilerplate before bash, grep/find/ls, extension tools, and registry lifetimes are stable. The accepted limited use is a small comptime-generated adapter at `ToolDefinition.init(&tool, metadata)`.

## Migration note for current work

If an existing draft `AgentSession.zig` only wires resources, builtins, and persistence directly to `agent.Agent`, treat it as disposable scaffolding. Prefer restarting from this ADR if reshaping it would preserve accidental structure.
