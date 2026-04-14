# cross-thread audit (zi-wub.2)

read-only audit against `threading-doctrine.md`. phase 4 will design fixes.

## grep counts

- `Thread.spawn` in src/: 5 hits
- `ca.agent.state` in src/: 13 hits (10 in coding_agent.zig tests, 2 TUI, 1 status cache refresh)
- `ca.session_store` in src/: 3 hits (all TUI)
- `status_text` in src/tui/interactive.zig: ~40 hits
- `tui.dirty` in src/tui/interactive.zig: ~12 hits
- `pending_renders*` in src/: 12 hits (runner.zig owner + transcript consumer — correct pattern)

## thread inventory

1. **main** — `main.zig`. builds ca, hands off to `Interactive.run`. after that, effectively the TUI thread.
2. **TUI** — same OS thread as main; runs `interactive.run` event loop, input, render, slash dispatch.
3. **agent** — `interactive.zig:733` spawned per-prompt via `agentThreadFn`. runs `ca.run` → streams → tools → lua. publishes to `event_queue`. short-lived: joined on `agent_finished`.
4. **login** — `interactive.zig:1163` spawned per `/login`. runs `oauth_mod.login` blocking, fires `on_auth`/`on_progress` callbacks synchronously on this thread, then pushes `login_complete` to event_queue.
5. **anthropic watchdog** — `ai/anthropic.zig:227`. per-request abort watchdog. touches only local `wd_ctx` + signals cancel flag. self-contained. CORRECT.
6. **spawn watchdog / aborter** — `spawn/spawn.zig:116`, `:609`. child-process abort helpers. local ctx only. CORRECT.

no other threads.

## owner-assignment adherence

| resource | owner (doctrine) | actual writers | status |
|---|---|---|---|
| `lua_State` | agent | agent (via runner); TUI reads via `takePendingRender` (transcript.zig:658) | CORRECT for paint path. audit of other lua touches is `zi-wub.1`, out of scope here. |
| `ExtensionRunner` | agent | agent. `pending_renders` mutex-guarded (runner.zig:370-395). | CORRECT (snapshot handoff). |
| `session_store` | agent | TUI writes: `interactive.zig:922` (`self.ca.session_store = loaded.store`), `:1072` (`appendModelChange`). TUI read: `:841` (`writer.cwd`). | VIOLATION x2. |
| `ca.agent.state` (model, messages) | agent | TUI writes: `:923` (`ca.agent.loadMessages`), `:1068` (`state.model = m`). TUI reads: `:228`, `:610` (`state.model.id` — snapshot-style read, HUNCH racy but not a write). | VIOLATION x2. |
| `tools`, `render_registry`, ext registries | agent | no TUI writes found. extension slash-command handler called from TUI (`:806`) — HUNCH may touch ext registries indirectly via user_ctx. | LIKELY VIOLATION (see below). |
| `transcript` | TUI | TUI only. | CORRECT. |
| components / overlays / editor | TUI | TUI only. | CORRECT. |
| `pending_renders` | cross-thread mutex | producer agent (`stashPendingRender`), consumer TUI (`takePendingRender` at transcript.zig:658). | CORRECT (SNAPSHOT). |
| `EventQueue` (agent→TUI) | push agent, consume TUI | agent thread pushes via `agentEventCallback` (:1321); login thread also pushes (:1202,:1209,:1216). consume TUI. | CORRECT shape, but login-thread push is a THIRD producer — doctrine says "from login thread via its own push path" so acceptable ONCE backing storage moves to msg_allocator (zi-wub.8/.9). flag for phase 3 invariant. |
| `AgentRequest` queue (TUI→agent) | n/a | does not exist yet. | phase 4 will introduce. |

## violations

each entry: file:line — current wrong path — phase-4 routing hint.

### login thread mutating TUI state

1. `src/tui/interactive.zig:1236-1238` `onLoginAuth` → `status_text.setContent` + `tui.dirty = true` — runs on **login thread**, mutates TUI-owned widgets.
   → push `UiEvent{.login_auth_url}` via `event_queue`; TUI applies.
2. `src/tui/interactive.zig:1243-1245` `onLoginProgress` → same pattern from login thread.
   → push `UiEvent{.login_progress = msg}` via `event_queue`.
3. `src/tui/interactive.zig:1195` `auth_storage.set(...)` called from **login thread**. HUNCH: `auth_storage` is shared with agent/other code paths; doctrine doesn't list it but if agent reads it for credential lookup this is a data race.
   → route cred commit through an `AgentRequest.login_complete` or an auth_storage-owning thread decision; flag for phase 4.

### TUI mutating agent-owned state

4. `src/tui/interactive.zig:922` `self.ca.session_store = loaded.store` — TUI pointer-swaps the agent-owned session_store during `/resume`.
   → `AgentRequest{.resume_session = path}`; agent opens store, loads messages, publishes `UiEvent{.session_loaded = transcript_snapshot}`.
5. `src/tui/interactive.zig:923` `self.ca.agent.loadMessages(loaded.messages)` — TUI mutates `ca.agent.state.messages`.
   → same request as #4; agent does the loadMessages.
6. `src/tui/interactive.zig:1068` `self.ca.agent.state.model = m` — TUI writes model field.
   → `AgentRequest{.set_model = {provider, id}}`; agent applies and publishes `UiEvent{.model_changed}`.
7. `src/tui/interactive.zig:1072` `self.ca.session_store.appendModelChange(...)` — TUI calls session writer.
   → folded into #6; agent-side handler does the append.

### TUI-thread snapshot reads (not violations, flag as HUNCH races)

- `:228` / `:610` — reads `ca.agent.state.model.id` for status bar. HUNCH: technically racy with agent writes, but today agent only writes model via TUI (#6), so it's consistent. post-phase-4, agent owns the write; TUI should read from a published snapshot (`status_data` is already that snapshot — just feed it via `UiEvent.model_changed`).
- `:841` — reads `session_store.writer.cwd` to list sessions. could be stale after a `/resume`; same fix: snapshot or fetch via request.
- `:433`, `:449` `ca.agent.abort()` — abort is documented as thread-safe (atomic flag). CORRECT (SNAPSHOT-ish), verify in phase 4.

### extension slash-command dispatch

8. `src/tui/interactive.zig:804-809` `ext.handler(args, &cmd_ctx, ext.user_ctx)` — extension command handler invoked **synchronously on TUI thread**. handler is registered by an extension (lua-backed, HUNCH), meaning it may reach into `lua_State`, ExtensionRunner, or agent state.
   → `AgentRequest{.run_slash_command = {name, args}}`; agent thread resolves registry, invokes handler, publishes results via events. doctrine explicitly names `run_slash_command` as a queue variant (threading-doctrine.md:75).
9. `src/tui/interactive.zig:797-802` builtin `.builtin` handler — same issue if any registered builtin touches agent state. HUNCH lower risk than ext.

### login-thread event_queue push (not a violation, pre-req flag)

- `:1202`, `:1209`, `:1216` — login thread pushes `UiEvent` directly. allowed by doctrine (third producer), but currently uses `self.allocator` for dupes (`:1205`, `:1212`, `:1219`, `:1192`). must migrate to `msg_allocator` in zi-wub.17 per R2.

## notes

- `agentThreadFn` at `:1305` is correct: agent thread runs `ca.run`, callback (`:1318`) pushes UiEvents via `event_queue`. no TUI mutation from agent thread.
- watchdog threads in `anthropic.zig` / `spawn.zig` are self-contained and do not touch doctrine-listed resources.
- the real violation surface is concentrated in `interactive.zig` lines 716-1170 (slash dispatch + login). fix all 9 by introducing `AgentRequest` (phase 4) and re-routing the login callbacks through `event_queue` with `msg_allocator` payloads.

## paint path (zi-wub.18, verified 5538d2b)

`dispatchRenderResult*` has exactly two non-test callers, both inside
`src/extensions/lua_tool.zig`:

- `precomputeRender` at `:129` — fires from the lua tool execute path
  (agent thread, holds lua mutex).
- `precomputeRenderOn` at `:435` — fires from the `ctx.update` host
  callback that runs inside a lua coroutine (still agent thread, still
  inside the mutex).

Both stash the resulting `LuaRenderState` into
`runner.pending_renders` (mutex-protected `StringHashMap`). The TUI
thread reads from the inbox via `transcript.refreshLuaRender` →
`runner.takePendingRender`, which is a pure data move — never reaches
into `lua_State`.

Contract: **the TUI thread MUST NOT call `dispatchRenderResult*`**.
The render is precomputed on the writer side and consumed as a
typed snapshot on the reader side. This is the canonical
push-snapshot pattern and the model future paint additions should
follow.

Verified clean as of 5538d2b. No code change required.

## violation count

**9** (3 login-thread→TUI, 4 TUI→agent-state, 1 HUNCH login-thread→auth_storage, 1 ext-handler on TUI thread). plus 3 HUNCH snapshot reads to tighten post-phase-4.
