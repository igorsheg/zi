---
slug: api
title: API
order: 30
aliases:
  - extension api
  - zi api
  - tools
  - commands
  - events
---

# API

Extensions get a global `zi` table.

The API is plain Lua. Tables in, tables out. Keep names exact and results small.

## `zi` table

`zi.tool(spec)`
: Register a model-visible tool. Duplicate names are ignored; returns `false`.

`zi.command(spec)`
: Register an interactive slash command. Duplicate names get resolved invocation names.

`zi.provider(name, config)`
: Register a provider/model claim. Existing claims are not replaced unless owned by this source.

`zi.unprovider(name)`
: Remove this extension's provider claim.

`zi.on(event_name, handler)`
: Register an observer or interceptor.

`zi.system(argv, opts?)`
: Run an argv command through zi's async scheduler.

`zi.spawn(opts)`
: Run delegated child zi work through batch JSON mode.

`zi.job.start(opts)`
: Start a host job. Returns `{ id }`.

`zi.job.write(id_or_job, data)`
: Write to job stdin.

`zi.job.stop(id_or_job)`
: Request job termination.

`zi.json.encode(value)`
: Encode a JSON-compatible Lua value.

`zi.json.decode(text)`
: Decode JSON. JSON `null` becomes Lua `nil`.

## Tools

A tool is visible to the model. Keep it narrow.

`zi.tool(spec)` accepts:

`name`
: Required string. Model-visible id and collision key.

`description`
: Required string. Human/model-facing description.

`parameters`
: Required JSON-schema-like table.

`execute(params, ctx)`
: Required function. Runs the tool and returns the final tool result.

`label`
: Optional UI label. Defaults to `name`.

`prompt_snippet`
: Optional prompt metadata.

`prompt_guidelines`
: Optional array of prompt guidance bullets.

`render_call(args, ctx)`
: Optional call-slot renderer.

`render_result(result, ctx)`
: Optional result-slot renderer.

Tool result:

```lua
{
  content = {
    { type = "text", text = "..." },
  },
  details = {},
  presentation = {},
  is_error = false,
}
```

`content` is model-visible and tightly bounded. `details` is small JSON metadata. `presentation` is extension-owned UI state for `render_result`; zi may truncate or omit oversized values and mark the object with reserved `__zi_*` fields.

## Commands

Commands are direct user actions.

`zi.command(spec)` accepts:

`name`
: Required string. Slash command name without `/`.

`description`
: Optional string shown in command lists.

`handler(args, ctx)`
: Required function. Runs on the agent thread.

```lua
return function(zi)
  zi.command({
    name = "hello",
    description = "Show a greeting.",
    handler = function(args, ctx)
      ctx.ui.render({
        id = "hello-command",
        target = { kind = "overlay", preset = "centered" },
        focus = true,
        keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
        root = {
          type = "view",
          style = { chrome = { kind = "frame", title = "hello", border = "rounded", tone = "muted" }, padding = 1 },
          children = { { type = "text", text = "hello, " .. (args or "zi") } },
        },
      })
    end,
  })
end
```

Slash command order:

1. built-in interactive commands
2. extension commands
3. prompt-template and skill expansion on miss
4. `input` interceptor
5. prompt assembly and provider run

Built-ins stay TUI-local when they need immediate UI/session behavior. Extension commands enqueue semantic work to the agent thread.

### UI focus

Overlay targets accept semantic presets with explicit fields as overrides: `preset = "ivy"` renders a full-width bottom sheet, `preset = "centered"` renders a modal dialog, and `preset = "top_toast"` renders a small top-right overlay. For example: `target = { kind = "overlay", preset = "ivy", max_height = "55%" }`.

`ctx.ui.render({ focus = true, target = { kind = "overlay" }, ... })` requests keyboard capture for that overlay. Capturing overlays receive v3 `ui` key events and prevent editor input until they close or re-render without focus. `input` nodes inside a focused overlay are edited by the TUI itself; each edit emits a structured `ui` event with `type = "change"`, `node`, `value`, and optional `action`, and Enter emits `type = "submit"`. Extensions should update their own state from those events and re-render the input value. Overlays without `focus = true`, including status views, remain visible but non-capturing; transcript scrolling and editor input continue to use the existing app focus.

Notifications use the fidget-style API instead of `ctx.ui.render` targets:

```lua
ctx.ui.notify("Ready for input", {
  id = "agent-ready",     -- replacement key
  group = "agent",        -- compact left label when no title is set
  level = "info",         -- debug/info/warn/error/success
  title = "Agent",        -- optional label
  annote = "until input", -- optional right-side note
  progress = false,
  done = false,
})

ctx.ui.notify_clear("agent-ready")
```

Notifications render as a quiet bottom-right stack, replacing previous entries with the same id. Use them for transient liveness and status; use `ctx.ui.render` for structured/persistent surfaces.

UI render trees support `view`, `text`, `input`, `chip`, `progress`, `separator`, and `surface` nodes. Visual frame chrome is composed on `view.style.chrome`; top-level render specs describe placement/focus only. The full text-node API, including wrapping, spans, ANSI/Markdown formats, links, and selection hints, is documented in [Context](context.html#ui-text-nodes). `surface` remains available for framebuffer graphs.

## Providers

Providers describe visible model/provider choices. Use events to rewrite requests.

`zi.provider(name, config)` supports:

`api`
: Required for custom provider names. Built-in provider overrides may infer it.

`base_url`
: Required string.

`api_key`
: Optional string.

`headers`
: Optional string map.

`models`
: Optional array of model tables.

`oauth`
: Optional callbacks for compatible OAuth-backed provider models. Supported fields: `login`, `refresh_token` or `refreshToken`, and `getApiKey`.

Built-in visible provider names with override support:

- `anthropic`
- `openai`
- `openrouter`
- `openai-codex`

Extensions own claims, not provider runtime pointers or credential persistence.

## Events

`zi.on(name, handler)` registers an observer or interceptor. Handlers receive `(event, ctx)`.

Observer events are post-commit. Return values are ignored.

Interceptor events run before zi commits an action. Depending on the event, handlers may replace payloads, cancel work, or provide event-specific results.

Event names:

`session_directory`
: Pick a session directory at startup.

`resources_discover`
: Aggregate event name reserved for resource-folder discovery. Current startup discovery is static; see [Resource discovery](resources.html).

`input`
: Middleware over submitted prompt text after slash-command dispatch.

`before_agent_start`
: Hook before the final agent prompt/request. May add messages or replace the system prompt.

`context`
: Middleware over message context for the next provider call.

`before_provider_request`
: Middleware over the semantic provider request payload.

`agent_start`, `agent_end`
: Observe agent run boundaries.

`turn_start`, `turn_end`
: Observe assistant turn boundaries.

`message_start`, `message_update`, `message_end`, `message`
: Observe transcript/message edges. `message_update` carries `event.message` plus `event.assistantMessageEvent` (`text_delta`, `thinking_delta`, `toolcall_delta`, etc.). `message` is the durable semantic observer and includes `event.message.entry_id`.

`tool_execution_start`, `tool_execution_update`, `tool_execution_end`
: Observe tool execution state.

`tool_call`
: Middleware over validated tool call input.

`tool_result`
: Middleware over final tool result content, details, and error bit before commit.

`user_bash`
: Cancellable/aggregate seam for user-initiated shell execution.

`session_start`, `session_shutdown`
: Observe session lifecycle.

`session_before_switch`
: Cancellable seam before `/new` or `/resume` replaces the session.

`session_before_fork`
: Cancellable/aggregate seam before forking from an entry.

`session_before_compact`, `session_compact`
: Pre/post compaction events.

`session_before_tree`, `session_tree`
: Pre/post tree navigation events.

`ui`
: Key interactions from focused v3 UI views. Handlers receive `{ type = "key", view, node?, action?, key?, ctrl, alt, shift }`. Use `ctx.ui.render({ id = event.view, remove = true })` to close views.

`job_stdout`, `job_stderr`, `job_exit`, `job_json`
: Job output and exit lifecycle events.

`model_select`
: Observe model selection changes.

Interceptors should return semantic data only. Do not depend on transport structs, TUI state, mailbox state, or provider runtime handles.

## Jobs

`zi.job.start({ argv, cwd?, stdout? })` starts a long-running host job.

By default, stdout/stderr/exit are delivered through job events.

`stdout = { mode = "json_lines", max_line_bytes? }` parses stdout as JSONL and emits `job_json`.

`stdout = { mode = "ui_frame", view = "doom-workbench", node = "doom-surface", protocol = "zi-halfblock-rgb-v1", max_frame_bytes? }` publishes half-block RGB records to a v3 `surface` node.

`zi-halfblock-rgb-v1` records look like:

```text
HALFBLOCK <cols> <rows> <byte_len>\n<fg_rgb bg_rgb cell bytes>
```

`byte_len` must equal `cols * rows * 6`: three foreground RGB bytes for the upper half block, then three background RGB bytes for the lower half block. `FRAME <width> <height> <byte_len>` remains the record marker for `protocol = "zi-rgba-frame-v1"`, where `byte_len` is `width * height * 4`.
