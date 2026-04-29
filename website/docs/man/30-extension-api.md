## extension api: zi table

The extension API is deliberately plain.

Most of it is ordinary Lua functions and tables. The shape is simple so an extension can be read, copied, changed, or removed by one person.

Prefer small tools. Prefer explicit names. Prefer behavior that will still make sense when it appears in a session transcript later.

`zi.register_tool(spec)`
: Register a model-visible tool. See [tools](#tools).

`zi.register_command(spec)`
: Register an interactive slash command. See [commands](#commands).


`zi.register_provider(name, config)`
: Register or override a provider claim. See [providers](#providers).

`zi.unregister_provider(name)`
: Remove this extension's provider claim.

`zi.on(event_name, handler)`
: Register an observer or interceptor handler. See [events](#events).

`zi.spawn(opts)`
: Run delegated child zi work through batch JSON mode. See [spawn helper](context.html#spawn-helper).

`zi.system(argv, opts?)`
: Run an argv-style system command through the extension async scheduler. Captures bounded stdout/stderr and returns a structured result.

## tools

Tools are definition-first. A tool definition is the unit zi exposes to the model. Keep each tool narrow: one clear name, one clear parameter shape, one readable result. Tool handlers receive the shared [context object](context.html#context-object).

`zi.register_tool(spec)` accepts:

`name`
: Required string. The model-visible tool id and collision key.

`description`
: Required string. Human/model-facing description.

`parameters`
: Required table. JSON-schema-like parameter schema; host validation owns whether `execute` may run.

`execute(params, ctx)`
: Required function. Runs the tool and returns the terminal tool result. Use [context ui api](context.html#context-ui-api), [context state api](context.html#context-state-api), or [context model and ai api](context.html#context-model-and-ai-api) from here as needed.

`label`
: Optional string. UI label. Defaults to `name`.

`prompt_snippet`
: Optional string. Prompt metadata for model guidance.

`prompt_guidelines`
: Optional array of strings. Additional prompt guidance bullets.

`render_call(args, ctx)`
: Optional function. Custom call-slot renderer.

`render_result(result, ctx)`
: Optional function. Custom result-slot renderer.

A terminal tool result has this shape:

```lua
{
  content = {
    { type = "text", text = "..." },
  },
  details = {},   -- optional open JSON-compatible envelope
  is_error = false,
}
```

Tool names are unique. If a later extension registers a tool with an already-claimed name, the later registration is ignored and `zi.register_tool` returns `false`. This keeps ownership explicit.

## commands

Commands are direct user actions. Use them for things a person asks zi to do now: open a report, save a note, start a workflow, or change local state.

`zi.register_command(spec)` accepts:

`name`
: Required string. Slash command name, without the leading `/`.

`description`
: Optional string. Shown in command lists.

`handler(args, ctx)`
: Required function. Runs on the agent thread when the command is invoked.

Example:

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

Slash command ordering is:

1. built-in interactive commands
2. extension commands
3. prompt-template and skill expansion on command miss
4. `input` interceptor over surviving prompt text
5. prompt assembly and provider run

Built-ins stay TUI-local when they need immediate UI/session behavior. Extension commands enqueue semantic command work to the agent thread. Command handlers receive the same [context object](context.html#context-object) as tools and events.

## providers

Providers let extensions add or override visible model/provider choices. Use them to describe what models exist; use events to rewrite requests.

`zi.register_provider(name, config)` supports:

`api`
: Required for custom provider names. For built-in provider overrides, zi can infer the required API family.

`base_url`
: Required string.

`api_key`
: Optional string.

`headers`
: Optional string map.

`models`
: Optional array of model tables for provider-owned visible models. Built-in provider overrides use the built-in visible catalog.

`oauth`
: Optional OAuth callbacks for provider-owned models where the host has a compatible OAuth template. Supported callback fields are `login`, `refresh_token` or `refreshToken`, and `getApiKey`.

Built-in visible provider names with override support today are:

- `anthropic`
- `openai`
- `openrouter`
- `openai-codex`

Provider registration changes the host-owned provider/model views. Extensions own claims, not provider runtime pointers or credential persistence. Use [before_provider_request](#events) for request rewriting, and [context model and ai api](context.html#context-model-and-ai-api) for model inspection/completions.

## events

`zi.on(name, handler)` registers an observer or interceptor. Handlers receive `(event, ctx)`, where `ctx` is described in [context object](context.html#context-object).

Events are where extensions react to the life of a session. They are powerful, so keep them visible and kind: avoid surprising network calls, hidden policy, or changes the user cannot explain later.

Observer events are additive and post-commit. Return values are ignored.

Interceptor events run before zi commits an action. Depending on the event family, handlers may replace payloads, cancel the action, or provide event-specific results.

Supported event names include:

`session_directory`
: Startup event for selecting a session directory.

`resources_discover`
: Add resource folders for `lua/`, `prompts/`, `skills/`, `themes/`, and `agents/`.

`input`
: Middleware/cancellable seam over submitted prompt text after slash-command dispatch.

`before_agent_start`
: Event before the final agent prompt/request. May add messages or replace the system prompt.

`context`
: Middleware over message context used for the next provider call.

`before_provider_request`
: Middleware over semantic provider request payload.

`agent_start`, `agent_end`
: Observe agent run boundaries.

`turn_start`, `turn_end`
: Observe assistant turn boundaries.

`message_start`, `message_update`, `message_end`, `message`
: Observe transcript/message edges. `message_update` is for streaming assistant deltas. `message_end` is the raw lifecycle edge. `message` is the durable semantic observer, dispatched after session persistence with `event.message.entry_id` for use with `ctx.session.entry`, notes, and labels.

`tool_execution_start`, `tool_execution_update`, `tool_execution_end`
: Observe tool execution state.

`tool_call`
: Middleware/cancellable seam over validated tool call input.

`tool_result`
: Middleware seam over final tool result content, details, and error bit before commit.

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

`model_select`
: Observe model selection changes.

Interceptors should return only event-specific semantic data. They should not depend on transport structs, TUI state, mailbox state, or provider runtime handles.
