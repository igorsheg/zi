# zi Extension System — Spec

> **Status**: Design — not yet implemented.
> **Layer**: L4 (extensions) sitting between L3 (agent session) and L5 (composition root).
> **Language**: Lua 5.4 embedded in the zig binary.
> **Source of inspiration**: pi-mono's extension system (`.references/pi-mono/packages/coding-agent/src/core/extensions/`).

## Goals

1. **Match pi-mono's extension surface.** Every hook, registration, action, and UI primitive in pi-mono has a 1:1 equivalent in zi (in Lua instead of TypeScript), with two documented exceptions.
2. **The extension system is the product.** zi ships a minimal core. All opinionated behavior (sub-agents, custom tools, workflows) lives in extensions — built-in defaults are themselves extensions, registered through the same API.
3. **Neovim-style ergonomics.** snake_case, tables as config, coroutines for async, JSON schema as Lua tables. If you can configure neovim, you can extend zi.
4. **No half-ass v1.** The internal architecture supports every pi-mono extension point from day one, even where the public Lua API is scoped down. Adding v2 features is pure wiring, not refactoring.

## Non-Goals

- **TypeScript compatibility.** Extensions are Lua, not TS. Porting a pi-mono extension to zi requires rewriting. The API shape translates directly, but the language does not.
- **Full component tree injection.** Two pi-mono UI primitives — `setEditorComponent` and `ui.custom(factory)` — are dropped. Both expose zi's TUI component vtable across the FFI boundary. That's a separable design problem best deferred.
- **Extension isolation.** All extensions share a single Lua state. A broken extension is caught and logged per-handler, but extensions can observe and affect each other. This matches pi-mono and neovim; sandboxing is out of scope.

## Architecture

```
  ┌──────────────────────────────────────────────────────────────────────┐
  │ L7  CLI (main.zig) — parse args, dispatch to mode                   │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L6  MODE (print / json / interactive) — consumes AgentSession       │
  │     interactive additionally binds UIContext into ExtensionRunner    │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L5  SDK (src/sdk.zig) — createAgentSession() factory                │
  │     constructs AgentSession, wires Agent closures → ExtensionRunner  │
  │     via forward-declared mutable ref                                 │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L4  AGENT SESSION (src/agent_session.zig)                           │
  │     owns: Agent, SessionStore, ResourceLoader, ExtensionRunner       │
  │     owns: tool registry (base + extension-registered)                │
  │     handles: session lifecycle, reload, compaction, tool activation │
  │                                                                      │
  │     ┌─────────────────────────────────────────────────────────────┐ │
  │     │ ExtensionRunner (src/extensions/)                           │ │
  │     │ ─────────────────────────────────────────────────────────── │ │
  │     │  lua_runtime  — single Lua 5.4 state, agent-thread affinity │ │
  │     │  loader       — discover .lua files, load factories         │ │
  │     │  runtime      — mutable object, stub → bound                │ │
  │     │  registries:                                                │ │
  │     │    tool_registry    (first-registered-wins, user > builtin) │ │
  │     │    event_registry   (event → [handlers])                    │ │
  │     │    command_registry                                         │ │
  │     │    provider_queue   (flushed at bind)                       │ │
  │     │  prompt_metadata — snippets, guidelines from tools         │ │
  │     └─────────────────────────────────────────────────────────────┘ │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L3  AGENT CORE (src/agent/) — dual-loop, hooks, tool execution      │
  │     knows nothing about extensions                                   │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L2  SESSION (src/session/) — JSONL persistence, tree, context       │
  ├──────────────────────────────────────────────────────────────────────┤
  │ L1  AI (src/ai/) — provider, messages, streaming, models           │
  └──────────────────────────────────────────────────────────────────────┘
```

### Key architectural decisions

1. **ExtensionRunner is owned by AgentSession.** Not a peer. This matches pi-mono and keeps reload/new/resume semantics internal to the session.
2. **Two-phase lifecycle: load → bind.** Extensions load into a passive registry first (tools, handlers, flags registered). Action methods (`send_message`, `exec`, etc.) throw `runtime_not_bound` until `bindRuntime()` swaps the stub for the real implementation. This preserves extension load order while preventing unsafe pre-bind side effects.
3. **Built-in tools go through the same registry.** Bash, Read, Edit, Write, Grep, Find, Ls are registered via the same `register_tool` mechanism as extension tools, just with zig function pointers instead of Lua coroutines. This means:
   - Users can override built-in tools by registering first
   - Event hooks (`tool_call`, `tool_result`) work uniformly across built-in and extension tools
   - The system prompt builds its snippets/guidelines from the same metadata source
4. **First-registered-wins collision semantics.** Load order: **explicit (--extension) → user-global → project-local → built-in**. More specific / user-authored sources load first and win collisions. A user `~/.zi/agent/extensions/task.lua` overrides the built-in Task tool because it registers first. (This deliberately inverts pi-mono's loader order, which loads project before global. zi prioritizes user intent over team configuration; override this by using `--extension` for explicit opt-in.)
5. **Single Lua state, agent-thread affinity.** The Lua state lives on the agent thread. Agent hooks (before/after_tool_call) run Lua inline. UI requests from Lua marshal to the TUI thread, do their work, and resume the Lua coroutine back on the agent thread.
6. **Forward-declared ExtensionRunner ref.** The Agent is constructed with `stream_fn` / `transform_context` / `on_payload` closures that reference a mutable ref. The ref is populated when AgentSession creates the ExtensionRunner. This mirrors pi-mono's `extensionRunnerRef: { current?: ExtensionRunner }` pattern.
7. **Session directory resolution happens BEFORE SessionStore creation.** Even though the `session_directory` hook is v2, zi's bootstrap reorders session path resolution ahead of `SessionStore.create()` so the hook can be added later without moving session ownership. See [Session Directory Resolution](#session-directory-resolution).
8. **Two context types from day one: `ExtensionContext` and `ExtensionCommandContext`.** Tools and events receive `ExtensionContext`. Command handlers (v2) receive `ExtensionCommandContext`, which extends it with session-control methods (`wait_for_idle`, `new_session`, `fork`, `navigate_tree`, `switch_session`, `reload`). The second type is reserved in the runtime bind seam even though `zi.register_command` is v2. See [Context Types](#context-types).
9. **Generation-based reload model.** Each reload produces a new ExtensionRunner generation. The old generation is destroyed only after the new one is fully bound and active tool list swapped atomically. See [Ownership and Reload](#ownership-and-reload).

### Discovery

```
  LOAD ORDER         PATH                                PURPOSE
  ──────────         ────                                ───────
  1. explicit        --extension <path> CLI flag         testing, opt-in
  2. user-global     ~/.zi/agent/extensions/*.lua        personal config
  3. project-local   .zi/extensions/*.lua                team-shared
  4. built-in        (compiled into binary)              defaults

  Within each directory:
  - foo.lua                → single-file extension
  - foo/init.lua           → directory extension with helper files
```

**Collision rule**: first-registered-wins **per identifier** (tool name, command name, provider name, flag name). Load order determines precedence: earlier loaders register first, so they win. Later registrations with the same identifier are silently dropped with a diagnostic log entry (`extension X tried to register tool "Y" but it is already registered by Z`).

**Precedence summary**: `explicit > user > project > builtin`. A user `~/.zi/agent/extensions/task.lua` wins over the built-in Task tool. An `--extension ./dev-task.lua` wins over everything.

### Lifecycle

```
  1. discover files (order above)
  2. create ExtensionRunner with stub runtime
  3. for each extension file:
       load lua chunk
       call factory(zi_api)
       collect registrations into runner's registries
       (action methods would throw here — registrations only)
  4. AgentSession.init consumes runner's:
       tool_registry → Agent's tools
       prompt_metadata → system_prompt build
       agent_hooks → AgentLoopConfig
       event dispatch → subscribed as a listener
  5. bindRuntime(runner, session, ui?) — swap stubs for real impls
       flush provider_queue
  6. emit "session_start" event → extensions can now act
  7. AgentSession.run(prompt) → agent loop runs, events fan out
  ...
  8. (on /reload)
     emit "session_shutdown"
     rebuild ExtensionRunner (re-discover, re-load)
     bindRuntime again
     emit "session_start" with reason="reload"
```

---

## Extension Surface — Parity Matrix

```
  LEGEND: ✓ v1   ◐ v2+ (internal seam exists)   ✗ intentionally dropped
```

### Event Hooks

All 28 pi-mono events are on the roadmap. v1 covers lifecycle + tool events, which is enough to build sub-agents and tool wrappers. v2 adds the session lifecycle hooks and transform events.

```
  CATEGORY        EVENT                      SEMANTICS                      v1
  ──────────────────────────────────────────────────────────────────────────
  lifecycle       agent_start                observer                       ✓
                  agent_end                  observer                       ✓
                  turn_start                 observer                       ✓
                  turn_end                   observer                       ✓
                  message_start              observer                       ✓
                  message_update             observer                       ✓
                  message_end                observer                       ✓

  tool            tool_execution_start       observer                       ✓
                  tool_execution_update      observer                       ✓
                  tool_execution_end         observer                       ✓
                  tool_call                  mutable + cancellable          ✓
                  tool_result                transformable                  ✓

  session         session_start              observer                       ✓
                  session_shutdown           observer                       ✓
                  session_directory          transform (path resolution)    ◐
                  session_before_switch      cancellable                    ◐
                  session_before_fork        cancellable                    ◐
                  session_before_compact     cancellable + customizable     ◐
                  session_compact            observer                       ◐
                  session_before_tree        cancellable                    ◐
                  session_tree               observer                       ◐

  transform       context                    transform messages             ◐
                  before_agent_start         transform prompt/system        ◐
                  before_provider_request    transform provider payload     ◐
                  input                      transform / short-circuit      ◐

  meta            resources_discover         provide extra resource paths   ◐
                  model_select               observer                       ✓
                  user_bash                  customize user bash            ◐
```

### Registrations

```
  PI-MONO                            ZI (LUA)                              v1
  ──────────────────────────────────────────────────────────────────────────
  pi.registerTool(def)               zi.register_tool(def)                 ✓
  pi.registerCommand(name, opts)     zi.register_command(name, opts)       ◐
  pi.registerShortcut(key, opts)     zi.register_shortcut(key, opts)       ◐
  pi.registerFlag(name, opts)        zi.register_flag(name, opts)          ◐
  pi.getFlag(name)                   zi.get_flag(name)                     ◐
  pi.registerProvider(name, cfg)     zi.register_provider(name, cfg)       ◐
  pi.unregisterProvider(name)        zi.unregister_provider(name)          ◐
  pi.registerMessageRenderer         zi.register_message_renderer          ◐
```

### Runtime Actions (post-bind)

```
  PI-MONO                            ZI (LUA)                              v1
  ──────────────────────────────────────────────────────────────────────────
  pi.sendMessage(msg, opts)          zi.send_message(msg, opts)            ◐
  pi.sendUserMessage(content)        zi.send_user_message(content)         ◐
  pi.appendEntry(type, data)         zi.append_entry(type, data)           ◐
  pi.exec(cmd, args, opts)           zi.exec(cmd, args, opts)              ◐
  pi.setModel(model)                 zi.set_model(model)                   ◐
  pi.getThinkingLevel()              zi.get_thinking_level()               ◐
  pi.setThinkingLevel(level)         zi.set_thinking_level(level)          ◐
  pi.setSessionName(name)            zi.set_session_name(name)             ◐
  pi.getSessionName()                zi.get_session_name()                 ◐
  pi.setLabel(id, label)             zi.set_label(id, label)               ◐
  pi.getActiveTools()                zi.get_active_tools()                 ◐
  pi.getAllTools()                   zi.get_all_tools()                    ◐
  pi.setActiveTools(names)           zi.set_active_tools(names)            ◐
  pi.getCommands()                   zi.get_commands()                     ◐
  pi.events.emit/on                  zi.events.emit/on                     ◐
  zi.spawn(config) — sub-agent       (no pi-mono equivalent; zi-specific)  ✓
```

### UI Context (interactive mode only)

```
  PI-MONO                                ZI (LUA)                          v1
  ──────────────────────────────────────────────────────────────────────────
  ctx.ui.select(title, options)          ctx.ui.select(title, options)     ◐
  ctx.ui.confirm(title, message)         ctx.ui.confirm(title, message)    ◐
  ctx.ui.input(title, placeholder)       ctx.ui.input(title, placeholder)  ◐
  ctx.ui.notify(message, type)           ctx.ui.notify(message, type)      ◐
  ctx.ui.setStatus(key, text)            ctx.ui.set_status(key, text)      ◐
  ctx.ui.setWorkingMessage(msg)          ctx.ui.set_working_message(msg)   ◐
  ctx.ui.setWidget(key, content, opts)   ctx.ui.set_widget(key, spec)      ◐
  ctx.ui.setFooter(factory)              ctx.ui.set_footer(spec)           ◐
  ctx.ui.setHeader(factory)              ctx.ui.set_header(spec)           ◐
  ctx.ui.setTitle(title)                 ctx.ui.set_title(title)           ◐
  ctx.ui.pasteToEditor(text)             ctx.ui.paste_to_editor(text)      ◐
  ctx.ui.setEditorText(text)             ctx.ui.set_editor_text(text)      ◐
  ctx.ui.getEditorText()                 ctx.ui.get_editor_text()          ◐
  ctx.ui.editor(title, prefill)          ctx.ui.editor(title, prefill)     ◐
  ctx.ui.onTerminalInput(handler)        ctx.ui.on_terminal_input(handler) ◐
  ctx.ui.theme                           ctx.ui.theme                      ◐
  ctx.ui.getAllThemes                    ctx.ui.get_all_themes             ◐
  ctx.ui.getTheme(name)                  ctx.ui.get_theme(name)            ◐
  ctx.ui.setTheme(theme)                 ctx.ui.set_theme(theme)           ◐

  ctx.ui.setEditorComponent(factory)     ✗ DROPPED — full TUI component tree
  ctx.ui.custom(factory, opts)           ✗ DROPPED — full TUI component tree
```

### Discovery

```
  PI-MONO                                 ZI                                v1
  ──────────────────────────────────────────────────────────────────────────
  .pi/extensions/*.ts                     .zi/extensions/*.lua              ✓
  ~/.pi/agent/extensions/*.ts             ~/.zi/agent/extensions/*.lua      ✓
  --extension <path> CLI flag             --extension <path> CLI flag       ✓
  .pi/extensions/foo/index.ts             .zi/extensions/foo/init.lua       ✓
  package.json pi.extensions manifest     (not needed — Lua is single-file) ✗
  .pi/agents/*.md                         .zi/agents/*.md                   ◐
  .pi/skills/*.md                         .zi/skills/*.md                   ◐
  .pi/prompts/*.md                        .zi/prompts/*.md                  ◐
  .pi/themes/*.json                       .zi/themes/*.json                 ◐
```

### Tool Definition Fields

```
  PI-MONO                         ZI (LUA)                                  v1
  ──────────────────────────────────────────────────────────────────────────
  name                            name                                     ✓
  label                           label                                    ✓
  description                     description                              ✓
  parameters (TypeBox)            parameters (JSON schema as Lua table)    ✓
  execute(id,params,sig,upd,ctx)  execute(params, ctx)                     ✓
  promptSnippet                   prompt_snippet                           ✓
  promptGuidelines                prompt_guidelines                        ✓
  prepareArguments                prepare_arguments                        ✓
  renderCall                      render_call (returns string[])           ◐
  renderResult                    render_result (returns string[])         ◐
```

---

## API Examples

### Registering a tool

```lua
return function(zi)
  zi.register_tool({
    name = "finder",
    label = "Finder",
    description = "Search the codebase intelligently using a fast sub-agent.",
    prompt_snippet = "Use finder for multi-step code search tasks.",
    prompt_guidelines = {
      "Prefer finder over chained grep calls.",
      "Finder runs in parallel; launch multiple queries when independent.",
    },

    parameters = {
      type = "object",
      properties = {
        query = { type = "string", description = "The search query." },
      },
      required = { "query" },
    },

    execute = function(params, ctx)
      local result = zi.spawn({
        task = params.query,
        model = "fireworks/kimi-k2p5",
        tools = "read,grep,find,ls",
        append_system_prompt = FINDER_PROMPT,
        cwd = ctx.cwd,
      })

      if result.cancelled then
        return {
          content = { { type = "text", text = "(cancelled)" } },
          is_error = true,
        }
      end

      return {
        content = { { type = "text", text = result.output or "(no output)" } },
        is_error = result.exit_code ~= 0,
        details = {
          model = result.model,
          usage = result.usage,
          stop_reason = result.stop_reason,
        },
      }
    end,
  })
end
```

### Subscribing to events

```lua
-- observer (fire-and-forget)
zi.on("message_end", function(event, ctx)
  if event.message.role == "assistant" then
    local tokens = event.message.usage and event.message.usage.total_tokens or 0
    ctx.ui.set_status("tokens", tostring(tokens))
  end
end)

-- cancellable + mutable
zi.on("tool_call", function(event, ctx)
  if event.tool_name == "bash" and event.input.command:match("rm%s+-rf%s+/") then
    return { block = true, reason = "refused: dangerous path" }
  end
  -- mutate event.input to patch args before execution
  if event.tool_name == "bash" then
    event.input.command = "nice -n 10 " .. event.input.command
  end
end)

-- transformable
zi.on("tool_result", function(event, ctx)
  if event.tool_name == "read" and event.content[1] then
    local text = event.content[1].text
    if text and #text > 100000 then
      return {
        content = {
          { type = "text", text = "(truncated: " .. #text .. " bytes)" },
        },
      }
    end
  end
end)
```

### Async operations via coroutines

```lua
execute = function(params, ctx)
  -- zi.spawn yields the coroutine; zig runs the child process
  -- and resumes the coroutine with the result
  local result = zi.spawn({ task = params.query })

  -- ctx.ui.confirm yields; zig shows the dialog on the TUI thread,
  -- gets the user's answer, resumes the coroutine
  if ctx.has_ui then
    local ok = ctx.ui.confirm("Proceed?", result.output)
    if not ok then
      return { content = { { type = "text", text = "aborted" } }, is_error = true }
    end
  end

  return { content = { { type = "text", text = result.output } } }
end
```

---

## Event Handler Semantics

Three kinds of handlers, matching pi-mono:

### Observer (fire-and-forget)

Used for: all lifecycle events (`agent_start/end`, `turn_start/end`, `message_*`, `tool_execution_*`), `session_start/shutdown`, `model_select`.

```lua
zi.on("message_end", function(event, ctx) end)
-- return value ignored
```

### Cancellable + mutable

Used for: `tool_call`, `session_before_switch/fork/compact/tree`.

```lua
zi.on("tool_call", function(event, ctx)
  -- return nil to allow with no changes
  if event.tool_name == "bash" and event.input.command:match("rm%s+-rf%s+/") then
    return { block = true, reason = "refused: dangerous path" }
  end

  -- return { input = new_input } to replace args before execution
  if event.tool_name == "bash" then
    return { input = { command = "nice -n 10 " .. event.input.command } }
  end
end)
```

**Important**: Lua handlers return a **replacement** `input` table — they do not mutate the original event. This is because:
- Lua tables and zig `std.json.Value` are separate memory; in-place mutation would require round-trip serialization on every access.
- Returning a new table is cheaper, simpler, and makes the handler chain explicit.
- The zig runner deserializes the returned `input` table into a new `std.json.Value` and passes that to the tool execution.

Multiple handlers chain: handler N+1 receives the event with `input` already replaced by handler N's return value (if any). If any handler returns `{ block = true }`, the chain stops and execution is blocked.

**Core zig hook contract** (required to support this):
```zig
pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
    args: ?std.json.Value = null,  // replacement args, null = unchanged
};
```
The agent loop uses `result.args orelse original_args` when executing the tool. This seam exists from Phase B — v1 Lua uses it, v2 extensions reuse it.

### Transformable

Used for: `tool_result`, `context`, `before_agent_start`, `before_provider_request`, `input`.

```lua
zi.on("context", function(event, ctx)
  -- return modified data; chains through multiple handlers
  return { messages = filtered_messages }
end)

zi.on("input", function(event, ctx)
  return { action = "transform", text = event.text:upper() }
  -- or { action = "handled" } to consume the input
  -- or { action = "continue" } (or nil) to pass through
end)
```

Each handler's return value feeds into the next. The final value is what the agent loop sees.

---

## Cancellation

Every yieldable Lua operation carries the current `AbortSignal` from the agent loop. When the agent aborts:

1. Pending child processes (from `zi.spawn`) get SIGTERM → SIGKILL
2. Pending UI dialogs get dismissed
3. The Lua coroutine **resumes with a normal result** carrying `cancelled = true`:
   ```lua
   local result = zi.spawn({ task = "..." })
   if result.cancelled then
     -- handle cancellation
   end
   ```
4. Cancellation does NOT raise a Lua error — it always returns a value. Extensions check the `cancelled` field explicitly.

**Cancellation vs errors**:
- **Cancellation** (user abort, timeout, parent process killed): resumes coroutine with `{ cancelled = true, ... }`. Normal control flow, extensions must handle it explicitly.
- **Hard failure** (spawn failed, UI unavailable, network error): raises a Lua error via `lua_error()`. Caught by the runner's `lua_pcall` wrapper, logged, and surfaced as a tool error result.

This distinction matters: extensions can compose (`if result.cancelled then return early end`) without being forced into `pcall` for every yieldable call.

This matches zi's existing `AbortSignal` threading through tool execution and spawn.

---

## Error Handling

- Errors in Lua handlers are caught per-handler, logged with extension path, and execution continues.
- A single broken extension does NOT disable all extensions.
- Repeated failures from the same extension (3+) log a warning; the extension stays loaded (user's responsibility).
- In print/json modes, errors write to stderr. In interactive mode, errors write to the status area.
- `error_message` events are raised on the extension runner for extensions that want to surface errors to the user.

---

## Lua Coroutine C-Call Model

Lua 5.4 supports yielding across C boundaries ONLY when host functions use continuation-safe primitives. Naive `lua_pcall` + C callback bridges cannot suspend — they raise `attempt to yield across C-call boundary` errors.

zi's coroutine model:

1. **Every tool execution and event handler runs in a dedicated Lua coroutine**, not in the main Lua state. This means zig can always `lua_resume` them.
2. **Yieldable host functions use `lua_yieldk` with a continuation function**. Example:
   ```c
   int zi_spawn(lua_State *L) {
       // ... start spawn, register callback ...
       return lua_yieldk(L, 0, ctx, zi_spawn_continue);
   }

   int zi_spawn_continue(lua_State *L, int status, lua_KContext ctx) {
       // called when coroutine is resumed with spawn result
       push_result_table(L, spawn_result);
       return 1;  // one return value
   }
   ```
3. **Zig resumes coroutines with `lua_resume`**, pushing result values onto the stack first.
4. **Non-yieldable operations** (pure computation, simple API calls like `get_active_tools()`) use regular `lua_pcall` — they don't yield.
5. **Errors from resumed coroutines** are normalized by the runner: Lua errors → logged + wrapped as tool error results; uncaught exceptions → the whole handler fails gracefully.

**Anti-pattern**: Do NOT use regular `lua_pcall` to call handlers that might yield on `zi.spawn` or `ctx.ui.*`. The stack unwinds wrong and you get runtime errors. Use `lua_resume` for all handlers that might yield.

---

## Ownership and Reload

Zig has no GC. Explicit ownership rules prevent use-after-free and leaks across extension reloads.

### Generation model

Each call to `reload()` produces a new `ExtensionRunner` **generation**. Generations are numbered `(0, 1, 2, ...)` and never reused.

```
  agent_session
    ├─ owns: current runner generation (one at a time)
    └─ owns: current active tool slice (points into runner)

  extension_runner[generation N]
    ├─ owns: Lua state (lua_State *)
    ├─ owns: loaded Lua chunks (compiled bytecode)
    ├─ owns: handler refs (luaL_ref registry entries)
    ├─ owns: registry entries (tool defs, event handlers, commands)
    ├─ owns: schema JSON values (std.json.Value, deep-copied from Lua)
    └─ owns: tool ctx wrappers (one per Lua-backed tool, points back to runner)
```

### Reload sequence

```
  1. wait for agent idle (no in-flight turn)
  2. emit session_shutdown on runner[N]
  3. discover extensions (fresh filesystem scan)
  4. build runner[N+1] in parallel (doesn't touch runner[N])
  5. atomically swap:
     - agent_session._runner = runner[N+1]
     - agent_session._active_tools = runner[N+1].getTools()
  6. emit session_start on runner[N+1] with reason="reload"
  7. destroy runner[N]:
     - lua_close(state) — releases all Lua memory
     - free registry entries
     - free schema JSON
     - free tool ctx wrappers
```

### Invariants

- **Lua never holds borrowed zig pointers past the current host call.** Pointers passed into Lua (e.g., strings) are either copied into Lua memory immediately or valid only for the duration of the C function.
- **Zig never stores pointers into Lua-managed memory.** When extracting values from Lua (strings, tables), zig clones them into owned allocator memory before the Lua stack unwinds.
- **Tool ctx wrappers are owned by the runner**, not by `AgentTool.ctx`. The tool's `ctx` field points into runner-owned memory; when the runner is destroyed, tools from that generation become invalid.
- **Reload requires idle.** Attempting reload during an active turn blocks until idle or errors out. Never swap the runner mid-execution.
- **Schema JSON is deep-copied on registration.** When a Lua extension calls `zi.register_tool({ parameters = {...} })`, the parameters table is converted to `std.json.Value` with all strings/arrays owned by the runner's allocator. The Lua table can be garbage collected afterward.

### Cross-generation references

**Problem**: If the TUI holds a reference to a tool from generation N, and reload creates generation N+1, the TUI's reference becomes dangling.

**Solution**: The active tool slice is looked up by name at each use site. The TUI never caches `AgentTool` pointers across reload — it caches tool names and re-resolves them. Tool registration updates a generation counter; consumers that care check it.

---

## Session Directory Resolution

The `session_directory` event (v2) lets extensions override where session files are stored. It must fire BEFORE `SessionStore` is created. To preserve this seam without refactoring bootstrap later, zi's session path resolution is factored out of `SessionStore.create()` into a separate step that can be intercepted later:

```
  (current flow, no extension override)          (v2 flow, with hook)
  1. resolve cwd                                  1. resolve cwd
  2. resolveSessionDir(cwd)                       2. resolveSessionDir(cwd)
       → default: ~/.zi/agent/sessions/<cwd>           → runner.emit("session_directory", cwd)
                                                       → extension can return custom path
  3. SessionStore.create(session_dir)             3. SessionStore.create(session_dir)
```

In v1, `resolveSessionDir` just returns the default. In v2, the ExtensionRunner hooks into it between step 1 and 2 without changing the bootstrap signature.

**Required refactor in Phase A**: Move session directory resolution out of `SessionWriter.init()` into a pre-step that happens before `AgentSession` construction. The resolved path is passed to `SessionStore.create(allocator, session_dir, cwd)`.

---

## Context Types

Two distinct context types are exposed to Lua handlers, matching pi-mono's `ExtensionContext` / `ExtensionCommandContext` split.

### ExtensionContext (v1)

Passed to tool `execute` functions and event handlers. Provides read-only session access and basic actions.

```lua
ctx = {
  cwd = string,                -- current working directory
  has_ui = boolean,            -- true in interactive mode
  ui = { ... } | nil,          -- UI primitives (v2)
  signal = AbortSignal,        -- current abort signal, or nil when idle
  model = { id, name, ... },   -- current model info
  is_idle = function() end,
  get_context_usage = function() end,
  get_system_prompt = function() end,
}
```

### ExtensionCommandContext (v2)

Passed to slash command handlers. Extends `ExtensionContext` with session-control methods that are only safe in user-initiated commands.

```lua
cmd_ctx = {
  -- all ExtensionContext fields, plus:
  wait_for_idle = function() end,
  new_session = function(opts) end,
  fork = function(entry_id) end,
  navigate_tree = function(target_id, opts) end,
  switch_session = function(path) end,
  reload = function() end,
}
```

**Phase B/D requirement**: The runtime's `bindRuntime()` method must bind BOTH context types, even though v1 only exposes `ExtensionContext` to Lua. The internal seam:

```zig
pub const ExtensionRuntime = union(enum) {
    stub: void,
    bound: struct {
        session: *AgentSession,
        ui: ?*ExtensionUIContext,
        // command context actions — called from command handlers only
        command_actions: ?*ExtensionCommandActions,
    },
};
```

v1 leaves `command_actions = null` (no commands registered). v2 wires the pointer when the command registry gains entries.

---

## Agent Core Seams (required by Phase B)

The following seams must exist in `src/agent/protocol.zig` and the agent loop from Phase B, even if the public Lua API doesn't expose them until v2. Adding them later would be retrofits into the core agent loop.

### 1. Mutable tool_call args

```zig
pub const BeforeToolCallResult = struct {
    block: bool = false,
    reason: ?[]const u8 = null,
    args: ?std.json.Value = null,  // NEW — replacement args
};
```

Loop usage: `const effective_args = hook_result.args orelse prepared_args;`

### 2. Provider payload transform hook

```zig
pub const OnPayloadHook = struct {
    func: *const fn (payload: std.json.Value, model: Model, ctx: ?*anyopaque) std.json.Value,
    ctx: ?*anyopaque = null,
};

pub const AgentLoopConfig = struct {
    // ... existing fields ...
    on_payload: ?OnPayloadHook = null,  // NEW — called before provider request
};
```

Called in the agent loop after `convert_to_llm` and before `stream_fn`. v1 doesn't expose this to Lua; v2 wires `before_provider_request` to it.

### 3. Context transform hook (already exists)

zi already has `transform_context`. No change needed; Phase D wires `context` event handlers to it.

---

## Implementation Layout

```
  src/
    sdk.zig                  — createAgentSession() factory
    agent_session.zig        — renamed from coding_agent.zig, owns ExtensionRunner
    extensions/
      root.zig               — module exports
      runner.zig             — ExtensionRunner, event dispatch
      loader.zig             — discover and load .lua files
      lua_runtime.zig        — Lua 5.4 C API wrappers, coroutine management
      runtime.zig            — mutable runtime object (stub → bound)
      registries/
        tool_registry.zig    — tool name → ExtensionTool (built-in or lua)
        event_registry.zig   — event type → [handler]
        command_registry.zig
      api.zig                — zi.* functions exposed to Lua
      types.zig              — ExtensionConfig, Tool definition, etc.
      builtins/
        bash.lua             — built-in bash tool (zig function under the hood)
        read.lua
        ...
    resources/
      loader.zig             — ResourceLoader for .lua, .md, themes, skills
    tools/
      (unchanged — zig implementations for built-in tools)
```

---

## v1 Scope Summary

**Enables:**
- Tool registration with schemas, snippets, guidelines, `prepare_arguments`
- Event hooks: all lifecycle + tool events (observer, cancellable, transformable)
- `zi.spawn` for sub-agent spawning with cancellation
- Extension discovery from `~/.zi/agent/extensions/` and `.zi/extensions/`
- Built-in tools go through the same registry (users can override)
- Two-phase load/bind lifecycle with `session_start`/`session_shutdown`

**Sufficient to rebuild:**
- Task, Oracle, Finder, HyperTask (the user's current `~/.pi` extensions) — the tool-body subset
- Custom tool wrappers and safety interceptors
- Custom logging / observability hooks
- Session-bound state via `zi.spawn`

**NOT sufficient for v1** (if your extension needs these, wait for v2):
- Extensions that register slash commands or shortcuts
- Extensions that render custom widgets or dialogs
- Extensions that transform user input or the context before LLM calls
- Extensions that override session directory or add resource paths
- Extensions that register custom providers or OAuth flows

**Deferred to v2+ (◐)**:

Each item below is categorized by whether its internal seam must exist in v1 or can be added later:

*Pure wiring (internal seam trivial, just expose to Lua)*:
- `context` event — Lua wrapper around existing `transform_context` hook
- `before_agent_start` event — session-layer seam
- `resources_discover` event — ResourceLoader already separate
- Providers — `provider_queue` already flushed at bind
- UI context methods beyond dialogs — tui integration, no core changes
- `zi.events` bus — in-memory pub/sub, no core changes

*Requires core seam in v1 (must land in Phase B regardless of Lua exposure)*:
- `before_provider_request` — `on_payload` hook in `AgentLoopConfig`
- Mutable `tool_call` args — `BeforeToolCallResult.args` field
- `session_directory` — bootstrap reordering to resolve path before `SessionStore.create`
- Commands — `ExtensionCommandContext` type + bind seam

*Still requires work in v2 (non-trivial)*:
- Session lifecycle hooks (before_switch, before_fork, compact, tree) — each needs its own cancel point
- `input` event — TUI integration for input interception
- Shortcuts — TUI keybinding integration
- Message renderers — custom component rendering pipeline

**Never supported (✗):**
- `ctx.ui.setEditorComponent(factory)` — would require exposing full TUI component vtable across FFI
- `ctx.ui.custom(factory)` — same reason
- `package.json pi.extensions` manifest — not needed for Lua single-file extensions

---

## Open Questions

1. **LuaJIT vs Lua 5.4 embedding ergonomics in zig.** Lua 5.4 wins on language features, LuaJIT on performance and neovim mindshare. Decision: **Lua 5.4** for v1. Extension hot paths are orchestration, not compute.

2. **Built-in tool representation.** Built-ins register through the same `register_tool` API but their `execute` is a zig function pointer, not a Lua coroutine. Represented internally as a union:
   ```zig
   const ToolImpl = union(enum) {
     builtin: *const fn (...) AgentToolResult,
     lua: LuaHandlerRef,
   };
   ```

3. **Coroutine scheduling.** When Lua yields on `zi.spawn` or `ctx.ui.confirm`, the agent thread needs to know whether to block, drive another event, or continue execution. v1 approach: synchronous from the agent loop's perspective — the thread blocks on the async op, then resumes the coroutine. Matches pi-mono's sync-from-runner semantics.

4. **Reload UX.** `/reload` triggers `session_shutdown` → rediscover extensions → new ExtensionRunner → `session_start` with `reason = "reload"`. Existing session state (messages, cwd) is preserved. Extensions should be idempotent across reloads.
