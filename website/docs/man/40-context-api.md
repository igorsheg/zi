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

`ctx.send_user_message(text, opts?)`
: Inject a user message into the main chat through the same host paths as typed input. When the session is idle, the default target submits a new prompt after the current extension handler returns. When the session is streaming, the default target queues steering text for the active run. `opts.target` may be `"prompt"`, `"steering"`, `"follow_up"`, or `"auto"` (default). The call returns `{ status = "submitted" }` for an idle prompt enqueue or `{ status = "queued" }` for a run-control queue. This API is intentionally not a session-control shortcut: it does not reload, fork, or replace the live runner.

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
: Publish, update, or remove a retained UI view. `spec.id` is required. `spec.target` is one of `status`, `toast`, `overlay`, `editor.border.top`, or `editor.border.bottom`; it may also be a table such as `{ kind = "overlay", width = "80%", max_height = "80%", anchor = "center", backdrop = "dim" }`. Set `spec.remove = true` to clear a view. `spec.root` is a node tree (`view`, `text`, `input`, `chip`, `progress`, `separator`, or `surface`). `spec.keys` declares key bindings that are delivered through `zi.on("ui", ...)`.

`ctx.ui.frame(spec)`
: Publish a frame for a `surface` node in an existing render tree. `spec.view` names the render view id, `spec.node` names the surface node id, and `spec.data` contains frame bytes. Supported formats include `rgba8888` and `halfblock_rgb`. `surface` remains the node type for framebuffer graphs and other pixel/cell-frame visuals.

### UI input nodes

Input nodes are first-class fields for focused overlays. Zi owns editing mechanics so extensions do not need to implement terminal cursor/delete behavior; extensions own durable state and should re-render after events.

`{ type = "input", ... }` supports:

`id`
: Required string. Used as the event `node` id and local input-state key.

`value`
: Current extension-owned value. Defaults to `""`. Re-render with the updated value after handling a change/submit event.

`placeholder`
: Optional string shown when `value` is empty.

`on_change`
: Optional action string delivered on edit events as `{ type = "change", node = id, action = on_change, value = "..." }`.

`on_submit`
: Optional action string delivered when Enter is pressed as `{ type = "submit", node = id, action = on_submit, value = "..." }`.

`style`
: Standard node style fields (`tone`, `fg`, `bg`, attributes, sizing).

Example:

```lua
ctx.ui.render({
  id = "rename-session",
  target = { kind = "overlay", width = "50%", anchor = "center", backdrop = "dim" },
  focus = true,
  root = { type = "view", style = { chrome = { kind = "frame", title = "Rename" }, padding = 1 }, children = {
    { type = "input", id = "name", value = state.name or "", placeholder = "Session name", on_change = "rename.change", on_submit = "rename.submit" },
  } },
})

zi.on("ui", function(event, ctx)
  if event.action == "rename.change" then
    state.name = event.value or ""
    -- re-render with state.name
  elseif event.action == "rename.submit" then
    -- commit state.name and close the overlay
  end
end)
```

### UI text nodes

Text nodes render plain, ANSI, or Markdown text and may contain newlines. By default they wrap by word to the node width; explicit newlines always start new lines. Use `wrap = "none"` for fixed-width dashboards/tables or `wrap = "char"` for character wrapping.

`{ type = "text", ... }` supports:

`text`
: String content. Omit when using `spans`.

`spans`
: Array of `{ text, style?, link? }`. Spans concatenate into the node text and can style or link ranges. Span `style` supports `fg`, `bg`, `tone`, `bold`, `dim`, `italic`, `underline`, and `strikethrough`.

`wrap`
: `"word"` (default), `"char"`, or `"none"`. Markdown format uses the existing Markdown renderer/document layer, which owns document wrapping; `wrap`, `max_lines`, `scroll_x`, and `align` are Text-component options and do not affect Markdown rendering. `scroll_y` does apply to Markdown.

`overflow`
: `"clip"` (default) or `"ellipsis"` for clipped text.

`max_lines`
: Optional maximum rendered/measured line count.

`scroll_y`, `scroll_x`
: Optional vertical/horizontal scroll offsets. `scroll_x` is most useful with `wrap = "none"`.

`align`
: `"left"` (default), `"center"`, or `"right"`.

`format`
: `"plain"` (default), `"ansi"`, or `"markdown"`. ANSI uses an SGR text parser and supports OSC 8 hyperlinks. Markdown uses zi's existing Markdown renderer/document layer.

`link`
: Optional link for the whole node. Span links can override ranges. Markdown-format text currently ignores node-level `link`; use inline Markdown links instead.

`selectable`
: Optional boolean marking text as selectable for future selection-oriented UI behavior. Markdown-format text currently ignores this hint.

Style colors accept names such as `red`, `green`, `yellow`, `blue`, `magenta`, `cyan`, `white`, `black`, or hex strings like `#7aa2f7`. Tones include `neutral`, `muted`, `info`, `success`, `warning`, `danger`, and `accent`. Visual frame chrome lives on the composing `view` via `style.chrome`; overlays only place/focus the tree.

Dashboard text example:

```lua
ctx.ui.render({
  id = "session-breakdown",
  target = { kind = "overlay", width = "80%", max_height = "80%", anchor = "center" },
  root = { type = "view", style = { chrome = { kind = "frame", title = "Session breakdown", border = "rounded", tone = "muted" }, padding = 1, gap = 1 }, children = {
    { type = "text", wrap = "none", spans = {
      { text = "7d", style = { tone = "accent", bold = true } },
      { text = " · tokens · cost", style = { dim = true } },
    } },
    { type = "text", text = "Tokens: 184k\nCost:   $3.42", wrap = "none", align = "right" },
    { type = "text", text = "## Notes\n- Spike on Tuesday\n- Cache hits improved", format = "markdown", scroll_y = 0 },
  } },
})
```

Example:

```lua
ctx.ui.render({
  id = "hello",
  target = { kind = "toast", anchor = "top_right", lifetime = "until_input" },
  root = { type = "text", text = "Hello from zi" },
})

ctx.ui.render({
  id = "panel",
  target = { kind = "overlay", width = "70%", anchor = "center", backdrop = "dim" },
  keys = { { key = "escape", action = "close" }, { key = "q", action = "close" } },
  root = { type = "view", style = { chrome = { kind = "frame", title = "Panel", border = "rounded", tone = "muted" }, padding = 1 }, children = {
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

Extension-scoped state maps are not part of API v3. Use Lua locals for extension-ephemeral state. Durable extension state should be represented explicitly as session artifacts. Use `ctx.session.append_artifact` for extension-owned JSON state, or notes/labels for human-readable annotations and entry bookmarks.

## Session

`ctx.session.info()`
: Return session information.

`ctx.session.name()`
: Return the session name, or `nil`.

`ctx.session.rename(name)`
: Set or clear the session name.

`ctx.session.messages({ limit?, include_tools? })`
: Return recent durable transcript messages. Default limit is 50, max is 500. Returned messages include durable `entry_id` values and are shaped for transcript inspection.

`ctx.session.context({ include_tools?, max_messages? })`
: Return the active assembled model context as semantic data: `{ system_prompt, messages, tools? }`. Messages are normalized from the current branch with compaction/branch summaries converted the same way zi prepares provider context. `max_messages` limits the returned tail after optional tool filtering (default/max 500). `include_tools = false` omits tool schemas, tool calls, and tool results. The result intentionally avoids provider transport payloads and session-manager internals; use `before_provider_request` when you need to observe the exact transport request.

`ctx.session.tool_results(tool_name)`
: Return recorded tool results.

`ctx.session.append_note({ kind, title?, body, source_entry_id? })`
: Append a durable note. `sourceEntryId` is accepted as an alias.

`ctx.session.notes({ kind?, source_entry_id?, limit? })`
: Return notes. Default limit is 50, max is 500.

`ctx.session.append_artifact({ kind?, key?, title?, data })`
: Append a durable extension-owned artifact on the current branch. `data` must be JSON-compatible and is bounded by the extension JSON conversion limits. Artifacts are stored as inspectable session entries, are not added to model context, advance the session tree like other durable entries, and are scoped to the calling extension owner. Default `kind` is `"artifact"`.

`ctx.session.artifacts({ kind?, key?, limit? })`
: Return artifacts for the calling extension owner from the current branch, newest limited to the requested tail. Default limit is 50, max is 500. Each item includes `entry_id`, `owner_id`, `kind`, optional `key`/`title`, and `data`.

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

Optional streaming callbacks may be passed as `on = function(event)` or as a table keyed by event type. Callbacks run on the extension Lua thread while `ctx.ai.complete` is waiting for the final result. They must be non-yielding (do not call yieldable APIs such as `ctx.ai.complete`, `zi.system`, or coroutine yield from them).

```lua
local result = ctx.ai.complete({
  prompt = "draft release notes",
  on = {
    message_start = function(event) end,
    message_update = function(event)
      local update = event.assistantMessageEvent
      if update and update.type == "text_delta" then io.write(update.delta or "") end
    end,
    message_end = function(event) end,
  },
})
```

Stream event tables use the normalized message lifecycle shape: `type = "message_start", message = {...}`, `type = "message_update", message = {...}, assistantMessageEvent = {...}`, and `type = "message_end", message = {...}`. For streamed text, read `event.assistantMessageEvent.delta` when `event.assistantMessageEvent.type == "text_delta"`. Error and backpressure events may be delivered as `type = "error", error = "..."` or `type = "events_dropped", count = n`.


`ctx.ai.session(options)`
: Create an extension-owned side AI session. The session is in-memory, belongs to the current extension runner generation, and is disposed automatically when the extension generation/session shuts down. Use this for persistent side-channel conversations; use `ctx.ai.complete` for one-off completions.

```lua
local side = ctx.ai.session({
  model = "provider/model-id",        -- optional; defaults to current model
  system_prompt = "You are concise",  -- optional
  reasoning = "low",                  -- optional
  tools = { "read", "edit" },         -- optional allowlist; absent means no tools
  context = ctx.session.context({ max_messages = 120 }), -- optional string or context object
  on = {
    message_update = function(event) end,
    tool_execution_start = function(event) end,
    tool_execution_end = function(event) end,
  },
  messages = {
    { role = "user", text = "initial question" },
    { role = "assistant", text = "initial answer" },
  },
})

local result = side:prompt({
  prompt = "continue the side conversation",
  on = function(event) end, -- same streaming callback shape as ctx.ai.complete
})
side:abort()   -- cancels the currently running side prompt when possible
side:clear()   -- clears side transcript when idle
side:dispose() -- releases in-memory state early
```

`side:prompt(...)` returns the same result shape as `ctx.ai.complete` and commits successful turns to that side session's typed in-memory transcript. Side sessions do not mutate the main transcript. zi runs prompts through a managed in-process side agent; `tools = nil` or `{}` means no tools, while `tools = { ... }` is fail-fast validated against the parent session's available tools. Nested extension loading remains disabled. Session-wide `on` callbacks and per-prompt `on` callbacks are both delivered through the parent extension runner on the Lua thread.

Side event tables include lifecycle events (`agent_start`, `agent_end`, `turn_start`, `turn_end`), message events (`message_start`, `message_update`, `message_end`), tool events (`tool_execution_start`, `tool_execution_update`, `tool_execution_end`), `error`, and `events_dropped`. Message events include a JSON-compatible `message` table; `message_update` also includes `assistantMessageEvent` with normalized stream details (`text_delta`, `thinking_delta`, `toolcall_delta`, etc.). Tool events include compatibility aliases such as `tool_name`/`toolName`, `tool_call_id`/`toolCallId`, `input`/`args`, and `is_error`/`isError`.

Results:

```lua
{ status = "completed", text = "..." }
{ status = "error", error = "..." }
{ status = "cancelled" }
```

Inspection helpers:

```lua
side:info()      -- { id, busy, disposed, message_count, tools }
side:messages({ limit = 100, include_tools = true }) -- typed, JSON-compatible side transcript summary
side:is_busy()   -- true while the side agent is running a prompt
```

`ctx.ai.complete`, `ctx.ai.session`, and `zi.spawn` remain distinct: complete is one-shot, session is a multi-turn in-process side agent, and spawn delegates to an isolated child zi task.

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
