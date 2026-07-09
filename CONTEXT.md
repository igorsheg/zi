# zi context

Zi is a Zig coding agent built around the completed gen-3 architecture: one
interactive owner loop, one runtime, direct function calls between product owners,
and bounded presentation state. Future work should deepen that shape, not create
new translation tiers around it.

`docs/gen3-tui-plan.md` is the architecture record and trap list for the frontend
migration. Its phase checklist is historical now; its constraints remain useful
review vocabulary.

## Product references

**`.references/pi-mono/`** is a behavioral and visual reference. Use it to answer
"what should this feel like?" Do not copy its layering or framework choices.

**`docs/gen3-tui-plan.md`** records why gen-1/gen-2 failed: too many in-process
protocol/view-model layers between the agent and the screen. Use it to reject
new translation corridors.

## Architecture in one sentence

`cli` selects a concrete frontend; the frontend owns the driving loop; the loop
calls `AgentSession` directly; `agent.Agent` emits events; subscribers fold those
events into durable session state and bounded presentation state; Vaxis paints
the final cells.

```text
main.zig
  -> cli/root.zig
      -> tui/root.zig + tui/Loop.zig             interactive alt-screen frontend
      -> frontends/print/print_mode.zig         text/json prompt frontend
      -> coding_agent/auth_mode.zig             auth commands

coding_agent/session_bootstrap.zig
  -> AgentSession.zig
      -> agent.Agent                            provider/tool turn loop
      -> session_manager.zig                    durable jsonl session log
      -> tool_registry.zig + tools/*            builtin tools
      -> settings/auth/resources/path owners

runtime/*                                      std.Io-first mechanism only
ai/*                                           provider protocol and models
tui/*                                          Vaxis terminal product
```

## Ownership language

Use these terms consistently in design notes, reviews, and comments.

**Owner**
The struct or loop allowed to mutate a piece of state and responsible for its
shutdown/deinit. If you add mutable state, name the owner first.

**Bounded policy**
The explicit behavior at an accumulation point: reject, evict, backpressure,
spill, or deadline/cancel. "Should stay small" is not a policy.

**Concrete frontend**
A process-facing adapter that owns a user-visible driving loop. Today:
`src/tui` for interactive alt-screen and `src/frontends/print` for text/json.
Concrete frontends may bridge `coding_agent`, `agent`, `ai`, and `runtime`.

**RuntimeServices**
Cwd-scoped service bundle shared by concrete frontends: cwd, agent dir, settings,
auth, provider registry, providers, and the host task runtime.

**AgentSession**
One session's policy spine: prompt resources, system prompt, builtin tools,
durable history, long-lived `agent.Agent`, lifecycle, retry, compaction,
settings-facing mutations, and private session event state.

**agent.Agent**
Product-agnostic turn loop. It owns provider streaming, runtime transcript
context, tool execution, and steering/follow-up queues. It does not know TUI,
print mode, settings files, or session jsonl.

**AgentEvent**
The in-process event stream from `agent.Agent`. Events are consumed directly by
subscribers; they are not converted into a second protocol for in-process use.

**Durable session log**
Append-only jsonl session truth: header, message entries, compaction entries,
and durable session facts such as model/thinking changes. It is not the screen
transcript.

**Transcript**
The bounded TUI render fold owned by `src/tui/Transcript.zig`. It is rebuilt from
live `AgentEvent`s or restored session entries and exists to render the screen.
It is presentation state, not durable truth.

**Loop**
The interactive TUI owner in `src/tui/Loop.zig`: input actions, editor, picker
stack, viewport, run driving, notices, trace counters, and frame composition.
It calls `AgentSession` directly.

**Screen**
`src/tui/screen.zig`: cell/line/frame primitives, the Kanso color tokens, and the
Vaxis paint adapter. It holds no product state.

**Text shimmer**
`src/tui/text_shimmer.zig`: the only permitted ad-hoc/interpolated RGB color
exception. It exists solely for the working-status gradient; other UI colors use
semantic tokens from `screen.zig`.

**Chrome**
`src/tui/chrome.zig`: composer, picker/completion listbox, status/footer, and
viewport chrome. It composes already-owned state; it does not drive sessions.

**Blocks**
`src/tui/blocks.zig`: transcript block rendering, especially tool-call UX. Tool
visual policy belongs here, with neutral display data coming from `Transcript`.

**Vaxis**
Vendored terminal mechanism: raw tty, parser, screen/window primitives, borders,
diff/render, styles, color, and Unicode width. Zi should not duplicate these
mechanisms locally unless a bounded Vaxis gap is demonstrated.

**Resource path policy**
All `.zi`, settings, auth, skills, prompt-resource, session, and agent-dir path
policy belongs in `src/coding_agent/paths.zig`. `ZI_CODING_AGENT_DIR` overrides
the agent dir.

## Binding relationships

- `main.zig` owns process/runtime setup only, then calls `cli.main`.
- `cli/` parses flags/modes and dispatches to a concrete frontend or auth.
- `frontends/print` owns non-interactive prompt execution and process output.
- `tui` owns the interactive terminal product and may sample concrete
  `AgentSession` facts directly.
- `coding_agent` owns product policy shared by frontends: sessions, resources,
  settings, tools, auth, persistence, file completion, slash-command catalog, and
  bootstrap.
- `agent` owns the generic provider/tool turn protocol.
- `ai` owns provider APIs, model catalog, wire adapters, and stream shapes.
- `runtime` owns mechanism only: tasks, wakes, event pipes, process I/O, and zio
  adaptation.

## Import shape

```text
ai            -> std (+ runtime I/O mechanism where needed)
agent         -> std, ai, runtime
runtime       -> std publicly; zio private behind src/runtime/zio_backend.zig
coding_agent  -> std, ai, agent, runtime
tui           -> std, vaxis, ai, agent, coding_agent, runtime
frontends     -> std, ai/agent/coding_agent/runtime as concrete adapters need
cli           -> concrete frontend selection and process policy
```

Lower layers do not import higher layers. `coding_agent` never imports `tui` or
`frontends`. `agent` never imports `coding_agent`. `runtime` never imports product
policy. `vaxis` imports stay inside `src/tui`.

## Gen-3 invariants

1. **No in-process protocol corridor.** Agent-to-screen is a function call and
   subscriber dispatch, not envelopes, view models, wire protocols, or client
   protocols.
2. **One owner per visible fact.** If a fact is displayed, the owner that knows
   its cause should compose the user-facing copy or display contract.
3. **One transcript representation.** TUI has one bounded `Transcript` plus dirty
   derived layout/cache state. Do not add mirrors with revision taxonomies.
4. **One wait point.** The frame loop waits on input/runtime wake sources with a
   deadline. Producers wake; owners inspect state.
5. **Streaming-first.** Assistant text, thinking, tool calls, and tool output are
   folded live. Backpressure belongs to bounded runtime pipes, not UI throttles.
6. **Alt-screen is intentional.** Terminal scrollback is not the product history;
   Zi owns virtual scrollback and export/copy features explicitly.
7. **Vaxis owns terminal mechanics.** Zi owns product layout and semantics, not
   ANSI encoders, raw-mode stacks, cell buffers, diff renderers, or width engines.
8. **Persistence precedes live mutation for durable facts.** Model/thinking/session
   facts are stored before the live agent state changes.
9. **Ephemeral sessions are explicit policy.** `--no-session` is a frontend/session
   bootstrap policy, not an inference from nullable internals.
10. **Tests use real frontend paths.** E2E tests drive provider resolution through
    `ZI_ENABLE_FAUX_PROVIDER=1`; do not inject stream callbacks to bypass runtime
    services.

## Common ambiguities to resolve this way

- **Session history vs transcript**: jsonl is durable truth; `Transcript` is UI
  presentation state.
- **Wake vs payload**: a wake carries no data and grants no mutation authority.
  After waking, inspect the owned state.
- **Cancel request vs completion**: cancel is intent; owners still drain/settle and
  observe the terminal outcome before deinit.
- **Settings vs session facts**: global/project settings are owned by
  `SettingsManager`; durable per-session facts are owned by `SessionManager` and
  `AgentSession`.
- **Picker focus**: the composer is the omni input. Pickers are listbox frames
  filtered by composer text, not nested modal inputs.
- **Tool display vs tool execution**: execution belongs to `agent`/tool runners;
  display policy belongs to TUI `Transcript`/`blocks`.
- **Behavior reference vs architecture reference**: pi-mono can answer UX parity
  questions; gen-3 answers ownership and dataflow questions.
