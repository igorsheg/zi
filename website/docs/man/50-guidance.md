## extension design rules

Prefer documented host APIs over host details.

Do not depend on TUI components, terminal input streams, mailbox payloads, provider runtime handles, transcript row objects, or render caches.

Keep load/register cheap and deterministic.

Use [tools](api.html#tools) for model-visible capabilities.

Use [commands](api.html#commands) for direct user actions.

Use [events](api.html#events) for lifecycle policy, prompt/context rewriting, message watching, and tool/provider interception.

Use [`ctx.ui`](context.html#context-ui-api) to publish UI intent.

Use [`ctx.state`](context.html#context-state-api) for durable per-extension session state.

Use [`ctx.ai.complete`](context.html#context-model-and-ai-api) for side-channel model calls that should not mutate the transcript.

Use [`zi.register_provider`](api.html#providers) for provider/model visibility, not for request rewriting. Use [`before_provider_request`](api.html#events) for request rewriting.

## capability guide

Need: add an action the model can call
: Use [tools](api.html#tools).

Need: add a slash command for the user
: Use [commands](api.html#commands).

Need: change the system prompt
: Use [`before_agent_start`](api.html#events).

Need: rewrite submitted user input
: Use [`input`](api.html#events).

Need: rewrite messages before a provider call
: Use [`context`](api.html#events).

Need: rewrite the provider request
: Use [`before_provider_request`](api.html#events).

Need: show status, footer text, a panel, or a prompt
: Use [context ui api](context.html#context-ui-api).

Need: remember a per-session choice
: Use [context state api](context.html#context-state-api).

Need: inspect the transcript or session notes
: Use [context session api](context.html#context-session-api).

Need: ask a side-channel model question
: Use [`ctx.ai.complete`](context.html#context-model-and-ai-api).

Need: expose a model/provider
: Use [providers](api.html#providers).

Need: delegate work to a child zi run
: Use [spawn helper](context.html#spawn-helper).

## canonical patterns

A model-visible tool has one job: accept structured parameters, perform the action, and return content.

```lua
return function(zi)
  zi.register_tool({
    name = "project_status",
    description = "Summarize project status.",
    parameters = { type = "object", properties = {} },
    execute = function(params, ctx)
      return { content = { { type = "text", text = "No status provider configured." } } }
    end,
  })
end
```

A slash command is for direct user intent.

```lua
return function(zi)
  zi.register_command({
    name = "note",
    description = "Save a session note.",
    handler = function(args, ctx)
      local ok = ctx.session.append_note({ kind = "manual", body = tostring(args or "") })
      if ctx.ui then ctx.ui.set_footer(ok and "note saved" or "note failed") end
    end,
  })
end
```

An event is for policy or reaction.

```lua
zi.on("message", function(event, ctx)
  local message = event.message or {}
  if message.role == "assistant" and ctx.ui then
    ctx.ui.set_footer("assistant replied")
  end
end)
```

## extension examples

`hello.lua`
: Minimal tool registration.

`commands.lua`
: Slash command with a host-owned panel.

`dynamic_tools.lua`
: Dynamic tool registration from an event or command.

`prompt_customizer.lua`
: System prompt customization with `before_agent_start`.

`status_line.lua`
: Turn lifecycle status publication.

`message_watch.lua`
: Semantic message observer.

`model_completion.lua`
: Model catalog inspection and `ctx.ai.complete`.

`session_lifecycle.lua`
: Session lifecycle observation and cancellable pre-hooks.

`session_notes.lua`
: Session note storage and retrieval.

`notify.lua`
: Notification surface.

`question.lua`, `questionnaire.lua`, `timed_confirm.lua`
: Host-owned prompts.

`custom_header.lua`, `widget_placement.lua`, `hidden_thinking_label.lua`, `titlebar.lua`
: Host-owned UI surfaces.

`input_transform.lua`, `permission_gate.lua`
: Input and permission-style interception patterns.

`summarize.lua`, `handoff.lua`, `qna.lua`
: Workflow-shaped commands/tools built from the same primitives.
