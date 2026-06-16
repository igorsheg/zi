# zi context

Zi is a Zig coding agent. It borrows product behavior from `.references/pi-mono/`,
but the implementation is Zi-shaped: bounded, explicit, owned, and small.

The goal is not to port a TypeScript architecture. The goal is to preserve what
users feel — session continuity, reliable tools, prompt/resources, model
selection, print/interactive modes, and observable cancellation — on top of
substrates Zi can reason about explicitly.

"Bounded" in Zi means bounded resident working set, bounded in-flight work, and
an explicit policy at every accumulation point. It does not mean every external
total gets a small fixed integer. Long sessions, slow networks, and long model
responses are allowed when they are shaped by one of these policies:

```text
reject        refuse input at a named cap
evict         keep a bounded resident view and drop older/lower-priority data
backpressure  keep bounded bytes/events in flight and make the producer wait
spill         append to durable storage and never load the total wholesale
deadline      bound waiting/cancellation, not the black-box operation itself
```

"Normally it will not grow" is not a policy.

This file is the architecture map and the north star. The build rules live in
`AGENTS.md`. When code and these files disagree, the code wins and these files are
wrong; fix them.

## architecture

```text
src/
  ai/            provider protocol, model catalog, provider registry, wire adapters, streams
  agent/         generic agent loop: transcript, tool execution, steering/follow-up queues, events
  coding_agent/  Zi core product/session policy and typed client protocol
  cli/           process CLI parsing and concrete mode dispatch
  runtime/       zio-backed mechanism: process, select, bounded queues, cancel, process runner
  tui/           agent-agnostic terminal UI product on vendored libvaxis
  frontends/     concrete client adapters; print, RPC, and TUI today
  main.zig       process init -> runtime.Runtime -> cli.main
  root.zig       public package surface (ai, agent, coding_agent, runtime, tui)
```

dependency direction points one way. higher layers import lower layers, never
the reverse:

```text
ai        depends on std (+ runtime mechanism for I/O). knows nothing above it.
agent     depends on std, ai, runtime. must not import coding_agent or tui.
runtime   depends on std + vendored zio. pure mechanism, no product policy.
tui       depends on std + vendored vaxis only. no runtime, agent, ai, or coding_agent.
coding_agent  depends on std, ai, agent, and runtime. no tui or concrete frontend adapters.
```

two facts follow from this and are load-bearing:

- `src/tui` is agent-agnostic. it never names a session, provider, tool, or
  agent event. the concrete TUI adapter lives in `src/frontends/tui` and talks
  to `coding_agent` only through the mailbox protocol.
- `src/agent` is product-agnostic. it runs any tool set against any provider;
  Zi-specific policy lives in `coding_agent`.

vendored dependencies are deliberate and minimal: `zio` (lalinsky/zio, the Zig
0.16 `std.Io` runtime — task spawning, channels, select, cancellation) and
`libvaxis` (terminal raw mode, parsing, screen/window primitives, diff/render,
Unicode width). The model catalog is generated into
`src/ai/models.generated.zig` via `zig build generate-models`.

## coding-agent spine

```text
main.zig
  builds runtime.Runtime, wraps it in runtime.Process, calls top-level cli.main.
  owns no session or product policy.

cli/
  parses args, resolves a mode, dispatches concrete clients:
    interactive  -> frontends/tui          (default on a tty)
    text         -> frontends/print        (--print or non-tty stdin)
    json         -> frontends/print (json) (--mode json)
    rpc          -> frontends/rpc          (--mode rpc)
    auth         -> coding_agent auth_mode login/logout/status
  resume/list selection runs through coding_agent session listing before a
  runtime is opened.

session_runtime.openSessionRuntime
  the public entry: builds RuntimeServices, resolves session options
  (explicit -> project settings -> global settings -> default; provider and
  model are scope-atomic and never mix across scopes), creates or resumes the
  session store, and constructs the one AgentSession inside a SessionRuntime.
  one runtime is one session: replacement is deliberately unsupported — a new
  session is a new runtime, opened by the CLI.

RuntimeServices
  cwd-scoped, long-lived services: duped cwd + agent_dir, SettingsManager,
  AuthManager, ProviderRegistry and its provider instances. owns or borrows
  the zio runtime explicitly.

SessionRuntime
  the client mailbox host (docs/mailbox-contract.md): bounded command and
  event queues, monotonically sequenced EventEnvelopes, the retained-event
  replay ledger, slash commands (/help, /session — handled at the mailbox,
  never reaching the model or queues), and the active-operation state machine
  whose phase (running | compacting | retry_wait) makes "a run, a summary
  run, and a retry timer at once" unrepresentable. frontends talk to it only
  through submit/drainEvent/step/waitAndApplyWake.

AgentSession
  owns one session's policy: prompt resources, system prompt, builtin tools,
  durable history (session_manager + jsonl store), the long-lived agent, the
  bounded public event queue and its drain, lifecycle, and the
  compaction/retry terminal policies. runs settle as verdicts (completed |
  failed | retry | compact); the owner loop does all waiting.

agent.Agent
  owns the transcript loop, provider stream, tool execution, and the
  steering/follow-up queues. it is generic and shared by every mode.
```

session history is durable truth: `session_store` writes append-only jsonl (a
header line, then one line per `message_end`). This is the spill policy for the
unbounded total conversation. `session_manager` is the in-memory view;
`session_history_snapshot` produces a bounded snapshot (≈512 items) used to seed
a frontend transcript on resume. the agent's in-memory transcript is runtime
context, not the source of truth.

The public boundary contracts are `docs/agent-event-contract.md` and
`docs/mailbox-contract.md`. In short: events are facts, snapshots are state,
owners hold state, and pipes do not smuggle unbounded state.

## agent runtime

`agent.Agent` plus `agent/loop.zig` drive a turn loop:

```text
drain steering queue (high priority, once per turn)
  -> stream assistant response from the provider
  -> emit message_start / message_update(delta) / message_end
  -> execute tool calls (sequential, or parallel via a bounded worker channel)
  -> drain follow-up queue (low priority) and continue or settle
```

tools reach the core loop as borrowed executable views (`agent.AgentTool`:
name, description, JSON-schema parameters, label, execute hook, execution mode).
`asTool()` strips the view down to the schema-only `ai.Tool` the model sees. the
agent does not define tools; `coding_agent` supplies them.

cancellation uses `runtime.CancelSource`/`CancelToken`. a run begins on a token,
streams, and ends when the stream is terminal or the token is requested.

the public event vocabulary (`agent.AgentEvent`) is:

```text
agent_start / agent_end
turn_start / turn_end
message_start / message_update / message_end
tool_execution_start / tool_execution_update / tool_execution_end
```

`message_update` carries an `ai.AssistantMessageEvent` sub-event: `text_start`,
`text_delta`, `text_end`, `thinking_*`, `toolcall_*`, `done`, `error`. these are
the streaming deltas a frontend renders.

streaming deltas are not guaranteed to be valid UTF-8 per chunk — a multibyte
codepoint can split across two `text_delta`s, and only surrogate sanitization
happens upstream. consumers must tolerate fragments; they must never treat a
partial-codepoint delta as a fatal error.

## ai layer

`ai` is provider protocol and models, with no session, UI, persistence, retry,
or tool-execution policy.

```text
protocol.zig   Message, AssistantContent {text, thinking, tool_call},
               AssistantMessageEvent, Tool, Model, StopReason, ThinkingLevel, Usage.
owned.zig      deep-copy / retained-message helpers for crossing ownership seams.
provider_registry.zig  dynamic provider registration keyed by api string.
models.zig     lookup over the generated static catalog (getModel/getModels/getProviders).
stream.zig     dispatch a stream request to the registered provider.
providers/     wire adapters: openai_responses, openai_codex_responses, shared SSE,
               option mapping, and faux (test-only; not registered in product).
sse.zig + utils/  SSE parsing, http, headers, streaming-json repair, oauth (PKCE).
```

product runs two registered providers today: OpenAI Responses and OpenAI Codex
Responses. assistant content carries text/thinking/tool_call (images are
user-only). provider streaming has two shapes. Product providers use pull streams: `.next`
reads network bytes, reduces SSE into one or more assistant events, and returns
as soon as an event is available. This bounds resident memory without dropping
stream deltas. Buffered streams are for faux/tests and reject with
`StreamEventBufferFull` at their fixed capacity; they are not the product network
I/O shape. The future operation-backed shape is still useful when provider
production must run concurrently with other owner work: backend production runs
under an owner, a bounded queue backpressures the producer, and the owner drains
while cancellation remains observable.

## runtime layer

`runtime` is a thin vocabulary over vendored `zio`. it is mechanism, never
product policy. the shipped surface is:

```text
Process            { arena, gpa, io: std.Io, zio_runtime, environ } context bundle
select(.{...})     zio-backed wait over named typed futures
ResetEvent         manual-reset wake (zio); coalescing wakeups
Timeout / sleep    zio time sources
BoundedQueue(T)    fixed-capacity fifo over a caller-owned buffer; pushOrDrop counts drops
ReadableFd         fd-readiness future for select integration
EventPipe          bounded event stream with a terminal result
CancelSource/Token two-phase cancel: request flips a flag + wakes; token observes
                   via a generation guard so stale tokens read as cancelled
runProcess         child execution with bounded output, timeout, and cancel
                   (SIGTERM grace period, then SIGKILL)
ByteBuilder        growable byte buffer with an optional hard cap
JsonOwned / clone  json ownership across seams
OperationId        monotonic non-zero id allocator
```

the invariant this layer protects, regardless of mechanism, is:

```text
operation -> backend runs concurrently under an owner
          -> events/completions enter a bounded queue
          -> the owner drains and mutates state
          -> cancel wakes the backend; shutdown drains, joins, then deinits
```

I/O primitive completions belong to the owner that created or armed the primitive; handoff means the receiving owner creates or arms its own primitive, not that a handle transfer moves completions.

note what is deliberately *not* built: there is no central `Operation` table,
`Completion` struct, `CompletionQueue`, or global `ShutdownState`. zio's typed
`select` plus per-owner bounded queues already provide the property; a registry
would be cargo-culted machinery until a concrete need (unified limits or
operation observability) proves otherwise.

`runtime` wraps `zio`, not bare `std.Io`, for a concrete reason: zio's `std.Io`
is a proactor that cannot poll pipe/tty fds — a std.Io file read on a child pipe
returns `WouldBlock`, or blocks uninterruptibly if made blocking. so pipe/tty
I/O (`runProcess`, `ReadableFd`) uses zio's poll-based reactor directly,
`std.process.run` / `Io.File.MultiReader` are unusable for child-output capture
on zio, and coordination (`select`, channels, `ResetEvent`, tasks) stays
zio-native by the same token. the seam is the `runtime` vocabulary, not `std.Io`.

## tui layer

Zi no longer owns a terminal substrate/infra/primitive stack. vendored libvaxis
owns terminal mechanism: raw tty setup, parsing, capability detection, screen
cells, windows, borders, diff/render, style/color encodings, and Unicode width.
Zi owns product policy and the frontend owner loop:

```text
tui/            App, Composer, Transcript, Terminal, render, input, status, theme
frontends/tui   concrete coding-agent adapter and wake/render loop
libvaxis        terminal substrate/infra/primitives
```

Do not reintroduce `tui/substrate`, `tui/infra`, or `tui/primitive` layers. Small
product drawing helpers may exist only as policy adapters over Vaxis primitives
(for example transcript wrapping or tool chrome); they must not grow into a
second terminal substrate. The vaxis import surface is deliberately small:
`Terminal.zig` (tty/render), `render.zig` (window writes), `input.zig` (events),
`text.zig` (unicode/gwidth), and `theme.zig` (the `Style`/`Color` aliases every
other policy module uses instead of importing vaxis).

`tui.App` is the single owner of TUI product state (composer, transcript,
status contributions, scroll, theme, dirty flag). all mutation goes through one
path:

```text
App.apply(Command) -> ?Effect
  Command : resize | input | tick | clear_transcript | append_transcript
          | tool_output_delta | replace_tool_output | replace_tool_footer
          | set_status | clear_status
  Effect  : submit_text | interrupt | request_shutdown
```

`Command` carries the domain-neutral `Transcript.Append` (message / status /
tool), not agent types. `Effect` is returned data, never a second mutation path.

`apply` is total over operational input: oversize pastes, invalid UTF-8, unknown
tool ids, and full status slots degrade into transcript notices or no-ops; only
OutOfMemory propagates. Streamed text is sanitized on ingest (a codepoint split
across two deltas is carried in a per-item pending tail), so stored transcript
text is valid UTF-8 by construction. Time enters only through `Command.tick`
(wall-clock ms from the frontend); App never reads a clock — the ctrl+c
double-press window and status shimmer both derive from ticked time.

rendering is a transaction through Vaxis. `render.draw` paints `App` state into
a Vaxis screen/window (infallibly); `vaxis.render` writes terminal output
synchronously at the render site; product state stays dirty until the write
succeeds. terminal output is single-owner and synchronous at the render site
(`tui.Terminal`, the heap-pinned owner of tty state and the draw scratch).

The concrete TUI frontend owns the wake loop and must block in
`SessionRuntime.waitAndApplyWake(input_fd, frame_ms)`. That select observes
terminal input readiness, session/agent progress, public-event wake, command
wake, retry deadlines, and the frame timer. `step()` and event draining happen
from this owner after wakes. Do not replace this with sleep polling, callback
mutation, or a foreign input thread: typing must not be required for shimmer,
transcript streaming, retry countdowns, or any other UI progress. The frame
timer is animation-gated: 16ms while a shimmer is live, a slow idle heartbeat
otherwise — an idle zi must not wake 60 times a second.

Input has one non-obvious platform split: Vaxis opens `/dev/tty` for raw mode,
size, and writes, while the frontend selects/reads `stdin` for readiness. This is
intentional on macOS because kqueue cannot poll `/dev/tty` reliably in this
setup. Bytes read from stdin are fed through a persistent `vaxis.Parser` on the
owner loop.

Do not use `vaxis.Loop` for Zi's product loop by default. It is a thread + queue
runtime and creates another lifecycle/overflow boundary. If it is introduced,
document the queue bound, overflow policy, shutdown order, and why the extra
owner boundary pays rent.

Any owner storing Vaxis/Tty state must be pinned once initialized. Vaxis/Tty may
store pointers into owner fields (for example tty buffers and env maps). Do not
return or copy such an owner by value after initialization; use heap allocation or
another explicit pinning strategy and document it on the type.

transcript is bounded resident state (item and byte caps; live-tail appends
evict oldest, while history-page prepends evict newest so the resident window
can slide backward). one tool's retained preview is capped at 1/8 of the total
budget so a chatty tool cannot evict the whole conversation. wrapping and
scrolling are measured in display rows, not newline counts. both
scroll-counting and drawing consume `render.buildItemRows`, the single producer
of an item's visual rows, so the two cannot drift. per-item row counts are
memoized in `Transcript.Item.layout`, keyed by (item version, width,
tools_expanded) — never caller discipline — so scroll math is O(items) and
drawing is O(viewport): items above the scroll window are skipped by cached
count without re-wrapping their text.

## public boundaries and semantic contracts

preserve these behaviors (the pi-mono lessons), not any TypeScript shape:

- `AgentSession` is shared by print, the session runtime, and tests. it is not a
  TUI object.
- `prompt()` is session preflight, not a raw `Agent.prompt` call.
- agent events are serialized and ordered through one drain.
- queue changes are visible to clients, but full queue text is read through a
  `QueueSnapshot`, not copied into every event.
- tools are definition-first; the core agent receives borrowed executable views.
- session history is append-only durable truth; the agent transcript is context.
- retry and compaction are terminal session policies, not provider policies.
- a frontend observes session state through public events, snapshots, and
  commands. it never reaches into the session, its agent, the session manager,
  providers, tools, settings, auth, or model owners.

the public boundary is `client_protocol`: frontends submit `CommandEnvelope`s
(`submit | cancel | queue.clear | snapshot | replay | shutdown`) and drain
sequenced `EventEnvelope`s carrying `ClientEvent`:

```zig
pub const ClientEvent = union(enum) {
    rejected: Rejection,
    operation_started,
    operation_finished: OperationFinished,
    shutdown_started,
    agent_event: OwnedAgentEvent,
    queue_changed: QueueChanged,
    snapshot: Snapshot,
    replay: ReplayBatch,
    replay_gap: ReplayGap,
    prompt_command: PromptCommand,
    compaction_start: CompactionStart,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,
    event_overflow: EventOverflow,
};
```

notes:

- every envelope carries a monotonically increasing `seq`; clients recover
  from gaps via `replay`, and from replay gaps via `snapshot`
  (docs/mailbox-contract.md).
- queues are bounded. on overflow, events are dropped and a single
  `event_overflow { dropped_count }` is emitted so clients learn of loss.
- stored string payloads are owned; the drained envelope's `deinit` frees them.
- retry/compaction recovery behaviors behind these events are implemented
  session policies (settle verdicts), not just vocabulary.

## cancellation and shutdown

both are two-phase. intent is not completion.

```text
cancel:   request -> keep progressing -> observe a terminal outcome
                     (completed / failed / canceled)

shutdown: request -> stop accepting work -> cancel active work -> keep draining
                  -> all owned work terminal and queues empty -> stopped -> deinit
```

`deinit()` for the runtime, TUI loops, AgentSession, Agent, providers, and tool
runners must not race active work. allocation may fail; deallocation must
succeed.

## north star

current code is honest about being a slice. the direction it is reaching for —
not yet built, and not to be built speculatively:

- operation-backed provider streaming, so backend production and owner drain
  run concurrently with bounded memory, backpressure, and clean cancellation
  (product providers pull today; concurrent production is the open half).
- manual compaction as a mailbox command (auto threshold/overflow compaction
  and bounded backoff retry shipped as settle-verdict session policies).
- a hard, enforced bash timeout/interrupt (today cancel is cooperative polling).
- an owned `ModelRegistry` that runtime providers can register into (today the
  catalog is generated and static).
- richer TUI product: modal surfaces (confirm dialogs), themes beyond `codex`,
  and composer completion. each enters only when a second concrete owner or real
  pressure proves the seam — one adapter is a hypothetical seam, two make a real
  one. (multi-line composer input, bounded prompt history, and the O(viewport)
  transcript layout shipped with the libvaxis TUI.)
- future Lua extensions that request through the same commands/events/slots the
  built-in product uses; they never receive mutable stores or terminal cells.

the parity ledger drives behavior work:

```text
docs/behavioral-parity.md
```

a behavior is done only when it has a Zi owner, a pi-mono reference, and a
public-boundary test.

## rejected shortcuts

- global runtime singleton, hidden task spawning, or callback reentrancy.
- a literal pi-mono port.
- unbounded queues, buffers, or file reads.
- env-gated fake providers in the product CLI (faux is test-only).
- callback listeners that mutate session state; only the event drain mutates it.
- json mode that emits event tags instead of real content.
- a broad tool framework before bash/grep/find/ls/edit/write prove the shape.
- `tui` reaching into `coding_agent`/session/provider/tool internals.
- terminal cells as an extension API, or write-only TUI event queues.
- treating streamed agent/tool data as a programmer error: operational input is
  sanitized or dropped, never allowed to tear down the owner loop.
- stringly-typed action ids for internal dispatch.
