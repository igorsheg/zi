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

Extensions get a global `zi` table during loading and a `ctx` table during runtime handlers.

API v4 has three namespaces:

```text
zi.define.*     declarations made while loading
zi.{json,schema,doc} pure helpers
ctx.*           runtime capabilities for the current invocation
```

There is no compatibility layer. Use only the names documented here.

## Loading contract

Every extension file must return a factory function:

```lua
return function(zi)
  -- declarations only
end
```

Load code must be cheap and deterministic. It must not run processes, call models, mutate sessions, or publish UI. Runtime effects belong in `run` handlers and event handlers through `ctx`.

## Declarations

`zi.define.tool(spec)`
: Register a model-visible tool. Duplicate names are ignored; first registration wins.

`zi.define.command(spec)`
: Register an interactive slash command.

`zi.define.event(event_name, run)`
: Register an event handler. Event handlers receive `(ctx, event)`.

`zi.define.provider(spec)`
: Register provider/model claims.

`zi.define.keybinding(spec)`
: Register a keybinding.

`zi.define.action(name, run)`
: Register a named action callable by keybindings or UI events.

## Tools

A tool is visible to the model. Keep it narrow and bounded.

```lua
zi.define.tool({
  name = "greet",
  label = "Greeting",
  description = "Generate a greeting for a named person.",
  input = {
    type = "object",
    properties = {
      name = { type = "string", description = "Name to greet." },
    },
  },
  display = { call = "name" },
  prompt = {
    snippet = "Generate a concise greeting.",
    guidelines = { "Use greet only when a greeting is requested." },
  },
  run = function(ctx, input)
    local name = input.name or "world"
    return { content = { { type = "text", text = "hello, " .. name } } }
  end,
})
```

Accepted fields:

`name`
: Required string. Model-visible id and collision key.

`description`
: Required string. Model/tool description.

`input`
: Required JSON-schema-like table.

`run(ctx, input)`
: Required function. Runs the tool and returns the final tool result.

`label`
: Optional UI label. Defaults to `name`.

`display.call`
: Optional string naming one top-level input field to show in the transcript tool-call header.

`prompt.snippet`
: Optional short system-prompt entry for this tool.

`prompt.guidelines`
: Optional array of system-prompt guidance bullets active while this tool is available.

### Tool result

Tool results are data. Zi owns conversion to the model transcript and TUI.

```lua
return {
  content = {
    { type = "text", text = "model-visible text" },
    { type = "doc", doc = zi.doc.fragment({ ... }) },
    { type = "json", value = { ok = true } },
  },
  metadata = { duration_ms = 12 },
  is_error = false,
}
```

`content`
: Optional array. Text and JSON are model-visible. Doc blocks are semantic transcript UI data.

`metadata`
: Optional bounded JSON-compatible table for durable machine-readable details. It is not prompt text.

`is_error`
: Optional boolean. Domain failures should return `is_error = true`; programmer errors should raise.

`nil`
: Empty successful result.

String tool returns are invalid in v4.

### Doc content

Use `zi.doc` for semantic transcript presentation:

```lua
local doc = require("zi.doc")

return {
  content = {
    { type = "text", text = summary },
    { type = "doc", doc = doc.fragment({
      doc.line({ doc.span("Finder", "title", { bold = true }), doc.span(" complete", "muted") }),
      doc.step("done", "grep", "search complete"),
      doc.markdown(summary, { collapsed_lines = 12 }),
    }) },
  },
}
```

Supported block types are `line`, `text`, `markdown`, `group`, and `separator`. Doc data is durable data, not a render callback. Arbitrary `render_call` and `render_result` functions are not part of v4.

## Commands

Commands are direct user actions.

```lua
zi.define.command({
  name = "hello",
  description = "Show a greeting.",
  input = {
    type = "object",
    properties = { name = { type = "string" } },
  },
  run = function(ctx, input)
    local name = input.name or "zi"
    if ctx.ui and ctx.ui.view then
      ctx.ui.view.set({
        id = "hello-command",
        slot = { kind = "overlay", preset = "centered" },
        focus = true,
        keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
        root = {
          type = "view",
          style = { chrome = { kind = "frame", title = "hello", border = "rounded" }, padding = 1 },
          children = { { type = "text", text = "hello, " .. name } },
        },
      })
    end
  end,
})
```

Accepted fields:

`name`
: Required string. Slash command name without `/`.

`description`
: Optional string shown in command lists.

`input`
: Optional schema for structured command input.

`run(ctx, input)`
: Required function.

## Events

Event handlers receive `(ctx, event)`.

```lua
zi.define.event("ui", function(ctx, event)
  if event.view == "hello-command" and event.action == "close" then
    ctx.ui.view.set({ id = "hello-command", remove = true })
  end
end)
```

Common events include `session_start`, `session_shutdown`, `message`, `message_start`, `message_update`, `message_end`, `tool_execution_start`, `tool_execution_update`, `tool_execution_end`, `before_agent_start`, `ui`, and job events.

## Runtime effects

Runtime effects live under `ctx`:

`ctx.process.run(argv, opts?)`
: Run an argv command through zi's scheduler.

`ctx.process.start(opts)`
: Start a host job. Returns a job handle.

`ctx.process.job(id_or_job)`
: Return a job handle for stdin/stop operations.

`ctx.agent.run(opts)`
: Spawn a child zi task through batch JSON mode.

`ctx.ai.complete(request)`
: Run a sessionless model completion.

`ctx.ai.session(request)`
: Create an extension-owned side AI session.

## UI boundary

Use retained views for extension UI:

```lua
ctx.ui.view.set({
  id = "panel",
  slot = { kind = "overlay", width = "70%", anchor = "center", backdrop = "dim" },
  keys = { { key = "escape", action = "close" } },
  root = { type = "view", children = { { type = "text", text = "hello" } } },
})
```

Use notifications for short status:

```lua
ctx.ui.notify.show({ id = "build", level = "info", message = "building" })
ctx.ui.notify.clear("build")
```

Use surfaces for raw frames:

```lua
ctx.ui.surface.frame({ view = "doom", node = "fb", width = 80, height = 40, format = "halfblock_rgb", data = frame })
```
