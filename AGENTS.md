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
coding_agent   sessions, resources, settings, tools, persistence, bootstrap
tui            concrete interactive terminal frontend on vaxis
frontends      non-interactive/concrete adapters such as print mode
```

Import rules:

- `ai`: std plus runtime I/O mechanism only.
- `agent`: std, ai, runtime. Never coding_agent or tui.
- `runtime`: std only publicly; zio stays private. No product policy.
- `tui`: std, vaxis, ai, agent, coding_agent, runtime. Never imported by coding_agent.
- `coding_agent`: std, ai, agent, runtime. Never tui or concrete frontends.
- Frontends may bridge concrete packages and own process-facing policy.

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

- `AgentSession` owns one long-lived `agent.Agent` plus resources, tools,
  persistence, retry, compaction, lifecycle, and private session event state.
- Concrete frontends own waiting/driving. They start `AgentSession.RunHandle`s,
  set wake handles, poll until terminal completion, then settle and deinit the
  handle before shutdown.
- Session replacement must build the next slot completely before swapping.
- Durable session facts are persisted before mutating mailbox-owned live agent
  facts such as model or thinking level.
- Registered listeners handle each event in subscription order: frontend
  fold/output and session persistence both run during `agent.emitEvent`; terminal
  retry/compaction policy runs after the handle settles.

```text
agent event -> registered listeners -> agent state reduce -> handle settle
            -> terminal retry/compaction policy
```
- Option resolution is explicit -> project -> global -> default. Provider/model
  are scope-atomic; reject mixed-scope pairs and record a diagnostic.

## tui changes

- `tui.Runner`/`Loop` own interactive terminal state. Mutate through
  `Loop.dispatch`, `Loop.tick`, `Loop.pumpDriver`, and `Transcript.apply` only.
- Operational input must not tear down the owner loop: oversize, invalid UTF-8,
  unknown parser events, and full bounded buffers degrade before mutation. Only
  `OutOfMemory` propagates intentionally.
- Time enters through runner/frame-loop deadlines; TUI state does not read wall
  clocks directly except through explicit `std.Io` timestamps at the owner edge.
- Use Vaxis for terminal mechanism: raw tty, parsing, cells, windows, borders,
  diff/render, colors/styles, and width.
- Rendering is draw -> synchronous flush -> clear dirty only after success.
- The frame loop blocks only in `std.posix.poll` over input/worker wake fds with
  a deadline.
- Rendering uses one `render_due` rule: 16ms floor and 3x last render cost
  backoff; typed input and resize render immediately.
- The debug watchdog budget is 33ms until ratcheted; no exemption enum.
- The owner loop performs no filesystem read of unbounded size, no subprocess wait, and no blocking network I/O.
- Treat typed input as foreground work; transcript/layout rebuild work is bounded
  by documented caps.
- Coalesce stream fragments before layout/render when ordering allows.
- Do not introduce local ANSI encoders, raw-mode managers, cell buffers, diff
  renderers, style/color encodings, or width engines without a proven bounded
  Vaxis gap.
- Owners storing Vaxis/Tty state must be pinned after initialization.

## print frontend changes

- `src/frontends/print` is the non-interactive prompt owner. It drives one
  `AgentSession.RunHandle` at a time, writes bounded text/JSON output directly to
  the supplied writer, honors retry sleeps and compaction verdicts, and returns a
  process-ready status code.
- Print mode does not mutate TUI state and does not import `tui`.

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
zig build pty-test
zig build
zig fmt --check src
zig fmt --check build.zig
```
For focused behavior, run the narrow command that exercises the changed path.
Report any gate you did not run.
