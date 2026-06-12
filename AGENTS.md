# zi agent rules

build the smallest correct system. do not add machinery because another project
has it. pi-mono is a behavioral reference, not a port target. the architecture
map is `CONTEXT.md`; this file is how to build inside it.

## contract

- simple first. complexity must pay rent in current, concrete need.
- one owner. one mutation path. one obvious failure mode.
- encode state directly. no dummy fields, boolean protocols, or ambient discipline.
- compile errors beat crashes. crashes beat silent corruption.
- allocation may fail. deallocation must succeed.
- programmer error fails fast (assert). operational input degrades (sanitize,
  drop, or report) and never tears down an owner loop.
- comments explain why. types, bounds, assertions, and tests enforce what.
- one source of truth per fact. do not reimplement an encoding, equality, or
  policy that a lower layer already owns.
- Events are facts.
- Snapshots are state.
- Owners hold state.
- Pipes do not smuggle unbounded state.

## before adding a boundary

answer in code, not prose:

```text
what can go wrong?
what is the maximum bound?
who owns each resource?
where is mutation allowed?
which errors are handled, and which are programmer vs operational?
which invariants must always hold?
what is the slowest resource involved?
what must a future maintainer not have to remember?
```

if the answer to "what bounds this?" is "normally it won't grow," there is no
bound. add one.

## ownership boundaries

```text
main.zig       build runtime + process, call cli. no product policy.
ai             provider protocol, models, registry, wire adapters, streams.
               no session, UI, persistence, retry/compaction, or tool policy.
agent          generic agent loop: transcript, tool execution, steering/follow-up
               queues, agent events, cancel source. must not import coding_agent or tui.
runtime        zio-backed mechanism: process, select, bounded queues, cancel
               tokens, event pipes, process runner, byte/json ownership. no app policy.
coding_agent   the app core: resources, settings, model/session config, tools,
               prompt preflight, persistence, public events, host replacement,
               CLI, and typed client protocol. no TUI or concrete frontend policy.
tui            terminal UI product + substrate. agent-agnostic. observes
               coding_agent only through commands/effects/events/snapshots via an
               external frontend adapter.
```

import rules (enforced by review; they are real today):

- `ai` imports std (+ runtime for I/O). nothing above it.
- `agent` imports std, ai, runtime. never coding_agent or tui.
- `runtime` imports std + vendored zio. never product modules.
- `tui` imports std + vendored vaxis only. never runtime, ai, agent, coding_agent.
- `coding_agent` imports ai, agent, runtime, and std. never tui or frontend adapters.
- concrete frontends live outside `src/coding_agent`; a TUI adapter may import both
  coding_agent and tui, but it is not part of the core.

## runtime discipline

`runtime` is mechanism, not policy. the shipped substrate is zio: `Process`,
`select`, `ResetEvent`, `Timeout`, `BoundedQueue`, `ReadableFd`, `EventPipe`,
`CancelSource`/`CancelToken`, `runProcess`. use them; do not build a second
runtime above them.

the invariant, whatever the mechanism:

```text
operation -> backend runs under an owner -> bounded queue -> owner drains and mutates
```

rules:

- `std.Io` enters at the process/runtime boundary and is passed down explicitly.
  no ambient I/O, no global state.
- completions are data, not authority. an owner mutates only at its drain/apply site.
- queues, buffers, resident views, retries, batches, and concurrency all have a
  named limit policy: reject, evict, backpressure, spill, or deadline/cancel.
  External totals may be unbounded only when they are spilled durably or exposed
  through a pull stream with bounded in-flight work.
- wakeups coalesce; inspect state after a wake, do not trust the wake to carry data.
- cancellation intent is not cancellation completion. observe the terminal outcome.
- shutdown is request -> stop accepting -> cancel -> drain -> stopped -> deinit.
  `deinit` must not race active work.
- do not build a central operation/completion/limits table speculatively. zio
  `select` + per-owner bounded queues already provide the property.
- `zio` is the substrate, not bare `std.Io`: zio's `std.Io` is a proactor that
  cannot poll pipe/tty fds, so pipe/tty I/O (`runProcess`, `ReadableFd`) and
  coordination stay zio-native. `std.process.run` / `Io.File.MultiReader` do not
  work for child-output capture on zio — do not reach for them.

## coding-agent rules

- `SessionRuntime` is the mailbox host and owns exactly one session for its
  lifetime. session replacement is unsupported by design: a new session is a
  new runtime, opened by the CLI. frontends never replace.
- `AgentSession` contains one long-lived `agent.Agent` and owns that session's
  policy spine, events, persistence, resources, and tools.
- the event drain is the only writer of queue mirrors, session history,
  retry/compaction state, and the public event queue. order is fixed:

```text
agent event
  -> queue/status mirror
  -> public ClientEvent queue (bounded; overflow emits event_overflow)
  -> persistence (append-only jsonl on message_end)
  -> terminal policy (retry/compaction accounting)
```

- session jsonl is durable truth. the agent transcript is runtime context. a
  persistent item reaches the jsonl before it can be dropped from any window.
- public clients communicate through commands, bounded events, and owned
  snapshots. no callback path mutates session state directly.
- option resolution is explicit -> project -> global -> default, and
  provider/model are scope-atomic (never mix project model with global provider;
  reject and record a diagnostic instead).

## tui rules

- `tui.App` is the only owner of TUI product state. all mutation goes through
  `App.apply(Command) -> ?Effect`. `Effect` is returned data, not a second
  mutation path.
- `apply` is total over operational input: oversize, invalid-UTF-8, unknown-id,
  and slot-full inputs degrade into notices or no-ops before mutation; only
  OutOfMemory propagates. it never mutates and then fails on a derived event,
  projection, or render. time enters only through `Command.tick`; App never
  reads a clock.
- the TUI is agent-agnostic. commands carry the domain-neutral
  `Transcript.Append` (message / status / tool). any `ClientEvent -> Command`
  translation lives in a frontend adapter outside `src/tui` and outside
  `src/coding_agent`.
- Vaxis owns terminal mechanism: raw tty setup, parsing, capability detection,
  screen cells, windows, borders, diff/render, and terminal primitive encodings.
  Zi owns product policy: transcript, composer, commands/effects, session adapter
  mapping, bounded resident state, and the frontend owner loop.
- rendering is a transaction through Vaxis: `render.draw` paints into a Vaxis
  screen/window (infallibly), `vaxis.render` writes terminal output synchronously
  at the render site, and product state stays dirty until the write succeeds.
  terminal output is single-owner (`tui.Terminal`) and synchronous at the render
  site.
- do not reintroduce Zi-owned terminal substrate/infra/primitive layers. no local
  ANSI encoders, raw-mode managers, cell buffers, diff renderers, style/color
  encodings, or grapheme/width engines unless a concrete Vaxis gap is proven and
  bounded. use Vaxis styles/colors/windows/borders/unicode/gwidth. policy modules
  take `Style`/`Color` from `theme.zig`; only Terminal/render/input/text import
  vaxis directly.
- transcript is bounded resident domain state with explicit item/byte caps and
  oldest-first eviction (a single tool preview is capped at a fraction of the
  total). wrapping and scrolling use display rows, not newline counts.
  layout/scroll work must be O(viewport + items), not O(resident bytes): count
  and draw share one row producer (`render.buildItemRows`), and per-item row
  counts memoize in `Transcript.Item.layout` keyed by (item version, width,
  expanded) rather than hidden caller discipline.
- product drawing helpers may exist only as Zi policy adapters over Vaxis
  primitives (for example transcript wrapping or tool chrome). they must not grow
  into a second terminal substrate.
- streamed agent/tool text is operational input. a fragment, an invalid-UTF-8
  split, or an oversized payload is sanitized or dropped — it must never
  propagate as a fatal error out of the owner loop.
- the concrete TUI frontend must keep Zi's event-driven owner loop: zio `select`
  over terminal input readiness, session/agent progress, public-event wake,
  command wake, and an animation-gated frame timer (~16ms while a shimmer is
  live, slow idle heartbeat otherwise — an idle zi must not spin). typing must
  not be required for shimmer or transcript progress; frame ticks and session
  wakes must render without input.
- do not use `vaxis.Loop` for Zi's product loop by default. it is a thread + queue
  runtime and creates another lifecycle/overflow boundary. If it is introduced,
  document the queue bound, overflow policy, shutdown order, and why the extra
  owner boundary pays rent. Zi may use `vaxis.Parser`/rendering while Zi owns
  scheduling and mutation.
- any TUI owner that stores Vaxis/Tty state must be pinned once initialized. Do
  not return or copy it by value after fields can point into its own storage
  (for example tty buffers, env maps, parser/terminal state, or spawned worker
  context). Prefer heap allocation or another explicit pinning strategy, and
  document the invariant on the type.
- defer modal surfaces, extra themes, composer history/completion, and extension
  UI until a second concrete owner proves the seam. extensions will request
  through the same commands/status contributions built-ins use; they never get
  mutable stores or raw cells.

## tools

- tools are definition-first: metadata + JSON schema + prompt text + impl. the
  core agent receives borrowed `agent.AgentTool` views only.
- builtin set: read, ls, grep, find, bash, edit, write. heterogeneous adapters
  belong at the registry boundary; the active set is bounded.
- file mutation has one path (`FileMutationQueue`). tool output is bounded by
  `tool_output_policy`. process tools need timeout and cancel before shipping new
  capability (bash cancel is cooperative today; a hard interrupt is north star).

## paths and resources

- all path policy lives in `src/coding_agent/paths.zig`.
- use `.zi`, never `.pi`, in Zi-owned behavior. global/user (`~/.zi/agent`) and
  project (`<cwd>/.zi`) are separate concepts even though both use `.zi`.
- do not hardcode `.zi`, `settings.json`, `auth.json`, `skills`, `SYSTEM.md`, or
  `APPEND_SYSTEM.md` outside the path owner. `ZI_CODING_AGENT_DIR` overrides the
  agent dir.

## zig craft

- read before writing. trace before fixing. use the local Zig 0.16 toolchain and
  vendored sources as the source of truth; do not design around removed pre-0.16 APIs.
- protocol types describe shape, not ownership; owned wrappers describe lifetime.
- small structs, explicit lifetimes, minimal scope. pass `std.mem.Allocator` and
  `std.Io` explicitly; no ambient resource access.
- state machines over callback control flow. expose borrowed slices only for the
  lifetime of the owner call.
- `errdefer` for partially initialized owners. every `deinit` releases all owned
  memory and poisons `self` (`self.* = undefined`) when practical.
- prefer fixed arrays or bounded owned buffers over unbounded lists. owned text
  fields are named by domain, not by `owned_*` prefixes.
- use `std.json.encodeJsonString` (or the runtime json helpers) for JSON strings;
  do not hand-roll escaping. validate at boundaries with `std.unicode`.

## tests and gates

run before claiming done:

```sh
zig build test     # lib + exe unit tests
zig build          # full build
zig fmt --check src
```

run focused behavior when relevant, e.g.:

```sh
zig build run -- "hello"
```

test invariants and behavior, not helper existence. use narrow assertions.
test names describe behavior. cover error paths and bounds, not just happy paths.
do not claim a result you have not run.

## git hygiene

- do not commit or push unless asked. ask for the commit scope first.
- stage files explicitly. never `git add -A` or `git add .`. keep unrelated
  changes untouched.
- conventional commits: `type(scope): imperative summary`. no emojis, no
  generated-by footers.
