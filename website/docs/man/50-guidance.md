---
slug: guidance
title: Extension guidance
order: 50
aliases:
  - best practices
  - patterns
  - examples
  - create extension
  - kindness
---

# Extension guidance

Write extensions a tired maintainer can understand.

One job. Clear name. Visible effect. No hidden policy.

Prefer documented APIs. Do not depend on TUI internals, mailbox payloads, provider runtime handles, transcript rows, terminal streams, or render caches.

## Choose the smallest surface

Need: add an action the model can call
: Use [tools](api.html#tools).

Need: add a slash command
: Use [commands](api.html#commands).

Need: change the system prompt
: Use `before_agent_start`.

Need: rewrite submitted input
: Use `input`.

Need: rewrite messages before a provider call
: Use `context`.

Need: rewrite the provider request
: Use `before_provider_request`.

Need: show feedback, status, progress, a report, or a prompt
: Use `ctx.ui`.

Need: remember a per-session choice
: Use explicit `ctx.session` artifacts such as notes or labels.

Need: inspect the transcript, attach notes, or label entries
: Use `ctx.session`.

Need: ask a side-channel model question
: Use `ctx.ai.complete`.

Need: expose a model/provider
: Use `zi.define.provider`.

Need: run a bounded OS command
: Use `ctx.process.run`.

Need: delegate to a child zi run
: Use `ctx.agent.run`.

## Patterns

A tool has one job. If it cannot be described in one sentence, split it.

```lua
return function(zi)
  zi.define.tool({
    name = "project_status",
    description = "Summarize project status.",
    parameters = { type = "object", properties = {} },
    execute = function(ctx, params)
      return { content = { { type = "text", text = "No status provider configured." } } }
    end,
  })
end
```

A command is direct user intent. It should be safe to run when a person asks for it.

```lua
return function(zi)
  zi.define.command({
    name = "note",
    description = "Save a session note.",
    handler = function(ctx, args)
      local ok = ctx.session.append_note({ kind = "manual", body = tostring(args or "") })
      if ctx.ui then ctx.ui.notify.show(ok and "note saved" or "note failed", { id = "note", level = ok and "success" or "error" }) end
    end,
  })
end
```

A message observer can attach durable memory without touching raw JSONL or UI rows.

```lua
zi.define.event("message", function(ctx, event)
  local message = event.message or {}
  if message.role == "user" and message.text and message.text:match("decision") then
    ctx.session.label(message.entry_id, "decision")
    ctx.session.append_note({
      kind = "observation",
      body = "possible decision",
      source_entry_id = message.entry_id,
    })
  end
end)
```

An event is for policy or reaction. Keep it easy to explain later.

```lua
zi.define.event("message", function(ctx, event)
  local message = event.message or {}
  if message.role == "assistant" and ctx.ui then
    ctx.ui.notify.show("assistant replied", { id = "assistant-replied", level = "info" })
  end
end)
```

## Kindness rules

- ask before destructive actions
- show paths before changing files outside the project
- name models and providers when changing them
- prefer local files, local state, and project-relative paths
- do not hide network calls inside unrelated commands
- return errors a person can act on
- keep generated extensions short enough to review

## Examples to copy

`hello.lua`
: Minimal tool.

`commands.lua`
: Slash command with a report.

`dynamic_tools.lua`
: Dynamic tool registration.

`prompt_customizer.lua`
: `before_agent_start` prompt customization.

`status_line.lua`
: Turn lifecycle status.

`message_watch.lua`
: Semantic message observer.

`model_completion.lua`
: Model catalog and `ctx.ai.complete`.

`session_lifecycle.lua`
: Session lifecycle hooks.

`session_notes.lua`
: Session notes.

`auto_label.lua`
: Durable labels and entry lookup.

`git_status.lua`
: `ctx.process.run` with report output.

`message.lua`
: Short feedback.

`question.lua`, `questionnaire.lua`, `timed_confirm.lua`
: Host-owned prompts.

`input_transform.lua`, `permission_gate.lua`
: Input and permission-style interceptors.

`summarize.lua`, `handoff.lua`, `qna.lua`
: Workflow-shaped commands/tools.
