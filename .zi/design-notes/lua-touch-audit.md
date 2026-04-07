# lua touch audit (zi-wub.1)

read-only catalog of every site that touches `lua_State` (directly or transitively) so phase 2 can `bindLuaOwnerThread` to the agent thread and flip `assertOnLuaThread` to fatal without surprising the first run.

doctrine source: `.zi/design-notes/threading-doctrine.md`. target model: lua_State owned by agent thread, no exceptions. TUI thread reads pending_renders snapshots only.

## grep counts (baseline for next-session diff)

| pattern | matches | files |
|---|---|---|
| `lua_\|luaL_` | 778 | 15 |
| `assertOnLuaThread` (call sites only, excl. defn + doc) | 6 | 3 |
| `pending_renders` / `stashPendingRender` / `takePendingRender` | 22 | 3 |
| `ExtensionRunner` | 105 | 15 |

per-file `lua_|luaL_` distribution: api.zig 181, event_bridge.zig 121, lua_runtime.zig 110, lua_renderer.zig 104, dispatch.zig 73, lua_tool.zig 69, runner.zig 23, transcript.zig 16, coding_agent.zig 16, registries/event_registry.zig 10, loader.zig 5, registries/command_registry.zig 4, test_root.zig 3, registries/tool_registry.zig 3, interactive.zig 1.

note: tui/transcript.zig and tui/interactive.zig contain the literal token `lua_` only via `lua_runner` field name and `lua_render_state` — they do NOT call any `lua_*` C API. verified: `rg 'lua_runtime|lua_state' src/tui/` returns nothing.

## classification summary

| class | count | meaning |
|---|---|---|
| CORRECT | 5 | already on agent thread by construction |
| ROUTED | 2 | tui touches via pending_renders snapshot, legal |
| VIOLATION | 4 | wrong thread will pin first-touch ownership wrong or directly corrupt lua |
| UNKNOWN | 1 | needs zi-wub.3 soft-trace to confirm |

## sites

| # | file:line | function | thread today | routed? | class |
|---|---|---|---|---|---|
| 1 | src/coding_agent.zig:158-159 | `AgentSession.init` → `lua_runtime.LuaState.init` | TUI/main (caller of `sdk.createAgentSession`, see main.zig:260,344) | no — direct lua_State alloc + `luaL_newstate` | VIOLATION |
| 2 | src/coding_agent.zig:171 | `AgentSession.init` → `extension_api.installZiTable` | TUI/main | no — pushes globals onto L | VIOLATION |
| 3 | src/coding_agent.zig:212 | `AgentSession.init` → `extension_loader.loadAll` (executes every discovered extension's `main.lua`, runs `zi.register_tool` etc.) | TUI/main | no — runs arbitrary lua | VIOLATION |
| 4 | src/coding_agent.zig:344-349 | `AgentSession.deinit` → `runner.deinit` + `state.deinit` (`lua_close`) | TUI/main (deinit caller) | no | VIOLATION |
| 5 | src/extensions/lua_tool.zig:100 (`execute`) → :118 `runHandler` (lua_resume of tool handler) → :129 `precomputeRender` | tool entry | agent (called from `agent/loop.zig` tool exec) | `assertOnLuaThread` at :100, stashes via `runner.stashPendingRender` :177 | CORRECT |
| 6 | src/extensions/lua_tool.zig:435 (`hostUpdate` → `precomputeRenderOn(..., L)`) | partial-update host fn fired from inside a tool's coroutine | agent (host C fn called from inside lua_resume) | uses current_L variant + stashPendingRender | CORRECT |
| 7 | src/extensions/lua_renderer.zig:178 `dispatchRenderResultFromResultOn` | render hook precompute (from-result variant) | agent (only callers are lua_tool.zig:164 paths above) | guarded by `assertOnLuaThread` | CORRECT |
| 8 | src/extensions/lua_renderer.zig:296 `dispatchRenderResult` | render hook precompute (full variant) | UNKNOWN — defined but no production callsite found outside tests; `rg dispatchRenderResult src/ -g '!*test*'` returns only the declaration. HUNCH: dead code or test-only. | n/a | UNKNOWN |
| 9 | src/extensions/event_bridge.zig:65 `handleAgentEvent` | agent event sink subscribed at coding_agent.zig:373 via `agent.subscribe` | agent (events emitted from `agent.prompt` running on agent_thread spawned at interactive.zig:733) | `assertOnLuaThread` at :65 | CORRECT |
| 10 | src/extensions/event_bridge.zig:298, :358 (test helpers `pushToolExecUpdate`/`pushToolExecEnd` internals) | agent event payload builders | agent (only invoked from #9 path) | guarded | CORRECT |
| 11 | src/tui/transcript.zig:658 `refreshLuaRender` → `runner.takePendingRender` | render of tool execution item | TUI | yes — pure data move, no lua API touched. matches doctrine §"render paint stays push-snapshot" | ROUTED |
| 12 | src/tui/transcript.zig:451 `lua_runner: ?*ExtensionRunner` field, set at interactive.zig:222 | borrowed pointer for #11 | TUI holds the pointer | only used through takePendingRender | ROUTED |
| 13 | src/tui/interactive.zig:796-810 `dispatchSlashCommand` → `.extension` arm calls `ext.handler(args, ctx, user_ctx)` synchronously on TUI thread | slash-command extension dispatch | TUI | no | VIOLATION-IN-WAITING |
| 14 | src/tui/interactive.zig:1176 `loginThreadFn` → `oauth_mod.login(...)` → progress callbacks | dedicated login_thread (3rd thread) | login_thread | progress events route through `event_queue.push` (interactive.zig:1202,1209,1216) — does NOT touch lua, no `runner.*` calls | CORRECT (no lua reach today) |

### notes per row

**rows 1-4 (init/deinit on TUI thread)** — this is the showstopper for phase 2. `assertOnLuaThread`'s cmpxchg first-touch claim fires on whichever thread runs `LuaState.init` / `installZiTable` / `loadAll` — today that's the main/TUI thread. when the agent_thread later runs `lua_tool.execute` (row 5) and calls `assertOnLuaThread`, it will see TUI as owner and panic. soft-tracing in zi-wub.3 will report this immediately on any session that has even one extension installed. fix shape: either (a) move ext setup into the agent thread before its first prompt drain, or (b) make `bindLuaOwnerThread` an explicit call from inside the agent thread that overrides the cmpxchg slot, plus an explicit teardown ticket sent through the agent request queue.

**row 13 (extension slash command)** — currently no extension surface registers a `.extension` handler that calls into lua (`zi.register_command` is documented as v2-only at registries/command_registry.zig:3, and no `register_command` C closure exists in api.zig). so this is not a live violation YET, but it is the trap door zi-wub.4/.15 must close before extensions register slash commands. routing fix: `dispatchSlashCommand` must enqueue an `AgentRequest.run_slash_command` rather than invoke the handler inline.

**row 14 (login_thread)** — verified login thread does not touch the runner today; it pushes UiEvents through `event_queue.push`. doctrine trap 5 calls out login as a hidden third thread; the audit confirms it's currently lua-clean. it remains a violation source for `status_text` / `tui.dirty` mutations (out of scope for this audit, in scope for zi-wub.16/.17).

**row 8 (`dispatchRenderResult` non-`FromResult` variant)** — declared at lua_renderer.zig:287 with full `assertOnLuaThread` guard, but no production caller. only references outside the file are tests at lua_renderer.zig:560,590,632,671,702. HUNCH: superseded by `dispatchRenderResultFromResultOn`. flag for cleanup, not a phase-2 blocker.

## hot list (must fix before flipping `assertOnLuaThread` to fatal)

ordered by blast radius:

1. **rows 1-3: lua state construction on TUI thread.** `coding_agent.zig:155-218` (`LuaState.init`, `installZiTable`, `loadAll`). first-touch will pin TUI as owner. fix: move the entire `ext_setup` block to run from the agent thread (e.g. lazy-init on first agent request, or have `interactive.zig` defer ext bootstrap to a primer message on the AgentRequest queue), OR introduce explicit `bindLuaOwnerThread(tid)` and call it from inside the agent thread the first time it touches the runner (zi-wub.5 design). either way, the cmpxchg-based first-touch must NOT be the source of truth.

2. **row 4: deinit path on TUI thread.** `AgentSession.deinit` is invoked from `Interactive.deinit` (interactive.zig:244 path, runs on the main/TUI thread shutdown). `runner.deinit` walks `pending_renders` and `state.deinit` calls `lua_close` — both on TUI. needs to land before flipping the assert, otherwise even a clean-quit triggers the panic. fix: route teardown through the agent thread join + drain, then have main thread free only after agent thread has fully exited.

3. **row 13: extension slash command dispatch.** not active today but the moment `zi.register_command` lands (zi-wub.15/.19 territory) this becomes a live violation. add the `AgentRequest.run_slash_command` queue path before any extension surface ships.

4. **row 8: dead `dispatchRenderResult` variant.** delete or wire up; leaving an unclaimed entry point with first-touch claim is a footgun for the next refactor.

## surprises for next session

- **AgentSession.init runs lua.** the file map in the doctrine implies `runner.zig` is the owner, but in practice the lua state's constructor and the entire extension load (which executes user lua) runs on the SDK caller's thread. this is the single biggest gap between the doctrine and the code. zi-wub.5 needs a design decision: lazy-init from agent thread (cleaner, requires reordering main.zig) vs explicit `bindLuaOwnerThread` (smaller diff, less safe).
- **`dispatchRenderResult` (no `FromResult`) appears dead.** confirm with `rg 'dispatchRenderResult\b' src/ -g '!*lua_renderer*'` → empty. either delete or document why it's an exported entry point.
- **`hookAllocator` is runner-arena, not msg_allocator.** runner.zig:305 hands out `hook_arena.allocator()`. once the agent thread bind lands, this is fine (single-owner arena). if any cross-thread free path emerges, this is the next mole.
- **`current_L` plumbing already landed correctly.** `lua_tool.zig:435` and `lua_renderer.zig:167` already pin the executing coroutine for renders fired from `ctx.update`. the band-aid from the original crash is in place; do NOT re-engineer it during phase 2.
- **login_thread is currently lua-clean.** doctrine flagged it as a trap; audit confirms it only pushes UiEvents. the `status_text`/`tui.dirty` mutation problem is real but orthogonal to lua ownership.
- **transcript.zig holds `lua_runner: ?*ExtensionRunner` borrowed pointer.** if AgentSession is ever rebuilt (e.g. `/reload`) without a corresponding `Transcript.lua_runner = newRunner`, you get use-after-free. not a lua-thread issue, but adjacent — file separately if it bites.

## verification re-grep (post-audit)

ran after writing this doc:

```
rg -c 'lua_|luaL_' src/                         → 15 files, 778 matches (unchanged)
rg -n 'assertOnLuaThread' src/                  → 6 call sites + 1 defn + 2 doc lines
rg -n 'pending_renders' src/                    → runner.zig (defn + 17 internal), lua_tool.zig (3), transcript.zig (2)
rg -n 'stashPendingRender' src/                 → 1 producer (lua_tool.zig:177), 1 defn (runner.zig:365)
rg -n 'takePendingRender' src/                  → 1 consumer (transcript.zig:658), 1 defn (runner.zig:388)
rg -n 'ExtensionRunner' src/                    → 15 files, 105 matches
```

next session: if any of these counts differ, audit is stale — re-run before flipping the assert.
