mapped the big pieces. coding-agent is much wider than agent/; it’s basically the app/runtime shell around the agent core.

.references/pi-mono/pacakges/coding-agent

```text
  pi-coding-agent
  ├─ cli / modes
  │  ├─ interactive TUI
  │  ├─ print/json mode
  │  └─ rpc mode
  │
  ├─ session runtime
  │  ├─ createAgentSession()
  │  ├─ AgentSession
  │  ├─ AgentSessionRuntime
  │  └─ session switching/forking/rebinding
  │
  ├─ persistence
  │  ├─ SessionManager
  │  ├─ JSONL tree sessions
  │  ├─ model/thinking/session metadata entries
  │  └─ branching/fork/tree navigation
  │
  ├─ resources/config
  │  ├─ SettingsManager
  │  ├─ ResourceLoader
  │  ├─ AGENTS.md / CLAUDE.md discovery
  │  ├─ skills
  │  ├─ prompt templates
  │  ├─ themes
  │  └─ packages/extensions
  │
  ├─ tools
  │  ├─ read / write / edit / bash
  │  ├─ grep / find / ls
  │  ├─ file mutation queue
  │  └─ tool definitions + wrapping
  │
  ├─ model/auth
  │  ├─ AuthStorage
  │  ├─ ModelRegistry
  │  ├─ model resolver
  │  └─ provider auth/retry settings
  │
  ├─ prompt/context
  │  ├─ buildSystemPrompt()
  │  ├─ project context files
  │  ├─ tool snippets/guidelines
  │  └─ convertToLlm image blocking
  │
  ├─ compaction
  │  ├─ context token estimation
  │  ├─ manual compaction
  │  ├─ threshold/overflow compaction
  │  └─ branch summaries
  │
  └─ extensions
     ├─ extension loader/runtime
     ├─ commands
     ├─ custom tools
     ├─ hooks: input/context/provider/tool/session
     └─ extension UI bindings
```

key observation

coding-agent has two “hearts”:

```text
                +------------------+
                |  AgentSession    |
                +------------------+
                   owns app policy
                   prompt preflight
                   persistence
                   tools/resources
                   compaction/retry
                   extensions

                +------------------+
                | SessionManager   |
                +------------------+
                   owns durable tree
                   append-only JSONL
                   branch/leaf state
                   restore context
```

the TUI/CLI/RPC modes are consumers. tools/resources/auth are dependencies. so i would not start with TUI or tools first.

## AgentSession semantic contract

Preserve these pi-mono behaviors even when Zi uses different implementation mechanics:

```text
1. AgentSession is the app-policy owner above Agent.

2. Agent emits conversation events; AgentSession decides what they mean
   for queues, persistence, retry, compaction, extensions, and UI.

3. Event processing order matters:
   queue mirror
   -> extension/session hooks
   -> public event
   -> persistence
   -> terminal policy

4. prompt() is not a raw Agent call.
   it owns command handling, input hooks, skill/template expansion,
   streaming queue choice, auth/model preflight, compaction preflight,
   pending message flush, and before-agent-start hooks.

5. streaming user input does not mutate agent state directly.
   it becomes steer/follow-up queued intent.

6. session history is durable truth.
   agent transcript is runtime context.

7. retry and compaction are terminal policies, not provider policies.

8. TUI observes session state; it does not own agent/provider/tool execution.
```

Zi translates those semantics through Tiger Style: one owner per mutation path, bounded queues, explicit terminal states, observable cancellation, and no hidden callback ownership.

recommended zi build order

### phase 1: session persistence spine

start here.

why:
- it’s the durable state model under everything.
- AgentSession depends on it.
- compaction/tree/fork/resume all depend on it.
- tests can be precise and headless.

port behavior from:
- .references/pi-mono/packages/coding-agent/src/core/session-manager.ts
- related message types in core/messages.ts

zi shape:

```text
  src/coding/
    root.zig
    session_manager.zig
    messages.zig
```

tigerstyle questions:

```text
  what can go wrong?
  - malformed JSONL
  - missing header
  - duplicate ids
  - parent id missing
  - partial write
  - branch leaf invalid
  - old session version

  maximum bound?
  - max entry size
  - max branch entries loaded
  - max tree depth
  - max session file bytes? maybe configurable later

  who owns mutation?
  - SessionManager append methods only

  where mutation allowed?
  - append entry
  - replace active leaf
  - session metadata setters

  which errors handled?
  - parse failure
  - io failure
  - invalid parent/leaf
```

this gives us a stable base.

### phase 2: system prompt + resource loader minimal

then build the prompt/context layer.

port:
- core/system-prompt.ts
- the AGENTS.md/CLAUDE.md part of core/resource-loader.ts
- defer extensions/packages/themes initially

why:
- agent needs system prompt before useful sessions.
- project context discovery is core zi behavior.
- much smaller than full ResourceLoader.

zi shape:

```text
  src/coding/
    system_prompt.zig
    resources.zig
```

first behavior:
- load global + ancestor project context files
- build default prompt
- include current date/cwd
- include selected tool snippets/guidelines
- no extensions yet

### phase 3: builtin tool definitions + tool registry

then port tools, but start narrow.

port first:
- read
- write
- edit
- bash

defer:
- grep/find/ls until read/write/bash/edit works
- extension tool wrappers

why:
- default pi behavior depends on these four.
- tool implementations force us to decide filesystem/process policy.

zi shape:

```text
  src/coding/tools/
    root.zig
    read.zig
    write.zig
    edit.zig
    bash.zig
    file_mutation_queue.zig
```

tigerstyle priorities:
- bounded output
- explicit cwd sandboxing policy
- one file mutation path
- process timeout/cancellation
- no unbounded stdout/stderr capture

### phase 4: AgentSession

then build app policy around agent.Agent.

port:
- core/agent-session.ts
- parts of core/sdk.ts

responsibilities:
- prompt preflight
- input/image handling
- active tool set
- session persistence on agent events
- model/thinking changes
- queue UI state
- reload resources
- basic extension hook placeholders

zi shape:

```text
  src/coding/AgentSession.zig
  src/coding/sdk.zig
```

current implemented spine:
- `ToolRegistry` is definition-first and exposes borrowed `agent.AgentTool` views.
- `ToolDefinition.init(&tool, metadata)` uses a small comptime-generated adapter at the heterogeneous boundary.
- `AgentSession` owns prompt resources, builtin tool definitions, active tool names, `SystemPromptState`, `SessionManager`, and core `agent.Agent`.
- `SystemPromptState` rebuilds prompt text from active tools and resources.
- `EventDrain` centralizes agent event policy order: queue mirror placeholder -> session hooks placeholder -> public event placeholder -> persistence -> terminal policy placeholder.
- `AgentSession.setActiveToolsByName()` is the single active-tool mutation path: registry -> prompt rebuild -> `agent.setTools()` -> `agent.setSystemPrompt()`.

next tightening work:
- make prompt preflight phases explicit beyond the current skill/template no-op seam.
- finish the public `AgentSessionEvent` stream as a bounded drain, not callback subscription.
- expose narrow owned snapshots for status, queue contents, tools, and session metadata instead of raw internals.
- introduce `AgentSessionRuntimeHost` before TUI/RPC so session replacement policy is not owned by frontends.

public boundary shape:

```text
frontend mode / adapter
  -> AgentSessionRuntimeHost
     owns current session replacement: new / switch / fork / import / teardown / rebind
  -> AgentSession
     owns one session's app policy: prompt preflight, queue mirror, persistence, events
  -> agent.Agent
     owns transcript loop, tool execution, steering/follow-up queues
```

Zi translates pi-mono `session.subscribe(listener)` into explicit event draining:

```text
AgentSessionEvent union
  -> bounded public queue
  -> frontend drains events and requests snapshots when it needs read models
```

this is where the previous agent package becomes useful.

### phase 5: model/auth/settings

port after the session spine exists.

port:
- settings-manager.ts
- auth-storage.ts
- model-registry.ts
- model-resolver.ts

but zi already has src/ai/ provider types, so we should not clone pi’s dependency-shaped model system directly. use pi-mono behavior as contract, zi types as mechanism.

### phase 6: print mode before TUI

print/json mode is the best first integration target.

port:
- modes/print-mode.ts

why:
- headless
- exercises AgentSession + tools + persistence
- json event output gives easy tests
- avoids TUI complexity

### phase 7+: compaction, extensions, TUI, RPC

after the spine is proven.

what to start with first

i recommend:

```text
  src/coding/session_manager.zig
```

smallest useful slice:

```text
  SessionHeader
  SessionEntry union
  SessionManager.init/create
  appendMessage
  appendModelChange
  appendThinkingLevelChange
  getBranch
  buildSessionContext
```

with tests:
- new session writes header
- append messages creates parent-linked branch
- build context follows active leaf
- fork/navigate changes leaf
- malformed/missing parent fails or is ignored according to chosen contract
- v1/v2 migration can be deferred unless we need compatibility immediately

why not start with tools?

tools are tempting, but without session manager + AgentSession they float. session persistence gives us the app’s mutation spine first. tigerstyle-wise: durable state owner before
side-effect tools.

current best next task:

```text
  implement zi coding session manager, modeled after pi-mono SessionManager,
  with append-only JSONL tree entries and buildSessionContext()
```

that creates the foundation for everything else.
