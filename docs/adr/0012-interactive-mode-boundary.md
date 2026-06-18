# adr 0012: split pi-mono interactive mode across Zi boundaries

status: partially superseded by adr 0013 and current grug simplification

date: 2026-06-01

## supersession note

The split into `tui_mode.zig`, `tui_owner.zig`, and `frontend.zig` was too much
ceremony for the current Zi shape. Current direction keeps `sdk.zig` as the
public create/resume/list host API and rebuilds interactive integration as one
small coding-agent TUI file when needed. No separate `frontend.zig` protocol
exists until multiple real frontends prove a shared read/action vocabulary.

## context

Pi-mono's interactive mode lives primarily in:

```text
packages/coding-agent/src/modes/interactive/interactive-mode.ts
```

That class is Zi's behavioral reference for interactive coding-agent behavior,
but it is not Zi's architecture target. It owns many responsibilities at once:

```text
mode entrypoint
TUI app/controller
terminal lifecycle
component tree
input routing
agent/session event handling
extension UI host
slash command UI
selectors/modals
status/footer/header
startup notices
initial prompt handling
session rebind handling
```

Zi already separates the session/runtime spine from the TUI substrate and should
not collapse those boundaries to mimic pi-mono's file layout.

## decision

Pi-mono's `InteractiveMode` maps to three Zi boundaries:

```text
src/coding_agent/tui_mode.zig
  mode entrypoint only:
  create/resume RuntimeHost
  create terminal/substrate
  create tui_owner.OwnerLoop
  shutdown/deinit

src/coding_agent/tui_owner.zig
  owner loop mechanics:
  own ProductApp, read model, transcript adapter, input scratch, frame scratch
  select terminal event, prompt progress, and host public-event wake
  drain public events and apply product commands
  render dirty frames through libvaxis

src/coding_agent/frontend.zig
  coding-agent-facing action/read-model boundary:
  submit_prompt
  cancel_run
  continue_run
  request_shutdown
  public session event read model

src/tui/*
  terminal UI substrate/product:
  composer/transcript stores
  input routing
  frame/read model
  render
  future slots/surfaces/extensions UI
```

Zi aligns with pi-mono at the mode contract and product behavior level, not at
the implementation-object level.

## behavior alignment

The following interactive behaviors must align with pi-mono through Zi's public
boundaries:

- Initial prompt behavior: `tui_mode.Options.initial_prompt` submits through
  the same public command/effect path as typed composer submit.
- Resume behavior: `session_selector` is handled by `tui_mode` and
  `AgentSessionRuntimeHost`, not by `src/tui`.
- Agent event handling: TUI observes only public session events and owned
  snapshots.
- Streaming assistant display: public event -> adapter -> transcript command ->
  one open assistant item.
- Tool execution display: public event -> transcript item/tool state. TUI does
  not inspect tool internals.
- Cancel behavior: terminal input emits cancel intent; `tui_owner` maps it to
  host cancellation or shutdown; TUI reflects public state.
- Steering and follow-up queues: surfaced through `frontend.ReadModel` and TUI
  product state, not direct session mutation.
- Extension UI behavior: future extensions contribute commands, slots, and
  surfaces. They do not receive mutable component trees or store pointers.

## invariants

- `src/tui` must not import `coding_agent`, `agent`, `ai`, session, provider,
  persistence, auth, or tool internals.
- `src/coding_agent/tui_mode.zig` and `src/coding_agent/tui_owner.zig` may
  import both `coding_agent` and `tui` because they are integration modules.
- `src/coding_agent/frontend.zig` owns frontend-facing action/read-model shapes
  for coding-agent behavior.
- `src/tui` owns terminal product mechanics and rendering only.
- Mode behavior goes through public host commands, public events, effects, and
  snapshots.
- There is no callback subscription path that mutates session state directly.

## next implementation shape

The first real TUI loop should stay thin:

```text
select terminal event
  -> input_router
  -> ProductApp.apply or frontend action

drain AgentSession public events
  -> frontend.ReadModel
  -> transcript adapter

if dirty
  -> frame.build
  -> render.render
  -> terminal render/flush
```

Do not add selectors, slash-command UI, command palette, extension UI, or
startup notices until the owner loop proves this boundary.

## rejected alternatives

- port pi-mono's `InteractiveMode` class shape. It is a behavior reference, not
  an architecture target.
- put product/session policy in `src/tui`. TUI renders and requests; coding
  agent/session owners mutate policy.
- make `frontend.zig` a TUI abstraction. It is a coding-agent frontend contract,
  shared by TUI, future RPC, and tests.
- let extensions mutate the default composer/transcript stores directly.
  Extensions request; owners mutate.
