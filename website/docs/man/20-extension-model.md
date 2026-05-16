---
slug: extensions
title: Extensions
order: 20
aliases:
  - extension
  - extension model
  - teach zi
  - extension files
  - loading
  - lifecycle
---

# Extensions

An extension is a Lua entrypoint that teaches zi one habit.

Use one when you need a command, a tool, a prompt rule, a lifecycle hook, a provider claim, or a small piece of UI.

Good extensions are boring to inspect: clear name, clear inputs, visible effects.

## What extensions can do

- add model-visible tools
- add slash commands
- customize prompts and provider context
- observe session, message, model, tool, and job events
- publish messages, status, progress, reports, prompts, and surfaces
- ask side-channel model questions
- register provider/model claims
- store per-session extension state
- attach notes and labels to durable session entries
- spawn child zi runs

The host API is in [API](api.html). Handler context is in [Context](context.html).

zi loads extensions from the `extensions/` directory in any resource root. See [Resource discovery](resources.html) for user/project locations, settings paths, packages, and root precedence.

## Extension files

Supported shapes:

`extensions/<id>.lua`
: A single-file extension. It can require modules from shared root-level `lua/` folders.

`extensions/<id>/init.lua`
: A bundled extension. Private modules live under `extensions/<id>/lua/` and should use a namespaced module id, for example `require("code_review.render")`.

Module lookup is deterministic:

1. the active bundled extension's private `lua/`
2. shared `lua/` folders from runtime roots
3. Lua's default paths

Within one root, discovery is lexical. Most duplicate registrations are first claimant wins. Slash commands keep duplicate names callable through resolved names.

## After roots

Runtime extension roots may contain an `after/` directory:

```text
<root>/
└─ after/
   ├─ 10-local/
   │  └─ extensions/
   │     └─ tweak.lua
   └─ 20-team/
      └─ extensions/
         └─ policy.lua
```

Each directory directly under `after/` is treated as another runtime root, loaded after the parent root in lexical order. Use this for late customization, not for hidden policy.

## Loading

zi installs a global `zi` table. An extension may register at top level or return a function that receives `zi`.

```lua
return function(zi)
  zi.define.tool({
    name = "greet",
    description = "Generate a greeting.",
    parameters = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name to greet" },
      },
    },
    execute = function(ctx, params)
      local name = params.name or "world"
      return { content = { { type = "text", text = "hello, " .. name } } }
    end,
  })
end
```

Load/register cannot yield. Keep it cheap. Register capabilities there. Do real work in tools, commands, events, jobs, or context helpers.

## Lifecycle

An extension has setup work and session work.

Setup registers tools, commands, providers, and event handlers.

Session work runs later with a live `ctx`.

Rules:

- keep setup cheap and deterministic
- do not start long work while loading
- use tools and commands for visible actions
- use events for policy and reaction
- recreate live UI, prompts, jobs, and provider handles after session changes
- keep ephemeral private state in Lua locals
- keep durable session facts in `ctx.session` artifacts

Common lifecycle events:

- `session_start`
- `session_shutdown`
- `session_before_switch`
- `session_before_fork`
