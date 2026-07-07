# zi context

Zi is a Zig coding agent. It keeps the product feel of `.references/pi-mono/`
while using Zi-owned, bounded Zig mechanisms instead of porting that codebase.

## Language

**Behavioral reference**:
`.references/pi-mono/`. Use it to understand product behavior. Do not copy its
architecture by default.
_Avoid_: upstream, source of truth

**Bounded policy**:
The named behavior at an accumulation point: reject, evict, backpressure, spill,
or deadline/cancel.
_Avoid_: "normally small", "should not grow"

**Owner**:
The struct or loop allowed to mutate a piece of state and responsible for its
shutdown/deinit.
_Avoid_: manager (unless the code already uses that name)

**TUI Loop**:
The terminal owner loop in `src/tui`: input decoding, run driving,
transcript folding, viewport, chrome, and rendering cadence. It owns visible
terminal state and samples session facts directly through `AgentSession`.
_Avoid_: mailbox, ViewModel

**Runtime mechanism**:
`src/runtime`: `std.Io`-first process/runtime support, bounded queues, wakes,
cancel tokens, event pipes, process running, byte/json ownership. Vendored `zio`
is a private backend adapter.
_Avoid_: app runtime, product layer

**Print frontend**:
The headless prompt runner in `src/frontends/print`. It drives an
`AgentSession.RunHandle`, writes assistant deltas or JSON events, and exits
with a process-ready status code.
_Avoid_: stub frontend

**RuntimeServices**:
Cwd-scoped services shared by concrete frontends: cwd, agent dir, settings,
auth, provider registry, provider instances, and the host task runtime.

**AgentSession**:
One session's policy spine: prompt resources, system prompt, builtin tools,
durable history, long-lived `agent.Agent`, lifecycle, retry, compaction, and
session event state.

**agent.Agent**:
The product-agnostic transcript/tool/stream loop. It owns runtime transcript
context, provider streaming, tool execution, and steering/follow-up queues.

**Durable session log**:
Append-only jsonl session truth: header, one line per `message_end`, plus durable
session facts such as model/thinking changes. In-memory history is a bounded
view; the agent transcript is runtime context.
_Avoid_: transcript as source of truth

**AgentEvent**:
The in-process run event stream emitted by `agent.Agent`. TUI folds it into a
bounded `Transcript`; print JSON writes it line-by-line; session events persist
durable message ends.

**Transcript**:
The bounded render fold owned by TUI. It is presentation state rebuilt from live
events or restored session entries; durable jsonl remains the source of truth.

**Concrete frontend**:
Code that bridges CLI/runtime resources to product behavior. `src/tui` owns the
interactive terminal frontend; `src/frontends/print` owns non-interactive text
and JSON output.

**Vaxis**:
Vendored terminal mechanism: raw tty, parser, screen/window primitives, borders,
diff/render, Unicode width. Zi should not duplicate these mechanisms locally.

**Tool view**:
Borrowed `agent.AgentTool` metadata/schema/execute hook supplied by
`coding_agent`. The model sees the stripped schema-only `ai.Tool`.

**Resource path policy**:
All `.zi`, settings, auth, skills, and prompt-resource path policy belongs in
`src/coding_agent/paths.zig`.

## Relationships

- `main.zig` builds process/runtime and calls `cli.main`; it owns no product
  policy.
- `cli/` parses mode and dispatches to concrete frontends: TUI frame loop,
  print/text, json, parked rpc, or auth.
- `coding_agent` owns sessions, resources, settings, tools, persistence, and
  session bootstrapping.
- `agent` owns the generic turn loop and tool execution protocol.
- `ai` owns provider protocol, model catalog, provider registry, wire adapters,
  and streams.
- `runtime` owns mechanism only; product policy lives above it.
- `tui` owns the interactive terminal frontend and may bridge concrete
  `AgentSession` facts into terminal presentation.
- `frontends/print` owns the non-interactive prompt frontend.

## Import shape

```text
ai            -> std (+ runtime I/O mechanism)
agent         -> std, ai, runtime
runtime       -> std (zio private behind adapters)
coding_agent  -> std, ai, agent, runtime
tui           -> std, vaxis, ai, agent, coding_agent, runtime
frontends     -> std, ai/agent/coding_agent/runtime as concrete adapters need
```

Lower layers do not import higher layers.

## Flagged ambiguities

- **Session history vs transcript**: session jsonl is durable truth; transcript
  is runtime/UI context.
- **Wake vs state**: a wake only says "inspect owned state"; it carries no
  authority or payload. The frontend polls/drains the owner after wake/deadline.
- **Cancellation request vs completion**: requesting cancel is intent; the owner
  must still observe the terminal outcome and drain/join before deinit.
- **TUI package vs generic TUI toolkit**: `src/tui` is now Zi's concrete
  interactive frontend, not a reusable agent-agnostic toolkit.
- **Bounded external totals**: long sessions and long responses are allowed when
  spilled durably or exposed through bounded in-flight work.
