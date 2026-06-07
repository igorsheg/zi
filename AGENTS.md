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
coding_agent   the app: resources, settings, model/session config, tools, prompt
               preflight, persistence, public events, host replacement, CLI, modes.
               the only module that wires ai + agent + runtime + tui together.
tui            terminal UI product + substrate. agent-agnostic. observes
               coding_agent only through commands/effects/events/snapshots.
```

import rules (enforced by review; they are real today):

- `ai` imports std (+ runtime for I/O). nothing above it.
- `agent` imports std, ai, runtime. never coding_agent or tui.
- `runtime` imports std + vendored zio. never product modules.
- `tui` imports std + vendored uucode only. never runtime, ai, agent, coding_agent.
- `coding_agent` may import everything below it. the tui bridge lives in exactly
  one file: `src/coding_agent/interactive.zig`.

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

- `AgentSessionRuntimeHost` is the only owner of session replacement; it builds
  the next session before invalidating the old one. frontends never replace.
- `AgentSession` contains one long-lived `agent.Agent` and owns that session's
  preflight, events, persistence, resources, and tools.
- the event drain is the only writer of queue mirrors, session history,
  retry/compaction state, and the public event queue. order is fixed:

```text
agent event
  -> queue/status mirror
  -> public AgentSessionEvent queue (bounded; overflow emits public_event_overflow)
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

- `ProductApp` is the only owner of TUI product state. all mutation goes through
  `ProductApp.apply(Command) -> ?Effect`. `Effect` is returned data, not a
  second mutation path.
- a command validates and bounds before it mutates. it fails before the state
  transition or commits completely; it never mutates and then fails on a derived
  event, projection, or render.
- the TUI is agent-agnostic. commands carry the domain-neutral `TranscriptAppend`
  (message / status / tool). the `AgentSessionEvent -> Command` translation lives
  in `coding_agent/interactive.zig`, not in `src/tui`.
- rendering is a transaction: `frame.build` paints into the next cell buffer,
  `Renderer.stage` diffs into a bounded `FrameOutput`, bytes are written, then
  `commit` swaps. on write failure, `discard` and stay dirty. terminal output is
  single-owner and synchronous at the render site.
- full-frame stage + diff first. do not add dirty rectangles or retained surfaces
  until full-frame is measured too slow.
- transcript is bounded resident domain state with explicit item/byte caps and
  oldest-first eviction. wrapping and scrolling use display rows, not newline
  counts. layout/scroll work must be O(viewport + visible items), not O(history),
  with caches keyed by transcript revision and viewport shape rather than hidden
  caller discipline.
- `substrate`, `infra`, and `primitive` must not name a product concept
  (transcript, composer, tool, assistant, user, system, session, model). color
  and style encoding/equality live in `primitive`; do not reimplement them in the
  renderer.
- streamed agent/tool text is operational input. a fragment, an invalid-UTF-8
  split, or an oversized payload is sanitized or dropped — it must never
  propagate as a fatal error out of the owner loop.
- defer multi-line composer, surfaces, slots, extra themes, and extension UI until
  a second concrete owner proves the seam. extensions will request through the
  same commands/slots built-ins use; they never get mutable stores or raw cells.

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
