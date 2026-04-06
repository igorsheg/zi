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
4. **First-registered-wins collision semantics.** Load order: user extensions first, then project extensions, then built-in defaults. A user override "wins" by loading before the built-in default.
5. **Single Lua state, agent-thread affinity.** The Lua state lives on the agent thread. Agent hooks (before/after_tool_call) run Lua inline. UI requests from Lua marshal to the TUI thread, do their work, and resume the Lua coroutine back on the agent thread.
6. **Forward-declared ExtensionRunner ref.** The Agent is constructed with `stream_fn` / `transform_context` / `on_payload` closures that reference a mutable ref. The ref is populated when AgentSession creates the ExtensionRunner. This mirrors pi-mono's `extensionRunnerRef: { current?: ExtensionRunner }` pattern.

### Discovery

```
  ORDER              PATH                                PURPOSE
  ─────              ────                                ───────
  1. explicit        --extension <path> CLI flag         testing, opt-in
  2. project-local   .zi/extensions/*.lua                team-shared
  3. user-global     ~/.zi/agent/extensions/*.lua        personal config
  4. built-in        (compiled into binary)              defaults

  Within each directory:
  - foo.lua                → single-file extension
  - foo/init.lua           → directory extension with helper files
```

Collision rule: first-registered-wins **per identifier** (tool name, command name). User extensions load before built-ins, so a `~/.zi/agent/extensions/task.lua` overrides the built-in Task tool. Multiple extensions registering the same tool name: earliest in load order wins, others log a warning.

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
  -- mutate event.input in place to patch args
  event.input.command = "..."

  -- return nil to allow, or a table to block:
  return { block = true, reason = "..." }
end)
```

Multiple handlers chain: earlier mutations are visible to later handlers. If any handler returns `{ block = true }`, execution stops and the reason is surfaced.

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
3. The Lua coroutine resumes with a cancellation result:
   ```lua
   local result = zi.spawn({ task = "..." })
   if result.cancelled then
     -- handle cancellation
   end
   ```
4. Extension event handlers may catch and continue, or re-raise to abort the current operation

This matches zi's existing `AbortSignal` threading through tool execution and spawn.

---

## Error Handling

- Errors in Lua handlers are caught per-handler, logged with extension path, and execution continues.
- A single broken extension does NOT disable all extensions.
- Repeated failures from the same extension (3+) log a warning; the extension stays loaded (user's responsibility).
- In print/json modes, errors write to stderr. In interactive mode, errors write to the status area.
- `error_message` events are raised on the extension runner for extensions that want to surface errors to the user.

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
- Task, Oracle, Finder, HyperTask (the user's current `~/.pi` extensions)
- Custom tool wrappers and safety interceptors
- Custom logging / observability hooks
- Session-bound state via `zi.spawn`

**Deferred to v2+ (◐):**
- Commands, shortcuts, flags, providers, message renderers
- Transform events (context, input, before_agent_start, before_provider_request)
- Session lifecycle hooks beyond start/shutdown (before_switch, before_fork, compact, tree)
- UI context (widgets, dialogs, status bar, footer/header, editor control)
- Resource discovery beyond extensions (.md agents, skills, prompts, themes)
- Inter-extension event bus (`zi.events`)

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
