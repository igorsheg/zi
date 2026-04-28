## context object

Most [tools](api.html#tools), [commands](api.html#commands), and [events](api.html#events) receive `ctx`.

`ctx.cwd`
: Current working directory.

`ctx.has_ui`
: Boolean indicating whether UI capabilities are available.

`ctx.binding`
: Session and extension identity information when available.

`ctx.ui`
: Host-owned UI API, or `nil` when unavailable.

`ctx.state`
: Session-persisted state API scoped to the current extension.

`ctx.session`
: Session information and semantic session helpers when bound.

`ctx.ai`
: Sessionless AI helper API.

`ctx.models`
: Visible model catalog helpers when bound.

`ctx.signal`
: Cancellation signal when available; otherwise `nil`.

`ctx.is_idle()`
: Return whether the active session is idle, when bound.

`ctx.abort()`
: Request abort on the active run, when bound.

`ctx.has_pending_messages()`
: Return whether the session has queued/pending messages, when bound.

`ctx.shutdown()`
: Request shutdown when that capability is bound.

`ctx.get_context_usage()`
: Return context usage information when bound.

`ctx.get_system_prompt()`
: Return the active system prompt when bound.

## context ui api

The UI API publishes presentation intent. Extensions do not own terminal components or redraw. Recreate live UI surfaces from [extension lifecycle](extensions.html#extension-lifecycle) events when sessions change.

`ctx.ui.show_panel({ id, title, lines, transient })`
: Show a host-owned panel. `lines` may be strings or arrays of text spans. A span may include `text`, `fg`, and `dim`.

`ctx.ui.notify(text, kind)`
: Publish a notification. `kind` is `info`, `warning`, or `error`; unknown kinds fall back to `info`.

`ctx.ui.set_status(id, value, opts?)`
: Publish a keyed status item.

`ctx.ui.set_title(value, opts?)`
: Publish title intent.

`ctx.ui.set_widget(id, value, opts?)`
: Publish a widget surface.

`ctx.ui.set_header(value, opts?)`
: Publish header content.

`ctx.ui.set_footer(value, opts?)`
: Publish footer content.

`ctx.ui.set_working(value, opts?)`
: Publish working/loading text.

`ctx.ui.set_hidden_thinking_label(value, opts?)`
: Publish hidden-thinking label text.

`ctx.ui.show_overlay(id, value, opts?)`
: Publish an overlay surface.

`ctx.ui.confirm(...)`
: Request boolean confirmation from the host.

`ctx.ui.input(...)`
: Request single-line text input.

`ctx.ui.select(...)`
: Request selection from stable options.

`ctx.ui.editor(...)`
: Request multi-line editor input.

`ctx.ui.prompt({ kind = "confirm"|"select"|"input"|"editor", ... })`
: Generic prompt request. Returns an envelope with `status` and, when submitted, `value`.

`ctx.ui.set_editor_text(text)`
: Set host editor text.

`ctx.ui.paste_to_editor(text)`
: Paste text into the host editor.

`ctx.ui.clear_editor_text()`
: Clear host editor text.

`ctx.ui.get_editor_text()`
: Request editor text when the host exposes that capability. Returns `nil` when unavailable.

Surface option tables may include `placement` and `lifetime`. `lifetime` is `session` or `until_input`.

## context state api

`ctx.state` is a per-extension session-persisted map:

`ctx.state.get(key)`
: Return a JSON-compatible value or `nil`.

`ctx.state.set(key, value)`
: Persist a JSON-compatible value for this extension's state owner.

`ctx.state.delete(key)`
: Write a tombstone for the key.

State is scoped to the extension and active session. It may survive session changes according to the lifecycle rules in [extension lifecycle](extensions.html#extension-lifecycle). UI handles, prompts, jobs, and provider handles are live objects and should be recreated when needed.

## context session api

`ctx.session.info()`
: Return semantic session information.

`ctx.session.name()`
: Return the session name, or `nil`.

`ctx.session.rename(name)`
: Set or clear the session name. Returns boolean success.

`ctx.session.messages({ limit?, include_tools? })`
: Return recent semantic messages. Default limit is 50; maximum is 500. `include_tools` defaults to true.

`ctx.session.tool_results(tool_name)`
: Return recorded tool results for a tool.

`ctx.session.append_note({ kind, title?, body, source_entry_id? })`
: Append a semantic session note. `source_entry_id` links the note to a durable session entry. Returns boolean success.

`ctx.session.notes({ kind?, source_entry_id?, limit? })`
: Return session notes. Default limit is 50; maximum is 500.

`ctx.session.label(entry_id, label)`
: Append a lightweight durable label for a session entry. Passing `nil` or an empty string clears the label. Returns boolean success.

`ctx.session.labels({ target_entry_id?, limit? })`
: Return label entries, optionally filtered to a target session entry. Default limit is 50; maximum is 500.

## context model and ai api

`ctx.models.list()`
: Return visible model catalog entries.

`ctx.models.current()`
: Return the current model.

`ctx.models.get(ref)`
: Resolve a model by id, provider/id string, or model-like table.

`ctx.ai.complete(request)`
: Run a sessionless model completion. It does not mutate the transcript and does not run tools. For provider/model registration, see [providers](api.html#providers).

`ctx.ai.complete` accepts either a prompt string or a table:

```lua
ctx.ai.complete({
  model = "provider/model-id",
  prompt = "summarize this",
  system_prompt = "optional system text",
  max_tokens = 800,
  reasoning = "low",
})
```

`reasoning` may be `off`, `minimal`, `low`, `medium`, `high`, `xhigh`, or a boolean (`true` maps high, `false` maps off).

The result shape is:

```lua
{ status = "completed", text = "..." }
{ status = "error", error = "..." }
{ status = "cancelled" }
```

## spawn helper

`zi.spawn(opts)` runs delegated child zi work through batch JSON mode and returns a table shaped like a tool result. Prefer normal [tools](api.html#tools), [commands](api.html#commands), and [context model and ai api](#context-model-and-ai-api) when a child agent is not required.

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
: Optional table of event-name callback functions.

Caveats:

- `zi.spawn` is yieldable and should be called only from yieldable execution contexts.
- callbacks in `on` must not yield.
- abort forwarding depends on the execution context. Prefer spawning from tool or command work where cancellation is expected.
