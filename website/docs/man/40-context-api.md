---
slug: context
title: Context
order: 40
aliases:
  - ctx
  - context api
  - session
  - ui
  - models
---

# Context

Most tools, commands, and events receive `ctx`.

`ctx` is the extension's view of the current run.

## Fields

`ctx.cwd`
: Current working directory.

`ctx.has_ui`
: Whether UI APIs are available.

`ctx.binding`
: Session and extension identity, when available.

`ctx.extension`
: Current extension identity and resource paths. Bundled extensions get their extension directory as `root`; flat extensions get the directory containing the `.lua` file.

`ctx.ui`
: Host-owned UI API, or `nil`.

`ctx.editor`
: Host-owned editor draft API, or `nil`.

`ctx.session`
: Session information and semantic session helpers.

`ctx.ai`
: Sessionless AI helper API.

`ctx.models`
: Visible model catalog helpers.

`ctx.signal`
: Cancellation signal, or `nil`.

`ctx.is_idle()`
: Return whether the active session is idle.

`ctx.abort()`
: Request abort on the active run.

`ctx.update(partial_result)`
: Update the current in-flight tool preview. The final tool return remains authoritative.

`ctx.has_pending_messages()`
: Return whether the session has queued messages.

`ctx.shutdown()`
: Request shutdown.

`ctx.context_usage()`
: Return context usage information.

`ctx.system_prompt()`
: Return the active system prompt.

## UI

`ctx.ui` publishes host-owned UI intent. Extensions describe views; zi owns placement, focus, and redraw. API v3 exposes two methods:

`ctx.ui.render(spec)`
: Publish, update, or remove a retained UI view. `spec.id` is required. `spec.target` is one of `status`, `toast`, `overlay`, `editor.border.top`, or `editor.border.bottom`; it may also be a table such as `{ kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }`. Set `spec.remove = true` to clear a view. `spec.root` is a node tree (`box`, `text`, `chip`, `progress`, or `surface`). `spec.keys` declares key bindings that are delivered through `zi.on("ui", ...)`.

`ctx.ui.frame(spec)`
: Publish a frame for a `surface` node in an existing render tree. `spec.view` names the render view id, `spec.node` names the surface node id, and `spec.data` contains frame bytes. Supported formats include `rgba8888` and `halfblock_rgb`.

Example:

```lua
ctx.ui.render({
  id = "hello",
  target = { kind = "toast", anchor = "top_right", lifetime = "until_input" },
  root = { type = "text", text = "Hello from zi" },
})

ctx.ui.render({
  id = "panel",
  title = "Panel",
  target = { kind = "overlay", width = "70%", anchor = "center", backdrop = "dim" },
  keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
  root = { type = "box", style = { border = true, padding = 1 }, children = {
    { type = "text", text = "Press q or Esc to close." },
  } },
})

zi.on("ui", function(event, ctx)
  if event.view == "panel" and event.action == "close" then
    ctx.ui.render({ id = "panel", remove = true })
  end
end)
```

## Editor

`ctx.editor` is available when zi can update the host-owned editor draft. It exposes exactly these methods:

`ctx.editor.set_text(text)`
: Replace editor text.

`ctx.editor.insert_text(text)`
: Insert text at the editor cursor.

`ctx.editor.clear()`
: Clear editor text.

There is no synchronous editor text getter.

## State

Extension-scoped state maps are not part of API v3. Use Lua locals for extension-ephemeral state. Durable extension state should be represented explicitly as session artifacts such as notes or labels.

## Session

`ctx.session.info()`
: Return session information.

`ctx.session.name()`
: Return the session name, or `nil`.

`ctx.session.rename(name)`
: Set or clear the session name.

`ctx.session.messages({ limit?, include_tools? })`
: Return recent semantic messages. Default limit is 50, max is 500. Returned messages include durable `entry_id` values.

`ctx.session.tool_results(tool_name)`
: Return recorded tool results.

`ctx.session.append_note({ kind, title?, body, source_entry_id? })`
: Append a durable note. `sourceEntryId` is accepted as an alias.

`ctx.session.notes({ kind?, source_entry_id?, limit? })`
: Return notes. Default limit is 50, max is 500.

`ctx.session.label(entry_id, label)`
: Append a durable label for an entry. Nil or empty label clears it.

`ctx.session.labels({ target_entry_id?, limit? })`
: Return label entries.

`ctx.session.entry(entry_id)`
: Return one semantic session entry, or `nil`.

`ctx.session.entries({ label?, limit? })`
: Return target entries by predicate. Currently supports `label`.

Use durable ids for memory that should be inspectable later.

```lua
zi.on("message", function(event, ctx)
  local message = event.message or {}
  if message.role == "user" and message.text and message.text:match("decision") then
    ctx.session.label(message.entry_id, "decision")
    ctx.session.append_note({
      kind = "observation",
      body = "decision candidate",
      source_entry_id = message.entry_id,
    })
  end
end)
```

Later:

```lua
for _, entry in ipairs(ctx.session.entries({ label = "decision", limit = 20 })) do
  local notes = ctx.session.notes({ source_entry_id = entry.entry_id })
end
```

## Models and AI

`ctx.models.list()`
: Return visible model catalog entries.

`ctx.models.current()`
: Return the current model.

`ctx.models.get(ref)`
: Resolve a model by id, provider/id string, or model-like table.

`ctx.ai.complete(request)`
: Run a sessionless model completion. It does not mutate the transcript and does not run tools.

```lua
ctx.ai.complete({
  model = "provider/model-id",
  prompt = "summarize this",
  system_prompt = "optional system text",
  max_tokens = 800,
  reasoning = "low",
})
```

`reasoning` may be `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or a boolean.

Results:

```lua
{ status = "completed", text = "..." }
{ status = "error", error = "..." }
{ status = "cancelled" }
```

## System commands

`zi.system(argv, opts?)` runs an OS command from an argv array. It is yieldable. Call it from tools or commands, not extension load code.

```lua
local result = zi.system({ "git", "status", "--short" }, {
  cwd = ctx.cwd,
  timeout_ms = 5000,
})
```

There is no shell string form. Use a shell explicitly when needed:

```lua
zi.system({ "/bin/sh", "-c", "echo $HOME" })
```

Options:

`cwd`
: Working directory.

`stdin`
: Optional stdin string.

`env`
: Optional string map over the inherited environment.

`clear_env`
: When true, only `env` is used.

`timeout_ms`
: Timeout in milliseconds.

`max_stdout_bytes`, `max_stderr_bytes`
: Bounded capture limits.

`text`
: Defaults true. Normalizes CRLF to LF.

`stdio`
: `"capture"` or `"terminal"`. Terminal mode is TUI-only and attaches the child to the user's terminal. Use it for `$EDITOR`, `$PAGER`, `fzf`, `lazygit`, and login flows. Capture-only options are invalid with terminal mode.

Results:

```lua
{ status = "completed", code = 0, signal = nil, stdout = "...", stderr = "..." }
{ status = "error", error = "...", stdout = "", stderr = "" }
{ status = "timeout", error = "timed out after ...ms", stdout = "...partial...", stderr = "...partial..." }
```

Non-zero exits are `status = "completed"`; inspect `code`.

## Spawn

`zi.spawn(opts)` runs a child zi task through batch JSON mode and returns a tool-shaped result. Use it for real delegation, not ordinary helper logic.

```lua
local result = zi.spawn({
  task = "inspect the API surface",
  model = "optional-model",
  tools = "bash,read,grep",
  system_append = "extra child-agent guidance",
  cwd = ctx.cwd,
  on = {
    message = function(event) end,
  },
})
```

Fields:

`task`
: Required child prompt.

`model`
: Optional child model.

`tools`
: Optional comma-separated child tool filter.

`system_append`
: Optional text appended to the child system prompt.

`cwd`
: Optional child working directory. Defaults to `.`.

`on`
: Optional event callbacks keyed by child event name. Callbacks run on the parent extension/Lua thread and must not yield.

Caveats:

- `zi.spawn` is yieldable
- callbacks in `on` must not yield
- abort forwarding depends on the execution context
