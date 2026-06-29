# zi agent operating guide

Use `CONTEXT.md` for project language and ownership. This file is the working
checklist for changing the repo.

## start of task

1. Read the relevant code before editing.
2. Avoid unrelated changes.
3. Use `symbols` before reading large Zig files; then read only the needed range.
4. Identify the owner that is allowed to mutate the state you are touching.
5. Identify the bound or limit policy for any queue, buffer, view, retry, batch,
   process output, or concurrent work you add or change.

## layer boundaries

```text
main.zig       process/runtime setup, then cli.main
ai             provider protocol, models, registry, wire adapters, streams
agent          generic transcript/tool/stream loop
runtime        std.Io-first mechanism; zio private behind adapters
coding_agent   sessions, resources, settings, tools, persistence, client protocol
tui            agent-agnostic terminal product on vaxis
frontends      concrete adapters between clients and coding_agent/tui
```

Import rules:

- `ai`: std plus runtime I/O mechanism only.
- `agent`: std, ai, runtime. Never coding_agent or tui.
- `runtime`: std only publicly; zio stays private. No product policy.
- `tui`: std plus vendored vaxis only.
- `coding_agent`: std, ai, agent, runtime. Never tui or concrete frontends.
- Frontends may bridge concrete packages.

## runtime changes

When touching `src/runtime` or code that uses it:

- Pass `std.Io` explicitly. Do not add ambient I/O or globals.
- Keep zio-native types and wait protocols behind runtime adapters.
- Owner mutation happens after drain/apply, not in completion producers.
- Wakes are coalesced and payload-free; after waking, inspect owned state.
- Cancellation is two phase: request cancel, then observe terminal completion.
- Shutdown order is request -> stop accepting -> cancel -> drain/join -> stopped
  -> deinit.
- `deinit` must not race worker-visible memory.
- Name the limit policy: reject, evict, backpressure, spill, or deadline/cancel.
- Do not add a generic operation/completion registry unless repeated code proves
  the concrete owner, bound, and failure mode.

## coding_agent changes

- `SessionRuntime` is the mailbox host and owns one live session slot.
- Session replacement must build the next slot completely before swapping.
- Frontends submit commands and drain events/snapshots; they do not mutate
  sessions directly.
- `AgentSession` owns one long-lived `agent.Agent` plus resources, tools,
  persistence, public events, retry, and compaction.
- The event drain is the only writer of queue mirrors, message-derived history,
  retry/compaction state, and public events.
- Drain order is:

```text
agent event -> queue/status mirror -> bounded ClientEvent queue
            -> jsonl persistence on message_end -> terminal policy
```

- Persist durable session facts before mutating the live agent when mailbox-owned
  facts change.
- Option resolution is explicit -> project -> global -> default. Provider/model
  are scope-atomic; reject mixed-scope pairs and record a diagnostic.

## tui changes

- `tui.App` owns TUI product state. Mutate through `App.apply(Command)` only.
- `apply` must handle operational input without tearing down the owner loop:
  oversize, invalid UTF-8, unknown IDs, and slot-full inputs degrade before
  mutation. Only `OutOfMemory` propagates.
- Time enters through `Command.tick`; App does not read clocks.
- Keep `src/tui` agent-agnostic. Translate `ClientEvent` in a frontend adapter.
- Use Vaxis for terminal mechanism: raw tty, parsing, cells, windows, borders,
  diff/render, colors/styles, and width.
- Rendering is draw -> synchronous flush -> clear dirty only after success.
- Every owner loop drain must have a per-turn event and/or time budget.
- Treat typed input as foreground work; model/session drains are background work.
- Coalesce stream fragments before layout/render when ordering allows.
- Do not introduce local ANSI encoders, raw-mode managers, cell buffers, diff
  renderers, style/color encodings, or width engines without a proven bounded
  Vaxis gap.
- Owners storing Vaxis/Tty state must be pinned after initialization.

## tool changes

- Builtins are read, bash, edit, and write.
- Tool definitions include metadata, JSON schema, prompt text, and implementation.
- The core agent receives borrowed `agent.AgentTool` views.
- File mutation goes through `FileMutationQueue`.
- Tool output is bounded.
- Process tools need timeout and cancellation.

## paths and resources

- All path policy lives in `src/coding_agent/paths.zig`.
- Use `.zi`, never `.pi`, for Zi-owned behavior.
- Do not hardcode agent dir resource names outside the path owner.
- `ZI_CODING_AGENT_DIR` overrides the agent dir.

## Zig workflow

- Use the local Zig 0.16 toolchain and vendored sources as the API source of
  truth.
- Pass allocators and `std.Io` explicitly.
- Use small structs with explicit lifetimes.
- Prefer state machines over callback control flow.
- Borrowed slices are valid only for the owner call that returned them.
- Use `errdefer` for partial initialization.
- `deinit` releases all owned memory and poisons `self` when practical.
- Prefer fixed arrays or bounded owned buffers over unbounded lists.
- Use `std.json.encodeJsonString` or runtime JSON helpers for JSON strings.
- Validate boundary text with `std.unicode`.

## before finishing

For code changes, run:

```sh
zig build test
zig build
zig fmt --check src
```

For focused behavior, run the narrow command that exercises the changed path.
Report any gate you did not run.
