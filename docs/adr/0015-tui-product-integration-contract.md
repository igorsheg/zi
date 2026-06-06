# adr 0015: tui product integration contract

status: accepted

date: 2026-06-05

## context

ADR 0013 made Zi own the terminal substrate and kept `src/tui` independent of
agent/session policy. The shipped TUI now has a concrete product boundary:
`ProductApp.apply(Command) -> ?Effect`, with `coding_agent/interactive.zig` as
the single adapter between coding-agent events and TUI commands.

This boundary is intentionally smaller than older plans that suggested an
agent-event API inside the TUI. The smaller boundary better preserves the import
rules: TUI is terminal product state, while coding-agent owns session meaning.

## decision

`src/tui/product` exposes a domain-neutral command/effect vocabulary:

```text
Command:
  resize
  input
  clear_composer
  append_transcript(message | status | tool)
  tool_output_delta

Effect:
  submit_text
  request_shutdown
```

`src/coding_agent/interactive.zig` is the only shipped bridge. It owns:

- translating `AgentSessionEvent` into `Command` values;
- turning `Effect.submit_text` into `startPromptRun`;
- turning shutdown effects/input into host cancellation or loop stop;
- bounded drains for terminal input, prompt progress, public events, and render;
- operational degradation for invalid/oversized streamed transcript payloads.

`src/tui` must not import `agent`, `ai`, `runtime`, or `coding_agent`, and must
not name sessions, providers, models, or agent events.

## invariants

- TUI mutation goes through `ProductApp.apply(Command) -> ?Effect`.
- Effects are returned data, not authority to mutate TUI state through another
  path.
- The integration adapter lives in `src/coding_agent/interactive.zig` unless a
  second concrete frontend proves a new seam.
- Agent/session events are coding-agent vocabulary; TUI receives only product
  commands.
- Streamed model/tool bytes are operational input. Invalid UTF-8 fragments or
  oversized payloads are dropped or reported; they must not tear down the owner
  loop.
- Rendering remains transactional: build next cells, stage bounded bytes, write,
  then commit; write failure discards staged renderer state.

## consequences

The TUI stays reusable as a terminal product without becoming an agent frontend
framework. The adapter is allowed to know both sides, but all mutation authority
still belongs to the owners it calls: `AgentSessionRuntimeHost` for sessions and
`ProductApp`/`TerminalLoop` for TUI state.

Future richer UI concepts (multi-line composer, slots, extension surfaces, rich
transcript blocks) extend the same command/effect boundary only after a concrete
owner needs them.

## rejected

### Put `AgentEvent` handling in `src/tui`

Rejected. That imports coding-agent semantics into TUI and violates the accepted
ADR 0013 layering.

### Split the bridge into a frontend framework now

Rejected. One adapter is a hypothetical seam. The single integration file is
small, bounded, and sufficient today.

### Let operational transcript append errors escape the interactive loop

Rejected. Streamed provider/tool bytes are operational input, not programmer
errors. The adapter must degrade rather than crash the session.
