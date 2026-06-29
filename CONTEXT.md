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

**Mailbox**:
A bounded command/event boundary owned by `SessionRuntime`. Frontends submit
commands and drain events; they do not mutate sessions directly.
_Avoid_: callback API, observer bus

**Runtime mechanism**:
`src/runtime`: `std.Io`-first process/runtime support, bounded queues, wakes,
cancel tokens, event pipes, process running, byte/json ownership. Vendored `zio`
is a private backend adapter.
_Avoid_: app runtime, product layer

**SessionRuntime**:
The stable mailbox host. It owns or borrows the task runtime for its lifetime and
owns exactly one live session slot. Session replacement builds the next slot
first, then swaps through the mailbox owner path.
_Avoid_: session service, session manager (unless referring to existing code)

**RuntimeServices**:
Cwd-scoped services replaceable with a session: cwd, agent dir, settings, auth,
provider registry, and provider instances. They borrow the host runtime.

**AgentSession**:
One session's policy spine: prompt resources, system prompt, builtin tools,
durable history, long-lived `agent.Agent`, public events, lifecycle, retry, and
compaction.

**agent.Agent**:
The product-agnostic transcript/tool/stream loop. It owns runtime transcript
context, provider streaming, tool execution, and steering/follow-up queues.

**Durable session log**:
Append-only jsonl session truth: header, one line per `message_end`, plus durable
session facts such as model/thinking changes. In-memory history is a bounded
view; the agent transcript is runtime context.
_Avoid_: transcript as source of truth

**ClientEvent**:
A public event fact emitted by `coding_agent` for frontends. It is bounded and
sequenced; overflow is itself reported as an event.

**Snapshot**:
Owned state copied out for a client, for example resume transcript state. Events
are facts; snapshots are state.

**Frontend adapter**:
Concrete bridge in `src/frontends/*`. The TUI adapter may import both
`coding_agent` and `tui`; neither core package imports the adapter.

**TUI product**:
`src/tui`: agent-agnostic terminal state and commands. It knows transcript,
composer, statuses, tools as UI concepts; it does not know providers, sessions,
or agent events.

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
- `cli/` parses mode and dispatches to concrete frontends: TUI, print/text,
  json, rpc, or auth.
- `coding_agent` owns sessions, resources, settings, tools, persistence, and the
  public client protocol.
- `agent` owns the generic turn loop and tool execution protocol.
- `ai` owns provider protocol, model catalog, provider registry, wire adapters,
  and streams.
- `runtime` owns mechanism only; product policy lives above it.
- `tui` owns terminal product state only; concrete session mapping lives in a
  frontend adapter.

## Import shape

```text
ai            -> std (+ runtime I/O mechanism)
agent         -> std, ai, runtime
runtime       -> std (zio private behind adapters)
tui           -> std, vaxis
coding_agent  -> std, ai, agent, runtime
frontends     -> bridge concrete packages
```

Lower layers do not import higher layers.

## Flagged ambiguities

- **Session history vs transcript**: session jsonl is durable truth; transcript
  is runtime/UI context.
- **Wake vs event**: a wake only says "inspect owned state"; it carries no
  authority or payload.
- **Cancellation request vs completion**: requesting cancel is intent; the owner
  must still observe the terminal outcome and drain/join before deinit.
- **TUI vs TUI frontend**: `src/tui` is agent-agnostic product state;
  `src/frontends/tui` translates `coding_agent` facts into TUI commands.
- **Bounded external totals**: long sessions and long responses are allowed when
  spilled durably or exposed through bounded in-flight work.
