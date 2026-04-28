## extension purpose

Extensions are Lua programs loaded by zi. They let users shape the agent without rebuilding the Zig core. The concrete host functions are listed in [extension api: zi table](api.html#extension-api-zi-table), and handler context is documented in [context object](context.html#context-object).

Use extensions for things like:

- adding model-visible tools
- adding slash commands
- customizing prompts
- reacting to session, message, tool, and model events
- publishing status/footer/header/widget/panel UI
- asking side-channel model questions
- registering provider/model claims
- storing per-session extension state
- spawning delegated child zi tasks

Extensions describe what should happen. zi decides how to schedule work, update the terminal UI, store session data, call providers, and render transcript output.

## extension discovery

An extension root is a directory-like container. zi discovers extensions from the `extensions/` folder:

```text
<root>/
├─ extensions/
│  ├─ foo.lua
│  └─ bar/
│     └─ init.lua
├─ lua/
├─ prompts/
├─ skills/
├─ themes/
├─ agents/
└─ after/
```

Supported extension shapes:

`extensions/<id>.lua`
: A flat single-file extension.

`extensions/<id>/init.lua`
: A bundled extension with extension-local modules next to `init.lua`.

When multiple roots provide the same kind of capability, zi resolves precedence in this order:

```text
explicit > user > project > builtin
```

Within a root, discovery is lexical and deterministic. Most duplicate registrations use first claimant wins. Commands are different: duplicate command names stay callable through resolved invocation names in [commands](api.html#commands).

## extension loading

The host installs a global `zi` table into the extension Lua state. Extensions may either register directly at top level or return a function that receives `zi`:

```lua
return function(zi)
  zi.register_tool({
    name = "greet",
    description = "Generate a greeting.",
    parameters = {
      type = "object",
      properties = {
        name = { type = "string", description = "Name to greet" },
      },
    },
    execute = function(params, ctx)
      local name = params.name or "world"
      return {
        content = { { type = "text", text = "hello, " .. name } },
      }
    end,
  })
end
```

Load/register is non-suspending. Do not perform long work while the extension loads. Register capabilities, initialize cheap local state, and defer work to [commands](api.html#commands), [tools](api.html#tools), [events](api.html#events), jobs, or [host-owned prompts](context.html#context-ui-api).

## extension lifecycle

An extension has two kinds of work:

- setup work, where it registers tools, commands, providers, and event handlers
- session work, where tools, commands, and events run with a live `ctx`

Important rules:

- keep setup cheap and deterministic
- do not perform long-running work while the extension loads
- use tool bodies or command handlers for user-visible work
- use events for lifecycle policy and reaction
- session-local UI surfaces, prompts, jobs, and provider handles should be recreated after session changes
- durable data that should survive session changes belongs in [context state api](context.html#context-state-api)

Common lifecycle events are [session_start](api.html#events), [session_shutdown](api.html#events), [session_before_switch](api.html#events), and [session_before_fork](api.html#events).
