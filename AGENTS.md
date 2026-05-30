# zi agent rules

build the smallest correct system. do not add machinery because another project has it. pi-mono is a behavioral reference, not a port target.

## contract

- simple first. complexity must pay rent.
- one owner. one mutation path. one obvious failure mode.
- encode state directly. no dummy fields, boolean protocols, or ambient discipline.
- compile errors beat crashes. crashes beat silent corruption.
- allocation may fail. deallocation must succeed.
- comments explain why. types, bounds, assertions, and tests enforce what.

## runtime discipline

before adding a boundary, answer in code:

```text
what can go wrong?
what is the maximum bound?
who owns each resource?
where is mutation allowed?
which errors are handled?
which invariants must always hold?
what is the slowest resource involved?
what must future maintainers not remember?
```

runtime shape:

```text
operation -> backend -> completion -> bounded queue -> owner drain
```

rules:

- `std.Io` enters at the process/runtime boundary and is passed down explicitly.
- runtime is mechanism, not app policy.
- completions are data, not authority.
- owners mutate only at drain/apply sites.
- queues, buffers, loops, retries, batches, and concurrency are bounded.
- wakeups coalesce; inspect state after wake.
- cancellation intent is not cancellation completion.
- shutdown is request -> drain -> stopped -> deinit.
- no global runtime, hidden task spawning, callback reentrancy, or unbounded event queues.

## ownership boundaries

```text
main.zig
  parse args, create process/runtime, call sdk/mode. no core policy.

coding_agent
  owns product/session policy: resources, settings, model/session config, tools,
  prompt preflight, session persistence, public events, runtime host replacement.

tui
  owns terminal UI product semantics: transcript items, buffers, views, surfaces,
  slots, composer, actions/keymaps, and the command/event boundary. observes
  coding_agent through public commands/events/snapshots only.

agent
  owns generic agent runtime: transcript, active run, cancel source, tool loop,
  steering/follow-up queues, agent events. must not import coding_agent.

ai
  owns provider protocol, model catalog, provider registry, wire adapters, streams.
  no session persistence, UI, retry/compaction policy, or tool execution policy.

runtime
  owns operation ids, cancel tokens, bounded completion/event queues, wake/shutdown
  mechanisms. no app policy.
```

## coding-agent spine

```text
frontend / cli / rpc / tests
      |
      v
coding_agent.sdk
  create runtime/services/session host
      |
      v
RuntimeServices
  cwd-bound services: zi paths, settings, provider registry, auth/model owners later
      |
      v
session_config.resolve
  explicit options + services -> AgentSessionRuntimeHost.BaseOptions
      |
      v
AgentSessionRuntimeHost
  owns current AgentSession and replacement; frontends do not
      |
      v
AgentSession
  owns one session's app policy, preflight, events, persistence, resources/tools
      |
      v
agent.Agent
  owns transcript loop, provider stream, tool execution, steering/follow-up queues
```

invariants:

- `AgentSession` contains one long-lived `agent.Agent`.
- `AgentSessionRuntimeHost` is the only owner of session replacement.
- session replacement is commit-atomic from the host perspective.
- public clients communicate through commands, bounded events, and owned snapshots.
- no callback subscription path may mutate session state directly.
- session history is durable truth; agent transcript is runtime context.

## tui spine

```text
terminal substrate
  libvaxis: raw terminal, input, resize, cells, styles, window clipping, render.
      |
      v
src/tui/substrate/terminal.zig
  owns substrate lifecycle and hides vaxis sharp edges from app policy.
      |
      v
TuiRuntime / App
  owns TranscriptStore, BufferStore, ViewStore, SurfaceTree, SlotRegistry,
  InputComposer, ActionRegistry, KeymapRegistry, TuiCommand, TuiEvent.
      |
      v
coding_agent frontend boundary
  AgentSessionRuntimeHost commands, AgentSessionEvent drain, owned snapshots.
```

tui invariants:

- `Buffer != View != Surface`.
- transcript is domain data first; rendering is a projection.
- built-in shell is a composition, not the architecture.
- public TUI mutation goes through `TuiCommand` / owner apply sites.
- TUI events are bounded and drained; do not add write-only event queues.
- surfaces render in deterministic `(layer, insertion_index)` order.
- popovers, modals, autocomplete, command palette, and toasts are surface policy,
  not special buffer kinds.
- slots are named, bounded contribution points; extensions do not own layout.
- future Lua extensions use the same commands/events/actions/slots/renderers as
  built-in code.
- extensions request; owners mutate.
- TUI must not touch `host.currentSession().agent`, provider internals, session
  manager internals, or tool internals.
- TUI should use `startPromptRun`, `stepPromptRun`, `cancel`, `continueRun`,
  `drainPublicEvent`, and owned snapshots.

tui source boundaries:

- `src/tui/substrate/`: libvaxis lifecycle, terminal adapter, PTY/vscreen tests.
- `src/tui/primitive/`: bounded retained facts such as buffers, views, surfaces,
  slots, commands, events, actions, and transcript items.
- `src/tui/component/`: reusable domain components and renderers built on
  primitives.
- `src/tui/composition/`: deterministic arrangements of primitives/components.
- `src/tui/bridge/`: owner of stores, dispatch, event application, and render
  coordination.
- `src/tui/root.zig`: public re-export surface for callers outside `src/tui`.

do not put session, provider, tool, persistence, auth, or model-selection policy
inside `src/tui`; those belong to `src/coding_agent`.

## event policy

agent events are processed in this order:

```text
agent event
  -> queue/status mirror
  -> session hooks/extensions        future
  -> public AgentSessionEvent queue
  -> persistence
  -> terminal policy                 retry/compaction/follow-up later
```

only this owner drain may mutate queue mirrors, session history, retry/compaction state, or public event queues.

## tools

- product tools are definition-first: metadata + schema + prompt text + implementation.
- core `agent.Agent` receives borrowed `agent.AgentTool` views only.
- heterogeneous runtime adapters belong at the registry boundary.
- file mutation has one path; tool output is bounded; process tools need timeout/cancel before shipping.

## paths and resources

- all zi path policy lives in `src/coding_agent/paths.zig`.
- use `.zi`, never `.pi`, in Zi-owned behavior.
- global/user and project paths are separate concepts even if both currently use `.zi`.
- do not hardcode `.zi`, `settings.json`, `skills`, `SYSTEM.md`, or `APPEND_SYSTEM.md` outside the path owner.

## zig craft

- read before writing. trace before fixing.
- protocol types describe shape, not ownership; owned wrappers describe lifetime.
- small structs, explicit lifetimes, owned wrappers.
- state machines over callback control flow.
- pass allocator and `std.Io`; no ambient resource access.
- use `std.json.encodeJsonString` for JSON strings. do not hand-roll escaping.
- do not use removed pre-0.16 APIs. check local Zig 0.16 APIs when unsure.

## tests and gates

run before claiming done:

```sh
zig build test
ziglint src/coding_agent
zig build
```

also run focused behavior commands when relevant, e.g.:

```sh
zig build run -- "hello"
```

test invariants, not helper existence. use narrow assertions. test names describe behavior.

## git hygiene

- do not commit or push unless asked.
- stage files explicitly. never `git add -A` or `git add .`.
- keep user/unrelated changes untouched.
- commit messages: `type(scope): imperative summary`.
