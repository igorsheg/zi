# API

Extensions get a global `zi` table.

The API is plain Lua. Tables in, tables out. Keep names exact and results small.

## `zi` table

`zi.register_tool(spec)`
: Register a model-visible tool. Duplicate names are ignored; returns `false`.

`zi.register_command(spec)`
: Register an interactive slash command. Duplicate names get resolved invocation names.

`zi.register_provider(name, config)`
: Register a provider/model claim. Existing claims are not replaced unless owned by this source.

`zi.unregister_provider(name)`
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

`zi.register_tool(spec)` accepts:

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

`zi.register_command(spec)` accepts:

`name`
: Required string. Slash command name without `/`.

`description`
: Optional string shown in command lists.

`handler(args, ctx)`
: Required function. Runs on the agent thread.

```lua
return function(zi)
  zi.register_command({
    name = "hello",
    description = "Show a greeting.",
    handler = function(args, ctx)
      ctx.ui.report({
        id = "hello-command",
        title = "hello",
        body = "hello, " .. (args or "zi"),
        transient = true,
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

## Providers

Providers describe visible model/provider choices. Use events to rewrite requests.

`zi.register_provider(name, config)` supports:

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
: Add resource folders for `lua/`, `prompts/`, `skills`, `themes`, and `agents`.

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
: Observe transcript/message edges. `message` is the durable semantic observer and includes `event.message.entry_id`.

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

`surface_input`
: Keyboard input routed to a focused extension surface. Host escape/unfocus behavior is not extension-owned.

`job_stdout`, `job_stderr`, `job_exit`, `job_json`
: Job output and exit lifecycle events.

`model_select`
: Observe model selection changes.

Interceptors should return semantic data only. Do not depend on transport structs, TUI state, mailbox state, or provider runtime handles.

## Jobs

`zi.job.start({ argv, cwd?, stdout? })` starts a long-running host job.

By default, stdout/stderr/exit are delivered through job events.

`stdout = { mode = "json_lines", max_line_bytes? }` parses stdout as JSONL and emits `job_json`.

`stdout = { mode = "surface_frame", protocol = "zi-rgba-frame-v1", surface = "id", max_frame_bytes? }` publishes framebuffer records to a surface.

`zi-rgba-frame-v1` records look like:

```text
FRAME <width> <height> <byte_len>\n<rgba bytes>
```

`byte_len` must equal `width * height * 4`.

`stdout = { mode = "surface_cells", protocol = "zi-cell-frame-v1", surface = "id", max_frame_bytes? }` publishes ready-to-render half-block terminal cell records to a surface. Each cell is six bytes: foreground RGB followed by background RGB. zi renders each cell as `▀`.

```text
CELLS <cols> <rows> <byte_len>\n<fg_rgb bg_rgb cells>
```

`byte_len` must equal `cols * rows * 6`.
