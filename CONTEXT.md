# zi context

Zi is a Zig coding agent. It borrows product behavior from `.references/pi-mono/`,
but the implementation is Zi-shaped: bounded, explicit, owned, and small.

The goal is not to port a TypeScript architecture. The goal is to preserve what
users feel — session continuity, reliable tools, prompt/resources, model
selection, print/interactive modes, and observable cancellation — on top of a
substrate Zi fully owns and can reason about.

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
  tui/           Zi-owned terminal UI (substrate/infra/primitive/product)
  frontends/     concrete client adapters; print today, TUI dormant
  main.zig       process init -> runtime.Runtime -> cli.main
  root.zig       public package surface (ai, agent, coding_agent, runtime, tui)
```

dependency direction points one way. higher layers import lower layers, never
the reverse:

```text
ai        depends on std (+ runtime mechanism for I/O). knows nothing above it.
agent     depends on std, ai, runtime. must not import coding_agent or tui.
runtime   depends on std + vendored zio. pure mechanism, no product policy.
tui       depends on std + vendored uucode only. no runtime, agent, ai, or coding_agent.
coding_agent  depends on std, ai, agent, and runtime. no tui or concrete frontend adapters.
```

two facts follow from this and are load-bearing:

- `src/tui` is agent-agnostic. it never names a session, provider, tool, or
  agent event. any bridge between `tui` and `coding_agent` lives outside both
  modules as a concrete frontend adapter.
- `src/agent` is product-agnostic. it runs any tool set against any provider;
  Zi-specific policy lives in `coding_agent`.

vendored dependencies are deliberate and minimal: `zio` (lalinsky/zio, the Zig
0.16 `std.Io` runtime — task spawning, channels, select, cancellation) and
`uucode` (grapheme segmentation and display width). The model catalog is
generated into `src/ai/models.generated.zig` via `zig build generate-models`.

## coding-agent spine

```text
main.zig
  builds runtime.Runtime, wraps it in runtime.Process, calls top-level cli.main.
  owns no session or product policy.

cli/
  parses args, resolves a mode, dispatches concrete clients:
    print/text   -> frontends/print        (--print or non-tty stdin)
    json         -> frontends/print (json) (--mode json)
    rpc          -> rejected (not implemented yet)
    interactive  -> rejected until the TUI frontend adapter is wired
    auth         -> coding_agent auth_mode login/logout/status
  resume/list selection runs through coding_agent session listing before a host is created.

coding_agent.sdk
  the public host API: createRuntimeHost, resumeRuntimeHost, selectRuntimeSession,
  listRuntimeSessions. returns RuntimeHostHandle { services, host }.
  deinit order is fixed: host first (shutdown/drain/deinit), then services.

RuntimeServices
  cwd-scoped, long-lived services: duped cwd + agent_dir, SettingsManager,
  AuthManager, ModelRegistry, ProviderRegistry and its provider instances,
  and resolution diagnostics. owns or borrows the zio runtime explicitly.
  exposes paths() as a borrowed view; it stores no self-referential path fields.

session_config.resolve
  explicit options + services -> AgentSessionRuntimeHost.BaseOptions.
  precedence: explicit option -> project settings -> global settings -> default.
  provider and model are scope-atomic: a project model paired with a global
  provider is rejected and recorded as a diagnostic, not silently mixed.

AgentSessionRuntimeHost
  owns the current AgentSession and the only session-replacement path.
  replacement builds the next session before invalidating the old one, drains
  the old session's events, then swaps and rebinds. frontends never replace.

AgentSession
  owns one session's policy: prompt resources, system prompt, builtin tools and
  tool registry, session manager, optional session store, the long-lived agent,
  a bounded public AgentSessionEvent queue, the queue mirror, the event drain,
  lifecycle state, and compaction/retry settings.
  a prompt run is a LivePromptRun { cancel token, event stream, bounded event
  buffer, prompt }. prompt() is session preflight, not a raw Agent.prompt call.

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

Zi owns its terminal substrate end to end. there is no libvaxis (removed in
ADR 0013). the layering is rings, dependencies pointing inward:

```text
tui/substrate   terminal lifecycle, raw mode, size query, ANSI, semantic-free input decoding
tui/infra       bounded cell buffers, output staging, the double-buffer diff renderer
tui/primitive   color, style, rect, grapheme/width text policy, border chrome
tui/product     ProductApp, composer, transcript, frame, keys, theme, the owner loops
```

`substrate`, `infra`, and `primitive` never mention a product concept
(transcript, composer, tool, assistant, session). they could render any app.

`ProductApp` is the single owner of TUI state (composer, transcript, scroll,
theme, dirty flag). all mutation goes through one path:

```text
ProductApp.apply(Command) -> ?Effect
  Command : resize | input | clear_composer | append_transcript | tool_output_delta
  Effect  : submit_text | request_shutdown
```

`Command` carries a domain-neutral `TranscriptAppend` (message / status / tool),
not agent types. `Effect` is returned data, never a second mutation path.

rendering is a transaction. `frame.build` paints `ProductApp` state into the
renderer's next cell buffer; `Renderer.stage` diffs next against current into a
bounded `FrameOutput`; the bytes are written; only then does `commit` swap
buffers. a write failure `discard`s and leaves state dirty, so the next frame
re-paints. terminal output is single-owner and synchronous at the render site.

no TUI bridge is part of `coding_agent`. A future concrete frontend adapter will
own the wake loop, translate `ClientEvent` into TUI `Command`s, and turn TUI
`Effect`s into `ClientCommand`s. Until that adapter is wired, interactive mode is
explicitly unsupported.

transcript is bounded resident state (item and byte caps, oldest-first eviction).
wrapping and scrolling are measured in display rows, not newline counts. visible
rows are projected fresh each frame through one newest-first row stream shared by
both scroll-counting and drawing, so the two cannot drift. Scroll/layout caches
key off transcript revision and viewport shape, not caller discipline, so direct
transcript mutation cannot silently leave stale layout facts.

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
  commands. it never reaches into `host.currentSession().agent`, the session
  manager, providers, tools, settings, auth, or model owners.

the public boundary type is `AgentSessionEvent`:

```zig
pub const AgentSessionEvent = union(enum) {
    agent_event: agent.AgentEvent,
    queue_update: QueueUpdate,
    prompt_command: PromptCommand,
    compaction_start: CompactionStart,
    session_info_changed: SessionInfoChanged,
    compaction_end: CompactionEnd,
    auto_retry_start: AutoRetryStart,
    auto_retry_end: AutoRetryEnd,
    public_event_overflow: PublicEventOverflow,
};
```

notes:

- the queue is bounded. on overflow, events are dropped and a single
  `public_event_overflow { dropped_count }` is emitted so clients learn of loss.
- stored string payloads are owned; the drained event's `deinit` frees them.
- compaction/retry events are protocol vocabulary; the recovery behavior behind
  some of them is still on the north star.

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

- pull-based / operation-backed provider streaming, so backend production and
  owner drain run concurrently with bounded memory, backpressure, and clean
  cancellation (today the provider fills a bounded buffer synchronously).
- retry and compaction wired as real terminal session policies (the events and
  settings exist; automatic recovery and overflow-triggered compaction do not).
- a hard, enforced bash timeout/interrupt (today cancel is cooperative polling).
- an owned `ModelRegistry` that runtime providers can register into (today the
  catalog is generated and static).
- an RPC mode (today rejected at dispatch).
- richer TUI product: multi-line composer, surfaces/slots, themes beyond
  `codex`, and a virtualized transcript layout whose work is O(viewport), not
  O(history). each enters only when a second concrete owner or real pressure
  proves the seam — one adapter is a hypothetical seam, two make a real one.
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
