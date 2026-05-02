## Extension purpose

An extension is a Lua entrypoint that teaches zi one habit.

It can register a command, expose a model-visible tool, customize prompts, store small bits of state, react to lifecycle events, or publish simple UI. You do not need a framework, build step, or package registry. Start with the smallest useful thing.

Good extensions have clear names, clear inputs, visible effects, and no surprise ownership of the user's workflow.

The concrete host functions are listed in [extension api: zi table](api.html#extension-api-zi-table), and handler context is documented in [context object](context.html#context-object).

Use extensions for things like:

- adding model-visible tools
- adding slash commands
- customizing prompts
- reacting to session, message, tool, and model events
- publishing message, status, progress, and report UI
- asking side-channel model questions
- registering provider/model claims
- storing per-session extension state
- attaching semantic notes/labels to durable session entries
- spawning delegated child zi tasks

Extensions describe what should happen. zi decides how to schedule work, update the terminal UI, store session data, call providers, and render transcript output.

## Extension discovery

An extension root is a directory-like container. zi discovers extension entrypoints from the `extensions/` folder and Lua modules from `lua/` folders:

```text
<root>/
├─ extensions/
│  ├─ notify.lua              # flat, single-file extension
│  └─ code-review/            # bundled extension
│     ├─ init.lua             # entrypoint
│     └─ lua/
│        └─ code_review/
│           └─ render.lua     # require("code_review.render")
├─ lua/
│  └─ shared/
│     └─ util.lua             # require("shared.util")
├─ prompts/
├─ skills/
├─ themes/
├─ agents/
└─ after/
```

Supported extension shapes:

`extensions/<id>.lua`
: A flat single-file extension. Use this for small extensions that do not own private Lua modules. Flat extensions can still require modules from the root-level shared `lua/` directories.

`extensions/<id>/init.lua`
: A bundled extension. Put private Lua modules under `extensions/<id>/lua/` and require them with a namespaced module id, such as `require("my_ext.render")` for `extensions/my-ext/lua/my_ext/render.lua`.

Lua module resolution follows the same precedence as extension loading: the active bundled extension's private `lua/` directory first, then shared `lua/` directories from runtime roots in canonical order, then Lua's default paths. zi does not synthesize private module roots for flat files.

When multiple roots provide the same kind of capability, zi resolves precedence in this order:

```text
explicit > user > project > builtin
```

Within a root, discovery is lexical and deterministic. Most duplicate registrations use first claimant wins. Commands are different: duplicate command names stay callable through resolved invocation names in [commands](api.html#commands).

## Extension loading

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

Load/register is non-suspending. Keep it cheap and deterministic: register capabilities, initialize small local state, and defer real work to [commands](api.html#commands), [tools](api.html#tools), [events](api.html#events), jobs, or [host-owned prompts](context.html#context-ui-api).

## Extension lifecycle

An extension has two kinds of work:

- setup work, where it registers tools, commands, providers, and event handlers
- session work, where tools, commands, and events run with a live `ctx`

Important rules:

- keep setup cheap and deterministic
- do not perform long-running work while the extension loads
- use tool bodies or command handlers for user-visible work
- use events for lifecycle policy and reaction
- recreate session-local UI surfaces, prompts, jobs, and provider handles after session changes
- store private extension state that should survive session changes in [context state api](context.html#context-state-api)
- store shared semantic session artifacts in [context session api](context.html#context-session-api), such as notes, labels, and entry lookup

Common lifecycle events are [session_start](api.html#events), [session_shutdown](api.html#events), [session_before_switch](api.html#events), and [session_before_fork](api.html#events).
